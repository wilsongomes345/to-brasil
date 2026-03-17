.PHONY: up down logs ps build clean \
        gcp-init gcp-plan gcp-apply gcp-destroy gcp-deploy gcp-ssh gcp-logs gcp-ip gcp-urls

# ──────────────────────────────────────────────────────────────
# Variáveis GCP (podem ser sobrescritas: make gcp-deploy ZONE=us-east1-b)
# ──────────────────────────────────────────────────────────────
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION     ?= us-central1
ZONE       ?= us-central1-a
REPO_NAME  ?= devops-challenge
VM_NAME    ?= devops-challenge-vm
REGISTRY    = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/$(REPO_NAME)

# ──────────────────────────────────────────────────────────────
# Local (Docker Compose)
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

# ──────────────────────────────────────────────────────────────
# GCP — Terraform
# ──────────────────────────────────────────────────────────────

## Inicializa o Terraform
gcp-init:
	cd infra/terraform && terraform init

## Mostra o plano de infraestrutura
gcp-plan:
	cd infra/terraform && terraform plan -var="project_id=$(PROJECT_ID)"

## Provisiona a infraestrutura na GCP
gcp-apply:
	cd infra/terraform && terraform apply -var="project_id=$(PROJECT_ID)" -auto-approve

## Destrói toda a infraestrutura na GCP
gcp-destroy:
	cd infra/terraform && terraform destroy -var="project_id=$(PROJECT_ID)" -auto-approve

# ──────────────────────────────────────────────────────────────
# GCP — Deploy
# ──────────────────────────────────────────────────────────────

## Build, push das imagens e deploy na VM (tudo em um comando)
gcp-deploy:
	PROJECT_ID=$(PROJECT_ID) REGION=$(REGION) ZONE=$(ZONE) REPO_NAME=$(REPO_NAME) VM_NAME=$(VM_NAME) ./deploy.sh

## SSH na VM de produção
gcp-ssh:
	gcloud compute ssh $(VM_NAME) --zone=$(ZONE)

## Logs da aplicação na VM
gcp-logs:
	gcloud compute ssh $(VM_NAME) --zone=$(ZONE) \
	  --command="cd /opt/app && docker compose -f docker-compose.prod.yml logs -f"

## IP externo da VM
gcp-ip:
	@gcloud compute instances describe $(VM_NAME) --zone=$(ZONE) \
	  --format="get(networkInterfaces[0].accessConfigs[0].natIP)"

## Exibe todas as URLs da aplicação em produção
gcp-urls:
	$(eval IP := $(shell gcloud compute instances describe $(VM_NAME) --zone=$(ZONE) --format="get(networkInterfaces[0].accessConfigs[0].natIP)"))
	@echo ""
	@echo "════════════════════════════════════════"
	@echo "  URLs de Produção (GCP)"
	@echo "════════════════════════════════════════"
	@echo "  App 1 (cache 10s)"
	@echo "  ├── http://$(IP)/app1/text"
	@echo "  └── http://$(IP)/app1/time"
	@echo "  App 2 (cache 60s)"
	@echo "  ├── http://$(IP)/app2/text"
	@echo "  └── http://$(IP)/app2/time"
	@echo "  Prometheus → http://$(IP):9090"
	@echo "  Grafana    → http://$(IP):3000"
	@echo ""
