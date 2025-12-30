#!/bin/bash
# =============================================================================
# BRANCHES - Multi-Service Git CLI Installer
# =============================================================================
# Interactive wizard that installs prerequisites and configures the unified
# `branches` CLI for GitHub, Gitea, and GitLab on macOS.
#
# Usage: curl -fsSL <url>/install-branches.sh | bash
#    or: ./install-branches.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/branches"
SCRIPT_URL_BASE="https://raw.githubusercontent.com/yalefox/branches-cli/main/tools/branches"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
# Read input from terminal even if script is piped
read_input() {
    local prompt="$1"
    local variable_name="$2"
    local default_value="${3:-}"
    
    # Check if /dev/tty is available
    if [[ -e /dev/tty ]]; then
        read -p "$prompt" "$variable_name" < /dev/tty
    else
        read -p "$prompt" "$variable_name"
    fi
}

read_secret() {
    local prompt="$1"
    local variable_name="$2"
    
    if [[ -e /dev/tty ]]; then
        read -sp "$prompt" "$variable_name" < /dev/tty
        echo ""
    else
        read -sp "$prompt" "$variable_name"
        echo ""
    fi
}

# =============================================================================
# COLORS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# LOGGING
# =============================================================================
log()       { echo -e "${GREEN}✓${NC} $1"; }
log_info()  { echo -e "${BLUE}→${NC} $1"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_step()  { echo -e "\n${PURPLE}${BOLD}Step $1${NC}"; }

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}       ${BOLD}BRANCHES${NC} - Multi-Service Git CLI Setup           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}       GitHub • Gitea • GitLab in one command            ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# PREREQUISITES
# =============================================================================
install_homebrew() {
    if command -v brew &>/dev/null; then
        log "Homebrew already installed"
        return 0
    fi
    
    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add to PATH for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    
    log "Homebrew installed"
}

install_prerequisites() {
    log_step "1/5: Installing Prerequisites"
    
    install_homebrew
    
    log_info "Updating Homebrew..."
    brew update --quiet
    
    local packages=("git" "gh" "gitea" "glab" "jq")
    
    for pkg in "${packages[@]}"; do
        if brew list "$pkg" &>/dev/null; then
            log "$pkg already installed"
        else
            log_info "Installing $pkg..."
            brew install "$pkg" --quiet
            log "$pkg installed"
        fi
    done
}

# =============================================================================
# GIT CONFIGURATION
# =============================================================================
configure_git() {
    log_step "2/5: Git Identity Configuration"
    
    local current_name current_email
    current_name=$(git config --global user.name 2>/dev/null || echo "")
    current_email=$(git config --global user.email 2>/dev/null || echo "")
    
    if [[ -n "$current_name" && -n "$current_email" ]]; then
        echo -e "  Current identity: ${GREEN}${current_name}${NC} <${GREEN}${current_email}${NC}>"
        read_input "  Keep this identity? [Y/n]: " keep_identity
        if [[ "${keep_identity,,}" != "n" ]]; then
            log "Keeping existing Git identity"
            return 0
        fi
    fi
    
    echo ""
    read_input "  Enter your full name: " git_name
    read_input "  Enter your email: " git_email
    
    git config --global user.name "$git_name"
    git config --global user.email "$git_email"
    git config --global init.defaultBranch main
    git config --global push.default current
    git config --global pull.rebase false
    git config --global credential.helper osxkeychain
    
    log "Git configured: $git_name <$git_email>"
}

# =============================================================================
# SERVICE AUTHENTICATION
# =============================================================================
setup_github() {
    log_step "3/5: GitHub Authentication"
    
    if gh auth status &>/dev/null; then
        local gh_user
        gh_user=$(gh api user -q '.login' 2>/dev/null || echo "unknown")
        log "Already logged in to GitHub as ${GREEN}${gh_user}${NC}"
        return 0
    fi
    
    read_input "  Set up GitHub now? [Y/n]: " setup_gh
    if [[ "${setup_gh,,}" == "n" ]]; then
        log_warn "Skipping GitHub setup (run 'branches login gh' later)"
        return 0
    fi
    
    log_info "Opening browser for GitHub authentication..."
    gh auth login --web --git-protocol https
    log "GitHub authenticated"
}

setup_gitea() {
    log_step "4/5: Gitea Authentication"
    
    local existing_logins
    existing_logins=$(tea login list 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
    
    if [[ "$existing_logins" -gt 0 ]]; then
        echo -e "  Existing Gitea logins:"
        tea login list
        read_input "  Add another Gitea server? [y/N]: " add_gitea
        if [[ "${add_gitea,,}" != "y" ]]; then
            log "Keeping existing Gitea logins"
            return 0
        fi
    else
    read_input "  Set up a Gitea server now? [Y/n]: " setup_gitea
        if [[ "${setup_gitea,,}" == "n" ]]; then
            log_warn "Skipping Gitea setup (run 'branches login tea' later)"
            return 0
        fi
    fi
    
    echo ""
    read_input "  Gitea server URL (e.g., https://branches.terrarium.network): " gitea_url
    read_input "  Gitea server name (e.g., branches): " gitea_name
    
    echo -e "  ${YELLOW}Generate a token at: ${gitea_url}/user/settings/applications${NC}"
    read_secret "  Gitea API token: " gitea_token
    echo ""
    
    tea login add \
        --name "${gitea_name}" \
        --url "${gitea_url}" \
        --token "${gitea_token}" \
        --ssh-key ""
    
    log "Gitea server '${gitea_name}' added"
}

setup_gitlab() {
    log_step "5/5: GitLab Authentication (Optional)"
    
    if glab auth status &>/dev/null; then
        log "Already logged in to GitLab"
        return 0
    fi
    
    read_input "  Set up GitLab now? [y/N]: " setup_gl
    if [[ "${setup_gl,,}" != "y" ]]; then
        log_warn "Skipping GitLab setup (run 'branches login glab' later)"
        return 0
    fi
    
    log_info "Opening browser for GitLab authentication..."
    glab auth login
    log "GitLab authenticated"
}

# =============================================================================
# INSTALL BRANCHES CLI
# =============================================================================
install_branches_cli() {
    log_info "Installing branches CLI..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
    
    # Get the directory where this installer script is located
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Copy the branches script
    if [[ -f "${script_dir}/branches" ]]; then
        cp "${script_dir}/branches" "${INSTALL_DIR}/branches"
    else
        log_info "Downloading branches CLI from GitHub..."
        curl -fsSL "${SCRIPT_URL_BASE}/branches" -o "${INSTALL_DIR}/branches"
    fi
    
    chmod +x "${INSTALL_DIR}/branches"
    
    # Add to PATH if not already there
    local shell_rc=""
    if [[ -f "${HOME}/.zshrc" ]]; then
        shell_rc="${HOME}/.zshrc"
    elif [[ -f "${HOME}/.bashrc" ]]; then
        shell_rc="${HOME}/.bashrc"
    fi
    
    if [[ -n "$shell_rc" ]] && ! grep -q "${INSTALL_DIR}" "$shell_rc" 2>/dev/null; then
        echo "" >> "$shell_rc"
        echo "# Branches CLI" >> "$shell_rc"
        echo "export PATH=\"${INSTALL_DIR}:\$PATH\"" >> "$shell_rc"
        log_info "Added ${INSTALL_DIR} to PATH in ${shell_rc}"
    fi
    
    log "Branches CLI installed to ${INSTALL_DIR}/branches"
    
    # Run verification tests
    local test_script="${INSTALL_DIR}/test-branches.sh"
    
    if [[ -f "${script_dir}/test-branches.sh" ]]; then
        cp "${script_dir}/test-branches.sh" "$test_script"
    else
        log_info "Downloading verification tests..."
        curl -fsSL "${SCRIPT_URL_BASE}/test-branches.sh" -o "$test_script"
    fi
    
    if [[ -f "$test_script" ]]; then
        log_info "Running verification tests..."
        chmod +x "$test_script"
        "$test_script" "${INSTALL_DIR}/branches" || log_warn "Some tests failed - check output above"
    fi
}

# =============================================================================
# COMPLETION MESSAGE
# =============================================================================
show_completion() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}              ${BOLD}Setup Complete!${NC}                            ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Usage:${NC}"
    echo -e "  ${BOLD}branches clone${NC} <url>      Clone a repository"
    echo -e "  ${BOLD}branches push${NC}            Push to the correct service"
    echo -e "  ${BOLD}branches pull${NC}            Pull from the correct service"
    echo -e "  ${BOLD}branches status${NC}          Show auth status for all services"
    echo -e "  ${BOLD}branches login${NC} <service> Re-authenticate (gh/tea/glab)"
    echo ""
    echo -e "${YELLOW}Note:${NC} Restart your terminal or run:"
    echo -e "  ${BOLD}source ~/.zshrc${NC}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    show_banner
    
    # Check if running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This installer is for macOS only"
        log_info "Linux support coming soon"
        exit 1
    fi
    
    install_prerequisites
    configure_git
    setup_github
    setup_gitea
    setup_gitlab
    install_branches_cli
    show_completion
}

main "$@"
