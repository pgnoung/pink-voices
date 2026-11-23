"""Build a private, evidence-bounded Pink voices vocabulary from local PLAUD text.

This tool reads only already captured transcript text on this Mac.  It never
contacts PLAUD, includes no transcript text in its output, and never changes
the user's personal correction dictionary.  The output is evidence for a later
confidence scorer, not a list of automatic substitutions.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import argparse
from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Iterable


SCHEMA = "pinkvoices.plaud-vocabulary"
VERSION = 1
# Set these for your own transcript archive; nothing personal is built in.
DEFAULT_SOURCE_ROOT = Path(os.environ["PV_TRANSCRIPTS_DIR"]) if os.environ.get("PV_TRANSCRIPTS_DIR") else None
DEFAULT_DICTIONARY = Path(os.environ["PV_TERMS_FILE"]) if os.environ.get("PV_TERMS_FILE") else None
DEFAULT_OUTPUT = Path.home() / "Library/Application Support/Pink voices/plaud-vocabulary.json"
TABLE_ROW = re.compile(r"^\|(?P<cells>[^\n]+)\|\s*$")
TABLE_DIVIDER = re.compile(r"^\s*:?-{3,}:?\s*$")
SKIP_HEADER = {"correct form", "use this", "correct", "notes"}
# Words that identify the archive owner and must never enter the index (comma-separated env).
PERSONAL_MARKERS = tuple(m.strip().casefold() for m in os.environ.get("PV_PERSONAL_MARKERS", "").split(",") if m.strip())


@dataclass(frozen=True)
class TermEvidence:
    term: str
    document_count: int
    occurrence_count: int


def _clean_candidate(value: str) -> str | None:
    term = value.strip().strip("`")
    if not (2 <= len(term) <= 72):
        return None
    if term.casefold() in SKIP_HEADER or any(marker in term.casefold() for marker in PERSONAL_MARKERS):
        return None
    if any(character.isdigit() for character in term):
        return None
    if "@" in term or "://" in term or "/" in term or "\\" in term:
        return None
    if not any(character.isalpha() for character in term):
        return None
    return term


def canonical_terms(dictionary_text: str) -> set[str]:
    """Read canonical spellings from the maintained terminology table only."""
    terms: set[str] = set()
    heading: list[str] | None = None
    for line in dictionary_text.splitlines():
        row = TABLE_ROW.match(line)
        if not row:
            heading = None
            continue
        cells = [cell.strip() for cell in row["cells"].split("|")]
        if all(TABLE_DIVIDER.match(cell) for cell in cells):
            continue
        lowered = [cell.casefold() for cell in cells]
        if any(cell in {"correct form", "use this", "correct"} for cell in lowered):
            heading = lowered
            continue
        if heading is None or len(cells) != len(heading):
            continue
        if "use this" in heading:
            term = _clean_candidate(cells[heading.index("use this")])
        elif "correct form" in heading:
            term = _clean_candidate(cells[heading.index("correct form")])
        elif "correct" in heading:
            term = _clean_candidate(cells[heading.index("correct")])
        else:
            continue
        if term:
            terms.add(term)
    return terms


def _count_occurrences(text: str, term: str) -> int:
    if re.search(r"[A-Za-z]", term):
        pattern = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(term) + r"(?![A-Za-z0-9_])", re.IGNORECASE)
        return len(pattern.findall(text))
    return text.casefold().count(term.casefold())


def build_evidence(terms: Iterable[str], transcripts: Iterable[str], minimum_documents: int = 2) -> list[TermEvidence]:
    """Count exact canonical terms in distinct documents without retaining text."""
    if minimum_documents < 1:
        raise ValueError("minimum_documents must be at least 1")
    ordered_terms = sorted(set(terms), key=lambda term: (-len(term), term.casefold()))
    counts = {term: [0, 0] for term in ordered_terms}
    latin_patterns = {
        term: re.compile(r"(?<![A-Za-z0-9_])" + re.escape(term) + r"(?![A-Za-z0-9_])", re.IGNORECASE)
        for term in ordered_terms if re.search(r"[A-Za-z]", term)
    }
    for transcript in transcripts:
        folded = transcript.casefold()
        for term, values in counts.items():
            if term.casefold() not in folded:
                continue
            occurrences = len(latin_patterns[term].findall(transcript)) if term in latin_patterns else folded.count(term.casefold())
            if occurrences:
                values[0] += 1
                values[1] += occurrences
    return [
        TermEvidence(term, document_count, occurrence_count)
        for term, (document_count, occurrence_count) in counts.items()
        if document_count >= minimum_documents
    ]


def _raw_transcripts(source_root: Path) -> list[Path]:
    return sorted(path for path in source_root.rglob("raw-transcript.md") if path.is_file() and not path.is_symlink())


def _recording_key(transcript_path: Path, transcript_text: str) -> str:
    receipt = transcript_path.with_name("source-storage-receipt.json")
    try:
        recording_id = json.loads(receipt.read_text(encoding="utf-8")).get("recording", {}).get("id")
    except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
        recording_id = None
    if isinstance(recording_id, str) and recording_id:
        return "recording:" + recording_id
    return "text:" + sha256(transcript_text.encode("utf-8")).hexdigest()


def _unique_transcripts(source_root: Path, source_counts: Counter[str]) -> Iterable[str]:
    seen: set[str] = set()
    for source in _raw_transcripts(source_root):
        source_counts["documents_found"] += 1
        try:
            transcript = source.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            source_counts["documents_skipped"] += 1
            continue
        source_counts["documents_readable"] += 1
        key = _recording_key(source, transcript)
        if key in seen:
            source_counts["documents_duplicates"] += 1
            continue
        seen.add(key)
        source_counts["documents_unique"] += 1
        yield transcript


def make_index(source_root: Path, dictionary_path: Path, minimum_documents: int) -> dict[str, object]:
    terms = canonical_terms(dictionary_path.read_text(encoding="utf-8"))
    source_counts: Counter[str] = Counter()
    evidence = sorted(build_evidence(terms, _unique_transcripts(source_root, source_counts), minimum_documents), key=lambda item: item.term.casefold())
    return {
        "schema": SCHEMA,
        "version": VERSION,
        "generated_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "source": {
            "kind": "local_plaud_private_transcripts",
            "documents_found": source_counts["documents_found"],
            "documents_readable": source_counts["documents_readable"],
            "documents_unique": source_counts["documents_unique"],
            "documents_duplicates": source_counts["documents_duplicates"],
            "documents_skipped": source_counts["documents_skipped"],
            "canonical_terms_considered": len(terms),
            "minimum_document_count": minimum_documents,
        },
        "terms": [item.__dict__ for item in evidence],
    }


def load_vocabulary(path: Path = DEFAULT_OUTPUT) -> dict[str, TermEvidence]:
    """Load only a validated local evidence map for the Pink voices scorer."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if data.get("schema") != SCHEMA or data.get("version") != VERSION or not isinstance(data.get("terms"), list):
        return {}
    result: dict[str, TermEvidence] = {}
    for item in data["terms"]:
        if not isinstance(item, dict):
            continue
        term = item.get("term")
        documents = item.get("document_count")
        occurrences = item.get("occurrence_count")
        if isinstance(term, str) and isinstance(documents, int) and isinstance(occurrences, int) and documents > 0 and occurrences > 0:
            result[term.casefold()] = TermEvidence(term, documents, occurrences)
    return result


def write_index(data: dict[str, object], output_path: Path) -> None:
    output_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(output_path.parent, 0o700)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=output_path.parent, prefix=".plaud-vocabulary-", delete=False) as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    os.chmod(temporary, 0o600)
    temporary.replace(output_path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Create Pink voices' local PLAUD term evidence index")
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT, required=DEFAULT_SOURCE_ROOT is None)
    parser.add_argument("--dictionary", type=Path, default=DEFAULT_DICTIONARY, required=DEFAULT_DICTIONARY is None)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--minimum-documents", type=int, default=2)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    data = make_index(args.source_root, args.dictionary, args.minimum_documents)
    if not args.dry_run:
        write_index(data, args.output)
    source = data["source"]
    print(json.dumps({"terms": len(data["terms"]), **source, "written": not args.dry_run}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
