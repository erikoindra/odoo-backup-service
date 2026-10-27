# syntax=docker/dockerfile:1
# Pick the PostgreSQL client that matches your server's major version.
# Alpine release that ships each client: 14 -> 3.20, 15 -> 3.22, 16/17/18 -> 3.23
ARG ALPINE_VERSION=3.23
FROM alpine:${ALPINE_VERSION}

ARG PG_MAJOR=17
ARG VERSION=dev

LABEL org.opencontainers.image.title="odoo-backup-service" \
      org.opencontainers.image.description="Scheduled Odoo backup: dump.sql + filestore in one Odoo-compatible zip" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

RUN apk add --no-cache "postgresql${PG_MAJOR}-client" bash zip unzip tzdata tini \
 && pg_dump --version | grep -q " ${PG_MAJOR}\."

COPY --chmod=0755 scripts/odoo-backup.sh /usr/local/bin/odoo-backup
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/odoo-backup-entrypoint

ENV ODOO_BACKUP_VERSION="${VERSION}" \
    ODOO_BACKUP_PG_MAJOR="${PG_MAJOR}" \
    TZ=UTC \
    PGPORT=5432 \
    BACKUP_DIR=/backups \
    FILESTORE_ROOT=/odoo-data/filestore \
    RETENTION_DAYS=3 \
    CRON_SCHEDULE="0 2 * * *" \
    RUN_ON_START=false \
    MIN_FREE_MB=1024

RUN mkdir -p /backups /odoo-data
VOLUME ["/backups"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/odoo-backup-entrypoint"]
CMD ["cron"]
