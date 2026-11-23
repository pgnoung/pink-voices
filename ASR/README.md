# OpenThai local ASR prototype

This folder runs the pinned public iApp NeMo backend locally at
`ws://127.0.0.1:18081/v1/live`; health is
`http://127.0.0.1:18081/v1/health`. The Swift app uses this endpoint through
a small adapter.

The local wrapper formats live `final.display_text` using context-limited Thai
and English terms and numeric grammar. On a calendar phrase with an invalid
hour, it checks the same utterance's streaming hypothesis first. It may then
re-decode a bounded span of audio in memory. A correction requires the candidate
to agree on the date's day, month, and minute. Short years are preserved as
spoken. The other WebSocket message fields and the HTTP API continue to use the
upstream contract.

For raw-ASR diagnostics, stop the running service and start it with
`THAI_DICTATION_RAW_ASR=1 ./start.sh`.

Run the local wrapper tests from this folder with
`PYTHONPATH="$PWD:$PWD/model/serve" .venv/bin/python -m unittest discover -s tests`.

## First run

```bash
cd ASR
./setup.sh
./start.sh
```

In another terminal:

```bash
cd ASR
./make_thai_fixture.sh
.venv/bin/python verify_live.py fixtures/thai-local.wav
```

`verify_live.py` uses the documented opening JSON (`standard`, `th-mix`,
560 ms), sends signed 16-bit mono 16 kHz PCM in 3,200-byte chunks, sends one
`end`, and requires `ready`, a non-empty `final.display_text`, then `done`.
It records all partial/final events and transcription text without requiring a
microphone.

The server is loopback-only. Model weights, virtual environment, fixture audio,
and logs are ignored by Git and remain in this folder.
