#!/bin/bash
# =============================================================================
# Terrarium Git - Update Script
# =============================================================================
# Pulls latest images and restarts containers with zero-downtime
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()       { echo -e "${GREEN}[OK]${NC} $1"; }
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

cd "${SCRIPT_DIR}"

# Determine compose command
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

log_info "Pulling latest images..."
${COMPOSE_CMD} pull

log_info "Updating containers with rolling restart..."
${COMPOSE_CMD} up -d --remove-orphans

log_info "Waiting for services to be healthy..."
sleep 10

# Check health
if docker inspect --format='{{.State.Health.Status}}' terrarium-git-server 2>/dev/null | grep -q "healthy"; then
    log "Gitea is healthy"
else
    log_warn "Gitea may still be starting..."
fi

echo ""
log "Update complete!"
echo ""
${COMPOSE_CMD} ps
