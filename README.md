# Desafio DevOps 2025

Dois serviços web em linguagens diferentes, com cache via Nginx Proxy Cache, observabilidade com Prometheus + Grafana — tudo orquestrado com Docker Compose.

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
├── docs/
│   └── architecture.md          # Diagrama + análise + pontos de melhoria
├── docker-compose.yml
└── Makefile
```

## Início Rápido

```bash
docker compose up -d
```

Ou usando o Makefile:

```bash
make up
```

Aguarde ~15s para todos os containers ficarem saudáveis.

---

## Endpoints

### App 1 — Python / FastAPI (cache: **10 segundos**)

| Método | URL | Descrição |
|--------|-----|-----------|
| GET | `http://localhost/app1/text` | Texto fixo |
| GET | `http://localhost/app1/time` | Horário atual do servidor |

### App 2 — Node.js / Express (cache: **1 minuto**)

| Método | URL | Descrição |
|--------|-----|-----------|
| GET | `http://localhost/app2/text` | Texto fixo |
| GET | `http://localhost/app2/time` | Horário atual do servidor |

### Observabilidade

| Serviço | URL | Credenciais |
|---------|-----|-------------|
| Prometheus | `http://localhost:9090` | — |
| Grafana | `http://localhost:3000` | admin / admin |

---

## Verificando o Cache

O header `X-Cache-Status` indica se a resposta veio do cache:

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

```bash
make up       # Subir toda a infraestrutura
make down     # Derrubar
make logs     # Acompanhar logs em tempo real
make ps       # Status dos containers
make build    # Reconstruir imagens
make clean    # Remover tudo, incluindo volumes
```

---

## Arquitetura

Ver [docs/architecture.md](docs/architecture.md) para:
- Diagrama de componentes
- Fluxo de requisição com cache (sequência)
- Fluxo de atualização de código e infra
- Análise e 12 sugestões de melhoria
