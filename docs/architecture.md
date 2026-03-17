# Arquitetura da Infraestrutura

## Visão Geral dos Componentes

| Componente        | Tecnologia                       | Porta (externa) |
|-------------------|----------------------------------|-----------------|
| App 1             | Python 3.12 / FastAPI            | — (interno)     |
| App 2             | Node.js 20 / Express             | — (interno)     |
| Reverse Proxy     | Nginx (+ Proxy Cache)            | **80**          |
| Nginx Exporter    | nginx-prometheus-exporter        | — (interno)     |
| Métricas          | Prometheus                       | **9090**        |
| Dashboards        | Grafana                          | **3000**        |

---

## Diagrama de Componentes

```mermaid
graph TB
    Client["🌐 Cliente"]

    subgraph proxy["Camada de Entrada"]
        Nginx["Nginx\nReverse Proxy + Cache\n:80"]
    end

    subgraph apps["Camada de Aplicação  (rede: backend)"]
        App1["🐍 App 1\nPython / FastAPI\nCache: 10s"]
        App2["🟢 App 2\nNode.js / Express\nCache: 60s"]
    end

    subgraph obs["Observabilidade  (rede: monitoring)"]
        NginxExp["Nginx Exporter"]
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

## Fluxo de Requisição (com Cache)

```mermaid
sequenceDiagram
    participant C  as Cliente
    participant N  as Nginx Cache
    participant A  as Aplicação

    C->>N: GET /app1/time
    alt Cache HIT
        N-->>C: 200 OK (X-Cache-Status: HIT)
    else Cache MISS
        N->>A: GET /time
        A-->>N: 200 OK + body
        N-->>C: 200 OK (X-Cache-Status: MISS)
        Note over N: Armazena resposta<br/>App1 = 10s / App2 = 60s
    end
```

---

## Fluxo de Atualização

### Código das Aplicações

```mermaid
flowchart LR
    Dev["👨‍💻 Developer\ngit push"] --> Repo["📦 Git Repository"]
    Repo --> CI["⚙️ CI Pipeline\n(GitHub Actions)"]
    CI --> Test["✅ Build & Test"]
    Test --> Registry["🗃️ Container Registry\n(GHCR / Docker Hub)"]
    Registry --> Pull["docker compose pull"]
    Pull --> Up["docker compose up -d\n(zero-downtime com múltiplas réplicas)"]
    Up --> Health["🔍 Health Check"]
    Health -->|OK| Done["✅ Deploy concluído"]
    Health -->|Falha| Rollback["⏪ Rollback\n(imagem anterior)"]
```

### Infraestrutura (nginx.conf, docker-compose.yml)

```mermaid
flowchart LR
    Config["📝 Alteração de config\ngit push"] --> Repo["📦 Git Repository"]
    Repo --> CI["⚙️ CI Pipeline"]
    CI --> Validate["🔎 nginx -t\ndocker compose config"]
    Validate -->|OK| Deploy["docker compose up -d\n--no-deps nginx"]
    Validate -->|Falha| Block["🚫 Pipeline bloqueado"]
    Deploy --> Health["🔍 Health Check"]
    Health -->|OK| Done["✅ Config aplicada"]
    Health -->|Falha| Rollback["⏪ git revert + redeploy"]
```

---

## Análise e Pontos de Melhoria

### Pontos fortes da arquitetura atual

- **Cache no proxy**: o Nginx absorve carga sem modificar o código das aplicações
- **Headers de debug**: `X-Cache-Status` e `X-Cache-TTL` em todas as respostas
- **Redes separadas**: `backend` (apps ↔ nginx) e `monitoring` (observabilidade) isoladas
- **Health checks**: todos os serviços possuem verificação de saúde
- **Execução em 1 comando**: `docker compose up -d` ou `make up`

### Sugestões de Melhoria

| # | Melhoria | Justificativa |
|---|----------|---------------|
| 1 | **Kubernetes (K8s)** | HPA para escalonamento automático, rolling updates nativos e self-healing |
| 2 | **Redis como cache distribuído** | Permite cache compartilhado entre múltiplas réplicas das apps; persistência e TTL granular por chave |
| 3 | **CI/CD completo** | GitHub Actions para build → test → push → deploy automático a cada `git push` |
| 4 | **HTTPS / TLS** | Certbot + Let's Encrypt via Nginx ou Traefik como ingress; obrigatório em produção |
| 5 | **Múltiplas réplicas** | Load balancing com `deploy.replicas` no Compose ou Deployment no K8s |
| 6 | **Distributed Tracing** | OpenTelemetry + Jaeger para rastrear latência ponta a ponta e correlacionar logs |
| 7 | **Centralização de logs** | Loki + Promtail + Grafana (stack PLG) para consultas e alertas sobre logs |
| 8 | **Rate Limiting** | `limit_req_zone` no Nginx para proteção contra DDoS / abuso |
| 9 | **Resource Limits** | `mem_limit` / `cpus` no Compose (ou `resources.limits` no K8s) para evitar noisy neighbor |
| 10 | **Secrets Management** | Docker Secrets ou HashiCorp Vault — nunca variáveis de ambiente em texto claro |
| 11 | **Alerting** | Alertmanager (Prometheus) + notificações Slack/PagerDuty para SLO/SLA |
| 12 | **Cache Warming** | Script de pré-aquecimento do cache após deploy para evitar spike de MISS |
