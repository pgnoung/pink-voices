"""Apply Thai Dictation display formatting to the pinned OpenThai live service."""

import asyncio
import json
import logging

from app import ASR, app as upstream_app
from chinda_asr import SAMPLE_RATE, pcm16_to_float32
from starlette.concurrency import run_in_threadpool

from dictation_text import malformed_calendar, normalize_terms, recover_calendar
from final_scoring import score_final
from thai_numbers import find_explicit_calendar_times, normalize_numbers


_PCM_BYTES_PER_SECOND = SAMPLE_RATE * 2
_PCM_LIMIT = 12 * _PCM_BYTES_PER_SECOND
_LOG = logging.getLogger(__name__)


async def app(scope, receive, send):
    if scope.get("type") != "websocket" or scope.get("path") != "/v1/live":
        await upstream_app(scope, receive, send)
        return

    audio = bytearray()
    retry_available = True
    calendar_partial = None
    partial_texts: dict[int, list[str]] = {}

    async def receive_audio():
        nonlocal retry_available
        message = await receive()
        pcm = message.get("bytes")
        if retry_available and pcm and len(pcm) % 2 == 0:
            if len(audio) + len(pcm) <= _PCM_LIMIT:
                audio.extend(pcm)
            else:
                audio.clear()
                retry_available = False
        return message

    async def send_display(message):
        nonlocal retry_available, calendar_partial
        if message["type"] == "websocket.send" and message.get("text"):
            event = json.loads(message["text"])
            if event.get("type") == "ready":
                # This confirms the wrapper that emits local review scores is active.
                event["pink_voices_score_protocol"] = 1
                message = {**message, "text": json.dumps(event, ensure_ascii=False)}
            utterance = event.get("utterance")
            if event.get("type") == "partial" and utterance is not None:
                partial = event.get("text", "")
                if partial:
                    history = partial_texts.setdefault(utterance, [])
                    if not history or history[-1] != partial:
                        history.append(partial)
                    del history[:-3]
                if "วันที่" in partial and "นาที" in partial and find_explicit_calendar_times(partial):
                    calendar_partial = (utterance, partial)
            if event.get("type") == "final" and event.get("display_text"):
                display = event["display_text"]
                formatted = display
                malformed = malformed_calendar(display)
                if malformed and calendar_partial and calendar_partial[0] == utterance:
                    formatted = recover_calendar(display, malformed, calendar_partial[1])
                    if formatted != display:
                        _LOG.info("Calendar recovered from streaming hypothesis")
                calendar_partial = None
                if (malformed and formatted == display and retry_available
                        and 0 <= event.get("start", -1) < event.get("end", -1)):
                    start = round(event["start"] * SAMPLE_RATE) * 2
                    end = round(event["end"] * SAMPLE_RATE) * 2
                    clip = bytes(audio[start:end])
                    if clip:
                        retry_available = False
                        audio.clear()
                        try:
                            async with asyncio.timeout(4):
                                alternate = await run_in_threadpool(
                                    ASR.transcribe, pcm16_to_float32(clip), "th-mix", 1120, "standard"
                                )
                            formatted = recover_calendar(display, malformed, alternate["display_text"])
                            if formatted != display:
                                _LOG.info("Calendar recovered from audio retry")
                        except Exception:
                            _LOG.warning("Calendar audio retry could not complete; kept primary text")
                formatted = normalize_numbers(normalize_terms(formatted))
                event["display_text"] = formatted
                try:
                    event["pink_voices_score"] = score_final(
                        event.get("text", ""),
                        formatted,
                        partial_texts=tuple(partial_texts.pop(utterance, [])) if utterance is not None else (),
                    )
                except Exception:
                    # Scoring is advisory. A scoring failure must never lose dictation.
                    _LOG.exception("Pink voices scoring failed")
                    event["pink_voices_score"] = {
                        "version": 1,
                        "decision": "unavailable",
                        "heuristic_score": None,
                        "confidence_kind": "unavailable",
                        "recognizer_confidence_available": False,
                        "reasons": ["scoring_unavailable"],
                        "uncertain_spans": [],
                        "review_request": None,
                    }
                message = {**message, "text": json.dumps(event, ensure_ascii=False)}
        await send(message)

    await upstream_app(scope, receive_audio, send_display)
