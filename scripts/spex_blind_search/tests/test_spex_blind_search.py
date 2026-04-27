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
    def test_legacy_module_is_stubbed(self):
        mod = _load_module("run_blind_search_test", SCRIPT_DIR / "run_blind_search.py")
        self.assertTrue(hasattr(mod, "BlindLineSearchResult"))
        self.assertTrue(hasattr(mod, "run_blind_line_search"))
        with self.assertRaises(NotImplementedError):
            mod.run_blind_line_search()
    def test_compatibility_wrapper_exports_stub(self):
        mod = _load_module("spex_blind_search_test", REPO_ROOT / "notebooks" / "spex_blind_search.py")
        self.assertTrue(hasattr(mod, "run_blind_line_search"))
        self.assertTrue(hasattr(mod, "BlindLineSearchResult"))
if __name__ == "__main__":
    unittest.main()
