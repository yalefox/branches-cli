# Terrarium Git

**Self-hosted Git server with CI/CD, MinIO LFS, OIDC, and multi-arch builds**

| Component | Version | Description |
|-----------|---------|-------------|
| Gitea | 1.23 | Git server with Actions |
| PostgreSQL | 17-alpine | Database |
| MinIO | latest | S3-compatible LFS storage |
| Nginx | alpine | Reverse proxy |
| Act Runners | latest | CI/CD build agents |
| Buildx | stable | Multi-arch builds |
| Watchtower | latest | Auto-updates (staging only) |

---

## Quick Start

### Staging (macOS/Dev)

```bash
git clone https://git.terrarium.network/yalefox/terrarium-git_official.git
cd terrarium-git_official
chmod +x 00-install-terrarium-git.sh
./00-install-terrarium-git.sh
```

### Production (Linux)

```bash
git clone https://git.terrarium.network/yalefox/terrarium-git_official.git
cd terrarium-git_official
chmod +x 01-install-production.sh
sudo ./01-install-production.sh
```

---

## Environment Files

| File | Purpose |
|------|---------|
| `.env.staging` | Local/dev deployments (macOS, Docker Desktop) |
| `.env.production` | Production Linux servers |
| `.env` | Active config (created from template) |
| `.password` | Admin password (auto-generated, idempotent) |
| `.minio-credentials` | MinIO credentials (auto-generated, idempotent) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    External Traffic                          │
│         https://terrarium-git.terrarium.network              │
│         https://terrarium-git-minio1.terrarium.network       │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│  Checkpoint (Traefik) - TLS Termination                      │
│  Managed via: https://checkpoint.terrarium.network           │
└──────────────────────────┬──────────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
      :3000           :9001           :2222
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│    Nginx     │  │    MinIO     │  │  Gitea SSH   │
│  (Reverse    │  │  (Console)   │  │  (Git Clone) │
│   Proxy)     │  │              │  │              │
└──────┬───────┘  └──────────────┘  └──────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────────┐
│  Gitea (Port 3000)                                           │
│  - Git repositories                                          │
│  - LFS → MinIO (S3)                                          │
│  - Actions/CI-CD                                             │
│  - OIDC (Pocket ID)                                          │
└──────────┬─────────────────────────────────┬────────────────┘
           │                                 │
           ▼                                 ▼
┌──────────────────────┐          ┌────────────────────────────┐
│  PostgreSQL 17       │          │  Act Runners (x2+)         │
│  - Metadata          │          │  - Docker-in-Docker        │
│  - Users, Issues     │          │  - SSH keys for cloning    │
└──────────────────────┘          │  - Multi-arch via Buildx   │
                                  └────────────────────────────┘
```

---

## Data Storage & Backups

### Storage Locations

| Data | Location | Purpose |
|------|----------|---------|
| Git repos | `/opt/terrarium-git/data/gitea` | Repository files |
| LFS objects | `/opt/terrarium-git/data/minio` | Large binary files |
| Database | `/opt/terrarium-git/data/postgres` | Metadata, users |
| SSH keys | `./ssh/` | Runner authentication |

### Backup Commands

```bash
# Quick backup (local)
./scripts/backup.sh

# rsync to remote server
rsync -av /opt/terrarium-git/data/ backup-server:/backups/terrarium-git/

# PostgreSQL dump only (small, fast)
docker exec terrarium-git-postgres pg_dump -U gitea gitea > backup.sql
```

### Recommended: Restic/Borg (TODO)

For production, configure Restic or Borg to external S3:

```bash
# Initialize
restic -r s3:s3.amazonaws.com/your-bucket/terrarium-git init

# Backup
restic -r s3:s3.amazonaws.com/your-bucket/terrarium-git backup \
  /opt/terrarium-git/data
```

---

## Traefik Routes (Mantrae/Checkpoint)

Mantrae manages Traefik routes at: **<https://checkpoint.terrarium.network>**

Profile Token: `b5pk6roume`

### Add Gitea Route

1. Login to Mantrae
2. Routers → Add Router:

| Field | Value |
|-------|-------|
| Name | `terrarium-git` |
| Rule | `Host(\`terrarium-git.terrarium.network\`)` |
| Service | `terrarium-git-svc` → `http://<server-ip>:3000` |
| Entrypoints | `websecure` |
| TLS | ✅ Enabled |

### Add MinIO Console Route

| Field | Value |
|-------|-------|
| Name | `terrarium-git-minio1` |
| Rule | `Host(\`terrarium-git-minio1.terrarium.network\`)` |
| Service | `terrarium-git-minio-svc` → `http://<server-ip>:9001` |
| Entrypoints | `websecure` |
| TLS | ✅ Enabled |

### DNS Records

| Type | Name | Value |
|------|------|-------|
| A | `terrarium-git.terrarium.network` | `<checkpoint-ip>` |
| A | `terrarium-git-minio1.terrarium.network` | `<checkpoint-ip>` |

---

## OIDC Configuration

### Gitea OIDC (Pocket ID)

| Setting | Value |
|---------|-------|
| Client ID | `3b5ec0af-31c0-4950-99e4-1627b7b7dd41` |
| Discovery URL | `https://auth.terrarium.network/.well-known/openid-configuration` |

### MinIO OIDC (svc-terrarium-git-lfs)

| Setting | Value |
|---------|-------|
| Client ID | `c2bb536c-cd99-4e6a-b165-6c2298028c1c` |
| Client Launch URL | `https://terrarium-git-minio1.terrarium.network` |
| Callback URL | `https://terrarium-git-minio1.terrarium.network/oauth_callback` |
| Logout URL | `https://terrarium-git-minio1.terrarium.network` |

---

## SSH Keys for Runners

Runners have SSH keys for cloning private repositories.

### Add Public Key to Gitea

1. Login as admin user
2. Settings → SSH/GPG Keys → Add Key
3. Paste contents of `./ssh/id_ed25519.pub`

### Generated Keys Location

```
./ssh/
├── id_ed25519        # Private key (mounted to runners)
├── id_ed25519.pub    # Public key (add to Gitea)
└── config            # SSH config (disables host checking)
```

---

## Scripts

| Script | Purpose |
|--------|---------|
| `00-install-terrarium-git.sh` | Staging installer (macOS/Linux) |
| `01-install-production.sh` | Production installer (Linux) |
| `scripts/setup-runners.sh <TOKEN>` | Configure CI/CD runners |
| `scripts/backup.sh` | Backup database + data |
| `scripts/update.sh` | Pull latest images, restart |

---

## Hardware Requirements

| Environment | Cores | RAM | Runners |
|-------------|-------|-----|---------|
| Minimum | 2 | 4GB | 1 |
| Staging | 4 | 8GB | 2 |
| Production | 4+ | 16GB | 5 |
| Heavy CI/CD | 8+ | 32GB | 8 |

---

## Management Commands

```bash
# Status
docker compose ps

# Logs
docker compose logs -f gitea
docker compose logs -f minio

# Restart
docker compose restart

# Update (staging)
./scripts/update.sh

# Stop
docker compose down

# Destroy (CAREFUL!)
./01-install-production.sh --destroy
```

---

## Troubleshooting

### Docker not running (macOS)

```bash
open -a Docker
```

### MinIO bucket not created

```bash
docker exec terrarium-git-minio mc mb local/terrarium-git-lfs-01
```

### LFS not working

Check Gitea → MinIO connection:

```bash
docker logs terrarium-git-server | grep -i lfs
docker logs terrarium-git-minio
```

### Runners not connecting

1. Verify token in `.env`
2. Restart: `docker compose restart runner1 runner2`
3. Check logs: `docker logs terrarium-git-runner-1`

---

## Version History

- **v0.3.0** - MinIO LFS, staging/production configs, SSH keys
  - Added MinIO for S3-compatible LFS storage
  - Separate staging and production environment files
  - SSH key generation for runners
  - Hardware/OS requirement checks
  - Full Mantrae/Traefik documentation

- **v0.2.0** - Documentation and Mantrae integration
  - README with architecture diagram
  - Traefik route configuration guide

- **v0.1.0** - Initial consolidated release
  - Docker Compose stack
  - PostgreSQL 17, Gitea 1.23
  - OIDC, AWS SES, Watchtower

---

## License

MIT - Terrarium Network
