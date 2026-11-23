import unittest

from dictation_text import malformed_calendar, normalize_terms, recover_calendar


class DictationTextTests(unittest.TestCase):
    def test_aliases_inside_new_sentences(self):
        self.assertEqual(
            normalize_terms("แชร์ตัวอย่างพิงก์คัตส์ให้ทีม4มุมเมืองทางไลน์โอเอ"),
            "แชร์ตัวอย่าง Pink Cuts ให้ทีมสี่มุมเมืองทาง LINE OA",
        )
        self.assertEqual(
            normalize_terms("ทดสอบโอเพ่นไทยด้วยโหมดทีเอชมิกซ์ก่อน"),
            "ทดสอบ OpenThai ด้วยโหมด th-mix ก่อน",
        )
        self.assertEqual(
            normalize_terms("อ่านฝ่ายรีเวิร์คแล้วรันพีเอ็มเทสต์อีกครั้ง"),
            "อ่านไฟล์ README แล้วรัน npm test อีกครั้ง",
        )

    def test_pink_cuts_vocabulary_accepts_mixed_thai_and_english(self):
        self.assertEqual(
            normalize_terms(
                "ส่งคลิปจากพิ้งคัตส์เข้าแชทจีพีทีแล้วเปิดโคเดกซ์กับโคลดผ่านเอ็มซีพี"
            ),
            "ส่งคลิปจาก Pink Cuts เข้า ChatGPT แล้วเปิด Codex กับ Claude ผ่าน MCP",
        )
        self.assertEqual(
            normalize_terms(
                "เซฟเทมเพลตในแคนวาแล้วลงเฟซบุ๊กติ๊กต็อกยูทูบและอินสตาแกรม"
            ),
            "เซฟเทมเพลตใน Canva แล้วลง Facebook TikTok YouTube และ Instagram",
        )
        self.assertEqual(
            normalize_terms("เอาเสียงอีเลฟเว่นแลบส์จากกูเกิลไดรฟ์ไปใส่แคปคัต"),
            "เอาเสียง ElevenLabs จาก Google Drive ไปใส่ CapCut",
        )
        self.assertEqual(
            normalize_terms("พิ้งวอยซ์ใช้โอเพ่นไทยและกูเกิลชีต"),
            "Pink voices ใช้ OpenThai และ Google Sheets",
        )

    def test_known_composite_aliases_accept_bilingual_and_clipped_forms(self):
        self.assertEqual(normalize_terms("ส่งสรุปผ่านLINE โอ๊เอ้ครับ"), "ส่งสรุปผ่าน LINE OA ครับ")
        self.assertEqual(normalize_terms("พิงวอยใช้โอเพ่นไทยนะ"), "Pink voices ใช้ OpenThai นะ")
        self.assertEqual(normalize_terms("พิงก์วอยซ์พูดผ่านไลน์โอเอ"), "Pink voices พูดผ่าน LINE OA")

    def test_historical_brief_anchor_recovers_only_the_known_pink_cuts_near_match(self):
        self.assertEqual(
            normalize_terms("ทรงบะหรี่พิ้งคักให้ทีม4มุมเมืองในลายโอ้เอ๊ครับ"),
            "ส่งบรีฟ Pink Cuts ให้ทีมสี่มุมเมืองใน LINE OA ครับ",
        )
        self.assertEqual(normalize_terms("จะพูดคำว่าพิ้งคักให้ทีมฟัง"), "จะพูดคำว่าพิ้งคักให้ทีมฟัง")

    def test_typed_brand_casing_and_spacing_are_normalized(self):
        self.assertEqual(
            normalize_terms("ส่ง pink-cuts ผ่าน chat g p t และ google sheets"),
            "ส่ง Pink Cuts ผ่าน ChatGPT และ Google Sheets",
        )
        self.assertEqual(
            normalize_terms("เปิดline_oaในpink voices2"),
            "เปิดline_oaในpink voices2",
        )

    def test_ambiguous_words_and_unrelated_commands_are_preserved(self):
        for text in (
            "เขาวิจารณ์ฝ่ายรีเวิร์คในบริษัท",
            "เพื่อนถ่ายแบบให้ลูกค้า",
            "ใช้ npm install กับโค้ดเดิม",
            "อย่าเพิ่งส่งรูปทั้ง4มุมเมือง",
            "รีดมีน้ำตา",
            "please read me a poem",
            "คลอดลูกที่โรงพยาบาล",
            "คำว่า canvastool และ tiktokker ไม่ใช่ชื่อแบรนด์เดี่ยว",
            "โคลดินอยู่ในสวน แคนว่าอะไร พิงคับครับ",
            "ซูมดูผลลัพธ์ในวิดีโอ",
            "ซูมห้องให้หน่อย",
            "README2 และ Pink voices2",
            "พิงวอยากพัก ลายเส้นสูง และ LINE_OA",
        ):
            with self.subTest(text=text):
                self.assertEqual(normalize_terms(text), text)

    def test_edit_is_idempotent(self):
        text = normalize_terms("ช่วยทรงบะหรี่พิ้งคัตส์ทางลายโอ้เอ๊ครับ")
        self.assertEqual(text, "ช่วยส่งบรีฟ Pink Cuts ทาง LINE OA ครับ")
        self.assertEqual(normalize_terms(text), text)

    def test_full_mixed_brand_sentence_is_idempotent(self):
        text = normalize_terms(
            "วันจันทร์ส่งพิ้งคัตส์เข้าแชทจีพีทีจากกูเกิลชีตแล้วตัดในแคปคัต"
        )
        self.assertEqual(
            text,
            "วันจันทร์ส่ง Pink Cuts เข้า ChatGPT จาก Google Sheets แล้วตัดใน CapCut",
        )
        self.assertEqual(normalize_terms(text), text)

    def test_urls_and_email_are_preserved(self):
        text = "อ่าน https://chatgpt.com/pink-cuts?tool=capcut ส่งให้ pink.cuts@example.com แล้วเปิดแชทจีพีที"
        self.assertEqual(
            normalize_terms(text),
            "อ่าน https://chatgpt.com/pink-cuts?tool=capcut ส่งให้ pink.cuts@example.com แล้วเปิด ChatGPT",
        )

    def test_paths_files_and_identifier_shaped_code_are_preserved(self):
        text = "แก้ /Users/me/Pink-Cuts/README.md แล้วรัน pink_cuts.py ค่า 1250บาท"
        self.assertEqual(normalize_terms(text), text)

    def test_contextual_canva_and_zoom(self):
        self.assertEqual(normalize_terms("เปิดแคนวาแล้วเข้า Zoom ประชุม"), "เปิด Canva แล้วเข้า Zoom ประชุม")
        self.assertEqual(normalize_terms("ซูมประชุมผ่านไลน์โอเอ"), "Zoom ประชุมผ่าน LINE OA")

    def test_versions_are_not_split_from_known_terms(self):
        self.assertEqual(normalize_terms("เปิด README2 กับ Pink voices2"), "เปิด README2 กับ Pink voices2")

    def test_calendar_uses_matching_audio_candidate_and_preserves_short_year(self):
        text = "นัดส่งงานวันที่7มกราคม 174 นาฬิกา 15 นาทีครับ"
        malformed = malformed_calendar(text)
        self.assertIsNotNone(malformed)
        self.assertEqual(
            recover_calendar(text, malformed, "ส่งงานวันที่7มกราคม27เวลา17นาฬิกา15นาที"),
            "นัดส่งงานวันที่ 7 มกราคม 27 เวลา 17:15 น. ครับ",
        )
        self.assertEqual(
            recover_calendar(text, malformed, "ส่งงานวันที่8มกราคม27เวลา17นาฬิกา15นาที"),
            text,
        )
        self.assertEqual(
            recover_calendar(text, malformed, "ส่งงานวันที่7มกราคม27เวลา17นาฬิกา50นาที"),
            text,
        )
        self.assertIsNone(malformed_calendar("วันที่7มกราคม เวลา17นาฬิกา15นาที"))
