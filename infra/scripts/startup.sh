#!/bin/bash
set -euo pipefail

log() { echo "[startup] $1" | tee -a /var/log/startup.log; }

META="http://metadata.google.internal/computeMetadata/v1"
H="Metadata-Flavor: Google"

PROJECT_ID=$(curl -sf "$META/project/project-id" -H "$H")
REGION=$(curl -sf     "$META/instance/attributes/region"    -H "$H" || echo "us-central1")
REPO_NAME=$(curl -sf  "$META/instance/attributes/repo_name" -H "$H" || echo "devops-challenge")
REPO_URL=$(curl -sf   "$META/instance/attributes/repo_url"  -H "$H")
REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME"

log "Instalando Docker..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker && systemctl start docker
log "Docker instalado."

log "Configurando Artifact Registry..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

log "Clonando repositório..."
git clone "$REPO_URL" /opt/app

echo "REGISTRY=$REGISTRY" > /opt/app/.env

log "Aguardando imagens no Artifact Registry..."
for i in $(seq 1 30); do
  if docker pull "$REGISTRY/app1:latest" >/dev/null 2>&1 && \
     docker pull "$REGISTRY/app2:latest" >/dev/null 2>&1; then
    log "Imagens disponíveis!"
    break
  fi
  log "Tentativa $i/30 — aguardando 20s..."
  sleep 20
done

log "Subindo stack..."
cd /opt/app
docker compose pull
docker compose up -d --remove-orphans
log "Deploy concluído! IP: $(curl -sf "$META/instance/network-interfaces/0/access-configs/0/external-ip" -H "$H")"
