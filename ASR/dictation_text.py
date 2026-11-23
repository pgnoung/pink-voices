"""Local, context-limited spelling for vocabulary used in dictation.

The formatter is deliberately a small display-only correction layer.  It never
changes ``text`` from the recogniser, does not call a network service, and
leaves addresses, paths, files, and code-shaped text byte-for-byte intact.
"""

import re

from protected_text import transform_unprotected
from thai_numbers import find_explicit_calendar_times


_ALIASES = tuple((re.compile(pattern, re.IGNORECASE), replacement) for pattern, replacement in (
    # Product names present in the Pink Cuts source and its reviewed name prompts.
    (r"(?<![A-Za-z0-9_])pink[ \t_-]*cuts?(?![A-Za-z0-9_])|(?:พิง|พิ้ง)(?:ก์|ค์)?[ \t]*ค(?:ัต(?:ส์|ส)?|ัท(?:ส์|ส)?|ัด)", "Pink Cuts"),
    (r"(?<![A-Za-z0-9_])pink[ \t_-]*voices?(?![A-Za-z0-9_])|(?:พิง|พิ้ง)(?:ก์|ค์)?[ \t]*วอย(?:ซ์|ซ|(?=[ \t]*(?:ใช้|ทำ|เปิด|พูด|บอก|ลอง|ครับ|ค่ะ|คะ|นะ|สิ|แล้ว|อยู่|ผ่าน|กับ|ใน|เป็น|ได้|ให้|หน่อย|$)))", "Pink voices"),
    (r"(?<![A-Za-z0-9_])line[ \t_-]*o[ \t_-]*a(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])line[ \t_-]*โอ[้๊]?[ \t]*เอ[๊้]?|(?:ไล|ลาย)(?:น์?)?[ \t]*โอ[้๊]?[ \t]*เอ[๊้]?", "LINE OA"),
    (r"(?<![A-Za-z0-9_])open[ \t_-]*thai(?![A-Za-z0-9_])", "OpenThai"),
    (r"(?<![A-Za-z0-9_])th[ \t_-]*mix(?![A-Za-z0-9_])|ที[ \t]*เอช[ \t]*มิก(?:ซ์|ซ|ส์)?", "th-mix"),
    (r"(?<![A-Za-z0-9_])chat[ \t_-]*g[ \t_-]*p[ \t_-]*t(?![A-Za-z0-9_])|แชท[ \t]*(?:จี|จ)[ \t]*(?:พี|ปี)[ \t]*(?:ที|ตี)", "ChatGPT"),
    (r"(?<![A-Za-z0-9_])claude(?![A-Za-z0-9_])|โคลด(?=ผ่าน|กับ|และ|ครับ|ค่ะ|คะ|ที่|ใน|เป็น|[ \t]|$)", "Claude"),
    (r"(?<![A-Za-z0-9_])codex(?![A-Za-z0-9_])|โค(?:เด็กซ์|เดกซ์)", "Codex"),
    (r"(?<![A-Za-z0-9_])cap[ \t_-]*cut(?![A-Za-z0-9_])|แค[็๊]?ป[ \t]*(?:คัต|คัท)", "CapCut"),
    (r"(?<![A-Za-z0-9_])canva(?![A-Za-z0-9_])", "Canva"),
    (r"(?<![A-Za-z0-9_])gemini(?![A-Za-z0-9_])|เจมินี", "Gemini"),
    (r"(?<![A-Za-z0-9_])google[ \t_-]*drive(?![A-Za-z0-9_])|กูเกิล[ \t]*(?:ไดรฟ์|ไดฟ์)", "Google Drive"),
    (r"(?<![A-Za-z0-9_])google[ \t_-]*sheets?(?![A-Za-z0-9_])|กูเกิล[ \t]*ชีต(?:ส์)?", "Google Sheets"),
    (r"(?<![A-Za-z0-9_])eleven[ \t_-]*labs?(?![A-Za-z0-9_])|อีเลฟเว่น[ \t]*แลบ(?:ส์|ส)?", "ElevenLabs"),
    (r"(?<![A-Za-z0-9_])facebook(?![A-Za-z0-9_])|เฟ[ซส](?:บุ๊ก|บุค)", "Facebook"),
    (r"(?<![A-Za-z0-9_])tiktok(?![A-Za-z0-9_])|ติ๊ก[ \t]*ต็อก", "TikTok"),
    (r"(?<![A-Za-z0-9_])youtube(?![A-Za-z0-9_])|ยู[ \t]*ทูบ", "YouTube"),
    (r"(?<![A-Za-z0-9_])instagram(?![A-Za-z0-9_])|อินสตาแกรม", "Instagram"),
    (r"(?<![A-Za-z0-9_])zoom(?![A-Za-z0-9_])|ซูม(?=[ \t]*(?:ประชุม|มีตติ้ง|meeting|คอล|call|ลิงก์))", "Zoom"),
    (r"(?<![A-Za-z0-9_])m[ \t_-]*c[ \t_-]*p(?![A-Za-z0-9_])|เอ็ม[ \t]*ซี[ \t]*พี", "MCP"),
    (r"(?<![A-Za-z0-9_])readme(?![A-Za-z0-9_])", "README"),
    (r"(?<![A-Za-z0-9_])npm[ \t_-]+test(?![A-Za-z0-9_])|เอ็น[ \t]*พี[ \t]*เอ็ม[ \t]*เท[สซ](?:ต์)?", "npm test"),
    (r"(?P<context>ตลาด|ทีม)[ \t]*[4๔][ \t]*มุมเมือง", r"\g<context>สี่มุมเมือง"),
))

_BRIEF = re.compile(r"(^|[ \t]|ช่วย|รบกวน)(?:ทรง|ส่ง)[ \t]*บะ[ \t]*หรี่(?=[ \t]*Pink Cuts)")
_BRIEF_PINK_CUTS = re.compile(
    r"(?:ทรง|ส่ง)[ \t]*บะ[ \t]*หรี่[ \t]*(?:พิง|พิ้ง)(?:ก์|ค์)?[ \t]*ค(?:ัก|ับ)"
    r"(?=[ \t]*(?:ให้(?:ทีม)?|ทาง|ใน))"
)
_SPOKEN_README = re.compile(r"(ไฟล์(?:ที่ชื่อ)?)[ \t]*รี้?ด[ \t]*มี")
_SPOKEN_OPENTHAI = re.compile(
    r"(โมเดล|ใช้|ทดสอบ|แพ็กเกจ|[Aa][Ss][Rr])[ \t]*(?:โอ[ \t]*เพ[่]?น|โอ[ \t]*เป[ิี]น)[ \t]*ไทย"
)
_SPOKEN_CANVA = re.compile(r"(?P<context>แอป|เปิด|ใช้|ใน)[ \t]*แคนวา")
_FILE_WITH_COMMAND = re.compile(
    r"(?P<verb>เปิด|อ่าน|ดู|แก้)[ \t]*(?:ไฟล์|ฝ่าย)[ \t]*(?:รีเวิร์ค|รีวะ|README|read[ \t]+me)"
    r"(?=[ \t]*แล้ว[ \t]*รัน[ \t]*(?:พี(?:เอ็?)?ม[ \t]*เทส(?:ต์)?|npm test))"
)
_COMMAND_AFTER_README = re.compile(r"(README[ \t]*แล้ว[ \t]*รัน)[ \t]*พี(?:เอ็?)?ม[ \t]*เทส(?:ต์)?")
_GREETING = re.compile(r"^(สวัสดี(?:ครับ|ค่ะ|คะ))(?=[ก-๙])")
_CANONICAL_TERMS = (
    "Google Sheets", "Google Drive", "Pink voices", "Pink Cuts", "OpenThai",
    "ElevenLabs", "Instagram", "ChatGPT", "CapCut", "Facebook", "YouTube",
    "Gemini", "TikTok", "Canva", "Claude", "Codex", "LINE OA", "th-mix", "Zoom",
    "README", "npm test", "MCP",
)
_KNOWN_TERM = "(?:" + "|".join(re.escape(term) for term in _CANONICAL_TERMS) + ")"
_BEFORE_TERM = re.compile(rf"(?<=[ก-๙])(?={_KNOWN_TERM})")
_AFTER_TERM = re.compile(rf"(?<![A-Za-z0-9])({_KNOWN_TERM})(?=[ก-๙])")
_BETWEEN_TERMS = re.compile(rf"({_KNOWN_TERM})(?={_KNOWN_TERM})")
_MONTHS = (
    "มกราคม|กุมภาพันธ์|มีนาคม|เมษายน|พฤษภาคม|มิถุนายน|"
    "กรกฎาคม|สิงหาคม|กันยายน|ตุลาคม|พฤศจิกายน|ธันวาคม"
)
_DATE = rf"วันที่\s*(?P<day>\d{{1,2}})\s*(?P<month>{_MONTHS})"
_CLOCK = r"(?P<hour>\d{1,4})\s*นาฬิกา\s*(?P<minute>\d{1,2})\s*นาที"
_MALFORMED_CALENDAR = re.compile(rf"{_DATE}\s*(?:เวลา\s*)?{_CLOCK}")


def _normalize_text_segment(text: str) -> str:
    # A single historical brief phrase gives enough independent context to
    # distinguish this acoustic near-match from ordinary Thai "พิงคับ".
    text = _BRIEF_PINK_CUTS.sub("ส่งบรีฟ Pink Cuts", text)
    for pattern, replacement in _ALIASES:
        text = pattern.sub(replacement, text)
    # Weak homophones are usable only when nearby recognized words disambiguate them.
    text = _SPOKEN_README.sub(r"\g<1> README", text)
    text = _SPOKEN_OPENTHAI.sub(r"\g<1> OpenThai", text)
    text = _SPOKEN_CANVA.sub(r"\g<context> Canva", text)
    text = _BRIEF.sub(r"\g<1>ส่งบรีฟ", text)
    text = _FILE_WITH_COMMAND.sub(r"\g<verb>ไฟล์ README", text)
    text = _COMMAND_AFTER_README.sub(r"\g<1> npm test", text)
    text = _GREETING.sub(r"\g<1> ", text)
    text = _BEFORE_TERM.sub(" ", text)
    text = _BETWEEN_TERMS.sub(r"\g<1> ", text)
    return _AFTER_TERM.sub(r"\g<1> ", text)


def normalize_terms(text: str) -> str:
    """Correct explicit spoken/typed terms while preserving code and addresses."""
    return transform_unprotected(text, _normalize_text_segment)


def malformed_calendar(text: str) -> re.Match[str] | None:
    date = _MALFORMED_CALENDAR.search(text)
    if date and 1 <= int(date["day"]) <= 31 and int(date["hour"]) > 23 and int(date["minute"]) < 60:
        return date
    return None


def recover_calendar(text: str, malformed: re.Match[str], alternate: str) -> str:
    """Use a second audio decode only when the day, month and minute agree."""
    expected = (int(malformed["day"]), malformed["month"], int(malformed["minute"]))
    dates = [date for date in find_explicit_calendar_times(alternate)
             if (date.day, date.month, date.minute) == expected]
    if len(dates) != 1:
        return text
    suffix = text[malformed.end():]
    gap = " " if suffix and suffix[0].isalnum() else ""
    return text[:malformed.start()] + dates[0].display + gap + suffix
