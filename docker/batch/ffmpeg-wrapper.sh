#!/bin/bash
# FFmpeg argument translation wrapper.
# Kaltura's KDLOperatorFfmpeg1_1_1 hardcodes -c:a libfdk_aac in conversion
# commands. libfdk_aac is non-free and excluded from most static ffmpeg
# builds. We replace it with the native aac encoder at invocation time so
# the Kaltura source stays AGPL-pristine while conversions actually run.
args=()
for a in "$@"; do
    args+=("${a//libfdk_aac/aac}")
done
exec /usr/bin/ffmpeg-real "${args[@]}"
