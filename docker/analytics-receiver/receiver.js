// Kaltura analytics event receiver — minimal Kanalony replacement.
//
// The V7 PlayKit (kava) player POSTs/GETs analytics beacons to
//   {analytics_host}/api_v3/index.php?service=analytics&action=trackEvent
// CE has no ingestion endpoint for these (it's a closed-source SaaS service),
// so Apache proxies that path here. We translate the numeric KAVA eventType to
// the string dimension values kKavaBase expects, buffer the events, and append
// them to the Druid `player-events-historical` datasource via native batch
// ingestion tasks. Kaltura's report API then queries that datasource.

const http = require('http');

const DRUID_OVERLORD = process.env.DRUID_OVERLORD || 'http://druid-coordinator:8081';
const DATASOURCE = 'player-events-historical';
const FLUSH_INTERVAL_MS = parseInt(process.env.FLUSH_INTERVAL_MS || '20000', 10);
const MAX_BUFFER = parseInt(process.env.MAX_BUFFER || '200', 10);
const PORT = parseInt(process.env.PORT || '9999', 10);

// KAVA numeric eventType -> kKavaBase string dimension value
const EVENT_TYPE_MAP = {
  1: 'playerImpression',
  2: 'playRequested',
  3: 'play',
  4: 'resume',
  11: 'playThrough25',
  12: 'playThrough50',
  13: 'playThrough75',
  14: 'playThrough100',
  33: 'pauseClicked',
  34: 'replay',
  35: 'seek',
  38: 'captions',
  39: 'sourceSelected',
  41: 'speed',
  43: 'flavorSwitch',
  45: 'bufferStart',
  46: 'bufferEnd',
  98: 'error',
  99: 'viewPeriod', // VIEW heartbeat (~every 10s) carries play time for the period
};

let buffer = [];

function nowIso() {
  // Druid timestamps are ISO-8601 UTC. (Receiver only stamps arrival time;
  // real ingestion timestamp = event arrival, which is fine for live analytics.)
  return new Date().toISOString();
}

function parseParams(req, body) {
  const url = new URL(req.url, 'http://localhost');
  const params = {};
  for (const [k, v] of url.searchParams) params[k] = v;
  if (body) {
    const ct = (req.headers['content-type'] || '').toLowerCase();
    try {
      if (ct.includes('application/json')) {
        Object.assign(params, JSON.parse(body));
      } else {
        // form-encoded
        for (const pair of body.split('&')) {
          const i = pair.indexOf('=');
          if (i > 0) params[decodeURIComponent(pair.slice(0, i))] =
            decodeURIComponent(pair.slice(i + 1).replace(/\+/g, ' '));
        }
      }
    } catch (e) { /* ignore malformed body */ }
  }
  return params;
}

function toEventRow(p) {
  const rawType = parseInt(p.eventType, 10);
  const eventType = EVENT_TYPE_MAP[rawType];
  if (!eventType) return null; // unknown/ignored event
  const partnerId = String(p.partnerId || p.partner_id || '');
  const entryId = String(p.entryId || p.entry_id || '');
  if (!partnerId || !entryId) return null;

  // playTimeSum: VIEW heartbeats and playThrough events carry play time (seconds).
  let playTimeSum = 0;
  if (eventType === 'viewPeriod') {
    playTimeSum = p.playTimeSum != null ? parseFloat(p.playTimeSum) : 10;
  } else if (eventType.startsWith('playThrough')) {
    playTimeSum = p.playTimeSum != null ? parseFloat(p.playTimeSum) : 0;
  }

  return {
    __time: nowIso(),
    partnerId,
    entryId,
    eventType,
    application: String(p.application || ''),
    mediaType: 'VIDEO',
    playbackType: String(p.playbackType || 'vod'),
    count: 1,
    playTimeSum: isNaN(playTimeSum) ? 0 : playTimeSum,
  };
}

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
        dimensionsSpec: {
          dimensions: ['partnerId', 'entryId', 'eventType', 'application', 'mediaType', 'playbackType'],
        },
        metricsSpec: [
          { type: 'count', name: 'events' },
          { type: 'longSum', name: 'count', fieldName: 'count' },
          { type: 'doubleSum', name: 'playTimeSum', fieldName: 'playTimeSum' },
        ],
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
  const opts = {
    hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
  };
  const r = http.request(opts, (res) => {
    let d = '';
    res.on('data', (c) => (d += c));
    res.on('end', () => {
      if (res.statusCode >= 300) console.error(`[receiver] ingest HTTP ${res.statusCode}: ${d}`);
      else console.log(`[receiver] ingested ${events.length} events: ${d}`);
    });
  });
  r.on('error', (e) => {
    console.error(`[receiver] ingest error: ${e.message}; re-buffering ${events.length}`);
    buffer = events.concat(buffer); // retry next flush
  });
  r.write(payload);
  r.end();
}

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/health')) {
    res.writeHead(200); res.end('ok'); return;
  }
  let body = '';
  req.on('data', (c) => { body += c; if (body.length > 1e6) req.destroy(); });
  req.on('end', () => {
    const params = parseParams(req, body);
    const row = toEventRow(params);
    if (row) {
      buffer.push(row);
      if (buffer.length >= MAX_BUFFER) flush();
    }
    // KAVA ignores the body; return a minimal Kaltura-style 200.
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('1');
  });
});

setInterval(flush, FLUSH_INTERVAL_MS);
server.listen(PORT, () => console.log(`[receiver] listening on :${PORT}, flushing to ${DRUID_OVERLORD} every ${FLUSH_INTERVAL_MS}ms`));
