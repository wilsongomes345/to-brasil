# Arquitetura da Infraestrutura

## Visão Geral

A infraestrutura roda na **Google Compute Engine (GCE)** na região `us-central1`.
Uma VM `e2-medium` executa toda a stack via **Docker Compose**:
Nginx (reverse proxy + cache), App1, App2, Prometheus e Grafana.
As imagens são armazenadas no **Artifact Registry** e o deploy é automatizado via **GitHub Actions + Terraform**.

---

## Diagrama — Arquitetura GCE

```mermaid
graph TB
    subgraph Internet
        DEV["Dev — Git Push"]
        CLIENT["Cliente — HTTP"]
    end

    subgraph GCP["Google Cloud Platform"]
        subgraph AR["Artifact Registry — us-central1"]
            IMG1["app1:sha"]
            IMG2["app2:sha"]
        end

        subgraph GCE["GCE VM — e2-medium — us-central1-a"]
            subgraph DC["Docker Compose Stack"]
                NGINX["Nginx :80\nReverse Proxy + Cache"]

                subgraph APPS["Aplicações"]
                    APP1["App1 Python/FastAPI :8000\n/text  /time  /metrics"]
                    APP2["App2 Node.js/Express :3001\n/text  /time  /metrics"]
                end

                subgraph OBS["Observabilidade"]
                    EXP["nginx-exporter :9113"]
                    PROM["Prometheus :9090"]
                    GRAF["Grafana :3000"]
                end
            end
        end

        GCS["GCS Bucket\nEstado Terraform"]
    end

    subgraph CICD["CI/CD — GitHub Actions"]
        T["1. Testes + Security\npytest · node:test · pip-audit · npm audit"]
        B["2. Build + Trivy\ndocker push · SARIF → GitHub Security"]
        TF["3. Terraform\ncria/mantém VM + Firewall + Registry"]
        D["4. Deploy SSH\ngit pull · docker compose up"]
    end

    DEV -->|"git push main"| T
    T --> B
    B --> AR
    B --> TF
    TF <-->|"estado"| GCS
    TF --> D
    D -->|"docker compose pull + up"| GCE

    CLIENT --> NGINX
    NGINX -->|"Cache MISS /app1/ TTL 10s"| APP1
    NGINX -->|"Cache MISS /app2/ TTL 60s"| APP2
    APP1 --> EXP
    APP2 --> EXP
    NGINX --> EXP
    EXP --> PROM
    APP1 -->|"/metrics"| PROM
    APP2 -->|"/metrics"| PROM
    PROM --> GRAF
```

---

## Diagrama — Fluxo de Requisição com Cache

```mermaid
sequenceDiagram
    participant C as Cliente
    participant N as Nginx Cache
    participant A as App Container

    C->>N: GET /app1/time
    alt Cache HIT
        N-->>C: 200 OK  X-Cache-Status: HIT
    else Cache MISS
        N->>A: GET /time
        A-->>N: 200 OK  timestamp
        N-->>C: 200 OK  X-Cache-Status: MISS
        Note over N: Armazena 10s (app1) ou 60s (app2)
    end
```

---

## Diagrama — Fluxo CI/CD

```mermaid
flowchart LR
    DEV["Developer"]

    subgraph GH["GitHub Actions"]
        T["1. Testes & Security\npytest · node:test\npip-audit · npm audit"]
        B["2. Build & Push\n+ Trivy → GitHub Security"]
        TF["3. Terraform Apply\ncria VM se não existir"]
        D["4. Deploy SSH\ndocker compose up"]
    end

    subgraph GCP["Google Cloud"]
        AR["Artifact Registry\napp1:sha  app2:sha"]
        GCS["GCS\nEstado Terraform"]
        subgraph VM["GCE VM"]
            OLD["Container antigo"]
            NEW["Container novo :sha"]
        end
    end

    DEV -->|"git push main"| T
    T -->|"ok"| B
    B --> AR
    B --> TF
    TF <--> GCS
    TF --> D
    D -->|"docker compose pull + up -d"| VM
    OLD -.->|"substituído"| NEW
```

> `docker compose up -d --remove-orphans` garante troca sem downtime perceptível.

---

## Componentes e Responsabilidades

| Componente | Tecnologia | Porta | Descrição |
|------------|-----------|-------|-----------|
| App 1 | Python FastAPI | 8000 | Rotas `/text`, `/time` e `/metrics` |
| App 2 | Node.js Express | 3001 | Rotas `/text`, `/time` e `/metrics` |
| Nginx | nginx:alpine | 80 | Reverse proxy com cache por rota e rate limiting |
| nginx-exporter | nginx-prometheus-exporter | 9113 | Exporta métricas do Nginx |
| Prometheus | prom/prometheus | 9090 | Coleta métricas de nginx, app1 e app2 |
| Grafana | grafana/grafana | 3000 | Dashboards auto-provisionados (admin/admin) |

---

## Cache — Configuração

| App | Cache Zone | TTL | Header de resposta |
|-----|-----------|-----|--------------------|
| App 1 | app1_cache 10MB | **10 segundos** | `X-Cache-Status: HIT` ou `MISS` |
| App 2 | app2_cache 10MB | **60 segundos** | `X-Cache-Status: HIT` ou `MISS` |

---

## Análise e Sugestões de Melhoria

### Pontos fortes da arquitetura atual

- **GCE + Docker Compose** — setup simples, reproduzível, fácil de depurar
- **Terraform no CI/CD** — infraestrutura como código, VM criada automaticamente no primeiro push
- **Estado remoto no GCS** — estado Terraform compartilhado entre máquinas e CI/CD
- **Cache no proxy** — sem alterar código das apps, TTLs diferentes por serviço
- **Imutabilidade de imagem** — cada deploy usa o SHA exato do commit (`:sha` + `:latest`)
- **Observabilidade completa** — Prometheus coleta métricas das apps e do Nginx, Grafana com dashboards pré-configurados
- **Segurança em camadas** — Trivy + pip-audit + npm audit + Dependabot + containers não-root + rate limiting

### Sugestões de melhoria

| # | Melhoria | Justificativa |
|---|----------|---------------|
| 1 | GKE Autopilot | Escala automática de pods sem gestão de VMs |
| 2 | HTTPS + cert-manager | TLS automático via Let's Encrypt |
| 3 | Workload Identity Federation | Autenticação GCP sem chave JSON no CI |
| 4 | Redis como cache distribuído | Cache persiste entre restarts e é compartilhado entre réplicas |
| 5 | Cloud Armor | WAF e proteção DDoS gerenciados |
| 6 | Cloud CDN | Cache na borda global para conteúdo estático |
| 7 | Loki + Grafana | Centralizar logs junto às métricas |
| 8 | OpenTelemetry | Distributed tracing entre Nginx e apps |
| 9 | Managed Instance Group | Auto-healing e escala horizontal automática da VM |
| 10 | Static IP | IP fixo para evitar mudança de endereço ao reiniciar a VM |
