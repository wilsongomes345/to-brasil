# Desafio DevOps 2025

Dois serviços web em linguagens diferentes, com cache via Nginx Proxy Cache, observabilidade com Prometheus + Grafana — rodando local com Docker Compose e em produção na **Google Cloud Platform (GCE + Artifact Registry)**.

## Estrutura

```
desafio/
├── app1/                        # Python 3.12 / FastAPI
├── app2/                        # Node.js 20 / Express
├── nginx/
│   └── nginx.conf               # Reverse proxy + cache zones
├── observability/
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── grafana/
│       └── provisioning/
│           └── datasources/
├── infra/
│   ├── terraform/               # IaC — provisiona GCE + Artifact Registry
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── scripts/
│       └── startup.sh           # Script de inicialização da VM
├── .github/
│   └── workflows/
│       └── ci-cd.yml            # Pipeline CI/CD (GitHub Actions)
├── docs/
│   └── architecture.md          # Diagrama + análise + pontos de melhoria
├── docker-compose.yml           # Stack local
├── docker-compose.prod.yml      # Stack de produção (usa imagens do Artifact Registry)
├── deploy.sh                    # Deploy GCP com um comando
└── Makefile
```

---

## Execução Local

```bash
docker compose up -d
# ou
make up
```

Aguarde ~15s para todos os containers ficarem saudáveis.

---

## Deploy na GCP

### Pré-requisitos

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) instalado e autenticado
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- Docker instalado
- Projeto GCP com a conta de testes ativa

### 1. Autenticar e configurar o projeto

```bash
gcloud auth login
gcloud config set project SEU_PROJECT_ID
```

### 2. Provisionar a infraestrutura (Terraform)

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edite terraform.tfvars com seu project_id

make gcp-init    # terraform init
make gcp-plan    # visualiza o que será criado
make gcp-apply   # cria VM + Artifact Registry + Firewall
```

O Terraform exibe os IPs e URLs ao final.

### 3. Build, push e deploy das imagens

```bash
make gcp-deploy
# ou diretamente:
./deploy.sh
```

Esse único comando:
1. Autentica o Docker no Artifact Registry
2. Faz build e push da App 1 (Python/FastAPI)
3. Faz build e push da App 2 (Node.js/Express)
4. SSH na VM e sobe o `docker-compose.prod.yml`
5. Exibe todas as URLs de acesso

### 4. Verificar URLs em produção

```bash
make gcp-urls
```

---

## Endpoints

### App 1 — Python / FastAPI (cache: **10 segundos**)

| Método | URL | Descrição |
|--------|-----|-----------|
| GET | `/app1/text` | Texto fixo |
| GET | `/app1/time` | Horário atual do servidor |

### App 2 — Node.js / Express (cache: **1 minuto**)

| Método | URL | Descrição |
|--------|-----|-----------|
| GET | `/app2/text` | Texto fixo |
| GET | `/app2/time` | Horário atual do servidor |

### Observabilidade

| Serviço | Porta | Credenciais |
|---------|-------|-------------|
| Prometheus | `:9090` | — |
| Grafana | `:3000` | admin / admin |

---

## Verificando o Cache

O header `X-Cache-Status` mostra se a resposta veio do cache:

```bash
# Primeira requisição — MISS (busca na app)
curl -sI http://localhost/app1/time | grep X-Cache
# X-Cache-Status: MISS

# Segunda requisição (dentro de 10s) — HIT (do cache)
curl -sI http://localhost/app1/time | grep X-Cache
# X-Cache-Status: HIT
```

Para o App 2 o mesmo comportamento se aplica, com janela de **60 segundos**.

---

## Comandos Úteis

### Local

```bash
make up       # Subir toda a stack localmente
make down     # Derrubar
make logs     # Logs em tempo real
make ps       # Status dos containers
make build    # Reconstruir imagens
make clean    # Remover tudo, incluindo volumes
```

### GCP

```bash
make gcp-init     # Inicializar Terraform
make gcp-plan     # Ver plano de infraestrutura
make gcp-apply    # Provisionar infraestrutura na GCP
make gcp-deploy   # Build + push + deploy na VM
make gcp-ssh      # SSH na VM de produção
make gcp-logs     # Logs da aplicação na VM
make gcp-ip       # IP externo da VM
make gcp-urls     # Todos os endpoints em produção
make gcp-destroy  # Destruir infraestrutura
```

---

## CI/CD (GitHub Actions)

O pipeline `.github/workflows/ci-cd.yml` executa automaticamente a cada push na `main`:

1. **Testes** — valida App 1 (pytest) e App 2 (Node.js)
2. **Build & Push** — constrói as imagens e envia ao Artifact Registry com tags `latest` e `<git-sha>`
3. **Deploy** — SSH na VM GCE, pull das novas imagens e restart do compose

**Secrets necessários no GitHub:**

| Secret | Descrição |
|--------|-----------|
| `GCP_PROJECT_ID` | ID do projeto GCP |
| `GCP_CREDENTIALS` | JSON da Service Account com permissões de Artifact Registry e Compute |

---

## Arquitetura

Ver [docs/architecture.md](docs/architecture.md) para:
- Diagrama local (Docker Compose)
- Diagrama de produção (GCP)
- Fluxo de requisição com cache
- Fluxo de atualização (CI/CD)
- Análise e sugestões de melhoria
