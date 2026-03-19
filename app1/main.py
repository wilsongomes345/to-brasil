from fastapi import FastAPI
from datetime import datetime
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(title="App 1 - Python FastAPI")

# Expõe /metrics automaticamente com métricas de request rate, latência, etc.
Instrumentator().instrument(app).expose(app, endpoint="/metrics")


@app.get("/health")
def health():
    return {"status": "ok", "app": "app1"}


@app.get("/text")
def get_text():
    return {
        "message": "Desafio devops!",
        "app": "app1",
        "language": "Python",
        "framework": "FastAPI",
    }


@app.get("/time")
def get_time():
    return {
        "time": datetime.now().isoformat(),
        "app": "app1",
    }
