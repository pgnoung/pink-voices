#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$ROOT/model"
PYTHON="$ROOT/.venv/bin/python"

test -x "$PYTHON" || { echo "Run ./setup.sh first." >&2; exit 1; }
test -f "$MODEL_DIR/openthai2.0-asr-streaming_raw.nemo" || { echo "Model missing. Run ./setup.sh first." >&2; exit 1; }

cd "$MODEL_DIR/serve"
server="local_dictation:app"
if [[ "${THAI_DICTATION_RAW_ASR:-0}" == "1" ]]; then
  server="app:app"
fi
exec env CHINDA_NUM_THREADS=1 CHINDA_PRELOAD=1 "PYTHONPATH=$ROOT:$MODEL_DIR/serve" \
  "$PYTHON" -m uvicorn "$server" --host 127.0.0.1 --port 18081
