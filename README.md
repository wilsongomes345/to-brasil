# Desafio DevOps

Dois serviços web em linguagens diferentes, com cache via **Nginx Proxy Cache**, observabilidade com **Prometheus + Grafana** — rodando local com Docker Compose e em produção na **Google Cloud Platform (GCE + Artifact Registry + CI/CD)**.

## Estrutura

```
.
├── app1/                        # Python 3.12 / FastAPI
│   ├── main.py
│   ├── test_main.py
│   ├── requirements.txt
│   └── Dockerfile
├── app2/                        # Node.js 20 / Express
│   ├── index.js
│   ├── app2.test.js
│   ├── package.json
│   └── Dockerfile
├── nginx/
│   └── nginx.conf               # Reverse proxy + cache zones (10s / 60s)
├── observability/
│   ├── prometheus/
│   │   └── prometheus.yml       # Scrape configs
│   └── grafana/
│       └── provisioning/        # Datasource + dashboard auto-provisionados
├── infra/
│   ├── terraform/               # IaC — GCE VM + Artifact Registry + Firewall
│   └── scripts/
│       └── startup.sh           # Bootstrap da VM (instala Docker, sobe stack)
├── .github/
│   └── workflows/
│       └── ci-cd.yml            # Pipeline: test → build → terraform → deploy
├── docs/
│   └── architecture.md          # Diagrama de arquitetura (Mermaid)
├── docker-compose.yml           # Stack local (build from source)
├── docker-compose.prod.yml      # Stack produção (imagens do Artifact Registry)
├── setup.sh                     # Setup completo GCP com 1 comando
└── Makefile
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
- `credentials.json` de uma Service Account com role **Editor** na pasta do projeto

### Executar

```bash
bash setup.sh
```

O script automaticamente:
1. Autentica no GCP com a Service Account
2. Habilita as APIs necessárias
3. Cria o bucket GCS para estado do Terraform
4. Provisiona com Terraform: VM (`e2-medium`), Artifact Registry e Firewall
5. Faz build e push das imagens via Cloud Build (sem Docker Desktop)
6. Aguarda a VM inicializar e a stack subir (~5–10 min)
7. Exibe todas as URLs de acesso

### URLs de produção (após setup)

| Serviço | URL |
|---------|-----|
| App 1 texto   (cache 10s)  | `http://<VM_IP>/app1/text` |
| App 1 horário (cache 10s)  | `http://<VM_IP>/app1/time` |
| App 2 texto   (cache 60s)  | `http://<VM_IP>/app2/text` |
| App 2 horário (cache 60s)  | `http://<VM_IP>/app2/time` |
| Prometheus                  | `http://<VM_IP>:9090`      |
| Grafana (admin/admin)       | `http://<VM_IP>:3000`      |

---

## CI/CD (GitHub Actions)

A cada push na `main`, o pipeline executa automaticamente:

1. **Testes** — `pytest` (App 1) + `node --test` (App 2)
2. **Build & Push** — imagens Docker enviadas ao Artifact Registry com tags `latest` e `<git-sha>`
3. **Infraestrutura** — Terraform garante que a VM existe (cria se necessário)
4. **Deploy** — SSH na VM GCE, pull das novas imagens e restart do Compose

### Secrets necessários no repositório

| Secret | Valor |
|--------|-------|
| `GCP_PROJECT_ID` | ID do projeto GCP |
| `GCP_CREDENTIALS` | Conteúdo completo do `credentials.json` |

> Configure em: **Settings → Secrets and variables → Actions → New repository secret**

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
