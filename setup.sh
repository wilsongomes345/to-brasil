#!/usr/bin/env bash
# =============================================================
# setup.sh — Provisiona toda a infra GCP e faz o primeiro deploy
# Uso: bash setup.sh
# Requisito: credentials.json na mesma pasta
# =============================================================
set -euo pipefail

# ── PATH: ferramentas instaladas no Windows via Google SDK ────
export CLOUDSDK_PYTHON="/c/Program Files (x86)/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
GCLOUD_BIN="/c/Program Files (x86)/Google/Cloud SDK/google-cloud-sdk/bin"
WINGET_BIN="/c/Users/Wilson/AppData/Local/Microsoft/WinGet/Links"
export PATH="$PATH:$GCLOUD_BIN:$WINGET_BIN"

# ── Configurações ──────────────────────────────────────────────
CREDS="credentials.json"
REGION="us-central1"
ZONE="us-central1-a"
REPO="devops-challenge"
VM_NAME="devops-challenge-vm"
GITHUB_REPO="wilsongomes345/to-brasil"

# ── Cores ──────────────────────────────────────────────────────
G='\033[1;32m'; B='\033[1;34m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
ok()   { echo -e "${G}  ✔${N} $1"; }
step() { echo -e "\n${B}▶ $1${N}"; }
warn() { echo -e "${Y}  ! $1${N}"; }
die()  { echo -e "${R}  ✘ ERRO: $1${N}"; exit 1; }

# ── Banner ─────────────────────────────────────────────────────
echo -e "${B}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║    DevOps Challenge — Setup GCP/GCE      ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${N}"

# ── Pré-requisitos ─────────────────────────────────────────────
step "Verificando pré-requisitos..."
[[ -f "$CREDS" ]]            || die "$CREDS não encontrado na pasta atual"
command -v gcloud    &>/dev/null || die "gcloud não instalado"
command -v terraform &>/dev/null || die "terraform não instalado"
ok "Ferramentas OK"

# ── Extrai dados do credentials.json ──────────────────────────
PROJECT_ID=$(grep -o '"project_id": *"[^"]*"' "$CREDS" | grep -o '[^"]*"$' | tr -d '"')
SA_EMAIL=$(grep -o '"client_email": *"[^"]*"' "$CREDS"  | grep -o '[^"]*"$' | tr -d '"')
REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO"
TFSTATE_BUCKET="$PROJECT_ID-tfstate"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
printf  "  │  Projeto  : %-40s│\n" "$PROJECT_ID"
printf  "  │  Região   : %-40s│\n" "$REGION"
printf  "  │  VM       : %-40s│\n" "$VM_NAME"
printf  "  │  Registry : %-40s│\n" "$REGISTRY"
echo    "  └─────────────────────────────────────────────────────┘"
echo ""

# ── Protege credentials do git ─────────────────────────────────
grep -q "credentials.json" .gitignore 2>/dev/null || echo "credentials.json" >> .gitignore

# ── 1. Autenticação ────────────────────────────────────────────
step "1/4 — Autenticando no GCP..."
export GOOGLE_APPLICATION_CREDENTIALS="$(realpath "$CREDS")"
gcloud auth activate-service-account --key-file="$CREDS" --quiet
gcloud config set project "$PROJECT_ID" --quiet
ok "Autenticado como $SA_EMAIL"

# ── 2. Habilita APIs ──────────────────────────────────────────
step "2/4 — Habilitando APIs e provisionando infraestrutura..."
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  storage.googleapis.com \
  --project="$PROJECT_ID" --quiet
ok "APIs habilitadas"

# Cria o bucket de estado do Terraform (idempotente)
echo "  Criando bucket de estado: gs://$TFSTATE_BUCKET"
gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://$TFSTATE_BUCKET" 2>/dev/null \
  || true  # já existe? ok
gsutil versioning set on "gs://$TFSTATE_BUCKET" 2>/dev/null || true

# Terraform: init + apply
cd infra/terraform
cat > terraform.tfvars <<EOF
project_id   = "$PROJECT_ID"
region       = "$REGION"
zone         = "$ZONE"
repo_name    = "$REPO"
EOF

# Remove estado local stale (VM foi deletada, migra para GCS)
rm -rf .terraform terraform.tfstate terraform.tfstate.backup 2>/dev/null || true

echo "  Inicializando Terraform (backend GCS)..."
terraform init \
  -input=false \
  -migrate-state \
  -backend-config="bucket=$TFSTATE_BUCKET" \
  -backend-config="prefix=devops-challenge"

# Importa recursos que já existem na GCP (idempotente — falha silenciosa se não existir)
echo "  Importando recursos existentes..."
terraform import -input=false \
  google_artifact_registry_repository.docker_repo \
  "projects/$PROJECT_ID/locations/$REGION/repositories/$REPO" 2>/dev/null || true
terraform import -input=false \
  google_compute_firewall.allow_app \
  "projects/$PROJECT_ID/global/firewalls/devops-challenge-allow" 2>/dev/null || true
terraform import -input=false \
  "google_project_service.apis[\"compute.googleapis.com\"]" \
  "projects/$PROJECT_ID/compute.googleapis.com" 2>/dev/null || true
terraform import -input=false \
  "google_project_service.apis[\"artifactregistry.googleapis.com\"]" \
  "projects/$PROJECT_ID/artifactregistry.googleapis.com" 2>/dev/null || true
terraform import -input=false \
  "google_project_service.apis[\"cloudbuild.googleapis.com\"]" \
  "projects/$PROJECT_ID/cloudbuild.googleapis.com" 2>/dev/null || true

echo "  Aplicando infraestrutura..."
terraform apply -auto-approve -input=false
cd ../..

VM_IP=$(cd infra/terraform && terraform output -raw vm_ip 2>/dev/null || echo "")
ok "Infraestrutura pronta — VM IP: $VM_IP"

# ── 3. Build e push das imagens ────────────────────────────────
step "3/4 — Build e push das imagens (Cloud Build)..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

echo "  → App 1 (Python/FastAPI)..."
gcloud builds submit ./app1 --tag "$REGISTRY/app1:latest" --project "$PROJECT_ID" --quiet
ok "app1 enviada"

echo "  → App 2 (Node.js/Express)..."
gcloud builds submit ./app2 --tag "$REGISTRY/app2:latest" --project "$PROJECT_ID" --quiet
ok "app2 enviada"

# ── 4. Aguarda a stack subir na VM (via health check HTTP) ─────
step "4/4 — Aguardando stack inicializar na VM..."
warn "A VM instalará Docker e subirá os containers automaticamente (~8-10 min)"
echo -n "  Verificando "

for i in $(seq 1 40); do
  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "http://$VM_IP/health" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    echo " OK!"
    break
  fi
  printf "."
  sleep 15
  if [[ $i -eq 40 ]]; then
    echo ""
    warn "Timeout esperando a VM. A stack pode ainda estar iniciando."
    warn "Verifique: gcloud compute ssh $VM_NAME --zone=$ZONE --command='sudo journalctl -u google-startup-scripts -f'"
  fi
done

# ── GitHub Secrets (CI/CD automático) ─────────────────────────
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  gh secret set GCP_PROJECT_ID --body "$PROJECT_ID" --repo "$GITHUB_REPO"
  gh secret set GCP_CREDENTIALS < "$CREDS"           --repo "$GITHUB_REPO"
  ok "Secrets configurados — CI/CD ativo no próximo push!"
else
  warn "Configure manualmente em: https://github.com/$GITHUB_REPO/settings/secrets/actions"
  warn "  GCP_PROJECT_ID  → $PROJECT_ID"
  warn "  GCP_CREDENTIALS → conteúdo completo do arquivo credentials.json"
fi

# ── URLs finais ───────────────────────────────────────────────
echo ""
echo -e "${G}"
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║              ✔  Deploy concluído com sucesso!             ║"
echo "  ╠═══════════════════════════════════════════════════════════╣"
printf "  ║  App 1 texto   (cache 10s) → http://%-22s║\n" "$VM_IP/app1/text"
printf "  ║  App 1 horário (cache 10s) → http://%-22s║\n" "$VM_IP/app1/time"
printf "  ║  App 2 texto   (cache 60s) → http://%-22s║\n" "$VM_IP/app2/text"
printf "  ║  App 2 horário (cache 60s) → http://%-22s║\n" "$VM_IP/app2/time"
echo  "  ╠═══════════════════════════════════════════════════════════╣"
printf "  ║  Prometheus → http://%-39s║\n" "$VM_IP:9090"
printf "  ║  Grafana    → http://%-39s║\n" "$VM_IP:3000  (admin/admin)"
echo  "  ╚═══════════════════════════════════════════════════════════╝"
echo -e "${N}"
