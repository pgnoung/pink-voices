"""Local, explainable review routing for completed OpenThai utterances.

OpenThai live events do not expose decoder token probabilities. Therefore
heuristic_score is a deterministic routing score, never a model confidence
probability. It keeps routine text local and packages only specific ambiguity
for a later JEV/Luna review.
"""

from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from dictation_text import _CANONICAL_TERMS, malformed_calendar
from plaud_vocabulary import TermEvidence, load_vocabulary
from protected_text import PROTECTED_SPAN


_PLAUD_TERMS_PATH = Path.home() / "Library" / "Application Support" / "Pink voices" / "plaud-vocabulary.json"
_LATIN_TOKEN = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9._-]{1,})(?![A-Za-z0-9_])")
_THAI_NEIGHBOR = re.compile(r"[ก-๙]")
_SUSPICIOUS_DATE_TIME = re.compile(r"(?:วันที่\s*\d{1,2}\s*[^\sก-๙]{0,3}\s*\d{3,}|\d{3,4}\s*นาฬิกา)")
_CLOCK = re.compile(r"(?:(?:เวลา\s*)?)(\d{1,2}):(\d{2})")
_URL_OR_MAIL = re.compile(r"(?:https?://|www\.|\S+@\S+)")
_GENERIC_LOWERCASE_WORDS = {"app", "api", "web", "file", "link"}
_BRAND_CUE = re.compile(
    r"(?:แอป|app|แบรนด์|ชื่อแบรนด์)\s*(?!(?:เพื่อ|แล้ว|ครับ|ค่ะ|คะ|นะ|และ|กับ|ใน|ที่|ให้|ของ))(?P<term>[ก-๙]{2,}?)(?=\s*(?:เพื่อ|แล้ว|ครับ|ค่ะ|คะ|นะ|และ|กับ|ใน|ที่|ให้|ของ|$))",
    re.IGNORECASE,
)
_THAI_NON_NAMES = {"นี้", "นั้น", "เรา", "ของ", "งาน"}
_LINE_TEXTILE_CONTEXT = re.compile(r"(?:ลายเสื้อ|บนผ้า|บนเสื้อ|ของผ้า)")
_MAX_SPANS = 3


def _intersects_protected(start: int, end: int, protected: list[tuple[int, int]]) -> bool:
    return any(start < protected_end and end > protected_start for protected_start, protected_end in protected)


def _within_one_edit(left: str, right: str) -> bool:
    if abs(len(left) - len(right)) > 1:
        return False
    if len(left) == len(right):
        return sum(a != b for a, b in zip(left, right)) <= 1
    shorter, longer = (left, right) if len(left) < len(right) else (right, left)
    return any(longer[:index] + longer[index + 1:] == shorter for index in range(len(longer)))


def _nearby_candidates(token: str, known_terms: dict[str, str]) -> list[str]:
    # A 2-3 letter acoustic near-match such as app/API is too weak to infer.
    if not 4 <= len(token) <= 40:
        return []
    candidates = [
        term for folded, term in known_terms.items()
        if _within_one_edit(token.casefold(), folded)
    ]
    return sorted(candidates, key=lambda value: (len(value), value.casefold()))[:2]


@lru_cache(maxsize=4)
def _cached_plaud_terms(path_text: str, modified_ns: int) -> dict[str, TermEvidence]:
    return load_vocabulary(Path(path_text))


def _load_cached_plaud_terms(path: Path) -> dict[str, TermEvidence]:
    try:
        modified_ns = path.stat().st_mtime_ns
    except OSError:
        return {}
    return _cached_plaud_terms(str(path), modified_ns)


def _unknown_latin_spans(
    text: str, known_terms: dict[str, str], protected: list[tuple[int, int]]
) -> list[dict[str, Any]]:
    spans: list[dict[str, Any]] = []
    for match in _LATIN_TOKEN.finditer(text):
        token = match.group(1)
        folded = token.casefold()
        if token == token.lower() and folded in _GENERIC_LOWERCASE_WORDS:
            continue
        if folded in known_terms or _URL_OR_MAIL.search(token) or "/" in token:
            continue
        start, end = match.span(1)
        if _intersects_protected(start, end, protected):
            continue
        surrounding = text[max(0, start - 8): min(len(text), end + 8)]
        looks_like_name = any(character.isupper() for character in token[1:]) or token.isupper() or bool(_THAI_NEIGHBOR.search(surrounding))
        if not looks_like_name:
            continue
        candidates = _nearby_candidates(token, known_terms)
        spans.append({
            "text": token,
            "category": "brand" if candidates else "mixed_thai_english",
            "reason": "mixed_term_near_known_brand" if candidates else "unknown_latin_token_in_thai_context",
            "candidates": candidates,
        })
        if len(spans) >= _MAX_SPANS:
            break
    return spans


def _brand_cue_spans(text: str, protected: list[tuple[int, int]]) -> list[dict[str, Any]]:
    spans = []
    for match in _BRAND_CUE.finditer(text):
        start, end = match.span("term")
        term = match["term"]
        if term in _THAI_NON_NAMES or _intersects_protected(start, end, protected):
            continue
        spans.append({
            "text": term,
            "category": "brand",
            "reason": "thai_name_after_explicit_brand_cue",
            "candidates": [],
        })
        if len(spans) >= _MAX_SPANS:
            break
    return spans


def _line_textile_span(text: str, protected: list[tuple[int, int]]) -> dict[str, Any] | None:
    match = re.search(r"(?<![A-Za-z0-9_])LINE(?![A-Za-z0-9_])", text)
    if not match or _intersects_protected(*match.span(), protected):
        return None
    context = text[max(0, match.start() - 18): min(len(text), match.end() + 18)]
    if not _LINE_TEXTILE_CONTEXT.search(context):
        return None
    return {
        "text": "LINE",
        "category": "brand",
        "reason": "line_textile_homonym",
        "candidates": ["ลาย"],
    }


def _partial_conflict_span(raw: str, partial_texts: tuple[str, ...]) -> str | None:
    """Return only the divergent final fragment, never a whole utterance."""
    if not partial_texts:
        return None
    partial = partial_texts[-1].strip()
    if not partial or raw.startswith(partial) or partial.startswith(raw):
        return None
    prefix = 0
    for left, right in zip(raw, partial):
        if left != right:
            break
        prefix += 1
    suffix = 0
    for left, right in zip(reversed(raw[prefix:]), reversed(partial[prefix:])):
        if left != right:
            break
        suffix += 1
    divergent = raw[prefix:len(raw) - suffix if suffix else None].strip()
    if len(divergent) >= 3:
        return divergent
    # A one-letter final correction still matters. Report its containing word,
    # not the whole utterance, when spaces give us a safe local boundary.
    word_start = raw.rfind(" ", 0, prefix) + 1
    word_end = raw.find(" ", prefix)
    fragment = raw[word_start:word_end if word_end != -1 else len(raw)].strip()
    return fragment if len(fragment) >= 3 else None


def _invalid_clock(text: str) -> re.Match[str] | None:
    for match in _CLOCK.finditer(text):
        if int(match.group(1)) > 23 or int(match.group(2)) > 59:
            return match
    return None


def score_final(
    raw_text: str,
    display_text: str,
    *,
    partial_texts: tuple[str, ...] = (),
    plaud_terms_path: Path | None = None,
) -> dict[str, Any]:
    """Return a deterministic, privacy-safe review decision for one final."""
    raw = raw_text.strip()
    display = display_text.strip()
    plaud_terms = _load_cached_plaud_terms(plaud_terms_path or _PLAUD_TERMS_PATH)
    known_terms = {term.casefold(): term for term in _CANONICAL_TERMS}
    known_terms.update({term.casefold(): term for term in plaud_terms.values() for term in [term.term]})
    known_words = {word.casefold(): word for term in known_terms.values() for word in term.split()}
    protected = [match.span() for match in PROTECTED_SPAN.finditer(display)]
    spans = _unknown_latin_spans(display, known_words | known_terms, protected)
    if len(spans) < _MAX_SPANS:
        spans.extend(_brand_cue_spans(display, protected)[:_MAX_SPANS - len(spans)])
    line_homonym = _line_textile_span(display, protected)
    if line_homonym and len(spans) < _MAX_SPANS:
        spans.append(line_homonym)
    reasons = ["final_text_present"]

    if raw != display:
        canonical_used = any(term.casefold() in display.casefold() for term in _CANONICAL_TERMS)
        reasons.append("reviewed_local_vocabulary_formatting" if canonical_used else "display_formatter_changed_text")

    calendar_match = _SUSPICIOUS_DATE_TIME.search(raw) or malformed_calendar(raw) or _invalid_clock(display)
    if calendar_match and len(spans) < _MAX_SPANS:
        spans.append({
            "text": calendar_match.group(0),
            "category": "date_time",
            "reason": "calendar_or_time_shape_needs_confirmation",
            "candidates": [],
        })

    partial_conflict = _partial_conflict_span(raw, partial_texts)
    if partial_conflict and len(spans) < _MAX_SPANS:
        matched_terms = [term for term in known_terms.values() if term.casefold() in partial_conflict.casefold()]
        spans.append({
            "text": partial_conflict,
            "category": "brand" if matched_terms else "thai_phrase",
            "reason": "partial_final_material_disagreement",
            "candidates": matched_terms[:2],
        })

    if spans:
        score = 58 if any(span["category"] == "date_time" for span in spans) else 68
        reasons.append("specific_ambiguous_spans_found")
        eligible_spans = [span for span in spans if span["reason"] == "mixed_term_near_known_brand"]
        review_request: dict[str, Any] | None = {
            "route": "jev_luna" if eligible_spans else "local_only",
            "policy": "review_only_no_automatic_rewrite",
            "spans": eligible_spans,
            "local_plaud_term_index_used": bool(plaud_terms),
        }
        decision = "review"
    else:
        # With no decoder posterior, routine text remains a modest local pass.
        score = 86 if raw != display else 80
        review_request = None
        decision = "pass"

    return {
        "version": 1,
        "decision": decision,
        "heuristic_score": score,
        "confidence_kind": "rule_based_quality_not_model_probability",
        "recognizer_confidence_available": False,
        "reasons": reasons,
        "uncertain_spans": spans,
        "review_request": review_request,
    }
