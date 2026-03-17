from fastapi import FastAPI
from datetime import datetime

app = FastAPI(title="App 1 - Python FastAPI")


@app.get("/health")
def health():
    return {"status": "ok", "app": "app1"}


@app.get("/text")
def get_text():
    return {
        "message": "Hello from App 1!",
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
