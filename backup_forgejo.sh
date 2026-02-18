#!/bin/bash

# Forgejo backup script
# Creates full dump using `forgejo dump`, copies to host, rotates old backups
#
# Usage:
#   ./backup-forgejo.sh [OPTIONS]
#
# Options:
#   --container NAME     Docker container name (default: forgejo_serv)
#   --backup-dir PATH    Host directory for backups (default: /home/gelez/backups)
#   --config-path PATH   Path to app.ini inside container (default: /data/gitea/conf/app.ini)
#   --user USER          User to run dump as (default: git)
#   --keep-days DAYS     Keep backups newer than N days (default: 7)
#   --monthly-keep       Keep all backups on 1st day of month (default: yes)
#   -h, --help           Show this help

# Immediatelly fall down with errors if typo in compents found or working pipeline broken or not all vars initialized
set -euo pipefail

# Default values
CONTAINER_NAME="forgejo_serv"
BACKUP_DIR="/home/gelez/backups"
CONFIG_PATH="/data/gitea/conf/app.ini"
DUMP_USER="git"
KEEP_DAYS=7
KEEP_MONTHLY=1

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --container) CONTAINER_NAME="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --config-path) CONFIG_PATH="$2"; shift 2 ;;
        --user) DUMP_USER="$2"; shift 2 ;;
        --keep-days) KEEP_DAYS="$2"; shift 2 ;;
        --monthly-keep) KEEP_MONTHLY=1; shift ;;
        -h|--help)
            grep '^#' "$0" | tail -n +2 | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Checkups
command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker ps -q -f name="^${CONTAINER_NAME}$" >/dev/null || { echo "Container ${CONTAINER_NAME} not running"; exit 1; }

# Creating local backup folder if not exists
mkdir -p "$BACKUP_DIR"

# Init local vars
NOW=$(date +"%d-%m-%Y")
TIMESTAMP=$(date +%s)
DUMP_FILE="forgejo-dump-${TIMESTAMP}.zip"
REMOTE_PATH="/data/backups/${DUMP_FILE}"

echo "=== Starting Forgejo backup ==="
echo "Container: ${CONTAINER_NAME}"
echo "Backup dir: ${BACKUP_DIR}"
echo "Target file: ${BACKUP_DIR}${NOW}-forgejo.zip"

# Creating backup folder in container if not exists
docker exec "${CONTAINER_NAME}" mkdir -p /data/backups
docker exec "${CONTAINER_NAME}" chown "${DUMP_USER}:${DUMP_USER}" /data/backups

# Dumb
echo "Running forgejo dump..."
docker exec -u "${DUMP_USER}" "${CONTAINER_NAME}" \
  forgejo dump \
    --config "${CONFIG_PATH}" \
    --tempdir /tmp \
    --file "${REMOTE_PATH}"

# Copy to host
echo "Copying dump to host..."
docker cp "${CONTAINER_NAME}:${REMOTE_PATH}" "${BACKUP_DIR}/${NOW}-forgejo.zip"

# Dumb remove from container
docker exec "${CONTAINER_NAME}" rm -f "${REMOTE_PATH}"

echo "Rotating old backups..."
find "$BACKUP_DIR" -type f -name "*-forgejo.zip" \
  ! -newermt "-${KEEP_DAYS} days" \
  $( [ "$KEEP_MONTHLY" = 1 ] && echo '! -regex ".*/.*-[0-9]{2}-01-forgejo\\.zip"' ) \
  -delete

echo "Done! Backup: ${BACKUP_DIR}/${NOW}-forgejo.zip"
