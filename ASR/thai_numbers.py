"""Safe display formatting for explicit Thai numbers."""

from __future__ import annotations

from dataclasses import dataclass
import re

from protected_text import transform_unprotected

_THAI_DIGITS = str.maketrans("๐๑๒๓๔๕๖๗๘๙", "0123456789")
_UNITS = {"ศูนย์": 0, "หนึ่ง": 1, "เอ็ด": 1, "สอง": 2, "ยี่": 2, "สาม": 3, "สี่": 4, "ห้า": 5, "หก": 6, "เจ็ด": 7, "แปด": 8, "เก้า": 9}
_SCALES = {"สิบ": 10, "ร้อย": 100, "พัน": 1_000, "หมื่น": 10_000, "แสน": 100_000}
_NUMBER_CHARS = "ศูนย์หนึ่งเอ็ดสองยี่สามสี่ห้าหกเจ็ดแปดเก้าสิบร้อยพันหมื่นแสนล้าน"
_NUMBER = rf"[0-9๐-๙{_NUMBER_CHARS}]+"
_MONTHS = "มกราคม|กุมภาพันธ์|มีนาคม|เมษายน|พฤษภาคม|มิถุนายน|กรกฎาคม|สิงหาคม|กันยายน|ตุลาคม|พฤศจิกายน|ธันวาคม"
_CALENDAR = re.compile(rf"วันที่\s*(?P<day>{_NUMBER})\s*(?P<month>{_MONTHS})\s*(?P<year>{_NUMBER})\s*เวลา\s*(?P<hour>{_NUMBER})\s*นาฬิกา\s*(?P<minute>{_NUMBER})\s*นาที")


@dataclass(frozen=True)
class CalendarTime:
    span: tuple[int, int]
    day: int
    month: str
    year: int
    hour: int
    minute: int

    @property
    def display(self) -> str:
        return f"วันที่ {self.day} {self.month} {self.year} เวลา {self.hour:02d}:{self.minute:02d} น."


def _thai_integer(value: str) -> int | None:
    value = value.strip().translate(_THAI_DIGITS)
    if not value:
        return None
    if value.isdecimal():
        return int(value)
    if any(letter not in _NUMBER_CHARS for letter in value):
        return None
    total = section = current = 0
    words = sorted((*_UNITS, *_SCALES, "ล้าน"), key=len, reverse=True)
    index = 0
    while index < len(value):
        word = next((item for item in words if value.startswith(item, index)), None)
        if word is None:
            return None
        index += len(word)
        if word in _UNITS:
            if current:
                return None
            current = _UNITS[word]
        elif word == "ล้าน":
            total = (total + section + current) * 1_000_000
            section = current = 0
        else:
            section += (current or 1) * _SCALES[word]
            current = 0
    return total + section + current


def find_explicit_calendar_times(text: str) -> list[CalendarTime]:
    """Return complete, valid date/time phrases. Never expands a two-digit year."""
    result = []
    for match in _CALENDAR.finditer(text):
        day, year, hour, minute = (_thai_integer(match.group(name)) for name in ("day", "year", "hour", "minute"))
        if None not in (day, year, hour, minute) and 1 <= day <= 31 and 0 <= hour <= 23 and 0 <= minute <= 59:
            result.append(CalendarTime(match.span(), day, match.group("month"), year, hour, minute))
    return result


def _calendar_replacement(match: re.Match[str]) -> str:
    found = find_explicit_calendar_times(match.group(0))
    return found[0].display if found else match.group(0)


def _half_hour(match: re.Match[str]) -> str:
    if match.group("prefix"):
        return match.group(0)
    hour = _thai_integer(match.group("hour"))
    return match.group(0) if hour is None or not 7 <= hour <= 12 else f"{hour:02d}:30 น."


def _numeric_percentage(match: re.Match[str]) -> str:
    number = match.group("number").translate(_THAI_DIGITS)
    return f"{number}%"


def _money(match: re.Match[str]) -> str:
    digits = match.group("digits").translate(_THAI_DIGITS)
    return f"{int(digits):,}"


def normalize_numbers(text: str) -> str:
    """Format only explicit calendar, half-hour, money, and percentage values."""
    def format_segment(value: str) -> str:
        value = _CALENDAR.sub(_calendar_replacement, value)
        value = re.sub(r"(?P<prefix>บ่าย\s*|ตี\s*)?(?P<hour>[0-9๐-๙]{1,2})\s*โมง\s*ครึ่ง", _half_hour, value)
        value = re.sub(r"(?<![\d๐-๙,])(?P<digits>[0-9๐-๙]{4,})(?=\s*บาท(?=\s|$|ครับ|ค่ะ))", _money, value)
        return re.sub(r"(?P<number>[0-9๐-๙]+(?:\.[0-9๐-๙]+)?)\s*(?:เปอร์เซ็นต์|percent)(?=$|\s|ครับ|ค่ะ)", _numeric_percentage, value, flags=re.I)

    return transform_unprotected(text, format_segment)
