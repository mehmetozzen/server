'use strict';

const express = require('express');
const fs = require('fs');

const app = express();
const PORT = 8080;

// Resolve pre-built player bundle at startup so we fail fast if the package is missing
const BUNDLE_PATH = require.resolve('@playkit-js/kaltura-player-js/dist/kaltura-ovp-player.js');
const BUNDLE_CONTENT = fs.readFileSync(BUNDLE_PATH, 'utf8');
const BUNDLE_B64 = Buffer.from(BUNDLE_CONTENT).toString('base64');

console.log(`[bundler] Loaded player bundle from ${BUNDLE_PATH} (${BUNDLE_CONTENT.length} bytes)`);

// Kaltura PHP embedPlaykitJsAction calls:
//   GET /build?config=<b64_json>&name=<md5>&source=<b64_path>&includeSourceMap=<bool>
// and expects:
//   { "status": 0, "payload": { "bundle": "<b64_js>", "sourceMap": "<b64>", "i18n": "<b64>", "extraModules": [] } }
// KNOWN LIMITATION: this is a STUB bundler. It always returns the pre-built
// kaltura-ovp-player bundle and IGNORES the requested plugin set — a Studio-
// configured plugin (IMA, playlist, dual-screen, …) that is not already part
// of the ovp bundle will silently not ship. The warning below makes that
// visible in the logs instead of surfacing as a mystery "Studio bug".
const BUNDLED_PKGS = new Set([
    'kaltura-ovp-player',
    '@playkit-js/kaltura-player-js',
    // shipped inside the ovp bundle:
    'playkit-js', 'playkit-ui', 'playkit-hls', 'playkit-dash',
    'playkit-kaltura-cuepoints', 'playkit-kaltura-live', 'playkit-ivq', 'playkit-youtube',
]);

app.get('/build', (req, res) => {
    const name = req.query.name || 'unknown';
    let config = {};
    try {
        config = JSON.parse(Buffer.from(req.query.config || '', 'base64').toString('utf8'));
    } catch (_) {}

    const requested = Object.keys(config);
    const ignored = requested.filter((p) => !BUNDLED_PKGS.has(p));
    console.log(`[bundler] Build request name=${name} packages=${requested.join(',')}`);
    if (ignored.length) {
        console.warn(`[bundler] WARN: stub bundler IGNORES requested plugin(s): ${ignored.join(', ')} — they will NOT be in the served player (see docker/README.md)`);
    }

    res.json({
        status: 0,
        payload: {
            bundle: BUNDLE_B64,
            sourceMap: '',
            i18n: Buffer.from('{}').toString('base64'),
            extraModules: []
        }
    });
});

app.get('/health', (_req, res) => res.send('ok'));

const PLAYER_VERSION = require('@playkit-js/kaltura-player-js/package.json').version;
app.get('/version', (_req, res) => res.send(PLAYER_VERSION));

app.listen(PORT, () => console.log(`[bundler] Listening on :${PORT}`));
