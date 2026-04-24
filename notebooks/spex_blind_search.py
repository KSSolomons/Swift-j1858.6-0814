"""Compatibility wrapper for the SPEX blind-search helper.
The canonical implementation now lives in:
    scripts/spex_blind_search/run_blind_search.py
This wrapper keeps existing notebook imports working:
    from spex_blind_search import run_blind_line_search
"""
from __future__ import annotations
import sys
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
def _load_impl():
    here = Path(__file__).resolve().parent
    script_path = here.parent / "scripts" / "spex_blind_search" / "run_blind_search.py"
    spec = spec_from_file_location("scripts.spex_blind_search.run_blind_search", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not import SPEX blind-search helper from {script_path}")
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module
_impl = _load_impl()
BlindLineSearchResult = _impl.BlindLineSearchResult
run_blind_line_search = _impl.run_blind_line_search
__all__ = ["BlindLineSearchResult", "run_blind_line_search"]
