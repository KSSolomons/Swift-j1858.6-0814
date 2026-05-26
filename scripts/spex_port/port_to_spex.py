#!/usr/bin/env python3
"""Convert OGIP spectra (PN/RGS) into SPEX .spo/.res files.

This script produces ungrouped SPEX files, as grouping is handled internally
within SPEX via batch commands (e.g., 'obin').

Examples:
    python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Full
    python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional, Any, Union
import subprocess
import shutil


@dataclass(frozen=True)
class PnDataset:
    spec: Path
    bkg: Path
    rmf: Path
    arf: Path
    region: int = 1
    sector: int = 1


@dataclass(frozen=True)
class RgsDataset:
    instrument: int
    order: int
    spec: Path
    bkg: Path
    rmf: Path
    region: int = 1
    sector: int = 1


def _first_existing(candidates: Iterable[Path]) -> Optional[Path]:
    for p in candidates:
        if p.is_file():
            return p
    return None


def _name_index(directory: Path) -> dict[str, Path]:
    return {p.name.lower(): p for p in directory.iterdir() if p.is_file()}


def _first_name_match(directory: Path, candidate_names: Iterable[str]) -> Optional[Path]:
    index = _name_index(directory)
    for name in candidate_names:
        match = index.get(name.lower())
        if match is not None:
            return match
    return None


def _find_interval_dir(rgs_root: Path, interval: str) -> Path:
    candidates = [
        rgs_root / "time_intervals" / interval,
        rgs_root / "flux_resolved" / interval,
        rgs_root / interval,
    ]
    for c in candidates:
        if c.is_dir():
            return c
    raise FileNotFoundError(
        f"Could not find an RGS interval directory for '{interval}'. Tried: "
        + ", ".join(str(c) for c in candidates)
    )


def resolve_pn_dataset(products_root: Path, obsid: str, interval: str) -> PnDataset:
    pn_spec_dir = products_root / obsid / "pn" / "spec"
    flux_dir = pn_spec_dir / "flux_resolved"

    if interval == "Full":
        spec_names = ["pn_source_spectrum.fits", "pn_source_spectrum.pha"]
        bkg_names = ["pn_bkg_spectrum.fits"]
        rmf_names = ["pn_rmf.rmf"]
        arf_names = ["pn_arf.arf"]
    else:
        spec_names = [f"pn_source_{interval}.fits", f"pn_source_{interval}.pha"]
        bkg_names = [f"pn_bkg_{interval}.fits"]
        rmf_names = [f"pn_rmf_{interval}.rmf", "pn_rmf.rmf"]
        arf_names = [f"pn_arf_{interval}.arf", "pn_arf.arf"]

    def _get_path(names: list[str]) -> Optional[Path]:
        c = []
        for n in names:
            c.extend([pn_spec_dir / n, flux_dir / n])
        return _first_existing(c)

    spec, bkg, rmf, arf = _get_path(spec_names), _get_path(bkg_names), _get_path(rmf_names), _get_path(arf_names)

    missing = [k for k, v in {"spec": spec, "bkg": bkg, "rmf": rmf, "arf": arf}.items() if v is None]
    if missing:
        raise FileNotFoundError(f"Missing PN files for interval={interval!r}: {', '.join(missing)}")

    return PnDataset(spec=spec, bkg=bkg, rmf=rmf, arf=arf, region=1, sector=1)


def resolve_rgs_datasets(products_root: Path, obsid: str, interval: str,
                         orders: tuple[int, ...] = (1, 2)) -> list[RgsDataset]:
    rgs_root = products_root / obsid / "rgs"
    interval_dir = _find_interval_dir(rgs_root, interval)

    out: list[RgsDataset] = []
    for inst in (1, 2):
        for order in orders:
            prefix = f"rgs{inst}_src_o{order}_{interval}"
            spec = _first_name_match(interval_dir, [f"{prefix}.fits", f"{prefix}.pha"])
            bkg = _first_name_match(interval_dir, [f"rgs{inst}_bkg_o{order}_{interval}.fits"])
            rmf = _first_name_match(interval_dir, [f"rgs{inst}_o{order}_{interval}.rmf"])

            if spec and bkg and rmf:
                # All in Sector 1, regions numbered sequentially
                region_id = (inst - 1) * len(orders) + orders.index(order) + 1
                out.append(RgsDataset(
                    instrument=inst, order=order, spec=spec, bkg=bkg, rmf=rmf,
                    region=region_id, sector=1
                ))

    if not out:
        raise FileNotFoundError(f"No complete RGS datasets found in {interval_dir} for interval={interval!r}.")
    return out


def _import_pyspextools():
    try:
        import pyspextools.io as spio
        import pyspextools.io.ogip as ogip
        return spio, ogip
    except ImportError:
        raise RuntimeError("pyspextools not found. Please activate your SPEX conda environment.")


def convert_to_spex(
    instrument: str, 
    datasets: list[Union[PnDataset, RgsDataset]], 
    out_base: Path, 
    overwrite: bool
) -> tuple[Path, Path]:
    """Generic converter for PN (list of 1) or RGS (list of N) datasets."""
    spio, ogip = _import_pyspextools()
    ds = spio.Dataset()

    print(f"Converting {len(datasets)} dataset(s) for {instrument.upper()}...")
    for d in datasets:
        oregion = ogip.OGIPRegion()
        # Read the OGIP data. grouping=False ensures we get channel-level data.
        kwargs = {
            "phafile": str(d.spec),
            "rmffile": str(d.rmf),
            "bkgfile": str(d.bkg),
            "grouping": False
        }
        if hasattr(d, "arf"):
            kwargs["arffile"] = str(d.arf)
        
        oregion.read_region(**kwargs)
        oregion.ogip_to_spex()
        
        print(f"  Mapping {d.spec.name} -> Region {d.region}, Sector {d.sector}")
        ds.append_region(oregion, d.region, d.sector)

    spo_path, res_path = out_base.with_suffix(".spo"), out_base.with_suffix(".res")
    ds.write_all_regions(str(spo_path), str(res_path), overwrite=overwrite)
    return spo_path, res_path


def convert_with_trafo(
    instrument: str, 
    datasets: list[Union[PnDataset, RgsDataset]], 
    out_base: Path, 
    overwrite: bool
) -> tuple[Path, Path]:
    import pexpect

    spo_path = out_base.with_suffix(".spo")
    res_path = out_base.with_suffix(".res")

    if not overwrite and (spo_path.exists() or res_path.exists()):
        print(f"Skipping {out_base} (already exists). Use --overwrite to replace.")
        return spo_path, res_path

    if spo_path.exists(): spo_path.unlink()
    if res_path.exists(): res_path.unlink()

    print(f"Converting {len(datasets)} dataset(s) for {instrument.upper()} using trafo...")

    # Run trafo in the directory of the first dataset to avoid path length issues
    work_dir = datasets[0].spec.parent
    
    # We will pass absolute path for the output base
    out_base_abs = out_base.resolve()

    child = pexpect.spawn("trafo", cwd=str(work_dir), encoding="utf-8", timeout=30)
    
    child.expect("Enter the type:")
    child.sendline("1")
    
    child.expect("Enter the number of spectra you want to transform:")
    child.sendline(str(len(datasets)))
    
    child.expect("Enter the maximum number of response groups.*:")
    child.sendline("100000")
    
    # If transforming multiple spectra (e.g. order 1 and 2), trafo asks for sectors
    idx = child.expect(["Enter the number of sectors you want to create:", "Enter your preferred option.*:"])
    if idx == 0:
        child.sendline("1")
        child.expect("Enter your preferred option.*:")
    child.sendline("1")
    
    child.expect(r"calculate the response derivatives.*:")
    child.sendline("n")
    
    for i, d in enumerate(datasets):
        print(f"  Mapping {d.spec.name} via trafo...")
        child.expect("Enter filename spectrum to be read:")
        child.sendline(d.spec.name)
        
        idx = child.expect(["Enter filename background spectrum to be read:", r"Read nevertheless a background file\?.*:"])
        if idx == 1:
            child.sendline("y")
            child.expect("Enter filename background spectrum to be read:")
        child.sendline(d.bkg.name)
        
        idx = child.expect(["Shall we use these quality flags to ignore bad channels.*:", "Enter filename response matrix to be read:", r"Read nevertheless a response.*:"])
        if idx == 0:
            child.sendline("y")
            idx = child.expect(["Enter filename response matrix to be read:", r"Read nevertheless a response.*:"])
            
        if idx == 1:
            child.sendline("y")
            child.expect("Enter filename response matrix to be read:")
        child.sendline(d.rmf.name)
        
        idx = child.expect(["Enter filename effective area to be read:", r"Read nevertheless an effective area file\?.*:"])
        if idx == 1:
            if hasattr(d, "arf") and d.arf:
                child.sendline("y")
                child.expect("Enter filename effective area to be read:")
                child.sendline(d.arf.name)
            else:
                child.sendline("n")
        else:
            if hasattr(d, "arf") and d.arf:
                child.sendline(d.arf.name)
            else:
                child.sendline("none")
                
        child.expect("Enter any shift in bins.*:")
        child.sendline("0")

    child.expect(r"Enter filename spectrum to be saved.*:")
    child.sendline(str(out_base_abs))
    
    child.expect(r"Enter filename response to be saved.*:")
    child.sendline(str(out_base_abs))
    
    child.expect(pexpect.EOF)
    child.close()
    
    if child.exitstatus != 0:
        print(f"TRAFO failed with exit status {child.exitstatus}")
        print(child.before)
        
    return spo_path, res_path


def _run_conversion(args: argparse.Namespace) -> int:
    products_root = Path(args.products_root).expanduser().resolve()
    
    # Resolve input datasets
    if args.instrument == "pn":
        datasets = [resolve_pn_dataset(products_root, args.obsid, args.interval)]
        default_out = products_root / args.obsid / "pn" / "spex" / f"pn_{args.interval}_spex"
    else:
        orders = tuple(int(o) for o in getattr(args, 'orders', '1,2').split(','))
        datasets = resolve_rgs_datasets(products_root, args.obsid, args.interval, orders=orders)
        default_out = products_root / args.obsid / "rgs" / "spex" / f"rgs_{args.interval}_spex"

    out_base = Path(args.out_base).expanduser().resolve() if args.out_base else default_out

    multi_sector = getattr(args, 'multi_sector', False) and args.instrument == "rgs"

    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "instrument": args.instrument,
        "obsid": args.obsid,
        "interval": args.interval,
        "multi_sector": multi_sector,
        "datasets": [{k: str(v) if isinstance(v, Path) else v for k, v in asdict(d).items()} for d in datasets],
        "out_base": str(out_base),
    }

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    out_base.parent.mkdir(parents=True, exist_ok=True)

    if multi_sector:
        # Write separate files per RGS instrument for multi-sector loading
        # SPEX creates sectors from separate `data` commands
        outputs = {}
        for inst_id in (1, 2):
            inst_datasets = [d for d in datasets if d.instrument == inst_id]
            if not inst_datasets:
                continue
            # Renumber regions sequentially within each instrument file (1, 2, ...)
            renumbered = []
            for i, d in enumerate(inst_datasets, start=1):
                renumbered.append(RgsDataset(
                    instrument=d.instrument, order=d.order,
                    spec=d.spec, bkg=d.bkg, rmf=d.rmf,
                    region=i, sector=inst_id
                ))
            inst_out = out_base.parent / f"rgs{inst_id}_{args.interval}_spex"
            if args.backend == 'trafo':
                spo, res = convert_with_trafo(args.instrument, renumbered, inst_out, args.overwrite)
            else:
                spo, res = convert_to_spex(args.instrument, renumbered, inst_out, args.overwrite)
            outputs[f"rgs{inst_id}"] = {"spo": str(spo), "res": str(res)}
        manifest["outputs"] = outputs
    else:
        if args.backend == 'trafo':
            spo, res = convert_with_trafo(args.instrument, datasets, out_base, args.overwrite)
        else:
            spo, res = convert_to_spex(args.instrument, datasets, out_base, args.overwrite)
        manifest["outputs"] = {"spo": str(spo), "res": str(res)}

    manifest_path = out_base.with_suffix(".manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    if multi_sector:
        for k, v in manifest["outputs"].items():
            print(f"Wrote: {v['spo']}\nWrote: {v['res']}")
    else:
        print(f"Wrote: {manifest['outputs']['spo']}\nWrote: {manifest['outputs']['res']}")
    print(f"Wrote: {manifest_path}")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Port OGIP PN/RGS products to SPEX .spo/.res")
    sub = p.add_subparsers(dest="instrument", required=True)

    for instr in ["pn", "rgs"]:
        sp = sub.add_parser(instr, help=f"Convert {instr.upper()} OGIP data to ungrouped SPEX files")
        sp.add_argument("--products-root", default="products", help="Path to products root")
        sp.add_argument("--obsid", required=True)
        sp.add_argument("--interval", required=True, help="Interval name (e.g. Full, Dipping)")
        sp.add_argument("--out-base", help="Output base path (without extension)")
        sp.add_argument("--dry-run", action="store_true", help="Print paths without converting")
        sp.add_argument("--overwrite", action="store_true", help="Overwrite existing .spo/.res files")
        sp.add_argument("--backend", choices=["pyspextools", "trafo"], default="pyspextools", 
                        help="Conversion engine to use (default: pyspextools)")
        if instr == "rgs":
            sp.add_argument("--multi-sector", action="store_true",
                            help="Place RGS1 in Sector 1 and RGS2 in Sector 2 (for cross-calibration)")
            sp.add_argument("--orders", default="1,2",
                            help="Comma-separated RGS orders to include (default: 1,2)")

    args = p.parse_args(argv)
    try:
        return _run_conversion(args)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
