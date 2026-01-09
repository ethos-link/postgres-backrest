# Postgres with PgBackRest

A Docker image that combines PostgreSQL with PgBackRest for backup and restore capabilities.

## Features

- Based on official PostgreSQL image
- Includes PgBackRest for advanced backup features
- Configurable via environment variables
- Supports multiple storage backends (local, S3, etc.)

## Usage

```bash
docker run -e POSTGRES_PASSWORD=mysecretpassword ghcr.io/your-org/postgres-backrest:latest
```

## Configuration

### PostgreSQL Configuration

The image includes a default `postgresql.conf` optimized for use with PgBackRest. You can override it by mounting your own configuration file.

### PgBackRest Configuration

PgBackRest is configured via environment variables. The default configuration uses local storage. For S3, set the following variables:

- `PGBACKREST_REPO1_TYPE=s3`
- `PGBACKREST_REPO1_S3_ENDPOINT`
- `PGBACKREST_REPO1_S3_BUCKET`
- `PGBACKREST_REPO1_S3_REGION`
- `PGBACKREST_REPO1_S3_KEY`
- `PGBACKREST_REPO1_S3_KEY_SECRET`

See the `pgbackrest.conf.template` for all available options.

## Building

To build the image with a specific PostgreSQL version:

```bash
docker build --build-arg POSTGRES_VERSION=17.0 -t postgres-backrest:17.0 .
```

## Publishing

The image is published to Docker Hub and GitHub Container Registry.

To update to a new PostgreSQL version, update the `POSTGRES_VERSION` in the Dockerfile and rebuild.

## License

MIT