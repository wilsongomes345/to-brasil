#!/usr/bin/env bash
# =============================================================
# setup.sh — Sobe toda a infraestrutura GCP/GKE com 1 comando
# Uso: bash setup.sh
# =============================================================
set -euo pipefail

# ── PATH: adiciona ferramentas instaladas via winget/Google SDK ─
# gcloud precisa do Python bundled (resolve conflito com Windows Store)
export CLOUDSDK_PYTHON="/c/Program Files (x86)/Google/Cloud SDK/google-cloud-sdk/platform/bundledpython/python.exe"
GCLOUD_BIN="/c/Program Files (x86)/Google/Cloud SDK/google-cloud-sdk/bin"
WINGET_BIN="/c/Users/Wilson/AppData/Local/Microsoft/WinGet/Links"
DOCKER_BIN="/c/Program Files/Docker/Docker/resources/bin"
export PATH="$PATH:$GCLOUD_BIN:$WINGET_BIN:$DOCKER_BIN"

# ── Configurações ─────────────────────────────────────────────
CREDS="credentials.json"
REGION="us-central1"
CLUSTER="devops-challenge-cluster"
NAMESPACE="devops-challenge"
REPO="devops-challenge"
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
echo "  ║    DevOps Challenge — Setup GCP/GKE      ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${N}"

# ── Pré-requisitos ─────────────────────────────────────────────
step "Verificando pré-requisitos..."
[[ -f "$CREDS" ]]            || die "$CREDS não encontrado na pasta atual"
command -v gcloud    &>/dev/null || die "gcloud não instalado"
command -v terraform &>/dev/null || die "terraform não instalado"
command -v kubectl   &>/dev/null || die "kubectl não instalado"
ok "Todas as ferramentas disponíveis"

# ── Extrai dados do credentials.json ──────────────────────────
PROJECT_ID=$(grep -o '"project_id": *"[^"]*"' "$CREDS" | grep -o '[^"]*"$' | tr -d '"')
SA_EMAIL=$(grep -o '"client_email": *"[^"]*"' "$CREDS"  | grep -o '[^"]*"$' | tr -d '"')
REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
printf  "  │  Projeto  : %-40s│\n" "$PROJECT_ID"
printf  "  │  Região   : %-40s│\n" "$REGION"
printf  "  │  Cluster  : %-40s│\n" "$CLUSTER"
printf  "  │  Registry : %-40s│\n" "$REGISTRY"
printf  "  │  SA       : %-40s│\n" "$SA_EMAIL"
echo    "  └─────────────────────────────────────────────────────┘"
echo ""

# ── 1. Autenticação GCP ───────────────────────────────────────
step "1/6 — Autenticando no GCP..."
export GOOGLE_APPLICATION_CREDENTIALS="$(realpath "$CREDS")"
gcloud auth activate-service-account --key-file="$CREDS" --quiet
gcloud config set project "$PROJECT_ID" --quiet
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
ok "Autenticado como $SA_EMAIL"

# ── 2a. Habilita APIs necessárias via gcloud ──────────────────
step "2/6 — Habilitando APIs do GCP (necessário para o Terraform)..."
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  --project="$PROJECT_ID" --quiet
ok "APIs habilitadas"

# ── 2b. Terraform — GKE + Artifact Registry ───────────────────
step "  Provisionando infraestrutura (GKE Autopilot + Artifact Registry)..."
cd infra/terraform

cat > terraform.tfvars << EOF
project_id   = "$PROJECT_ID"
region       = "$REGION"
cluster_name = "$CLUSTER"
repo_name    = "$REPO"
EOF

terraform init   -upgrade -input=false -no-color 2>&1 | grep -E "Terraform|provider|Initialized"
terraform apply  -auto-approve -input=false -no-color 2>&1 | grep -E "Apply|created|cluster|registry|error" || true
cd ../..
ok "Cluster GKE e Artifact Registry prontos"

# ── 3. Instala gke-gcloud-auth-plugin e configura kubectl ─────
step "3/6 — Configurando kubectl para o cluster GKE..."

# Plugin obrigatório para autenticação kubectl ↔ GKE
gcloud components install gke-gcloud-auth-plugin --quiet 2>/dev/null || true
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# Aguarda cluster ficar RUNNING antes de pegar credenciais
echo -n "  Aguardando cluster ficar RUNNING"
for i in {1..30}; do
  STATUS=$(gcloud container clusters describe "$CLUSTER" \
    --region "$REGION" --project "$PROJECT_ID" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")
  [[ "$STATUS" == "RUNNING" ]] && echo " OK!" && break
  printf "."
  sleep 15
  [[ $i -eq 30 ]] && echo "" && die "Cluster não ficou RUNNING em tempo hábil."
done

gcloud container clusters get-credentials "$CLUSTER" \
  --region "$REGION" --project "$PROJECT_ID"
ok "kubectl apontando para $CLUSTER"

# ── 4. Build e push via Cloud Build (sem Docker local) ────────
step "4/6 — Build e push das imagens via Google Cloud Build..."
# Cloud Build roda na GCP — não precisa de Docker instalado localmente

echo "  → Cloud Build: App 1 (Python/FastAPI)..."
gcloud builds submit ./app1 \
  --tag "$REGISTRY/app1:latest" \
  --project "$PROJECT_ID" \
  --quiet
ok "app1 enviada para $REGISTRY/app1:latest"

echo "  → Cloud Build: App 2 (Node.js/Express)..."
gcloud builds submit ./app2 \
  --tag "$REGISTRY/app2:latest" \
  --project "$PROJECT_ID" \
  --quiet
ok "app2 enviada para $REGISTRY/app2:latest"

# ── 5. Deploy no GKE ─────────────────────────────────────────
step "5/6 — Aplicando manifests no Kubernetes..."

# Namespace e ConfigMaps primeiro
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/nginx/

# Apps: injeta a URL real do registry sem modificar os arquivos fonte
sed "s|us-central1-docker.pkg.dev/PROJECT_ID/devops-challenge|$REGISTRY|g" \
  k8s/app1/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/app1/service.yaml
kubectl apply -f k8s/app1/hpa.yaml

sed "s|us-central1-docker.pkg.dev/PROJECT_ID/devops-challenge|$REGISTRY|g" \
  k8s/app2/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/app2/service.yaml
kubectl apply -f k8s/app2/hpa.yaml

# Observabilidade
kubectl apply -f k8s/observability/prometheus/
kubectl apply -f k8s/observability/grafana/
ok "Todos os manifests aplicados"

# Aguarda pods
echo "  → Aguardando rollout dos pods..."
kubectl rollout status deployment/app1  -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/app2  -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/nginx -n "$NAMESPACE" --timeout=180s
ok "Todos os pods estão rodando"

# ── 6. GitHub Secrets (CI/CD automático) ─────────────────────
step "6/6 — Configurando GitHub Secrets para CI/CD..."
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  gh secret set GCP_PROJECT_ID --body "$PROJECT_ID"   --repo "$GITHUB_REPO"
  gh secret set GCP_CREDENTIALS < "$CREDS"             --repo "$GITHUB_REPO"
  ok "Secrets GCP_PROJECT_ID e GCP_CREDENTIALS configurados no GitHub"
else
  warn "Configure manualmente em: https://github.com/$GITHUB_REPO/settings/secrets/actions"
  warn "  GCP_PROJECT_ID  → $PROJECT_ID"
  warn "  GCP_CREDENTIALS → conteúdo completo do credentials.json"
fi

# ── URLs finais ───────────────────────────────────────────────
echo ""
echo -e "  ${B}Aguardando IP externo do LoadBalancer...${N}"
NGINX_IP=""
for i in {1..24}; do
  NGINX_IP=$(kubectl get svc nginx -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -n "$NGINX_IP" ]] && break
  printf "  aguardando... (%d/24)\r" "$i"
  sleep 10
done

PROM_IP=$(kubectl get svc prometheus -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pendente")
GRAF_IP=$(kubectl get svc grafana -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pendente")

echo ""
echo -e "${G}"
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║              ✔  Deploy concluído com sucesso!             ║"
echo "  ╠═══════════════════════════════════════════════════════════╣"
printf "  ║  App 1 (cache 10s) texto   → http://%-22s║\n" "$NGINX_IP/app1/text"
printf "  ║  App 1 (cache 10s) horário → http://%-22s║\n" "$NGINX_IP/app1/time"
printf "  ║  App 2 (cache 60s) texto   → http://%-22s║\n" "$NGINX_IP/app2/text"
printf "  ║  App 2 (cache 60s) horário → http://%-22s║\n" "$NGINX_IP/app2/time"
echo  "  ╠═══════════════════════════════════════════════════════════╣"
printf "  ║  Prometheus → http://%-39s║\n" "$PROM_IP:9090"
printf "  ║  Grafana    → http://%-39s║\n" "$GRAF_IP:3000  (admin/admin)"
echo  "  ╚═══════════════════════════════════════════════════════════╝"
echo -e "${N}"
