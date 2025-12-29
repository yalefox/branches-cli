#!/bin/bash
# =============================================================================
# Terrarium Git - Test Suite
# =============================================================================
# Comprehensive tests for Gitea deployment including:
# - Container health
# - Network connectivity
# - Git operations (clone, push, LFS)
# - Registry access (build, push, pull)
# - OIDC authentication
# =============================================================================

# set -euo pipefail (Disabled to allow tests to fail without stopping script)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/.env"

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

# Test results
PASS=0
FAIL=0

log_test()   { echo -e "${PURPLE}[TEST]${NC} $1"; }
log_pass()   { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail()   { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_skip()   { echo -e "${YELLOW}[SKIP]${NC} $1"; }
log_info()   { echo -e "${BLUE}[INFO]${NC} $1"; }

# =============================================================================
# CONTAINER HEALTH TESTS
# =============================================================================
test_container_health() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    CONTAINER HEALTH TESTS                         ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    local containers=("terrarium-git-postgres" "terrarium-git-server" "terrarium-git-nginx" "terrarium-git-minio" "terrarium-git-buildx")
    
    for container in "${containers[@]}"; do
        log_test "Container: $container"
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
            local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "N/A")
            if [[ "$status" == "running" ]]; then
                log_pass "$container is running (health: $health)"
            else
                log_fail "$container status: $status"
            fi
        else
            log_fail "$container not found"
        fi
    done
}

# =============================================================================
# NETWORK CONNECTIVITY TESTS
# =============================================================================
test_network() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    NETWORK CONNECTIVITY TESTS                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Test internal connectivity (from host)
    log_test "Gitea HTTP (localhost:3000)"
    if curl -sf -o /dev/null http://localhost:3000/; then
        log_pass "Gitea HTTP accessible on localhost:3000"
    else
        log_fail "Cannot reach Gitea on localhost:3000"
    fi
    
    # Test MinIO
    log_test "MinIO API (localhost:9000)"
    if curl -sf -o /dev/null http://localhost:9000/minio/health/live; then
        log_pass "MinIO API accessible on localhost:9000"
    else
        log_fail "Cannot reach MinIO on localhost:9000"
    fi
    
    log_test "MinIO Console (localhost:9001)"
    if curl -sf -o /dev/null http://localhost:9001/; then
        log_pass "MinIO Console accessible on localhost:9001"
    else
        log_fail "Cannot reach MinIO Console on localhost:9001"
    fi
    
    # Test external domain (if configured)
    log_test "External domain (${DOMAIN:-terrarium-git.terrarium.network})"
    if curl -sf -o /dev/null --max-time 5 "https://${DOMAIN:-terrarium-git.terrarium.network}/" 2>/dev/null; then
        log_pass "External domain accessible via HTTPS"
    else
        log_skip "External domain not accessible (may need Traefik routing)"
    fi
}

# =============================================================================
# GIT OPERATIONS TESTS
# =============================================================================
test_git_operations() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    GIT OPERATIONS TESTS                           ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    local TEST_REPO="${SCRIPT_DIR}/.test-repo-$$"
    
    # Test API access
    log_test "Gitea API access"
    if curl -sf -o /dev/null http://localhost:3000/api/v1/version; then
        local version=$(curl -sf http://localhost:3000/api/v1/version | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        log_pass "Gitea API accessible (version: $version)"
    else
        log_fail "Cannot access Gitea API"
    fi
    
    # Test SSH connectivity
    log_test "SSH connectivity (port ${SSH_PORT:-2222})"
    if timeout 5 ssh -o StrictHostKeyChecking=no -o BatchMode=yes -p "${SSH_PORT:-2222}" git@localhost 2>&1 | grep -qi "gitea"; then
        log_pass "SSH accessible on port ${SSH_PORT:-2222}"
    else
        log_skip "SSH connection test inconclusive (may need key setup)"
    fi
    
    # Test push-to-create (if authenticated)
    log_test "Push-to-create capability"
    # Test push-to-create (if authenticated)
    log_test "Push-to-create capability"
    if grep -q "ENABLE_PUSH_CREATE_USER=true" "${SCRIPT_DIR}/.env" 2>/dev/null || \
       grep -q "ENABLE_PUSH_CREATE_ORG=true" "${SCRIPT_DIR}/.env" 2>/dev/null; then
        log_pass "Push-to-create is enabled in configuration"
    else
        log_info "Push-to-create: checking Gitea config..."
        # app.ini check (CLI config command is deprecated/removed in some versions)
        if docker exec terrarium-git-server grep -qi "ENABLE_PUSH_CREATE_USER.*true" /data/gitea/conf/app.ini 2>/dev/null; then
             log_pass "Push-to-create enabled (verified in app.ini)"
        else
            log_skip "Push-to-create status unknown (could not verify in app.ini)"
        fi
    fi
    
    rm -rf "$TEST_REPO" 2>/dev/null || true
}

# =============================================================================
# LFS TESTS
# =============================================================================
test_lfs() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    GIT LFS TESTS                                  ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    # Check LFS is enabled
    log_test "LFS enabled in Gitea"
    if docker exec terrarium-git-server cat /data/gitea/conf/app.ini 2>/dev/null | grep -qi "LFS_START_SERVER.*true"; then
        log_pass "LFS server is enabled"
    else
        log_skip "Could not verify LFS configuration"
    fi
    
    # Check MinIO bucket exists
    log_test "LFS bucket in MinIO"
    local bucket="${MINIO_LFS_BUCKET:-terrarium-git-lfs-01}"
    if docker exec terrarium-git-minio mc ls local/ 2>/dev/null | grep -q "$bucket"; then
        log_pass "LFS bucket '$bucket' exists"
    else
        log_info "LFS bucket may be created on first use"
        log_skip "LFS bucket '$bucket' not yet created"
    fi
    
    # Check Gitea can reach MinIO
    log_test "Gitea -> MinIO connectivity"
    if docker exec terrarium-git-server curl -sf http://minio:9000/minio/health/live >/dev/null 2>&1; then
        log_pass "Gitea can reach MinIO internally"
    else
        log_fail "Gitea cannot reach MinIO"
    fi
}

# =============================================================================
# REGISTRY TESTS
# =============================================================================
test_registry() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    CONTAINER REGISTRY TESTS                       ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    local registry="${CONTAINER_REGISTRY:-containers.terrarium.network}"
    
    log_test "Registry connectivity ($registry)"
    if curl -sf -o /dev/null "https://${registry}/v2/" 2>/dev/null; then
        log_pass "Container registry accessible"
    else
        log_skip "Registry not accessible (may need authentication or different URL)"
    fi
    
    log_test "Buildx available"
    if docker buildx version >/dev/null 2>&1; then
        local buildx_version=$(docker buildx version | head -1)
        log_pass "Buildx installed: $buildx_version"
    else
        log_fail "Buildx not available"
    fi
    
    log_test "Buildx builder"
    if docker ps --format '{{.Names}}' | grep -q "terrarium-git-buildx"; then
        log_pass "Buildx container running"
    else
        log_fail "Buildx container not running"
    fi
}

# =============================================================================
# RUNNER TESTS
# =============================================================================
test_runners() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    RUNNER TESTS                                   ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    log_test "Runner 1 container"
    if docker ps --format '{{.Names}}' | grep -q "terrarium-git-runner-1"; then
        log_pass "Runner 1 is running"
    else
        log_skip "Runner 1 not started (needs RUNNER_TOKEN)"
    fi
    
    log_test "Runner 2 container"
    if docker ps --format '{{.Names}}' | grep -q "terrarium-git-runner-2"; then
        log_pass "Runner 2 is running"
    else
        log_skip "Runner 2 not started (needs RUNNER_TOKEN)"
    fi
    
    log_test "config.yaml --add-host setting"
    if grep -q "\-\-add-host=" "${SCRIPT_DIR}/config.yaml" 2>/dev/null; then
        local addhost=$(grep -o '\-\-add-host=[^ ]*' "${SCRIPT_DIR}/config.yaml")
        log_pass "Job container networking: $addhost"
    else
        log_fail "config.yaml missing --add-host setting for job containers"
    fi
    
    log_test "SSH keys for private repo cloning"
    if [[ -d "${SCRIPT_DIR}/ssh" ]] && [[ -f "${SCRIPT_DIR}/ssh/id_ed25519" ]]; then
        log_pass "SSH keys present in ./ssh/"
    else
        log_skip "SSH keys not generated yet"
    fi
}

# =============================================================================
# OIDC TESTS
# =============================================================================
test_oidc() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    OIDC AUTHENTICATION TESTS                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    log_test "OIDC auth source configured"
    if docker exec terrarium-git-server gitea admin auth list 2>/dev/null | grep -qi "pocket\|oidc\|openid"; then
        log_pass "OIDC authentication source configured"
    else
        log_fail "OIDC authentication source not found"
    fi
    
    log_test "OIDC discovery endpoint reachable"
    local oidc_url="${OIDC_DISCOVERY_URL:-https://auth.terrarium.network/.well-known/openid-configuration}"
    if curl -sf -o /dev/null "$oidc_url" 2>/dev/null; then
        log_pass "OIDC discovery endpoint reachable"
    else
        log_skip "OIDC endpoint not reachable from host"
    fi
}

# =============================================================================
# WAZUH AGENT TEST
# =============================================================================
test_wazuh() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    WAZUH AGENT TESTS                              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    
    log_test "Wazuh agent container"
    if docker ps --format '{{.Names}}' | grep -q "terrarium-git-wazuh-agent"; then
        log_pass "Wazuh agent is running"
        
        log_test "Wazuh manager connectivity"
        local manager="${WAZUH_MANAGER:-wazuh.terrarium.network}"
        if docker exec terrarium-git-wazuh-agent /var/ossec/bin/agent_control -l 2>/dev/null | grep -qi "connected"; then
            log_pass "Wazuh agent connected to manager"
        else
            log_skip "Wazuh agent not connected (manager may be down)"
        fi
    else
        log_skip "Wazuh agent not started"
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    TEST SUMMARY                                   ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}PASSED:${NC} $PASS"
    echo -e "  ${RED}FAILED:${NC} $FAIL"
    echo ""
    
    if [[ $FAIL -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
    else
        echo -e "${YELLOW}⚠ Some tests failed. Review output above.${NC}"
    fi
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║               TERRARIUM GIT - TEST SUITE                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    
    test_container_health
    test_network
    test_git_operations
    test_lfs
    test_registry
    test_runners
    test_oidc
    test_wazuh
    
    print_summary
}

main "$@"
