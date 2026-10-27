#!/usr/bin/env python3
"""Exercise OS logrotate/tmpfiles with temporary logs; never start host services."""
import gzip
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'ops/install-log-rotation.sh'


class RotationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.logs = self.directory / 'logs'
        self.logs.mkdir()
        self.config = self.directory / 'logrotate.conf'
        self.config.write_text(self.render('pgbackrest-logrotate.conf.template', self.logs))
        self.tmpfiles = self.directory / 'tmpfiles.conf'
        self.tmpfiles.write_text(self.render('pgbackrest-tmpfiles.conf.template', self.logs))
        self.state = self.directory / 'status'

    def render(self, name, directory):
        return ((ROOT / 'ops' / name).read_text().replace('${LOG_DIRECTORY}', str(directory))
                .replace('${LOG_UID}', str(os.getuid()))
                .replace('${LOG_GID}', str(os.getgid())))

    def run_rotation(self):
        # Use the real OS binary directly, as logrotate.service does.
        subprocess.run(['logrotate', '--state', str(self.state), str(self.config)],
                       check=True, umask=0o077)

    def test_size_compression_open_writer_and_permissions(self):
        path = self.logs / 'main-archive-push-async.log'
        with path.open('wb') as stream:
            stream.write(b'diagnostic before rotation\n')
            stream.truncate(25 * 1024 * 1024 + 1)
        path.chmod(0o640)
        before = path.stat()
        with path.open('ab', buffering=0) as writer:
            self.run_rotation()
            writer.write(b'active logging after rotation\n')
        after = path.stat()
        self.assertEqual((before.st_ino, before.st_uid, before.st_gid, before.st_mode),
                         (after.st_ino, after.st_uid, after.st_gid, after.st_mode))
        self.assertEqual(path.read_bytes(), b'active logging after rotation\n')
        archives = list((self.logs / 'rotated').glob('*.gz'))
        self.assertEqual(len(archives), 1)
        with gzip.open(archives[0]) as stream:
            self.assertTrue(stream.read(100).startswith(b'diagnostic before rotation\n'))
        archived = archives[0].stat()
        self.assertEqual((archived.st_uid, archived.st_gid, archived.st_mode & 0o777),
                         (before.st_uid, before.st_gid, 0o640))
        self.assertEqual((self.logs / 'rotated').stat().st_mode & 0o777, 0o750)
        self.run_rotation()
        self.assertEqual(len(list((self.logs / 'rotated').glob('*.gz'))), 1)

    def test_daily_all_logs_missing_and_empty(self):
        self.run_rotation()
        (self.logs / 'empty.log').touch()
        for name in ['main-backup.log', 'main-expire.log', 'other-command.log']:
            (self.logs / name).write_text('useful log\n')
        old = time.localtime(time.time() - 2 * 86400)
        self.state.write_text('logrotate state -- version 2\n' + ''.join(
            f'"{path}" {old.tm_year}-{old.tm_mon}-{old.tm_mday}-0:0:0\n'
            for path in self.logs.glob('*.log')))
        self.run_rotation()
        self.assertEqual(len(list((self.logs / 'rotated').glob('*.gz'))), 3)
        self.assertEqual((self.logs / 'empty.log').stat().st_size, 0)
        self.assertFalse(list((self.logs / 'rotated').glob('empty.log-*')))

    def test_native_expiry_of_inactive_rotations_preserves_live_files(self):
        # Missing rotated directories are harmless to the OS cleaner.
        subprocess.run(['systemd-tmpfiles', '--clean', str(self.tmpfiles)], check=True)
        rotated = self.logs / 'rotated'
        rotated.mkdir()
        stale = time.time() - 15 * 86400
        recent = time.time() - 13 * 86400
        old = rotated / 'quiet.log-20260101000000.gz'
        fresh = rotated / 'fresh.log-20260102000000.gz'
        live = self.logs / 'main-archive-push-async.log'
        for path, timestamp in [(old, stale), (fresh, recent), (live, stale)]:
            path.write_text('diagnostic contents\n')
            os.utime(path, (timestamp, timestamp))
        link = rotated / 'symlink.log-20260101000000.gz'
        link.symlink_to(live)
        os.utime(link, (stale, stale), follow_symlinks=False)
        subprocess.run(['systemd-tmpfiles', '--clean', str(self.tmpfiles)], check=True)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())
        self.assertEqual(live.read_text(), 'diagnostic contents\n')

    def test_default_install_reuses_os_units(self):
        self.check_staged_install('/var/log/ethos-postgres-18/pgbackrest', custom=False)

    def test_native_expiry_does_not_follow_a_symlinked_rotation_directory(self):
        outside = self.directory / 'outside'
        outside.mkdir()
        preserved = outside / 'unrelated-data'
        preserved.write_text('preserve')
        stale = time.time() - 15 * 86400
        os.utime(preserved, (stale, stale))
        (self.logs / 'rotated').symlink_to(outside, target_is_directory=True)
        subprocess.run(['systemd-tmpfiles', '--clean', str(self.tmpfiles)], check=True)
        self.assertEqual(preserved.read_text(), 'preserve')

    def test_custom_directory_is_shared_by_os_rotation_expiry_and_permissions(self):
        self.check_staged_install('/srv/diagnostics/custom-postgres', custom=True)

    def check_staged_install(self, log_directory, custom):
        stage = self.directory / 'stage'
        units = stage / 'usr/lib/systemd/system'
        units.mkdir(parents=True)
        for name in ['sysinit', 'basic', 'shutdown', 'timers']:
            (units / f'{name}.target').write_text('[Unit]\nDescription=Offline target\n')
        # Stage distribution-owned units; the installer must not create replacements.
        for name in ['logrotate.timer', 'logrotate.service',
                     'systemd-tmpfiles-clean.timer', 'systemd-tmpfiles-clean.service']:
            shutil.copyfile(Path('/usr/lib/systemd/system') / name, units / name)
        # Verification checks executability, but never executes these staged paths.
        for executable in ['/usr/sbin/logrotate', '/usr/bin/systemd-tmpfiles']:
            path = stage / executable.lstrip('/')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        arguments = [str(INSTALLER), str(os.getuid()), str(os.getgid())]
        if custom:
            arguments.append(log_directory)
        subprocess.run(arguments, check=True, env={**os.environ, 'DESTDIR': str(stage)})
        config = (stage / 'etc/logrotate.d/pgbackrest').read_text()
        self.assertIn('rotate 336', config)
        self.assertIn('maxage 14', config)
        self.assertNotIn('${', config)
        self.assertIn(f'"{log_directory}/*.log"', config)
        self.assertIn('olddir rotated', config)
        expiry = (stage / 'etc/tmpfiles.d/pgbackrest.conf').read_text()
        self.assertIn(f'e {log_directory}/rotated - - - m:14d -', expiry)
        timer = (stage / 'etc/systemd/system/logrotate.timer.d/pgbackrest-hourly.conf').read_text()
        self.assertIn('OnCalendar=\nOnCalendar=hourly', timer)
        self.assertIn('RandomizedDelaySec=0', timer)
        service = (stage / 'etc/systemd/system/logrotate.service.d/pgbackrest.conf').read_text()
        self.assertIn(f'ReadWritePaths={log_directory}\n', service)
        for name in ['logrotate.timer', 'systemd-tmpfiles-clean.timer']:
            self.assertTrue((stage / 'etc/systemd/system/timers.target.wants' / name).is_symlink())
        self.assertFalse(list((stage / 'etc/systemd/system').glob('pgbackrest-*')))
        subprocess.run(['systemd-analyze', f'--root={stage}', 'verify',
                        '/usr/lib/systemd/system/logrotate.timer',
                        '/usr/lib/systemd/system/systemd-tmpfiles-clean.timer'], check=True)
        installer = INSTALLER.read_text()
        self.assertIn('systemctl enable --now logrotate.timer', installer)
        self.assertIn('systemctl add-wants timers.target systemd-tmpfiles-clean.timer', installer)
        self.assertIn('systemctl start systemd-tmpfiles-clean.timer', installer)

    def test_installer_rejects_ambiguous_or_sandboxed_paths(self):
        for path in ['relative/path', '/', '/var/log/trailing/', '/var/log/../tmp',
                     '/var/log/./logs', '/var/log//logs', '/var/log/space here',
                     '/var/log/%n', '/tmp/logs', '/var/tmp/logs', '/home/user/logs']:
            with self.subTest(path=path):
                stage = self.directory / 'stage'
                result = subprocess.run([str(INSTALLER), str(os.getuid()),
                                         str(os.getgid()), path],
                                        env={**os.environ, 'DESTDIR': str(stage)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(stage.exists())

    def test_installation_space_check_is_read_only(self):
        live = self.logs / 'main-archive-push-async.log'
        live.write_text('preserve these diagnostics\n')
        before = live.stat()
        result = self.check_space(available=0)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Insufficient rotation space', result.stderr)
        self.assertEqual(live.read_text(), 'preserve these diagnostics\n')
        self.assertEqual(live.stat().st_ino, before.st_ino)
        self.assertFalse(self.state.exists())

    def test_installation_budget_covers_all_copies_and_largest_compression(self):
        (self.logs / 'main-backup.log').write_bytes(b'a' * 1024)
        (self.logs / 'main-expire.log').write_bytes(b'b' * 2048)
        required = 1024 + 2048 + 2048 + 64 * 1024 * 1024
        for available, expected in [(required - 1, 1), (required, 0)]:
            with self.subTest(available=available):
                result = self.check_space(available)
                self.assertEqual(result.returncode, expected, result.stderr)

    def check_space(self, available):
        binaries = self.directory / 'bin'
        binaries.mkdir(exist_ok=True)
        df = binaries / 'df'
        df.write_text(f'#!/bin/sh\nprintf "Avail\\n{available}\\n"\n')
        df.chmod(0o755)
        return subprocess.run([str(INSTALLER), '--check-space', str(self.logs)],
                              env={**os.environ, 'PATH': f'{binaries}:{os.environ["PATH"]}'},
                              capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
