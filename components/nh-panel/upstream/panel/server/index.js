/* ═══════════════════════════════════════════════════════════
   NHM Panel — Backend
   ═══════════════════════════════════════════════════════════ */

'use strict';

const express = require('express');
const session = require('express-session');
const FileStore = require('session-file-store')(session);
const bcrypt = require('bcryptjs');
const cors = require('cors');
const bodyParser = require('body-parser');
const http = require('http');
const WebSocket = require('ws');
const { spawn, spawnSync, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const yaml = require('js-yaml');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = process.env.PORT || 3000;
const TRUST_PROXY = process.env.TRUST_PROXY !== '0';
const CORS_ORIGINS = (process.env.CORS_ORIGINS || process.env.CORS_ORIGIN || '')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);
const LOGIN_WINDOW_MS = parseInt(process.env.LOGIN_WINDOW_MS || String(10 * 60 * 1000), 10);
const LOGIN_MAX_FAILURES = parseInt(process.env.LOGIN_MAX_FAILURES || '8', 10);
const SESSION_COOKIE_SECURE = process.env.SESSION_COOKIE_SECURE || 'auto';
const CADDY_SERVICE = process.env.CADDY_SERVICE || 'caddy';
const CADDY_BIN = process.env.CADDY_BIN || 'caddy';
const CADDYFILE_PATH = process.env.CADDYFILE_PATH || '/etc/caddy/Caddyfile';
const CADDY_SITE_TEMPLATE = process.env.CADDY_SITE_TEMPLATE || ':443, {domain}';
const CADDY_BIND = process.env.CADDY_BIND || '';
const CADDY_LISTENER_SERVER = process.env.CADDY_LISTENER_SERVER || '';
const CADDY_PROXY_PROTOCOL = process.env.CADDY_PROXY_PROTOCOL === '1';
const CADDY_TLS_CERT = process.env.CADDY_TLS_CERT || '';
const CADDY_TLS_KEY = process.env.CADDY_TLS_KEY || '';
const MIERU_ENABLED = process.env.NH_ENABLE_MIERU === '1' || process.env.ENABLE_MIERU === '1';
const MIERU_CONFIG_PATH = process.env.MIERU_CONFIG_PATH || '/etc/mieru/server_config.json';
// LISTEN_HOST: 0.0.0.0 (по умолчанию — публично) | 127.0.0.1 (SSH-only режим).
// Управляется через Environment=LISTEN_HOST=... в systemd-юните или
// --env LISTEN_HOST=... в PM2. Дефолт сохраняет обратную совместимость
// со всеми существующими установками.
const LISTEN_HOST = process.env.LISTEN_HOST || '0.0.0.0';
const DATA_DIR = path.join(__dirname, '../data');
const CONFIG_FILE = path.join(DATA_DIR, 'config.json');
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const SECRET_FILE = path.join(DATA_DIR, '.session_secret');
const SESSION_DIR = path.join(DATA_DIR, 'sessions');
const SUBSCRIPTION_TOKEN_FILE = process.env.NH_SUBSCRIPTION_TOKEN_FILE || '/etc/nh-panel/subscription-token';
const SUBSCRIPTION_DIR = process.env.NH_SUBSCRIPTION_DIR || '/opt/panel-naive-hy2/subscriptions';
const PROFILE_MAP_FILE = process.env.NH_PROFILE_MAP || '/etc/nh-panel/generated-profile-map.json';

if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
if (!fs.existsSync(SESSION_DIR)) fs.mkdirSync(SESSION_DIR, { recursive: true, mode: 0o700 });
try { fs.chmodSync(DATA_DIR, 0o700); } catch {}
try { fs.chmodSync(SESSION_DIR, 0o700); } catch {}

// ─── Session secret (персистентный, генерится при первом запуске) ───
let SESSION_SECRET;
try {
  SESSION_SECRET = fs.readFileSync(SECRET_FILE, 'utf8').trim();
  if (!SESSION_SECRET || SESSION_SECRET.length < 32) throw new Error('short');
} catch {
  SESSION_SECRET = crypto.randomBytes(48).toString('hex');
  fs.writeFileSync(SECRET_FILE, SESSION_SECRET, { mode: 0o600 });
}

// ─── Storage ────────────────────────────────────────────────
function defaultConfig() {
  return {
    installed: false,
    stack: { naive: false, hy2: false, mieru: false },
    domain: '',
    email: '',
    serverIp: '',
    arch: '',
    naiveUsers: [],
    hy2Users: [],
    mieruUsers: [],
    mieruPort: 0,
    mieruProtocol: 'TCP'
  };
}

function writeJsonFile(file, data, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), { mode });
  try { fs.chmodSync(file, mode); } catch {}
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_FILE)) {
    const cfg = defaultConfig();
    writeJsonFile(CONFIG_FILE, cfg);
    return cfg;
  }
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    // Миграция со старого формата (только Naive)
    if (!raw.stack) {
      raw.stack = { naive: !!raw.installed, hy2: false, mieru: false };
      raw.naiveUsers = raw.proxyUsers || raw.naiveUsers || [];
      raw.hy2Users = raw.hy2Users || [];
      delete raw.proxyUsers;
      writeJsonFile(CONFIG_FILE, raw);
    }
    if (typeof raw.stack.mieru !== 'boolean') raw.stack.mieru = false;
    if (!Array.isArray(raw.naiveUsers)) raw.naiveUsers = [];
    if (!Array.isArray(raw.hy2Users)) raw.hy2Users = [];
    if (!Array.isArray(raw.mieruUsers)) raw.mieruUsers = [];
    if (!raw.mieruProtocol) raw.mieruProtocol = 'TCP';
    if (!Number.isInteger(raw.mieruPort)) raw.mieruPort = parseInt(raw.mieruPort || '0', 10) || 0;

    // Миграция: если panelDomain не записан в config, но в Caddyfile есть
    // второй site-блок для поддомена с reverse_proxy на 127.0.0.1 — вытащим его.
    // Это спасает установки, сделанные до того, как install.sh начал писать
    // panelDomain в config.json (коммит 0c0c204 и ранее).
    if (!raw.panelDomain) {
      try {
        const caddyfile = fs.readFileSync('/etc/caddy/Caddyfile', 'utf8');
        // Ищем блок вида: "somesubdomain.example.com {\n  tls ...\n  ...\n  reverse_proxy 127.0.0.1:..."
        const m = caddyfile.match(/\n(\S+)\s*\{\s*\n\s*tls\s+(\S+)\s*\n[^}]*reverse_proxy\s+127\.0\.0\.1/);
        if (m && m[1] && m[1] !== raw.domain && m[1].includes('.')) {
          raw.panelDomain = m[1];
          raw.panelEmail = m[2] || raw.email;
          writeJsonFile(CONFIG_FILE, raw);
          console.log('[migrate] panelDomain восстановлен из Caddyfile:', raw.panelDomain);
        }
      } catch (_) { /* Caddyfile может отсутствовать — ничего страшного */ }
    }

    return raw;
  } catch (e) {
    console.error('config.json parse error, resetting:', e.message);
    const cfg = defaultConfig();
    writeJsonFile(CONFIG_FILE, cfg);
    return cfg;
  }
}

function saveConfig(cfg) {
  writeJsonFile(CONFIG_FILE, cfg);
}

function syncNaiveUsersFromCaddyfile(cfg) {
  if (!cfg || !cfg.stack || !cfg.stack.naive || !fs.existsSync(CADDYFILE_PATH)) return cfg;
  let text = '';
  try {
    text = fs.readFileSync(CADDYFILE_PATH, 'utf8');
  } catch {
    return cfg;
  }

  const parsed = [];
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*basic_auth\s+(\S+)\s+(\S+)/);
    if (match) parsed.push({ username: match[1], password: match[2] });
  }
  if (!parsed.length) return cfg;

  const existing = new Map((cfg.naiveUsers || []).map(u => [String(u.username || ''), u]));
  let changed = !Array.isArray(cfg.naiveUsers) || cfg.naiveUsers.length !== parsed.length;
  const now = new Date().toISOString();
  const synced = parsed.map(u => {
    const previous = existing.get(u.username) || {};
    if (previous.password !== u.password) changed = true;
    return {
      ...previous,
      username: u.username,
      password: u.password,
      createdAt: previous.createdAt || now
    };
  });

  for (const old of cfg.naiveUsers || []) {
    if (!parsed.find(u => u.username === old.username)) changed = true;
  }

  if (changed) {
    cfg.naiveUsers = synced;
    saveConfig(cfg);
  }
  return cfg;
}

function hy2Link(username, password, domain, name = username) {
  return `hysteria2://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${domain}:443?sni=${domain}&insecure=0#${encodeURIComponent(name)}`;
}

function naiveLink(username, password, domain, name = '') {
  const fragment = name ? `#${encodeURIComponent(name)}` : '';
  return `naive+https://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${domain}:443${fragment}`;
}

function mieruServerHost(cfg) {
  if (isValidDomain(cfg.domain)) return { key: 'domainName', value: cfg.domain };
  return { key: 'ipAddress', value: cfg.serverIp || 'SERVER_IP' };
}

function mieruClientConfig(username, password, cfg) {
  const host = mieruServerHost(cfg);
  const server = {
    portBindings: [{ port: cfg.mieruPort || 0, protocol: normalizeMieruProtocol(cfg.mieruProtocol) }]
  };
  if (host.value) server[host.key] = host.value;
  return {
    profiles: [{
      profileName: username,
      user: { name: username, password },
      servers: [server],
      mtu: 1400,
      multiplexing: { level: 'MULTIPLEXING_LOW' }
    }],
    activeProfile: username,
    socks5Port: 1080,
    loggingLevel: 'INFO'
  };
}

function mieruMihomoSnippet(username, password, cfg) {
  const host = (isValidDomain(cfg.domain) ? cfg.domain : cfg.serverIp) || 'SERVER_IP';
  return [
    'proxies:',
    `  - name: mieru-${username}`,
    '    type: mieru',
    `    server: ${host}`,
    `    port: ${cfg.mieruPort || 0}`,
    `    transport: ${normalizeMieruProtocol(cfg.mieruProtocol)}`,
    `    username: ${username}`,
    `    password: ${password}`,
    '    multiplexing: MULTIPLEXING_LOW'
  ].join('\n');
}

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const initialPassword = crypto.randomBytes(18).toString('base64url');
    const users = { admin: { password: bcrypt.hashSync(initialPassword, 10), role: 'admin' } };
    writeJsonFile(USERS_FILE, users);
    fs.writeFileSync(path.join(DATA_DIR, 'initial-admin.txt'), `admin:${initialPassword}\n`, { mode: 0o600 });
    try { fs.chmodSync(path.join(DATA_DIR, 'initial-admin.txt'), 0o600); } catch {}
    console.warn('Initial admin password generated in data/initial-admin.txt');
    return users;
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  writeJsonFile(USERS_FILE, users);
}

// ─── Middleware ─────────────────────────────────────────────
if (TRUST_PROXY) app.set('trust proxy', 1);
if (CORS_ORIGINS.length > 0) {
  app.use(cors({
    origin(origin, cb) {
      if (!origin || CORS_ORIGINS.includes(origin)) return cb(null, true);
      return cb(new Error('CORS origin denied'));
    },
    credentials: true
  }));
}
app.use(bodyParser.json({ limit: '256kb' }));
app.use(bodyParser.urlencoded({ extended: true, limit: '256kb' }));
const sessionMiddleware = session({
  name: 'nh_sid',
  store: new FileStore({
    path: SESSION_DIR,
    ttl: 24 * 60 * 60,
    retries: 0,
    reapInterval: 60 * 60
  }),
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: SESSION_COOKIE_SECURE === '1' ? true : SESSION_COOKIE_SECURE === '0' ? false : 'auto',
    httpOnly: true,
    sameSite: 'lax',
    maxAge: 24 * 60 * 60 * 1000
  }
});
app.use(sessionMiddleware);
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});
app.use(rejectCrossSiteMutation);
app.use(express.static(path.join(__dirname, '../public')));

function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

function requireMieruEnabled(req, res, next) {
  if (MIERU_ENABLED) return next();
  res.status(404).json({ error: 'Mieru module is disabled. Reinstall or restart panel with NH_ENABLE_MIERU=1.' });
}

// ─── Validation helpers ─────────────────────────────────────
function isValidDomain(s) {
  return typeof s === 'string'
    && /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i.test(s)
    && s.length <= 253;
}
function isValidEmail(s) {
  return typeof s === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) && s.length <= 254;
}
function isValidUsername(s) {
  return typeof s === 'string' && /^[A-Za-z0-9_.-]{1,32}$/.test(s);
}
function isValidPassword(s) {
  return typeof s === 'string' && s.length >= 8 && s.length <= 128
    && /^[A-Za-z0-9!@#$%^&*_+\-=.,~]+$/.test(s);
}
function isValidPanelPassword(s) {
  return typeof s === 'string' && s.length >= 8 && s.length <= 128
    && !/[\x00-\x1F\x7F]/.test(s);
}
function isValidPort(n) {
  const v = parseInt(n, 10);
  return Number.isInteger(v) && v >= 1025 && v <= 65535;
}
function normalizeMieruProtocol(s) {
  const p = String(s || 'TCP').toUpperCase();
  return p === 'UDP' ? 'UDP' : 'TCP';
}
function isSafeMasqueradeUrl(s) {
  if (typeof s !== 'string' || /\s/.test(s) || s.length > 2048) return false;
  try {
    const u = new URL(s);
    return (u.protocol === 'http:' || u.protocol === 'https:')
      && !!u.hostname
      && !u.username
      && !u.password;
  } catch {
    return false;
  }
}
function findFileByName(root, filename, maxDepth = 8) {
  const stack = [{ dir: root, depth: 0 }];
  while (stack.length) {
    const item = stack.pop();
    if (!item || item.depth > maxDepth) continue;
    let entries = [];
    try {
      entries = fs.readdirSync(item.dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(item.dir, entry.name);
      if (entry.isFile() && entry.name === filename) return full;
      if (entry.isDirectory()) stack.push({ dir: full, depth: item.depth + 1 });
    }
  }
  return null;
}
function findCaddyCertPair(domain) {
  if (!isValidDomain(domain)) return null;
  const roots = [
    '/var/lib/caddy/.local/share/caddy/certificates',
    '/root/.local/share/caddy/certificates'
  ];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    const cert = findFileByName(root, `${domain}.crt`);
    if (!cert) continue;
    const key = cert.replace(/\.crt$/, '.key');
    if (fs.existsSync(key)) {
      return { cert, key, ca: path.basename(path.dirname(path.dirname(cert))) };
    }
  }
  return null;
}

// Срок действия пользователя: 0 = бессрочно, иначе число дней (1..3650)
function isValidExpireDays(n) {
  if (n === undefined || n === null || n === '' || n === 0 || n === '0') return true;
  const v = parseInt(n, 10);
  return Number.isFinite(v) && v >= 1 && v <= 3650;
}

// Вычислить дату окончания (ISO) от now + days. days<=0 → null (бессрочно)
function computeExpiresAt(days) {
  const d = parseInt(days, 10);
  if (!Number.isFinite(d) || d <= 0) return null;
  return new Date(Date.now() + d * 86400 * 1000).toISOString();
}

// Истёк ли пользователь?
function isExpired(user) {
  if (!user || !user.expiresAt) return false;
  const t = Date.parse(user.expiresAt);
  if (!Number.isFinite(t)) return false;
  return Date.now() >= t;
}

// Оставшиеся секунды до истечения (для UI)
function remainingSeconds(user) {
  if (!user || !user.expiresAt) return null;
  const t = Date.parse(user.expiresAt);
  if (!Number.isFinite(t)) return null;
  return Math.max(0, Math.floor((t - Date.now()) / 1000));
}

function getRequestHost(req) {
  const forwarded = TRUST_PROXY ? req.headers['x-forwarded-host'] : '';
  const raw = Array.isArray(forwarded) ? forwarded[0] : forwarded || req.headers.host || '';
  const host = String(raw).split(',')[0].trim().toLowerCase();
  if (!TRUST_PROXY || !host || host.includes(':')) return host;
  const forwardedPortRaw = req.headers['x-forwarded-port'];
  const forwardedPort = String(Array.isArray(forwardedPortRaw) ? forwardedPortRaw[0] : forwardedPortRaw || '').split(',')[0].trim();
  if (!/^[0-9]+$/.test(forwardedPort)) return host;
  const protoRaw = req.headers['x-forwarded-proto'];
  const proto = String(Array.isArray(protoRaw) ? protoRaw[0] : protoRaw || '').split(',')[0].trim().toLowerCase();
  if ((proto === 'http' && forwardedPort === '80') || (proto === 'https' && forwardedPort === '443')) return host;
  return `${host}:${forwardedPort}`;
}

function isAllowedOrigin(origin, req) {
  if (!origin) return true;
  try {
    const parsed = new URL(origin);
    const reqHost = getRequestHost(req);
    if (reqHost && parsed.host.toLowerCase() === reqHost) return true;
    return CORS_ORIGINS.includes(origin);
  } catch {
    return false;
  }
}

function isTrustedRequestOrigin(req) {
  const origin = req.headers.origin;
  if (origin) return isAllowedOrigin(origin, req);
  const referer = req.headers.referer;
  if (!referer) return true;
  try {
    const u = new URL(referer);
    return isAllowedOrigin(u.origin, req);
  } catch {
    return false;
  }
}

function rejectCrossSiteMutation(req, res, next) {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  if (isTrustedRequestOrigin(req)) return next();
  res.status(403).json({ error: 'Cross-site request denied' });
}

const loginFailures = new Map();
function loginRateKey(req, username) {
  const ip = req.ip || req.socket?.remoteAddress || 'unknown';
  return `${ip}:${String(username || '').slice(0, 64)}`;
}
function pruneLoginFailures(now = Date.now()) {
  for (const [key, record] of loginFailures) {
    if (!record || now - record.first > LOGIN_WINDOW_MS) loginFailures.delete(key);
  }
}
function isLoginLimited(req, username) {
  pruneLoginFailures();
  const record = loginFailures.get(loginRateKey(req, username));
  return !!record && record.count >= LOGIN_MAX_FAILURES;
}
function noteLoginFailure(req, username) {
  const now = Date.now();
  const key = loginRateKey(req, username);
  const record = loginFailures.get(key);
  if (!record || now - record.first > LOGIN_WINDOW_MS) {
    loginFailures.set(key, { count: 1, first: now });
  } else {
    record.count += 1;
  }
}
function clearLoginFailures(req, username) {
  loginFailures.delete(loginRateKey(req, username));
}

// ═══════════════════════════════════════════════════════════
//  AUTH
// ═══════════════════════════════════════════════════════════
app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string' || !username || !password) {
    return res.json({ success: false, message: 'Заполните все поля' });
  }
  if (isLoginLimited(req, username)) {
    return res.status(429).json({ success: false, message: 'Слишком много попыток. Повторите позже.' });
  }
  const users = loadUsers();
  const user = users[username];
  if (!user) {
    noteLoginFailure(req, username);
    return res.json({ success: false, message: 'Неверный логин или пароль' });
  }
  if (!bcrypt.compareSync(password, user.password)) {
    noteLoginFailure(req, username);
    return res.json({ success: false, message: 'Неверный логин или пароль' });
  }
  clearLoginFailures(req, username);
  req.session.authenticated = true;
  req.session.username = username;
  req.session.role = user.role;
  res.json({ success: true });
});

app.post('/api/logout', (req, res) => {
  req.session.destroy(() => res.json({ success: true }));
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.username, role: req.session.role });
});

app.post('/api/config/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body || {};
  if (!currentPassword || !newPassword) return res.json({ success: false, message: 'Заполните все поля' });
  if (!isValidPanelPassword(newPassword)) return res.json({ success: false, message: 'Новый пароль 8-128 символов, без управляющих символов' });
  const users = loadUsers();
  const user = users[req.session.username];
  if (!user) return res.json({ success: false, message: 'Пользователь не найден' });
  if (!bcrypt.compareSync(currentPassword, user.password)) {
    return res.json({ success: false, message: 'Текущий пароль неверен' });
  }
  user.password = bcrypt.hashSync(newPassword, 10);
  saveUsers(users);
  const cfg = loadConfig();
  cfg.panelLogin = req.session.username;
  cfg.panelPassword = newPassword;
  saveConfig(cfg);
  res.json({ success: true, message: 'Пароль успешно изменён' });
});

// ═══════════════════════════════════════════════════════════
//  CONFIG / STATUS
// ═══════════════════════════════════════════════════════════
app.get('/api/config', requireAuth, (req, res) => {
  res.json(loadConfig());
});

// Динамическая версия панели — читается из /etc/nh-panel/version (обновляется update.sh).
// Fallback: '1.0.0' если файл недоступен (например, на dev-окружении или сразу после установки).
app.get('/api/system/version', requireAuth, (req, res) => {
  const VERSION_FILE = '/etc/nh-panel/version';
  const FALLBACK = '1.0.0';
  try {
    if (fs.existsSync(VERSION_FILE)) {
      const v = fs.readFileSync(VERSION_FILE, 'utf8').trim();
      if (v && /^\d+\.\d+\.\d+/.test(v)) {
        return res.json({ version: v, source: 'file' });
      }
    }
  } catch (_) { /* ignore — отдадим fallback */ }
  res.json({ version: FALLBACK, source: 'fallback' });
});

function checkServiceActive(unit) {
  return new Promise((resolve) => {
    const p = spawn('systemctl', ['is-active', unit]);
    let out = '';
    p.stdout.on('data', d => out += d.toString());
    p.on('close', () => resolve(out.trim() === 'active'));
    p.on('error', () => resolve(false));
  });
}

function checkMieruRunning() {
  return new Promise((resolve) => {
    const p = spawn('mita', ['status']);
    let out = '';
    p.stdout.on('data', d => out += d.toString());
    p.stderr.on('data', d => out += d.toString());
    p.on('close', () => resolve(/RUNNING/i.test(out)));
    p.on('error', () => resolve(false));
  });
}

app.get('/api/status', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  const exposedStack = { ...(cfg.stack || {}), mieru: MIERU_ENABLED && !!cfg.stack?.mieru };
  if (!cfg.installed) {
    return res.json({
      installed: false,
      features: { mieru: MIERU_ENABLED },
      stack: exposedStack || { naive: false, hy2: false, mieru: false }
    });
  }
  const [naiveActive, hy2Active, mieruActive] = await Promise.all([
    cfg.stack.naive ? checkServiceActive(CADDY_SERVICE) : Promise.resolve(null),
    cfg.stack.hy2 ? checkServiceActive('hysteria-server') : Promise.resolve(null),
    MIERU_ENABLED && cfg.stack.mieru ? checkMieruRunning() : Promise.resolve(null)
  ]);
  res.json({
    installed: true,
    features: { mieru: MIERU_ENABLED },
    stack: exposedStack,
    domain: cfg.domain,
    email: cfg.email,
    serverIp: cfg.serverIp,
    arch: cfg.arch,
    naive: cfg.stack.naive ? { active: naiveActive, usersCount: cfg.naiveUsers.length } : null,
    hy2:   cfg.stack.hy2   ? { active: hy2Active,   usersCount: cfg.hy2Users.length }   : null,
    mieru: MIERU_ENABLED && cfg.stack.mieru ? {
      active: mieruActive,
      usersCount: cfg.mieruUsers.length,
      port: cfg.mieruPort || 0,
      protocol: normalizeMieruProtocol(cfg.mieruProtocol)
    } : null,
  });
});

app.get('/api/subscriptions', requireAuth, (req, res) => {
  let token = '';
  try {
    token = fs.readFileSync(SUBSCRIPTION_TOKEN_FILE, 'utf8').trim().replace(/[^A-Za-z0-9._-]/g, '').slice(0, 128);
  } catch (_) {
    return res.json({ available: false, reason: 'subscription token not found' });
  }
  if (!token) return res.json({ available: false, reason: 'subscription token is empty' });

  const subDir = path.join(SUBSCRIPTION_DIR, token);
  let files = [];
  try {
    files = fs.readdirSync(subDir).filter(name => /^[A-Za-z0-9_.-]+\.(txt|b64|json)$/.test(name)).sort();
  } catch (_) {
    return res.json({ available: false, reason: 'subscription files not found', token });
  }

  const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'http').split(',')[0].trim() || 'http';
  const host = getRequestHost(req);
  const baseUrl = `${proto}://${host}/sub/${token}`;
  const has = name => files.includes(name);
  const url = name => `${baseUrl}/${name}`;
  const users = [];

  const addedUsers = new Set();
  try {
    const profileMap = JSON.parse(fs.readFileSync(PROFILE_MAP_FILE, 'utf8'));
    const profiles = Array.isArray(profileMap.profiles) ? profileMap.profiles : [];
    for (const profile of profiles) {
      const name = String(profile.subId || '').trim();
      const subscriptionId = String(profile.subscriptionId || '').trim();
      if (!name || !subscriptionId || addedUsers.has(name) || !has(`${subscriptionId}.txt`)) continue;
      addedUsers.add(name);
      users.push({
        name,
        txt: url(`${subscriptionId}.txt`),
        b64: has(`${subscriptionId}.b64`) ? url(`${subscriptionId}.b64`) : ''
      });
    }
  } catch (_) {}

  for (const file of files) {
    const m = file.match(/^(auto-\d+)\.txt$/);
    if (!m || addedUsers.has(m[1])) continue;
    const name = m[1];
    addedUsers.add(name);
    users.push({
      name,
      txt: url(`${name}.txt`),
      b64: has(`${name}.b64`) ? url(`${name}.b64`) : ''
    });
  }

  res.json({
    available: true,
    token,
    baseUrl,
    combined: {
      txt: has('combined.txt') ? url('combined.txt') : '',
      b64: has('combined.b64') ? url('combined.b64') : ''
    },
    v2rayn: {
      txt: has('v2rayn.txt') ? url('v2rayn.txt') : '',
      b64: has('v2rayn.b64') ? url('v2rayn.b64') : '',
      raw: has('v2rayn-raw.txt') ? url('v2rayn-raw.txt') : '',
      stable: has('v2rayn-stable.txt') ? url('v2rayn-stable.txt') : ''
    },
    singBox: has('sing-box.json') ? url('sing-box.json') : '',
    users
  });
});

app.post('/api/service/:kind/:action', requireAuth, async (req, res) => {
  const { kind, action } = req.params;
  if (!['start', 'stop', 'restart'].includes(action)) return res.status(400).json({ error: 'bad action' });
  if (kind === 'mieru') {
    if (!MIERU_ENABLED) return res.status(404).json({ error: 'Mieru module is disabled' });
    let result;
    if (action === 'restart') {
      await runCommand('mita', ['stop']);
      result = await runCommand('mita', ['start']);
    } else {
      result = await runCommand('mita', [action]);
    }
    if (result.code !== 0) return res.json({ success: false, message: result.err || result.out || `mita ${action} failed` });
    const active = await checkMieruRunning();
    res.json({
      success: true,
      active,
      message: active ? `mita ${action} — прокси запущен` : `mita ${action} — прокси остановлен`
    });
    return;
  }
  const unit = kind === 'naive' ? CADDY_SERVICE : kind === 'hy2' ? 'hysteria-server' : kind === 'mieru' ? 'mita' : null;
  if (!unit) return res.status(400).json({ error: 'bad kind' });

  const p = spawn('systemctl', [action, unit]);
  p.on('close', (code) => {
    if (code !== 0) {
      return res.json({ success: false, message: `${unit} ${action} failed (code ${code})` });
    }
    // Даём сервису 1.5с подняться, потом проверяем реальный статус
    setTimeout(() => {
      checkServiceActive(unit).then(active => {
        res.json({
          success: true,
          active,
          message: active
            ? `${unit} ${action} — сервис активен`
            : `${unit} ${action} — команда принята (сервис ещё стартует)`
        });
      }).catch(() => {
        res.json({ success: true, active: null, message: `${unit} ${action} OK` });
      });
    }, 1500);
  });
  p.on('error', () => res.json({ success: false, message: 'systemctl недоступен' }));
});

// ═══════════════════════════════════════════════════════════
//  NAIVE USERS
// ═══════════════════════════════════════════════════════════
function writeCaddyfile(cfg) {
  if (!cfg.stack.naive || !cfg.domain) return false;
  // Фильтруем истёкших пользователей — их basic_auth не попадёт в Caddyfile (подключиться не смогут)
  const lines = (cfg.naiveUsers || [])
    .filter(u => !isExpired(u))
    .map(u => `    basic_auth ${u.username} ${u.password}`)
    .join('\n');

  // КРИТИЧНО: если Hy2 тоже установлен — отключаем HTTP/3 в Caddy,
  // иначе он займёт UDP/443 и Hy2 не запустится.
  const disableH3 = cfg.stack && cfg.stack.hy2;
  let serversBlock = '';
  if (CADDY_PROXY_PROTOCOL && CADDY_LISTENER_SERVER) {
    serversBlock = `

  servers ${CADDY_LISTENER_SERVER} {
    listener_wrappers {
      proxy_protocol {
        timeout 2s
        allow 127.0.0.1/32
        fallback_policy skip
      }
      tls
    }
    protocols h1 h2
  }`;
  } else if (disableH3) {
    serversBlock = `

  servers {
    protocols h1 h2
  }`;
  }

  const globalBlock = `{
  auto_https disable_redirects
  order forward_proxy before file_server${serversBlock}
}`;

  // Маскировка: local → file_server, mirror → reverse_proxy <url>.
  // Если masqueradeMode не задан (старая установка) — оставляем file_server (дефолт).
  const masqueradeBlock = (cfg.masqueradeMode === 'mirror' && isSafeMasqueradeUrl(cfg.masqueradeUrl))
    ? `  reverse_proxy ${cfg.masqueradeUrl} {
    header_up Host {upstream_hostport}
  }`
    : `  file_server {
    root /var/www/html
  }`;

  const siteAddress = CADDY_SITE_TEMPLATE.replace(/\{domain\}/g, cfg.domain);
  const bindLine = CADDY_BIND ? `  bind ${CADDY_BIND}\n` : '';
  const tlsLine = (CADDY_TLS_CERT && CADDY_TLS_KEY)
    ? `  tls ${CADDY_TLS_CERT} ${CADDY_TLS_KEY}`
    : `  tls ${cfg.email}`;

  // Основной site-блок: домен прокси
  let content = `${globalBlock}

${siteAddress} {
${bindLine}${tlsLine}

  forward_proxy {
${lines || '    # no users yet'}
    hide_ip
    hide_via
    probe_resistance
  }

${masqueradeBlock}
}
`;

  // Второй site-блок: панель на отдельном поддомене (ACCESS_MODE=3).
  // ОБЯЗАТЕЛЬНО сохраняем этот блок при любой перегенерации Caddyfile,
  // иначе после добавления юзеров Naive панель перестанет отвечать по HTTPS.
  // panelDomain/panelEmail записываются install.sh при установке в режиме 3.
  //
  // ИСКЛЮЧЕНИЕ: SSH-only режим (cfg.sshOnly === 1) — panel-блок НЕ добавляем,
  // т.к. панель доступна только через SSH-туннель на 127.0.0.1.
  const internalPort = process.env.PORT || 3000;
  if (cfg.panelDomain && cfg.panelDomain !== cfg.domain && cfg.sshOnly !== 1) {
    const panelEmail = cfg.panelEmail || cfg.email;
    content += `
${cfg.panelDomain} {
  tls ${panelEmail}
  encode gzip
  reverse_proxy 127.0.0.1:${internalPort}
}
`;
  }

  // ── Атомарная запись с валидацией и rollback (PR #4) ──
  // Проблема: если writeFileSync прервётся посередине или сгенерируется
  // невалидный Caddyfile, мы оставим систему в полуразобранном состоянии —
  // panel-блок может пропасть, и панель станет недоступна.
  //
  // Решение:
  //   1. Бэкап текущего Caddyfile в /etc/caddy/Caddyfile.last (atomic via rename).
  //   2. Запись нового конфига во временный файл /etc/caddy/Caddyfile.new.
  //   3. Валидация через `caddy validate` (если caddy установлен).
  //   4. Если валидно — atomic rename .new → Caddyfile.
  //   5. Если невалидно — удаляем .new, бэкап остался нетронутым, возврат false.
  //   6. На любой ошибке записи восстанавливаем из .last (rollback).
  const targetPath = CADDYFILE_PATH;
  const tmpPath = `${CADDYFILE_PATH}.new`;
  const backupPath = `${CADDYFILE_PATH}.last`;
  try {
    // 1) Бэкап (best-effort: если файла ещё нет — это первичная установка).
    if (fs.existsSync(targetPath)) {
      try { fs.copyFileSync(targetPath, backupPath); } catch (e) { /* best-effort */ }
    }
    // 2) Запись во временный файл.
    fs.writeFileSync(tmpPath, content, 'utf8');
    // 3) Валидация через caddy validate (если caddy доступен).
    try {
      execFileSync(CADDY_BIN, ['validate', '--config', tmpPath], { stdio: 'pipe', timeout: 10000 });
    } catch (validateErr) {
      // caddy либо не установлен, либо validate упал.
      // Если ошибка — НЕ stderr пустой → это реальная невалидность.
      const stderr = (validateErr && validateErr.stderr) ? validateErr.stderr.toString() : '';
      if (stderr && /error|adapt|parse/i.test(stderr)) {
        console.error('[writeCaddyfile] caddy validate failed, keeping previous Caddyfile:', stderr.slice(0, 500));
        try { fs.unlinkSync(tmpPath); } catch {}
        return false;
      }
      // Иначе (caddy не установлен, ENOENT и т.п.) — пропускаем валидацию,
      // продолжаем atomic rename (валидность подтвердится при reload).
    }
    // 4) Atomic rename — на ext4/xfs это атомарная операция.
    fs.renameSync(tmpPath, targetPath);
    return true;
  } catch (e) {
    console.error('Caddyfile write error:', e.message);
    // Rollback: если временный файл остался — удаляем; если бэкап есть — восстанавливаем.
    try { if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath); } catch {}
    try {
      if (fs.existsSync(backupPath) && !fs.existsSync(targetPath)) {
        fs.copyFileSync(backupPath, targetPath);
        console.warn('[writeCaddyfile] Rolled back to previous Caddyfile from backup.');
      }
    } catch (rb) { /* best-effort */ }
    return false;
  }
}

function reloadCaddy() {
  const run = (cmd, args) => new Promise((resolve) => {
    const p = spawn(cmd, args);
    p.on('close', (code) => resolve(code === 0));
    p.on('error', () => resolve(false));
  });
  return (async () => {
    if (await run(CADDY_BIN, ['reload', '--config', CADDYFILE_PATH])) return true;
    if (await run('systemctl', ['reload', CADDY_SERVICE])) return true;
    return run('systemctl', ['restart', CADDY_SERVICE]);
  })();
}

function enrichUser(u) {
  return {
    ...u,
    expiresAt: u.expiresAt || null,
    remainingSec: remainingSeconds(u),
    expired: isExpired(u)
  };
}

app.get('/api/naive/users', requireAuth, (req, res) => {
  const cfg = syncNaiveUsersFromCaddyfile(loadConfig());
  res.json({ users: (cfg.naiveUsers || []).map(enrichUser) });
});

app.post('/api/naive/users', requireAuth, async (req, res) => {
  const { username, password, expireDays } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 симв. (A-Z, a-z, 0-9, . _ -)' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов (без пробелов)' });
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0 (бессрочно)' });

  const cfg = loadConfig();
  if (cfg.naiveUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  const expiresAt = computeExpiresAt(expireDays);
  cfg.naiveUsers.push({ username, password, createdAt: new Date().toISOString(), expiresAt });
  saveConfig(cfg);

  let reloaded = true;
  if (cfg.installed && cfg.stack.naive) {
    if (!writeCaddyfile(cfg)) {
      return res.json({ success: false, message: 'Caddyfile не обновлён; пользователь сохранён, но не активен' });
    }
    reloaded = await reloadCaddy();
    if (!reloaded) {
      return res.json({ success: false, message: 'Caddy не перезагружен; пользователь сохранён, но не активен' });
    }
  }

  res.json({
    success: true,
    link: cfg.domain ? naiveLink(username, password, cfg.domain) : null,
    reloaded
  });
});

app.delete('/api/naive/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const cfg = loadConfig();
  const before = cfg.naiveUsers.length;
  cfg.naiveUsers = cfg.naiveUsers.filter(u => u.username !== username);
  if (cfg.naiveUsers.length === before) return res.json({ success: false, message: 'Не найден' });
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.naive) {
    if (!writeCaddyfile(cfg)) {
      return res.json({ success: false, message: 'Caddyfile не обновлён' });
    }
    if (!await reloadCaddy()) {
      return res.json({ success: false, message: 'Caddy не перезагружен' });
    }
  }
  res.json({ success: true });
});

// Продлить/изменить срок: { expireDays: N } (0 = бессрочно, N>0 = now + N дней)
app.patch('/api/naive/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const { expireDays } = req.body || {};
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0' });

  const cfg = loadConfig();
  const user = cfg.naiveUsers.find(u => u.username === username);
  if (!user) return res.json({ success: false, message: 'Не найден' });
  user.expiresAt = computeExpiresAt(expireDays);
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.naive) {
    if (!writeCaddyfile(cfg)) {
      return res.json({ success: false, message: 'Caddyfile не обновлён' });
    }
    if (!await reloadCaddy()) {
      return res.json({ success: false, message: 'Caddy не перезагружен' });
    }
  }
  res.json({ success: true, expiresAt: user.expiresAt });
});

// ═══════════════════════════════════════════════════════════
//  HY2 ACL ROUTING: RU direct bypass + AI via WARP
// ═══════════════════════════════════════════════════════════
const BYPASS_FILE = path.join(DATA_DIR, 'bypass.json');
const WARP_ROUTING_FILE = path.join(DATA_DIR, 'warp-routing.json');
const HY2_ACL_PATH = process.env.HY2_ACL_PATH || '/etc/hysteria/bypass-ru.acl';
const WARP_PROXY_HOST = process.env.WARP_PROXY_HOST || '127.0.0.1';
const WARP_PROXY_PORT = parseInt(process.env.WARP_PROXY_PORT || '40000', 10);
const WARP_OUTBOUND_NAME = process.env.WARP_OUTBOUND_NAME || process.env.WARP_OUTBOUND_TAG || 'warp-cli';
const DEFAULT_AI_DOMAINS = (process.env.WARP_AI_DOMAINS || [
  'domain:openai.com',
  'domain:chatgpt.com',
  'domain:oaistatic.com',
  'domain:oaiusercontent.com',
  'domain:anthropic.com',
  'domain:claude.ai',
  'domain:gemini.google.com',
  'domain:aistudio.google.com',
  'domain:ai.google.dev',
  'domain:generativelanguage.googleapis.com',
  'domain:aiplatform.googleapis.com',
  'domain:googleapis.com',
  'domain:gstatic.com',
  'domain:googleusercontent.com',
  'domain:ggpht.com',
  'domain:clients6.google.com',
  'domain:accounts.google.com',
  'domain:apis.google.com',
  'domain:ogs.google.com',
  'domain:www.google.com',
  'domain:play.google.com',
  'domain:withgoogle.com',
  'domain:youtube.com',
  'domain:ytimg.com',
  'domain:notebooklm.google.com',
  'domain:notebooklm.google'
].join(','));

// Список сервисов, которые блокируют иностранные IP — их лучше пускать напрямую.
// Обновляется пользователем через API /api/bypass.
function loadBypass() {
  try {
    if (!fs.existsSync(BYPASS_FILE)) {
      // Дефолт — пусто, т.е. bypass выключен
      const d = { enabled: false, cidrs: [], source: '', updatedAt: null };
      fs.writeFileSync(BYPASS_FILE, JSON.stringify(d, null, 2));
      return d;
    }
    const raw = JSON.parse(fs.readFileSync(BYPASS_FILE, 'utf8'));
    if (!Array.isArray(raw.cidrs)) raw.cidrs = [];
    return raw;
  } catch {
    return { enabled: false, cidrs: [], source: '', updatedAt: null };
  }
}
function saveBypass(b) {
  writeJsonFile(BYPASS_FILE, b);
}

function parseDomainList(value) {
  const items = Array.isArray(value)
    ? value
    : String(value || '').split(/[\s,]+/);
  const seen = new Set();
  const result = [];
  items.forEach(item => {
    const raw = String(item || '').trim().replace(/^["']|["']$/g, '');
    if (!raw || raw.startsWith('#')) return;
    const acl = domainRuleToAclTarget(raw);
    if (!acl || seen.has(acl)) return;
    seen.add(acl);
    result.push(raw);
  });
  return result;
}

function domainRuleToAclTarget(rule) {
  let s = String(rule || '').trim().toLowerCase();
  if (!s) return null;
  if (s.startsWith('regexp:')) return null;
  if (s.startsWith('full:')) s = s.slice(5);
  if (s.startsWith('domain:')) s = `suffix:${s.slice(7)}`;
  if (!s.includes(':') && !s.includes('*')) s = `suffix:${s}`;
  if (s.startsWith('suffix:')) {
    const host = s.slice(7);
    if (!/^[a-z0-9.*_-]+(\.[a-z0-9.*_-]+)+$/.test(host)) return null;
  } else if (!/^(\*\.)?[a-z0-9*_-]+(\.[a-z0-9*_-]+)+$/.test(s) && !/^geosite:[a-z0-9_@.-]+$/.test(s)) {
    return null;
  }
  return s;
}

function loadWarpRouting() {
  try {
    if (!fs.existsSync(WARP_ROUTING_FILE)) {
      const d = {
        enabled: false,
        domains: parseDomainList(DEFAULT_AI_DOMAINS),
        source: 'default AI domains',
        updatedAt: null
      };
      fs.writeFileSync(WARP_ROUTING_FILE, JSON.stringify(d, null, 2));
      return d;
    }
    const raw = JSON.parse(fs.readFileSync(WARP_ROUTING_FILE, 'utf8'));
    raw.domains = parseDomainList(raw.domains && raw.domains.length ? raw.domains : DEFAULT_AI_DOMAINS);
    raw.enabled = !!raw.enabled;
    return raw;
  } catch {
    return {
      enabled: false,
      domains: parseDomainList(DEFAULT_AI_DOMAINS),
      source: 'default AI domains',
      updatedAt: null
    };
  }
}

function saveWarpRouting(w) {
  writeJsonFile(WARP_ROUTING_FILE, w);
}

function warpLocalProxyReady() {
  const status = {
    ready: false,
    host: WARP_PROXY_HOST,
    port: WARP_PROXY_PORT,
    service: 'unknown',
    status: ''
  };
  try {
    const svc = spawnSync('systemctl', ['is-active', 'warp-svc'], { encoding: 'utf8', timeout: 3000 });
    status.service = (svc.stdout || svc.stderr || '').trim() || 'unknown';
  } catch {}
  try {
    const cli = spawnSync('warp-cli', ['--accept-tos', 'status'], { encoding: 'utf8', timeout: 5000 });
    status.status = (cli.stdout || cli.stderr || '').trim();
  } catch {}
  try {
    const curl = spawnSync('curl', [
      '-fsS',
      '--max-time', '8',
      '--socks5-hostname', `${WARP_PROXY_HOST}:${WARP_PROXY_PORT}`,
      'https://www.cloudflare.com/cdn-cgi/trace'
    ], { encoding: 'utf8', timeout: 10000 });
    status.ready = curl.status === 0 && /^warp=(on|plus)$/mi.test(curl.stdout || '');
  } catch {}
  return status;
}

function ensureWarpOutbound(base) {
  const warpOutbound = {
    name: WARP_OUTBOUND_NAME,
    type: 'socks5',
    socks5: { addr: `${WARP_PROXY_HOST}:${WARP_PROXY_PORT}` }
  };
  const existing = Array.isArray(base.outbounds) ? base.outbounds : [];
  const withoutManaged = existing.filter(o => o && o.name !== WARP_OUTBOUND_NAME);
  const direct = withoutManaged.find(o => o && o.name === 'direct') || { name: 'direct', type: 'direct' };
  const rest = withoutManaged.filter(o => o && o.name !== 'direct');
  base.outbounds = [direct, ...rest, warpOutbound];
}

function removeWarpOutbound(base) {
  if (!Array.isArray(base.outbounds)) return;
  base.outbounds = base.outbounds.filter(o => o && o.name !== WARP_OUTBOUND_NAME);
  if (base.outbounds.length === 0) delete base.outbounds;
}

function buildPanelAclLines() {
  const b = loadBypass();
  const w = loadWarpRouting();
  const lines = ['# Managed by NHM Panel. Do not edit manually.'];

  if (w.enabled && Array.isArray(w.domains) && w.domains.length > 0) {
    lines.push('', '# AI domains through local Cloudflare WARP');
    parseDomainList(w.domains)
      .map(domainRuleToAclTarget)
      .filter(Boolean)
      .forEach(target => lines.push(`${WARP_OUTBOUND_NAME}(${target})`));
  }

  if (b.enabled && Array.isArray(b.cidrs) && b.cidrs.length > 0) {
    lines.push('', '# Direct bypass CIDRs');
    b.cidrs
      .filter(c => /^[0-9a-fA-F:.\/]+$/.test(c))
      .forEach(c => lines.push(`direct(${c})`));
  }

  return lines.length > 1 ? lines : [];
}

// Применяет ACL routing к переданному Hysteria-конфигу (in-place).
// Hysteria2 ACL v2: outbound(address), например direct(1.2.3.0/24) или warp-cli(suffix:openai.com).
function applyPanelAclRouting(base, cfg) {
  const warp = loadWarpRouting();
  const lines = buildPanelAclLines();
  if (lines.length === 0) {
    if (base.acl && base.acl.file === HY2_ACL_PATH) delete base.acl;
    removeWarpOutbound(base);
    try { if (fs.existsSync(HY2_ACL_PATH)) fs.unlinkSync(HY2_ACL_PATH); } catch {}
    return;
  }

  try {
    fs.mkdirSync(path.dirname(HY2_ACL_PATH), { recursive: true });
    fs.writeFileSync(HY2_ACL_PATH, lines.join('\n') + '\n', 'utf8');
    base.acl = { file: HY2_ACL_PATH };
    if (warp.enabled) {
      ensureWarpOutbound(base);
      base.sniff = Object.assign({}, base.sniff || {}, {
        enable: true,
        timeout: (base.sniff && base.sniff.timeout) || '2s',
        rewriteDomain: false,
        tcpPorts: (base.sniff && base.sniff.tcpPorts) || '80,443',
        udpPorts: (base.sniff && base.sniff.udpPorts) || '443'
      });
    } else {
      removeWarpOutbound(base);
    }
  } catch (e) {
    console.error('[acl-routing] write acl failed:', e.message);
  }
}

app.get('/api/bypass', requireAuth, (req, res) => {
  const b = loadBypass();
  res.json({
    enabled: !!b.enabled,
    count:   (b.cidrs || []).length,
    source:  b.source || '',
    updatedAt: b.updatedAt || null,
    // первые 50 строк для предпросмотра
    preview: (b.cidrs || []).slice(0, 50)
  });
});

// Загрузка списка: принимает либо { cidrs: ["1.2.3.0/24", ...] },
// либо { json: { "service.ru": ["1.2.3.0/24", ...], ... } } (формат пользовательского файла)
app.post('/api/bypass', requireAuth, async (req, res) => {
  const { cidrs, json, enabled, source } = req.body || {};
  const b = loadBypass();

  let newList = null;
  if (Array.isArray(cidrs)) {
    newList = cidrs;
  } else if (json && typeof json === 'object') {
    const set = new Set();
    Object.values(json).forEach(arr => {
      if (Array.isArray(arr)) arr.forEach(c => { if (typeof c === 'string') set.add(c.trim()); });
    });
    newList = Array.from(set);
  }

  if (newList) {
    // Валидация CIDR — оставляем только корректные
    const re = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$|^[0-9a-fA-F:]+\/\d{1,3}$/;
    b.cidrs = newList.map(s => String(s).trim()).filter(s => re.test(s));
    b.source = typeof source === 'string' ? source.slice(0, 128) : b.source;
    b.updatedAt = new Date().toISOString();
  }
  if (typeof enabled === 'boolean') b.enabled = enabled;

  saveBypass(b);

  // Применяем немедленно, если Hy2 установлен
  const cfg = loadConfig();
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true, enabled: !!b.enabled, count: b.cidrs.length });
});

app.delete('/api/bypass', requireAuth, async (req, res) => {
  saveBypass({ enabled: false, cidrs: [], source: '', updatedAt: null });
  const cfg = loadConfig();
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true });
});

app.get('/api/warp-routing', requireAuth, (req, res) => {
  const w = loadWarpRouting();
  const proxy = warpLocalProxyReady();
  const preview = parseDomainList(w.domains).map(domainRuleToAclTarget).filter(Boolean).slice(0, 50);
  res.json({
    enabled: !!w.enabled,
    count: preview.length,
    domains: w.domains,
    source: w.source || '',
    updatedAt: w.updatedAt || null,
    outboundName: WARP_OUTBOUND_NAME,
    proxyHost: WARP_PROXY_HOST,
    proxyPort: WARP_PROXY_PORT,
    proxyReady: proxy.ready,
    proxy,
    aclPath: HY2_ACL_PATH,
    preview
  });
});

app.post('/api/warp-routing', requireAuth, async (req, res) => {
  const { domains, enabled, source } = req.body || {};
  const w = loadWarpRouting();
  if (domains !== undefined) {
    const parsed = parseDomainList(domains);
    if (parsed.length === 0) {
      return res.json({ success: false, message: 'Список доменов пуст или не поддерживается' });
    }
    w.domains = parsed;
    w.source = typeof source === 'string' ? source.slice(0, 128) : w.source;
    w.updatedAt = new Date().toISOString();
  }
  if (typeof enabled === 'boolean') w.enabled = enabled;
  saveWarpRouting(w);

  const cfg = loadConfig();
  if (cfg.installed && cfg.stack.hy2) {
    if (!writeHysteriaConfig(cfg)) {
      return res.json({ success: false, message: 'config.yaml не обновлён' });
    }
    await reloadHysteria();
  }
  const proxy = warpLocalProxyReady();
  res.json({ success: true, enabled: !!w.enabled, count: parseDomainList(w.domains).length, proxyReady: proxy.ready });
});

app.delete('/api/warp-routing', requireAuth, async (req, res) => {
  const w = loadWarpRouting();
  w.enabled = false;
  w.updatedAt = new Date().toISOString();
  saveWarpRouting(w);
  const cfg = loadConfig();
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true });
});

// ═══════════════════════════════════════════════════════════
//  HY2 USERS
// ═══════════════════════════════════════════════════════════
function writeHysteriaConfig(cfg) {
  if (!cfg.stack.hy2 || !cfg.domain) return false;

  const userpass = {};
  // Фильтруем истёкших пользователей — их не будет в userpass (подключиться не смогут)
  (cfg.hy2Users || []).forEach(u => {
    if (u.username && u.password && !isExpired(u)) userpass[u.username] = u.password;
  });
  if (Object.keys(userpass).length === 0) {
    userpass.default = crypto.randomBytes(16).toString('base64url');
  }

  const hyCfgPath = '/etc/hysteria/config.yaml';

  // Читаем существующий конфиг и ОБНОВЛЯЕМ только секцию auth.
  // Это критично: TLS/ACME/masquerade/quic секции должны сохраняться!
  let base = null;
  try {
    const raw = fs.readFileSync(hyCfgPath, 'utf8');
    base = yaml.load(raw);
  } catch {
    base = null;
  }

  if (base && typeof base === 'object') {
    // Только обновляем userpass — TLS/ACME/QUIC секции должны сохраняться!
    if (!base.auth) base.auth = { type: 'userpass' };
    base.auth.type = 'userpass';
    base.auth.userpass = userpass;

    // Masquerade: переписываем секцию ТОЛЬКО если в config.json явно задан режим.
    // Если masqueradeMode не указан (старая установка) — masquerade не трогаем,
    // чтобы не сломать существующую конфигурацию.
    if (cfg.masqueradeMode === 'mirror' && isSafeMasqueradeUrl(cfg.masqueradeUrl)) {
      base.masquerade = {
        type: 'proxy',
        proxy: { url: cfg.masqueradeUrl, rewriteHost: true }
      };
    } else if (cfg.masqueradeMode === 'local') {
      base.masquerade = {
        type: 'file',
        file: { dir: '/var/www/html' }
      };
    }
    // ACL routing: RU direct bypass and AI-only WARP route for Hy2.
    applyPanelAclRouting(base, cfg);
  } else {
    // Файла нет или повреждён — создаём минимальный.
    // Пытаемся найти сертификат Caddy через find (любой CA, новый или старый путь).
    // Если не нашли — НЕ включаем ACME fallback (чтобы не сжечь LE rate limit 429),
    // оставляем конфиг без TLS — Hy2 не стартует, пока админ вручную не допишет tls.
    console.warn('[writeHysteriaConfig] /etc/hysteria/config.yaml not found — creating minimal config.');
    let tlsBlock = null;
    try {
      const roots = [
        '/var/lib/caddy/.local/share/caddy/certificates',
        '/root/.local/share/caddy/certificates'
      ];
      for (const root of roots) {
        if (!fs.existsSync(root)) continue;
        const pair = findCaddyCertPair(cfg.domain);
        if (pair) {
          tlsBlock = { cert: pair.cert, key: pair.key };
          console.log('[writeHysteriaConfig] Found Caddy cert:', tlsBlock.cert);
          break;
        }
      }
    } catch (e) { /* ignore */ }

    // Masquerade: учитываем выбор пользователя (по умолчанию — local).
    const masqueradeBlock = (cfg.masqueradeMode === 'mirror' && isSafeMasqueradeUrl(cfg.masqueradeUrl))
      ? { type: 'proxy', proxy: { url: cfg.masqueradeUrl, rewriteHost: true } }
      : { type: 'file', file: { dir: '/var/www/html' } };

    base = {
      listen: ':443',
      auth: { type: 'userpass', userpass },
      masquerade: masqueradeBlock,
      ignoreClientBandwidth: true,
      quic: {
        initStreamReceiveWindow: 8388608, maxStreamReceiveWindow: 8388608,
        initConnReceiveWindow: 20971520, maxConnReceiveWindow: 20971520,
        maxIdleTimeout: '30s', keepAlivePeriod: '10s', disablePathMTUDiscovery: false
      }
    };
    if (tlsBlock) {
      base.tls = tlsBlock;
    } else {
      console.warn('[writeHysteriaConfig] No Caddy cert found. Hysteria2 will NOT start until TLS is configured manually.');
    }
    applyPanelAclRouting(base, cfg);
  }

  // ── Атомарная запись с валидацией и rollback (PR #4) ──
  // Та же стратегия, что и в writeCaddyfile: temp → validate → atomic rename.
  // Валидация: пробуем yaml.load() обратно; если падает — это означает
  // что мы сами породили невалидный YAML (баг в коде), сохраняем старый.
  const tmpPath = hyCfgPath + '.new';
  const backupPath = hyCfgPath + '.last';
  try {
    const newContent = yaml.dump(base, { lineWidth: 120, quotingType: '"' });
    // 1) Бэкап (best-effort).
    if (fs.existsSync(hyCfgPath)) {
      try { fs.copyFileSync(hyCfgPath, backupPath); } catch (e) { /* best-effort */ }
    }
    // 2) Запись во временный файл.
    fs.writeFileSync(tmpPath, newContent, 'utf8');
    // 3) Self-validate: парсим обратно.
    try {
      const reparsed = yaml.load(newContent);
      if (!reparsed || typeof reparsed !== 'object' || !reparsed.auth) {
        throw new Error('parsed config is empty or missing auth section');
      }
    } catch (vErr) {
      console.error('[writeHysteriaConfig] self-validate failed, keeping previous config:', vErr.message);
      try { fs.unlinkSync(tmpPath); } catch {}
      return false;
    }
    // 4) Atomic rename.
    fs.renameSync(tmpPath, hyCfgPath);
    return true;
  } catch (e) {
    console.error('hysteria config write error:', e.message);
    try { if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath); } catch {}
    try {
      if (fs.existsSync(backupPath) && !fs.existsSync(hyCfgPath)) {
        fs.copyFileSync(backupPath, hyCfgPath);
        console.warn('[writeHysteriaConfig] Rolled back to previous config from backup.');
      }
    } catch (rb) { /* best-effort */ }
    return false;
  }
}

function reloadHysteria() {
  return new Promise((resolve) => {
    const p = spawn('systemctl', ['restart', 'hysteria-server']);
    p.on('close', () => resolve());
    p.on('error', () => resolve());
  });
}

app.get('/api/hy2/users', requireAuth, (req, res) => {
  const cfg = loadConfig();
  res.json({ users: (cfg.hy2Users || []).map(enrichUser) });
});

app.post('/api/hy2/users', requireAuth, async (req, res) => {
  const { username, password, expireDays } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 символа' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов' });
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0 (бессрочно)' });

  const cfg = loadConfig();
  if (cfg.hy2Users.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  const expiresAt = computeExpiresAt(expireDays);
  cfg.hy2Users.push({ username, password, createdAt: new Date().toISOString(), expiresAt });
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({
    success: true,
    link: cfg.domain
      ? hy2Link(username, password, cfg.domain)
      : null
  });
});

app.delete('/api/hy2/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const cfg = loadConfig();
  const before = cfg.hy2Users.length;
  cfg.hy2Users = cfg.hy2Users.filter(u => u.username !== username);
  if (cfg.hy2Users.length === before) return res.json({ success: false, message: 'Не найден' });
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true });
});

// Продлить/изменить срок Hy2: { expireDays: N }
app.patch('/api/hy2/users/:username', requireAuth, async (req, res) => {
  const { username } = req.params;
  const { expireDays } = req.body || {};
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0' });

  const cfg = loadConfig();
  const user = cfg.hy2Users.find(u => u.username === username);
  if (!user) return res.json({ success: false, message: 'Не найден' });
  user.expiresAt = computeExpiresAt(expireDays);
  saveConfig(cfg);

  if (cfg.installed && cfg.stack.hy2) {
    writeHysteriaConfig(cfg);
    await reloadHysteria();
  }
  res.json({ success: true, expiresAt: user.expiresAt });
});

// ═══════════════════════════════════════════════════════════
//  MIERU / MITA
// ═══════════════════════════════════════════════════════════
function writeMieruConfig(cfg) {
  if (!cfg.stack.mieru || !isValidPort(cfg.mieruPort)) return false;
  const users = (cfg.mieruUsers || [])
    .filter(u => u.username && u.password && !isExpired(u))
    .map(u => ({ name: u.username, password: u.password }));
  if (users.length === 0) users.push({ name: 'disabled', password: crypto.randomBytes(18).toString('base64url') });
  const mitaCfg = {
    portBindings: [{ port: parseInt(cfg.mieruPort, 10), protocol: normalizeMieruProtocol(cfg.mieruProtocol) }],
    users,
    loggingLevel: 'INFO',
    mtu: 1400
  };
  writeJsonFile(MIERU_CONFIG_PATH, mitaCfg);
  return true;
}

function runCommand(cmd, args) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args);
    let out = '', err = '';
    p.stdout.on('data', d => out += d.toString());
    p.stderr.on('data', d => err += d.toString());
    p.on('close', code => resolve({ code, out, err }));
    p.on('error', e => resolve({ code: -1, out, err: e.message }));
  });
}

async function applyMieruConfig(cfg, restart = false) {
  if (!writeMieruConfig(cfg)) return { success: false, message: 'Mieru port/config invalid' };
  const applied = await runCommand('mita', ['apply', 'config', MIERU_CONFIG_PATH]);
  if (applied.code !== 0) return { success: false, message: applied.err || applied.out || 'mita apply failed' };
  if (restart) {
    await runCommand('mita', ['stop']);
    const started = await runCommand('mita', ['start']);
    if (started.code !== 0) return { success: false, message: started.err || started.out || 'mita start failed' };
  } else {
    const reloaded = await runCommand('mita', ['reload']);
    if (reloaded.code !== 0) await runCommand('mita', ['start']);
  }
  return { success: true };
}

app.get('/api/mieru/users', requireAuth, requireMieruEnabled, (req, res) => {
  const cfg = loadConfig();
  res.json({
    users: (cfg.mieruUsers || []).map(enrichUser),
    port: cfg.mieruPort || 0,
    protocol: normalizeMieruProtocol(cfg.mieruProtocol)
  });
});

app.post('/api/mieru/users', requireAuth, requireMieruEnabled, async (req, res) => {
  const { username, password, expireDays } = req.body || {};
  if (!isValidUsername(username)) return res.json({ success: false, message: 'Логин 1-32 символа' });
  if (!isValidPassword(password)) return res.json({ success: false, message: 'Пароль 8-128 символов' });
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0 (бессрочно)' });

  const cfg = loadConfig();
  if (cfg.mieruUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }
  cfg.mieruUsers.push({ username, password, createdAt: new Date().toISOString(), expiresAt: computeExpiresAt(expireDays) });
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.mieru) {
    const applied = await applyMieruConfig(cfg);
    if (!applied.success) return res.json(applied);
  }
  res.json({ success: true, clientConfig: mieruClientConfig(username, password, cfg), mihomo: mieruMihomoSnippet(username, password, cfg) });
});

app.delete('/api/mieru/users/:username', requireAuth, requireMieruEnabled, async (req, res) => {
  const { username } = req.params;
  const cfg = loadConfig();
  const before = cfg.mieruUsers.length;
  cfg.mieruUsers = cfg.mieruUsers.filter(u => u.username !== username);
  if (cfg.mieruUsers.length === before) return res.json({ success: false, message: 'Не найден' });
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.mieru) {
    const applied = await applyMieruConfig(cfg);
    if (!applied.success) return res.json(applied);
  }
  res.json({ success: true });
});

app.patch('/api/mieru/users/:username', requireAuth, requireMieruEnabled, async (req, res) => {
  const { username } = req.params;
  const { expireDays } = req.body || {};
  if (!isValidExpireDays(expireDays)) return res.json({ success: false, message: 'Срок: 1..3650 дней или 0' });
  const cfg = loadConfig();
  const user = cfg.mieruUsers.find(u => u.username === username);
  if (!user) return res.json({ success: false, message: 'Не найден' });
  user.expiresAt = computeExpiresAt(expireDays);
  saveConfig(cfg);
  if (cfg.installed && cfg.stack.mieru) {
    const applied = await applyMieruConfig(cfg);
    if (!applied.success) return res.json(applied);
  }
  res.json({ success: true, expiresAt: user.expiresAt });
});

app.get('/api/mieru/client-config/:username', requireAuth, requireMieruEnabled, (req, res) => {
  const cfg = loadConfig();
  const user = (cfg.mieruUsers || []).find(u => u.username === req.params.username);
  if (!user) return res.status(404).json({ error: 'not found' });
  res.json({
    clientConfig: mieruClientConfig(user.username, user.password, cfg),
    mihomo: mieruMihomoSnippet(user.username, user.password, cfg)
  });
});

// ═══════════════════════════════════════════════════════════
//  LOGS / DIAGNOSTICS
// ═══════════════════════════════════════════════════════════
app.get('/api/logs/:kind', requireAuth, (req, res) => {
  const { kind } = req.params;
  if (kind === 'mieru' && !MIERU_ENABLED) return res.status(404).json({ error: 'Mieru module is disabled' });
  const lines = Math.max(10, Math.min(parseInt(req.query.lines || '60', 10) || 60, 500));
  const unitMap = {
    naive: CADDY_SERVICE,
    hy2: 'hysteria-server',
    mieru: 'mita',
    panel: 'pm2-root'
  };
  const unit = unitMap[kind];
  if (!unit) return res.status(400).json({ error: 'bad kind' });

  if (kind === 'panel') {
    // PM2 logs (panel сам себя)
    const p = spawn('pm2', ['logs', 'panel-naive-hy2', '--lines', String(lines), '--nostream', '--raw']);
    let out = '';
    p.stdout.on('data', d => out += d.toString());
    p.stderr.on('data', d => out += d.toString());
    p.on('close', () => res.json({ unit: 'pm2', output: out || '(no logs)' }));
    p.on('error', () => res.json({ unit: 'pm2', output: 'pm2 недоступен' }));
    return;
  }

  const p = spawn('journalctl', ['-u', unit, '-n', String(lines), '--no-pager', '--output=cat']);
  let out = '';
  p.stdout.on('data', d => out += d.toString());
  p.on('close', () => res.json({ unit, output: out || '(no logs)' }));
  p.on('error', () => res.json({ unit, output: 'journalctl недоступен' }));
});

// Диагностика портов: что слушает 443/tcp и 443/udp + сертификаты
app.get('/api/diag/ports', requireAuth, (req, res) => {
  const p = spawn('bash', ['-c',
    'echo "=== TCP/443 (Naive/Caddy) ==="; (ss -tlnp 2>/dev/null | grep -E ":443 " || echo "(никто не слушает)"); ' +
    'echo ""; echo "=== UDP/443 (Hysteria2) ==="; (ss -ulnp 2>/dev/null | grep -E ":443 " || echo "(никто не слушает)"); ' +
    'echo ""; echo "=== Статус сервисов ==="; ' +
    'echo "caddy:            $(systemctl is-active caddy 2>/dev/null || echo unknown)"; ' +
    'echo "hysteria-server:  $(systemctl is-active hysteria-server 2>/dev/null || echo unknown)"; ' +
    'echo ""; echo "=== Hysteria TLS ==="; ' +
    'if [ -f /etc/hysteria/config.yaml ]; then ' +
    '  TLS_CERT=$(grep -E "^\\s*cert:" /etc/hysteria/config.yaml 2>/dev/null | head -1 | sed "s/.*cert:\\s*//" | tr -d " "); ' +
    '  TLS_KEY=$(grep -E "^\\s*key:" /etc/hysteria/config.yaml 2>/dev/null | head -1 | sed "s/.*key:\\s*//" | tr -d " "); ' +
    '  ACME_ON=$(grep -c "^acme:" /etc/hysteria/config.yaml 2>/dev/null || echo 0); ' +
    '  if [ -n "$TLS_CERT" ]; then ' +
    '    echo "TLS mode: shared (Caddy cert)"; ' +
    '    echo "cert: $TLS_CERT"; ' +
    '    if [ -f "$TLS_CERT" ]; then echo "  └─ exists ✓ ($(stat -c %s "$TLS_CERT") bytes, perms $(stat -c %a "$TLS_CERT"))"; ' +
    '    else echo "  └─ FILE MISSING ✗ (Hy2 не сможет загрузиться!)"; fi; ' +
    '    echo "key:  $TLS_KEY"; ' +
    '    if [ -f "$TLS_KEY" ]; then echo "  └─ exists ✓ (perms $(stat -c %a "$TLS_KEY"))"; ' +
    '    else echo "  └─ FILE MISSING ✗"; fi; ' +
    '  elif [ "$ACME_ON" -gt 0 ]; then ' +
    '    echo "TLS mode: ACME (Hy2 сам получает cert)"; ' +
    '    echo "(убедитесь что порт 80/tcp свободен или что cert уже получен)"; ' +
    '  else echo "TLS: НЕ НАСТРОЕН в конфиге ✗"; fi; ' +
    'else echo "/etc/hysteria/config.yaml не найден"; fi; ' +
    'echo ""; echo "=== Masquerade ==="; ' +
    'if [ -f /etc/hysteria/config.yaml ]; then ' +
    '  MASQ_TYPE=$(awk "/^masquerade:/{f=1;next} f && /^[^ ]/{f=0} f && /type:/{print \\$2; exit}" /etc/hysteria/config.yaml); ' +
    '  echo "type: ${MASQ_TYPE:-(не задано)}"; ' +
    'fi'
  ]);
  let out = '';
  p.stdout.on('data', d => out += d.toString());
  p.on('close', () => res.json({ output: out }));
  p.on('error', () => res.json({ output: 'команды недоступны' }));
});

// Просмотр активного hysteria config.yaml (с маскировкой паролей)
app.get('/api/diag/hysteria-config', requireAuth, (req, res) => {
  const cfgPath = '/etc/hysteria/config.yaml';
  if (!fs.existsSync(cfgPath)) {
    return res.json({ exists: false, output: '/etc/hysteria/config.yaml не найден' });
  }
  try {
    let raw = fs.readFileSync(cfgPath, 'utf8');
    // Маскируем пароли userpass
    raw = raw.replace(/(\s+)([a-zA-Z0-9_.-]+)(:\s*)"[^"]+"/g,
      (m, sp, user, col) => `${sp}${user}${col}"***masked***"`);
    res.json({ exists: true, output: raw });
  } catch (e) {
    res.json({ exists: false, output: 'Ошибка чтения: ' + e.message });
  }
});

// ═══════════════════════════════════════════════════════════
//  HY2 TLS AUTO-FIX (заменяет acme: на tls: с путями к Caddy cert)
// ═══════════════════════════════════════════════════════════
// Частая проблема: при установке Caddy получил серт от ZeroSSL, install.sh
// искал только по пути Let's Encrypt, не нашёл → прописал acme: в Hy2 конфиге →
// Hy2 попытался получить свой серт LE → HTTP 429 rate limit на неделю.
// Этот endpoint находит фактический серт Caddy через find и переписывает
// секцию TLS Hy2 конфига.
app.post('/api/diag/fix-hy2-tls', requireAuth, async (req, res) => {
  try {
    const cfg = loadConfig();
    if (!cfg.stack || !cfg.stack.hy2) {
      return res.status(400).json({ ok: false, error: 'Hy2 не установлен' });
    }
    const domain = cfg.domain;
    if (!domain) {
      return res.status(400).json({ ok: false, error: 'Домен не задан в config' });
    }

    const certPair = findCaddyCertPair(domain);
    const certPath = certPair && certPair.cert;
    const keyPath = certPair && certPair.key;
    const ca = certPair && certPair.ca;

    if (!certPath) {
      return res.status(404).json({
        ok: false,
        error: 'Сертификат Caddy не найден на диске',
        hint: 'Caddy должен получить сертификат (проверьте: systemctl status caddy; journalctl -u caddy -n 50)'
      });
    }

    // Ставим права на сами файлы; рекурсивно открывать директории сертификатов нельзя.
    try {
      fs.chmodSync(certPath, 0o644);
      fs.chmodSync(keyPath, 0o640);
    } catch {}

    // Читаем config.yaml
    const hyCfgPath = '/etc/hysteria/config.yaml';
    let hyCfg = {};
    if (fs.existsSync(hyCfgPath)) {
      hyCfg = yaml.load(fs.readFileSync(hyCfgPath, 'utf8')) || {};
    }

    // Убираем acme: секцию, вставляем tls:
    delete hyCfg.acme;
    hyCfg.tls = { cert: certPath, key: keyPath };

    // Пишем обратно
    fs.writeFileSync(hyCfgPath, yaml.dump(hyCfg, { lineWidth: 120, quotingType: '"' }), 'utf8');

    // Сбрасываем счётчик рестартов и перезапускаем Hy2
    spawnSync('systemctl', ['reset-failed', 'hysteria-server'], { stdio: 'ignore' });
    const restart = spawnSync('systemctl', ['restart', 'hysteria-server'], { encoding: 'utf8' });
    if (restart.status !== 0 || restart.error) {
      return res.status(500).json({
        ok: false,
        error: 'Конфиг обновлён, но hysteria-server не перезапустился',
        details: restart.error ? restart.error.message : (restart.stderr || restart.stdout || `exit ${restart.status}`),
        certPath, keyPath, ca
      });
    }

    // Проверяем что стартовал
    await new Promise(r => setTimeout(r, 2500));
    let active = false;
    const isActive = spawnSync('systemctl', ['is-active', 'hysteria-server'], { encoding: 'utf8' });
    active = isActive.status === 0 && String(isActive.stdout || '').trim() === 'active';

    res.json({
      ok: active,
      message: active
        ? `Hy2 TLS починен — cert от ${ca}, сервис запущен`
        : `Конфиг обновлён, но сервис не активен. journalctl -u hysteria-server -n 30`,
      certPath, keyPath, ca
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

// ═══════════════════════════════════════════════════════════
//  SYSCTL TUNING
// ═══════════════════════════════════════════════════════════
app.get('/api/tuning/status', requireAuth, (req, res) => {
  const p = spawn('bash', ['-c',
    'echo cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown); ' +
    'echo qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown); ' +
    'echo rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown); ' +
    'echo wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)'
  ]);
  let out = '';
  p.stdout.on('data', d => out += d.toString());
  p.on('close', () => {
    const parsed = {};
    out.split('\n').forEach(line => {
      const [k, v] = line.split('=');
      if (k && v) parsed[k.trim()] = v.trim();
    });
    res.json({
      cc: parsed.cc || 'unknown',
      qdisc: parsed.qdisc || 'unknown',
      rmem_max: parsed.rmem_max || 'unknown',
      wmem_max: parsed.wmem_max || 'unknown',
      bbrOn: parsed.cc === 'bbr' && parsed.qdisc === 'fq',
      udpBufOk: Number(parsed.rmem_max || 0) >= 16777216
    });
  });
  p.on('error', () => res.json({ error: 'sysctl недоступен' }));
});

app.post('/api/tuning/apply', requireAuth, (req, res) => {
  const scriptPath = path.join(__dirname, '../scripts/sysctl_tune.sh');
  if (!fs.existsSync(scriptPath)) return res.json({ success: false, message: 'script not found' });
  const p = spawn('bash', [scriptPath]);
  let out = '', err = '';
  p.stdout.on('data', d => out += d.toString());
  p.stderr.on('data', d => err += d.toString());
  p.on('close', (code) => {
    res.json({ success: code === 0, output: out, error: err });
  });
  p.on('error', (e) => res.json({ success: false, message: e.message }));
});

// ═══════════════════════════════════════════════════════════
//  INSTALL VIA WEBSOCKET
// ═══════════════════════════════════════════════════════════
wss.on('connection', (ws, req) => {
  if (!isTrustedRequestOrigin(req)) {
    ws.send(JSON.stringify({ type: 'error', message: 'cross-site websocket denied' }));
    ws.close();
    return;
  }
  const wsRes = {
    getHeader() { return undefined; },
    setHeader() {},
    writeHead() {},
    end() {}
  };
  sessionMiddleware(req, wsRes, (err) => {
    if (err || !req.session || !req.session.authenticated) {
      ws.send(JSON.stringify({ type: 'error', message: 'unauthorized' }));
      ws.close();
      return;
    }

    ws.on('message', (message) => {
      try {
        const data = JSON.parse(message);
        if (data.type === 'install_naive') return handleInstallNaive(ws, data);
        if (data.type === 'install_hy2')   return handleInstallHy2(ws, data);
        if (data.type === 'install_mieru') return handleInstallMieru(ws, data);
        if (data.type === 'install_both')  return handleInstallBoth(ws, data);
      } catch (e) {
        ws.send(JSON.stringify({ type: 'error', message: 'bad message' }));
      }
    });
  });
});

function sendLog(ws, text, step = null, progress = null, level = 'info') {
  if (ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: 'log', text, step, progress, level }));
}

function parseLogLine(line) {
  const stepMap = [
    { p: /STEP:1/,    step: 'update',    progress: 8,  text: '📦 Обновление системы...' },
    { p: /STEP:2/,    step: 'bbr',       progress: 15, text: '⚡ BBR + UDP тюнинг...' },
    { p: /STEP:3/,    step: 'firewall',  progress: 22, text: '🛡 Файрволл...' },
    { p: /STEP:4/,    step: 'dl',        progress: 35, text: '📥 Загрузка бинарника...' },
    { p: /STEP:5/,    step: 'build',     progress: 60, text: '🔨 Сборка / настройка...' },
    { p: /STEP:6/,    step: 'config',    progress: 75, text: '📝 Конфигурация...' },
    { p: /STEP:7/,    step: 'service',   progress: 85, text: '⚙ Systemd сервис...' },
    { p: /STEP:8/,    step: 'start',     progress: 93, text: '🟢 Запуск...' },
    { p: /STEP:DONE/, step: 'done',      progress: 100, text: '✅ Готово!' },
  ];
  for (const s of stepMap) {
    if (s.p.test(line)) return { text: s.text, step: s.step, progress: s.progress, level: 'step' };
  }
  if (/error|ошибка|failed|fail/i.test(line)) return { text: line, level: 'error' };
  if (/warn|⚠/i.test(line)) return { text: line, level: 'warn' };
  if (/✅|✓|OK:/i.test(line)) return { text: line, level: 'success' };
  return { text: line, level: 'info' };
}

function runScript(ws, scriptName, env, onExit) {
  const scriptPath = path.join(__dirname, '../scripts', scriptName);
  if (!fs.existsSync(scriptPath)) {
    sendLog(ws, `❌ Скрипт ${scriptName} не найден!`, null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: scriptName + ' not found' }));
    return;
  }
  const child = spawn('bash', [scriptPath], { env: { ...process.env, ...env, DEBIAN_FRONTEND: 'noninteractive' } });

  child.stdout.on('data', (data) => {
    data.toString().split('\n').filter(l => l.trim()).forEach(line => {
      const parsed = parseLogLine(line);
      sendLog(ws, parsed.text, parsed.step, parsed.progress, parsed.level);
    });
  });
  child.stderr.on('data', (data) => {
    data.toString().split('\n').filter(l => l.trim()).forEach(line => {
      if (!line.includes('WARNING')) sendLog(ws, line, null, null, 'warn');
    });
  });
  child.on('close', onExit);
  child.on('error', (err) => {
    sendLog(ws, `❌ ${err.message}`, null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: err.message }));
  });
}

// Helper: вытянуть server_ip в конфиг
function persistServerIp(cfg) {
  const saveIp = (raw) => {
    const ip = String(raw || '').trim().split(/\s+/).find(Boolean);
    if (!ip) return;
    cfg.serverIp = ip;
    cfg.arch = require('os').arch();
    saveConfig(cfg);
  };

  const curl = spawn('curl', ['-4', '-s', '--connect-timeout', '5', 'ifconfig.me']);
  let curlOut = '';
  curl.stdout.on('data', d => curlOut += d.toString());
  curl.on('close', (code) => {
    if (code === 0 && curlOut.trim()) {
      saveIp(curlOut);
      return;
    }

    const hostname = spawn('hostname', ['-I']);
    let hostOut = '';
    hostname.stdout.on('data', d => hostOut += d.toString());
    hostname.on('close', () => saveIp(hostOut));
    hostname.on('error', () => {});
  });
  curl.on('error', () => {
    const hostname = spawn('hostname', ['-I']);
    let hostOut = '';
    hostname.stdout.on('data', d => hostOut += d.toString());
    hostname.on('close', () => saveIp(hostOut));
    hostname.on('error', () => {});
  });
}

function handleInstallNaive(ws, data) {
  const { domain, email, login, password } = data;
  if (!isValidDomain(domain)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный домен' }));
  if (!isValidEmail(email)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный email' }));
  if (!isValidUsername(login)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный логин' }));
  if (!isValidPassword(password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Пароль минимум 8 символов' }));

  const cfg = loadConfig();
  cfg.domain = domain;
  cfg.email = email;
  cfg.stack.naive = true;
  if (!cfg.naiveUsers.find(u => u.username === login)) {
    cfg.naiveUsers.push({ username: login, password, createdAt: new Date().toISOString() });
  }
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '🚀 Запуск установки NaiveProxy...', 'init', 2, 'info');
  runScript(ws, 'install_naiveproxy.sh', {
    NAIVE_DOMAIN: domain, NAIVE_EMAIL: email,
    NAIVE_LOGIN: login, NAIVE_PASSWORD: password
  }, (code) => {
    if (code === 0) {
      cfg.installed = true;
      saveConfig(cfg);
      sendLog(ws, '✅ NaiveProxy готов!', 'done', 100, 'success');
      ws.send(JSON.stringify({
        type: 'install_done',
        links: {
          naive: naiveLink(login, password, domain)
        }
      }));
    } else {
      ws.send(JSON.stringify({ type: 'install_error', message: `Exit code: ${code}` }));
    }
  });
}

function handleInstallHy2(ws, data) {
  const { domain, email, password, useCaddyCert } = data;
  if (!isValidDomain(domain)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный домен' }));
  if (!isValidEmail(email)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный email' }));
  if (!isValidPassword(password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Пароль минимум 8 символов' }));

  const cfg = loadConfig();
  cfg.domain = domain;
  cfg.email = email;
  cfg.stack.hy2 = true;
  if (!cfg.hy2Users.find(u => u.username === 'default')) {
    cfg.hy2Users.push({ username: 'default', password, createdAt: new Date().toISOString() });
  } else {
    cfg.hy2Users.find(u => u.username === 'default').password = password;
  }
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '⚡ Запуск установки Hysteria2...', 'init', 2, 'info');
  runScript(ws, 'install_hysteria.sh', {
    HY_DOMAIN: domain, HY_EMAIL: email, HY_PASSWORD: password,
    USE_CADDY_CERT: useCaddyCert ? '1' : '0'
  }, (code) => {
    if (code === 0) {
      cfg.installed = true;
      saveConfig(cfg);
      sendLog(ws, '✅ Hysteria2 готова!', 'done', 100, 'success');
      ws.send(JSON.stringify({
        type: 'install_done',
        links: {
          hy2: hy2Link('default', password, domain, 'NHM')
        }
      }));
    } else {
      ws.send(JSON.stringify({ type: 'install_error', message: `Exit code: ${code}` }));
    }
  });
}

function handleInstallMieru(ws, data) {
  if (!MIERU_ENABLED) {
    return ws.send(JSON.stringify({
      type: 'install_error',
      message: 'Mieru модуль выключен. Запустите установку панели с флагом --with-mieru.'
    }));
  }
  const { username, password, port, protocol } = data;
  const mieruPort = parseInt(port || '0', 10);
  const mieruProtocol = normalizeMieruProtocol(protocol);
  if (!isValidUsername(username)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный Mieru логин' }));
  if (!isValidPassword(password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Mieru пароль минимум 8 символов' }));
  if (!isValidPort(mieruPort)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Mieru порт должен быть 1025..65535' }));

  const cfg = loadConfig();
  cfg.installed = true;
  cfg.stack.mieru = true;
  cfg.mieruPort = mieruPort;
  cfg.mieruProtocol = mieruProtocol;
  if (!cfg.serverIp) cfg.serverIp = '';
  const existingMieruUser = cfg.mieruUsers.find(u => u.username === username);
  if (existingMieruUser) {
    existingMieruUser.password = password;
  } else {
    cfg.mieruUsers.push({ username, password, createdAt: new Date().toISOString() });
  }
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '🔭 Запуск установки Mieru/mita...', 'init', 2, 'info');
  runScript(ws, 'install_mieru.sh', {
    MIERU_LOGIN: username,
    MIERU_PASSWORD: password,
    MIERU_PORT: String(mieruPort),
    MIERU_PROTOCOL: mieruProtocol,
    MIERU_CONFIG: MIERU_CONFIG_PATH
  }, (code) => {
    if (code === 0) {
      cfg.installed = true;
      saveConfig(cfg);
      sendLog(ws, '✅ Mieru готов!', 'done', 100, 'success');
      ws.send(JSON.stringify({
        type: 'install_done',
        links: {
          mieru: JSON.stringify(mieruClientConfig(username, password, cfg), null, 2)
        }
      }));
    } else {
      ws.send(JSON.stringify({ type: 'install_error', message: `Mieru failed: ${code}` }));
    }
  });
}

function handleInstallBoth(ws, data) {
  const { domain, email, naiveLogin, naivePassword, hy2Password } = data;
  if (!isValidDomain(domain)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный домен' }));
  if (!isValidEmail(email)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный email' }));
  if (!isValidUsername(naiveLogin)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Неверный Naive логин' }));
  if (!isValidPassword(naivePassword)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Naive пароль 8+ символов' }));
  if (!isValidPassword(hy2Password)) return ws.send(JSON.stringify({ type: 'install_error', message: 'Hy2 пароль 8+ символов' }));

  const cfg = loadConfig();
  cfg.domain = domain;
  cfg.email = email;
  cfg.stack.naive = true;
  cfg.stack.hy2 = true;
  if (!cfg.naiveUsers.find(u => u.username === naiveLogin)) {
    cfg.naiveUsers.push({ username: naiveLogin, password: naivePassword, createdAt: new Date().toISOString() });
  }
  const existDef = cfg.hy2Users.find(u => u.username === 'default');
  if (existDef) existDef.password = hy2Password;
  else cfg.hy2Users.push({ username: 'default', password: hy2Password, createdAt: new Date().toISOString() });
  saveConfig(cfg);
  persistServerIp(cfg);

  sendLog(ws, '🚀 Установка Naive + Hy2 последовательно...', 'init', 2, 'info');

  runScript(ws, 'install_naiveproxy.sh', {
    NAIVE_DOMAIN: domain, NAIVE_EMAIL: email,
    NAIVE_LOGIN: naiveLogin, NAIVE_PASSWORD: naivePassword,
    WITH_HY2: '1'  // отключит HTTP/3 в Caddy → UDP/443 свободен для Hy2
  }, (codeNaive) => {
    if (codeNaive !== 0) {
      ws.send(JSON.stringify({ type: 'install_error', message: `Naive failed: ${codeNaive}` }));
      return;
    }
    sendLog(ws, '✅ Naive ок, запускаю Hy2...', null, 50, 'success');
    runScript(ws, 'install_hysteria.sh', {
      HY_DOMAIN: domain, HY_EMAIL: email, HY_PASSWORD: hy2Password,
      USE_CADDY_CERT: '1'
    }, (codeHy) => {
      if (codeHy === 0) {
        cfg.installed = true;
        saveConfig(cfg);
        sendLog(ws, '✅ Оба протокола готовы!', 'done', 100, 'success');
        ws.send(JSON.stringify({
          type: 'install_done',
          links: {
            naive: naiveLink(naiveLogin, naivePassword, domain),
            hy2:   hy2Link('default', hy2Password, domain, 'NHM')
          }
        }));
      } else {
        ws.send(JSON.stringify({ type: 'install_error', message: `Hy2 failed: ${codeHy}` }));
      }
    });
  });
}

// ═══════════════════════════════════════════════════════════
//  EXPIRE CHECKER — каждые 5 минут фильтрует истёкших и релоадит сервисы
// ═══════════════════════════════════════════════════════════
let _lastExpireSig = '';
async function expireChecker() {
  try {
    const cfg = loadConfig();
    if (!cfg.installed) return;

    // Сигнатура «кто истёк» — чтобы не релоадить без причины
    const sig = JSON.stringify([
      (cfg.naiveUsers || []).filter(isExpired).map(u => u.username).sort(),
      (cfg.hy2Users   || []).filter(isExpired).map(u => u.username).sort(),
      (cfg.mieruUsers || []).filter(isExpired).map(u => u.username).sort()
    ]);
    if (sig === _lastExpireSig) return;
    _lastExpireSig = sig;

    const naiveExpired = (cfg.naiveUsers || []).filter(isExpired).length;
    const hy2Expired   = (cfg.hy2Users   || []).filter(isExpired).length;
    const mieruExpired = (cfg.mieruUsers || []).filter(isExpired).length;
    if (naiveExpired === 0 && hy2Expired === 0 && mieruExpired === 0) return;

    console.log(`[expire-check] naive=${naiveExpired} hy2=${hy2Expired} mieru=${mieruExpired} — обновляю конфиги`);
    if (cfg.stack.naive && naiveExpired > 0) {
      writeCaddyfile(cfg);
      await reloadCaddy();
    }
    if (cfg.stack.hy2 && hy2Expired > 0) {
      writeHysteriaConfig(cfg);
      await reloadHysteria();
    }
    if (cfg.stack.mieru && mieruExpired > 0) {
      await applyMieruConfig(cfg);
    }
  } catch (e) {
    console.error('[expire-check] error:', e.message);
  }
}
setInterval(expireChecker, 5 * 60 * 1000);
setTimeout(expireChecker, 20 * 1000); // первый запуск через 20 сек после старта

// ─── SPA fallback ─────────────────────────────────────────
app.get(/^(?!\/api).*/, (req, res) => {
  res.sendFile(path.join(__dirname, '../public/index.html'));
});

server.listen(PORT, LISTEN_HOST, () => {
  const isLocal = LISTEN_HOST === '127.0.0.1' || LISTEN_HOST === 'localhost';
  console.log(`\n╔═══════════════════════════════════════════════╗`);
  console.log(`║   NHM Panel            ║`);
  console.log(`║   Running on http://${LISTEN_HOST}:${PORT}${' '.repeat(Math.max(0, 14 - LISTEN_HOST.length))}║`);
  if (isLocal) {
    console.log(`║   SSH-only mode (доступ через ssh -L)         ║`);
  }
  console.log(`╚═══════════════════════════════════════════════╝\n`);
});
