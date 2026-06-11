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
const DRUID_BROKER     = process.env.DRUID_BROKER || 'http://druid-broker:8082';
const DATASOURCE       = 'player-events-historical';
// Real-Time tab: beacons are also streamed through Kafka into the
// player-events-realtime datasource (Druid kafka-indexing-service) so the
// realtime reports see data within seconds. Empty KAFKA_BROKERS = disabled.
const KAFKA_BROKERS    = (process.env.KAFKA_BROKERS || '').split(',').map((s) => s.trim()).filter(Boolean);
const REALTIME_DS      = 'player-events-realtime';
const REALTIME_TOPIC   = 'player-events-realtime';
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
  const cached = entryCache.get(entryId);
  // Trust the cache once the real duration is known. An entry enriched before
  // transcoding finishes reports length_in_msecs=0; caching that permanently
  // would peg every later viewPeriod to percentile 0 — a flat engagement curve
  // and 0% completion. Re-query provisional (0-duration) entries, but at most
  // once a minute so genuinely duration-less entries (images/live) don't hammer the DB.
  if (cached && (cached.durationSec > 0 || Date.now() - cached.fetchedAt < 60000)) return cached;
  let meta = { ownerId: '', mediaType: 'VIDEO', durationSec: 0, categories: [], fetchedAt: Date.now() };
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

  // Realtime engagement state from the player's view-event flags
  // (kKavaBase $realtime_engagement counts SoundOn+TabFocused variants as
  // engaged). soundMode/tabMode: 2 = on/focused; screenMode: 1 = fullscreen.
  const userEngagement =
    (String(p.soundMode || '') === '2' ? 'SoundOn' : 'SoundOff') +
    (String(p.tabMode || '') === '2' ? 'TabFocused' : 'TabNotFocused') +
    (String(p.screenMode || '') === '1' ? 'FullScreen'
      : (String(p.screenMode || '') === '0' ? 'FullScreenOff' : ''));

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
    userEngagement,                             // realtime engaged-users metric
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

// Realtime rows carry the same columns plus the engagement state the
// realtime-only metrics (view_unique_engaged_users) filter on.
const REALTIME_DIMENSIONS = [...DIMENSIONS, 'userEngagement'];

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

// ── Entry-lifecycle collector (Contributors) ─────────────────────────────────
// Contributors analytics (Added Entries / Added Minutes / unique uploaders) is
// fed by ENTRY metadata, NOT player beacons: each created entry is a
// "physicalAdd" event in the `entry-lifecycle` Druid datasource. Kaltura's
// closed cloud emits these server-side; self-hosted ships no emitter, so we read
// the entry table and ingest them ourselves — the legitimate equivalent.
// (kKavaBase: eventType=physicalAdd, dims partnerId/entryId/kuserId/userType/
//  mediaType/sourceType/categories, metrics delta(+1) and duration(seconds).)
const ELIFECYCLE_DS  = 'entry-lifecycle';
const ELIFE_POLL_MS  = parseInt(process.env.ELIFE_POLL_MS || '60000', 10);
const ELIFE_MEDIA    = { 1: 'Video', 2: 'Image', 5: 'Audio', 201: 'Live stream', 202: 'Live stream', 203: 'Live stream' };
// entry.source (EntrySourceType) → KAVA sourceType label (kKavaBase $sourceTypes).
const ELIFE_SOURCE   = { 0: 'Other', 1: 'Upload', 2: 'Webcam', 5: 'Url', 6: 'Text', 20: 'Kaltura',
  29: 'Live stream', 30: 'Live stream', 31: 'Live stream', 32: 'Live stream', 33: 'Live channel',
  34: 'Recorded live stream', 35: 'Clip', 36: 'Recorded live stream', 37: 'Classroom Capture' };
const ingestedEntries = new Set(); // entries we have emitted a physicalAdd for
const deletedEntries  = new Set(); // entries we have emitted a physicalDelete for
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function druidQuery(q) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(q);
    const u = new URL(DRUID_BROKER + '/druid/v2/');
    const r = http.request({ hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } },
      (res) => { let d = ''; res.on('data', (c) => (d += c));
        res.on('end', () => { try { resolve(JSON.parse(d || '[]')); } catch (e) { reject(e); } }); });
    r.on('error', reject); r.write(payload); r.end();
  });
}

function postDruidTask(task) {
  return new Promise((resolve) => {
    const payload = JSON.stringify(task);
    const u = new URL(DRUID_OVERLORD + '/druid/indexer/v1/task');
    const r = http.request({ hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } },
      (res) => { let d = ''; res.on('data', (c) => (d += c));
        res.on('end', () => { if (res.statusCode >= 300) console.error(`[receiver] task HTTP ${res.statusCode}: ${d}`); resolve(); }); });
    r.on('error', (e) => { console.error(`[receiver] task error: ${e.message}`); resolve(); });
    r.write(payload); r.end();
  });
}

// On startup, learn which entries already have add/delete events in Druid so a
// receiver restart cannot re-emit them (double-counting). THROWS if Druid is
// unreachable — start() retries so a not-yet-ready Druid never seeds us empty.
async function seedIngestedEntries() {
  const rows = await druidQuery({
    queryType: 'groupBy', dataSource: ELIFECYCLE_DS,
    intervals: ['2000-01-01T00:00:00Z/2100-01-01T00:00:00Z'],
    granularity: 'all', dimensions: ['entryId', 'eventType'],
    aggregations: [{ type: 'count', name: 'c' }],
  });
  for (const r of rows) {
    if (r.event.eventType === 'physicalAdd') ingestedEntries.add(r.event.entryId);
    else if (r.event.eventType === 'physicalDelete') deletedEntries.add(r.event.entryId);
  }
  return ingestedEntries.size;
}

// Build one entry-lifecycle row. sign = +1 (add, created_at) or -1 (delete,
// updated_at) — delta and duration are negated on delete so net totals balance.
async function lifecycleEvent(e, eventType, sign) {
  let categories = [];
  try {
    const [cats] = await pool.query(
      'SELECT c.full_name FROM category_entry ce JOIN category c ON c.id = ce.category_id ' +
      'WHERE ce.entry_id = ? AND ce.status = 1 LIMIT 20', [e.id]);
    categories = cats.map((r) => String(r.full_name || '')).filter(Boolean);
  } catch { /* categories optional */ }
  const tsCol = sign > 0 ? e.created_at : (e.updated_at || e.created_at);
  const ts = tsCol instanceof Date ? tsCol : new Date(tsCol || Date.now());
  const durSec = Math.round((e.length_in_msecs || 0) / 1000);
  return {
    __time: ts.toISOString(),
    eventType,
    partnerId: String(e.partner_id),
    entryId: String(e.id),
    // The uploader as the NUMERIC kuser id — the contributor reports enrich it
    // back to a name via a kuserPeer PK lookup (reportType 39 genericQueryEnrich
    // and reportType 5 getUserScreenNameWithFallback both key on the numeric id).
    kuserId: String(e.kuser_id || ''),
    entryCreatorId: String(e.kuser_id || ''),
    userType: 'User',
    mediaType: ELIFE_MEDIA[e.media_type] || 'Video',
    sourceType: ELIFE_SOURCE[e.source] || 'Other',  // how the content was added
    categories,
    count: 1,
    delta: sign,             // +1 add / -1 delete
    duration: sign * durSec, // seconds, negative on delete
  };
}

function buildLifecycleTask(events) {
  return {
    type: 'index_parallel',
    spec: {
      dataSchema: {
        dataSource: ELIFECYCLE_DS,
        timestampSpec: { column: '__time', format: 'iso' },
        dimensionsSpec: { dimensions: ['eventType', 'partnerId', 'entryId', 'kuserId', 'entryCreatorId', 'userType', 'mediaType', 'sourceType',
          { type: 'string', name: 'categories', multiValueHandling: 'ARRAY' }] },
        metricsSpec: [
          { type: 'count', name: 'count' },
          { type: 'longSum', name: 'delta', fieldName: 'delta' },
          { type: 'longSum', name: 'duration', fieldName: 'duration' },
        ],
        // Entries are sparse and each is distinct (keep per-entry rows for entryId/kuserId cardinality).
        granularitySpec: { type: 'uniform', segmentGranularity: 'MONTH', queryGranularity: 'NONE', rollup: false },
      },
      ioConfig: { type: 'index_parallel', inputSource: { type: 'inline', data: events.map((e) => JSON.stringify(e)).join('\n') }, inputFormat: { type: 'json' }, appendToExisting: true },
      tuningConfig: { type: 'index_parallel' },
    },
  };
}

// Poll the entry table: emit physicalAdd for new entries (once their duration is
// known) and physicalDelete for entries that have since been deleted.
async function pollEntryLifecycle() {
  if (!pool) return;
  let rows;
  try {
    [rows] = await pool.query(
      'SELECT id, partner_id, kuser_id, media_type, length_in_msecs, source, status, created_at, updated_at ' +
      'FROM entry WHERE partner_id > 0 ORDER BY created_at');
  } catch (e) { console.error(`[receiver] entry-lifecycle query: ${e.message}`); return; }

  const events = [];
  let added = 0, removed = 0;
  for (const e of rows) {
    const id = String(e.id);
    if (e.status === 3) {
      // Deleted: emit physicalDelete once, only if we had counted the add.
      if (!ingestedEntries.has(id) || deletedEntries.has(id)) continue;
      events.push(await lifecycleEvent(e, 'physicalDelete', -1));
      deletedEntries.add(id); removed++;
    } else {
      // Live: emit physicalAdd once its duration is known (images carry none).
      const durationKnown = (e.media_type === 2 || (e.length_in_msecs || 0) > 0);
      if (ingestedEntries.has(id) || !durationKnown) continue;
      events.push(await lifecycleEvent(e, 'physicalAdd', +1));
      ingestedEntries.add(id); added++;
    }
  }
  if (events.length === 0) return;
  await postDruidTask(buildLifecycleTask(events));
  console.log(`[receiver] entry-lifecycle: +${added} added, -${removed} deleted (Contributors)`);
}

// ── Usage collector (storage + transcoding) ──────────────────────────────────
// The KMC-NG "Usage" tab reads two further datasources Kaltura's cloud fills
// server-side: `storage-usage` (Stored Media — net bytes currently held) and
// `transcoding-usage` (Transcoded Media / hours — one-time transcoding consumed).
// Both are derived from flavor_asset: stored bytes = sum of a ready entry's
// flavor sizes; transcoded flavors are the non-original ones. Storage is SIGNED
// (physicalAdd +bytes, physicalDelete -bytes) so the net equals live storage;
// transcoding is consumption — emitted once and never reversed.
// (Outbound bandwidth / active users come from delivery & api-usage datasources
//  we do not feed, so those Usage figures legitimately stay zero.)
const STORAGE_DS       = 'storage-usage';
const TRANSCODING_DS   = 'transcoding-usage';
const STORAGE_DIMS     = ['eventType', 'partnerId', 'partnerParentId', 'entryId', 'categories', 'kuserId', 'mediaType', 'sourceType', 'videoCodec'];
const TRANSCODING_DIMS = ['partnerId', 'partnerParentId', 'entryId', 'categories', 'kuserId', 'mediaType', 'sourceType', 'status', 'flavorParamsId', 'videoCodec'];
const storedEntries     = new Set(); // entries with a storage-usage physicalAdd
const storageDeleted    = new Set(); // entries with a storage-usage physicalDelete
const transcodedEntries = new Set(); // entries whose transcoding rows are in Druid

// Generic Druid index task for a usage datasource (rollup off, monthly segments).
function buildUsageTask(dataSource, dims, metricsSpec, rows) {
  const dimensions = dims.map((d) => d === 'categories'
    ? { type: 'string', name: 'categories', multiValueHandling: 'ARRAY' } : d);
  return {
    type: 'index_parallel',
    spec: {
      dataSchema: {
        dataSource,
        timestampSpec: { column: '__time', format: 'iso' },
        dimensionsSpec: { dimensions },
        metricsSpec,
        granularitySpec: { type: 'uniform', segmentGranularity: 'MONTH', queryGranularity: 'NONE', rollup: false },
      },
      ioConfig: { type: 'index_parallel', inputSource: { type: 'inline', data: rows.map((e) => JSON.stringify(e)).join('\n') }, inputFormat: { type: 'json' }, appendToExisting: true },
      tuningConfig: { type: 'index_parallel' },
    },
  };
}

// Entry-level dimensions shared by storage + transcoding rows.
function entryDims(e) {
  return {
    partnerId: String(e.partner_id),
    partnerParentId: '0',
    entryId: String(e.id),
    categories: [],                                   // Usage Overview totals don't group by category
    kuserId: String(e.kuser_id || ''),
    mediaType: ELIFE_MEDIA[e.media_type] || 'Video',
    sourceType: ELIFE_SOURCE[e.source] || 'Other',
    videoCodec: '',
  };
}

// On startup, learn which entries already have usage rows in Druid (avoids
// double-counting on restart). A missing datasource returns [] (HTTP 200); only
// an unreachable broker throws, so start()'s retry loop handles cold starts.
async function seedUsage() {
  const groupBy = (dataSource, dimensions) => druidQuery({ queryType: 'groupBy', dataSource,
    intervals: ['2000-01-01T00:00:00Z/2100-01-01T00:00:00Z'], granularity: 'all',
    dimensions, aggregations: [{ type: 'count', name: 'c' }] });
  for (const r of await groupBy(STORAGE_DS, ['entryId', 'eventType'])) {
    if (r.event.eventType === 'physicalAdd') storedEntries.add(r.event.entryId);
    else if (r.event.eventType === 'physicalDelete') storageDeleted.add(r.event.entryId);
  }
  for (const r of await groupBy(TRANSCODING_DS, ['entryId'])) transcodedEntries.add(r.event.entryId);
  return storedEntries.size;
}

// Poll flavor_asset for storage (net bytes per ready entry) and transcoding
// (per non-original flavor) usage, and ingest the new rows.
async function pollUsage() {
  if (!pool) return;

  // ── storage-usage: one signed `size` row per entry ─────────────────────────
  let entries;
  try {
    // Sum every sized flavor (KB). Deleted flavors keep their size, so the
    // physicalDelete reverses exactly what the physicalAdd recorded.
    [entries] = await pool.query(
      'SELECT e.id, e.partner_id, e.kuser_id, e.media_type, e.source, e.status, e.created_at, e.updated_at, ' +
      'COALESCE(SUM(GREATEST(fa.size, 0)), 0) AS kb ' +
      'FROM entry e LEFT JOIN flavor_asset fa ON fa.entry_id = e.id ' +
      'WHERE e.partner_id > 0 GROUP BY e.id ORDER BY e.created_at');
  } catch (e) { console.error(`[receiver] storage-usage query: ${e.message}`); return; }

  const storageRows = [];
  let added = 0, removed = 0;
  for (const e of entries) {
    const id = String(e.id);
    const bytes = Number(e.kb || 0) * 1024;
    const tsCol = e.status === 3 ? (e.updated_at || e.created_at) : e.created_at;
    const when = (tsCol instanceof Date ? tsCol : new Date(tsCol || Date.now())).toISOString();
    if (e.status === 3) {
      if (!storedEntries.has(id) || storageDeleted.has(id)) continue;
      storageRows.push({ __time: when, eventType: 'physicalDelete', ...entryDims(e), size: -bytes, count: 1 });
      storageDeleted.add(id); removed++;
    } else {
      // Wait until the entry is READY (status 2) so all flavor sizes are final.
      if (storedEntries.has(id) || e.status !== 2 || bytes <= 0) continue;
      storageRows.push({ __time: when, eventType: 'physicalAdd', ...entryDims(e), size: bytes, count: 1 });
      storedEntries.add(id); added++;
    }
  }
  if (storageRows.length) {
    await postDruidTask(buildUsageTask(STORAGE_DS, STORAGE_DIMS,
      [{ type: 'count', name: 'count' }, { type: 'longSum', name: 'size', fieldName: 'size' }], storageRows));
    console.log(`[receiver] storage-usage: +${added} added, -${removed} deleted`);
  }

  // ── transcoding-usage: one row per non-original flavor (consumed once) ──────
  let flavors;
  try {
    [flavors] = await pool.query(
      'SELECT fa.entry_id AS id, fa.flavor_params_id, fa.size AS kb, e.partner_id, e.kuser_id, ' +
      'e.media_type, e.source, e.length_in_msecs, e.created_at ' +
      'FROM flavor_asset fa JOIN entry e ON e.id = fa.entry_id ' +
      'WHERE e.partner_id > 0 AND e.status = 2 AND fa.is_original = 0 AND fa.status = 2 AND fa.size > 0 ' +
      'ORDER BY fa.entry_id');
  } catch (e) { console.error(`[receiver] transcoding-usage query: ${e.message}`); return; }

  const transRows = [];
  const newlyTranscoded = new Set();
  for (const f of flavors) {
    if (transcodedEntries.has(String(f.id))) continue; // this entry's flavors already ingested
    const when = (f.created_at instanceof Date ? f.created_at : new Date(f.created_at || Date.now())).toISOString();
    transRows.push({
      __time: when,
      ...entryDims(f),
      status: 'Success',
      flavorParamsId: String(f.flavor_params_id),
      flavorSize: Number(f.kb || 0) * 1024,                  // transcoded output bytes
      duration: Math.round((f.length_in_msecs || 0) / 1000), // seconds of media transcoded
      count: 1,
    });
    newlyTranscoded.add(String(f.id));
  }
  if (transRows.length) {
    await postDruidTask(buildUsageTask(TRANSCODING_DS, TRANSCODING_DIMS,
      [{ type: 'count', name: 'count' },
       { type: 'longSum', name: 'flavorSize', fieldName: 'flavorSize' },
       { type: 'longSum', name: 'duration', fieldName: 'duration' }], transRows));
    for (const id of newlyTranscoded) transcodedEntries.add(id);
    console.log(`[receiver] transcoding-usage: ${transRows.length} flavors across ${newlyTranscoded.size} entries`);
  }
}

// ── Real-Time streaming (Kafka → Druid kafka-indexing-service) ───────────────
// The Real-Time tab (kKavaRealtimeReports) queries player-events-realtime with
// 30s cache — minute-latency batch tasks cannot feed it. Each beacon is also
// produced to a Kafka topic that a Druid supervisor consumes within seconds.
// The realtime row differs from the historical one in eventType naming only:
// beacon 99 is 'viewPeriod' in historical and 'view' in realtime (kKavaBase
// EVENT_TYPE_VIEW vs EVENT_TYPE_VIEW_PERIOD).
let kafkaProducer = null;

async function startKafka() {
  const { Kafka } = require('kafkajs');
  const kafka = new Kafka({ clientId: 'kaltura-analytics-receiver', brokers: KAFKA_BROKERS, retry: { retries: 8 } });
  const producer = kafka.producer({ allowAutoTopicCreation: true });
  await producer.connect();
  kafkaProducer = producer;
  console.log(`[receiver] kafka connected (${KAFKA_BROKERS.join(',')}) → topic ${REALTIME_TOPIC}`);
}

function publishRealtime(row) {
  if (!kafkaProducer) return;
  const rt = { ...row, eventType: row.eventType === 'viewPeriod' ? 'view' : row.eventType };
  kafkaProducer.send({ topic: REALTIME_TOPIC, messages: [{ value: JSON.stringify(rt) }] })
    .catch((e) => console.error(`[receiver] kafka send: ${e.message}`));
}

// Submit the Druid kafka supervisor (idempotent — same spec re-submission is a
// no-op) and a short retention rule so the realtime datasource stays small:
// the Real-Time tab only ever queries the last hours.
function submitRealtimeSupervisor() {
  const spec = {
    type: 'kafka',
    spec: {
      dataSchema: {
        dataSource: REALTIME_DS,
        timestampSpec: { column: '__time', format: 'iso' },
        dimensionsSpec: { dimensions: REALTIME_DIMENSIONS },
        metricsSpec: METRICS,
        granularitySpec: { type: 'uniform', segmentGranularity: 'HOUR', queryGranularity: 'NONE', rollup: false },
      },
      ioConfig: {
        topic: REALTIME_TOPIC,
        inputFormat: { type: 'json' },
        consumerProperties: { 'bootstrap.servers': KAFKA_BROKERS.join(',') },
        taskCount: 1, replicas: 1, taskDuration: 'PT1H',
        useEarliestOffset: false,
      },
      tuningConfig: { type: 'kafka', maxRowsInMemory: 25000 },
    },
  };
  const post = (path, body, label) => new Promise((resolve) => {
    const payload = JSON.stringify(body);
    const u = new URL(DRUID_OVERLORD + path);
    const r = http.request({ hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } },
      (res) => { let d = ''; res.on('data', (c) => (d += c));
        res.on('end', () => {
          if (res.statusCode >= 300) console.error(`[receiver] ${label} HTTP ${res.statusCode}: ${d.slice(0, 200)}`);
          else console.log(`[receiver] ${label} ok`);
          resolve();
        }); });
    r.on('error', (e) => { console.error(`[receiver] ${label}: ${e.message}`); resolve(); });
    r.write(payload); r.end();
  });
  return post('/druid/indexer/v1/supervisor', spec, 'realtime supervisor')
    .then(() => post(`/druid/coordinator/v1/rules/${REALTIME_DS}`,
      [{ type: 'loadByPeriod', period: 'P2D', includeFuture: true, tieredReplicants: { _default_tier: 1 } },
       { type: 'dropForever' }], 'realtime retention rules'));
}

// ── Native live orchestration bridge ──────────────────────────────────────────
// "Broadcasting Now" (Real-Time tab) and the KMC "Live" badge key off the
// entry's isLive flag, which only liveStream.registerMediaServer sets. When an
// encoder starts/stops publishing we bridge nginx-rtmp into that native
// lifecycle: find the Manual Live Stream entry whose hls_stream_url points at
// the stream and register/unregister this host as its media server. The server
// node auto-registers through serverNode.reportStatus on first use — the same
// path a real Kaltura media server (Wowza) uses.
const https = require('https');
const WWW_HOST       = process.env.WWW_HOST || 'localhost';
const LIVE_HOSTNAME  = process.env.LIVE_RTMP_HOSTNAME || 'live-rtmp';
// The serverNode/registerMediaServer actions are permissioned to the Media
// partner (-5, MEDIA_SERVER_BASE) — the identity real media servers (Wowza)
// authenticate as; a regular partner admin KS gets SERVICE_FORBIDDEN.
const MEDIA_SERVER_PARTNER = -5;
const activeStreams  = new Map();   // stream name -> { entryId, partnerId }
const partnerKsCache = new Map();   // partnerId -> { ks, at }

function kalturaApi(params) {
  return new Promise((resolve, reject) => {
    const qs = new URLSearchParams({ format: '1', ...params }).toString();
    const req = https.request({
      host: 'kaltura', port: 443, path: '/api_v3/index.php', method: 'POST',
      headers: { Host: WWW_HOST, 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(qs) },
      rejectUnauthorized: false, servername: WWW_HOST,   // self-signed certs in dev
    }, (res) => {
      let d = ''; res.on('data', (c) => (d += c));
      res.on('end', () => {
        try {
          const j = JSON.parse(d);
          if (j && typeof j === 'object' && j.code && j.message) {
            return reject(new Error(`${params.service}.${params.action}: ${j.message}`));
          }
          resolve(j);
        } catch { resolve(d); }
      });
    });
    req.on('error', reject); req.write(qs); req.end();
  });
}

async function partnerKs(partnerId) {
  const hit = partnerKsCache.get(partnerId);
  if (hit && Date.now() - hit.at < 20 * 60 * 1000) return hit.ks;
  const [rows] = await pool.query('SELECT admin_secret FROM partner WHERE id = ?', [partnerId]);
  if (!rows.length) throw new Error(`partner ${partnerId} not found`);
  const ks = await kalturaApi({ service: 'session', action: 'start',
    secret: rows[0].admin_secret, partnerId: String(partnerId), type: '2', expiry: '86400' });
  partnerKsCache.set(partnerId, { ks, at: Date.now() });
  return ks;
}

// Manual live entries keep their playback URL in custom_data; the stream name
// inside ".../hlsme/<name>.m3u8" is the natural join key with the RTMP publish.
async function lookupLiveEntry(name) {
  if (!pool || !/^[A-Za-z0-9_-]+$/.test(name)) return null;
  // Native (Kaltura Live, source 32): the broadcast map names the stream
  // "<entryId>_<flavorIndex>" (stream_name_template = {entryId}_%i), so the
  // entryId is the name minus the trailing _<digits>.
  const m = name.match(/^(\d+_[A-Za-z0-9]+)_\d+$/);
  if (m) {
    const [rows] = await pool.query(
      'SELECT id, partner_id, custom_data FROM entry WHERE id = ? AND media_type = 201 LIMIT 1', [m[1]]);
    if (rows.length) {
      // The broadcast token (?t=) is the entry's streamPassword in custom_data.
      const pw = /"streamPassword";s:\d+:"([^"]+)"/.exec(rows[0].custom_data || '');
      return { entryId: String(rows[0].id), partnerId: rows[0].partner_id, native: true,
        streamPassword: pw ? pw[1] : null };
    }
  }
  // Manual (source 30): matched by its hls_stream_url in custom_data.
  const [rows] = await pool.query(
    "SELECT id, partner_id, (custom_data LIKE '%\"configurations\"%') AS hasCfg " +
    'FROM entry WHERE media_type = 201 AND status = 2 AND custom_data LIKE ? LIMIT 1',
    [`%hlsme/${name}.m3u8%`]);
  return rows.length
    ? { entryId: String(rows[0].id), partnerId: rows[0].partner_id, hasCfg: !!rows[0].hasCfg, native: false }
    : null;
}

// isLive (Broadcasting Now / the KMC Live badge) for MANUAL entries works by
// probing the entry's liveStreamConfigurations — hlsStreamUrl alone is not
// consulted on that path (LiveStreamEntry::getLiveStreamConfigurations only
// folds it in for format-specific calls). Backfill the APPLE_HTTP config once;
// the update also re-saves the entry, which re-indexes isLive into Sphinx.
async function ensureLiveConfig(name, entry) {
  const ks = await partnerKs(entry.partnerId);
  await kalturaApi({ service: 'liveStream', action: 'update', ks, entryId: entry.entryId,
    'liveStreamEntry:objectType': 'KalturaLiveStreamEntry',
    'liveStreamEntry:liveStreamConfigurations:0:objectType': 'KalturaLiveStreamConfiguration',
    'liveStreamEntry:liveStreamConfigurations:0:protocol': 'applehttp',
    'liveStreamEntry:liveStreamConfigurations:0:url': `https://${WWW_HOST}/hlsme/${name}.m3u8`,
  });
}

// Native entries: the live manifest is built from the entry_server_node's
// `streams` (kLiveStreamParams). With none, playManifest short-circuits to an
// empty redirect (HTTP 404). A real media server reports the flavors it is
// broadcasting; for our single-bitrate passthrough we report one (flavorId 1,
// matching the "<entryId>_1" stream OBS publishes). The Live Packager delivery
// profile then emits /dc-0/live/hls/.../e/<entryId>/.../index-s1.m3u8, which
// the live-rtmp container bridges back to the flat HLS files.
async function setLiveStreams(name, entry) {
  if (!pool) return;
  const [rows] = await pool.query(
    'SELECT id FROM entry_server_node WHERE entry_id = ? AND server_type = 0 LIMIT 1', [entry.entryId]);
  if (!rows.length) return;
  // The flavorId we report becomes the "s<N>" in the playManifest URL
  // (index-s<N>.m3u8), which the live-rtmp bridge maps back to the published
  // stream "<entryId>_<N>". Hardcoding '1' broke playback whenever the encoder
  // used a different suffix (e.g. the backup URL publishes <entryId>_2) — the
  // manifest then pointed at a stale/nonexistent playlist.
  const suffix = (name.match(/_(\d+)$/) || [])[1] || '1';
  const ks = await partnerKs(MEDIA_SERVER_PARTNER);
  await kalturaApi({ service: 'entryServerNode', action: 'update', ks, id: String(rows[0].id),
    'entryServerNode:objectType': 'KalturaLiveEntryServerNode',
    'entryServerNode:streams:0:objectType': 'KalturaLiveStreamParams',
    'entryServerNode:streams:0:flavorId': suffix,
    'entryServerNode:streams:0:bitrate': '1000000',
    'entryServerNode:streams:0:width': '1280',
    'entryServerNode:streams:0:height': '720',
    'entryServerNode:streams:0:codec': 'avc1',
  });
}

// Register (or heartbeat-refresh) the entry's live state. Real media servers
// re-register every minute — Kaltura expires the live status otherwise — so
// this is called both on publish and from the refresh interval.
async function registerLive(name, entry) {
  const ks = await partnerKs(MEDIA_SERVER_PARTNER);
  await kalturaApi({ service: 'serverNode', action: 'reportStatus', ks, hostName: LIVE_HOSTNAME,
    'serverNode:objectType': 'KalturaWowzaMediaServerNode',
    'serverNode:hostName': LIVE_HOSTNAME, 'serverNode:name': LIVE_HOSTNAME });
  await kalturaApi({ service: 'liveStream', action: 'registerMediaServer', ks,
    entryId: entry.entryId, hostname: LIVE_HOSTNAME, mediaServerIndex: '0',
    applicationName: 'kLive', liveEntryStatus: '1', shouldCreateRecordedEntry: '0' });
  if (entry.native) await setLiveStreams(name, entry);
}

async function liveBroadcastStarted(name) {
  const entry = await lookupLiveEntry(name);
  if (!entry) {
    console.log(`[receiver] live orchestration: no entry maps to stream "${name}" — create a Manual Live Stream entry with .../hlsme/${name}.m3u8 to appear in Broadcasting Now`);
    return;
  }
  // Native entries derive isLive directly from the entry_server_node status, so
  // they only need registerMediaServer. Manual entries additionally need the
  // liveStreamConfigurations backfill so the URL-probe isLive check passes.
  if (!entry.native && !entry.hasCfg) await ensureLiveConfig(name, entry);
  await registerLive(name, entry);
  if (!entry.native) {
    setTimeout(() => ensureLiveConfig(name, entry)
      .catch((e) => console.error(`[receiver] live reindex (${name}): ${e.message}`)), 15000).unref();
  }
  activeStreams.set(name, entry);
  console.log(`[receiver] live orchestration: entry ${entry.entryId} is LIVE (stream "${name}", ${entry.native ? 'native' : 'manual'})`);
}

async function liveBroadcastEnded(name) {
  const entry = activeStreams.get(name) || await lookupLiveEntry(name);
  activeStreams.delete(name);
  if (!entry) return;
  const ks = await partnerKs(MEDIA_SERVER_PARTNER);
  await kalturaApi({ service: 'liveStream', action: 'unregisterMediaServer', ks,
    entryId: entry.entryId, hostname: LIVE_HOSTNAME, mediaServerIndex: '0' });
  // Touch-update → entry re-save → Sphinx re-probes the (now gone) manifest →
  // isLive drops and the entry moves to Previous Broadcasts.
  await ensureLiveConfig(name, entry).catch(() => {});
  console.log(`[receiver] live orchestration: entry ${entry.entryId} stopped (stream "${name}")`);
}

// ── Live publish auth (nginx-rtmp on_publish callback) ───────────────────────
// nginx-rtmp POSTs the publish request (form-encoded: app, name, addr + the
// encoder's query args). We refuse the stream unless we answer 2xx. Auth is
// per-entry for native entries (the ?t= token is the entry's streamPassword)
// and a shared secret (LIVE_PUBLISH_TOKEN) for manual streams.
const LIVE_PUBLISH_TOKEN = process.env.LIVE_PUBLISH_TOKEN || '';
function handleLivePublish(req, res) {
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
  req.on('end', async () => {
    const p = new URLSearchParams(body);
    const name = p.get('name') || '?';
    const addr = p.get('addr') || '?';
    // The ?t= token may arrive as a direct field (query on the stream key, e.g.
    // ffmpeg .../<stream>?t=...) or inside tcurl (query on the app/server URL,
    // e.g. OBS Server "rtmp://host/kLive?...&t=..."). Check both.
    const tcurlQs = new URLSearchParams((p.get('tcurl') || '').split('?')[1] || '');
    const token = p.get('t') || tcurlQs.get('t');
    const allow = () => {
      console.log(`[receiver] live publish ALLOWED: stream=${name} from=${addr}`);
      res.writeHead(200); res.end('ok');
      liveBroadcastStarted(name).catch((e) => console.error(`[receiver] live orchestration start: ${e.message}`));
    };
    const deny = (why) => {
      console.warn(`[receiver] live publish DENIED (${why}): stream=${name} from=${addr}`);
      res.writeHead(403); res.end('forbidden');
    };
    try {
      const entry = await lookupLiveEntry(name);
      if (entry && entry.native) {
        // Native: validate ?t= against the entry's own streamPassword.
        return (!entry.streamPassword || token === entry.streamPassword) ? allow() : deny('bad stream token');
      }
      // Manual / unknown: shared secret (empty = open publishing for dev).
      return (!LIVE_PUBLISH_TOKEN || p.get('token') === LIVE_PUBLISH_TOKEN) ? allow() : deny('bad token');
    } catch (e) {
      console.error(`[receiver] live publish auth error: ${e.message}`);
      deny('auth error');
    }
  });
}

// nginx-rtmp on_publish_done: the encoder disconnected — clear isLive.
function handleLivePublishDone(req, res) {
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e5) req.destroy(); });
  req.on('end', () => {
    const name = new URLSearchParams(body).get('name') || '?';
    res.writeHead(200); res.end('ok');
    liveBroadcastEnded(name).catch((e) => console.error(`[receiver] live orchestration end: ${e.message}`));
  });
}

// ── HTTP server ──────────────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.url.startsWith('/health')) { res.writeHead(200); res.end('ok'); return; }
  if (req.url.startsWith('/live/publish_done')) { handleLivePublishDone(req, res); return; }
  if (req.url.startsWith('/live/publish')) { handleLivePublish(req, res); return; }
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
  req.on('end', async () => {
    try {
      const row = await buildRow(parseParams(req, body), req);
      if (row) {
        buffer.push(row); if (buffer.length >= MAX_BUFFER) flush();
        publishRealtime(row);   // fire-and-forget → Real-Time tab
      }
    } catch (e) { console.error(`[receiver] handler error: ${e.message}`); }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('1');
  });
});

async function start() {
  // MySQL is a hard dependency for live orchestration: on_publish maps the
  // stream name to an entry via lookupLiveEntry(), which needs the pool. A
  // single failed attempt used to leave pool=null for the process lifetime —
  // on cold starts (make reset) the receiver could come up before MySQL
  // finished init, and live publishes then never registered (player stuck on
  // "Off Air" while nginx-rtmp happily served segments). Retry until it
  // answers; compose's depends_on(service_healthy) makes this a no-op on the
  // happy path, the loop covers any ordering that still slips through.
  for (let i = 0; i < 60 && !pool; i++) {
    const p = mysql.createPool({ ...DB, waitForConnections: true, connectionLimit: 4, queueLimit: 0 });
    try {
      await p.query('SELECT 1');
      pool = p;
      console.log(`[receiver] DB connected (${DB.host}:${DB.port}/${DB.database}) — entry enrichment on`);
    } catch (e) {
      await p.end().catch(() => {});
      console.log(`[receiver] waiting for MySQL (${e.message}) — attempt ${i + 1}/60`);
      await sleep(5000);
    }
  }
  if (!pool) {
    console.error('[receiver] MySQL never reachable after 60 attempts — enrichment AND live orchestration disabled (Contributors/categories/geo empty, live entries will not register)');
  }
  setInterval(flush, FLUSH_INTERVAL_MS);
  // Entry-lifecycle (Contributors) + usage (storage/transcoding) collectors:
  // seed their state from Druid FIRST — retry until Druid answers, because
  // seeding empty against a not-yet-ready Druid would re-ingest everything and
  // double-count. Only poll the DB once a successful seed has run.
  if (pool) {
    let seeded = false;
    for (let i = 0; i < 30 && !seeded; i++) {
      try {
        const n = await seedIngestedEntries();
        const m = await seedUsage();
        console.log(`[receiver] seeded from Druid: ${n} entries / ${deletedEntries.size} deleted (Contributors), ` +
          `${m} stored / ${transcodedEntries.size} transcoded (Usage)`);
        seeded = true;
      } catch (e) {
        console.log(`[receiver] waiting for Druid before seeding (${e.message})`);
        await sleep(5000);
      }
    }
    if (seeded) {
      await pollEntryLifecycle();
      await pollUsage();
      setInterval(() => { pollEntryLifecycle().catch((e) => console.error(`[receiver] entry-lifecycle poll: ${e.message}`)); }, ELIFE_POLL_MS).unref();
      setInterval(() => { pollUsage().catch((e) => console.error(`[receiver] usage poll: ${e.message}`)); }, ELIFE_POLL_MS).unref();
    } else {
      console.error('[receiver] Druid never reachable for seeding — lifecycle/usage collectors disabled to avoid double-counting');
    }
  }
  // Real-Time streaming: connect the Kafka producer and (re)submit the Druid
  // supervisor. Failures only disable the Real-Time tab — the historical batch
  // path above keeps working regardless.
  if (KAFKA_BROKERS.length) {
    startKafka()
      .then(() => submitRealtimeSupervisor())
      .catch((e) => console.error(`[receiver] kafka init failed (Real-Time tab disabled): ${e.message}`));
  }
  // Heartbeat: re-register active live streams every minute — Kaltura expires
  // the entry's live status otherwise (real media servers do the same).
  setInterval(() => {
    for (const [name, entry] of activeStreams) {
      registerLive(name, entry).catch((e) => console.error(`[receiver] live heartbeat (${name}): ${e.message}`));
    }
  }, 60000).unref();
  server.listen(PORT, () => console.log(`[receiver] listening on :${PORT}, flush ${FLUSH_INTERVAL_MS}ms → ${DRUID_OVERLORD}`));
}
start();
