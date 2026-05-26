import importlib.util
import json
import sys
import tempfile
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

    def test_workflow_with_best_fit_params_skips_staged_fitting(self):
        workflow = _load_module("spex_cli_workflow_bf", SCRIPT_DIR / "workflow.py")
        params = {
            "hot": {"nh": 0.002, "t": 0.0008, "nh_status": "frozen", "t_status": "frozen"},
            "xabs": {"nh": 0.023, "xil": -1.07, "fcov": 0.726,
                     "nh_status": "thawn", "xil_status": "thawn", "fcov_status": "thawn"},
            "dbb": {"t": 0.0001, "norm": 0.0, "t_status": "thawn", "norm_status": "thawn"},
            "pow": {"gamm": 2.0, "norm": 1322.9, "gamm_status": "frozen", "norm_status": "thawn"},
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(params, f)
            tmp_path = Path(f.name)

        try:
            cfg = workflow.WorkflowConfig(
                obsid="0865600201", instrument="pn",
                best_fit_params_file=tmp_path,
            )
            paths, script = workflow.build_workflow(REPO_ROOT, cfg)

            # Should contain the best-fit values
            self.assertIn("best-fit values file", script)
            self.assertIn("par 1 2 nh v 0.023", script)
            self.assertIn("par 1 2 xil v -1.07", script)
            self.assertIn("par 1 2 nh stat thawn", script)

            # Should NOT contain staged fitting comments
            self.assertNotIn("Stage 0b", script)
            self.assertNotIn("Stage 1", script)
            self.assertNotIn("Stage 2", script)
            self.assertNotIn("Stage 3", script)

            # Should still have a single fit call
            self.assertIn("fit", script)
            self.assertIn("fit stat cstat", script)
        finally:
            tmp_path.unlink()

    def test_workflow_without_best_fit_params_uses_fallback_defaults(self):
        workflow = _load_module("spex_cli_workflow_nob", SCRIPT_DIR / "workflow.py")
        cfg = workflow.WorkflowConfig(obsid="0865600201", instrument="pn", continuum_model="pow")
        paths, script = workflow.build_workflow(REPO_ROOT, cfg)

        # Should contain fallback default values
        self.assertIn("par 1 1 t v 0.0008", script)
        self.assertIn("par 1 2 nh v 0.003", script)
        self.assertIn("par 1 3 t v 0.5", script)
        self.assertIn("par 1 4 gamm v 1.5", script)

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
        self.assertIsNone(ns.best_fit_params)

    def test_run_workflow_argument_parser_with_best_fit(self):
        runner = _load_module("spex_cli_runner_bf_test", SCRIPT_DIR / "run_workflow.py")
        parser = runner._build_parser()
        ns = parser.parse_args([
            "--obsid", "0865600201", "--instrument", "pn",
            "--best-fit-params", "/tmp/params.json",
        ])
        self.assertEqual(ns.best_fit_params, "/tmp/params.json")

    def test_workflow_with_blind_search_refit_baseline(self):
        workflow = _load_module("spex_cli_workflow_bs_refit", SCRIPT_DIR / "workflow.py")
        cfg = workflow.WorkflowConfig(
            obsid="0865600201", instrument="pn",
            blind_search_run=True,
            blind_search_refit_baseline=True
        )
        paths, script = workflow.build_workflow(REPO_ROOT, cfg)
        self.assertIn("Refit baseline model to ensure best-fit baseline before freezing", script)


if __name__ == "__main__":
    unittest.main()
