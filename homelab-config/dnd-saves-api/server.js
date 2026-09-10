'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const url = require('url');

const DATA_DIR = process.env.DATA_DIR || '/data';
const API_KEY = process.env.API_KEY || 'changeme';
const PORT = parseInt(process.env.PORT || '7846', 10);

function log(msg){ console.log(`[${new Date().toISOString()}] ${msg}`); }

function setCors(res){
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type,X-API-Key');
}
function checkAuth(req){ return req.headers['x-api-key'] === API_KEY; }
function jsonResp(res, code, data){
  const body = JSON.stringify(data, null, 2);
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(body);
}
function readBody(req){
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {}); }
      catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function ensureDataDir(){ if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true }); }
function gameDir(id){ return path.join(DATA_DIR, id); }
function savesDir(id){ return path.join(gameDir(id), 'saves'); }

function listGames(){
  ensureDataDir();
  const ids = fs.readdirSync(DATA_DIR).filter(f => {
    try { return fs.statSync(path.join(DATA_DIR, f)).isDirectory(); } catch (e) { return false; }
  });
  return ids.map(id => {
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(gameDir(id), 'meta.json')));
      return { id, ...meta };
    } catch (e) { return null; }
  }).filter(Boolean).sort((a, b) => (b.updatedAt || '').localeCompare(a.updatedAt || ''));
}

function createGame(name){
  ensureDataDir();
  const id = crypto.randomUUID();
  fs.mkdirSync(gameDir(id), { recursive: true });
  fs.mkdirSync(savesDir(id), { recursive: true });
  const now = new Date().toISOString();
  const meta = { name: name || 'Untitled Game', createdAt: now, updatedAt: now };
  fs.writeFileSync(path.join(gameDir(id), 'meta.json'), JSON.stringify(meta, null, 2));
  return { id, ...meta };
}

function touchGame(id){
  const metaPath = path.join(gameDir(id), 'meta.json');
  if (!fs.existsSync(metaPath)) return;
  const meta = JSON.parse(fs.readFileSync(metaPath));
  meta.updatedAt = new Date().toISOString();
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
}

function deleteGame(id){ fs.rmSync(gameDir(id), { recursive: true, force: true }); }

function modulesDir(){ return path.join(DATA_DIR, '_modules'); }
function ensureModulesDir(){ if (!fs.existsSync(modulesDir())) fs.mkdirSync(modulesDir(), { recursive: true }); }

function listModules(){
  ensureModulesDir();
  return fs.readdirSync(modulesDir()).filter(f => f.endsWith('.json')).map(f => {
    try {
      const data = JSON.parse(fs.readFileSync(path.join(modulesDir(), f)));
      return { id: f.replace(/\.json$/, ''), name: data.name, confidence: data.confidence, numPages: data.numPages, createdAt: data.createdAt };
    } catch (e) { return null; }
  }).filter(Boolean).sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
}
function createModule(payload){
  ensureModulesDir();
  const id = crypto.randomUUID();
  const data = Object.assign({}, payload, { createdAt: new Date().toISOString() });
  fs.writeFileSync(path.join(modulesDir(), id + '.json'), JSON.stringify(data, null, 2));
  return { id, ...data };
}
function getModule(id){
  const fp = path.join(modulesDir(), id + '.json');
  if (!fs.existsSync(fp)) return null;
  return JSON.parse(fs.readFileSync(fp));
}
function updateModule(id, patch){
  const existing = getModule(id);
  if (!existing) return null;
  const updated = Object.assign({}, existing, patch, { updatedAt: new Date().toISOString() });
  fs.writeFileSync(path.join(modulesDir(), id + '.json'), JSON.stringify(updated, null, 2));
  return updated;
}
function deleteModule(id){
  const fp = path.join(modulesDir(), id + '.json');
  if (fs.existsSync(fp)) fs.unlinkSync(fp);
}

function listSaves(id){
  const dir = savesDir(id);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter(f => f.endsWith('.json')).map(f => {
    try {
      const data = JSON.parse(fs.readFileSync(path.join(dir, f)));
      return { id: f.replace(/\.json$/, ''), label: data.label, savedAt: data.savedAt };
    } catch (e) { return null; }
  }).filter(Boolean).sort((a, b) => (b.savedAt || '').localeCompare(a.savedAt || ''));
}

const server = http.createServer(async (req, res) => {
  setCors(res);
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const parsed = url.parse(req.url, true);
  const p = parsed.pathname;
  log(`${req.method} ${p}`);

  if (p === '/health') return jsonResp(res, 200, { status: 'ok' });
  if (!checkAuth(req)) return jsonResp(res, 401, { error: 'Unauthorized' });

  const parts = p.split('/').filter(Boolean);

  try {
    if (req.method === 'GET' && parts.length === 1 && parts[0] === 'games')
      return jsonResp(res, 200, { games: listGames() });

    if (req.method === 'POST' && parts.length === 1 && parts[0] === 'games') {
      const body = await readBody(req);
      return jsonResp(res, 201, createGame(body.name));
    }

    if (req.method === 'DELETE' && parts.length === 2 && parts[0] === 'games') {
      deleteGame(parts[1]);
      return jsonResp(res, 200, { deleted: true });
    }

    if (req.method === 'GET' && parts.length === 3 && parts[0] === 'games' && parts[2] === 'autosave') {
      const fp = path.join(gameDir(parts[1]), 'autosave.json');
      if (!fs.existsSync(fp)) return jsonResp(res, 404, { error: 'No autosave yet' });
      return jsonResp(res, 200, JSON.parse(fs.readFileSync(fp)));
    }

    if (req.method === 'PUT' && parts.length === 3 && parts[0] === 'games' && parts[2] === 'autosave') {
      const body = await readBody(req);
      if (!fs.existsSync(gameDir(parts[1]))) return jsonResp(res, 404, { error: 'Game not found' });
      fs.writeFileSync(path.join(gameDir(parts[1]), 'autosave.json'), JSON.stringify(body, null, 2));
      touchGame(parts[1]);
      return jsonResp(res, 200, { saved: true });
    }

    if (req.method === 'GET' && parts.length === 3 && parts[0] === 'games' && parts[2] === 'saves')
      return jsonResp(res, 200, { saves: listSaves(parts[1]) });

    if (req.method === 'POST' && parts.length === 3 && parts[0] === 'games' && parts[2] === 'saves') {
      const body = await readBody(req);
      if (!fs.existsSync(gameDir(parts[1]))) return jsonResp(res, 404, { error: 'Game not found' });
      const saveId = crypto.randomUUID();
      const payload = { label: body.label || 'Save', savedAt: new Date().toISOString(), state: body.state };
      fs.mkdirSync(savesDir(parts[1]), { recursive: true });
      fs.writeFileSync(path.join(savesDir(parts[1]), saveId + '.json'), JSON.stringify(payload, null, 2));
      touchGame(parts[1]);
      return jsonResp(res, 201, { id: saveId, label: payload.label, savedAt: payload.savedAt });
    }

    if (req.method === 'GET' && parts.length === 4 && parts[0] === 'games' && parts[2] === 'saves') {
      const fp = path.join(savesDir(parts[1]), parts[3] + '.json');
      if (!fs.existsSync(fp)) return jsonResp(res, 404, { error: 'Save not found' });
      return jsonResp(res, 200, JSON.parse(fs.readFileSync(fp)));
    }

    if (req.method === 'DELETE' && parts.length === 4 && parts[0] === 'games' && parts[2] === 'saves') {
      const fp = path.join(savesDir(parts[1]), parts[3] + '.json');
      if (fs.existsSync(fp)) fs.unlinkSync(fp);
      return jsonResp(res, 200, { deleted: true });
    }

    if (req.method === 'GET' && parts.length === 1 && parts[0] === 'modules')
      return jsonResp(res, 200, { modules: listModules() });

    if (req.method === 'POST' && parts.length === 1 && parts[0] === 'modules') {
      const body = await readBody(req);
      return jsonResp(res, 201, createModule(body));
    }

    if (req.method === 'GET' && parts.length === 2 && parts[0] === 'modules') {
      const mod = getModule(parts[1]);
      if (!mod) return jsonResp(res, 404, { error: 'Module not found' });
      return jsonResp(res, 200, mod);
    }

    if (req.method === 'DELETE' && parts.length === 2 && parts[0] === 'modules') {
      deleteModule(parts[1]);
      return jsonResp(res, 200, { deleted: true });
    }

    if (req.method === 'PUT' && parts.length === 2 && parts[0] === 'modules') {
      const body = await readBody(req);
      const updated = updateModule(parts[1], body);
      if (!updated) return jsonResp(res, 404, { error: 'Module not found' });
      return jsonResp(res, 200, updated);
    }

    return jsonResp(res, 404, { error: 'Not found' });
  } catch (e) {
    log('ERROR: ' + e.message);
    return jsonResp(res, 500, { error: e.message });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  log(`DND-SAVES-API running on port ${PORT}`);
  log(`Data dir: ${DATA_DIR}`);
});
