#!/bin/bash
# qt-faststart equivalent using ffmpeg's modern -movflags faststart.
# Kaltura's KConversionEngineFfmpeg runs `qt-faststart INPUT OUTPUT` as a post-
# conversion step to move the MOOV atom to the start of the MP4 (for fast
# streaming start). mwader/static-ffmpeg doesn't ship the standalone tool, but
# ffmpeg can do the same thing via -movflags +faststart with -c copy (no re-encode).
# Kaltura's OUTPUT path has no extension; force mp4 format explicitly.
INPUT="$1"
OUTPUT="$2"
if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    echo "Usage: $0 INPUT.mp4 OUTPUT.mp4" >&2
    exit 1
fi
exec /usr/bin/ffmpeg-real -i "$INPUT" -c copy -movflags +faststart -f mp4 -y "$OUTPUT"
