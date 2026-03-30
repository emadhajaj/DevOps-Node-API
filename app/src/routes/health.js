const express = require('express');
const router = express.Router();

router.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: process.env.APP_VERSION || '1.0.0',
    environment: process.env.NODE_ENV || 'development',
  });
});

router.get('/info', (req, res) => {
  res.json({
    name: 'devops-node-api',
    uptime: process.uptime(),
    memory: process.memoryUsage(),
  });
});

module.exports = router;
