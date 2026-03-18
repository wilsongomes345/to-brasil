#!/usr/bin/env bash
# =============================================================
# setup.sh — Sobe toda a infraestrutura GCP/GKE com 1 comando
# Uso: bash setup.sh
# =============================================================
set -euo pipefail

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
[[ -f "$CREDS" ]]           || die "$CREDS não encontrado na pasta atual"
command -v gcloud    &>/dev/null || die "gcloud não instalado"
command -v terraform &>/dev/null || die "terraform não instalado"
command -v kubectl   &>/dev/null || die "kubectl não instalado"
command -v docker    &>/dev/null || die "docker não instalado"
docker info &>/dev/null          || die "Docker não está rodando — abra o Docker Desktop"
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

# ── 2. Terraform — GKE + Artifact Registry ────────────────────
step "2/6 — Provisionando infraestrutura (GKE Autopilot + Artifact Registry)..."
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

# ── 3. Configura kubectl ──────────────────────────────────────
step "3/6 — Configurando kubectl para o cluster GKE..."
gcloud container clusters get-credentials "$CLUSTER" \
  --region "$REGION" --project "$PROJECT_ID"
ok "kubectl apontando para $CLUSTER"

# ── 4. Build e push das imagens ───────────────────────────────
step "4/6 — Build e push das imagens para o Artifact Registry..."

echo "  → Building App 1 (Python/FastAPI)..."
docker build -t "$REGISTRY/app1:latest" ./app1 -q
docker push  "$REGISTRY/app1:latest" -q
ok "app1 enviada para $REGISTRY/app1:latest"

echo "  → Building App 2 (Node.js/Express)..."
docker build -t "$REGISTRY/app2:latest" ./app2 -q
docker push  "$REGISTRY/app2:latest" -q
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
