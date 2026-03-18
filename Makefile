.PHONY: up down logs ps build clean test \
        gcp-init gcp-plan gcp-apply gcp-destroy \
        gcp-deploy gcp-ssh gcp-logs gcp-ip gcp-urls gcp-status

# ──────────────────────────────────────────────────────────────
# Variáveis GCP (sobrescrevíveis: make gcp-deploy PROJECT_ID=xxx)
# ──────────────────────────────────────────────────────────────
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION     ?= us-central1
ZONE       ?= us-central1-a
REPO_NAME  ?= devops-challenge
VM_NAME    ?= devops-challenge-vm
REGISTRY    = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/$(REPO_NAME)

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
	cd app1 && pip install -q -r requirements.txt "httpx<0.28" pytest && pytest test_main.py -v
	@echo "==> Testando App 2 (Node.js/Express)..."
	cd app2 && npm install --silent && npm test

# ──────────────────────────────────────────────────────────────
# GCP — Terraform (provisiona VM GCE + Artifact Registry)
# ──────────────────────────────────────────────────────────────

## Inicializa o Terraform
gcp-init:
	cd infra/terraform && terraform init

## Mostra o plano de infraestrutura
gcp-plan:
	cd infra/terraform && terraform plan -var="project_id=$(PROJECT_ID)"

## Provisiona GCE VM + Artifact Registry na GCP
gcp-apply:
	cd infra/terraform && terraform apply -var="project_id=$(PROJECT_ID)" -auto-approve

## Destrói toda a infraestrutura na GCP
gcp-destroy:
	cd infra/terraform && terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve

# ──────────────────────────────────────────────────────────────
# GCP — Operações na VM GCE
# ──────────────────────────────────────────────────────────────

## Faz o deploy manual via SSH (build via Cloud Build + docker-compose)
gcp-deploy:
	@echo "==> Build e push App 1..."
	gcloud builds submit ./app1 --tag "$(REGISTRY)/app1:latest" --project "$(PROJECT_ID)" --quiet
	@echo "==> Build e push App 2..."
	gcloud builds submit ./app2 --tag "$(REGISTRY)/app2:latest" --project "$(PROJECT_ID)" --quiet
	@echo "==> Deploy via SSH..."
	gcloud compute ssh $(VM_NAME) --zone=$(ZONE) --project=$(PROJECT_ID) \
	  --quiet --ssh-flag="-o StrictHostKeyChecking=no" \
	  --command="cd /opt/app && git pull origin main && echo 'REGISTRY=$(REGISTRY)' > .env && \
	    gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet && \
	    docker compose -f docker-compose.prod.yml pull && \
	    docker compose -f docker-compose.prod.yml up -d --remove-orphans && \
	    docker compose -f docker-compose.prod.yml ps"

## Abre SSH na VM
gcp-ssh:
	gcloud compute ssh $(VM_NAME) --zone=$(ZONE) --project=$(PROJECT_ID)

## Exibe logs do docker-compose na VM
gcp-logs:
	gcloud compute ssh $(VM_NAME) --zone=$(ZONE) --project=$(PROJECT_ID) \
	  --quiet --ssh-flag="-o StrictHostKeyChecking=no" \
	  --command="cd /opt/app && docker compose -f docker-compose.prod.yml logs --tail=50"

## Obtém o IP externo da VM
gcp-ip:
	@gcloud compute instances describe $(VM_NAME) \
	  --zone=$(ZONE) --project=$(PROJECT_ID) \
	  --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null

## Exibe todas as URLs da aplicação
gcp-urls:
	$(eval IP := $(shell gcloud compute instances describe $(VM_NAME) \
	  --zone=$(ZONE) --project=$(PROJECT_ID) \
	  --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null))
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  URLs de Produção — GCE"
	@echo "════════════════════════════════════════════"
	@echo "  App 1 (cache 10s)"
	@echo "  ├── http://$(IP)/app1/text"
	@echo "  └── http://$(IP)/app1/time"
	@echo "  App 2 (cache 60s)"
	@echo "  ├── http://$(IP)/app2/text"
	@echo "  └── http://$(IP)/app2/time"
	@echo "  Prometheus → http://$(IP):9090"
	@echo "  Grafana    → http://$(IP):3000  (admin/admin)"
	@echo "════════════════════════════════════════════"
	@echo ""

## Status dos containers na VM
gcp-status:
	gcloud compute ssh $(VM_NAME) --zone=$(ZONE) --project=$(PROJECT_ID) \
	  --quiet --ssh-flag="-o StrictHostKeyChecking=no" \
	  --command="cd /opt/app && docker compose -f docker-compose.prod.yml ps"
