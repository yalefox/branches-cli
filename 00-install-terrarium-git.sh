#!/bin/bash
# =============================================================================
# Terrarium Git - Installation Script
# =============================================================================
# Single-command deployment for Gitea with Actions, Buildx, and OIDC
# Domain: terrarium-git.terrarium.network
# =============================================================================
# Usage: ./00-install-terrarium-git.sh [OPTIONS]
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
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        return 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        
        # macOS-specific check
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_info "On macOS, please ensure Docker Desktop is running"
            log_info "Open Docker Desktop from Applications or run: open -a Docker"
        else
            log_info "Try: sudo systemctl start docker"
        fi
        return 1
    fi
    
    log "Docker is running"
    return 0
}

check_docker_compose() {
    # Check for docker compose (v2) or docker-compose (v1)
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
        log "Docker Compose v2 available"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
        log "Docker Compose v1 available"
    else
        log_error "Docker Compose is not installed"
        return 1
    fi
    return 0
}

detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
        log_info "Detected: macOS"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS_TYPE="linux"
        log_info "Detected: Linux"
    else
        OS_TYPE="unknown"
        log_warn "Unknown OS type: $OSTYPE"
    fi
}

generate_password() {
    # Generate a secure password
    openssl rand -base64 24 | tr -d '/+=' | head -c 24
}

install_root_ca() {
    log_step "Installing Terrarium Root CA"
    
    if [[ "${SKIP_CERTS:-false}" == "true" ]]; then
        log_warn "Skipping root CA installation (--skip-certs)"
        return 0
    fi
    
    # On macOS, check if the CA is already in the Keychain
    if [[ "$OS_TYPE" == "macos" ]]; then
        if security find-certificate -c "TerrariumOS Root CA" /Library/Keychains/System.keychain &>/dev/null || \
           security find-certificate -c "TerrariumOS Root CA" ~/Library/Keychains/login.keychain-db &>/dev/null; then
            log "Terrarium Root CA already installed in Keychain"
            return 0
        fi
        
        # CA not found - prompt user
        log_info "Terrarium Root CA not found in Keychain"
        echo -e "${YELLOW}Do you want to install the Root CA now?${NC}"
        echo -e "This will prompt for TouchID / Admin Password."
        read -p "Install CA? (y/N): " -r install_confirm
        
        if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
            log_info "Installing root CA from certs.terrarium.network..."
            if curl -fsSL -k https://certs.terrarium.network/install.sh | sudo bash; then
                log "Root CA installed successfully"
            else
                log_warn "Root CA installation failed"
            fi
        else
            log_warn "Skipping root CA installation. HTTPS may show certificate warnings."
            echo -e "To install manually later: ${CYAN}curl -fsSL -k https://certs.terrarium.network/install.sh | sudo bash${NC}"
        fi
        return 0
    fi
    
    # On Linux, we can install automatically
    log_info "Installing root CA from certs.terrarium.network..."
    
    if curl -fsSL -k https://certs.terrarium.network/install.sh | sudo bash; then
        log "Root CA installed successfully"
    else
        log_warn "Root CA installation failed - continuing anyway"
        log_info "You can install manually later: curl -fsSL -k https://certs.terrarium.network/install.sh | sudo bash"
    fi
}

# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================
setup_environment() {
    log_step "Setting Up Environment"
    
    cd "${SCRIPT_DIR}"
    
    # Check if .env exists
    if [[ -f .env ]]; then
        log ".env file exists"
        source .env
        
        # Validate required variables
        if [[ "${POSTGRES_PASSWORD:-GENERATE_ME_FIRST}" == "GENERATE_ME_FIRST" ]]; then
            log_info "Generating PostgreSQL password..."
            POSTGRES_PASSWORD=$(generate_password)
            sed -i.bak "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" .env
            rm -f .env.bak
            log "PostgreSQL password generated"
        fi
        
        # Check admin password - only generate if it's the placeholder AND no password file exists
        if [[ "${ADMIN_PASSWORD:-GENERATE_ME_FIRST}" == "GENERATE_ME_FIRST" ]]; then
            if [[ -f "${PASSWORD_FILE}" ]]; then
                ADMIN_PASSWORD=$(cat "${PASSWORD_FILE}")
                sed -i.bak "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASSWORD}/" .env
                rm -f .env.bak
                log "Admin password restored from previous install"
            else
                ADMIN_PASSWORD=$(generate_password)
                echo "${ADMIN_PASSWORD}" > "${PASSWORD_FILE}"
                chmod 600 "${PASSWORD_FILE}"
                sed -i.bak "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASSWORD}/" .env
                rm -f .env.bak
                log "Admin password generated and saved to ${PASSWORD_FILE}"
            fi
        fi
        
        # Generate MinIO credentials if needed
        if [[ "${MINIO_ROOT_USER:-GENERATE_ME_FIRST}" == "GENERATE_ME_FIRST" ]]; then
            MINIO_ROOT_USER="admin-$(openssl rand -hex 4)"
            MINIO_ROOT_PASSWORD=$(generate_password)
            sed -i.bak "s/MINIO_ROOT_USER=.*/MINIO_ROOT_USER=${MINIO_ROOT_USER}/" .env
            sed -i.bak "s/MINIO_ROOT_PASSWORD=.*/MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}/" .env
            rm -f .env.bak
            log "MinIO credentials generated"
        fi
    else
        log_info "Creating .env from template..."
        
        # Use staging template by default
        if [[ -f .env.staging ]]; then
            cp .env.staging .env
        elif [[ -f .env.example ]]; then
            cp .env.example .env
        else
            log_error "No .env template found!"
            exit 1
        fi
        
        # Generate passwords
        POSTGRES_PASSWORD=$(generate_password)
        ADMIN_PASSWORD=$(generate_password)
        MINIO_ROOT_USER="admin-$(openssl rand -hex 4)"
        MINIO_ROOT_PASSWORD=$(generate_password)
        
        # Save admin password for idempotency
        echo "${ADMIN_PASSWORD}" > "${PASSWORD_FILE}"
        chmod 600 "${PASSWORD_FILE}"
        
        # Update .env with all generated values
        sed -i.bak "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" .env
        sed -i.bak "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${ADMIN_PASSWORD}/" .env
        sed -i.bak "s/MINIO_ROOT_USER=.*/MINIO_ROOT_USER=${MINIO_ROOT_USER}/" .env
        sed -i.bak "s/MINIO_ROOT_PASSWORD=.*/MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}/" .env
        rm -f .env.bak
        
        log ".env created with generated passwords"
    fi
    
    # Re-source to get updated values
    source .env
}

# =============================================================================
# DOCKER DEPLOYMENT
# =============================================================================
deploy_containers() {
    log_step "Deploying Docker Containers"
    
    cd "${SCRIPT_DIR}"
    
    # Pull latest images
    log_info "Pulling Docker images..."
    ${COMPOSE_CMD} pull
    
    # Start PostgreSQL first
    log_info "Starting PostgreSQL..."
    ${COMPOSE_CMD} up -d postgres
    
    # Wait for PostgreSQL to be healthy
    log_info "Waiting for PostgreSQL to be ready..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if docker inspect --format='{{.State.Health.Status}}' terrarium-git-postgres 2>/dev/null | grep -q "healthy"; then
            log "PostgreSQL is healthy"
            break
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done
    echo ""
    
    if [[ $attempts -ge $max_attempts ]]; then
        log_error "PostgreSQL failed to become healthy"
        docker logs terrarium-git-postgres --tail 20
        exit 1
    fi
}

check_ports() {
    log_step "Checking Ports"
    
    local ports=("3000" "9000" "9001" "2222")
    local conflict=false
    
    for port in "${ports[@]}"; do
        if lsof -i ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
            # Port is in use - check who is using it
            local pid=$(lsof -i ":$port" -sTCP:LISTEN -t | head -n 1)
            local name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            
            # If it's docker, we can try to clean up silently first
            if [[ "$name" == *"com.docker"* ]] || [[ "$name" == *"docker"* ]]; then
                 # Find container ID using this port
                 local container_id=$(docker ps --format '{{.ID}}\t{{.Ports}}' | grep "$port->" | awk '{print $1}')
                 if [[ -n "$container_id" ]]; then
                     log_info "Freeing port $port (stopping container $container_id)..."
                     docker stop "$container_id" >/dev/null
                     docker rm "$container_id" >/dev/null
                     continue # Resolved, check next port
                 fi
            fi

            # If we couldn't resolve it, NOW we warn
            log_warn "Port $port is in use by $name (PID: $pid)"
            conflict=true
        fi
    done
    
    if [[ "$conflict" == "true" ]]; then
        log_error "Port conflicts detected. Please free up the ports listed above and try again."
        exit 1
    fi
    
    log "Ports are clear"
}

# =============================================================================
# DOCKER DEPLOYMENT
# =============================================================================
deploy_containers() {
    log_step "Deploying Docker Containers"
    
    cd "${SCRIPT_DIR}"
    
    # Check ports before starting
    check_ports
    
    # Pull latest images
    # Pull latest images
    log_info "Pulling Docker images..."
    ${COMPOSE_CMD} pull
    
    # Start PostgreSQL first
    log_info "Starting PostgreSQL..."
    ${COMPOSE_CMD} up -d postgres
    
    # Wait for PostgreSQL to be healthy
    log_info "Waiting for PostgreSQL to be ready..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if docker inspect --format='{{.State.Health.Status}}' terrarium-git-postgres 2>/dev/null | grep -q "healthy"; then
            log "PostgreSQL is healthy"
            break
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done
    echo ""
    
    if [[ $attempts -ge $max_attempts ]]; then
        log_error "PostgreSQL failed to become healthy"
        docker logs terrarium-git-postgres --tail 20
        exit 1
    fi
    
    # Start Gitea, Nginx, Buildx, Watchtower
    log_info "Starting Gitea and supporting services..."
    ${COMPOSE_CMD} up -d gitea nginx buildx watchtower
    
    # Wait for Gitea to be healthy
    log_info "Waiting for Gitea to be ready (this may take 1-2 minutes on first start)..."
    attempts=0
    max_attempts=60
    while [[ $attempts -lt $max_attempts ]]; do
        if docker inspect --format='{{.State.Health.Status}}' terrarium-git-server 2>/dev/null | grep -q "healthy"; then
            log "Gitea is healthy"
            break
        fi
        echo -n "."
        sleep 3
        ((attempts++))
    done
    echo ""
    
    if [[ $attempts -ge $max_attempts ]]; then
        log_error "Gitea failed to become healthy"
        docker logs terrarium-git-server --tail 30
        exit 1
    fi
}

# =============================================================================
# ADMIN USER CREATION
# =============================================================================
create_admin_user() {
    log_step "Creating Admin User"
    
    source "${SCRIPT_DIR}/.env"
    
    # Check if admin user already exists
    if docker exec terrarium-git-server gitea admin user list 2>/dev/null | grep -q "${ADMIN_USERNAME:-yalefox}"; then
        log "Admin user '${ADMIN_USERNAME:-yalefox}' already exists (idempotent)"
        return 0
    fi
    
    log_info "Creating admin user: ${ADMIN_USERNAME:-yalefox}"
    
    if docker exec --user 1000:1000 terrarium-git-server gitea admin user create \
        --username "${ADMIN_USERNAME:-yalefox}" \
        --password "${ADMIN_PASSWORD}" \
        --email "${ADMIN_EMAIL:-yale@terrarium.network}" \
        --admin \
        --must-change-password=false 2>&1; then
        log "Admin user created successfully"
    else
        log_warn "Admin user creation returned an error (may already exist)"
    fi
}

# =============================================================================
# OIDC CONFIGURATION
# =============================================================================
configure_oidc() {
    log_step "Configuring OIDC Authentication"
    
    source "${SCRIPT_DIR}/.env"
    
    if [[ "${OIDC_ENABLED:-true}" != "true" ]]; then
        log_info "OIDC is disabled in configuration"
        return 0
    fi
    
    # Check if OIDC auth source already exists
    if docker exec terrarium-git-server gitea admin auth list 2>/dev/null | grep -qi "pocket"; then
        log "OIDC auth source already configured (idempotent)"
        return 0
    fi
    
    log_info "Adding OIDC authentication source: ${OIDC_PROVIDER_NAME:-Pocket ID}"
    
    if docker exec --user 1000:1000 terrarium-git-server gitea admin auth add-oauth \
        --name "${OIDC_PROVIDER_NAME:-Pocket ID}" \
        --provider openidConnect \
        --key "${OIDC_CLIENT_ID}" \
        --secret "${OIDC_CLIENT_SECRET}" \
        --auto-discover-url "${OIDC_DISCOVERY_URL}" \
        --scopes "openid email profile" 2>&1; then
        log "OIDC authentication source added"
    else
        log_warn "OIDC configuration returned an error (may already exist)"
    fi
}

# =============================================================================
# DISPLAY RESULTS
# =============================================================================
display_results() {
    log_step "Installation Complete"
    
    source "${SCRIPT_DIR}/.env"
    
    local LOCAL_IP
    if [[ "$OS_TYPE" == "macos" ]]; then
        LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
    else
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    fi
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              TERRARIUM GIT - INSTALLATION COMPLETE               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Access:${NC}"
    echo -e "  Local:     ${GREEN}http://${LOCAL_IP}:3000${NC}"
    echo -e "  External:  ${GREEN}https://${DOMAIN}${NC}"
    echo ""
    echo -e "${CYAN}Admin Credentials:${NC}"
    echo -e "  Username:  ${GREEN}${ADMIN_USERNAME:-yalefox}${NC}"
    echo -e "  Email:     ${GREEN}${ADMIN_EMAIL:-yale@terrarium.network}${NC}"
    echo -e "  Password:  ${GREEN}${ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "${CYAN}SSH Clone:${NC}"
    echo -e "  ${YELLOW}ssh://git@${DOMAIN}:${SSH_PORT:-2222}/org/repo.git${NC}"
    echo ""
    echo -e "${CYAN}Container Registry (Zot):${NC}"
    echo -e "  ${GREEN}${CONTAINER_REGISTRY:-containers.terrarium.network}${NC}"
    echo ""
    echo -e "${CYAN}Features Enabled:${NC}"
    echo -e "  ${GREEN}✓${NC} Git LFS (5GB max upload)"
    echo -e "  ${GREEN}✓${NC} Actions/CI-CD"
    echo -e "  ${GREEN}✓${NC} Buildx (multi-arch)"
    echo -e "  ${GREEN}✓${NC} OIDC (Pocket ID)"
    echo -e "  ${GREEN}✓${NC} Watchtower (auto-updates)"
    echo -e "  ${GREEN}✓${NC} Push-to-create repos"
    echo ""
    
    # Check runner token status
    if [[ "${RUNNER_TOKEN:-CONFIGURE_AFTER_FIRST_START}" == "CONFIGURE_AFTER_FIRST_START" ]]; then
        echo -e "${YELLOW}⚠ RUNNERS NOT YET CONFIGURED${NC}"
        echo ""
        echo -e "  To enable CI/CD runners:"
        echo -e "  1. Go to ${GREEN}https://${DOMAIN}/admin/actions/runners${NC}"
        echo -e "  2. Click 'Create new Runner' and copy the token"
        echo -e "  3. Run: ${CYAN}./scripts/setup-runners.sh <TOKEN>${NC}"
        echo ""
    else
        echo -e "${GREEN}✓ Runners configured${NC}"
    fi
    
    echo -e "${CYAN}Management Commands:${NC}"
    echo -e "  Status:    ${YELLOW}${COMPOSE_CMD} ps${NC}"
    echo -e "  Logs:      ${YELLOW}${COMPOSE_CMD} logs -f gitea${NC}"
    echo -e "  Restart:   ${YELLOW}${COMPOSE_CMD} restart${NC}"
    echo -e "  Stop:      ${YELLOW}${COMPOSE_CMD} down${NC}"
    echo ""
    
    # Mark as installed
    date > "${INSTALL_MARKER}"
    
    echo -e "${GREEN}Password saved to: ${PASSWORD_FILE}${NC}"
    echo -e "${YELLOW}Keep this file safe! It won't be regenerated on re-runs.${NC}"
    echo ""
}

# =============================================================================
# DESTROY (cleanup)
# =============================================================================
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
    
    rm -f "${INSTALL_MARKER}" "${PASSWORD_FILE}" .env
    
    log "All containers and data removed"
    log_info "Run this script again for a fresh install"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    TERRARIUM GIT INSTALLER                       ║${NC}"
    echo -e "${GREEN}║              Gitea + Actions + Buildx + OIDC                     ║${NC}"
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
                echo "  --destroy       Remove all containers and volumes (DESTRUCTIVE)"
                exit 0
                ;;
            --check)
                CHECK_ONLY=true
                ;;
            --skip-certs)
                SKIP_CERTS=true
                ;;
            --destroy)
                detect_os
                check_docker_compose
                destroy_all
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done
    
    # Prerequisites
    log_step "Checking Prerequisites"
    detect_os
    check_docker || exit 1
    check_docker_compose || exit 1
    
    if [[ "${CHECK_ONLY:-false}" == "true" ]]; then
        log "All prerequisites satisfied!"
        exit 0
    fi
    
    # Installation steps
    install_root_ca
    setup_environment
    deploy_containers
    create_admin_user
    configure_oidc
    display_results
}

# Run main
main "$@"
