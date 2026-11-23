import json
import tempfile
import unittest
from pathlib import Path

from final_scoring import score_final


class FinalScoringTests(unittest.TestCase):
    def test_plain_final_passes_without_claiming_decoder_confidence(self):
        result = score_final("วันนี้ทดสอบไมค์ครับ", "วันนี้ทดสอบไมค์ครับ")
        self.assertEqual(result["decision"], "pass")
        self.assertEqual(result["confidence_kind"], "rule_based_quality_not_model_probability")
        self.assertFalse(result["recognizer_confidence_available"])
        self.assertIsNone(result["review_request"])

    def test_reviewed_local_brand_formatting_stays_on_fast_path(self):
        result = score_final("ส่งพิ้งคัตส์", "ส่ง Pink Cuts")
        self.assertEqual(result["decision"], "pass")
        self.assertIn("reviewed_local_vocabulary_formatting", result["reasons"])

    def test_unknown_mixed_name_is_routed_with_local_term_hint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plaud-vocabulary.json"
            path.write_text(
                json.dumps({
                    "schema": "pinkvoices.plaud-vocabulary",
                    "version": 1,
                    "terms": [{"term": "Molto", "document_count": 2, "occurrence_count": 3}],
                }),
                encoding="utf-8",
            )
            result = score_final("ส่ง Motto ให้ทีม", "ส่ง Motto ให้ทีม", plaud_terms_path=path)
        self.assertEqual(result["decision"], "review")
        span, = result["uncertain_spans"]
        self.assertEqual(span["category"], "brand")
        self.assertEqual(span["candidates"], ["Molto"])
        self.assertEqual(result["review_request"]["policy"], "review_only_no_automatic_rewrite")

    def test_plaud_term_can_supply_a_bounded_typo_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plaud-vocabulary.json"
            path.write_text(
                json.dumps({
                    "schema": "pinkvoices.plaud-vocabulary",
                    "version": 1,
                    "terms": [{"term": "Notion", "document_count": 2, "occurrence_count": 2}],
                }),
                encoding="utf-8",
            )
            result = score_final("เปิด Notionn", "เปิด Notionn", plaud_terms_path=path)
        self.assertEqual(result["uncertain_spans"][0]["candidates"], ["Notion"])

    def test_single_edit_brand_typos_are_reviewed_with_canonical_candidates(self):
        result = score_final("ส่ง CapCutt ให้ทีม", "ส่ง CapCutt ให้ทีม")
        self.assertEqual(result["decision"], "review")
        self.assertEqual(result["uncertain_spans"][0]["category"], "brand")
        self.assertEqual(result["uncertain_spans"][0]["candidates"], ["CapCut"])

    def test_protected_url_is_not_scored_as_a_brand_or_typo(self):
        result = score_final("เปิด https://example.test/CapCutt", "เปิด https://example.test/CapCutt")
        self.assertEqual(result["decision"], "pass")

    def test_material_partial_conflict_is_reviewed_but_a_streaming_prefix_is_not(self):
        stable = score_final("วันนี้ใช้ OpenThai", "วันนี้ใช้ OpenThai", partial_texts=("วันนี้ใช้",))
        conflict = score_final("วันนี้ใช้ Pink Cuts", "วันนี้ใช้ Pink Cuts", partial_texts=("วันนี้ใช้ Pink Cats",))
        self.assertEqual(stable["decision"], "pass")
        self.assertEqual(conflict["decision"], "review")
        self.assertIn("partial_final_material_disagreement", [span["reason"] for span in conflict["uncertain_spans"]])
        self.assertNotEqual(conflict["uncertain_spans"][-1]["text"], "วันนี้ใช้ Pink Cuts")

    def test_suspicious_calendar_is_reviewed_without_rewriting(self):
        raw = "นัดวันที่7มกราคม 174 นาฬิกา 15 นาที"
        result = score_final(raw, raw)
        self.assertEqual(result["decision"], "review")
        self.assertEqual(result["uncertain_spans"][0]["category"], "date_time")

    def test_plain_english_phrase_does_not_create_brand_review(self):
        result = score_final("please send the update", "please send the update")
        self.assertEqual(result["decision"], "pass")

    def test_generic_lowercase_app_does_not_fuzz_to_an_acronym(self):
        result = score_final(
            "เปิด app ทิ้งวอยเพื่อจดงานให้ทีมข่าว",
            "เปิด app ทิ้งวอยเพื่อจดงานให้ทีมข่าว",
        )
        self.assertEqual(result["decision"], "review")
        self.assertEqual(result["uncertain_spans"], [{
            "text": "ทิ้งวอย",
            "category": "brand",
            "reason": "thai_name_after_explicit_brand_cue",
            "candidates": [],
        }])
        self.assertEqual(result["review_request"]["route"], "local_only")
        self.assertEqual(score_final("เปิด app เพื่อจดงาน", "เปิด app เพื่อจดงาน")["decision"], "pass")

    def test_line_textile_homonym_is_local_review_without_rewrite(self):
        textile = score_final("เลือก LINE บนผ้า", "เลือก LINE บนผ้า")
        chat = score_final("ส่งรูปเสื้อใน LINE", "ส่งรูปเสื้อใน LINE")
        self.assertEqual(textile["decision"], "review")
        self.assertEqual(textile["uncertain_spans"][0]["reason"], "line_textile_homonym")
        self.assertEqual(textile["uncertain_spans"][0]["candidates"], ["ลาย"])
        self.assertEqual(textile["review_request"]["route"], "local_only")
        self.assertEqual(chat["decision"], "pass")
