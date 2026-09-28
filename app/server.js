const express = require('express');
const os = require('os');

const app = express();
app.disable('x-powered-by');

const PORT = parseInt(process.env.PORT, 10) || 3000;
const HOST = process.env.HOST || '0.0.0.0';

app.get('/', (req, res) => {
  res.json({
    message: 'Hello from the DevOps test-task Node.js app',
    hostname: os.hostname(),
    podIP: process.env.POD_IP || null,
    time: new Date().toISOString(),
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

const server = app.listen(PORT, HOST, () => {
  console.log(`nodeapp listening on http://${HOST}:${PORT}`);
});

const shutdown = (signal) => () => {
  console.log(`Received ${signal}, shutting down.`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
};
process.on('SIGTERM', shutdown('SIGTERM'));
process.on('SIGINT', shutdown('SIGINT'));
