// Kaltura analytics event receiver — Kanalony stand-in for Kaltura CE.
//
// The V2 mwEmbed (kwidget) and V7 PlayKit (kava) players POST/GET analytics
// beacons to {analytics_host}/api_v3/index.php?service=analytics&action=trackEvent.
// CE has no ingestion endpoint (it is a closed-source SaaS service), so Apache
// proxies that path here. We translate each beacon into the exact Druid row
// shape that kKavaBase.php / kKavaReportsMgr query, and batch-append it to the
// `player-events-historical` datasource via native index_parallel tasks.
//
// Schema is derived 1:1 from alpha/apps/kaltura/lib/reports/kKavaBase.php so
// every analytics-front-end view (engagement, audience, technology, geo,
// content, QoE) resolves correctly:
//   - dimensions: exact kKavaBase column names (incl. dotted userAgent.*, etc.)
//   - metrics:    count, playTimeSum, uniquePercentiles, bitrate*, buffer*, …
//   - HLL sketch: uniqueUserIds + uniqueSessionId (hyperUnique at ingest time) —
//                 required for the unique_* metrics; raw strings won't work.

const http = require('http');
const crypto = require('crypto');

const DRUID_OVERLORD = process.env.DRUID_OVERLORD || 'http://druid-coordinator:8081';
const DATASOURCE = 'player-events-historical';
const FLUSH_INTERVAL_MS = parseInt(process.env.FLUSH_INTERVAL_MS || '15000', 10);
const MAX_BUFFER = parseInt(process.env.MAX_BUFFER || '200', 10);
const PORT = parseInt(process.env.PORT || '9999', 10);
const VIEW_PERIOD_SECONDS = 10; // KAVA VIEW heartbeat fires every ~10s (VIEW_EVENT_PERIOD=PT10S)

// ── KAVA numeric eventType -> kKavaBase string dimension value (KB 115-157) ──
const EVENT_TYPE_MAP = {
  1: 'playerImpression',
  2: 'playRequested',
  3: 'play',
  4: 'resume',
  11: 'playThrough25',
  12: 'playThrough50',
  13: 'playThrough75',
  14: 'playThrough100',
  16: 'replay',
  17: 'seek',
  18: 'editClicked',
  19: 'shareClicked',
  20: 'shared',
  21: 'downloadClicked',
  22: 'reportClicked',
  24: 'enterFullscreen',
  25: 'exitFullscreen',
  32: 'info',
  33: 'pauseClicked',
  34: 'replay',
  35: 'seek',
  38: 'captions',
  39: 'sourceSelected',
  41: 'speed',
  43: 'flavorSwitch',
  45: 'bufferStart',
  46: 'bufferStart',
  48: 'error',
  98: 'error',
  99: 'viewPeriod', // VIEW heartbeat → one view period
};

// ── Minimal User-Agent parser (no deps) → browser / os / device ──────────────
function parseUA(ua) {
  ua = ua || '';
  let browser = '', browserFamily = '', os = '', osFamily = '', device = 'Desktop';

  // Browser
  if (/Edg\//.test(ua)) { browser = 'Edge'; browserFamily = 'Edge'; }
  else if (/OPR\/|Opera/.test(ua)) { browser = 'Opera'; browserFamily = 'Opera'; }
  else if (/Chrome\//.test(ua) && !/Chromium/.test(ua)) { browser = 'Chrome'; browserFamily = 'Chrome'; }
  else if (/Chromium/.test(ua)) { browser = 'Chromium'; browserFamily = 'Chrome'; }
  else if (/Firefox\//.test(ua)) { browser = 'Firefox'; browserFamily = 'Firefox'; }
  else if (/Version\/.*Safari/.test(ua)) { browser = 'Safari'; browserFamily = 'Safari'; }
  else if (/MSIE|Trident/.test(ua)) { browser = 'Internet Explorer'; browserFamily = 'Internet Explorer'; }
  else { browser = 'Other'; browserFamily = 'Other'; }

  // OS
  if (/Windows NT/.test(ua)) { os = 'Windows'; osFamily = 'Windows'; }
  else if (/Mac OS X/.test(ua) && !/iPhone|iPad/.test(ua)) { os = 'macOS'; osFamily = 'macOS'; }
  else if (/Android/.test(ua)) { os = 'Android'; osFamily = 'Android'; }
  else if (/iPhone|iPad|iPod/.test(ua)) { os = 'iOS'; osFamily = 'iOS'; }
  else if (/Linux/.test(ua)) { os = 'Linux'; osFamily = 'Linux'; }
  else { os = 'Other'; osFamily = 'Other'; }

  // Device class
  if (/iPad|Tablet/.test(ua)) device = 'Tablet';
  else if (/Mobi|iPhone|Android.*Mobile/.test(ua)) device = 'Mobile';
  else device = 'Desktop';

  return { browser, browserFamily, os, osFamily, device };
}

function md5(s) { return crypto.createHash('md5').update(String(s)).digest('hex'); }

function domainFromReferrer(ref) {
  if (!ref) return '';
  try { return new URL(ref).hostname; } catch (e) { return ''; }
}

let buffer = [];

function nowIso() { return new Date().toISOString(); }

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
    } catch (e) { /* ignore malformed body */ }
  }
  return params;
}

function num(v, def = 0) { const n = parseFloat(v); return isNaN(n) ? def : n; }

function toEventRow(p, req) {
  const eventType = EVENT_TYPE_MAP[parseInt(p.eventType, 10)];
  if (!eventType) return null;
  const partnerId = String(p.partnerId || p.partner_id || '');
  const entryId = String(p.entryId || p.entry_id || '');
  if (!partnerId || !entryId) return null;

  const uaRaw = req.headers['user-agent'] || '';
  const ua = parseUA(uaRaw);
  const sessionId = String(p.sessionId || p.playbackSessionId || '');
  // Unique-viewer identity. KAVA normally uses a persistent browser cookie; the
  // beacon carries no such id, so for anonymous playback we fingerprint the
  // viewer by client IP + User-Agent. This keeps the SAME viewer stable across
  // page reloads (a reload is not a new unique viewer), unlike sessionId which
  // changes every page load. A logged-in kuserId/userId still wins when present.
  const clientIp = String((req.headers['x-forwarded-for'] || '').split(',')[0].trim()
    || req.socket.remoteAddress || '');
  const userKey = String(p.userId || p.kuserId || (clientIp + '|' + uaRaw));

  // playTimeSum (seconds): viewPeriod = one ~10s period; playThrough may carry it.
  let playTimeSum = 0;
  if (eventType === 'viewPeriod') {
    playTimeSum = p.playTimeSum != null ? Math.min(num(p.playTimeSum, VIEW_PERIOD_SECONDS), VIEW_PERIOD_SECONDS) : VIEW_PERIOD_SECONDS;
  } else if (eventType.startsWith('playThrough')) {
    playTimeSum = num(p.playTimeSum, 0);
  }

  // QoE inputs + eventProperties flags (KB 238-245)
  const eventProperties = [];
  const bitrate = num(p.actualBitrate, 0) || num(p.averageBitrate, 0);
  let bitrateSum = 0, bitrateCount = 0;
  if (bitrate > 0 && (eventType === 'viewPeriod' || eventType === 'view')) {
    bitrateSum = bitrate; bitrateCount = 1; eventProperties.push('hasBitrate');
  }
  const bufferTime = num(p.bufferTime, 0);
  let bufferTimeSum = 0;
  if (bufferTime > 0) { bufferTimeSum = bufferTime; eventProperties.push('isBuffering'); }
  const joinTime = num(p.joinTime, 0);
  let eventDoubleSum1 = 0;
  if (joinTime > 0 && eventType === 'play') { eventDoubleSum1 = joinTime; eventProperties.push('hasJoinTime'); }
  const bufferStarts = eventType === 'bufferStart' ? 1 : 0;
  const flavorSwitches = eventType === 'flavorSwitch' ? 1 : 0;

  return {
    __time: nowIso(),
    // ── dimensions (kKavaBase player-events-historical) ──
    eventType,
    partnerId,
    entryId,
    kuserId: userKey ? md5(userKey) : '',
    mediaType: String(p.mediaType || 'VIDEO'),
    playbackType: String(p.playbackType || 'vod'),
    'location.country': '', // geo enrichment hook (needs real client IP + MaxMind)
    'location.region': '',
    'location.city': '',
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
    eventProperties,                // multi-value dimension
    // ── HLL sketch inputs (consumed by hyperUnique aggregators, not stored raw) ──
    _userId: userKey,
    _sessionId: sessionId,
    // ── metric value columns ──
    count: 1,
    playTimeSum,
    bitrateSum,
    bitrateCount,
    bufferTimeSum,
    eventDoubleSum1,
    bufferStarts,
    flavorSwitches,
  };
}

const DIMENSIONS = [
  'eventType', 'partnerId', 'entryId', 'kuserId', 'mediaType', 'playbackType',
  'location.country', 'location.region', 'location.city',
  'userAgent.browser', 'userAgent.browserFamily',
  'userAgent.operatingSystem', 'userAgent.operatingSystemFamily', 'userAgent.device',
  'urlParts.domain', 'application', 'applicationVer', 'playerVersion', 'uiConfId',
  'playbackContext',
  { type: 'string', name: 'eventProperties', multiValueHandling: 'ARRAY' },
];

const METRICS = [
  { type: 'count', name: 'count' },
  { type: 'longSum', name: 'playTimeSum', fieldName: 'playTimeSum' },
  { type: 'longSum', name: 'bitrateSum', fieldName: 'bitrateSum' },
  { type: 'longSum', name: 'bitrateCount', fieldName: 'bitrateCount' },
  { type: 'longSum', name: 'bufferStarts', fieldName: 'bufferStarts' },
  { type: 'longSum', name: 'flavorSwitches', fieldName: 'flavorSwitches' },
  { type: 'doubleSum', name: 'bufferTimeSum', fieldName: 'bufferTimeSum' },
  { type: 'doubleSum', name: 'eventDoubleSum1', fieldName: 'eventDoubleSum1' },
  // HLL sketches — the only way unique_* metrics resolve.
  { type: 'hyperUnique', name: 'uniqueUserIds', fieldName: '_userId' },
  { type: 'hyperUnique', name: 'uniqueSessionId', fieldName: '_sessionId' },
];

function flush() {
  if (buffer.length === 0) return;
  const events = buffer;
  buffer = [];
  const ndjson = events.map((e) => JSON.stringify(e)).join('\n');

  const task = {
    type: 'index_parallel',
    spec: {
      dataSchema: {
        dataSource: DATASOURCE,
        timestampSpec: { column: '__time', format: 'iso' },
        dimensionsSpec: { dimensions: DIMENSIONS },
        metricsSpec: METRICS,
        granularitySpec: {
          type: 'uniform', segmentGranularity: 'DAY', queryGranularity: 'HOUR', rollup: true,
        },
      },
      ioConfig: {
        type: 'index_parallel',
        inputSource: { type: 'inline', data: ndjson },
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
  r.on('error', (e) => {
    console.error(`[receiver] ingest error: ${e.message}; re-buffering ${events.length}`);
    buffer = events.concat(buffer);
  });
  r.write(payload); r.end();
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/health')) { res.writeHead(200); res.end('ok'); return; }
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
  req.on('end', () => {
    try {
      const row = toEventRow(parseParams(req, body), req);
      if (row) { buffer.push(row); if (buffer.length >= MAX_BUFFER) flush(); }
    } catch (e) { console.error(`[receiver] parse error: ${e.message}`); }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('1');
  });
});

setInterval(flush, FLUSH_INTERVAL_MS);
server.listen(PORT, () => console.log(`[receiver] listening on :${PORT}, flush ${FLUSH_INTERVAL_MS}ms → ${DRUID_OVERLORD}`));
