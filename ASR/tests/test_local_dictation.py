import json
import unittest
from unittest.mock import AsyncMock, patch

import local_dictation


class LocalDictationTests(unittest.IsolatedAsyncioTestCase):
    async def send_events(self, path, events, pcm=b""):
        async def upstream(scope, receive, send):
            if pcm:
                self.assertEqual(await receive(), {"type": "websocket.receive", "bytes": pcm})
            for event in events:
                await send({"type": "websocket.send", "text": json.dumps(event)})

        receive = AsyncMock(return_value={"type": "websocket.receive", "bytes": pcm})
        send = AsyncMock()
        with patch.object(local_dictation, "upstream_app", upstream):
            await local_dictation.app({"type": "websocket", "path": path}, receive, send)
        return [json.loads(entry.args[0]["text"]) for entry in send.await_args_list]

    async def test_only_live_display_text_changes(self):
        events = [
            {"type": "ready", "lang": "th-mix", "latency_ms": 560},
            {"type": "partial", "text": "แจ้งทีมทางไลน์โอเอ"},
            {"type": "final", "text": "แจ้งทีมทางไลน์โอเอ", "display_text": "แจ้งทีมทางไลน์โอเอ"},
            {"type": "done", "utterances": 1},
        ]
        self.assertEqual(await self.send_events("/v1/stream", events), events)
        sent = await self.send_events("/v1/live", events)
        self.assertEqual(sent[0], {**events[0], "pink_voices_score_protocol": 1})
        self.assertEqual(sent[1], events[1])
        self.assertEqual(sent[2]["text"], events[2]["text"])
        self.assertEqual(sent[2]["display_text"], "แจ้งทีมทาง LINE OA")
        self.assertEqual(sent[2]["pink_voices_score"]["decision"], "pass")
        self.assertEqual(sent[3], events[3])

    async def test_mixed_brand_formatting_preserves_raw_asr_text(self):
        raw = "นัดวันที่22พฤศจิกายน26เวลา14นาฬิกา30นาทีส่งพิ้งคัตส์เข้าแชทจีพีที"
        events = [{"type": "final", "text": raw, "display_text": raw}]
        final, = await self.send_events("/v1/live", events)
        self.assertEqual(final["text"], raw)
        self.assertEqual(
            final["display_text"],
            "นัดวันที่ 22 พฤศจิกายน 26 เวลา 14:30 น.ส่ง Pink Cuts เข้า ChatGPT",
        )

    async def test_bilingual_alias_changes_only_display_text(self):
        raw = "ส่งผ่านLINE โอ๊เอ้ให้พิงวอยใช้โอเพ่นไทย"
        final, = await self.send_events("/v1/live", [{"type": "final", "text": raw, "display_text": raw}])
        self.assertEqual(final["text"], raw)
        self.assertEqual(final["display_text"], "ส่งผ่าน LINE OA ให้ Pink voices ใช้ OpenThai")
        self.assertEqual(final["pink_voices_score"]["decision"], "pass")
        self.assertFalse(final["pink_voices_score"]["recognizer_confidence_available"])

    async def test_unknown_mixed_term_is_packaged_for_local_review_only(self):
        raw = "ส่ง NovaLab ให้ทีม"
        final, = await self.send_events("/v1/live", [{"type": "final", "text": raw, "display_text": raw}])
        score = final["pink_voices_score"]
        self.assertEqual(score["decision"], "review")
        self.assertEqual(score["review_request"]["route"], "local_only")
        self.assertEqual(score["review_request"]["policy"], "review_only_no_automatic_rewrite")

    async def test_only_material_partial_conflict_is_routed_to_review(self):
        partial = {"type": "partial", "utterance": 4, "text": "วันนี้ใช้ Pink Cats"}
        final = {"type": "final", "utterance": 4, "text": "วันนี้ใช้ Pink Cuts", "display_text": "วันนี้ใช้ Pink Cuts"}
        _, sent = await self.send_events("/v1/live", [partial, final])
        self.assertEqual(sent["pink_voices_score"]["decision"], "review")
        self.assertEqual(sent["pink_voices_score"]["review_request"]["route"], "local_only")

    async def test_score_failure_keeps_the_final_text(self):
        event = {"type": "final", "text": "วันนี้ทดสอบ", "display_text": "วันนี้ทดสอบ"}
        with patch.object(local_dictation, "score_final", side_effect=RuntimeError("test")):
            final, = await self.send_events("/v1/live", [event])
        self.assertEqual(final["display_text"], "วันนี้ทดสอบ")
        self.assertEqual(final["pink_voices_score"]["decision"], "unavailable")

    async def test_calendar_retry_uses_captured_utterance(self):
        primary = "เจอกันวันที่ 8 เมษายน 347 นาฬิกา 15 นาทีครับ"
        event = {"type": "final", "text": primary, "display_text": primary, "start": 0.02, "end": 0.06}
        alternate = AsyncMock(return_value={"display_text": "วันที่8เมษายน2570เวลา17นาฬิกา15นาที"})
        with patch.object(local_dictation, "run_in_threadpool", alternate):
            final, = await self.send_events("/v1/live", [event], pcm=b"\0" * 3200)
        self.assertEqual(final["text"], primary)
        self.assertEqual(final["display_text"], "เจอกันวันที่ 8 เมษายน 2570 เวลา 17:15 น. ครับ")
        self.assertEqual(len(alternate.await_args.args[1]), 640)

    async def test_matching_partial_avoids_an_extra_decode(self):
        primary = "เจอกันวันที่ 8 เมษายน 347 นาฬิกา 15 นาทีครับ"
        event = {"type": "final", "utterance": 2, "text": primary,
                 "display_text": primary, "start": 0.02, "end": 0.06}
        partial = {"type": "partial", "utterance": 2, "text": "วันที่8เมษายน27เวลา17นาฬิกา15นาที"}
        with patch.object(local_dictation, "run_in_threadpool", AsyncMock()) as retry:
            sent_partial, final = await self.send_events("/v1/live", [partial, event], pcm=b"\0" * 3200)
        self.assertEqual(sent_partial, partial)
        self.assertEqual(final["display_text"], "เจอกันวันที่ 8 เมษายน 27 เวลา 17:15 น. ครับ")
        retry.assert_not_awaited()
