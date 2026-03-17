.PHONY: up down logs ps build clean test \
        gcp-init gcp-plan gcp-apply gcp-destroy \
        k8s-creds k8s-deploy k8s-status k8s-pods k8s-logs-app1 k8s-logs-app2 \
        k8s-hpa k8s-urls k8s-rollout k8s-delete

# ──────────────────────────────────────────────────────────────
# Variáveis GCP/K8s (sobrescrevíveis: make k8s-deploy PROJECT_ID=xxx)
# ──────────────────────────────────────────────────────────────
PROJECT_ID    ?= $(shell gcloud config get-value project 2>/dev/null)
REGION        ?= us-central1
REPO_NAME     ?= devops-challenge
CLUSTER_NAME  ?= devops-challenge-cluster
NAMESPACE     ?= devops-challenge
REGISTRY       = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/$(REPO_NAME)

# ──────────────────────────────────────────────────────────────
# Local — Docker Compose
# ──────────────────────────────────────────────────────────────

## Sobe toda a stack localmente
up:
	docker compose up -d

## Para a stack local
down:
	docker compose down

## Logs em tempo real
logs:
	docker compose logs -f

## Status dos containers
ps:
	docker compose ps

## Reconstrói as imagens locais
build:
	docker compose build

## Remove containers, redes e volumes
clean:
	docker compose down -v --remove-orphans

## Executa os testes localmente
test:
	@echo "==> Testando App 1 (Python/FastAPI)..."
	cd app1 && pip install -q -r requirements.txt httpx pytest && pytest test_main.py -v
	@echo "==> Testando App 2 (Node.js/Express)..."
	cd app2 && npm ci --silent && npm test

# ──────────────────────────────────────────────────────────────
# GCP — Terraform (provisiona o cluster GKE)
# ──────────────────────────────────────────────────────────────

## Inicializa o Terraform
gcp-init:
	cd infra/terraform && terraform init

## Mostra o plano de infraestrutura
gcp-plan:
	cd infra/terraform && terraform plan -var="project_id=$(PROJECT_ID)"

## Provisiona GKE + Artifact Registry na GCP
gcp-apply:
	cd infra/terraform && terraform apply -var="project_id=$(PROJECT_ID)" -auto-approve

## Destrói toda a infraestrutura na GCP
gcp-destroy:
	cd infra/terraform && terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve

# ──────────────────────────────────────────────────────────────
# Kubernetes — Deploy e operações no GKE
# ──────────────────────────────────────────────────────────────

## Configura o kubectl para o cluster GKE
k8s-creds:
	gcloud container clusters get-credentials $(CLUSTER_NAME) \
	  --region $(REGION) --project $(PROJECT_ID)

## Build, push das imagens e aplica todos os manifests no GKE
k8s-deploy: k8s-creds
	@echo "==> Autenticando Docker no Artifact Registry..."
	gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet
	@echo "==> Build e push das imagens..."
	docker build -t $(REGISTRY)/app1:latest ./app1 && docker push $(REGISTRY)/app1:latest
	docker build -t $(REGISTRY)/app2:latest ./app2 && docker push $(REGISTRY)/app2:latest
	@echo "==> Aplicando manifests no Kubernetes..."
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/nginx/
	kubectl apply -f k8s/app1/
	kubectl apply -f k8s/app2/
	kubectl apply -f k8s/observability/prometheus/
	kubectl apply -f k8s/observability/grafana/
	@echo "==> Aguardando rollout..."
	kubectl rollout status deployment/app1 -n $(NAMESPACE) --timeout=120s
	kubectl rollout status deployment/app2 -n $(NAMESPACE) --timeout=120s
	kubectl rollout status deployment/nginx -n $(NAMESPACE) --timeout=120s

## Status de todos os pods no namespace
k8s-status:
	kubectl get all -n $(NAMESPACE)

## Lista apenas os pods com status
k8s-pods:
	kubectl get pods -n $(NAMESPACE) -o wide

## Logs do App 1 em tempo real
k8s-logs-app1:
	kubectl logs -n $(NAMESPACE) -l app=app1 -f --tail=50

## Logs do App 2 em tempo real
k8s-logs-app2:
	kubectl logs -n $(NAMESPACE) -l app=app2 -f --tail=50

## Logs do Nginx em tempo real
k8s-logs-nginx:
	kubectl logs -n $(NAMESPACE) -l app=nginx -f --tail=50

## Status do HPA (Horizontal Pod Autoscaler)
k8s-hpa:
	kubectl get hpa -n $(NAMESPACE)

## Aguarda o rollout de todos os deployments
k8s-rollout:
	kubectl rollout status deployment/app1    -n $(NAMESPACE)
	kubectl rollout status deployment/app2    -n $(NAMESPACE)
	kubectl rollout status deployment/nginx   -n $(NAMESPACE)
	kubectl rollout status deployment/grafana -n $(NAMESPACE)

## Exibe todas as URLs da aplicação no GKE
k8s-urls:
	$(eval NGINX_IP   := $(shell kubectl get svc nginx      -n $(NAMESPACE) -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null))
	$(eval PROM_IP    := $(shell kubectl get svc prometheus -n $(NAMESPACE) -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null))
	$(eval GRAFANA_IP := $(shell kubectl get svc grafana    -n $(NAMESPACE) -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null))
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  URLs de Produção — GKE"
	@echo "════════════════════════════════════════════"
	@echo "  App 1 (cache 10s)"
	@echo "  ├── http://$(NGINX_IP)/app1/text"
	@echo "  └── http://$(NGINX_IP)/app1/time"
	@echo "  App 2 (cache 60s)"
	@echo "  ├── http://$(NGINX_IP)/app2/text"
	@echo "  └── http://$(NGINX_IP)/app2/time"
	@echo "  Prometheus → http://$(PROM_IP):9090"
	@echo "  Grafana    → http://$(GRAFANA_IP):3000"
	@echo "════════════════════════════════════════════"
	@echo ""

## Remove todos os recursos do namespace do GKE
k8s-delete:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
