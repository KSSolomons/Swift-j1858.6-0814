"""Deprecated notebook compatibility shim.
The CLI-only workflow is canonical now. Importing this module intentionally
keeps no notebook-era SPEX logic alive.
"""
from scripts.spex_blind_search.run_blind_search import BlindLineSearchResult, run_blind_line_search
__all__ = ["BlindLineSearchResult", "run_blind_line_search"]
