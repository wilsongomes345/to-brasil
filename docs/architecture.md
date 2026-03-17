# Arquitetura — Desafio DevOps 2025

---

## 1. Visão Geral dos Componentes

| Componente        | Tecnologia                       | Porta (externa) |
|-------------------|----------------------------------|-----------------|
| App 1             | Python 3.12 / FastAPI            | — (interno)     |
| App 2             | Node.js 20 / Express             | — (interno)     |
| Reverse Proxy     | Nginx (+ Proxy Cache)            | **80**          |
| Nginx Exporter    | nginx-prometheus-exporter        | — (interno)     |
| Métricas          | Prometheus                       | **9090**        |
| Dashboards        | Grafana                          | **3000**        |

---

## 2. Diagrama Local (Docker Compose)

```mermaid
graph TB
    Client["🌐 Cliente"]

    subgraph proxy["Camada de Entrada"]
        Nginx["⚙️ Nginx\nReverse Proxy + Cache\n:80"]
    end

    subgraph apps["Camada de Aplicação  (rede: backend)"]
        App1["🐍 App 1\nPython / FastAPI\nCache: 10s"]
        App2["🟢 App 2\nNode.js / Express\nCache: 60s"]
    end

    subgraph obs["Observabilidade  (rede: monitoring)"]
        NginxExp["📡 Nginx Exporter"]
        Prometheus["📈 Prometheus\n:9090"]
        Grafana["📊 Grafana\n:3000"]
    end

    Client -->|"HTTP :80"| Nginx
    Nginx -->|"HIT / MISS  /app1/*"| App1
    Nginx -->|"HIT / MISS  /app2/*"| App2
    Nginx -->|"/nginx_status"| NginxExp
    NginxExp -->|"scrape :9113"| Prometheus
    Prometheus -->|"datasource"| Grafana
```

---

## 3. Diagrama de Produção (GCP)

```mermaid
graph TB
    Internet["🌐 Internet"]
    Dev["👨‍💻 Developer\ngit push"]

    subgraph GCP["☁️ Google Cloud Platform"]

        subgraph CICD["GitHub Actions (CI/CD)"]
            Test["✅ Testes"]
            Build["🔨 Build Images"]
            PushImg["📤 Push :latest + :sha"]
        end

        AR["🗄️ Artifact Registry\nus-central1-docker.pkg.dev\n└── /app1\n└── /app2"]

        FW["🔒 Firewall\n:80  :3000  :9090  :22"]

        subgraph VM["🖥️ GCE VM — e2-medium"]
            subgraph DC["Docker Compose (prod)"]
                NginxP["⚙️ Nginx\n:80"]
                App1P["🐍 App 1\nFastAPI"]
                App2P["🟢 App 2\nExpress"]
                PromP["📈 Prometheus\n:9090"]
                GrafP["📊 Grafana\n:3000"]
            end
        end
    end

    Dev -->|"push main"| CICD
    Test --> Build --> PushImg --> AR
    AR -->|"docker pull"| VM
    Internet --> FW --> NginxP
    NginxP --> App1P
    NginxP --> App2P
```

---

## 4. Fluxo de Requisição (com Cache)

```mermaid
sequenceDiagram
    participant C  as 🌐 Cliente
    participant N  as ⚙️ Nginx Cache
    participant A1 as 🐍 App 1 (FastAPI)
    participant A2 as 🟢 App 2 (Express)

    Note over N: app1_cache TTL = 10s
    Note over N: app2_cache TTL = 60s

    C->>N: GET /app1/time
    alt Cache MISS
        N->>A1: GET /time
        A1-->>N: {"time": "..."}
        N-->>C: 200 OK  X-Cache-Status: MISS
        Note over N: Armazena por 10s
    else Cache HIT (< 10s)
        N-->>C: 200 OK  X-Cache-Status: HIT
    end

    C->>N: GET /app2/text
    alt Cache MISS
        N->>A2: GET /text
        A2-->>N: {"message": "..."}
        N-->>C: 200 OK  X-Cache-Status: MISS
        Note over N: Armazena por 60s
    else Cache HIT (< 60s)
        N-->>C: 200 OK  X-Cache-Status: HIT
    end
```

---

## 5. Fluxo de Atualização

### 5.1 — Código das Aplicações (CI/CD automatizado)

```mermaid
flowchart LR
    Dev["👨‍💻 git push\nmain"] --> GH["GitHub\nActions"]
    GH --> Test["✅ Testes\nautomáticos"]
    Test --> Build["🔨 Build\nDocker image"]
    Build --> AR["🗄️ Artifact\nRegistry\n:latest + :sha"]
    AR --> SSH["🔑 SSH\nna VM"]
    SSH --> Pull["📥 compose\npull"]
    Pull --> Up["🚀 compose\nup -d"]
    Up --> Health["❤️ Health\nCheck"]
    Health -->|"OK"| Done["✅ Deploy\nconcluído"]
    Health -->|"Falha"| Roll["⏪ Rollback\ntag anterior"]
```

### 5.2 — Infraestrutura (Terraform)

```mermaid
flowchart LR
    Edit["✏️ Editar\n.tf files"] --> Plan["📋 terraform\nplan"]
    Plan --> Review["👀 Code\nReview / PR"]
    Review -->|"Aprovado"| Apply["⚡ terraform\napply"]
    Apply --> GCP["☁️ GCP\natualizado"]
    Review -->|"Rejeitado"| Edit
```

### 5.3 — Config Nginx (sem downtime)

```mermaid
flowchart LR
    Cfg["📝 Editar\nnginx.conf"] --> Val["🔎 nginx -t\n(valida config)"]
    Val -->|"OK"| Reload["🔄 nginx -s reload\n(zero downtime)"]
    Val -->|"Erro"| Block["🚫 Bloqueado\n(não aplica)"]
    Reload --> Health["❤️ Health Check"]
    Health -->|"OK"| Done["✅ Config\naplicada"]
    Health -->|"Falha"| Revert["⏪ git revert\n+ redeploy"]
```

---

## 6. Análise e Pontos de Melhoria

### Pontos fortes da arquitetura atual

- ✅ Cache centralizado no Nginx sem modificar código das apps
- ✅ TTLs diferentes por serviço (`app1_cache: 10s` / `app2_cache: 60s`)
- ✅ Headers `X-Cache-Status` e `X-Cache-TTL` em todas as respostas (debug fácil)
- ✅ Redes Docker separadas (`backend` / `monitoring`)
- ✅ Health checks em todos os containers
- ✅ IaC com Terraform — infra versionada e reproduzível
- ✅ CI/CD automatizado com GitHub Actions (test → build → push → deploy)
- ✅ Imagens versionadas por SHA do commit no Artifact Registry

---

### Sugestões de Melhoria

| # | Melhoria | Impacto | Esforço |
|---|----------|:-------:|:-------:|
| 1 | **Kubernetes (GKE)** — HPA, rolling updates, self-healing | 🔴 Alto | 🔴 Alto |
| 2 | **Cloud Load Balancer** — GLB gerenciado em vez de IP direto da VM | 🔴 Alto | 🟡 Médio |
| 3 | **HTTPS / TLS** — Managed Certificate no GCP ou Let's Encrypt | 🔴 Alto | 🟢 Baixo |
| 4 | **Redis como cache distribuído** — cache entre múltiplas réplicas, TTL por chave | 🟡 Médio | 🟡 Médio |
| 5 | **Múltiplas réplicas + LB** — escalar app1/app2 horizontalmente | 🔴 Alto | 🟡 Médio |
| 6 | **Cloud Armor** — WAF + proteção contra DDoS | 🔴 Alto | 🟡 Médio |
| 7 | **OpenTelemetry + Jaeger** — distributed tracing ponta a ponta | 🟡 Médio | 🟡 Médio |
| 8 | **Loki + Promtail + Grafana** — agregação centralizada de logs | 🟡 Médio | 🟢 Baixo |
| 9 | **Terraform remote state (GCS)** — estado compartilhado em Cloud Storage | 🔴 Alto | 🟢 Baixo |
| 10 | **Resource limits** — CPU/Memory limits nos containers | 🟡 Médio | 🟢 Baixo |
| 11 | **Alertas Grafana/Alertmanager** — notificar no Slack se cache hit rate cair | 🟡 Médio | 🟢 Baixo |
| 12 | **GCP Secret Manager** — credenciais via secret manager em vez de env vars | 🔴 Alto | 🟢 Baixo |

---

## 7. Estimativa de Custo Mensal (GCP — us-central1)

| Recurso | Configuração | Custo estimado/mês |
|---------|-------------|-------------------:|
| GCE VM | e2-medium 24/7 | ~$27,00 |
| Artifact Registry | 1 GB storage | ~$0,10 |
| Egress de rede | ~10 GB | ~$1,20 |
| **Total estimado** | | **~$28/mês** |

> 💡 Com os **$1.700 de créditos** da conta de testes GCP, a infraestrutura tem aproximadamente **5 anos** de operação contínua.
