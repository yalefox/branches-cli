#!/bin/bash
# =============================================================================
# Terrarium Git - Configure Traefik Routes via Mantrae
# =============================================================================
# Automatically sets up Traefik routes and DNS via Checkpoint/Mantrae API
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
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
else
    log_error ".env file not found. Run install script first."
    exit 1
fi

# Configuration
CHECKPOINT_URL="${CHECKPOINT_URL:-https://checkpoint.terrarium.network}"
MANTRAE_TOKEN="${MANTRAE_PROFILE_TOKEN:-}"
SERVER_IP="${SERVER_IP:-}"

if [[ -z "${MANTRAE_TOKEN}" ]]; then
    log_error "MANTRAE_PROFILE_TOKEN not set in .env"
    exit 1
fi

# Auto-detect server IP if not set
if [[ -z "${SERVER_IP}" ]]; then
    if [[ -f /proc/net/route ]]; then
        SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    else
        SERVER_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
    fi
fi

if [[ -z "${SERVER_IP}" ]]; then
    log_error "Could not detect SERVER_IP. Please set it in .env"
    exit 1
fi

log_info "Using server IP: ${SERVER_IP}"

# =============================================================================
# MANTRAE API FUNCTIONS
# =============================================================================

create_service() {
    local name="$1"
    local url="$2"
    
    log_info "Creating service: ${name} -> ${url}"
    
    curl -sf -X POST "${CHECKPOINT_URL}/api/config/services" \
        -H "Authorization: Bearer ${MANTRAE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${name}\",
            \"loadBalancer\": {
                \"servers\": [{\"url\": \"${url}\"}]
            }
        }" 2>/dev/null && log "Service created: ${name}" || log_warn "Service may already exist: ${name}"
}

create_router() {
    local name="$1"
    local rule="$2"
    local service="$3"
    local tls="${4:-true}"
    
    log_info "Creating router: ${name}"
    
    local tls_config=""
    if [[ "${tls}" == "true" ]]; then
        tls_config='"tls": {"certResolver": "letsencrypt"}'
    fi
    
    curl -sf -X POST "${CHECKPOINT_URL}/api/config/routers" \
        -H "Authorization: Bearer ${MANTRAE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${name}\",
            \"rule\": \"${rule}\",
            \"service\": \"${service}\",
            \"entryPoints\": [\"websecure\"],
            ${tls_config}
        }" 2>/dev/null && log "Router created: ${name}" || log_warn "Router may already exist: ${name}"
}

# =============================================================================
# CONFIGURE ROUTES
# =============================================================================

log_info "Configuring Traefik routes via Mantrae..."

# Gitea main service
create_service "terrarium-git-svc" "http://${SERVER_IP}:3000"
create_router "terrarium-git" "Host(\`${DOMAIN:-terrarium-git.terrarium.network}\`)" "terrarium-git-svc"

# MinIO console
create_service "terrarium-git-minio-svc" "http://${SERVER_IP}:9001"
create_router "terrarium-git-minio1" "Host(\`${MINIO_DOMAIN:-terrarium-git-minio1.terrarium.network}\`)" "terrarium-git-minio-svc"

echo ""
log "Traefik routes configured!"
echo ""
echo -e "${BLUE}Routes:${NC}"
echo -e "  ${GREEN}https://${DOMAIN:-terrarium-git.terrarium.network}${NC} -> http://${SERVER_IP}:3000"
echo -e "  ${GREEN}https://${MINIO_DOMAIN:-terrarium-git-minio1.terrarium.network}${NC} -> http://${SERVER_IP}:9001"
echo ""
echo -e "${YELLOW}Note: DNS records should be auto-configured if Mantrae has PowerDNS integration.${NC}"
echo -e "${YELLOW}If not, add A records pointing to checkpoint server IP.${NC}"
