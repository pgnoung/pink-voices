# Observed local validation

Run on 2026-11-22, Apple Silicon CPU, using the official NeMo server and the
checkpoint pinned in [MODEL_SOURCE.md](MODEL_SOURCE.md).

| Check | Observed result |
| --- | --- |
| Bind | `127.0.0.1:18081` only |
| Warm load | 42.2 s reported by `chinda_asr` |
| Health | `GET /v1/health` returned `200`, `loaded: true`, `device: cpu`, `num_threads: 1`, `replicas: 1` |
| Fixture | local macOS Kanya voice, 5.349 s, mono 16 kHz signed PCM, 171,170 bytes |
| Open | `ready` with `lang: th-mix`, `latency_ms: 560`, `policy: shortclip`, `end_silence_ms: 700` |
| Streaming | 8 `partial`, 1 non-empty `final.display_text`, 1 terminal `done` after exactly one `end` |
| Final text | `สวัสดีครับวันนี้เราทดสอบการเขียนตามคำบอกภาษาไทย` |
| End payload | `audio_seconds: 5.349`, `utterances: 1` |
| Fixture wall time | 4.286 s first run; 5.015 s repeat |
| Server RSS after repeat | 2,600,368 KiB |

The app adapter should await `ready` before sending PCM, render `partial.text`
only as temporary UI, append `final.display_text`, then finalize only after
`done`. The tested audio used no microphone permission and did not leave the
machine.
