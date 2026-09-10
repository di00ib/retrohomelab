'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const APPS_DIR = process.env.APPS_DIR || '/apps';
const API_KEY = process.env.API_KEY || 'changeme';
const PORT = parseInt(process.env.PORT || '7845');

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

function setCors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type,X-API-Key');
}

function checkAuth(req) {
  return req.headers['x-api-key'] === API_KEY;
}

function jsonResp(res, code, data) {
  const body = JSON.stringify(data, null, 2);
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(body);
}

function scanApps() {
  const apps = [];
  try {
    for (const name of fs.readdirSync(APPS_DIR)) {
      const full = path.join(APPS_DIR, name);
      if (!fs.statSync(full).isDirectory()) continue;
      const metaPath = path.join(full, 'retro-launch.json');
      let meta = {};
      if (fs.existsSync(metaPath)) {
        try { meta = JSON.parse(fs.readFileSync(metaPath)); } catch(e) {}
      }
      const htmls = fs.readdirSync(full)
        .filter(f => f.endsWith('.html') || f.endsWith('.htm'));
      const entry = meta.entry || htmls.find(f =>
        f.toLowerCase() === 'index.html') || htmls[0];
      if (!entry) continue;
      apps.push({
        id: name,
        name: meta.name || name.replace(/[-_]/g, ' '),
        version: meta.version || '',
        description: meta.description || '',
        entry,
        tags: meta.tags || [],
        accentColor: meta.accentColor || null
      });
    }
  } catch(e) { log('ERROR: ' + e.message); }
  return apps;
}

const server = http.createServer((req, res) => {
  setCors(res);
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  const p = url.parse(req.url).pathname;
  log(`${req.method} ${p}`);

  if (p === '/health') {
    return jsonResp(res, 200, { status: 'ok', apps: scanApps().length });
  }
  if (!checkAuth(req)) {
    return jsonResp(res, 401, { error: 'Unauthorized' });
  }
  if (p === '/bundles') {
    return jsonResp(res, 200, { bundles: scanApps() });
  }
  res.writeHead(404); res.end('Not found');
});

server.listen(PORT, '0.0.0.0', () => {
  log(`RETRO-SERVER running on port ${PORT}`);
  log(`Apps dir: ${APPS_DIR}`);
});
