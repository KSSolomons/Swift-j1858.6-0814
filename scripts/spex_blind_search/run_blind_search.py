"""Deprecated blind-search helper.
The active workflow is now CLI-only and does not use this module.
"""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
@dataclass(frozen=True)
class BlindLineSearchResult:
    dataframe: object | None = None
    csv_path: Path | None = None
    plot_path: Path | None = None
def run_blind_line_search(*args, **kwargs):
    raise NotImplementedError(
        "Blind line search has been retired from the legacy notebook-style workflow. "
        "Use the CLI workflow and a future CLI blind-search implementation instead."
    )
