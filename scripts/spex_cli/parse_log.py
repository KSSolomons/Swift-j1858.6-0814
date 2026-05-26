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
    "fit_method": re.compile(r"(?i)fit\s*method\s*[:=]\s*(.*)"),
    "fit_statistic": re.compile(r"(?i)fit\s*statistic\s*(?!\s*used)\s*[:=]\s*(.*)"),
    "fit_statistic_used": re.compile(r"(?i)fit\s*statistic\s*used\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "cstatistic": re.compile(r"(?i)(?:c-statistic|cstat)\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "expected_cstat": re.compile(r"(?i)expected\s*c-stat(?:istic)?\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)(?:\s*\+/-\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?))?"),
    "chi2_value": re.compile(r"(?i)(?:chi-squared(?:\s*value)?|chi2|chisq)\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "wstat": re.compile(r"(?i)(?:w-statistic|wstat)\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "dof": re.compile(r"(?i)(?:degrees\s*of\s*freedom|dof)\s*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "nfree": re.compile(r"(?i)(?:free\s*parameters|n\s*free|nfree)[^\n:=]*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
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


def _search_stats(text: str) -> dict[str, float | str | None]:
    out: dict[str, float | str | None] = {}
    for key, pattern in _STAT_PATTERNS.items():
        matches = list(pattern.finditer(text))
        if not matches:
            out[key] = None
        else:
            match = matches[-1]  # Use the last occurrence
            if key == "expected_cstat":
                val = match.group(1)
                unc = match.group(2) if match.lastindex and match.lastindex >= 2 else None
                out[key] = f"{val} +/- {unc}" if unc else val
            elif key in ("fit_method", "fit_statistic"):
                out[key] = match.group(1)
            else:
                out[key] = _safe_float(match.group(1)) if match.group(1) is not None else None

    # Aliases for compatibility
    out["cstat"] = out["cstatistic"]
    out["chisq"] = out["chi2_value"]
    return out


def _parse_param_lines(lines: Iterable[str]) -> list[ParsedParameter]:
    params_dict: dict[tuple[int, int, str], ParsedParameter] = {}
    for raw in lines:
        line = raw.strip()
        if not line:
            continue

        # par show free style rows: sect comp mod acro parameter_with_unit value status minimum maximum
        # or other table rows with values
        match = re.match(
            r"^\s*(?P<sect>\d+)\s+(?P<comp>\d+)\s+(?P<mod>[A-Za-z][\w-]*)\s+(?P<name>[A-Za-z0-9_]+)\s+"
            r"(?P<desc>.*?)\s+"
            r"(?P<value>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)\s+"
            r"(?P<status>thawn|frozen|coupled|tied)\s+"
            r"(?P<min>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)\s+"
            r"(?P<max>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)$", line, )
        if match:
            p = ParsedParameter(
                sect=int(match.group("sect")),
                comp=int(match.group("comp")),
                name=f"{match.group('mod')}_{match.group('name')}",
                value=_safe_float(match.group("value")),
                status=match.group("status"),
            )
            key = (p.sect, p.comp, p.name)
            if key in params_dict:
                del params_dict[key]
            params_dict[key] = p
            continue

        # Fallback for simpler format: sect comp name value err_low err_high
        # status
        match_simple = re.match(
            r"^\s*(?P<sect>\d+)\s+(?P<comp>\d+)\s+(?P<name>[A-Za-z][\w-]*)\s+"
            r"(?P<value>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"
            r"(?:\s+(?P<err_low>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?))?"
            r"(?:\s+(?P<err_high>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?))?"
            r"(?:\s+(?P<status>[A-Za-z][\w-]*))?$", line, )
        if match_simple:
            p = ParsedParameter(
                sect=int(match_simple.group("sect")),
                comp=int(match_simple.group("comp")),
                name=match_simple.group("name"),
                value=_safe_float(match_simple.group("value")),
                err_low=_safe_float(match_simple.group("err_low")),
                err_high=_safe_float(match_simple.group("err_high")),
                status=match_simple.group("status"),
            )
            key = (p.sect, p.comp, p.name)
            if key in params_dict:
                del params_dict[key]
            params_dict[key] = p

    return list(params_dict.values())


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
    return parse_spex_log_text(
        Path(path).read_text(
            encoding="utf-8",
            errors="replace"))


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


def write_summary_txt(path: Path | str, parsed: dict) -> Path:
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["SPEX Fit Summary", "================", ""]

    stats = parsed.get("statistics", {})
    # Output in CLI block style if possible
    lines.append("Statistics:")
    lines.append("-----------")
    cli_keys = [
        ("fit_method", "Fit method"),
        ("fit_statistic", "Fit statistic"),
        ("fit_statistic_used", "Fit statistic used"),
        ("cstatistic", "C-statistic"),
        ("expected_cstat", "Expected C-stat"),
        ("chi2_value", "Chi-squared value"),
        ("dof", "Degrees of freedom"),
        ("wstat", "W-statistic"),
        ("nfree", "N free parameters"),
    ]
    for k, label in cli_keys:
        v = stats.get(k)
        if v is not None:
            lines.append(f"  {label:<20}: {v}")
    lines.append("")

    lines.append("Parameters:")
    lines.append("-----------")
    params = parsed.get("parameters", [])
    if params:
        # Header
        lines.append(f"{'Sect':<6} {'Comp':<6} {'Name':<20} {'Value':<15} {'Status':<10}")
        lines.append("-" * 60)
        for p in params:
            val_str = f"{p.get('value', 0.0):.4e}" if p.get('value') is not None else "N/A"
            lines.append(f"{p.get('sect', ''):<6} {p.get('comp', ''):<6} {p.get('name', ''):<20} {val_str:<15} {p.get('status', '')}")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out_path
