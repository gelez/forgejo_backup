#!/bin/bash

# Immediatelly exit on errors if working pipeline broken or not all vars initialized
set -euo pipefail

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
    echo "Error: expect 5 or 6 arguments"
    echo ""
    echo "Usage:"
    echo "  $(basename "$0") <forgejo_container_name> <backup_zip> <forgejo_data_dir> <postgres_data_dir> <forgejo_port> [forgejo_image_tag]"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") forgejo-test ~/backups/15-02-2026-forgejo.zip ~/containers/forgejo_data ~/containers/postgres_data 3001"
    echo "  $(basename "$0") forgejo-old  old-dump.zip               ~/test/forgejo      ~/test/postgres      3002   7.0"
    echo ""
    echo "forgejo_image_tag — optional, default 11"
    exit 1
fi

FORGEJO_NAME="$1"
BACKUP_ZIP="$2"
FORGEJO_DATA="$3"
PG_DATA="$4"
FORGEJO_PORT="$5"
FORGEJO_TAG="${6:-11}"

# Variables (set up your ones) if forgot - check app.ini from backup.zip
PG_PASS="POSTGRES_PASSWROD"
FORGEJO_DB_USER="DATABASE_USER"
FORGEJO_DB_PASS="DATABASE_PASSWORD"
FORGEJO_DB_NAME="DATABASE_NAME"
NETWORK="restore-net"
PG_CONTAINER="postgres-for-${FORGEJO_NAME}"
PG_HOST_PORT="5432"

# ──────────────────────────────────────────────────────────────────────────────
# Checkups
# ──────────────────────────────────────────────────────────────────────────────

if [ ! -f "$BACKUP_ZIP" ]; then
    echo "Error: ZIP-backup file not found → $BACKUP_ZIP"
    exit 1
fi

for name in "$FORGEJO_NAME" "$PG_CONTAINER"; do
    if docker ps -a -q -f name=^${name}$ | grep -q .; then
        echo "Error: Docker container with name '${name}' already exists. You may stop and delete it manually if you want by:"
        echo "  docker stop ${name} && docker rm ${name}"
        exit 1
    fi
done

for port in "$FORGEJO_PORT" "$PG_HOST_PORT"; do
    if docker ps --filter "publish=${port}" -q | grep -q .; then
        echo "Error: port ${port} is in use"
        exit 1
    fi
done

echo "=== Restore Forgejo ==="
echo "Forgejo docker container : ${FORGEJO_NAME}"
echo "Backup ZIP file          : ${BACKUP_ZIP}"
echo "Forgejo data folder      : ${FORGEJO_DATA}"
echo "Postgres data folder     : ${PG_DATA}"
echo "Forgejo port             : ${FORGEJO_PORT} → 3000"
echo "Postgres port            : ${PG_HOST_PORT} → 5432"
echo "Docker image             : codeberg.org/forgejo/forgejo:${FORGEJO_TAG}"

# ──────────────────────────────────────────────────────────────────────────────
# Preparation
# ──────────────────────────────────────────────────────────────────────────────

TEMP_DIR="./temp_restore_$(date +%s)"
mkdir -p "$TEMP_DIR" "$FORGEJO_DATA" "$PG_DATA"

echo "Extract ZIP archive ..."
unzip -o "$BACKUP_ZIP" -d "$TEMP_DIR"

mkdir -p "$FORGEJO_DATA/gitea/conf" "$FORGEJO_DATA/gitea/custom" "$FORGEJO_DATA/git/repositories"

# app.ini
APP_INI=""
if [ -f "$TEMP_DIR/app.ini" ]; then
    APP_INI="$TEMP_DIR/app.ini"
elif [ -f "$TEMP_DIR/custom/conf/app.ini" ]; then
    APP_INI="$TEMP_DIR/custom/conf/app.ini"
fi

if [ -n "$APP_INI" ]; then
    cp "$APP_INI" "$FORGEJO_DATA/gitea/conf/app.ini"
    # Change HOST to postgres container name
    sed -i 's/^\s*HOST\s*=.*/HOST = '"${PG_CONTAINER}"':5432/' "$FORGEJO_DATA/gitea/conf/app.ini" || true
    echo "app.ini copied and HOST changed to ${PG_CONTAINER}:5432"
else
    echo "WARNING: app.ini file not found in backup!"
fi

# custom, data, etc.
cp -r "$TEMP_DIR/custom/"* "$FORGEJO_DATA/gitea/custom/" 2>/dev/null || true
cp -r "$TEMP_DIR/data/"*   "$FORGEJO_DATA/"             2>/dev/null || true
cp -r "$TEMP_DIR/data/avatars/." "$FORGEJO_DATA/gitea/avatars/" 2>/dev/null || true


# Repos
mkdir -p "$FORGEJO_DATA/git/repositories"
cp -r "$TEMP_DIR/repos/"* "$FORGEJO_DATA/git/repositories/" 2>/dev/null || true
echo "Repositories copied"

chown -R 1000:1000 "$FORGEJO_DATA" 2>/dev/null || true


# ──────────────────────────────────────────────────────────────────────────────
# Start Postgres container
# ──────────────────────────────────────────────────────────────────────────────

docker network create "$NETWORK" 2>/dev/null || true

docker run -d --name "$PG_CONTAINER" \
  --network "$NETWORK" \
  -p "${PG_HOST_PORT}:5432" \
  -v "$PG_DATA:/var/lib/postgresql/data" \
  -e POSTGRES_PASSWORD="$PG_PASS" \
  postgres:latest

# It need to sleep well to make sure that database ready before we start forgejo
sleep 12

# Setup Database
docker exec "$PG_CONTAINER" psql -U postgres -c "CREATE USER ${FORGEJO_DB_USER} WITH PASSWORD '${FORGEJO_DB_PASS}' CREATEDB;" || true
docker exec "$PG_CONTAINER" psql -U postgres -c "CREATE DATABASE ${FORGEJO_DB_NAME} OWNER ${FORGEJO_DB_USER};" || true
docker exec "$PG_CONTAINER" psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${FORGEJO_DB_NAME} TO ${FORGEJO_DB_USER};" || true

# Import DUMP to database
DUMP_PATH="$TEMP_DIR/forgejo-db.sql"

if [ -f "$DUMP_PATH" ]; then
    docker cp "$DUMP_PATH" "$PG_CONTAINER:/tmp/dump.sql"
    docker exec -e PGPASSWORD="$FORGEJO_DB_PASS" "$PG_CONTAINER" \
      psql -U "${FORGEJO_DB_USER}" -d "${FORGEJO_DB_NAME}" -f /tmp/dump.sql
    echo "DB successfully restored from $DUMP_PATH"
else
    echo "WARNING: forgejo-db.sql file not found in backup ($TEMP_DIR)"
    echo "ERROR!!! DB not restored."
    exit 1;
fi

rm -rf "$TEMP_DIR"  # Cleanup temp dir

# ──────────────────────────────────────────────────────────────────────────────
# Run Forgejo docker container
# ──────────────────────────────────────────────────────────────────────────────

docker run -d --name "$FORGEJO_NAME" \
  --network "$NETWORK" \
  -p "${FORGEJO_PORT}:3000" \
  -v "$FORGEJO_DATA:/data" \
  --restart unless-stopped \
  codeberg.org/forgejo/forgejo:"${FORGEJO_TAG}"

# Waiting some time to make sure it starts
sleep 10

# Regenerate hooks
docker exec -u 1000 "$FORGEJO_NAME" forgejo admin regenerate hooks 2>/dev/null || \
  echo "regenerate hooks failed  — maybe try manually: docker exec -u 1000 ${FORGEJO_NAME} forgejo admin regenerate hooks"

echo ""
echo "Ready!"
echo "Forgejo → http://localhost:${FORGEJO_PORT}"
echo "Forgejo logs: docker logs -f ${FORGEJO_NAME}"
echo "Postgres logs: docker logs -f ${PG_CONTAINER}"

# How to REMOVE it:
#  docker stop ${FORGEJO_NAME} ${PG_CONTAINER}
#  docker rm   ${FORGEJO_NAME} ${PG_CONTAINER}
#  docker network rm ${NETWORK}  # if not necessary
#  rm -rf \"${FORGEJO_DATA}\" \"${PG_DATA}\"
