'use strict';
/*
 * Apple Music Now Playing – Stream Deck Plugin (Windows)
 * Ohne externe Abhängigkeiten: eigener kleiner WebSocket-Client + PowerShell-Helfer für die
 * Windows-Mediensteuerung (SMTC), über die Apple Music Titel, Künstler, Cover und Position meldet.
 */
const net = require('net');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const readline = require('readline');
const { spawn } = require('child_process');

const PLUGIN_DIR = path.join(__dirname, '..');
const LOG_FILE = path.join(PLUGIN_DIR, 'plugin.log');
const PLACEHOLDER_FRAME = 'imgs/display-idle.png';
const ACTIONS = {
  nowplaying: 'de.local.applemusic.nowplaying',
  playpause: 'de.local.applemusic.playpause',
  next: 'de.local.applemusic.next',
  previous: 'de.local.applemusic.previous',
  volume: 'de.local.applemusic.volume',
  shuffle: 'de.local.applemusic.shuffle',
  repeat: 'de.local.applemusic.repeat',
  open: 'de.local.applemusic.open',
};
const PLACEHOLDER_VOLUME = 'imgs/display-volume.png';

// ---------- Logging ----------
try { if (fs.statSync(LOG_FILE).size > 512 * 1024) fs.unlinkSync(LOG_FILE); } catch (_) { /* ignore */ }
function log(...parts) {
  try { fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${parts.join(' ')}\n`); } catch (_) { /* ignore */ }
}

// ---------- Startparameter von Stream Deck ----------
const args = {};
for (let i = 2; i < process.argv.length - 1; i += 2) args[process.argv[i].replace(/^-+/, '')] = process.argv[i + 1];

// ---------- Minimaler WebSocket-Client (RFC 6455) ----------
class MiniWebSocket {
  constructor(port, handlers) {
    this.port = Number(port);
    this.h = handlers;
    this.buf = Buffer.alloc(0);
    this.frags = [];
    this.open = false;
  }

  connect() {
    this.sock = net.connect(this.port, '127.0.0.1', () => {
      const key = crypto.randomBytes(16).toString('base64');
      this.sock.write(
        `GET / HTTP/1.1\r\nHost: 127.0.0.1:${this.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
        `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`
      );
    });
    this.sock.setNoDelay(true);
    this.sock.on('data', (d) => { this.buf = Buffer.concat([this.buf, d]); this._process(); });
    this.sock.on('close', () => { this.open = false; this.h.onClose && this.h.onClose(); });
    this.sock.on('error', (e) => log('socket error', e.message));
  }

  _process() {
    if (!this.open) {
      const end = this.buf.indexOf('\r\n\r\n');
      if (end < 0) return;
      const head = this.buf.subarray(0, end).toString();
      if (!/^HTTP\/1\.1 101/.test(head)) { log('handshake failed:', head); this.sock.destroy(); return; }
      this.buf = this.buf.subarray(end + 4);
      this.open = true;
      this.h.onOpen && this.h.onOpen();
    }
    while (this.buf.length >= 2) {
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const fin = (b0 & 0x80) !== 0;
      const op = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let off = 2;
      if (len === 126) { if (this.buf.length < 4) return; len = this.buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (this.buf.length < 10) return; len = Number(this.buf.readBigUInt64BE(2)); off = 10; }
      let mask = null;
      if (masked) { if (this.buf.length < off + 4) return; mask = this.buf.subarray(off, off + 4); off += 4; }
      if (this.buf.length < off + len) return;
      const payload = Buffer.from(this.buf.subarray(off, off + len));
      this.buf = this.buf.subarray(off + len);
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];

      if (op === 0x8) { this.sock.end(); return; }          // close
      if (op === 0x9) { this._send(0xA, payload); continue; } // ping -> pong
      if (op === 0xA) continue;                               // pong
      this.frags.push(payload);
      if (fin) {
        const msg = Buffer.concat(this.frags).toString('utf8');
        this.frags = [];
        try { this.h.onMessage && this.h.onMessage(msg); } catch (e) { log('handler error', e.stack || e.message); }
      }
    }
  }

  _send(op, data) {
    const len = data.length;
    let header;
    if (len < 126) { header = Buffer.alloc(2); header[1] = 0x80 | len; }
    else if (len < 65536) { header = Buffer.alloc(4); header[1] = 0x80 | 126; header.writeUInt16BE(len, 2); }
    else { header = Buffer.alloc(10); header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(len), 2); }
    header[0] = 0x80 | op;
    const mask = crypto.randomBytes(4);
    const body = Buffer.alloc(len);
    for (let i = 0; i < len; i++) body[i] = data[i] ^ mask[i & 3];
    this.sock.write(Buffer.concat([header, mask, body]));
  }

  send(obj) {
    if (!this.open) return;
    this._send(0x1, Buffer.from(JSON.stringify(obj), 'utf8'));
  }
}

// ---------- Zustand ----------
const contexts = new Map(); // context -> { action, settings, last: {} }
let media = { active: false };
let art = { key: null, data: null };
let frame = null;
let volFrame = null;
let keyImgs = null;

const defaultSettings = { rotate: 'tracks', source: 'apple', seekStep: 5, volStep: 2 };
const settingsOf = (c) => Object.assign({}, defaultSettings, (c && c.settings) || {});

// ---------- Hilfsprozess (PowerShell / SMTC) ----------
let helper = null;
let helperMode = 'apple';
let restartDelay = 1000;
let restartTimer = null;

function wantedMode() {
  for (const c of contexts.values()) if (settingsOf(c).source === 'any') return 'any';
  return 'apple';
}

function startHelper() {
  if (helper || restartTimer) return;
  const ps = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const script = path.join(__dirname, 'media-helper.ps1');
  helperMode = wantedMode();
  log('starting helper, mode', helperMode, '| plugin', require('../manifest.json').Version);
  // Skript als ScriptBlock laden statt per -File: funktioniert auch, wenn Skriptausführung per Richtlinie gesperrt ist.
  const cmd = `& ([ScriptBlock]::Create([IO.File]::ReadAllText('${script.replace(/'/g, "''")}'))) -Mode ${helperMode}`;
  helper = spawn(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd], {
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  renderOn = null; volOn = null; // nach (Neu-)Start Zustand erneut senden
  readline.createInterface({ input: helper.stdout }).on('line', onHelperLine);
  readline.createInterface({ input: helper.stderr }).on('line', (l) => log('helper:', l));
  helper.on('error', (e) => log('helper spawn error', e.message));
  syncHelperMode();
  helper.on('exit', (code) => {
    log('helper exited', code);
    helper = null;
    restartTimer = setTimeout(() => { restartTimer = null; startHelper(); }, restartDelay);
    restartDelay = Math.min(restartDelay * 2, 30000);
  });
}

function helperCmd(cmd) {
  if (helper && helper.stdin.writable) helper.stdin.write(cmd + '\n');
}

let renderOn = null;
let volOn = null;
function syncHelperMode() {
  const m = wantedMode();
  if (m !== helperMode) { helperMode = m; helperCmd('mode:' + m); }
  const r = [...contexts.values()].some((c) => c.action === ACTIONS.nowplaying);
  if (r !== renderOn) { renderOn = r; helperCmd(r ? 'render:on' : 'render:off'); }
  const v = [...contexts.values()].some((c) => c.action === ACTIONS.volume);
  if (v !== volOn) { volOn = v; helperCmd(v ? 'volrender:on' : 'volrender:off'); }
}

function onHelperLine(line) {
  line = line.replace(/^\uFEFF/, '').trim();
  if (!line.startsWith('{')) { if (line) log('helper stdout:', line.slice(0, 300)); return; }
  let msg;
  try { msg = JSON.parse(line); } catch (_) { return; }
  restartDelay = 1000;
  if (msg.type === 'hello') {
    log('helper ready');
  } else if (msg.type === 'keyimgs') {
    keyImgs = msg.imgs;
    renderAll();
  } else if (msg.type === 'volframe') {
    volFrame = msg.data;
    for (const [ctx, c] of contexts) if (c.action === ACTIONS.volume) renderVolume(ctx, c);
  } else if (msg.type === 'frame') {
    frame = msg.data;
    for (const [ctx, c] of contexts) if (c.action === ACTIONS.nowplaying) renderDial(ctx, c);
  } else if (msg.type === 'art') {
    art = { key: msg.key, data: msg.data };
    renderAll();
  } else if (msg.type === 'state') {
    if (msg.active !== media.active || msg.key !== media.key) log('state:', msg.active ? `aktiv (${msg.app}) ${msg.status}: ${msg.title}` : 'keine Wiedergabe gefunden');
    media = normalize(msg);
    if (media.key !== art.key) art = { key: null, data: null };
    renderAll();
  }
}

// Apple Music für Windows schreibt teils "Künstler — Album" in das Künstlerfeld.
function normalize(m) {
  if (!m.active) return m;
  let artist = m.artist || '';
  let album = m.album || '';
  const sep = artist.indexOf(' \u2014 ');
  if (sep > 0) {
    if (!album) album = artist.slice(sep + 3);
    artist = artist.slice(0, sep);
  }
  return Object.assign({}, m, { artist, album });
}

// ---------- Darstellung ----------
const fmt = (s) => {
  s = Math.max(0, Math.floor(s || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
};

function renderAll() {
  for (const [ctx, c] of contexts) renderContext(ctx, c);
}

function renderContext(ctx, c) {
  switch (c.action) {
    case ACTIONS.nowplaying: return renderDial(ctx, c);
    case ACTIONS.volume: return renderVolume(ctx, c);
    case ACTIONS.playpause: return renderPlayPauseKey(ctx, c);
    case ACTIONS.next: return setKeyImg(ctx, c, 'next');
    case ACTIONS.previous: return setKeyImg(ctx, c, 'previous');
    case ACTIONS.open: return setKeyImg(ctx, c, 'open');
    case ACTIONS.shuffle: return setKeyImg(ctx, c, media.active && media.shuffle ? 'shuffle_on' : 'shuffle_off');
    case ACTIONS.repeat: {
      const r = media.active ? media.repeat : '';
      return setKeyImg(ctx, c, r === 'List' ? 'repeat_all' : r === 'Track' ? 'repeat_one' : 'repeat_off');
    }
    default: return undefined;
  }
}

function setKeyImg(ctx, c, name) {
  if (!keyImgs || !keyImgs[name] || c.last.img === name) return;
  c.last.img = name;
  ws.send({ event: 'setImage', context: ctx, payload: { image: keyImgs[name], target: 0 } });
}

function renderVolume(ctx, c) {
  const img = volFrame || PLACEHOLDER_VOLUME;
  if (c.last.frame === img) return;
  c.last.frame = img;
  ws.send({ event: 'setFeedback', context: ctx, payload: { canvas: img } });
}

function renderDial(ctx, c) {
  // Das komplette Feld wird vom Helfer als PNG im Apple-Music-Stil gezeichnet.
  const img = frame || PLACEHOLDER_FRAME;
  if (c.last.frame === img) return;
  c.last.frame = img;
  ws.send({ event: 'setFeedback', context: ctx, payload: { canvas: img } });
}

function svgDataUrl(svg) {
  return 'data:image/svg+xml;base64,' + Buffer.from(svg, 'utf8').toString('base64');
}

function renderPlayPauseKey(ctx, c) {
  const playing = media.active && media.status === 'Playing';
  const key = `${art.data ? art.key : 'none'}|${playing}|${media.active}`;
  if (c.last.key === key) return;
  c.last.key = key;

  if (!media.active || !art.data) {
    // Standardbild aus dem Manifest
    ws.send({ event: 'setImage', context: ctx, payload: { target: 0 } });
    return;
  }
  const overlay = playing
    ? ''
    : '<rect width="144" height="144" fill="#000" fill-opacity="0.55"/>' +
      '<polygon points="56,42 56,102 104,72" fill="#FFFFFF"/>';
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="144" height="144" viewBox="0 0 144 144">' +
    `<image x="0" y="0" width="144" height="144" preserveAspectRatio="xMidYMid slice" xlink:href="${art.data}"/>` +
    overlay +
    '</svg>';
  ws.send({ event: 'setImage', context: ctx, payload: { image: svgDataUrl(svg), target: 0 } });
}

// ---------- Eingaben ----------
let lastSkip = 0;
function onRotate(c, ticks) {
  const s = settingsOf(c);
  if (s.rotate === 'seek') {
    helperCmd(`seek:${ticks * (Number(s.seekStep) || 5)}`);
  } else {
    const now = Date.now();
    if (now - lastSkip < 300) return; // nicht bei jedem Rastpunkt mehrfach springen
    lastSkip = now;
    helperCmd(ticks > 0 ? 'next' : 'prev');
  }
}

function onStreamDeckMessage(raw) {
  const msg = JSON.parse(raw);
  const { event, context, action, payload = {} } = msg;

  switch (event) {
    case 'willAppear':
      contexts.set(context, { action, settings: payload.settings || {}, last: {} });
      startHelper();
      syncHelperMode();
      renderContext(context, contexts.get(context));
      break;
    case 'willDisappear':
      contexts.delete(context);
      syncHelperMode();
      break;
    case 'didReceiveSettings': {
      const c = contexts.get(context);
      if (c) { c.settings = payload.settings || {}; syncHelperMode(); }
      break;
    }
    case 'dialRotate': {
      const c = contexts.get(context);
      if (!c || !payload.ticks) break;
      if (action === ACTIONS.volume) helperCmd(`vol:${payload.ticks * (Number(settingsOf(c).volStep) || 2)}`);
      else onRotate(c, payload.ticks);
      break;
    }
    case 'dialDown':
    case 'touchTap':
      helperCmd(action === ACTIONS.volume ? 'mute' : 'toggle');
      break;
    case 'dialPress': // ältere Stream-Deck-Versionen
      if (payload.pressed) helperCmd(action === ACTIONS.volume ? 'mute' : 'toggle');
      break;
    case 'keyDown': {
      const cmd = {
        [ACTIONS.playpause]: 'toggle',
        [ACTIONS.next]: 'next',
        [ACTIONS.previous]: 'prev',
        [ACTIONS.shuffle]: 'shuffle',
        [ACTIONS.repeat]: 'repeat',
        [ACTIONS.open]: 'open',
      }[action];
      if (cmd) helperCmd(cmd);
      break;
    }
    default:
      break;
  }
}

// ---------- Start ----------
const ws = new MiniWebSocket(args.port, {
  onOpen: () => {
    log('connected to Stream Deck');
    ws.send({ event: args.registerEvent, uuid: args.pluginUUID });
  },
  onMessage: onStreamDeckMessage,
  onClose: () => {
    log('Stream Deck connection closed');
    if (helper) helper.kill();
    process.exit(0);
  },
});

process.on('exit', () => { if (helper) try { helper.kill(); } catch (_) { /* ignore */ } });
process.on('uncaughtException', (e) => log('uncaught', e.stack || e.message));

if (require.main === module && args.port) ws.connect();

module.exports = { MiniWebSocket, normalize, fmt };
