#!/bin/bash
# =============================================================
# startup.sh — Executado automaticamente na criação da VM GCE
# Instala Docker, clona o repo e sobe o docker-compose.prod.yml
# =============================================================
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] [startup] $1" | tee -a /var/log/startup.log; }

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
# 2. Instalar Docker (repo oficial Docker)
# -------------------------------------------------------
log "Instalando Docker..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git

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
log "Docker instalado."

# -------------------------------------------------------
# 3. Autenticar Docker no Artifact Registry
# -------------------------------------------------------
log "Configurando autenticação no Artifact Registry..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
log "Auth configurada."

# -------------------------------------------------------
# 4. Clonar repositório
# -------------------------------------------------------
log "Clonando repositório..."
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$APP_DIR"
fi
log "Repositório pronto em $APP_DIR"

# -------------------------------------------------------
# 5. Escrever .env e aguardar imagens no Artifact Registry
# -------------------------------------------------------
cd "$APP_DIR"
echo "REGISTRY=$REGISTRY" > .env
log "Arquivo .env criado com REGISTRY=$REGISTRY"

log "Aguardando imagens no Artifact Registry (pode levar até 10 min)..."
for i in $(seq 1 30); do
  if docker pull "$REGISTRY/app1:latest" >/dev/null 2>&1 && \
     docker pull "$REGISTRY/app2:latest" >/dev/null 2>&1; then
    log "Imagens disponíveis! ($i tentativas)"
    break
  fi
  log "Tentativa $i/30 — imagens ainda não disponíveis, aguardando 20s..."
  sleep 20
  if [ "$i" -eq 30 ]; then
    log "AVISO: timeout aguardando imagens. O CI/CD fará o primeiro deploy."
    exit 0
  fi
done

# -------------------------------------------------------
# 6. Subir toda a stack
# -------------------------------------------------------
log "Subindo docker-compose.prod.yml..."
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d --remove-orphans
log "Stack iniciada!"

VM_IP=$(curl -sf "$META/instance/network-interfaces/0/access-configs/0/external-ip" -H "$HEADER" || echo "?")
log "============================================="
log "Deploy concluído! IP da VM: $VM_IP"
log "  App1:       http://$VM_IP/app1/text"
log "  App2:       http://$VM_IP/app2/text"
log "  Prometheus: http://$VM_IP:9090"
log "  Grafana:    http://$VM_IP:3000  (admin/admin)"
log "============================================="
