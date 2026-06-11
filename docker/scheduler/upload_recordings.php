<?php
/**
 * Live recording → VOD ingest (Kaltura's "[name]-VOD" pattern from the
 * official nginx-rtmp live-streaming guide).
 *
 * nginx-rtmp records every stream to the shared live_recordings volume; the
 * .flv closes when the encoder disconnects. This script (scheduler cron,
 * every minute) uploads each settled file as a VOD entry via the official
 * API (uploadToken + media.add) and deletes it on success. A failed upload
 * leaves the file in place, so the next run retries naturally.
 *
 * Partner resolution (robust across resets):
 *   • Native streams are named "<entryId>_<flavorIndex>" — the owning partner
 *     is derived from that entry, so no fixed ID is needed.
 *   • Manual streams have arbitrary names — they fall back to LIVE_PARTNER_ID.
 *   Admin secrets are read from the DB, never stored in env.
 */

$REC_DIR  = '/opt/kaltura/live_recordings';
$SETTLE_S = 60; // a file still being written is younger than this

$files = glob("$REC_DIR/*.flv") ?: [];
$ready = array_filter($files, fn($f) => time() - filemtime($f) > $SETTLE_S && filesize($f) > 0);
if (!$ready) {
    exit(0);
}

require_once '/opt/kaltura/app/tests/lib/KalturaClient.php';

$wwwHost  = getenv('WWW_HOST') ?: 'localhost';
$protocol = getenv('PROTOCOL') ?: 'https';
$fallbackPartner = (int)(getenv('LIVE_PARTNER_ID') ?: 0);
$pdo = new PDO(
    sprintf('mysql:host=%s;port=%s;dbname=%s', getenv('DB1_HOST') ?: 'mysql', getenv('DB1_PORT') ?: '3306', getenv('DB1_NAME') ?: 'kaltura'),
    getenv('DB1_USER') ?: 'kaltura', getenv('DB1_PASS') ?: ''
);

// Cache one Kaltura client per partner (admin secret looked up on demand).
$clients = [];
function clientFor($partnerId, $pdo, $protocol, $wwwHost, &$clients) {
    if (isset($clients[$partnerId])) return $clients[$partnerId];
    $stmt = $pdo->prepare('SELECT admin_secret FROM partner WHERE id = ?');
    $stmt->execute([$partnerId]);
    $secret = $stmt->fetchColumn();
    if (!$secret) return $clients[$partnerId] = null;
    $cfg = new KalturaConfiguration($partnerId);
    $cfg->serviceUrl = "$protocol://$wwwHost";
    $cfg->verifySSL = false; // self-signed certs in dev
    $client = new KalturaClient($cfg);
    $client->setKs($client->session->start($secret, 'live-recorder', KalturaSessionType::ADMIN, $partnerId));
    return $clients[$partnerId] = $client;
}

foreach ($ready as $file) {
    // 0_abc123_1-2026-06-10-082233.flv → stream "0_abc123_1", strip the timestamp
    $base = basename($file, '.flv');
    $stream = preg_replace('/-\d{4}-\d{2}-\d{2}-\d{6}$/', '', $base);

    // Native stream "<entryId>_<idx>" → owning partner from the entry.
    $partnerId = $fallbackPartner;
    if (preg_match('/^(\d+_[A-Za-z0-9]+)_\d+$/', $stream, $m)) {
        $st = $pdo->prepare('SELECT partner_id FROM entry WHERE id = ? LIMIT 1');
        $st->execute([$m[1]]);
        $p = $st->fetchColumn();
        if ($p) $partnerId = (int)$p;
    }
    if ($partnerId <= 0) {
        echo date('c') . " skip $base: no partner (set LIVE_PARTNER_ID for manual streams)\n";
        continue;
    }

    $client = clientFor($partnerId, $pdo, $protocol, $wwwHost, $clients);
    if (!$client) { echo date('c') . " ERROR: partner $partnerId not found for $base\n"; continue; }

    try {
        $token = $client->uploadToken->add(new KalturaUploadToken());
        $client->uploadToken->upload($token->id, $file);

        $e = new KalturaMediaEntry();
        $e->name = "$stream-VOD " . date('Y-m-d H:i', filemtime($file));
        $e->description = "Live stream recording ($base)";
        $e->mediaType = KalturaMediaType::VIDEO;
        $entry = $client->media->add($e);

        $res = new KalturaUploadedFileTokenResource();
        $res->token = $token->id;
        $client->media->addContent($entry->id, $res);

        unlink($file);
        echo date('c') . " uploaded $base → entry {$entry->id} (partner $partnerId)\n";
    } catch (Exception $ex) {
        echo date('c') . " ERROR uploading $base: {$ex->getMessage()} — will retry\n";
    }
}
