#!/usr/bin/env python3
"""Verify iApp's documented /v1/live protocol with a local Thai WAV fixture."""
import asyncio
import json
import sys
import time
import urllib.error
import urllib.request
import wave

import websockets

HOST = "127.0.0.1"
PORT = 18081
URL = f"ws://{HOST}:{PORT}/v1/live"
CHUNK_BYTES = 3200  # 100 ms of signed 16-bit, 16 kHz, mono PCM.


def health_probe():
    try:
        with urllib.request.urlopen(f"http://{HOST}:{PORT}/v1/health", timeout=3) as response:
            return {"available": True, "status": response.status, "body": response.read().decode("utf-8")}
    except urllib.error.HTTPError as error:
        return {"available": False, "status": error.code, "detail": "endpoint not provided by server"}
    except OSError as error:
        return {"available": False, "detail": str(error)}


async def verify(wav_path: str):
    started = time.monotonic()
    with wave.open(wav_path, "rb") as audio:
        if audio.getnchannels() != 1:
            raise ValueError("fixture must be mono")
        if audio.getframerate() != 16000:
            raise ValueError("fixture must be 16 kHz")
        if audio.getsampwidth() != 2:
            raise ValueError("fixture must be 16-bit PCM")
        pcm = audio.readframes(audio.getnframes())

    report = {"health": health_probe(), "wav_bytes": len(pcm), "events": []}
    async with websockets.connect(URL, max_size=2**20) as ws:
        await ws.send(json.dumps({"mode": "standard", "lang": "th-mix", "latency_ms": 560}))
        ready = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
        report["ready"] = ready

        for offset in range(0, len(pcm), CHUNK_BYTES):
            await ws.send(pcm[offset:offset + CHUNK_BYTES])
        await ws.send("end")

        while True:
            event = json.loads(await asyncio.wait_for(ws.recv(), timeout=45))
            report["events"].append(event)
            if event.get("type") == "done":
                break

    report["elapsed_s"] = round(time.monotonic() - started, 3)
    types = [event.get("type") for event in report["events"]]
    report["event_types"] = types
    report["final_count"] = types.count("final")
    report["partial_count"] = types.count("partial")
    if report["ready"].get("type") != "ready":
        raise RuntimeError(f"expected ready, got {report['ready']}")
    if types[-1:] != ["done"]:
        raise RuntimeError(f"stream did not terminate in done: {types}")
    final_texts = [event.get("display_text", "").strip() for event in report["events"] if event.get("type") == "final"]
    if not any(final_texts):
        raise RuntimeError(f"expected nonempty final.display_text, got {report['events']}")
    report["final_texts"] = final_texts
    return report


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_live.py fixtures/thai-local.wav")
    print(json.dumps(asyncio.run(verify(sys.argv[1])), ensure_ascii=False, indent=2))
