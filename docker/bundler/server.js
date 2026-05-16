'use strict';

const express = require('express');
const fs = require('fs');
const path = require('path');

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
app.get('/build', (req, res) => {
    const name = req.query.name || 'unknown';
    let config = {};
    try {
        config = JSON.parse(Buffer.from(req.query.config || '', 'base64').toString('utf8'));
    } catch (_) {}

    console.log(`[bundler] Build request name=${name} packages=${Object.keys(config).join(',')}`);

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
