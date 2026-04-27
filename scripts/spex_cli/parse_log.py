"""Best-effort parsing for SPEX CLI logs.

The SPEX command-line output format can vary between installations, so this
parser is intentionally permissive. It extracts the pieces needed for a compact
run summary:
- fit statistics such as C-stat / chi-squared / W-stat
- the number of free parameters if it appears in the log
- any obvious parameter rows from report tables

If your local SPEX build prints tables differently, extend the regexes here.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import csv
import json
import re
from typing import Iterable


_STAT_PATTERNS = {
    "cstat": re.compile(r"(?i)\bcstat\b\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "chisq": re.compile(r"(?i)\bchi(?:-?squared|2)\b\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "wstat": re.compile(r"(?i)\bwstat\b\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "dof": re.compile(r"(?i)\bdof\b\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "nfree": re.compile(r"(?i)\b(?:n\s*free(?:\s*parameters)?|free\s*parameters)\b\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
}


@dataclass(frozen=True)
class ParsedParameter:
    sect: int
    comp: int
    name: str
    value: float | None = None
    err_low: float | None = None
    err_high: float | None = None
    status: str | None = None


def _safe_float(text: str | None) -> float | None:
    if text is None:
        return None
    try:
        return float(text)
    except Exception:
        return None


def _search_stats(text: str) -> dict[str, float | None]:
    out: dict[str, float | None] = {}
    for key, pattern in _STAT_PATTERNS.items():
        match = pattern.search(text)
        out[key] = _safe_float(match.group(1)) if match else None
    return out


def _parse_param_lines(lines: Iterable[str]) -> list[ParsedParameter]:
    rows: list[ParsedParameter] = []
    for raw in lines:
        line = raw.strip()
        if not line:
            continue

        # Common report-table style rows: sect comp name value err_low err_high status
        match = re.match(
            r"^(?P<sect>\d+)\s+(?P<comp>\d+)\s+(?P<name>[A-Za-z][\w-]*)\s+"
            r"(?P<value>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"
            r"(?:\s+(?P<err_low>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?))?"
            r"(?:\s+(?P<err_high>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?))?"
            r"(?:\s+(?P<status>[A-Za-z][\w-]*))?$",
            line,
        )
        if not match:
            continue

        rows.append(
            ParsedParameter(
                sect=int(match.group("sect")),
                comp=int(match.group("comp")),
                name=match.group("name"),
                value=_safe_float(match.group("value")),
                err_low=_safe_float(match.group("err_low")),
                err_high=_safe_float(match.group("err_high")),
                status=match.group("status"),
            )
        )
    return rows


def parse_spex_log_text(text: str) -> dict:
    lines = text.splitlines()
    stats = _search_stats(text)
    params = _parse_param_lines(lines)
    return {
        "statistics": stats,
        "parameters": [p.__dict__ for p in params],
        "line_count": len(lines),
    }


def parse_spex_log(path: Path | str) -> dict:
    return parse_spex_log_text(Path(path).read_text(encoding="utf-8", errors="replace"))


def write_summary_csv(path: Path | str, parsed: dict) -> Path:
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Statistic", "Value"])
        for key, value in parsed.get("statistics", {}).items():
            writer.writerow([key, "" if value is None else value])
    return out_path


def write_summary_json(path: Path | str, parsed: dict) -> Path:
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(parsed, indent=2), encoding="utf-8")
    return out_path


