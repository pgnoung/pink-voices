import unittest

from thai_numbers import find_explicit_calendar_times, normalize_numbers


class ThaiNumberTests(unittest.TestCase):
    def test_explicit_spoken_calendar_time(self):
        text = "วันที่ยี่สิบสองพฤศจิกายนสองพันยี่สิบหกเวลาสิบสี่นาฬิกาสามสิบนาที"
        self.assertEqual(normalize_numbers(text), "วันที่ 22 พฤศจิกายน 2026 เวลา 14:30 น.")

    def test_two_digit_year_is_preserved(self):
        text = "วันที่22พฤศจิกายน26เวลา14นาฬิกา30นาทีครับ"
        self.assertEqual(normalize_numbers(text), "วันที่ 22 พฤศจิกายน 26 เวลา 14:30 น.ครับ")

    def test_complete_calendar_gate(self):
        value = find_explicit_calendar_times("วันที่22พฤศจิกายน26เวลา14นาฬิกา30นาที")
        self.assertEqual(value[0].display, "วันที่ 22 พฤศจิกายน 26 เวลา 14:30 น.")

    def test_formats_half_hour_money_and_percentage(self):
        self.assertEqual(normalize_numbers("ประชุม 9 โมงครึ่ง งบ 1250 บาทครับ"), "ประชุม 09:30 น. งบ 1,250 บาทครับ")
        self.assertEqual(normalize_numbers("ยอดเพิ่มขึ้น ๑๒.๕ percent"), "ยอดเพิ่มขึ้น 12.5%")
        self.assertEqual(normalize_numbers("บ่ายสองโมงครึ่ง หกโมงครึ่ง 6 โมงครึ่ง"), "บ่ายสองโมงครึ่ง หกโมงครึ่ง 6 โมงครึ่ง")
        self.assertEqual(normalize_numbers("ยอดเพิ่ม 12.5 percentครับ"), "ยอดเพิ่ม 12.5%ครับ")

    def test_ambiguous_misrecognition_is_unchanged(self):
        raw = "นัดส่งงานวันที่22พฤศจิกายน 254 นาฬิกา 30 นาทีครับ"
        self.assertEqual(normalize_numbers(raw), raw)
        self.assertEqual(find_explicit_calendar_times(raw), [])

    def test_identifier_is_unchanged(self):
        self.assertEqual(normalize_numbers("รหัสงาน 12345 พร้อมแล้ว"), "รหัสงาน 12345 พร้อมแล้ว")
        self.assertEqual(normalize_numbers("รหัสไทย ๑๒๓๔๕ พร้อมแล้ว"), "รหัสไทย ๑๒๓๔๕ พร้อมแล้ว")
        self.assertEqual(normalize_numbers("ยอดสิบสองจุดศูนย์เปอร์เซ็นต์"), "ยอดสิบสองจุดศูนย์เปอร์เซ็นต์")

    def test_urls_paths_and_code_are_not_number_formatted(self):
        self.assertEqual(normalize_numbers("https://host/1250บาท"), "https://host/1250บาท")
        self.assertEqual(normalize_numbers("/tmp/1250บาท/report.txt"), "/tmp/1250บาท/report.txt")
        self.assertEqual(normalize_numbers("price_1250บาท"), "price_1250บาท")


if __name__ == "__main__":
    unittest.main()
