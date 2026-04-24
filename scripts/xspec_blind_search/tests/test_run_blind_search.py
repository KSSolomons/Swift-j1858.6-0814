import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
SCRIPT_DIR = TEST_DIR.parent

_SPEC = importlib.util.spec_from_file_location("run_blind_search", SCRIPT_DIR / "run_blind_search.py")
if _SPEC is None or _SPEC.loader is None:
    raise RuntimeError("Could not load run_blind_search.py for tests")

rbs = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = rbs
_SPEC.loader.exec_module(rbs)


class BlindSearchResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.obsid = "0865600201"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _touch(self, rel_path: str) -> Path:
        p = self.root / rel_path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.touch()
        return p

    def test_resolve_pn_grouped_flux_fallback(self):
        spec = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_source_Dipping_HighFlux_grp.pha")
        bkg = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_bkg_Dipping_HighFlux.fits")
        rmf = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_rmf_Dipping_HighFlux.rmf")
        arf = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_arf_Dipping_HighFlux.arf")

        ds = rbs.resolve_pn_dataset(self.root, self.obsid, "Dipping_HighFlux", grouped=True)
        self.assertEqual(ds.spec, spec)
        self.assertEqual(ds.bkg, bkg)
        self.assertEqual(ds.rmf, rmf)
        self.assertEqual(ds.arf, arf)

    def test_resolve_rgs_order1_lowflux_suffix_mapping(self):
        base = f"{self.obsid}/rgs/flux_resolved/LowFlux"
        s1 = self._touch(f"{base}/rgs1_src_o1_LowFlux_grp.pha")
        b1 = self._touch(f"{base}/rgs1_bkg_o1_LowFlux.fits")
        r1 = self._touch(f"{base}/rgs1_o1_LowFlux.rmf")
        s2 = self._touch(f"{base}/rgs2_src_o1_LowFlux_grp.pha")
        b2 = self._touch(f"{base}/rgs2_bkg_o1_LowFlux.fits")
        r2 = self._touch(f"{base}/rgs2_o1_LowFlux.rmf")

        ds = rbs.resolve_rgs_order1_dataset(self.root, self.obsid, "Dipping_LowFlux", grouped=True)
        self.assertEqual(ds.rgs1_spec, s1)
        self.assertEqual(ds.rgs1_bkg, b1)
        self.assertEqual(ds.rgs1_rmf, r1)
        self.assertEqual(ds.rgs2_spec, s2)
        self.assertEqual(ds.rgs2_bkg, b2)
        self.assertEqual(ds.rgs2_rmf, r2)

    def test_resolve_rgs_order2_persistent_grouped(self):
        base = f"{self.obsid}/rgs/time_intervals/Persistent"
        s1 = self._touch(f"{base}/rgs1_src_o2_Persistent_grp.pha")
        b1 = self._touch(f"{base}/rgs1_bkg_o2_Persistent.fits")
        r1 = self._touch(f"{base}/rgs1_o2_Persistent.rmf")
        s2 = self._touch(f"{base}/rgs2_src_o2_Persistent_grp.pha")
        b2 = self._touch(f"{base}/rgs2_bkg_o2_Persistent.fits")
        r2 = self._touch(f"{base}/rgs2_o2_Persistent.rmf")

        ds = rbs.resolve_rgs_dataset(self.root, self.obsid, "Persistent", grouped=True, order=2)
        self.assertEqual(ds.rgs1_spec, s1)
        self.assertEqual(ds.rgs1_bkg, b1)
        self.assertEqual(ds.rgs1_rmf, r1)
        self.assertEqual(ds.rgs2_spec, s2)
        self.assertEqual(ds.rgs2_bkg, b2)
        self.assertEqual(ds.rgs2_rmf, r2)

    def test_build_pn_scan_grid_is_monotonic_in_energy(self):
        grid = rbs._build_pn_scan_grid(0.7, 7.0, 0.05)
        self.assertGreater(len(grid), 10)
        energies = [e for e, _ in grid]
        self.assertTrue(all(energies[i] < energies[i + 1] for i in range(len(energies) - 1)))

    def test_build_rgs_scan_grid_hits_end_point(self):
        grid = rbs._build_rgs_scan_grid(5.0, 5.3, 0.1)
        lambdas = [lam for _, lam in grid]
        self.assertEqual(lambdas, [5.0, 5.1, 5.199999999999999, 5.299999999999999])


if __name__ == "__main__":
    unittest.main()

