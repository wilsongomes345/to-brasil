[![CI/CD](https://github.com/wilsongomes345/to-brasil/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/wilsongomes345/to-brasil/actions/workflows/ci-cd.yml)

# Desafio DevOps

Dois serviços web em linguagens diferentes, com cache via **Nginx Proxy Cache**, observabilidade com **Prometheus + Grafana** e segurança com **Trivy + pip-audit + npm audit + Dependabot** — rodando local com Docker Compose e em produção na **Google Cloud Platform (GCE + Artifact Registry)**.

## Estrutura

```
.
├── app1/                        # Python 3.12 / FastAPI
│   ├── main.py                  # API + /metrics (Prometheus)
│   ├── test_main.py             # Testes pytest
│   ├── requirements.txt
│   └── Dockerfile               # Usuário não-root
├── app2/                        # Node.js 20 / Express
│   ├── index.js                 # API + /metrics (prom-client)
│   ├── app2.test.js             # Testes node:test nativos
│   ├── package.json
│   └── Dockerfile               # Usuário não-root (node)
├── nginx/
│   └── nginx.conf               # Reverse proxy + cache (10s/60s) + rate limiting
├── observability/
│   ├── prometheus/
│   │   └── prometheus.yml       # Scrape: nginx-exporter + app1 + app2
│   └── grafana/
│       └── provisioning/        # Datasource + dashboards auto-provisionados
│           ├── datasources/
│           └── dashboards/
│               ├── nginx-overview.json   # Dashboard Nginx
│               └── app-metrics.json      # Dashboard App1 + App2
├── infra/
│   ├── terraform/               # IaC — GCE VM + Artifact Registry + Firewall
│   └── scripts/
│       └── startup.sh           # Bootstrap da VM (instala Docker, sobe stack)
├── .github/
│   ├── dependabot.yml           # Atualização automática de dependências
│   └── workflows/
│       └── ci-cd.yml            # Pipeline: test+security → build+trivy → deploy → smoke-test
├── docs/
│   └── architecture.md          # Diagrama de arquitetura (Mermaid)
├── docker-compose.yml           # Stack local
├── docker-compose.prod.yml      # Stack produção (resource limits + não-root)
├── setup.sh                     # Setup completo GCP com 1 comando
└── Makefile
```

---

## Pipeline CI/CD

```
push main
    │
    ▼
┌─────────────────────────┐
│  1. Testes & Security   │  pytest + node:test + pip-audit + npm audit
└────────────┬────────────┘
             │
    ▼
┌─────────────────────────┐
│  2. Build & Trivy Scan  │  docker build + push + scan CRITICAL/HIGH CVEs
└────────────┬────────────┘
             │
    ▼
┌─────────────────────────┐
│  3. Deploy (Terraform)  │  cria/mantém VM + SSH deploy
└────────────┬────────────┘
             │
    ▼
┌─────────────────────────┐
│  4. Smoke Test          │  valida endpoints + cache MISS→HIT + rate limit
└─────────────────────────┘
```

---

## Execução Local

```bash
docker compose up -d
```

Aguarde ~15s para todos os containers ficarem saudáveis.

### Endpoints locais

| App | Rota | Cache |
|-----|------|-------|
| App 1 — Python/FastAPI | `http://localhost/app1/text` | 10s |
| App 1 — Python/FastAPI | `http://localhost/app1/time` | 10s |
| App 2 — Node.js/Express | `http://localhost/app2/text` | 60s |
| App 2 — Node.js/Express | `http://localhost/app2/time` | 60s |
| Prometheus | `http://localhost:9090` | — |
| Grafana | `http://localhost:3000` | admin/admin |

---

## Verificando o Cache

O header `X-Cache-Status` indica se a resposta veio do cache:

```bash
# 1ª requisição — MISS (resposta veio do servidor)
curl -sI http://localhost/app1/time | grep X-Cache-Status
# X-Cache-Status: MISS

# 2ª requisição (dentro de 10s) — HIT (do cache)
curl -sI http://localhost/app1/time | grep X-Cache-Status
# X-Cache-Status: HIT
```

App 2 tem o mesmo comportamento com janela de **60 segundos**.

---

## Deploy na GCP (1 comando)

### Pré-requisitos

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) instalado
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- `credentials.json` de uma Service Account com role **Editor**

### Executar

```bash
bash setup.sh
```

O script automaticamente:
1. Autentica no GCP com a Service Account
2. Habilita as APIs necessárias
3. Cria bucket GCS para estado Terraform (compartilhado com CI/CD)
4. Provisiona com Terraform: VM (`e2-medium`), Artifact Registry e Firewall
5. Faz build e push das imagens via Cloud Build (sem Docker Desktop)
6. Aguarda a VM inicializar e a stack subir (~5–10 min)
7. Exibe todas as URLs de acesso

---

## Observabilidade

Grafana abre com **dois dashboards pré-configurados**:

| Dashboard | Métricas |
|-----------|----------|
| **Nginx Overview** | Conexões ativas, request rate, cache HIT/MISS |
| **App Metrics** | Request rate, latência p50/p95/p99, taxa de erros — por app |

Prometheus scraping:
- `nginx-exporter:9113` — métricas do Nginx
- `app1:8000/metrics` — métricas FastAPI (requests, latência)
- `app2:3001/metrics` — métricas Express (requests, latência)

---

## Segurança

| Camada | Ferramenta | Frequência |
|--------|------------|------------|
| Vulnerabilidades Python | `pip-audit` | A cada push |
| Vulnerabilidades Node.js | `npm audit` | A cada push |
| CVEs nas imagens Docker | `Trivy` (CRITICAL/HIGH) | A cada push |
| Atualização automática | `Dependabot` | Toda semana |
| Containers não-root | `USER appuser` / `USER node` | Sempre |
| Resource limits | `deploy.resources.limits` | Sempre |
| Rate limiting | Nginx `limit_req` (10 req/s) | Sempre |

---

## CI/CD — Secrets necessários

Configure em: **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Valor |
|--------|-------|
| `GCP_PROJECT_ID` | ID do projeto GCP |
| `GCP_CREDENTIALS` | Conteúdo completo do `credentials.json` |

---

## Rodando os Testes Localmente

```bash
# App 1 — Python
cd app1 && pip install -r requirements.txt "httpx<0.28" pytest && pytest -v

# App 2 — Node.js
cd app2 && npm install && npm test
```

---

## Comandos Make

```bash
make up       # Subir stack local
make down     # Derrubar stack
make logs     # Logs em tempo real
make ps       # Status dos containers
make test     # Rodar todos os testes
make clean    # Remover containers e volumes
```

---

## Arquitetura

Ver [docs/architecture.md](docs/architecture.md) para diagrama completo com fluxo de requisição, cache e CI/CD.
