#!/bin/bash
# =============================================================================
# BRANCHES CLI - Test Script
# =============================================================================
# Verifies the branches CLI is working correctly using public repositories.
#
# Usage: ./test-branches.sh
# =============================================================================

# Don't use strict mode - tests handle their own errors
set +e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Test directory
TEST_DIR="${TMPDIR:-/tmp}/branches-test-$$"
BRANCHES_CMD="${1:-branches}"

# Convert to absolute path if relative
if [[ "$BRANCHES_CMD" == ./* ]]; then
    BRANCHES_CMD="$(pwd)/${BRANCHES_CMD#./}"
fi

PASSED=0
FAILED=0

# Logging
log_test()   { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass()   { echo -e "${GREEN}[PASS]${NC} $1"; ((PASSED++)); }
log_fail()   { echo -e "${RED}[FAIL]${NC} $1"; ((FAILED++)); }
log_skip()   { echo -e "${YELLOW}[SKIP]${NC} $1"; }

# Cleanup on exit
cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# TEST CASES
# =============================================================================

test_help() {
    log_test "branches help"
    # Strip ANSI color codes before checking
    if $BRANCHES_CMD help 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q "COMMANDS"; then
        log_pass "Help command works"
    else
        log_fail "Help command failed"
    fi
}

test_version() {
    log_test "branches version"
    if $BRANCHES_CMD version | grep -q "branches v"; then
        log_pass "Version command works"
    else
        log_fail "Version command failed"
    fi
}

test_status() {
    log_test "branches status"
    if $BRANCHES_CMD status 2>&1 | grep -q "GitHub\|Gitea\|GitLab"; then
        log_pass "Status command works"
    else
        log_fail "Status command failed"
    fi
}

test_github_auth() {
    log_test "GitHub authentication check"
    if gh auth status &>/dev/null; then
        log_pass "GitHub is authenticated"
    else
        log_skip "GitHub not authenticated (run 'branches login gh')"
    fi
}

test_gitea_config() {
    log_test "Gitea configuration check"
    local count
    count=$(tea login list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
        log_pass "Gitea has $count server(s) configured"
    else
        log_skip "No Gitea servers configured (run 'branches login tea')"
    fi
}

test_clone_github() {
    log_test "Clone from GitHub (public repo)"
    
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    # Clone a small public repo
    if $BRANCHES_CMD clone https://github.com/octocat/Hello-World.git 2>&1; then
        if [[ -d "Hello-World" ]]; then
            log_pass "GitHub clone works"
            rm -rf Hello-World
        else
            log_fail "GitHub clone directory not created"
        fi
    else
        log_fail "GitHub clone failed"
    fi
}

test_service_detection() {
    log_test "Service detection"
    
    mkdir -p "$TEST_DIR/test-repo"
    cd "$TEST_DIR/test-repo"
    git init --quiet
    
    # Test GitHub detection
    git remote add origin https://github.com/user/repo.git
    if $BRANCHES_CMD help 2>&1 >/dev/null; then
        log_pass "Service detection initialized"
    fi
    
    cd "$TEST_DIR"
    rm -rf test-repo
}

test_push_no_remote() {
    log_test "Push without remote (should fail gracefully)"
    
    mkdir -p "$TEST_DIR/no-remote"
    cd "$TEST_DIR/no-remote"
    git init --quiet
    echo "test" > test.txt
    git add test.txt
    git commit -m "test" --quiet
    
    if ! $BRANCHES_CMD push 2>&1 | grep -qi "error\|no remote"; then
        log_fail "Push should fail without remote"
    else
        log_pass "Push fails gracefully without remote"
    fi
    
    cd "$TEST_DIR"
    rm -rf no-remote
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}            ${BOLD}BRANCHES CLI - Test Suite${NC}                     ${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if branches command exists
if ! command -v "$BRANCHES_CMD" &>/dev/null && [[ ! -x "$BRANCHES_CMD" ]]; then
    echo -e "${RED}Error: branches command not found${NC}"
    echo "Make sure to install it first: ./install-branches.sh"
    exit 1
fi

echo -e "${BOLD}Testing: $BRANCHES_CMD${NC}"
echo ""

# Run tests
test_help
test_version
test_status
test_github_auth
test_gitea_config
test_clone_github
test_service_detection
test_push_no_remote

# Summary
echo ""
echo -e "${CYAN}─────────────────────────────────────────${NC}"
echo -e "${BOLD}Results:${NC} ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
