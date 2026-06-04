// Kaltura analytics event receiver — Kanalony stand-in for Kaltura CE.
//
// The V2 mwEmbed (kwidget) and V7 PlayKit (kava) players POST/GET analytics
// beacons to {analytics_host}/api_v3/index.php?service=analytics&action=trackEvent.
// CE has no ingestion endpoint (it is a closed-source SaaS service), so Apache
// proxies that path here. We ENRICH each beacon (entry owner/categories/media
// type/duration from the DB, geo from IP, derived percentiles) and ingest the
// exact Druid row shape kKavaBase/kKavaReportsMgr query, so the analytics-front-
// end views resolve: Engagement, Technology, Geo, Contributors, completion rate
// and the per-entry engagement heatmap.
//
// Out of scope by design (NOT player-beacon data):
//   • Usage (bandwidth/storage/transcoding) — server-side feed, never in a beacon.
//   • Real-Time tab — needs a low-latency streaming pipeline (Kafka supervisor),
//     not batch ingestion.

const http = require('http');
const crypto = require('crypto');
const mysql = require('mysql2/promise');
const geoip = require('geoip-lite');

// ── Config ───────────────────────────────────────────────────────────────────
const DRUID_OVERLORD   = process.env.DRUID_OVERLORD || 'http://druid-coordinator:8081';
const DATASOURCE       = 'player-events-historical';
const FLUSH_INTERVAL_MS = parseInt(process.env.FLUSH_INTERVAL_MS || '15000', 10);
const MAX_BUFFER       = parseInt(process.env.MAX_BUFFER || '500', 10);
const PORT             = parseInt(process.env.PORT || '9999', 10);
const SESSION_TTL_MS   = 30 * 60 * 1000;     // forget idle sessions after 30 min
// One view-period delta is normally ~10s; allow larger gaps (backgrounded tab,
// missed heartbeats) but reject clearly-corrupt jumps so a cumulative reset or
// garbage value cannot inflate Minutes Viewed.
const MAX_PERIOD_SEC   = 600;

const DB = {
  host: process.env.DB1_HOST || process.env.DB_HOST || 'mysql',
  port: parseInt(process.env.DB1_PORT || '3306', 10),
  user: process.env.DB1_USER || 'kaltura',
  password: process.env.DB1_PASS || 'kaltura123',
  database: process.env.DB1_NAME || 'kaltura',
};

// ── KAVA numeric eventType -> kKavaBase string dimension value (KB 115-157) ──
const EVENT_TYPE_MAP = {
  1: 'playerImpression', 2: 'playRequested', 3: 'play', 4: 'resume',
  11: 'playThrough25', 12: 'playThrough50', 13: 'playThrough75', 14: 'playThrough100',
  16: 'replay', 17: 'seek', 18: 'editClicked', 19: 'shareClicked', 20: 'shared',
  21: 'downloadClicked', 22: 'reportClicked', 24: 'enterFullscreen', 25: 'exitFullscreen',
  32: 'info', 33: 'pauseClicked', 34: 'replay', 35: 'seek', 38: 'captions',
  39: 'sourceSelected', 41: 'speed', 43: 'flavorSwitch', 45: 'bufferStart',
  46: 'bufferStart', 48: 'error', 98: 'error', 99: 'viewPeriod',
};

// Kaltura KalturaMediaType int -> string
const MEDIA_TYPE_MAP = { 1: 'VIDEO', 2: 'IMAGE', 5: 'AUDIO' };

// ── Minimal User-Agent parser (no deps) → browser / os / device ──────────────
function parseUA(ua) {
  ua = ua || '';
  let browser = 'Other', browserFamily = 'Other', os = 'Other', osFamily = 'Other', device = 'Desktop';
  if (/Edg\//.test(ua)) browser = browserFamily = 'Edge';
  else if (/OPR\/|Opera/.test(ua)) browser = browserFamily = 'Opera';
  else if (/Chrome\//.test(ua) && !/Chromium/.test(ua)) browser = browserFamily = 'Chrome';
  else if (/Chromium/.test(ua)) { browser = 'Chromium'; browserFamily = 'Chrome'; }
  else if (/Firefox\//.test(ua)) browser = browserFamily = 'Firefox';
  else if (/Version\/.*Safari/.test(ua)) browser = browserFamily = 'Safari';
  else if (/MSIE|Trident/.test(ua)) browser = browserFamily = 'Internet Explorer';
  if (/Windows NT/.test(ua)) os = osFamily = 'Windows';
  else if (/Mac OS X/.test(ua) && !/iPhone|iPad/.test(ua)) os = osFamily = 'macOS';
  else if (/Android/.test(ua)) os = osFamily = 'Android';
  else if (/iPhone|iPad|iPod/.test(ua)) os = osFamily = 'iOS';
  else if (/Linux/.test(ua)) os = osFamily = 'Linux';
  if (/iPad|Tablet/.test(ua)) device = 'Tablet';
  else if (/Mobi|iPhone|Android.*Mobile/.test(ua)) device = 'Mobile';
  return { browser, browserFamily, os, osFamily, device };
}

const md5 = (s) => crypto.createHash('md5').update(String(s)).digest('hex');
const domainFromReferrer = (ref) => { try { return new URL(ref).hostname; } catch { return ''; } };
const num = (v, d = 0) => { const n = parseFloat(v); return isNaN(n) ? d : n; };

// ── Entry enrichment (cached DB lookup) ──────────────────────────────────────
// Maps an entryId to its owner, media type, duration and categories so the
// Contributors / category / completion reports resolve. Kanalony does this via
// the admin API; we read the operational DB directly (read-only) with a cache.
let pool = null;
const entryCache = new Map(); // entryId -> { ownerId, mediaType, durationSec, categories }
async function enrichEntry(entryId) {
  if (entryCache.has(entryId)) return entryCache.get(entryId);
  let meta = { ownerId: '', mediaType: 'VIDEO', durationSec: 0, categories: [] };
  if (pool) {
    try {
      const [rows] = await pool.query(
        'SELECT puser_id, media_type, length_in_msecs FROM entry WHERE id = ? LIMIT 1', [entryId]);
      if (rows.length) {
        meta.ownerId = String(rows[0].puser_id || '');
        meta.mediaType = MEDIA_TYPE_MAP[rows[0].media_type] || 'VIDEO';
        meta.durationSec = Math.round((rows[0].length_in_msecs || 0) / 1000);
      }
      const [cats] = await pool.query(
        "SELECT c.full_name FROM category_entry ce JOIN category c ON c.id = ce.category_id " +
        "WHERE ce.entry_id = ? AND ce.status = 1 LIMIT 20", [entryId]);
      meta.categories = cats.map((r) => String(r.full_name || '')).filter(Boolean);
    } catch (e) {
      console.error(`[receiver] entry enrich error (${entryId}): ${e.message}`);
    }
  }
  entryCache.set(entryId, meta);
  return meta;
}

// ── Per-session state (accurate minutes, dedup, completion) ──────────────────
const sessions = new Map(); // sessionId -> { lastSeen, lastPlayTime, maxPct, seen:Set }
function sessionState(id) {
  let s = sessions.get(id);
  if (!s) { s = { lastSeen: Date.now(), lastPlayTime: 0, maxPct: 0, seen: new Set() }; sessions.set(id, s); }
  s.lastSeen = Date.now();
  return s;
}
setInterval(() => {
  const cutoff = Date.now() - SESSION_TTL_MS;
  for (const [id, s] of sessions) if (s.lastSeen < cutoff) sessions.delete(id);
}, SESSION_TTL_MS).unref();

function parseParams(req, body) {
  const url = new URL(req.url, 'http://localhost');
  const params = {};
  for (const [k, v] of url.searchParams) params[k] = v;
  if (body) {
    const ct = (req.headers['content-type'] || '').toLowerCase();
    try {
      if (ct.includes('application/json')) Object.assign(params, JSON.parse(body));
      else for (const pair of body.split('&')) {
        const i = pair.indexOf('=');
        if (i > 0) params[decodeURIComponent(pair.slice(0, i))] =
          decodeURIComponent(pair.slice(i + 1).replace(/\+/g, ' '));
      }
    } catch { /* ignore malformed body */ }
  }
  return params;
}

// ── Build the enriched Druid row from a beacon ───────────────────────────────
async function buildRow(p, req) {
  const eventType = EVENT_TYPE_MAP[parseInt(p.eventType, 10)];
  if (!eventType) return null;
  const partnerId = String(p.partnerId || p.partner_id || '');
  const entryId = String(p.entryId || p.entry_id || '');
  if (!partnerId || !entryId) return null;

  const sessionId = String(p.sessionId || p.playbackSessionId || '');
  const eventIndex = String(p.eventIndex || '');
  const session = sessionId ? sessionState(sessionId) : null;

  // Dedup: same (eventType,eventIndex) within a session is a retransmit.
  if (session && eventIndex) {
    const key = eventType + ':' + eventIndex;
    if (session.seen.has(key)) return null;
    session.seen.add(key);
  }

  const uaRaw = req.headers['user-agent'] || '';
  const ua = parseUA(uaRaw);
  const clientIp = String((req.headers['x-forwarded-for'] || '').split(',')[0].trim()
    || req.socket.remoteAddress || '');
  // Unique viewer identity: logged-in user when present, else an IP+UA
  // fingerprint so a page reload counts as the SAME viewer (not a new one).
  const userKey = String(p.userId || p.kuserId || (clientIp + '|' + uaRaw));

  const meta = await enrichEntry(entryId);
  const geo = geoip.lookup(clientIp) || null;
  const position = num(p.position, 0);

  // ── Derived play-time + percentile (for Minutes Viewed, completion, heatmap) ──
  let playTimeSum = 0, percentile = 0, uniquePercentiles = 0;
  if (eventType === 'viewPeriod') {
    // Beacon playTimeSum is cumulative; the per-period delta is the real play time.
    const cur = num(p.playTimeSum, 0);
    let delta = cur - (session ? session.lastPlayTime : 0);
    if (delta < 0 || delta > MAX_PERIOD_SEC) delta = 0; // seek/reset/garbage
    if (session) session.lastPlayTime = cur;
    playTimeSum = delta;
    // Percentile reached at this point in the video → heatmap + completion.
    if (meta.durationSec > 0) percentile = Math.max(0, Math.min(100, Math.round(position / meta.durationSec * 100)));
    if (session) {
      // Completion = final max percentile; emit only the increase so the longSum
      // of uniquePercentiles over a session equals its max percentile.
      uniquePercentiles = Math.max(0, percentile - session.maxPct);
      if (percentile > session.maxPct) session.maxPct = percentile;
    } else {
      uniquePercentiles = percentile;
    }
  } else if (eventType.startsWith('playThrough')) {
    playTimeSum = num(p.playTimeSum, 0);
    percentile = { playThrough25: 25, playThrough50: 50, playThrough75: 75, playThrough100: 100 }[eventType] || 0;
  }

  // ── QoE metrics + eventProperties flags (KB 238-245) ──
  const eventProperties = [];
  const bitrate = num(p.actualBitrate, 0) || num(p.averageBitrate, 0);
  let bitrateSum = 0, bitrateCount = 0;
  if (bitrate > 0 && eventType === 'viewPeriod') { bitrateSum = bitrate; bitrateCount = 1; eventProperties.push('hasBitrate'); }
  const bufferTime = num(p.bufferTime, 0);
  let bufferTimeSum = 0;
  if (bufferTime > 0) { bufferTimeSum = bufferTime; eventProperties.push('isBuffering'); }
  const joinTime = num(p.joinTime, 0);
  let eventDoubleSum1 = 0;
  if (joinTime > 0 && eventType === 'play') { eventDoubleSum1 = joinTime; eventProperties.push('hasJoinTime'); }

  return {
    __time: new Date().toISOString(),
    // ── dimensions ──
    eventType, partnerId, entryId,
    kuserId: userKey ? md5(userKey) : '',
    entryKuserId: meta.ownerId,                 // entry owner → Contributors
    mediaType: meta.mediaType,                  // real media type from the entry
    playbackType: String(p.playbackType || 'vod'),
    categories: meta.categories,                // multi-value
    'location.country': geo ? geo.country : '',
    'location.region':  geo ? (geo.region || '') : '',
    'location.city':    geo ? (geo.city || '') : '',
    'userAgent.browser': ua.browser,
    'userAgent.browserFamily': ua.browserFamily,
    'userAgent.operatingSystem': ua.os,
    'userAgent.operatingSystemFamily': ua.osFamily,
    'userAgent.device': ua.device,
    'urlParts.domain': domainFromReferrer(p.referrer),
    application: String(p.application || ''),
    applicationVer: String(p.clientVer || p.applicationVer || ''),
    playerVersion: String(p.clientTag || p.playerVersion || ''),
    uiConfId: String(p.uiConfId || ''),
    playbackContext: String(p.playbackContext || ''),
    position: String(Math.round(position)),
    percentiles: String(percentile),            // 0-100 → engagement heatmap
    eventProperties,
    // ── HLL sketch inputs (consumed by hyperUnique aggregators) ──
    _userId: userKey,
    _sessionId: sessionId,
    // ── metric value columns ──
    count: 1,
    playTimeSum,
    uniquePercentiles,
    bitrateSum, bitrateCount, bufferTimeSum, eventDoubleSum1,
    bufferStarts: eventType === 'bufferStart' ? 1 : 0,
    flavorSwitches: eventType === 'flavorSwitch' ? 1 : 0,
  };
}

const DIMENSIONS = [
  'eventType', 'partnerId', 'entryId', 'kuserId', 'entryKuserId', 'mediaType', 'playbackType',
  { type: 'string', name: 'categories', multiValueHandling: 'ARRAY' },
  'location.country', 'location.region', 'location.city',
  'userAgent.browser', 'userAgent.browserFamily',
  'userAgent.operatingSystem', 'userAgent.operatingSystemFamily', 'userAgent.device',
  'urlParts.domain', 'application', 'applicationVer', 'playerVersion', 'uiConfId',
  'playbackContext', 'position', 'percentiles',
  { type: 'string', name: 'eventProperties', multiValueHandling: 'ARRAY' },
];

const METRICS = [
  { type: 'count', name: 'count' },
  { type: 'longSum', name: 'playTimeSum', fieldName: 'playTimeSum' },
  { type: 'longSum', name: 'uniquePercentiles', fieldName: 'uniquePercentiles' },
  { type: 'longSum', name: 'bitrateSum', fieldName: 'bitrateSum' },
  { type: 'longSum', name: 'bitrateCount', fieldName: 'bitrateCount' },
  { type: 'longSum', name: 'bufferStarts', fieldName: 'bufferStarts' },
  { type: 'longSum', name: 'flavorSwitches', fieldName: 'flavorSwitches' },
  { type: 'doubleSum', name: 'bufferTimeSum', fieldName: 'bufferTimeSum' },
  { type: 'doubleSum', name: 'eventDoubleSum1', fieldName: 'eventDoubleSum1' },
  { type: 'hyperUnique', name: 'uniqueUserIds', fieldName: '_userId' },
  { type: 'hyperUnique', name: 'uniqueSessionId', fieldName: '_sessionId' },
];

// ── Ingestion ────────────────────────────────────────────────────────────────
let buffer = [];
function flush() {
  if (buffer.length === 0) return;
  const events = buffer;
  buffer = [];
  const task = {
    type: 'index_parallel',
    spec: {
      dataSchema: {
        dataSource: DATASOURCE,
        timestampSpec: { column: '__time', format: 'iso' },
        dimensionsSpec: { dimensions: DIMENSIONS },
        metricsSpec: METRICS,
        granularitySpec: { type: 'uniform', segmentGranularity: 'DAY', queryGranularity: 'HOUR', rollup: true },
      },
      ioConfig: {
        type: 'index_parallel',
        inputSource: { type: 'inline', data: events.map((e) => JSON.stringify(e)).join('\n') },
        inputFormat: { type: 'json' },
        appendToExisting: true,
      },
      tuningConfig: { type: 'index_parallel' },
    },
  };
  const payload = JSON.stringify(task);
  const u = new URL(DRUID_OVERLORD + '/druid/indexer/v1/task');
  const r = http.request({
    hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
  }, (res) => {
    let d = ''; res.on('data', (c) => (d += c));
    res.on('end', () => {
      if (res.statusCode >= 300) console.error(`[receiver] ingest HTTP ${res.statusCode}: ${d}`);
      else console.log(`[receiver] ingested ${events.length} events`);
    });
  });
  r.on('error', (e) => { console.error(`[receiver] ingest error: ${e.message}; re-buffering ${events.length}`); buffer = events.concat(buffer); });
  r.write(payload); r.end();
}

// ── HTTP server ──────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.url.startsWith('/health')) { res.writeHead(200); res.end('ok'); return; }
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
  req.on('end', async () => {
    try {
      const row = await buildRow(parseParams(req, body), req);
      if (row) { buffer.push(row); if (buffer.length >= MAX_BUFFER) flush(); }
    } catch (e) { console.error(`[receiver] handler error: ${e.message}`); }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('1');
  });
});

async function start() {
  try {
    pool = mysql.createPool({ ...DB, waitForConnections: true, connectionLimit: 4, queueLimit: 0 });
    await pool.query('SELECT 1');
    console.log(`[receiver] DB connected (${DB.host}:${DB.port}/${DB.database}) — entry enrichment on`);
  } catch (e) {
    console.error(`[receiver] DB connect failed: ${e.message} — enrichment disabled (Contributors/categories/geo-by-entry will be empty)`);
    pool = null;
  }
  setInterval(flush, FLUSH_INTERVAL_MS);
  server.listen(PORT, () => console.log(`[receiver] listening on :${PORT}, flush ${FLUSH_INTERVAL_MS}ms → ${DRUID_OVERLORD}`));
}
start();
