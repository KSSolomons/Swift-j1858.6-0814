import tempfile
import unittest
from pathlib import Path
import sys

TEST_DIR = Path(__file__).resolve().parent
SCRIPT_DIR = TEST_DIR.parent

# Import from sibling script directory without requiring package install.
import importlib.util

_SPEC = importlib.util.spec_from_file_location("port_to_spex", SCRIPT_DIR / "port_to_spex.py")
if _SPEC is None or _SPEC.loader is None:
    raise RuntimeError("Could not load port_to_spex.py for tests")
pts = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = pts
_SPEC.loader.exec_module(pts)


class PortToSpexResolverTests(unittest.TestCase):
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

    def test_resolve_pn_ungrouped(self):
        """port_to_spex always works with ungrouped spectra."""
        spec = self._touch(f"{self.obsid}/pn/spec/pn_source_Dipping.fits")
        self._touch(f"{self.obsid}/pn/spec/pn_bkg_Dipping.fits")
        self._touch(f"{self.obsid}/pn/spec/pn_rmf_Dipping.rmf")
        self._touch(f"{self.obsid}/pn/spec/pn_arf_Dipping.arf")

        ds = pts.resolve_pn_dataset(self.root, self.obsid, "Dipping")
        self.assertEqual(ds.spec, spec)

    def test_resolve_pn_flux_resolved_fallback(self):
        spec = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_source_Dipping_HighFlux.fits")
        bkg = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_bkg_Dipping_HighFlux.fits")
        rmf = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_rmf_Dipping_HighFlux.rmf")
        arf = self._touch(f"{self.obsid}/pn/spec/flux_resolved/pn_arf_Dipping_HighFlux.arf")

        ds = pts.resolve_pn_dataset(self.root, self.obsid, "Dipping_HighFlux")
        self.assertEqual(ds.spec, spec)
        self.assertEqual(ds.bkg, bkg)
        self.assertEqual(ds.rmf, rmf)
        self.assertEqual(ds.arf, arf)

    def test_resolve_rgs_case_insensitive(self):
        base = f"{self.obsid}/rgs/time_intervals/Full"
        spec = self._touch(f"{base}/rgs1_src_o1_Full.fits")
        bkg = self._touch(f"{base}/RGS1_BKG_O1_FULL.FITS")
        rmf = self._touch(f"{base}/rgs1_o1_Full.rmf")

        datasets = pts.resolve_rgs_datasets(self.root, self.obsid, "Full")
        first = next(d for d in datasets if d.instrument == 1 and d.order == 1)

        self.assertEqual(first.spec, spec)
        self.assertEqual(first.bkg, bkg)
        self.assertEqual(first.rmf, rmf)

    def test_find_interval_dir_falls_back_to_flux_resolved(self):
        d = self.root / self.obsid / "rgs" / "flux_resolved" / "LowFlux"
        d.mkdir(parents=True, exist_ok=True)

        found = pts._find_interval_dir(self.root / self.obsid / "rgs", "LowFlux")
        self.assertEqual(found, d)

    def test_default_pn_out_base(self):
        """Output goes to a flat spex/ directory (no grouped/ungrouped split)."""
        out = pts._default_pn_out_base(self.root, self.obsid, "Persistent")
        self.assertEqual(
            out,
            self.root / self.obsid / "pn" / "spex" / "pn_Persistent_spex",
        )

    def test_default_rgs_out_base(self):
        """Output goes to a flat spex/ directory (no grouped/ungrouped split)."""
        out = pts._default_rgs_out_base(self.root, self.obsid, "Full")
        self.assertEqual(
            out,
            self.root / self.obsid / "rgs" / "spex" / "rgs_Full_spex",
        )


if __name__ == "__main__":
    unittest.main()
