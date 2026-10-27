# Restore

A backup zip has the same layout as the zips made by Odoo's Database Manager
(`dump.sql` + `filestore/`), so both ways below work.

Always restore into a **new database name** first, check it, then switch.

## Get the zip out of the volume

```bash
# list
docker exec <backup-container> ls -lh /backups
# copy to the host
docker cp <backup-container>:/backups/<file>.zip .
```

In Portainer you can also browse and download from **Volumes > (backup volume) > Browse**.

## Option A: Odoo Database Manager

1. Temporarily set `list_db = True` in `odoo.conf` and restart Odoo.
2. Open `/web/database/manager` > **Restore Database**, upload the zip, choose a new name.
   - "This database was moved": keeps the database UUID (a real move of production).
   - "This database is a copy": new UUID (staging/test copies).
3. Set `list_db = False` again and restart.

Large zips may hit the reverse proxy upload limit (e.g. nginx `client_max_body_size`).
Option B has no such limit.

## Option B: manual (Docker)

```bash
NEWDB=mydb_restored
unzip <file>.zip -d restore/

# 1) database (as the Odoo DB user; --no-owner dumps load under any owner)
docker exec <db-container> createdb -U <odoo-user> "$NEWDB"
docker exec -i <db-container> psql -U <odoo-user> -d "$NEWDB" -v ON_ERROR_STOP=1 -q < restore/dump.sql

# 2) filestore: the folder name must equal the database name
docker cp restore/filestore <odoo-container>:/var/lib/odoo/filestore/"$NEWDB"
docker exec -u root <odoo-container> chown -R odoo:odoo /var/lib/odoo/filestore/"$NEWDB"
```

Then open Odoo with that database (`?db=mydb_restored` or `db_name` / `dbfilter`).

## Restoring production data into staging

Neutralize it first so the copy does not send emails, run payment providers or fetch
mail (Odoo 16+):

```bash
# docker exec skips the image entrypoint, so pass the DB connection explicitly
# if it is not in odoo.conf
docker exec <odoo-container> odoo neutralize -d "$NEWDB" \
  --db_host <db-host> --db_user <odoo-user> --db_password '<password>'
```

## Check a restore

```sql
-- every attachment the database expects must exist in the filestore
SELECT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL;
-- modules are there
SELECT name, state, latest_version FROM ir_module_module WHERE name = 'base';
```
