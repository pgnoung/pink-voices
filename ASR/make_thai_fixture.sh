#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/fixtures"
say -v Kanya -o "$ROOT/fixtures/thai-local.aiff" 'สวัสดีครับ วันนี้เราทดสอบการเขียนตามคำบอกภาษาไทย'
ffmpeg -hide_banner -loglevel error -y -i "$ROOT/fixtures/thai-local.aiff" \
  -ac 1 -ar 16000 -c:a pcm_s16le "$ROOT/fixtures/thai-local.wav"
echo "$ROOT/fixtures/thai-local.wav"
