// Testes da App 2 - Node.js Express
// Usa o test runner nativo do Node.js (>=18) — sem dependências extras
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

const app = require('./index');

// Inicia servidor em porta aleatória para os testes
let server;
let baseUrl;

// Setup: inicia servidor antes dos testes
const serverReady = new Promise((resolve) => {
  server = app.listen(0, () => {
    const { port } = server.address();
    baseUrl = `http://localhost:${port}`;
    resolve();
  });
});

// Helper para fazer requisições HTTP
function get(path) {
  return new Promise((resolve, reject) => {
    http.get(`${baseUrl}${path}`, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    }).on('error', reject);
  });
}

test('GET /health retorna status ok', async () => {
  await serverReady;
  const { status, body } = await get('/health');
  assert.equal(status, 200);
  assert.equal(body.status, 'ok');
  assert.equal(body.app, 'app2');
});

test('GET /text retorna mensagem e metadados', async () => {
  await serverReady;
  const { status, body } = await get('/text');
  assert.equal(status, 200);
  assert.ok(body.message);
  assert.equal(body.app, 'app2');
  assert.equal(body.language, 'Node.js');
  assert.equal(body.framework, 'Express');
});

test('GET /time retorna horário ISO 8601 válido', async () => {
  await serverReady;
  const { status, body } = await get('/time');
  assert.equal(status, 200);
  assert.ok(body.time);
  const parsed = new Date(body.time);
  assert.ok(!isNaN(parsed.getTime()), 'time deve ser uma data válida');
});

// Teardown: fecha servidor após os testes
process.on('exit', () => {
  if (server) server.close();
});
