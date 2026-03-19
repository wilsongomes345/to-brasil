.PHONY: up down logs ps build test clean

## Sobe toda a stack (Nginx + App1 + App2 + Prometheus + Grafana)
up:
	docker compose up -d --build

## Para e remove os containers
down:
	docker compose down

## Exibe logs em tempo real
logs:
	docker compose logs -f

## Lista containers e status
ps:
	docker compose ps

## Constrói as imagens sem subir
build:
	docker compose build

## Roda os testes das duas aplicações
test:
	@echo "==> Testando App 1 (Python/FastAPI)..."
	cd app1 && pip install -q -r requirements.txt "httpx<0.28" pytest && pytest test_main.py -v
	@echo "==> Testando App 2 (Node.js/Express)..."
	cd app2 && npm install --silent && npm test

## Remove containers, volumes e imagens do projeto
clean:
	docker compose down -v --rmi local
