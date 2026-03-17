"""Testes da App 1 - Python FastAPI"""
import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["app"] == "app1"


def test_text():
    r = client.get("/text")
    assert r.status_code == 200
    body = r.json()
    assert "message" in body
    assert body["app"] == "app1"
    assert body["language"] == "Python"
    assert body["framework"] == "FastAPI"


def test_time():
    r = client.get("/time")
    assert r.status_code == 200
    body = r.json()
    assert "time" in body
    assert body["app"] == "app1"
    # Valida que o campo time é uma string ISO 8601
    from datetime import datetime
    datetime.fromisoformat(body["time"])
