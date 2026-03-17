'use strict';

const express = require('express');
const app = express();
const PORT = process.env.PORT || 3001;

app.get('/health', (_req, res) => {
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
    app: 'app2',
  });
});

// Só inicia o servidor se executado diretamente (não em testes)
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`App 2 listening on port ${PORT}`);
  });
}

module.exports = app;
