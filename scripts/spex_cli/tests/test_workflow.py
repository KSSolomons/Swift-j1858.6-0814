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


class SpexCliWorkflowTests(unittest.TestCase):
    def test_workflow_script_renders_expected_sections(self):
        workflow = _load_module("spex_cli_workflow_test", SCRIPT_DIR / "workflow.py")
        cfg = workflow.WorkflowConfig(obsid="0865600201", instrument="pn")
        paths, script = workflow.build_workflow(REPO_ROOT, cfg)
        self.assertIn("fit stat cstat", script)
        self.assertIn("com hot", script)
        self.assertIn("par show free", script)
        self.assertIn("obin", script)

    def test_parse_log_extracts_stats(self):
        parser = _load_module("spex_cli_parse_log_test", SCRIPT_DIR / "parse_log.py")
        sample = """
        fit stat cstat
        cstat = 1234.5
        chi-squared: 678.9
        wstat = 111.0
        n free parameters = 42
        1 2 nh 3.0e-03 -1.0e-04 2.0e-04 frozen
        """
        parsed = parser.parse_spex_log_text(sample)
        self.assertAlmostEqual(parsed["statistics"]["cstat"], 1234.5)
        self.assertAlmostEqual(parsed["statistics"]["chisq"], 678.9)
        self.assertAlmostEqual(parsed["statistics"]["wstat"], 111.0)
        self.assertAlmostEqual(parsed["statistics"]["nfree"], 42.0)
        self.assertGreaterEqual(len(parsed["parameters"]), 1)

    def test_run_workflow_argument_parser(self):
        runner = _load_module("spex_cli_runner_test", SCRIPT_DIR / "run_workflow.py")
        parser = runner._build_parser()
        ns = parser.parse_args(["--obsid", "0865600201", "--instrument", "pn"])
        self.assertEqual(ns.instrument, "pn")
        self.assertEqual(ns.obsid, "0865600201")


if __name__ == "__main__":
    unittest.main()


