# Documentação Técnica — DevOps Challenge

> Explicação linha a linha de cada arquivo do projeto.

---

## Índice

1. [Visão Geral da Arquitetura](#1-visão-geral-da-arquitetura)
2. [App 1 — Python / FastAPI](#2-app-1--python--fastapi)
3. [App 2 — Node.js / Express](#3-app-2--nodejs--express)
4. [Nginx — Reverse Proxy + Cache + Rate Limiting](#4-nginx--reverse-proxy--cache--rate-limiting)
5. [Docker Compose — Produção](#5-docker-compose--produção)
6. [Observabilidade — Prometheus + Grafana](#6-observabilidade--prometheus--grafana)
7. [Infraestrutura — Terraform (GCP)](#7-infraestrutura--terraform-gcp)
8. [Startup Script — Inicialização da VM](#8-startup-script--inicialização-da-vm)
9. [CI/CD — GitHub Actions](#9-cicd--github-actions)
10. [setup.sh — Deploy com Um Comando](#10-setupsh--deploy-com-um-comando)

---

## 1. Visão Geral da Arquitetura

```
Internet
   │
   ▼
[Nginx :80]  ←── Rate limit: 10 req/s por IP
   │
   ├─── /app1/* ──► [App 1 - Python/FastAPI :8000]  cache: 10s
   └─── /app2/* ──► [App 2 - Node.js/Express :3001]  cache: 60s
   │
   │ /nginx_status
   ▼
[nginx-exporter :9113] ──► [Prometheus :9090] ──► [Grafana :3000]
                                  ▲
                          app1:8000/metrics
                          app2:3001/metrics
```

**Fluxo de deploy:**
```
git push main
     │
     ▼
GitHub Actions
  ├── Job 1: Testes + pip-audit + npm audit
  ├── Job 2: Docker build + push + Trivy scan → GitHub Security tab
  ├── Job 3: Terraform (cria/mantém VM) + SSH deploy
  └── Job 4: Smoke test (valida cache MISS→HIT + endpoints)
```

---

## 2. App 1 — Python / FastAPI

### `app1/requirements.txt`

```
fastapi==0.110.0                 # Framework web assíncrono para Python
uvicorn[standard]==0.27.1        # Servidor ASGI (executa o FastAPI)
prometheus-fastapi-instrumentator # Adiciona /metrics automaticamente ao FastAPI
httpx<0.28                       # Cliente HTTP usado pelo TestClient do FastAPI
                                 # Pinado <0.28 pois a v0.28 quebrou a API interna
                                 # que o Starlette usa para testes
```

### `app1/main.py`

```python
from fastapi import FastAPI          # Importa a classe principal do framework
from datetime import datetime        # Para gerar o timestamp no endpoint /time
from prometheus_fastapi_instrumentator import Instrumentator
# ^ Biblioteca que intercepta todas as requisições e expõe métricas Prometheus
# Métricas geradas: http_request_duration_seconds, http_requests_total

app = FastAPI(title="App 1 - Python FastAPI")
# ^ Instancia a aplicação. O title aparece na documentação automática (/docs)

Instrumentator().instrument(app).expose(app, endpoint="/metrics")
# instrument(app): registra um middleware que mede latência e contagem de requests
# expose(app, endpoint="/metrics"): adiciona a rota GET /metrics que retorna
#   as métricas no formato Prometheus (text/plain)

@app.get("/health")
def health():
    return {"status": "ok", "app": "app1"}
# Rota de health check — usada pelo Docker healthcheck e pelo Nginx
# Retorna 200 com JSON simples

@app.get("/text")
def get_text():
    return {
        "message": "Hello from App 1!",
        "app": "app1",
        "language": "Python",
        "framework": "FastAPI",
    }
# Rota de texto fixo — demonstra que a app responde corretamente
# Esse endpoint é cacheado pelo Nginx por 10 segundos

@app.get("/time")
def get_time():
    return {
        "time": datetime.now().isoformat(),
        # ^ isoformat() retorna string no formato ISO 8601: "2024-03-18T10:30:00.123456"
        # É o padrão internacional para timestamps em APIs REST
        "app": "app1",
    }
# Retorna o horário atual do servidor
# Também cacheado por 10s — depois do TTL, a próxima req busca horário novo
```

### `app1/Dockerfile`

```dockerfile
FROM python:3.12-slim
# Imagem base oficial Python 3.12 "slim" — versão mínima sem ferramentas extras
# ~45MB vs ~900MB da imagem completa. Suficiente para rodar FastAPI.

WORKDIR /app
# Define /app como diretório de trabalho. Todos os comandos seguintes
# são executados a partir daqui. Cria o diretório se não existir.

RUN groupadd --system appgroup && useradd --system --gid appgroup appuser
# Cria um grupo e usuário de sistema (sem shell, sem home) para rodar a app
# --system: UID < 1000, não aparece no login. Boa prática de segurança:
# nunca rode containers como root em produção.

COPY requirements.txt .
# Copia apenas o requirements.txt ANTES do código.
# Razão: Docker cacheia cada layer. Se o requirements.txt não mudou,
# o pip install não roda de novo — economiza tempo no build.

RUN pip install --no-cache-dir -r requirements.txt
# --no-cache-dir: não salva cache do pip dentro da imagem
# Reduz o tamanho final da imagem

COPY main.py .
# Copia o código-fonte. Fica em layer separada do pip install
# (estratégia de cache: código muda frequentemente, dependências não)

RUN chown -R appuser:appgroup /app
# Transfere a posse dos arquivos para o usuário não-root criado acima
# Necessário pois o COPY acima cria arquivos como root

USER appuser
# A partir daqui, todos os comandos (incluindo CMD) rodam como appuser
# Se alguém invadir a app, não terá acesso root ao container/host

EXPOSE 8000
# Documenta que a app escuta na porta 8000 (não abre a porta — só documenta)

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
# Comando padrão ao iniciar o container
# main:app = arquivo main.py, objeto app
# --host 0.0.0.0 = aceita conexões de qualquer interface (necessário em container)
# --port 8000 = porta interna do container
```

### `app1/test_main.py`

```python
import pytest
from fastapi.testclient import TestClient
# TestClient: cliente HTTP síncrono do Starlette que roda a app em memória
# Não precisa de servidor rodando — os testes são rápidos e isolados
from main import app

client = TestClient(app)
# Instancia o cliente uma vez para todos os testes

def test_health():
    r = client.get("/health")
    assert r.status_code == 200          # Verifica HTTP 200 OK
    body = r.json()
    assert body["status"] == "ok"        # Verifica campo específico
    assert body["app"] == "app1"

def test_text():
    r = client.get("/text")
    assert r.status_code == 200
    body = r.json()
    assert "message" in body            # Verifica que o campo existe
    assert body["app"] == "app1"
    assert body["language"] == "Python"
    assert body["framework"] == "FastAPI"

def test_time():
    r = client.get("/time")
    assert r.status_code == 200
    body = r.json()
    assert "time" in body
    assert body["app"] == "app1"
    from datetime import datetime
    datetime.fromisoformat(body["time"])
    # ^ Tenta fazer parse do campo "time" como ISO 8601
    # Se o formato estiver errado, lança ValueError e o teste falha
    # Garante que a app retorna um timestamp válido, não uma string qualquer
```

---

## 3. App 2 — Node.js / Express

### `app2/package.json` (principais campos)

```json
{
  "name": "app2",
  "version": "1.0.0",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "test": "node --test app2.test.js"
    // node --test: test runner nativo do Node.js (sem Jest, sem Mocha)
    // Disponível desde Node.js 18. Zero dependências extras para testes.
  },
  "dependencies": {
    "express": "^4.18.2",    // Framework web minimalista para Node.js
    "prom-client": "^15.1.0" // Cliente Prometheus oficial para Node.js
  }
}
```

### `app2/index.js`

```javascript
'use strict';
// Ativa o modo estrito do JavaScript:
// - Proíbe variáveis não declaradas
// - Erros silenciosos viram exceções
// - Melhora performance em alguns engines

const express = require('express');
const client = require('prom-client');

const app = express();
const PORT = process.env.PORT || 3001;
// Lê a porta da variável de ambiente PORT.
// Se não definida, usa 3001. Boa prática: configuração via env.

// ── Prometheus metrics ────────────────────────────────────────
const register = new client.Registry();
// Registry: coleção de métricas. Criamos um separado (não o default)
// para evitar conflitos se múltiplas instâncias rodarem no mesmo processo

client.collectDefaultMetrics({ register });
// Coleta métricas padrão do Node.js automaticamente:
// - process_cpu_seconds_total (uso de CPU)
// - process_resident_memory_bytes (uso de memória)
// - nodejs_eventloop_lag_seconds (lag do event loop)
// - nodejs_active_handles_total (handles ativos)

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total de requisições HTTP',
  labelNames: ['method', 'route', 'status'],
  // Labels permitem filtrar no Prometheus:
  // http_requests_total{method="GET", route="/text", status="200"}
  registers: [register],
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duração das requisições HTTP em segundos',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1],
  // Buckets definem os "baldes" do histograma em segundos:
  // 1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s
  // Permite calcular percentis: p50, p95, p99 de latência
  registers: [register],
});

// Middleware: instrumenta todas as rotas
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  // startTimer() inicia a medição de tempo e retorna função para finalizar

  res.on('finish', () => {
    // 'finish' dispara quando a resposta foi completamente enviada ao cliente
    const route = req.route ? req.route.path : req.path;
    // req.route.path = rota registrada (ex: "/text")
    // req.path = URL real (fallback se rota não foi matched)
    const labels = { method: req.method, route, status: res.statusCode };
    httpRequestsTotal.inc(labels);  // Incrementa o contador
    end(labels);                    // Finaliza o timer e registra no histograma
  });
  next(); // Passa para o próximo middleware/rota
});

app.get('/health', (_req, res) => {
  // _req: convenção para parâmetro não usado (underscore = "ignorado")
  res.json({ status: 'ok', app: 'app2' });
});

app.get('/text', (_req, res) => {
  res.json({
    message: 'Hello from App 2!',
    app: 'app2',
    language: 'Node.js',
    framework: 'Express',
  });
});

app.get('/time', (_req, res) => {
  res.json({
    time: new Date().toISOString(),
    // toISOString(): formato "2024-03-18T10:30:00.000Z"
    // 'Z' indica UTC — padrão para APIs REST
    app: 'app2',
  });
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  // Seta o Content-Type correto para o Prometheus entender
  // Exemplo: "text/plain; version=0.0.4; charset=utf-8"
  res.end(await register.metrics());
  // register.metrics() retorna todas as métricas serializadas
  // no formato texto do Prometheus (exposition format)
});

if (require.main === module) {
  // require.main === module: verdadeiro SOMENTE quando este arquivo
  // é executado diretamente (node index.js)
  // Falso quando é importado em outro arquivo (require('./index'))
  // Isso permite que os testes importem o app SEM iniciar o servidor
  app.listen(PORT, () => {
    console.log(`App 2 listening on port ${PORT}`);
  });
}

module.exports = app;
// Exporta o app para que os testes possam importar e fazer requisições
```

### `app2/Dockerfile`

```dockerfile
FROM node:20-alpine
# node:20 LTS (Long Term Support) na variante Alpine Linux
# Alpine = ~5MB vs ~200MB do Debian. Ideal para produção.
# LTS = suporte até 2026. Não use versões "current" em produção.

WORKDIR /app

COPY package*.json ./
# Copia package.json E package-lock.json (se existir) com um glob
# Importante: package-lock.json garante versões exatas das dependências

RUN npm install --omit=dev
# --omit=dev: instala apenas dependências de produção (não devDependencies)
# Reduz o tamanho da imagem e a superfície de ataque
# Nota: não usamos "npm ci" pois não temos package-lock.json

COPY index.js .

RUN chown -R node:node /app
# A imagem node:alpine já vem com o usuário "node" (uid=1000)
# Transferimos a propriedade dos arquivos para ele

USER node
# Roda a app como usuário não-root "node"

EXPOSE 3001

CMD ["node", "index.js"]
# Inicia diretamente com node (não npm start) — mais eficiente:
# npm adicionaria um processo intermediário desnecessário
```

### `app2/app2.test.js`

```javascript
'use strict';

const { test, after } = require('node:test');
// test: função para definir um caso de teste
// after: hook que roda após todos os testes (teardown)
const assert = require('node:assert/strict');
// assert/strict: versão estrita — === em vez de ==
const http = require('node:http');
// http nativo do Node — sem dependências externas para fazer requests

const app = require('./index');
// Importa o app SEM iniciar o servidor
// (graças ao "if (require.main === module)" em index.js)

let server;
let baseUrl;

const serverReady = new Promise((resolve) => {
  server = app.listen(0, () => {
    // Porta 0 = sistema operacional escolhe uma porta livre aleatória
    // Evita conflitos se vários testes rodarem em paralelo
    const { port } = server.address();
    baseUrl = `http://localhost:${port}`;
    resolve();
  });
});
// Promise que resolve quando o servidor está pronto para receber conexões

function get(path) {
  return new Promise((resolve, reject) => {
    http.get(`${baseUrl}${path}`, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      // Acumula os chunks da resposta
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
          // Tenta fazer parse do JSON — se falhar, retorna a string raw
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    }).on('error', reject);
  });
}

test('GET /health retorna status ok', async () => {
  await serverReady; // Garante que o servidor está pronto antes do teste
  const { status, body } = await get('/health');
  assert.equal(status, 200);
  assert.equal(body.status, 'ok');
  assert.equal(body.app, 'app2');
});

// ... outros testes omitidos (mesma estrutura)

after(() => {
  if (server) {
    server.closeAllConnections?.();
    // closeAllConnections(): fecha conexões keep-alive pendentes
    // O ?. (optional chaining) é compatibilidade: disponível desde Node 18.2
    // Sem isso, o processo do Node ficaria "pendurado" após os testes
    server.close();
    // Fecha o servidor (para de aceitar novas conexões)
  }
});
// Sem o after(), o runner ficaria rodando indefinidamente
// esperando o servidor fechar (open handle)
```

---

## 4. Nginx — Reverse Proxy + Cache + Rate Limiting

### `nginx/nginx.conf`

```nginx
worker_processes auto;
# auto = um worker process por CPU core
# Para e2-medium (2 vCPUs) = 2 workers

error_log /var/log/nginx/error.log warn;
# Loga erros de nível "warn" ou superior (warn, error, crit, alert, emerg)
# "notice" e "info" são ignorados em produção para não poluir os logs

pid /var/run/nginx.pid;
# Arquivo onde o Nginx escreve seu PID (Process ID)
# Usado pelo sistema para sinalizar o processo (ex: reload, stop)

events {
    worker_connections 1024;
    # Cada worker pode manter até 1024 conexões simultâneas
    # Total máximo = worker_processes × worker_connections = 2048
}

http {
    include /etc/nginx/mime.types;
    # Carrega o mapeamento de extensões para Content-Type
    # Ex: .html → text/html, .js → application/javascript

    default_type application/octet-stream;
    # Content-Type padrão para tipos desconhecidos

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent '
                    'cache=$upstream_cache_status '
                    'rt=$upstream_response_time';
    # Formato personalizado de log que inclui:
    # $upstream_cache_status = HIT, MISS, BYPASS, EXPIRED, etc.
    # $upstream_response_time = tempo que o backend levou para responder

    # ── Rate Limiting ────────────────────────────────────────────
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    # $binary_remote_addr: chave = IP do cliente em formato binário (4 bytes)
    #   mais eficiente que $remote_addr (string)
    # zone=api_limit:10m: zona de memória compartilhada de 10MB
    #   1MB armazena ~16.000 IPs. 10MB = ~160.000 IPs
    # rate=10r/s: 10 requisições por segundo por IP

    limit_req_status 429;
    # HTTP 429 = Too Many Requests (padrão RFC 6585)

    # ── Cache App 1 — TTL: 10 segundos ──────────────────────────
    proxy_cache_path /var/cache/nginx/app1
        levels=1:2
        # Estrutura de diretórios: 1 nível de 1 char + 1 nível de 2 chars
        # Evita muitos arquivos no mesmo diretório (performance do filesystem)
        keys_zone=app1_cache:10m
        # Nome da zona de memória compartilhada e tamanho (10MB para metadados)
        # 10MB suporta ~80.000 chaves de cache
        max_size=100m
        # Tamanho máximo do cache em disco. Nginx remove entradas antigas
        # automaticamente quando atinge o limite (LRU)
        inactive=30s
        # Remove entradas não acessadas por 30 segundos
        # Importante: separado do TTL. Uma entrada pode expirar por inatividade
        # mesmo antes do TTL (10s) se ninguém requisitar
        use_temp_path=off;
        # Escreve diretamente no diretório final (sem tmp intermediário)
        # Mais eficiente em sistemas de arquivos modernos

    # ── Cache App 2 — TTL: 1 minuto ─────────────────────────────
    proxy_cache_path /var/cache/nginx/app2
        levels=1:2
        keys_zone=app2_cache:10m
        max_size=100m
        inactive=5m    # 5 minutos de inatividade (> TTL de 60s)
        use_temp_path=off;

    upstream app1 {
        server app1:8000;
        # "app1" é resolvido pelo DNS interno do Docker
        # Docker resolve nomes de serviço via rede bridge
    }

    upstream app2 {
        server app2:3001;
    }

    server {
        listen 80;
        server_name localhost;

        location /health {
            return 200 '{"status":"ok","service":"nginx"}';
            add_header Content-Type application/json;
            # Responde diretamente sem bater nos backends
            # Usado pelo smoke test e pelo Docker healthcheck
        }

        location /nginx_status {
            stub_status on;
            # Ativa o módulo stub_status que expõe:
            # - Active connections
            # - Total accepts/handled/requests
            # - Reading/Writing/Waiting connections
            allow 127.0.0.1;    # Permite localhost
            allow 172.0.0.0/8;  # Permite rede Docker interna (172.x.x.x)
            deny all;           # Bloqueia todo o resto
            # nginx-prometheus-exporter acessa este endpoint para coletar métricas
        }

        location /app1/ {
            limit_req zone=api_limit burst=20 nodelay;
            # burst=20: permite burst de até 20 requisições acima do rate limit
            # nodelay: não enfileira as requisições — rejeita imediatamente
            # Com nodelay: req 1-20 do burst passam instantaneamente,
            # a 21ª recebe 429 na hora (sem esperar na fila)

            proxy_pass http://app1/;
            # A barra no final é crucial: /app1/text → /text (remove o prefixo)
            # Sem a barra: /app1/text → /app1/text (backend receberia /app1/text)

            proxy_cache app1_cache;
            proxy_cache_valid 200 10s;
            # Respostas HTTP 200 são cacheadas por 10 segundos
            proxy_cache_valid 404 1s;
            # 404s são cacheados por 1 segundo (evita hammering no backend)

            proxy_cache_key "$scheme$request_method$host$request_uri";
            # Chave única do cache: https + GET + localhost + /app1/text
            # Garante que GET e POST não compartilham cache

            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            # Se o backend falhar, serve a versão stale (expirada) do cache
            # "updating": se outra req já está buscando dados novos, serve o stale
            # Isso garante disponibilidade mesmo com backend lento/com erro

            proxy_cache_lock on;
            # Apenas UMA requisição por vez busca do backend para a mesma chave
            # As outras esperam o resultado (evita "thundering herd")

            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            # Headers padrão de reverse proxy:
            # X-Real-IP: IP real do cliente (o backend vê o IP do Nginx sem isso)
            # X-Forwarded-For: lista de proxies pelo caminho

            add_header X-Cache-Status $upstream_cache_status;
            # Adiciona header na resposta indicando: HIT, MISS, EXPIRED, etc.
            # Essencial para testar e demonstrar que o cache está funcionando
            add_header X-Cache-TTL "10s";
            add_header X-App "app1";
        }

        location /app2/ {
            # Mesma lógica do app1, mas com:
            proxy_cache app2_cache;
            proxy_cache_valid 200 60s;  # TTL de 60 segundos (1 minuto)
            # ... demais diretivas idênticas ao /app1/
        }
    }
}
```

---

## 5. Docker Compose — Produção

### `docker-compose.prod.yml`

```yaml
services:

  app1:
    image: ${REGISTRY}/app1:latest
    # REGISTRY é lido do arquivo .env na VM
    # Exemplo: us-central1-docker.pkg.dev/meu-projeto/devops-challenge/app1:latest
    container_name: app1     # Nome fixo — facilita logs e debugging
    restart: unless-stopped  # Reinicia automaticamente se cair
                             # Exceto se parado manualmente (docker stop)
    user: "appuser"          # Roda como usuário não-root (definido no Dockerfile)
    networks:
      - backend    # Rede para comunicação com Nginx
      - monitoring # Rede para o Prometheus coletar métricas em :8000/metrics
    deploy:
      resources:
        limits:
          cpus: "0.5"    # Máximo 50% de 1 CPU
          memory: 256M   # Máximo 256MB de RAM
          # Sem limites: um vazamento de memória derruba a VM inteira
          # Com limites: o container é morto e reiniciado (restart: unless-stopped)

  app2:
    image: ${REGISTRY}/app2:latest
    user: "node"         # Usuário não-root nativo da imagem node:alpine
    # ... (mesma estrutura do app1)

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"          # Expõe a porta 80 para a internet
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      # :ro = read-only. O container não pode modificar o arquivo de configuração.
      - nginx_cache:/var/cache/nginx
      # Volume Docker para persistir o cache entre reinícios do container
    depends_on:
      app1:
        condition: service_healthy  # Aguarda app1 passar no healthcheck
      app2:
        condition: service_healthy  # Aguarda app2 passar no healthcheck
      # Sem isso, Nginx iniciaria antes dos backends e daria 502

  nginx-exporter:
    image: nginx/nginx-prometheus-exporter:latest
    command: --nginx.scrape-uri=http://nginx/nginx_status
    # Raspa o endpoint /nginx_status do Nginx a cada 15s
    # e expõe na porta 9113 no formato Prometheus
    # Métricas: nginx_connections_active, nginx_http_requests_total, etc.

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--web.enable-lifecycle"
        # Permite recarregar config via HTTP POST /-/reload (sem reiniciar)
      - "--storage.tsdb.retention.time=7d"
        # Mantém dados dos últimos 7 dias. Após isso, deleta automaticamente.

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD:-admin}
        # Lê a senha do .env. Se não definida, usa "admin" como padrão
        # ${VAR:-default} = sintaxe bash de valor padrão
      - GF_USERS_ALLOW_SIGN_UP=false
        # Desabilita registro de novos usuários pela interface web
      - GF_ANALYTICS_REPORTING_ENABLED=false
        # Desabilita envio de telemetria anônima para a Grafana Inc.
    volumes:
      - ./observability/grafana/provisioning:/etc/grafana/provisioning:ro
        # Provisioning = configuração automática ao iniciar o Grafana
        # Carrega datasources e dashboards automaticamente (sem clicar na UI)

networks:
  backend:
    driver: bridge    # Rede isolada para app1, app2, nginx
  monitoring:
    driver: bridge    # Rede isolada para prometheus, grafana, exporters

volumes:
  nginx_cache:        # Persiste cache do Nginx entre reinícios
  prometheus_data:    # Persiste séries temporais do Prometheus
  grafana_data:       # Persiste dashboards criados manualmente e configurações
```

---

## 6. Observabilidade — Prometheus + Grafana

### `observability/prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  # A cada 15 segundos, o Prometheus "raspa" (scrape) todos os targets
  evaluation_interval: 15s
  # A cada 15 segundos, avalia as regras de alertas (se configuradas)

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
    # Prometheus monitora a si mesmo. Métricas: uso de memória,
    # número de séries ativas, tempo de scrape, etc.

  - job_name: "nginx"
    static_configs:
      - targets: ["nginx-exporter:9113"]
    # nginx-exporter é o container que converte /nginx_status em métricas Prometheus
    # "nginx-exporter" é resolvido pelo DNS Docker

  - job_name: "app1"
    static_configs:
      - targets: ["app1:8000"]
    metrics_path: /metrics
    # Acessa http://app1:8000/metrics
    # Métricas: http_requests_total, http_request_duration_seconds

  - job_name: "app2"
    static_configs:
      - targets: ["app2:3001"]
    metrics_path: /metrics
    # Acessa http://app2:3001/metrics
```

### `observability/grafana/provisioning/datasources/datasource.yml`

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus       # ID único — referenciado nos dashboards JSON
    access: proxy
    # proxy: o servidor Grafana faz a requisição ao Prometheus
    # (não o browser do usuário). Necessário para redes internas.
    url: http://prometheus:9090
    # "prometheus" é resolvido pelo DNS Docker
    isDefault: true       # Datasource padrão ao criar novos painéis
    editable: true        # Permite edição pela interface web
```

### `observability/grafana/provisioning/dashboards/dashboards.yml`

```yaml
apiVersion: 1
providers:
  - name: default
    folder: DevOps Challenge   # Agrupa os dashboards nesta pasta no Grafana
    type: file
    disableDeletion: false      # Permite deletar pela UI (mas volta no restart)
    updateIntervalSeconds: 10   # Verifica novos arquivos a cada 10 segundos
    options:
      path: /etc/grafana/provisioning/dashboards
      # Grafana lê todos os .json neste diretório e importa automaticamente
```

---

## 7. Infraestrutura — Terraform (GCP)

### `infra/terraform/main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  # Garante que a versão do Terraform seja compatível com a sintaxe usada

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
      # ~> 5.0 = "pessimistic constraint": aceita 5.x mas não 6.0
      # Evita breaking changes ao atualizar providers automaticamente
    }
  }

  backend "gcs" {}
  # Backend remoto no Google Cloud Storage
  # Estado do Terraform fica em um bucket GCS (compartilhado entre setup.sh e CI/CD)
  # As configurações (bucket, prefix) são passadas via -backend-config
  # para não hardcodar o projeto no código
}

provider "google" {
  project = var.project_id
  region  = var.region
  # Autenticação via GOOGLE_APPLICATION_CREDENTIALS (env var)
  # ou Application Default Credentials
}

# ── APIs do GCP ──────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",          # GCE (Virtual Machines)
    "artifactregistry.googleapis.com", # Artifact Registry (Docker)
    "cloudbuild.googleapis.com",       # Cloud Build (build de imagens)
  ])
  service            = each.key
  disable_on_destroy = false
  # false: ao destruir a infra, NÃO desativa as APIs
  # Desativar APIs pode quebrar outros projetos dependentes
}

# ── Artifact Registry ────────────────────────────────────────
resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = var.repo_name     # "devops-challenge"
  format        = "DOCKER"
  description   = "Docker images — DevOps Challenge"
  depends_on    = [google_project_service.apis]
  # depends_on: garante que a API artifactregistry.googleapis.com
  # esteja habilitada ANTES de tentar criar o repositório
}

# ── Firewall ─────────────────────────────────────────────────
resource "google_compute_firewall" "allow_app" {
  name    = "devops-challenge-allow"
  network = "default"               # VPC padrão do GCP

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "3000", "9090"]
    # 22:   SSH (para deploy e debugging)
    # 80:   HTTP (Nginx → apps)
    # 3000: Grafana
    # 9090: Prometheus
  }

  source_ranges = ["0.0.0.0/0"]    # Qualquer IP da internet
  target_tags   = ["devops-challenge"]
  # A regra aplica SOMENTE às VMs com a tag "devops-challenge"
  # (a VM abaixo tem essa tag)
}

# ── VM GCE ───────────────────────────────────────────────────
resource "google_compute_instance" "vm" {
  name         = "devops-challenge-vm"
  machine_type = var.machine_type   # e2-medium: 2 vCPU, 4GB RAM
  zone         = var.zone           # us-central1-a
  tags         = ["devops-challenge"]  # Aplica a regra de firewall acima

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"  # Debian Bookworm (LTS)
      size  = 20                        # 20GB de disco
      type  = "pd-standard"             # HDD padrão (mais barato que SSD)
    }
  }

  network_interface {
    network = "default"
    access_config {}
    # access_config vazio = IP externo efêmero (atribuído automaticamente)
    # O IP muda se a VM for reiniciada. Para IP fixo, usar
    # google_compute_address (Static IP), que tem custo adicional.
  }

  metadata = {
    region         = var.region
    repo_name      = var.repo_name
    startup-script = file("${path.module}/../scripts/startup.sh")
    # startup-script: chave especial do GCP que executa o script
    # automaticamente na primeira inicialização da VM
    # O script lê "region" e "repo_name" do metadata server (evita
    # problemas de escaping de variáveis bash vs Terraform)
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    # cloud-platform scope: acesso completo às APIs GCP
    # Necessário para: gcloud auth configure-docker, docker pull do Artifact Registry
    # Em produção real, usar scopes mais granulares por segurança
  }

  depends_on = [
    google_project_service.apis,
    google_artifact_registry_repository.docker_repo,
    # Garante que o registry existe antes da VM tentar fazer pull das imagens
  ]
}
```

### `infra/terraform/variables.tf`

```hcl
variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
  # Sem default — obrigatório. Terraform falha se não fornecido.
}

variable "region" {
  type    = string
  default = "us-central1"   # Iowa — menor latência para América do Sul
}

variable "zone" {
  type    = string
  default = "us-central1-a" # Zona específica dentro da região
}

variable "machine_type" {
  type    = string
  default = "e2-medium"
  # e2-medium: 2 vCPUs, 4GB RAM, ~$33/mês
  # Suficiente para rodar 6 containers (app1, app2, nginx, exporter, prometheus, grafana)
}

variable "repo_name" {
  type    = string
  default = "devops-challenge"
}
```

### `infra/terraform/outputs.tf`

```hcl
output "vm_ip" {
  value = google_compute_instance.vm.network_interface[0].access_config[0].nat_ip
  # nat_ip = IP externo (NAT = Network Address Translation)
  # [0] = primeiro elemento da lista (só temos uma interface e um access_config)
}

output "artifact_registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo_name}"
  # Exemplo: us-central1-docker.pkg.dev/meu-projeto/devops-challenge
}

# Outputs de conveniência — usados no step summary do CI/CD
output "app1_text" { value = "http://${...nat_ip}/app1/text" }
output "app1_time" { value = "http://${...nat_ip}/app1/time" }
# ... demais outputs omitidos (mesma estrutura)

output "ssh_command" {
  value = "gcloud compute ssh devops-challenge-vm --zone=${var.zone} --project=${var.project_id}"
  # Comando pronto para copiar e colar para SSH na VM
}
```

---

## 8. Startup Script — Inicialização da VM

### `infra/scripts/startup.sh`

```bash
#!/bin/bash
set -euo pipefail
# set -e: para o script se qualquer comando retornar erro
# set -u: erro se usar variável não definida
# set -o pipefail: pipe falha se qualquer comando do pipe falhar
# Exemplo: cmd1 | cmd2 — sem pipefail, erros de cmd1 são ignorados

log() { echo "[$(date '+%H:%M:%S')] [startup] $1" | tee -a /var/log/startup.log; }
# Loga no stdout E em /var/log/startup.log simultaneamente (tee -a = append)
# O GCP coleta o stdout automaticamente no Cloud Logging

# ── Lê variáveis do Metadata Server ────────────────────────
META="http://metadata.google.internal/computeMetadata/v1"
HEADER="Metadata-Flavor: Google"
# O Metadata Server é uma API HTTP disponível apenas dentro da VM GCE
# Fornece informações sobre o projeto, instância, service account, etc.
# O header "Metadata-Flavor: Google" é obrigatório (proteção SSRF)

PROJECT_ID=$(curl -sf "$META/project/project-id" -H "$HEADER")
REGION=$(curl -sf     "$META/instance/attributes/region"    -H "$HEADER" || echo "us-central1")
REPO_NAME=$(curl -sf  "$META/instance/attributes/repo_name" -H "$HEADER" || echo "devops-challenge")
REPO_URL=$(curl -sf   "$META/instance/attributes/repo_url"  -H "$HEADER" || echo "https://github.com/...")
# "attributes/" = metadados customizados definidos no Terraform (metadata block)
# Lemos daqui para evitar problemas de escaping de variáveis no Terraform HCL

# ── Instala Docker ──────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
# Evita prompts interativos durante apt-get install

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git
# ca-certificates: certificados SSL (necessário para HTTPS)
# gnupg: para verificar assinatura do repositório Docker

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
# Adiciona a chave GPG do repositório oficial Docker
# gpg --dearmor: converte de ASCII armored para binário
# Verifica que os pacotes são genuinamente da Docker Inc.

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
# Adiciona o repositório oficial Docker para Debian
# $VERSION_CODENAME = "bookworm" (Debian 12)

apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
# docker-ce: Docker Engine (Community Edition)
# docker-compose-plugin: plugin que permite "docker compose" (v2)

systemctl enable docker  # Inicia Docker automaticamente no boot
systemctl start docker   # Inicia Docker agora

# ── Autentica no Artifact Registry ─────────────────────────
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
# Configura o Docker para usar as credenciais do service account da VM
# quando fazer pull de imagens do Artifact Registry
# O service account tem acesso via scope "cloud-platform"

# ── Clona o repositório ─────────────────────────────────────
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
  # --ff-only: só aceita fast-forward (sem merge commits)
  # Se houver divergência, falha — mais seguro em produção
else
  git clone "$REPO_URL" "$APP_DIR"
fi

# ── Aguarda imagens no Artifact Registry ───────────────────
for i in $(seq 1 30); do
  if docker pull "$REGISTRY/app1:latest" >/dev/null 2>&1 && \
     docker pull "$REGISTRY/app2:latest" >/dev/null 2>&1; then
    break
  fi
  sleep 20
  # Aguarda até 10 minutos (30 × 20s) pelo CI/CD fazer o build e push das imagens
  # Isso é necessário porque a VM sobe ANTES do CI/CD terminar o build
done

# ── Sobe o Docker Compose ───────────────────────────────────
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d --remove-orphans
# --remove-orphans: remove containers de serviços que foram removidos do compose
```

---

## 9. CI/CD — GitHub Actions

### `.github/workflows/ci-cd.yml`

```yaml
name: CI/CD Pipeline

on:
  push:
    branches: [main]        # Roda em todo push para a branch main
  pull_request:
    branches: [main]        # Roda em PRs para a main (só testes, sem deploy)

env:
  REGION:  us-central1
  ZONE:    us-central1-a
  REPO:    devops-challenge
  VM_NAME: devops-challenge-vm
  # Variáveis globais disponíveis em todos os jobs

# ════════════════════════════════════════════════════════════
# JOB 1 — Testes + Dependency Security Check
# ════════════════════════════════════════════════════════════
jobs:
  test:
    runs-on: ubuntu-latest   # Runner Linux gerenciado pelo GitHub

    steps:
      - uses: actions/checkout@v4
        # Clona o repositório no runner

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Testar App 1 (Python/FastAPI)
        run: |
          cd app1
          pip install -r requirements.txt "httpx<0.28" pytest
          pytest test_main.py -v
          # -v: verbose — mostra o nome de cada teste

      - name: Verificar vulnerabilidades Python (pip-audit)
        run: |
          pip install pip-audit
          cd app1
          pip-audit -r requirements.txt --desc on || true
          # --desc on: mostra descrição de cada vulnerabilidade
          # || true: não falha o pipeline (aviso, não bloqueio)
          # Em produção real: remover || true para bloquear CVEs críticos

      - name: Testar App 2 (Node.js/Express)
        run: |
          cd app2
          npm install    # Instala dependências incluindo devDependencies
          npm test       # Executa: node --test app2.test.js

      - name: Verificar vulnerabilidades Node.js (npm audit)
        run: |
          cd app2
          npm audit --audit-level=critical || true
          # --audit-level=critical: só falha para vulnerabilidades CRÍTICAS
          # (HIGH, MODERATE, LOW são apenas avisos)

# ════════════════════════════════════════════════════════════
# JOB 2 — Build, Push e Scan de Segurança de Imagens
# ════════════════════════════════════════════════════════════
  build:
    needs: test
    # Só roda se o job "test" passar — gates de qualidade
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    # Só em push para main (não em PRs — sem credenciais GCP)

    permissions:
      security-events: write   # Necessário para upload de SARIF ao GitHub Security
      contents: read

    steps:
      - uses: google-github-actions/auth@v2
        with:
          credentials_json: ${{ secrets.GCP_CREDENTIALS }}
          # GCP_CREDENTIALS = conteúdo do credentials.json (service account key)
          # Armazenado como GitHub Secret (criptografado)

      - uses: google-github-actions/setup-gcloud@v2
        # Instala e configura o gcloud CLI no runner

      - name: Build e push App 1
        env:
          REGISTRY: ${{ env.REGION }}-docker.pkg.dev/${{ secrets.GCP_PROJECT_ID }}/${{ env.REPO }}
        run: |
          docker build -t $REGISTRY/app1:latest -t $REGISTRY/app1:${{ github.sha }} ./app1
          # Duas tags: :latest (sempre atualizada) e :sha do commit (imutável)
          # O sha permite rollback para qualquer versão anterior
          docker push $REGISTRY/app1:latest
          docker push $REGISTRY/app1:${{ github.sha }}

      - name: Instalar Trivy
        run: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
        # Trivy: scanner de vulnerabilidades open source da Aqua Security
        # Verifica CVEs em imagens Docker (sistema operacional + dependências)

      - name: Scan de vulnerabilidades — App 1 (Trivy → SARIF)
        run: |
          TOKEN=$(gcloud auth print-access-token)
          # Obtém token OAuth2 do service account autenticado
          trivy image \
            --username oauth2accesstoken \
            --password "$TOKEN" \
            # Autentica no Artifact Registry para fazer pull da imagem privada
            --severity CRITICAL,HIGH \
            # Filtra apenas vulnerabilidades de alta criticidade
            --exit-code 0 \
            # 0 = não falha o pipeline mesmo se encontrar vulnerabilidades
            # (1 = falharia). Mudamos para 0 para ser informativo, não bloqueante.
            --format sarif \
            --output trivy-app1.sarif \
            "$REGISTRY/app1:latest"
            # SARIF = Static Analysis Results Interchange Format (JSON padronizado)
            # Aceito pelo GitHub Security tab, Azure DevOps, etc.

      - name: Publicar App 1 no GitHub Security tab
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        # always(): roda mesmo se o step anterior falhou
        # Garantimos que o relatório é publicado mesmo com erros
        with:
          sarif_file: trivy-app1.sarif
          category: trivy-app1
          # category: identificador único — evita conflito entre app1 e app2

# ════════════════════════════════════════════════════════════
# JOB 3 — Infraestrutura (Terraform) + Deploy via SSH
# ════════════════════════════════════════════════════════════
  deploy:
    needs: build

    steps:
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_wrapper: false
          # false: não envolve outputs em JSON.
          # Necessário para usar "terraform output -raw" no shell

      - name: Terraform — criar/manter infraestrutura
        env:
          GOOGLE_CREDENTIALS: ${{ secrets.GCP_CREDENTIALS }}
          # Terraform usa esta env var para autenticar no GCP
        run: |
          cd infra/terraform
          cat > terraform.tfvars <<EOF
          project_id = "$PROJECT"
          region     = "us-central1"
          zone       = "us-central1-a"
          repo_name  = "devops-challenge"
          EOF
          # terraform.tfvars: arquivo de valores das variáveis
          # Gerado dinamicamente para injetar o project_id do secret

          terraform init \
            -input=false \
            -backend-config="bucket=$PROJECT-tfstate" \
            -backend-config="prefix=devops-challenge"
          # Inicializa o Terraform com o backend GCS
          # O estado é compartilhado com o setup.sh local

          terraform apply -auto-approve -input=false
          # -auto-approve: não pede confirmação (necessário em CI/CD)
          # Se a VM existir: verifica se há mudanças (normalmente no-op)
          # Se não existir: cria toda a infraestrutura

          echo "VM_IP=$(terraform output -raw vm_ip)" >> $GITHUB_ENV
          # Salva o IP no ambiente do GitHub Actions
          # Disponível nos steps seguintes como $VM_IP

      - name: Aguardar VM estar pronta
        run: |
          for i in $(seq 1 40); do
            STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
              "http://$VM_IP/health" 2>/dev/null || echo "000")
            if [ "$STATUS" = "200" ]; then echo "VM pronta!"; exit 0; fi
            echo "Tentativa $i/40 (status=$STATUS)..."
            sleep 15
          done
          # Até 10 minutos (40 × 15s) para a VM inicializar
          # O startup script instala Docker, clona o repo e sobe a stack

      - name: Deploy via SSH
        run: |
          gcloud compute ssh $VM_NAME \
            --zone=$ZONE \
            --project=$PROJECT \
            --quiet \
            --ssh-flag="-o StrictHostKeyChecking=no" \
            # StrictHostKeyChecking=no: não verifica fingerprint do host
            # Necessário pois o IP pode mudar entre deploys
            --command="
              set -e
              sudo git config --global --add safe.directory /opt/app
              # Git 2.35.2+ recusa operar em repos com owner diferente do usuário atual
              # /opt/app pertence ao root (criado pelo startup script)
              # O SSH user é diferente — precisamos marcar como seguro

              cd /opt/app
              sudo git pull origin main          # Atualiza o código
              echo 'REGISTRY=...' | sudo tee .env  # Atualiza variáveis
              sudo gcloud auth configure-docker ... # Reautentica Docker
              sudo docker compose -f docker-compose.prod.yml pull  # Baixa imagens novas
              sudo docker compose -f docker-compose.prod.yml up -d --remove-orphans
              # up -d: modo detached (background)
              # --remove-orphans: remove containers de serviços deletados do compose
            "

# ════════════════════════════════════════════════════════════
# JOB 4 — Smoke Test (valida cache + endpoints após deploy)
# ════════════════════════════════════════════════════════════
  smoke-test:
    needs: deploy

    steps:
      - name: Smoke Test — endpoints e cache
        run: |
          # Verifica todos os endpoints retornam 200
          check() {
            local url=$1 expected=$2
            status=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$url")
            [ "$status" = "$expected" ] && echo "✔ $url" || { echo "✘ $url → $status"; FAIL=1; }
          }

          check "$BASE/health"      "200"
          check "$BASE/app1/text"   "200"
          check "$BASE/app1/time"   "200"
          # ... demais endpoints

          # Verifica cache MISS → HIT
          CACHE1=$(curl -sI "$BASE/app1/time" | grep -i x-cache-status)
          sleep 1
          CACHE2=$(curl -sI "$BASE/app1/time" | grep -i x-cache-status)
          # 1ª req: MISS (não estava no cache)
          # 2ª req: HIT (veio do cache, mesmo conteúdo, resposta mais rápida)
          echo "$CACHE2" | grep -qi "HIT" && echo "✔ Cache HIT confirmado!"
```

---

## 10. setup.sh — Deploy com Um Comando

### Fluxo completo

```bash
bash setup.sh
# │
# ├── Pré-requisitos
# │   ├── Verifica se credentials.json existe
# │   ├── Verifica se gcloud está instalado
# │   └── Verifica se terraform está instalado
# │
# ├── 1. Autenticação
# │   ├── gcloud auth activate-service-account  ← usa o credentials.json
# │   └── gcloud config set project $PROJECT_ID
# │
# ├── 2. APIs + Infraestrutura
# │   ├── gcloud services enable (APIs necessárias)
# │   ├── gsutil mb (cria bucket para estado Terraform)
# │   ├── terraform init -backend-config (conecta ao GCS)
# │   ├── terraform import (importa recursos já existentes)
# │   └── terraform apply (cria VM + Artifact Registry + Firewall)
# │
# ├── 3. Build e push das imagens
# │   ├── gcloud builds submit ./app1 (Cloud Build — sem Docker local)
# │   └── gcloud builds submit ./app2
# │
# ├── 4. Aguarda VM inicializar
# │   └── curl /health até retornar 200 (max 10 min)
# │
# └── Exibe URLs de acesso
```

### Por que Cloud Build em vez de Docker local?

```bash
gcloud builds submit ./app1 --tag "$REGISTRY/app1:latest"
# O Cloud Build:
# 1. Empacota o diretório ./app1 em um .tar.gz
# 2. Faz upload para um bucket GCS temporário
# 3. Inicia uma VM na nuvem para fazer o build
# 4. Faz push da imagem resultante para o Artifact Registry
# 5. Deleta a VM temporária
#
# Vantagens:
# - Não precisa do Docker Desktop instalado localmente
# - Build acontece na nuvem (não usa CPU/RAM local)
# - A VM já tem acesso ao Artifact Registry por default
```

---

## Resumo das Tecnologias

| Camada | Tecnologia | Por quê |
|--------|-----------|---------|
| App 1 | Python 3.12 + FastAPI | Performance, type hints, docs automáticos |
| App 2 | Node.js 20 LTS + Express | Ecossistema npm, I/O assíncrono |
| Cache | Nginx proxy_cache | Battle-tested, TTL configurável por rota |
| Rate Limiting | Nginx limit_req | Proteção DDoS simples e eficiente |
| Métricas | Prometheus | Padrão da indústria para observabilidade |
| Dashboard | Grafana | Visualização rica, auto-provisionado |
| Container | Docker + Compose | Portabilidade e simplicidade |
| Registry | GCP Artifact Registry | Integrado ao GCP, autenticação via SA |
| Infra como Código | Terraform | Reproduzível, versionado, idempotente |
| VM | GCE e2-medium | Custo-benefício para workloads variados |
| CI/CD | GitHub Actions | Integrado ao repositório, gratuito |
| Segurança | Trivy + pip-audit + npm audit | CVEs nas imagens e dependências |
| Segurança | GitHub Security tab (SARIF) | Relatórios padronizados e integrados |
| Dependências | Dependabot | Atualizações automáticas semanais |
| Container Security | Non-root user + resource limits | Boas práticas de segurança em produção |
