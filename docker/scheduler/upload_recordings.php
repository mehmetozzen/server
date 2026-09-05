<?php
/**
 * Live recording → VOD ingest.
 *
 * nginx-rtmp records every publish to the shared live_recordings volume
 * (`record all`); the .flv closes when the encoder disconnects. This cron runs
 * every minute and hands each settled file to Kaltura.
 *
 * NATIVE entries (stream "<entryId>_<flavorIndex>") go through Kaltura's own
 * live→VOD pipeline via liveStream.appendRecording. That is worth insisting on:
 * an earlier version concatenated the sessions here with `ffmpeg -f concat -c
 * copy` into a per-entry FLV master, and on real nginx-rtmp captures the video
 * track silently stopped at the previous session's end while audio kept going —
 * a whole 30s session lost with a success line in the log. Kaltura remuxes each
 * chunk to MPEG-TS first (KAsyncConvertLiveSegment), checks segment continuity,
 * then joins under a lock (KAsyncConcat); TS concatenation has none of FLV's
 * timestamp fragility. Both workers are already enabled in batch.ini.
 *
 * Delegating also hands us the panel semantics for free — Kaltura, not this
 * script, decides what record_status means:
 *   DISABLED    no recorded entry at all
 *   PER_SESSION new entry per session ("<live name> 1", "<live name> 2", …)
 *   APPENDED    same entry grows, until a week or the duration cap is reached
 * and the VOD it creates is a proper KALTURA_RECORDED_LIVE entry linked to the
 * live one by rootEntryId, instead of a loose "<stream>-VOD <date>" upload.
 *
 * MANUAL entries have arbitrary stream names, so no entry carries a setting and
 * none of the above applies. They keep the plain uploadToken + media.add path
 * under LIVE_PARTNER_ID.
 *
 * DISABLED is still enforced here rather than left to Kaltura: nginx-rtmp has no
 * view of the entry and records regardless, so the file must be dropped by the
 * first component that can read record_status — this one.
 *
 * Admin secrets are read from the DB, never stored in env.
 */

$REC_DIR   = '/opt/kaltura/live_recordings';
// appendRecording runs in the app container, which mounts kaltura_web but NOT
// live_recordings — the chunk has to be staged somewhere both can see. This is
// kConf's uploaded_segment_destination.
$STAGE_DIR = '/opt/kaltura/web/tmp/convert';
$SETTLE_S  = 60; // a file still being written is younger than this

// LiveEntry::CUSTOM_DATA_RECORD_STATUS values (alpha/lib/enums/RecordStatus.php)
const RECORD_DISABLED    = 0;
const RECORD_APPENDED    = 1;
const RECORD_PER_SESSION = 2;

// Sweep staged chunks Kaltura has finished with. appendRecording copies the
// file into the recorded entry synchronously (ingestAsset, shouldCopy=true) but
// the ConvertLiveSegment job reads the staged path later and asynchronously, so
// the cron cannot delete on success and Kaltura never does — every recording
// leaked its full size into tmp/convert. The job runs within minutes; anything
// older than STAGE_TTL_S is done. Only our own "<entry>_<idx>-<stamp>" names
// are touched: tmp/convert is Kaltura's shared uploaded_segment_destination.
$STAGE_TTL_S = 2 * 3600;
foreach (glob("$STAGE_DIR/*") ?: [] as $stale) {
    if (!is_file($stale) || time() - filemtime($stale) <= $STAGE_TTL_S) continue;
    if (!preg_match('/^\d+_[A-Za-z0-9]+_\d+-\d{4}-\d{2}-\d{2}-\d{6}\.(flv|mp4)$/', basename($stale))) continue;
    if (@unlink($stale)) echo date('c') . " swept staged chunk " . basename($stale) . "\n";
}

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

// Kaltura's own live→VOD path refuses to run while the partner still carries
// FEATURE_LIVE_STREAM_KALTURA_RECORDING, the flag meaning "Kaltura's cloud does
// the recording" — which has no counterpart in this deployment. Block it, but
// only when the API actually complains, so we never touch permissions we did
// not have to. FEATURE_LIVE_STREAM_RECORD stays active: the KMC panel needs it
// to set recordStatus at all.
// appendRecording is a media-server call, not a publisher one: it is guarded by
// MEDIA_SERVER_BASE, which lives on the built-in Media partner (-5) — the same
// identity analytics-receiver already uses for registerMediaServer. A content
// partner's admin KS gets "access to service is forbidden".
const MEDIA_SERVER_PARTNER = -5;

function blockKalturaRecordingFlag($client) {
    try {
        $p = new KalturaPermission();
        $p->status = KalturaPermissionStatus::BLOCKED;
        $client->permission->update('FEATURE_LIVE_STREAM_KALTURA_RECORDING', $p);
        return true;
    } catch (Exception $e) {
        echo date('c') . " ERROR blocking FEATURE_LIVE_STREAM_KALTURA_RECORDING: {$e->getMessage()}\n";
        return false;
    }
}

foreach ($ready as $file) {
    // 0_abc123_1-2026-06-10-082233.flv → stream "0_abc123_1", strip the timestamp
    $base = basename($file, '.flv');
    $stream = preg_replace('/-\d{4}-\d{2}-\d{2}-\d{6}$/', '', $base);

    // Native stream "<entryId>_<idx>" → the owning entry carries the partner and
    // the recording settings. Manual streams have no such entry.
    $partnerId    = $fallbackPartner;
    $liveEntryId  = null;
    $recordStatus = RECORD_PER_SESSION;
    if (preg_match('/^(\d+_[A-Za-z0-9]+)_\d+$/', $stream, $m)) {
        $st = $pdo->prepare('SELECT partner_id, custom_data FROM entry WHERE id = ? LIMIT 1');
        $st->execute([$m[1]]);
        $row = $st->fetch(PDO::FETCH_ASSOC);
        if ($row && $row['partner_id']) {
            $partnerId   = (int)$row['partner_id'];
            $liveEntryId = $m[1];
            // custom_data is a flat serialized map. Read it by pattern rather
            // than unserialize(): it embeds kLiveStreamConfiguration objects
            // that are not autoloadable from the scheduler container, and the
            // receiver reads streamPassword the same way.
            if (preg_match('/"record_status";i:(\d+);/', (string)$row['custom_data'], $rm)) {
                $recordStatus = (int)$rm[1];
            }
        }
    }

    // The publisher said no. nginx-rtmp recorded it anyway because it cannot see
    // Kaltura, so this is where the file dies.
    if ($recordStatus === RECORD_DISABLED) {
        unlink($file);
        echo date('c') . " discard $base: recording disabled on entry $liveEntryId\n";
        continue;
    }

    if ($partnerId <= 0) {
        echo date('c') . " skip $base: no partner (set LIVE_PARTNER_ID for manual streams)\n";
        continue;
    }

    $client = clientFor($partnerId, $pdo, $protocol, $wwwHost, $clients);
    if (!$client) { echo date('c') . " ERROR: partner $partnerId not found for $base\n"; continue; }

    // ── Native: delegate to Kaltura's live→VOD pipeline ──────────────────────
    if ($liveEntryId) {
        // The chunk is attributed to the live asset tagged recording_anchor;
        // that tag is what makes Kaltura treat it as the duration reference.
        $st = $pdo->prepare(
            'SELECT id FROM flavor_asset WHERE entry_id = ? AND type = 3 AND tags LIKE ? AND status = 2 LIMIT 1');
        $st->execute([$liveEntryId, '%recording_anchor%']);
        $assetId = $st->fetchColumn();

        $msClient = clientFor(MEDIA_SERVER_PARTNER, $pdo, $protocol, $wwwHost, $clients);
        if ($assetId && $msClient) {
            $probe = [];
            exec('ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 '
                . escapeshellarg($file) . ' 2>/dev/null', $probe);
            $duration = (float)($probe[0] ?? 0);
            if ($duration <= 0) {
                echo date('c') . " ERROR $base: could not read duration — will retry\n";
                continue;
            }

            if (!is_dir($STAGE_DIR) && !mkdir($STAGE_DIR, 0775, true) && !is_dir($STAGE_DIR)) {
                echo date('c') . " ERROR $base: cannot create $STAGE_DIR — will retry\n";
                continue;
            }
            // Remux to MP4 first. appendRecording hands the file straight to
            // ingestAsset, which stores it on the recorded entry as-is and takes
            // the playback extension from it — and the packager cannot serve an
            // FLV, so a recording ingested as .flv answers 404 and the entry is
            // unplayable. A real Wowza never hits this because it records MP4
            // chunks; nginx-rtmp only writes FLV. -c copy is a container swap,
            // no re-encode, so the cost is I/O.
            //
            // The bug hid behind the append case: two or more sessions trigger
            // Kaltura's concat job, whose output happens to be MP4, so only
            // single-session recordings — the common case — were broken.
            $staged = "$STAGE_DIR/$base.mp4";
            exec('ffmpeg -y -hide_banner -loglevel error -i ' . escapeshellarg($file)
                . ' -c copy -movflags +faststart ' . escapeshellarg($staged) . ' 2>&1', $out, $rc);
            if ($rc !== 0 || !file_exists($staged) || filesize($staged) === 0) {
                @unlink($staged);
                echo date('c') . " ERROR $base: remux to mp4 failed ("
                    . implode(' ', array_slice($out, 0, 2)) . ") — will retry\n";
                continue;
            }
            unlink($file);
            // The app runs as www-data and has to read what this cron wrote.
            @chmod($staged, 0644);

            $res = new KalturaServerFileResource();
            $res->localFilePath   = $staged;
            $res->keepOriginalFile = false;

            // isLastChunk: the .flv is closed, so the encoder is already gone.
            $send = function () use ($msClient, $liveEntryId, $assetId, $res, $duration) {
                return $msClient->liveStream->appendRecording(
                    $liveEntryId, $assetId, KalturaEntryServerNodeType::LIVE_PRIMARY, $res, $duration, true);
            };

            try {
                try {
                    $send();
                } catch (Exception $inner) {
                    // KALTURA_RECORDING_ENABLED — clear the flag once, then retry.
                    if (strpos($inner->getMessage(), 'KALTURA_RECORDING_ENABLED') === false) throw $inner;
                    echo date('c') . " note: partner $partnerId still has FEATURE_LIVE_STREAM_KALTURA_RECORDING — blocking it\n";
                    if (!blockKalturaRecordingFlag($client)) throw $inner;
                    $send();
                }
                printf("%s appended %s (%.1fs) → live entry %s [%s] (partner %d)\n",
                    date('c'), $base, $duration, $liveEntryId,
                    $recordStatus === RECORD_APPENDED ? 'append' : 'per-session', $partnerId);
            } catch (Exception $ex) {
                // Put it back so the next run retries instead of losing the take.
                // Renaming the mp4 to the original .flv name is fine: the next
                // run remuxes it again, and ffmpeg reads the container it finds
                // rather than trusting the extension.
                if (file_exists($staged)) @rename($staged, $file);
                echo date('c') . " ERROR appendRecording $base: {$ex->getMessage()} — will retry\n";
            }
            continue;
        }

        echo date('c') . " WARN $base: no recording_anchor live asset (or no media-server session) on $liveEntryId"
            . " — falling back to a standalone VOD upload\n";
    }

    // ── Manual streams (and the native fallback): plain VOD upload ───────────
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
