# SPEX Blind Line Search

Standalone SPEX blind-search helper for the PN/SPEX workflow.

## Canonical module

- `scripts/spex_blind_search/run_blind_search.py`

## Compatibility import

Existing notebooks can keep using:

```python
from spex_blind_search import run_blind_line_search
```

That import is now provided by the thin compatibility wrapper in
`notebooks/spex_blind_search.py`, which forwards to the canonical module in
`scripts/spex_blind_search/`.

## Provided API

- `BlindLineSearchResult`
- `run_blind_line_search(...)`

## Typical notebook usage

```python
from spex_blind_search import run_blind_line_search
result = run_blind_line_search(
    session,
    artifact_dir=fit_artifact_dir,
    fit_tag=fit_tag,
)
```

