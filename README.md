# odoo-backup-service

Scheduled backups for Odoo running in Docker: a ready-made image plus a
Portainer/Docker stack template, so any Odoo-on-Docker server can add the same
backup in a few minutes. Each run writes one zip per database, in the same
layout as the backups made by Odoo's Database Manager:

```
mydb_20261028_020000.zip
├── dump.sql      # pg_dump --no-owner, plain SQL
└── filestore/    # contents of /var/lib/odoo/filestore/mydb/
```

- Runs as its own small container (Alpine + `pg_dump` + BusyBox `crond`, ~31 MB)
  next to your Odoo stack. No `docker.sock`, Odoo data mounted read-only.
- Configured only with environment variables: no server, stack or database names
  are baked in.
- Daily schedule, retention in days, run-now command, atomic writes, verified zips.

## What's in this repo

| Path | What it is |
|---|---|
| `Dockerfile`, `scripts/` | the backup image, published as `ghcr.io/erikoindra/odoo-backup-service` |
| `stacks/odoo-backup/` | the stack: `docker-compose.yml` + `.env.example` |
| `templates/portainer.json` | Portainer App Template for that stack |
| `tools/discover.sh` | prints the stack variables for an existing Odoo container |
| `tools/restore.sh` | restores a backup zip into a new database |
| `docs/` | [how it works](docs/how-it-works.md), [restore guide](docs/restore.md) |
| `.github/workflows/` | tests the image and publishes it to GHCR (it does not deploy anything) |

## 1. Find your values

On the Docker host that runs Odoo:

```bash
git clone https://github.com/erikoindra/odoo-backup-service.git
cd odoo-backup-service
sudo tools/discover.sh <odoo-container> > backup.env
```

`discover.sh` only reads the Odoo container: the DB host and user (from `odoo.conf`,
then the `HOST`/`USER` variables of the official image), the volume holding
`data_dir`, the network shared with the PostgreSQL container, the PostgreSQL version
(which picks the image tag) and the databases that have a filestore. It never prints
the password: fill in `PGPASSWORD` yourself.

```
IMAGE=ghcr.io/erikoindra/odoo-backup-service:pg17
PGHOST=db
PGPORT=5432
PGUSER=odoo
PGPASSWORD=
ODOO_DATA_VOLUME=myproject_odoo_data
DB_NETWORK=myproject_default
DB_NAME=mydb
...
```

Run it without arguments to list the containers that look like Odoo.

## 2. Deploy with Portainer

Pick one way:

**A. App Template** (a form with every field)

1. *Settings > App Templates > URL*:
   `https://raw.githubusercontent.com/erikoindra/odoo-backup-service/master/templates/portainer.json`.
   This replaces Portainer's built-in template list for that Portainer instance.
2. *App Templates > Odoo Backup*: fill in the fields and deploy.

**B. Stack from this repository** (follows the repo)

1. *Stacks > Add stack > Repository*: URL `https://github.com/erikoindra/odoo-backup-service`,
   reference `refs/heads/master`, compose path `stacks/odoo-backup/docker-compose.yml`.
2. *Environment variables > Load variables from .env file*: `backup.env` from step 1,
   then fill in `PGPASSWORD`.
3. Deploy. Optionally turn on GitOps updates to pick up changes to the stack file.

**C. Web editor**: paste [`stacks/odoo-backup/docker-compose.yml`](stacks/odoo-backup/docker-compose.yml)
and load the variables as in B.

Without Portainer:

```bash
docker compose --env-file backup.env -f stacks/odoo-backup/docker-compose.yml -p odoo-backup up -d
```

## 3. First backup

The container log should start with:

```
odoo-backup-service v0.1.0: schedule '0 2 * * *' (TZ=Asia/Jakarta), retention 3 day(s), target /backups
```

Run one backup now instead of waiting for the schedule:

```bash
docker exec <backup-container> odoo-backup
docker exec <backup-container> ls -lh /backups
```

In Portainer: *Containers > (backup container) > Console > Connect*, then type `odoo-backup`.
A stack named `mystack` gets the container `mystack-odoo-backup-1`.

## Image tags

`pg_dump` must match your PostgreSQL **server major version**, so the tag is the major:

| Server | Tag |
|---|---|
| PostgreSQL 14 | `ghcr.io/erikoindra/odoo-backup-service:pg14` |
| PostgreSQL 15 | `…:pg15` |
| PostgreSQL 16 | `…:pg16` |
| PostgreSQL 17 | `…:pg17` |
| PostgreSQL 18 | `…:pg18` |

Pinned releases: `pg17-0.1.0`, `pg17-0.1`. Latest build of the default branch:
`pg17-edge`. There is no `latest`. `tools/discover.sh` picks the tag for you.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE` | `…:pg17` | image to run (stack variable) |
| `PGHOST` | (required) | DB host: container name or alias on `DB_NETWORK` |
| `PGPORT` | `5432` | DB port |
| `PGUSER` | (required) | DB user. The Odoo user that owns the database is enough |
| `PGPASSWORD` | (required) | DB password. In Portainer write a `$` as `$$` |
| `PGPASSWORD_FILE` | | file holding the password instead (Docker secrets) |
| `ODOO_DATA_VOLUME` | (required) | existing volume mounted at Odoo's `data_dir` (stack variable) |
| `DB_NETWORK` | (required) | existing network the DB container is on (stack variable) |
| `DB_NAME` | empty | database(s), comma or space separated. Empty: every database that has a folder in the filestore |
| `BACKUP_VOLUME` | `odoo-backups` | volume the zips go to, created if missing (stack variable) |
| `BACKUP_PREFIX` | empty | file name prefix, e.g. `prod_` → `prod_mydb_20261028_020000.zip` |
| `RETENTION_DAYS` | `3` | delete this database's zips older than N days after a successful run. `0` keeps everything |
| `CRON_SCHEDULE` | `0 2 * * *` | 5-field cron expression |
| `TZ` | `UTC` | time zone for the schedule and file names, e.g. `Asia/Jakarta` |
| `RUN_ON_START` | `false` | also run one backup when the container starts |
| `MIN_FREE_MB` | `1024` | refuse to start a backup with less free space in `/backups` |
| `FILESTORE_ROOT` | `/odoo-data/filestore` | only if `data_dir` is a subfolder of the volume (`discover.sh` tells you) |

Any other libpq variable (`PGSSLMODE`, …) is passed through to `pg_dump`.

## Restore

```bash
sudo tools/restore.sh <backup.zip> <new-db-name> <odoo-container> <db-container>
```

It always restores into a **new** database and never overwrites anything. Odoo's
Database Manager and a manual way are in [docs/restore.md](docs/restore.md).

## Use your own fork

Replace `erikoindra/odoo-backup-service` in `templates/portainer.json`,
`stacks/odoo-backup/docker-compose.yml` (default `IMAGE`) and `tools/discover.sh`
(`IMAGE_REPO`), then push a `v*` tag: CI publishes the images under your account.

## Development

```bash
docker build --build-arg PG_MAJOR=17 -t odoo-backup-service:test .
PG_MAJOR=17 tests/smoke.sh odoo-backup-service:test   # needs Docker + unzip, cleans up after itself
shellcheck -x scripts/*.sh tests/*.sh tools/*.sh
```

CI (`.github/workflows/docker.yml`) runs shellcheck, checks the template and the stack
file, runs the smoke test, then publishes multi-arch (amd64, arm64) images for
PostgreSQL 14–18 to GHCR. Push a `v*` tag to publish the `pgNN` and `pgNN-x.y.z` tags.

## License

MIT
