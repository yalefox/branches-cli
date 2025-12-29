#!/bin/bash
# =============================================================================
# Terrarium Git - Production Installation Script
# =============================================================================
# Deploys Gitea with MinIO, OIDC, and CI/CD runners on Linux production servers
# 
# Usage: ./01-install-production.sh [OPTIONS]
#
# Options:
#   --help          Show this help message
#   --check         Check prerequisites only
#   --skip-certs    Skip root CA installation
#   --destroy       Remove all containers and volumes (DESTRUCTIVE)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="terrarium-git.terrarium.network"
INSTALL_MARKER="${SCRIPT_DIR}/.installed"
PASSWORD_FILE="${SCRIPT_DIR}/.password"
MINIO_CREDS_FILE="${SCRIPT_DIR}/.minio-credentials"
SSH_DIR="${SCRIPT_DIR}/ssh"
DATA_ROOT="/opt/terrarium-git/data"

# Minimum requirements
MIN_CORES=4
MIN_RAM_GB=4
RECOMMENDED_RAM_GB=8

# =============================================================================
# COLORS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
log()         { echo -e "${GREEN}[OK]${NC} $1"; }
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${PURPLE}=== $1 ===${NC}"; }

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
generate_password() {
    openssl rand -base64 24 | tr -d '/+=' | head -c 24
}

check_os() {
    log_step "Checking Operating System"
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_info "Detected: ${PRETTY_NAME:-$ID}"
        
        # Check for Ubuntu 24.04
        if [[ "${ID:-}" == "ubuntu" ]]; then
            VERSION_NUM=$(echo "${VERSION_ID:-0}" | cut -d. -f1)
            if [[ $VERSION_NUM -lt 22 ]]; then
                log_warn "Ubuntu ${VERSION_ID} detected. Recommended: Ubuntu 24.04 LTS"
            else
                log "Ubuntu ${VERSION_ID} - OK"
            fi
        fi
    else
        log_warn "Could not detect OS version"
    fi
}

check_hardware() {
    log_step "Checking Hardware Requirements"
    
    # Check CPU cores
    CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "unknown")
    if [[ "$CORES" != "unknown" ]]; then
        if [[ $CORES -lt $MIN_CORES ]]; then
            log_warn "CPU cores: ${CORES} (minimum: ${MIN_CORES})"
        else
            log "CPU cores: ${CORES} - OK"
        fi
    fi
    
    # Check RAM
    if [[ -f /proc/meminfo ]]; then
        RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        RAM_GB=$((RAM_KB / 1024 / 1024))
    elif command -v sysctl &>/dev/null; then
        RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
        RAM_GB=$((RAM_BYTES / 1024 / 1024 / 1024))
    else
        RAM_GB=0
    fi
    
    if [[ $RAM_GB -gt 0 ]]; then
        if [[ $RAM_GB -lt $MIN_RAM_GB ]]; then
            log_error "RAM: ${RAM_GB}GB (minimum: ${MIN_RAM_GB}GB)"
            log_error "Insufficient RAM. Please add more memory."
            exit 1
        elif [[ $RAM_GB -lt $RECOMMENDED_RAM_GB ]]; then
            log_warn "RAM: ${RAM_GB}GB (recommended: ${RECOMMENDED_RAM_GB}GB)"
            log_warn "Consider upgrading for better performance"
        else
            log "RAM: ${RAM_GB}GB - OK"
        fi
        
        # Recommend runner count based on RAM
        if [[ $RAM_GB -ge 32 ]]; then
            RECOMMENDED_RUNNERS=8
        elif [[ $RAM_GB -ge 16 ]]; then
            RECOMMENDED_RUNNERS=5
        elif [[ $RAM_GB -ge 8 ]]; then
            RECOMMENDED_RUNNERS=3
        else
            RECOMMENDED_RUNNERS=2
        fi
        log_info "Recommended runners for ${RAM_GB}GB RAM: ${RECOMMENDED_RUNNERS}"
    fi
}

check_docker() {
    log_step "Checking Docker"
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        log_info "Install with: curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        log_info "Start with: sudo systemctl start docker"
        exit 1
    fi
    
    log "Docker is running: $(docker --version | cut -d' ' -f3 | tr -d ',')"
}

check_docker_compose() {
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
        log "Docker Compose v2 available"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
        log "Docker Compose v1 available"
    else
        log_error "Docker Compose is not installed"
        exit 1
    fi
}

install_root_ca() {
    log_step "Installing Terrarium Root CA"
    
    if [[ "${SKIP_CERTS:-false}" == "true" ]]; then
        log_warn "Skipping root CA installation (--skip-certs)"
        return 0
    fi
    
    log_info "Installing root CA from certs.terrarium.network..."
    
    if curl -fsSL -k https://certs.terrarium.network/install.sh | sudo bash; then
        log "Root CA installed successfully"
    else
        log_warn "Root CA installation failed - continuing anyway"
    fi
}

create_data_directories() {
    log_step "Creating Data Directories"
    
    sudo mkdir -p "${DATA_ROOT}"/{postgres,gitea,minio}
    sudo chown -R "$(id -u):$(id -g)" "${DATA_ROOT}"
    chmod -R 755 "${DATA_ROOT}"
    
    log "Data directories created at ${DATA_ROOT}"
    log_info "For rsync backup: rsync -av ${DATA_ROOT}/ backup-server:/backups/"
}

generate_ssh_keys() {
    log_step "Generating SSH Keys for Runners"
    
    mkdir -p "${SSH_DIR}"
    
    if [[ -f "${SSH_DIR}/id_ed25519" ]]; then
        log "SSH keys already exist (idempotent)"
    else
        ssh-keygen -t ed25519 -f "${SSH_DIR}/id_ed25519" -N "" -C "terrarium-git-runner@$(hostname)"
        log "SSH keypair generated"
    fi
    
    # Create SSH config for runners
    cat > "${SSH_DIR}/config" << 'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    IdentityFile ~/.ssh/id_ed25519
EOF
    
    chmod 600 "${SSH_DIR}/id_ed25519"
    chmod 644 "${SSH_DIR}/id_ed25519.pub"
    chmod 644 "${SSH_DIR}/config"
    
    log_info "Add this public key to Gitea admin user's SSH keys:"
    echo ""
    cat "${SSH_DIR}/id_ed25519.pub"
    echo ""
}

setup_environment() {
    log_step "Setting Up Environment"
    
    cd "${SCRIPT_DIR}"
    
    # Use production config if .env doesn't exist
    if [[ ! -f .env ]]; then
        log_info "Creating .env from production template..."
        cp .env.production .env
    fi
    
    source .env
    
    # Generate PostgreSQL password if needed
    if [[ "${POSTGRES_PASSWORD:-GENERATE_ME_FIRST}" == "GENERATE_ME_FIRST" ]]; then
        log_info "Generating PostgreSQL password..."
        POSTGRES_PASSWORD=$(generate_password)
        sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" .env
        log "PostgreSQL password generated"
    fi
    
    # Generate admin password (idempotent)
    if [[ "${ADMIN_PASSWORD:-GENERATE_ME_FIRST}" == "GENERATE_ME_FIRST" ]]; then
        if [[ -f "${PASSWORD_FILE}" ]]; then
            ADMIN_PASSWORD=$(cat "${PASSWORD_FILE}")
            sed -i "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASSWORD}/" .env
            log "Admin password restored from previous install"
        else
            ADMIN_PASSWORD=$(generate_password)
            echo "${ADMIN_PASSWORD}" > "${PASSWORD_FILE}"
            chmod 600 "${PASSWORD_FILE}"
            sed -i "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASSWORD}/" .env
            log "Admin password generated and saved"
        fi
    fi
    
    # Generate MinIO credentials (idempotent)
    if [[ "${MINIO_ROOT_USER:-GENERATE_ME_FIRST}" == "GENERATE_ME_FIRST" ]]; then
        if [[ -f "${MINIO_CREDS_FILE}" ]]; then
            source "${MINIO_CREDS_FILE}"
            sed -i "s/MINIO_ROOT_USER=.*/MINIO_ROOT_USER=${MINIO_ROOT_USER}/" .env
            sed -i "s/MINIO_ROOT_PASSWORD=.*/MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}/" .env
            log "MinIO credentials restored from previous install"
        else
            MINIO_ROOT_USER="admin-$(openssl rand -hex 4)"
            MINIO_ROOT_PASSWORD=$(generate_password)
            cat > "${MINIO_CREDS_FILE}" << EOF
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
EOF
            chmod 600 "${MINIO_CREDS_FILE}"
            sed -i "s/MINIO_ROOT_USER=.*/MINIO_ROOT_USER=${MINIO_ROOT_USER}/" .env
            sed -i "s/MINIO_ROOT_PASSWORD=.*/MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}/" .env
            log "MinIO credentials generated and saved"
        fi
    fi
    
    # Update data paths for production
    sed -i "s|DATA_ROOT=.*|DATA_ROOT=${DATA_ROOT}|" .env
    sed -i "s|POSTGRES_DATA=.*|POSTGRES_DATA=${DATA_ROOT}/postgres|" .env
    sed -i "s|GITEA_DATA=.*|GITEA_DATA=${DATA_ROOT}/gitea|" .env
    sed -i "s|MINIO_DATA=.*|MINIO_DATA=${DATA_ROOT}/minio|" .env
    
    source .env
    log "Environment configured"
}

deploy_containers() {
    log_step "Deploying Docker Containers"
    
    cd "${SCRIPT_DIR}"
    
    log_info "Pulling Docker images..."
    ${COMPOSE_CMD} pull
    
    # Start PostgreSQL first
    log_info "Starting PostgreSQL..."
    ${COMPOSE_CMD} up -d postgres
    
    log_info "Waiting for PostgreSQL..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if docker inspect --format='{{.State.Health.Status}}' terrarium-git-postgres 2>/dev/null | grep -q "healthy"; then
            log "PostgreSQL is healthy"
            break
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done
    echo ""
    
    # Start MinIO
    log_info "Starting MinIO..."
    ${COMPOSE_CMD} up -d minio
    
    log_info "Waiting for MinIO..."
    attempts=0
    while [[ $attempts -lt 30 ]]; do
        if docker inspect --format='{{.State.Health.Status}}' terrarium-git-minio 2>/dev/null | grep -q "healthy"; then
            log "MinIO is healthy"
            break
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done
    echo ""
    
    # Create LFS bucket
    log_info "Creating LFS bucket..."
    source .env
    docker exec terrarium-git-minio mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" 2>/dev/null || true
    docker exec terrarium-git-minio mc mb local/"${MINIO_LFS_BUCKET:-terrarium-git-lfs-01}" 2>/dev/null || log_info "Bucket may already exist"
    
    # Start Gitea and other services
    log_info "Starting Gitea, Nginx, Buildx..."
    ${COMPOSE_CMD} up -d gitea nginx buildx
    
    log_info "Waiting for Gitea (this may take 1-2 minutes)..."
    attempts=0
    while [[ $attempts -lt 60 ]]; do
        if docker inspect --format='{{.State.Health.Status}}' terrarium-git-server 2>/dev/null | grep -q "healthy"; then
            log "Gitea is healthy"
            break
        fi
        echo -n "."
        sleep 3
        ((attempts++))
    done
    echo ""
    
    if [[ $attempts -ge 60 ]]; then
        log_error "Gitea failed to become healthy"
        docker logs terrarium-git-server --tail 30
        exit 1
    fi
}

create_admin_user() {
    log_step "Creating Admin User"
    
    source "${SCRIPT_DIR}/.env"
    
    if docker exec terrarium-git-server gitea admin user list 2>/dev/null | grep -q "${ADMIN_USERNAME:-yalefox}"; then
        log "Admin user '${ADMIN_USERNAME:-yalefox}' already exists (idempotent)"
        return 0
    fi
    
    log_info "Creating admin user: ${ADMIN_USERNAME:-yalefox}"
    
    docker exec --user 1000:1000 terrarium-git-server gitea admin user create \
        --username "${ADMIN_USERNAME:-yalefox}" \
        --password "${ADMIN_PASSWORD}" \
        --email "${ADMIN_EMAIL:-yale@terrarium.network}" \
        --admin \
        --must-change-password=false 2>&1 || log_warn "User may already exist"
    
    log "Admin user ready"
}

configure_oidc() {
    log_step "Configuring OIDC Authentication"
    
    source "${SCRIPT_DIR}/.env"
    
    if [[ "${OIDC_ENABLED:-true}" != "true" ]]; then
        log_info "OIDC is disabled"
        return 0
    fi
    
    if docker exec terrarium-git-server gitea admin auth list 2>/dev/null | grep -qi "pocket"; then
        log "OIDC already configured (idempotent)"
        return 0
    fi
    
    log_info "Adding OIDC authentication source..."
    
    docker exec --user 1000:1000 terrarium-git-server gitea admin auth add-oauth \
        --name "${OIDC_PROVIDER_NAME:-Pocket ID}" \
        --provider openidConnect \
        --key "${OIDC_CLIENT_ID}" \
        --secret "${OIDC_CLIENT_SECRET}" \
        --auto-discover-url "${OIDC_DISCOVERY_URL}" \
        --scopes "openid email profile" 2>&1 || log_warn "OIDC may already be configured"
    
    log "OIDC configured"
}

display_results() {
    log_step "Installation Complete"
    
    source "${SCRIPT_DIR}/.env"
    
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         TERRARIUM GIT - PRODUCTION INSTALLATION COMPLETE         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Access URLs:${NC}"
    echo -e "  Gitea:       ${GREEN}https://${DOMAIN}${NC}"
    echo -e "  MinIO:       ${GREEN}https://${MINIO_DOMAIN:-terrarium-git-minio1.terrarium.network}${NC}"
    echo -e "  Local:       ${GREEN}http://${LOCAL_IP}:3000${NC}"
    echo ""
    echo -e "${CYAN}Admin Credentials:${NC}"
    echo -e "  Username:    ${GREEN}${ADMIN_USERNAME:-yalefox}${NC}"
    echo -e "  Password:    ${GREEN}${ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "${CYAN}MinIO Credentials:${NC}"
    echo -e "  User:        ${GREEN}${MINIO_ROOT_USER}${NC}"
    echo -e "  Password:    ${GREEN}${MINIO_ROOT_PASSWORD}${NC}"
    echo -e "  OIDC:        ${GREEN}Login with Pocket ID (svc-terrarium-git-lfs)${NC}"
    echo ""
    echo -e "${CYAN}Data Location (for backups):${NC}"
    echo -e "  ${GREEN}${DATA_ROOT}${NC}"
    echo -e "  Backup: rsync -av ${DATA_ROOT}/ backup-server:/backups/"
    echo ""
    echo -e "${CYAN}SSH Public Key (add to Gitea admin):${NC}"
    cat "${SSH_DIR}/id_ed25519.pub"
    echo ""
    
    if [[ "${RUNNER_TOKEN:-CONFIGURE_AFTER_FIRST_START}" == "CONFIGURE_AFTER_FIRST_START" ]]; then
        echo -e "${YELLOW}⚠ RUNNERS NOT CONFIGURED${NC}"
        echo -e "  1. Go to: https://${DOMAIN}/admin/actions/runners"
        echo -e "  2. Create new Runner → copy token"
        echo -e "  3. Run: ./scripts/setup-runners.sh <TOKEN>"
        echo ""
    fi
    
    echo -e "${CYAN}Traefik Routes (add via Mantrae):${NC}"
    echo -e "  Gitea: Host(\`${DOMAIN}\`) → http://${LOCAL_IP}:3000"
    echo -e "  MinIO: Host(\`${MINIO_DOMAIN:-terrarium-git-minio1.terrarium.network}\`) → http://${LOCAL_IP}:9001"
    echo ""
    
    date > "${INSTALL_MARKER}"
    log "Installation complete!"
}

destroy_all() {
    log_step "DESTROYING ALL CONTAINERS AND DATA"
    
    echo -e "${RED}WARNING: This will remove all containers, volumes, and data!${NC}"
    read -p "Type 'DESTROY' to confirm: " -r confirm
    
    if [[ "$confirm" != "DESTROY" ]]; then
        log_info "Destruction cancelled"
        exit 0
    fi
    
    cd "${SCRIPT_DIR}"
    ${COMPOSE_CMD} down -v --remove-orphans 2>/dev/null || true
    
    sudo rm -rf "${DATA_ROOT}"
    rm -f "${INSTALL_MARKER}" "${PASSWORD_FILE}" "${MINIO_CREDS_FILE}" .env
    rm -rf "${SSH_DIR}"
    
    log "All containers and data removed"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            TERRARIUM GIT - PRODUCTION INSTALLER                  ║${NC}"
    echo -e "${GREEN}║        Gitea + MinIO + Actions + Buildx + OIDC                   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --help          Show this help message"
                echo "  --check         Check prerequisites only"
                echo "  --skip-certs    Skip root CA installation"
                echo "  --destroy       Remove all containers and volumes"
                exit 0
                ;;
            --check)
                CHECK_ONLY=true
                ;;
            --skip-certs)
                SKIP_CERTS=true
                ;;
            --destroy)
                check_docker_compose
                destroy_all
                exit 0
                ;;
        esac
        shift
    done
    
    check_os
    check_hardware
    check_docker
    check_docker_compose
    
    if [[ "${CHECK_ONLY:-false}" == "true" ]]; then
        log "All prerequisites satisfied!"
        exit 0
    fi
    
    install_root_ca
    create_data_directories
    generate_ssh_keys
    setup_environment
    deploy_containers
    create_admin_user
    configure_oidc
    display_results
}

main "$@"
