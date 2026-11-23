#!/usr/bin/env bash
# Read-only environment check for a Pink voices handoff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Pink voices.app"
HEALTH_URL="http://127.0.0.1:18081/v1/health"
failures=0
warnings=0

ok() { printf 'OK      %s\n' "$*"; }
warn() { printf 'WARNING %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'MISSING %s\n' "$*"; failures=$((failures + 1)); }

find_app() {
    local candidate
    for candidate in "$ROOT/$APP_NAME" "$ROOT/App/build/$APP_NAME"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

printf 'Pink voices doctor (read-only)\n'
printf 'Package: %s\n\n' "$ROOT"

if [[ "$(uname -s)" == "Darwin" ]]; then
    ok "macOS $(sw_vers -productVersion 2>/dev/null || printf 'version unavailable')"
else
    fail "Pink voices requires macOS; this check will not alter this computer."
fi

if APP_PATH="$(find_app)"; then
    if [[ -x "$APP_PATH/Contents/MacOS/ThaiDictation" ]]; then
        ok "prebuilt app found: ${APP_PATH#$ROOT/}"
    else
        fail "app bundle is incomplete: ${APP_PATH#$ROOT/}"
    fi

    if command -v codesign >/dev/null 2>&1; then
        if codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
            ok "prebuilt app signature verifies"
        else
            fail "prebuilt app signature did not verify; do not rebuild or replace it automatically."
        fi
    else
        warn "codesign is unavailable; cannot check the prebuilt signature."
    fi
else
    fail "prebuilt app not found. Expected $APP_NAME or App/build/$APP_NAME."
fi

if [[ -f "$ROOT/ASR/.venv/bin/python" && -x "$ROOT/ASR/.venv/bin/python" ]]; then
    ok "ASR virtual environment is present"
else
    warn "ASR virtual environment is not present. Source setup is a separate, download-capable step."
fi

if [[ -f "$ROOT/ASR/model/openthai2.0-asr-streaming_raw.nemo" ]]; then
    ok "OpenThai model checkpoint is present"
else
    warn "OpenThai model checkpoint is not present. The local service cannot start yet."
fi

if [[ -r "$ROOT/ASR/local_dictation.py" && -r "$ROOT/ASR/model/serve/app.py" && -r "$ROOT/ASR/model/serve/chinda_asr.py" && -r "$ROOT/ASR/model/serve/chinda_realtime.py" && -r "$ROOT/ASR/model/serve/chinda_diar.py" ]]; then
    ok "ASR adapter and pinned serve modules are present"
else
    warn "the local ASR source setup still needs model/serve files for independent startup"
fi

if command -v uv >/dev/null 2>&1; then
    ok "uv available: $(uv --version 2>/dev/null || printf 'version unavailable')"
else
    warn "uv is absent. It is needed only to prepare ASR source, not to open an already-running service."
fi

if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    ok "ffmpeg and ffprobe available (audio-format fallback)"
else
    warn "ffmpeg/ffprobe absent. WAV/AIFF use remains possible; MP3/M4A/OGG fallback and fixture conversion need them."
fi

if command -v curl >/dev/null 2>&1; then
    if health="$(curl -fsS --noproxy 127.0.0.1 --max-time 2 "$HEALTH_URL" 2>/dev/null)"; then
        if grep -Eq '"model"[[:space:]]*:[[:space:]]*"openthai2\.0-asr-streaming-v1\.0"' <<< "$health" && \
           grep -Eq '"loaded"[[:space:]]*:[[:space:]]*true' <<< "$health"; then
            ok "local OpenThai service is ready"
        else
            warn "a local service answered, but it is not the expected loaded OpenThai model."
        fi
    else
        warn "local OpenThai service is not currently ready at $HEALTH_URL"
    fi
else
    warn "curl is unavailable; cannot inspect the local ASR health endpoint."
fi

printf '\nResult: %d missing, %d warning(s). This doctor made no changes.\n' "$failures" "$warnings"
if (( failures > 0 )); then
    exit 1
fi
