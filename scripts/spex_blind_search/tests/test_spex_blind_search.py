import importlib.util
import sys
import unittest
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
SCRIPT_DIR = TEST_DIR.parent
REPO_ROOT = SCRIPT_DIR.parents[1]


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class SpexBlindSearchTests(unittest.TestCase):
    def test_canonical_module_exports(self):
        mod = _load_module("run_blind_search_test", SCRIPT_DIR / "run_blind_search.py")
        self.assertTrue(hasattr(mod, "run_blind_line_search"))
        self.assertTrue(hasattr(mod, "BlindLineSearchResult"))

    def test_compatibility_wrapper_exports(self):
        mod = _load_module("spex_blind_search_test", REPO_ROOT / "notebooks" / "spex_blind_search.py")
        self.assertTrue(hasattr(mod, "run_blind_line_search"))
        self.assertTrue(hasattr(mod, "BlindLineSearchResult"))

    def test_make_scan_grid_monotonic(self):
        mod = _load_module("run_blind_search_grid_test", SCRIPT_DIR / "run_blind_search.py")
        grid = mod._make_scan_grid(0.7, 7.0, 0.1)
        self.assertGreater(len(grid), 10)
        energies = [e for e, _ in grid]
        self.assertTrue(all(energies[i] < energies[i + 1] for i in range(len(energies) - 1)))


if __name__ == "__main__":
    unittest.main()

