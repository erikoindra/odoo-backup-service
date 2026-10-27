# How it works

Notes on the design choices, so the image is easy to reason about (and to change).

## What one run does

```
lock ─► preflight ─► pg_dump ─► zip (dump.sql + filestore) ─► verify ─► publish ─► retention
```

1. **Lock** with `flock` on `BACKUP_DIR/.odoo-backup.lock`, so a manual run and the
   scheduled run can never overlap. Leftovers of a killed run (`.work-*`, `.*.partial`)
   are removed while holding the lock.
2. **Preflight**: `pg_isready`, a login check (`SHOW server_version_num`), a PostgreSQL
   version check, and free space ≥ `MIN_FREE_MB`.
3. **Pick databases**: `DB_NAME` if set, otherwise every database that also has a folder
   in `FILESTORE_ROOT` (Odoo names that folder after the database).
4. **Dump**: `pg_dump --no-owner --format=plain` → `dump.sql`, same flags Odoo uses for its
   own zip backups.
5. **Zip**: `filestore` is a symlink to `FILESTORE_ROOT/<db>`, and `zip` follows it, so the
   filestore is read straight from the read-only mount with no temporary copy.
6. **Verify**: `unzip -t` (CRC of every entry) and a layout check: the top level must be
   exactly `dump.sql` and `filestore/`.
7. **Publish**: the zip is written as `.<name>.zip.partial` and renamed only after it
   passed verification. A file with the final name is always complete.
8. **Retention**: delete this database's zips older than `RETENTION_DAYS` × 24 h. It runs
   only after a successful backup, so failures never leave you with zero backups.

## Why `pg_dump` and not a copy of the PostgreSQL volume

Copying `/var/lib/postgresql/data` while the server runs gives an inconsistent copy, and
the files only work with the exact same PostgreSQL major version. `pg_dump` runs inside
one transaction (a consistent snapshot, without blocking Odoo) and produces plain SQL
that loads into any server of the same major or newer.

## Why the database goes first

Odoo's filestore is content-addressed (`ab/abc123…`) and files are only deleted later by
the attachment garbage collector. So:

- dump first, filestore after: an attachment created in between leaves a file without a
  database row, which is harmless (garbage-collected later);
- filestore first, dump after: an attachment created in between leaves a database row
  pointing to a file that is not in the backup, which is broken after restore.

## Why the pg_dump major must match the server

- `pg_dump` older than the server refuses to run (`server version mismatch`).
- `pg_dump` newer than the server works, but its SQL can use settings the older server
  does not know (e.g. `SET transaction_timeout` from 17), so the dump may not load back.

Hence one image tag per major (`pg14` … `pg18`) and no `latest`. The script stops on
an older client and warns on a newer one.

## Safety of the container

- The Odoo data volume is mounted **read-only**.
- No `docker.sock`: the container can reach PostgreSQL over the Docker network and
  nothing else. Compare with host scripts that run `docker exec`, which need full
  Docker access.
- The DB user only needs to own the database (e.g. Odoo's own user); no superuser.
- `umask 077`: zips are readable by root only inside the volume.

## Cron inside a container

- `tini` is PID 1, so `docker stop` reaches `crond` and zombies get reaped.
- **Environment gotcha**: `crond` starts jobs with an almost empty environment, so a
  job would not see `PGHOST`, `PGPASSWORD`, … The entrypoint writes the needed variables
  to `/run/odoo-backup.env` (mode 600, single-quoted values) and the crontab line sources
  it before running `odoo-backup`.
- Job output is redirected to `/proc/1/fd/1` and `/proc/1/fd/2` (PID 1's stdout/stderr),
  which is what `docker logs` and Portainer's log view read.
- `TZ` + `tzdata` make `CRON_SCHEDULE` and file names use your local time.

## Known limits (next steps)

- Backups live on the same disk as the data. Copy them off the server (e.g. rclone to
  object storage) to survive a disk or server loss.
- No notification on failure yet; watch the container log or add a webhook.
- Zips are not encrypted.
