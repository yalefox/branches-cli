#!/bin/bash
# =============================================================================
# Terrarium Git - Backup Script
# =============================================================================
# Creates a backup of Gitea data and PostgreSQL database
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()       { echo -e "${GREEN}[OK]${NC} $1"; }
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }

# Create backup directory
mkdir -p "${BACKUP_DIR}"

log_info "Starting backup..."

# Determine compose command
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

cd "${SCRIPT_DIR}"

# Backup PostgreSQL
log_info "Backing up PostgreSQL database..."
docker exec terrarium-git-postgres pg_dump -U gitea gitea > "${BACKUP_DIR}/gitea_db_${TIMESTAMP}.sql"
log "Database backup: gitea_db_${TIMESTAMP}.sql"

# Backup Gitea data (using docker cp)
log_info "Backing up Gitea data..."
docker cp terrarium-git-server:/data "${BACKUP_DIR}/gitea_data_${TIMESTAMP}"
log "Data backup: gitea_data_${TIMESTAMP}/"

# Backup .env (excluding passwords - for structure reference)
cp "${SCRIPT_DIR}/.env" "${BACKUP_DIR}/env_${TIMESTAMP}.backup"
log "Env backup: env_${TIMESTAMP}.backup"

# Compress
log_info "Compressing backups..."
cd "${BACKUP_DIR}"
tar -czf "terrarium-git_backup_${TIMESTAMP}.tar.gz" \
    "gitea_db_${TIMESTAMP}.sql" \
    "gitea_data_${TIMESTAMP}" \
    "env_${TIMESTAMP}.backup"

# Cleanup uncompressed files
rm -rf "gitea_db_${TIMESTAMP}.sql" "gitea_data_${TIMESTAMP}" "env_${TIMESTAMP}.backup"

log "Backup complete: ${BACKUP_DIR}/terrarium-git_backup_${TIMESTAMP}.tar.gz"

# Show backup size
ls -lh "${BACKUP_DIR}/terrarium-git_backup_${TIMESTAMP}.tar.gz"
