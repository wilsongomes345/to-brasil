#!/bin/bash
# =============================================================
# deploy.sh — Build, push e deploy na GCP com um comando
#
# Uso:
#   ./deploy.sh
#
# Variáveis de ambiente (opcionais, sobrepõem os defaults):
#   PROJECT_ID   — ID do projeto GCP  (default: gcloud config get-value project)
#   REGION       — Região GCP         (default: us-central1)
#   ZONE         — Zona GCP           (default: us-central1-a)
#   REPO_NAME    — Nome do repo AR    (default: devops-challenge)
#   VM_NAME      — Nome da VM GCE     (default: devops-challenge-vm)
# =============================================================
set -euo pipefail

# ── Cores para output ──────────────────────────────────────────
GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[deploy]${NC} $1"; }
info() { echo -e "${YELLOW}[info]${NC}   $1"; }
err()  { echo -e "${RED}[error]${NC}  $1" >&2; exit 1; }

# ── Variáveis ──────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
REPO_NAME="${REPO_NAME:-devops-challenge}"
VM_NAME="${VM_NAME:-devops-challenge-vm}"
REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME"

# ── Validações ─────────────────────────────────────────────────
[[ -z "$PROJECT_ID" ]] && err "PROJECT_ID não definido. Execute: gcloud config set project <PROJECT_ID>"
command -v docker   &>/dev/null || err "Docker não encontrado. Instale em: https://docs.docker.com/get-docker/"
command -v gcloud   &>/dev/null || err "gcloud não encontrado. Instale em: https://cloud.google.com/sdk/docs/install"

# ── Resumo ─────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  DevOps Challenge — Deploy GCP"
echo "════════════════════════════════════════"
info "Projeto:  $PROJECT_ID"
info "Registry: $REGISTRY"
info "VM:       $VM_NAME ($ZONE)"
echo ""

# ── 1. Autenticar Docker no Artifact Registry ──────────────────
log "1/5 Configurando auth no Artifact Registry..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

# ── 2. Build e push — App 1 (Python/FastAPI) ──────────────────
log "2/5 Build + push App 1 (Python/FastAPI)..."
docker build -t "$REGISTRY/app1:latest" ./app1
docker push "$REGISTRY/app1:latest"

# ── 3. Build e push — App 2 (Node.js/Express) ─────────────────
log "3/5 Build + push App 2 (Node.js/Express)..."
docker build -t "$REGISTRY/app2:latest" ./app2
docker push "$REGISTRY/app2:latest"

log "Imagens enviadas para o Artifact Registry!"

# ── 4. Deploy na VM ────────────────────────────────────────────
log "4/5 Fazendo deploy na VM GCE..."
gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE" \
  --command="
    set -e
    cd /opt/app
    git pull
    export REGISTRY=$REGISTRY
    docker compose -f docker-compose.prod.yml pull
    docker compose -f docker-compose.prod.yml up -d --remove-orphans
    docker image prune -f
  "

# ── 5. Obter IP e exibir URLs ──────────────────────────────────
log "5/5 Obtendo IP externo da VM..."
VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

echo ""
echo "════════════════════════════════════════"
echo -e "  ${GREEN}Deploy concluído com sucesso!${NC}"
echo "════════════════════════════════════════"
echo ""
echo "  Endpoints:"
echo "  ├── App 1 (cache 10s)"
echo "  │   ├── http://$VM_IP/app1/text"
echo "  │   └── http://$VM_IP/app1/time"
echo "  ├── App 2 (cache 60s)"
echo "  │   ├── http://$VM_IP/app2/text"
echo "  │   └── http://$VM_IP/app2/time"
echo "  ├── Prometheus → http://$VM_IP:9090"
echo "  └── Grafana    → http://$VM_IP:3000  (admin/admin)"
echo ""
