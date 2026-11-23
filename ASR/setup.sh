#!/usr/bin/env bash
set -euo pipefail

# Official iApp macOS CPU installation, isolated to this directory.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# The app passes its own pinned uv; a developer checkout can use one on PATH.
UV="${UV:-uv}"

if [[ -e .venv || -L .venv ]]; then
  if ! .venv/bin/python -c 'import sys; sys.exit(sys.version_info[:2] != (3, 12))'; then
    echo 'Existing ASR/.venv is not a usable Python 3.12 environment. Choose a fresh extraction directory.' >&2
    exit 1
  fi
else
  "$UV" venv .venv --python 3.12.15
fi
PYTHON="$ROOT/.venv/bin/python"
# The engine is installed from a source archive whose version has no git suffix, so its own pin is left out.
CONSTRAINTS="$ROOT/.constraints.txt"
grep -v '^nemo-toolkit==' "$ROOT/runtime-versions.txt" > "$CONSTRAINTS"

"$UV" pip install -c "$CONSTRAINTS" --python "$PYTHON" torch==2.13.0
"$UV" pip install -c "$CONSTRAINTS" --python "$PYTHON" Cython packaging
"$UV" pip install -c "$CONSTRAINTS" --python "$PYTHON" \
  "nemo-toolkit[asr] @ https://github.com/NVIDIA-NeMo/Speech/archive/cf724ac337d1ebc7d0dda1e23fb80916f52927a5.tar.gz"
# A source archive of the same commit: no git or Xcode tools needed on a fresh Mac.
"$UV" pip install -c "$CONSTRAINTS" --python "$PYTHON" fastapi uvicorn python-multipart websockets huggingface_hub sounddevice

# This revision is the public model HEAD observed on 2026-11-22.  Only the
# official server and raw checkpoint are downloaded; no account token is used.
if [[ ! -f "$ROOT/model/openthai2.0-asr-streaming_raw.nemo" ]]; then
  "$ROOT/.venv/bin/hf" download \
    iapp/OpenThai2.0-ASR-Streaming \
    --revision c28df2a70bb16376ed7dc6a5233cffb41bb54a68 \
    --include '*_raw.nemo' \
    --local-dir "$ROOT/model"
fi
if ! (cd "$ROOT/model" && awk '/  serve\// {print}' "$ROOT/model.sha256" | shasum -a 256 -c - >/dev/null 2>&1); then
  "$ROOT/.venv/bin/hf" download \
    iapp/OpenThai2.0-ASR-Streaming \
    --revision c28df2a70bb16376ed7dc6a5233cffb41bb54a68 \
    --include 'serve/*' \
    --local-dir "$ROOT/model"
fi

(cd "$ROOT/model" && shasum -a 256 -c ../model.sha256)

printf '\nInstalled. Run ./start.sh, then ./make_thai_fixture.sh and ./verify_live.py\n'
