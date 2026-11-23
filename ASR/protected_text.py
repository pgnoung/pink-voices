"""Text fragments that display formatters must leave byte-for-byte unchanged."""

from __future__ import annotations

import re
from collections.abc import Callable


# URLs, mail, command-line paths, file names, and identifier-shaped code can
# contain familiar brands or numbers without being spoken prose.
PROTECTED_SPAN = re.compile(
    r"(?:https?://|www\.)[^\s]+"
    r"|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
    r"|(?:~|/)[^\s]+"
    r"|(?<![A-Za-z0-9])[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+(?![A-Za-z0-9])"
    r"|(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*\.(?:py|js|mjs|swift|json|md|txt|yaml|yml|sh|command)(?![A-Za-z0-9_])"
    r"|(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+(?![A-Za-z0-9_])",
    re.IGNORECASE,
)


def transform_unprotected(text: str, transform: Callable[[str], str]) -> str:
    """Apply a formatter only to natural-language spans."""
    pieces = []
    position = 0
    for protected in PROTECTED_SPAN.finditer(text):
        pieces.append(transform(text[position:protected.start()]))
        pieces.append(protected.group(0))
        position = protected.end()
    pieces.append(transform(text[position:]))
    return "".join(pieces)
