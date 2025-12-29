#!/bin/bash
# =============================================================================
# Terrarium Git - Runner Setup Script
# =============================================================================
# Configure and start Gitea Actions runners after getting token from web UI
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log()       { echo -e "${GREEN}[OK]${NC} $1"; }
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for token argument
if [[ -z "${1:-}" ]]; then
    echo -e "${YELLOW}Usage: $0 <RUNNER_TOKEN>${NC}"
    echo ""
    echo "To get the runner token:"
    echo "  1. Go to: https://terrarium-git.terrarium.network/admin/actions/runners"
    echo "  2. Click 'Create new Runner'"
    echo "  3. Copy the registration token"
    echo "  4. Run this script with the token"
    exit 1
fi

TOKEN="$1"

cd "${SCRIPT_DIR}"

# Check for .env
if [[ ! -f .env ]]; then
    log_error ".env file not found. Run 00-install-terrarium-git.sh first."
    exit 1
fi

# Update token in .env
log_info "Updating runner token in .env..."
if grep -q "^RUNNER_TOKEN=" .env; then
    sed -i.bak "s/^RUNNER_TOKEN=.*/RUNNER_TOKEN=${TOKEN}/" .env
    rm -f .env.bak
else
    echo "RUNNER_TOKEN=${TOKEN}" >> .env
fi
log "Runner token updated"

# Determine compose command
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Start runners
log_info "Starting runners..."
${COMPOSE_CMD} up -d runner1 runner2

# Wait and check status
sleep 5

echo ""
log "Runners started!"
echo ""
echo -e "${BLUE}Runner Status:${NC}"
${COMPOSE_CMD} ps runner1 runner2
echo ""
echo -e "Check runners at: ${GREEN}https://terrarium-git.terrarium.network/admin/actions/runners${NC}"
echo ""
