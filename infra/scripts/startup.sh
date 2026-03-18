#!/bin/bash
# =============================================================
# startup.sh — Executado automaticamente na criação da VM GCE
# Instala Docker, clona o repo e sobe o docker-compose.prod.yml
# =============================================================
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] [startup] $1"; }

# -------------------------------------------------------
# 1. Ler variáveis do Metadata Server da GCP
# -------------------------------------------------------
META="http://metadata.google.internal/computeMetadata/v1"
HEADER="Metadata-Flavor: Google"

PROJECT_ID=$(curl -sf "$META/project/project-id"            -H "$HEADER")
REGION=$(curl -sf     "$META/instance/attributes/region"    -H "$HEADER" || echo "us-central1")
REPO_NAME=$(curl -sf  "$META/instance/attributes/repo_name" -H "$HEADER" || echo "devops-challenge")
REPO_URL=$(curl -sf   "$META/instance/attributes/repo_url"  -H "$HEADER" || echo "https://github.com/wilsongomes345/to-brasil.git")

REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME"
APP_DIR="/opt/app"

log "Projeto:  $PROJECT_ID"
log "Registry: $REGISTRY"
log "Repo:     $REPO_URL"

# -------------------------------------------------------
# 2. Instalar Docker e dependências (repo oficial Docker)
# -------------------------------------------------------
log "Instalando Docker (repo oficial)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git wget

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# -------------------------------------------------------
# 3. Autenticar Docker no Artifact Registry
# -------------------------------------------------------
log "Configurando auth no Artifact Registry..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

# -------------------------------------------------------
# 4. Clonar repositório
# -------------------------------------------------------
log "Clonando repositório..."
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull
else
  git clone "$REPO_URL" "$APP_DIR"
fi

# -------------------------------------------------------
# 5. Salvar .env e aguardar primeiro deploy do CI/CD
# -------------------------------------------------------
cd "$APP_DIR"
echo "REGISTRY=$REGISTRY" > .env

VM_IP=$(curl -sf "$META/instance/network-interfaces/0/access-configs/0/external-ip" -H "$HEADER" || echo "?")
log "VM pronta! IP: $VM_IP — aguardando primeiro deploy pelo CI/CD."
log "  Registry: $REGISTRY"
log "  App dir:  $APP_DIR"
