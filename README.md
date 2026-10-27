# odoo-docker-backup

Scheduled backups for Odoo running in Docker. Each run writes one zip per database,
in the same layout as Odoo's own Database Manager backups:

```
mydb_20261028_020000.zip
├── dump.sql      # pg_dump --no-owner, plain SQL
└── filestore/    # contents of /var/lib/odoo/filestore/mydb/
```

- Runs as its own small container (Alpine + `pg_dump` + BusyBox `crond`), next to your
  Odoo stack. No `docker.sock`, Odoo data mounted read-only.
- Everything is configured with environment variables: no server, stack or database
  names are baked in.
- Daily schedule, retention in days, run-now command, atomic writes, verified zips.

## Image tags

`pg_dump` must match your PostgreSQL **server major version**, so pick the tag by major:

| Server | Tag |
|---|---|
| PostgreSQL 14 | `ghcr.io/OWNER/odoo-docker-backup:pg14` |
| PostgreSQL 15 | `…:pg15` |
| PostgreSQL 16 | `…:pg16` |
| PostgreSQL 17 | `…:pg17` |
| PostgreSQL 18 | `…:pg18` |

Pinned versions: `pg17-1.2.3`, `pg17-1.2`. Builds of `main`: `pg17-edge`.
There is no `latest`. Check your server with `docker exec <db-container> postgres --version`.

## Quick start: Portainer stack

1. Find the three names the stack needs:
   ```bash
   docker inspect <odoo-container> --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'
   #   the volume mounted at /var/lib/odoo is ODOO_DATA_VOLUME
   docker inspect <db-container> --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}'
   #   a network listed here is DB_NETWORK; the DB container name is PGHOST
   ```
2. **Stacks > Add stack > Web editor**: paste [`examples/portainer-stack.yml`](examples/portainer-stack.yml).
3. **Environment variables**: fill them in (template: [`examples/stack.env.example`](examples/stack.env.example)).
4. **Deploy the stack**, then check its log:
   ```
   odoo-docker-backup v0.1.0: schedule '0 2 * * *' (TZ=Asia/Jakarta), retention 3 day(s), target /backups
   ```
5. Run a first backup by hand (below) and look at the zip.

## Run a backup now

```bash
docker exec <backup-container> odoo-backup
```

In Portainer: **Containers > (backup container) > Console > Connect**, then type `odoo-backup`.

One-shot without a stack (exits when done):

```bash
docker run --rm --network <DB_NETWORK> \
  -v <ODOO_DATA_VOLUME>:/odoo-data:ro -v "$PWD/backups:/backups" \
  -e PGHOST=<db-container> -e PGUSER=<odoo-user> -e PGPASSWORD='<password>' \
  ghcr.io/OWNER/odoo-docker-backup:pg17 backup
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PGHOST` | (required) | DB host: container name or alias on the shared network |
| `PGPORT` | `5432` | DB port |
| `PGUSER` | (required) | DB user. The Odoo user that owns the database is enough |
| `PGPASSWORD` | | DB password, or use `PGPASSWORD_FILE` |
| `PGPASSWORD_FILE` | | file holding the password (Docker secrets) |
| `DB_NAME` | empty | database(s) to back up, comma or space separated. Empty: every database that has a folder in `FILESTORE_ROOT` |
| `FILESTORE_ROOT` | `/odoo-data/filestore` | where the filestores are. Mount Odoo's data_dir volume at `/odoo-data` |
| `BACKUP_DIR` | `/backups` | where zips are written |
| `BACKUP_PREFIX` | empty | file name prefix, e.g. `prod_` → `prod_mydb_20261028_020000.zip` |
| `RETENTION_DAYS` | `3` | delete this database's zips older than N days after a successful run. `0` keeps everything |
| `CRON_SCHEDULE` | `0 2 * * *` | 5-field cron expression |
| `TZ` | `UTC` | time zone for the schedule and file names, e.g. `Asia/Jakarta` |
| `RUN_ON_START` | `false` | also run one backup when the container starts |
| `MIN_FREE_MB` | `1024` | refuse to start a backup with less free space in `BACKUP_DIR` |

Any other libpq variable (`PGSSLMODE`, …) is passed through to `pg_dump`.

Note for Portainer: a `$` inside a stack variable is treated as a variable reference by
Compose. Write it as `$$`, or use `PGPASSWORD_FILE`.

## Restore

See [docs/restore.md](docs/restore.md): Odoo Database Manager or plain `psql` + copy.

## How it works

See [docs/how-it-works.md](docs/how-it-works.md): run order, why the database is dumped
before the filestore, version matching, the cron environment gotcha.

## Development

```bash
docker build --build-arg PG_MAJOR=17 -t odoo-docker-backup:test .
PG_MAJOR=17 tests/smoke.sh odoo-docker-backup:test   # needs Docker; cleans up after itself
shellcheck scripts/*.sh tests/*.sh
```

CI (`.github/workflows/docker.yml`) runs shellcheck and the smoke test, then publishes
multi-arch (amd64, arm64) images for PostgreSQL 14–18 to GHCR. Push a `v*` tag to
publish the `pgNN` and `pgNN-x.y.z` tags.

## License

MIT
