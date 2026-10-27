#!/usr/bin/env python3
"""Host smoke tests: real logrotate, temporary logs, no production paths."""
import gzip
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RotationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.logs = self.directory / 'logs'
        self.logs.mkdir()
        self.config = self.directory / 'logrotate.conf'
        template = (ROOT / 'ops/pgbackrest-logrotate.conf.template').read_text()
        self.config.write_text(template.replace('${LOG_DIRECTORY}', str(self.logs))
                               .replace('${LOG_UID}', str(os.getuid()))
                               .replace('${LOG_GID}', str(os.getgid())))
        self.state = self.directory / 'status'

    def run_rotation(self):
        subprocess.run([str(ROOT / 'ops/rotate-pgbackrest-logs'),
                        str(self.config), str(self.state), str(self.logs)], check=True,
                       umask=0o077)

    def test_size_compression_open_writer_and_permissions(self):
        path = self.logs / 'main-archive-push-async.log'
        with path.open('wb') as stream:
            stream.write(b'diagnostic before rotation\n')
            stream.truncate(25 * 1024 * 1024 + 1)
        path.chmod(0o640)
        before = path.stat()
        # Hold the same O_APPEND descriptor across the rotation, like pgBackRest.
        with path.open('ab', buffering=0) as writer:
            self.run_rotation()
            writer.write(b'active logging after rotation\n')
        after = path.stat()
        self.assertEqual((before.st_ino, before.st_uid, before.st_gid, before.st_mode),
                         (after.st_ino, after.st_uid, after.st_gid, after.st_mode))
        self.assertEqual(path.read_bytes(), b'active logging after rotation\n')
        archives = list(self.logs.glob('*.gz'))
        self.assertEqual(len(archives), 1)
        with gzip.open(archives[0]) as stream:
            self.assertTrue(stream.read(100).startswith(b'diagnostic before rotation\n'))
        archived = archives[0].stat()
        self.assertEqual((archived.st_uid, archived.st_gid, archived.st_mode & 0o777),
                         (before.st_uid, before.st_gid, 0o640))
        # State survives repeated invocations; small files do not rotate hourly.
        self.run_rotation()
        self.assertEqual(len(list(self.logs.glob('*.gz'))), 1)

    def test_daily_all_logs_missing_and_empty(self):
        self.run_rotation()  # No files is fine.
        (self.logs / 'empty.log').touch()
        for name in ['main-backup.log', 'main-expire.log', 'other-command.log']:
            (self.logs / name).write_text('useful log\n')
        # A state from two days ago exercises daily rotation without force.
        old = time.localtime(time.time() - 2 * 86400)
        self.state.write_text('logrotate state -- version 2\n' + ''.join(
            f'"{path}" {old.tm_year}-{old.tm_mon}-{old.tm_mday}-0:0:0\n'
            for path in self.logs.glob('*.log')))
        self.run_rotation()
        self.assertEqual(len(list(self.logs.glob('*.gz'))), 3)
        self.assertEqual((self.logs / 'empty.log').stat().st_size, 0)
        self.assertFalse(list(self.logs.glob('empty.log-*')))

    def test_expiration_inactive_logs_and_safety(self):
        files = ['quiet.log-20260101000000.gz', 'quiet.log-20260101000001',
                 'fresh.log-20260101000000.gz', 'live.log', 'unrelated.gz']
        for name in files:
            (self.logs / name).write_text('retain diagnostics\n')
        stale = time.time() - 15 * 86400
        for name in files:
            if not name.startswith('fresh'):
                os.utime(self.logs / name, (stale, stale))
        recent = time.time() - 13 * 86400
        os.utime(self.logs / files[2], (recent, recent))
        nested = self.logs / 'subdirectory'
        nested.mkdir()
        (nested / files[0]).write_text('do not traverse\n')
        os.utime(nested / files[0], (stale, stale))
        (self.logs / 'symlink.log-20260101000000.gz').symlink_to(self.logs / 'live.log')
        self.run_rotation()
        self.assertFalse((self.logs / files[0]).exists())
        self.assertFalse((self.logs / files[1]).exists())
        for name in files[2:]:
            self.assertTrue((self.logs / name).exists())
        self.assertTrue((nested / files[0]).exists())
        self.assertTrue((self.logs / 'symlink.log-20260101000000.gz').is_symlink())

    def test_staged_install_and_scheduler_contract(self):
        self.check_staged_install('/var/log/ethos-postgres-18/pgbackrest', custom=False)

    def test_custom_log_directory_is_shared_by_rotation_expiry_and_sandbox(self):
        self.check_staged_install('/srv/diagnostics/custom-postgres', custom=True)

    def check_staged_install(self, log_directory, custom):
        stage = self.directory / 'stage'
        # Supply the normal systemd target in the minimal offline staging tree.
        targets = stage / 'usr/lib/systemd/system'
        targets.mkdir(parents=True)
        for name in ['sysinit', 'basic', 'shutdown', 'timers']:
            (targets / f'{name}.target').write_text('[Unit]\nDescription=Offline target\n')
        arguments = [str(ROOT / 'ops/install-log-rotation.sh'),
                     str(os.getuid()), str(os.getgid())]
        if custom:
            arguments.append(log_directory)
        subprocess.run(arguments, check=True,
                       env={**os.environ, 'DESTDIR': str(stage)})
        config = (stage / 'etc/pgbackrest-logrotate.conf').read_text()
        self.assertIn('rotate 336', config)
        self.assertIn('maxage 14', config)
        self.assertNotIn('${', config)
        self.assertIn(f'"{log_directory}/*.log"', config)
        timer = (stage / 'etc/systemd/system/pgbackrest-logrotate.timer').read_text()
        self.assertIn('OnCalendar=hourly', timer)
        self.assertIn('Persistent=true', timer)
        self.assertIn('WantedBy=timers.target', timer)
        service = (stage / 'etc/systemd/system/pgbackrest-logrotate.service').read_text()
        self.assertIn('StateDirectory=pgbackrest-logrotate', service)
        self.assertIn('ExecStart=/usr/local/sbin/rotate-pgbackrest-logs ', service)
        command = next(line.removeprefix('ExecStart=') for line in service.splitlines()
                       if line.startswith('ExecStart='))
        self.assertEqual(shlex.split(command)[-1], log_directory)
        self.assertIn(f'ReadWritePaths={log_directory}\n', service)
        self.assertNotIn('${', service)
        for directive in ['ProtectSystem=strict', 'ProtectHome=true',
                          'PrivateTmp=true', 'NoNewPrivileges=true']:
            self.assertIn(directive, service)
        self.assertTrue(os.access(stage / 'usr/local/sbin/rotate-pgbackrest-logs', os.X_OK))
        self.assertTrue((stage / 'etc/systemd/system/timers.target.wants/pgbackrest-logrotate.timer').is_symlink())
        subprocess.run(['systemd-analyze', f'--root={stage}', 'verify',
                        '/etc/systemd/system/pgbackrest-logrotate.service',
                        '/etc/systemd/system/pgbackrest-logrotate.timer'], check=True)
        # Staging never starts a host service; a live installation must enable AND start.
        installer = (ROOT / 'ops/install-log-rotation.sh').read_text()
        self.assertIn('systemctl enable --now pgbackrest-logrotate.timer', installer)
        self.assertIn('systemctl is-active --quiet pgbackrest-logrotate.timer', installer)

    def test_installer_rejects_ambiguous_or_sandboxed_paths(self):
        for path in ['relative/path', '/', '/var/log/trailing/', '/var/log/../tmp',
                     '/var/log/./logs', '/var/log//logs', '/var/log/space here',
                     '/var/log/%n', '/tmp/logs', '/var/tmp/logs', '/home/user/logs']:
            with self.subTest(path=path):
                stage = self.directory / 'stage'
                result = subprocess.run([str(ROOT / 'ops/install-log-rotation.sh'),
                                         str(os.getuid()), str(os.getgid()), path],
                                        env={**os.environ, 'DESTDIR': str(stage)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(stage.exists())

    def test_low_space_preserves_live_logs_and_still_expires_old_rotations(self):
        live = self.logs / 'main-archive-push-async.log'
        live.write_text('preserve these diagnostics\n')
        before = live.stat()
        old = self.logs / 'quiet.log-20260101000000.gz'
        old.write_text('expired rotation')
        stale = time.time() - 15 * 86400
        os.utime(old, (stale, stale))
        binaries = self.directory / 'bin'
        binaries.mkdir()
        df = binaries / 'df'
        df.write_text('#!/bin/sh\nprintf "Avail\\n0\\n"\n')
        df.chmod(0o755)
        environment = {**os.environ, 'PATH': f'{binaries}:{os.environ["PATH"]}'}
        runner = str(ROOT / 'ops/rotate-pgbackrest-logs')
        preflight = subprocess.run([runner, '--check-space', str(self.logs)],
                                   env=environment, capture_output=True, text=True)
        self.assertEqual(preflight.returncode, 1)
        self.assertTrue(old.exists())  # Installation preflight is read-only.
        rotation = subprocess.run([runner, str(self.config), str(self.state), str(self.logs)],
                                  env=environment, capture_output=True, text=True)
        self.assertEqual(rotation.returncode, 1)
        self.assertIn('Insufficient rotation space', rotation.stderr)
        self.assertFalse(old.exists())
        self.assertEqual(live.read_text(), 'preserve these diagnostics\n')
        self.assertEqual(live.stat().st_ino, before.st_ino)
        self.assertFalse(self.state.exists())
        self.assertFalse(list(self.logs.glob('main-archive-push-async.log-*')))

    def test_space_budget_covers_all_copies_and_largest_compression(self):
        (self.logs / 'main-backup.log').write_bytes(b'a' * 1024)
        (self.logs / 'main-expire.log').write_bytes(b'b' * 2048)
        required = 1024 + 2048 + 2048 + 64 * 1024 * 1024
        binaries = self.directory / 'bin'
        binaries.mkdir()
        df = binaries / 'df'
        for available, expected in [(required - 1, 1), (required, 0)]:
            with self.subTest(available=available):
                df.write_text(f'#!/bin/sh\nprintf "Avail\\n{available}\\n"\n')
                df.chmod(0o755)
                result = subprocess.run([str(ROOT / 'ops/rotate-pgbackrest-logs'),
                                         '--check-space', str(self.logs)],
                                        env={**os.environ, 'PATH': f'{binaries}:{os.environ["PATH"]}'},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
