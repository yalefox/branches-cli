# Branches CLI

**Unified multi-service Git CLI for GitHub, Gitea, and GitLab.**

One command to rule them all – `branches` automatically detects which service your repo uses and executes the right CLI.

## Quick Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/yalefox/branches-cli/main/tools/branches/install-branches.sh | bash
```

This will:

1. Install Homebrew (if needed)
2. Install `git`, `gh`, `tea`, `glab`
3. Configure your global Git identity
4. Set up authentication for each service
5. Install `branches` to `~/.local/bin`
6. Run verification tests

After install, restart your terminal or run:

```bash
source ~/.zshrc
```

## Usage

```bash
branches clone <url>      # Clone repo (auto-detects service)
branches push             # Push to correct service
branches pull             # Pull from correct service
branches status           # Show auth status for all services
branches login <service>  # Re-authenticate (gh/tea/glab)
```

## Examples

```bash
# Clone from any service
branches clone https://github.com/user/repo.git
branches clone https://git.example.com/user/repo.git

# Push/pull (in any repo)
branches push
branches pull

# Check all authentications
branches status

# Re-login to a specific service
branches login gh
branches login tea
branches login glab
```

## Supported Services

| Service | CLI | Detection |
|---------|-----|-----------|
| GitHub | `gh` | `github.com` in URL |
| GitLab | `glab` | `gitlab.com` in URL or configured host |
| Gitea | `tea` | Any host configured via `tea login` |

## Manual Install

```bash
git clone https://github.com/yalefox/branches-cli.git
cd branches-cli/tools/branches
./install-branches.sh
```

## Testing

```bash
./tools/branches/test-branches.sh
```

## Requirements

- macOS (Linux support coming soon)
- Homebrew (auto-installed)

## License

MIT
