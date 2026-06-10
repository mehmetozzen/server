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
 * Config: LIVE_PARTNER_ID env — the partner that owns the recordings
 * (unset = feature off). The partner's admin secret is read from the DB,
 * never stored in env.
 */

$REC_DIR  = '/opt/kaltura/live_recordings';
$SETTLE_S = 60; // a file still being written is younger than this

$partnerId = (int)(getenv('LIVE_PARTNER_ID') ?: 0);
if ($partnerId <= 0) {
    exit(0); // feature off — stay silent so the cron log doesn't fill up
}

$files = glob("$REC_DIR/*.flv") ?: [];
$ready = array_filter($files, fn($f) => time() - filemtime($f) > $SETTLE_S && filesize($f) > 0);
if (!$ready) {
    exit(0);
}

require_once '/opt/kaltura/app/tests/lib/KalturaClient.php';

$wwwHost  = getenv('WWW_HOST') ?: 'localhost';
$protocol = getenv('PROTOCOL') ?: 'https';
$pdo = new PDO(
    sprintf('mysql:host=%s;port=%s;dbname=%s', getenv('DB1_HOST') ?: 'mysql', getenv('DB1_PORT') ?: '3306', getenv('DB1_NAME') ?: 'kaltura'),
    getenv('DB1_USER') ?: 'kaltura', getenv('DB1_PASS') ?: ''
);
$stmt = $pdo->prepare('SELECT admin_secret FROM partner WHERE id = ?');
$stmt->execute([$partnerId]);
$adminSecret = $stmt->fetchColumn();
if (!$adminSecret) {
    echo date('c') . " ERROR: partner $partnerId not found\n";
    exit(1);
}

$cfg = new KalturaConfiguration($partnerId);
$cfg->serviceUrl = "$protocol://$wwwHost";
$cfg->verifySSL = false; // self-signed certs in dev (KalturaClientBase::doCurl)
$client = new KalturaClient($cfg);
$client->setKs($client->session->start($adminSecret, 'live-recorder', KalturaSessionType::ADMIN, $partnerId));

foreach ($ready as $file) {
    // test1-2026-06-10-082233.flv → stream "test1", timestamp from the suffix
    $base = basename($file, '.flv');
    $stream = preg_replace('/-\d{4}-\d{2}-\d{2}-\d{6}$/', '', $base);
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
