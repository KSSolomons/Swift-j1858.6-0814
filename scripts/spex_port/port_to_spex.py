#!/usr/bin/env python3
"""Config-light helpers to port OGIP spectra (PN/RGS) into SPEX .spo/.res files.

This script is intentionally conservative:
- It auto-resolves the naming scheme used by this repository.
- It can run as a dry-run to validate file discovery before conversion.
- It writes a JSON manifest for reproducibility.

Examples:
    python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --grouped --dry-run
    python scripts/spex_port/port_to_spex.py pn --obsid 0865600201 --interval Dipping --grouped
    python scripts/spex_port/port_to_spex.py rgs --obsid 0865600201 --interval Full --grouped --dry-run
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional


@dataclass
class PnDataset:
    spec: Path
    bkg: Path
    rmf: Path
    arf: Path


@dataclass
class RgsDataset:
    instrument: int
    order: int
    spec: Path
    bkg: Path
    rmf: Path


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


def resolve_pn_dataset(products_root: Path, obsid: str, interval: str, grouped: bool) -> PnDataset:
    pn_spec_dir = products_root / obsid / "pn" / "spec"
    flux_dir = pn_spec_dir / "flux_resolved"

    if interval == "Full":
        grouped_spec_names = ["pn_source_spectrum_grp.pha", "pn_source_spectrum_grp.fits"]
        ungrouped_spec_names = ["pn_source_spectrum.fits", "pn_source_spectrum.pha"]
        bkg_names = ["pn_bkg_spectrum.fits"]
        rmf_names = ["pn_rmf.rmf"]
        arf_names = ["pn_arf.arf"]
    else:
        grouped_spec_names = [f"pn_source_{interval}_grp.pha", f"pn_source_{interval}_grp.fits"]
        ungrouped_spec_names = [f"pn_source_{interval}.fits", f"pn_source_{interval}.pha"]
        bkg_names = [f"pn_bkg_{interval}.fits"]
        rmf_names = [f"pn_rmf_{interval}.rmf", "pn_rmf.rmf"]
        arf_names = [f"pn_arf_{interval}.arf", "pn_arf.arf"]

    spec_candidates: list[Path] = []
    chosen_spec_names = grouped_spec_names if grouped else ungrouped_spec_names
    for name in chosen_spec_names:
        spec_candidates.extend([pn_spec_dir / name, flux_dir / name])

    bkg_candidates: list[Path] = []
    rmf_candidates: list[Path] = []
    arf_candidates: list[Path] = []
    for name in bkg_names:
        bkg_candidates.extend([pn_spec_dir / name, flux_dir / name])
    for name in rmf_names:
        rmf_candidates.extend([pn_spec_dir / name, flux_dir / name])
    for name in arf_names:
        arf_candidates.extend([pn_spec_dir / name, flux_dir / name])

    spec = _first_existing(spec_candidates)
    bkg = _first_existing(bkg_candidates)
    rmf = _first_existing(rmf_candidates)
    arf = _first_existing(arf_candidates)

    missing = []
    if spec is None:
        missing.append("spec")
    if bkg is None:
        missing.append("bkg")
    if rmf is None:
        missing.append("rmf")
    if arf is None:
        missing.append("arf")

    if missing:
        raise FileNotFoundError(
            f"Missing PN files for interval={interval!r}, grouped={grouped}: {', '.join(missing)}"
        )

    # Narrow Optional[Path] -> Path for static type checkers.
    assert spec is not None and bkg is not None and rmf is not None and arf is not None
    return PnDataset(spec=spec, bkg=bkg, rmf=rmf, arf=arf)


def resolve_rgs_datasets(products_root: Path, obsid: str, interval: str, grouped: bool) -> list[RgsDataset]:
    rgs_root = products_root / obsid / "rgs"
    interval_dir = _find_interval_dir(rgs_root, interval)

    out: list[RgsDataset] = []
    for inst in (1, 2):
        for order in (1, 2):
            prefix = f"rgs{inst}_src_o{order}_{interval}"
            if grouped:
                spec_names = [f"{prefix}_grp.pha", f"{prefix}_grp.fits"]
            else:
                spec_names = [f"{prefix}.fits", f"{prefix}.pha"]

            bkg_names = [f"rgs{inst}_bkg_o{order}_{interval}.fits"]
            rmf_names = [f"rgs{inst}_o{order}_{interval}.rmf"]

            spec = _first_name_match(interval_dir, spec_names)
            bkg = _first_name_match(interval_dir, bkg_names)
            rmf = _first_name_match(interval_dir, rmf_names)

            # Keep going even if one pair is missing: users often have partial outputs.
            if spec is None or bkg is None or rmf is None:
                continue

            out.append(RgsDataset(instrument=inst, order=order, spec=spec, bkg=bkg, rmf=rmf))

    if not out:
        raise FileNotFoundError(
            f"No complete RGS datasets found in {interval_dir} for interval={interval!r}, grouped={grouped}."
        )

    return out


def _import_ogip_modules():
    try:
        import pyspextools.io as spio
        import pyspextools.io.ogip as ogip
    except Exception as exc:
        raise RuntimeError(
            "Could not import pyspextools. Activate the SPEX environment before running conversion."
        ) from exc
    return spio, ogip


def convert_pn_to_spex(dataset: PnDataset, out_base: Path, overwrite: bool, keep_grouping: bool = False) -> tuple[Path, Path]:
    spio, ogip = _import_ogip_modules()

    oregion = ogip.OGIPRegion()
    oregion.read_region(
        phafile=str(dataset.spec),
        rmffile=str(dataset.rmf),
        bkgfile=str(dataset.bkg),
        arffile=str(dataset.arf),
        grouping=keep_grouping,
    )
    oregion.ogip_to_spex()

    ds = spio.Dataset()
    ds.append_region(oregion, 1, 1)

    spo_path = out_base.with_suffix(".spo")
    res_path = out_base.with_suffix(".res")
    ds.write_all_regions(str(spo_path), str(res_path), overwrite=overwrite)
    return spo_path, res_path


def convert_rgs_to_spex(
    datasets: list[RgsDataset], out_base: Path, overwrite: bool, keep_grouping: bool = False
) -> tuple[Path, Path]:
    spio, ogip = _import_ogip_modules()

    ds = spio.Dataset()
    for region_idx, d in enumerate(datasets, start=1):
        oregion = ogip.OGIPRegion()
        oregion.read_region(
            phafile=str(d.spec),
            rmffile=str(d.rmf),
            bkgfile=str(d.bkg),
            grouping=keep_grouping,
        )
        oregion.ogip_to_spex()
        ds.append_region(oregion, 1, region_idx)

    spo_path = out_base.with_suffix(".spo")
    res_path = out_base.with_suffix(".res")
    ds.write_all_regions(str(spo_path), str(res_path), overwrite=overwrite)
    return spo_path, res_path


def write_manifest(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _default_pn_out_base(products_root: Path, obsid: str, interval: str, grouped: bool) -> Path:
    suffix = f"{interval}_grp" if grouped else interval
    group_dir = "grouped" if grouped else "ungrouped"
    return products_root / obsid / "pn" / "spex" / group_dir / f"pn_{suffix}_spex"


def _default_rgs_out_base(products_root: Path, obsid: str, interval: str, grouped: bool) -> Path:
    suffix = f"{interval}_grp" if grouped else interval
    group_dir = "grouped" if grouped else "ungrouped"
    return products_root / obsid / "rgs" / "spex" / group_dir / f"rgs_{suffix}_spex"


def _pn_command(args: argparse.Namespace) -> int:
    products_root = Path(args.products_root).expanduser().resolve()
    out_base = (
        Path(args.out_base).expanduser().resolve()
        if args.out_base
        else _default_pn_out_base(products_root, args.obsid, args.interval, args.grouped)
    )

    dataset = resolve_pn_dataset(products_root, args.obsid, args.interval, args.grouped)

    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "instrument": "pn",
        "obsid": args.obsid,
        "interval": args.interval,
        "grouped": args.grouped,
        "dry_run": args.dry_run,
        "dataset": {
            "spec": str(dataset.spec),
            "bkg": str(dataset.bkg),
            "rmf": str(dataset.rmf),
            "arf": str(dataset.arf),
        },
        "out_base": str(out_base),
    }

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    out_base.parent.mkdir(parents=True, exist_ok=True)
    spo_path, res_path = convert_pn_to_spex(
        dataset,
        out_base,
        overwrite=args.overwrite,
        keep_grouping=args.grouped,
    )
    manifest["outputs"] = {"spo": str(spo_path), "res": str(res_path)}

    write_manifest(out_base.with_suffix(".manifest.json"), manifest)
    print(f"Wrote: {spo_path}")
    print(f"Wrote: {res_path}")
    print(f"Wrote: {out_base.with_suffix('.manifest.json')}")
    return 0


def _rgs_command(args: argparse.Namespace) -> int:
    products_root = Path(args.products_root).expanduser().resolve()
    out_base = (
        Path(args.out_base).expanduser().resolve()
        if args.out_base
        else _default_rgs_out_base(products_root, args.obsid, args.interval, args.grouped)
    )

    datasets = resolve_rgs_datasets(products_root, args.obsid, args.interval, args.grouped)

    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "instrument": "rgs",
        "obsid": args.obsid,
        "interval": args.interval,
        "grouped": args.grouped,
        "dry_run": args.dry_run,
        "datasets": [
            {
                "instrument": d.instrument,
                "order": d.order,
                "spec": str(d.spec),
                "bkg": str(d.bkg),
                "rmf": str(d.rmf),
            }
            for d in datasets
        ],
        "out_base": str(out_base),
    }

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    out_base.parent.mkdir(parents=True, exist_ok=True)
    spo_path, res_path = convert_rgs_to_spex(
        datasets,
        out_base,
        overwrite=args.overwrite,
        keep_grouping=args.grouped,
    )
    manifest["outputs"] = {"spo": str(spo_path), "res": str(res_path)}

    write_manifest(out_base.with_suffix(".manifest.json"), manifest)
    print(f"Wrote: {spo_path}")
    print(f"Wrote: {res_path}")
    print(f"Wrote: {out_base.with_suffix('.manifest.json')}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Port OGIP PN/RGS products to SPEX .spo/.res")

    sub = p.add_subparsers(dest="instrument", required=True)

    pn = sub.add_parser("pn", help="Convert one PN interval to SPEX")
    pn.add_argument("--products-root", default="products", help="Path to products root (default: products)")
    pn.add_argument("--obsid", required=True)
    pn.add_argument("--interval", required=True, help="Examples: Full, Dipping, Persistent, Shallow, Dipping_HighFlux")
    pn.add_argument("--grouped", action="store_true")
    pn.add_argument("--out-base", help="Output base path without extension ('.spo' and '.res' added)")
    pn.add_argument("--dry-run", action="store_true", help="Resolve and print paths without conversion")
    pn.add_argument("--overwrite", action="store_true")
    pn.set_defaults(func=_pn_command)

    rgs = sub.add_parser("rgs", help="Convert one RGS interval to SPEX")
    rgs.add_argument("--products-root", default="products", help="Path to products root (default: products)")
    rgs.add_argument("--obsid", required=True)
    rgs.add_argument("--interval", required=True, help="Examples: Full, Persistent, Dipping, Shallow, LowFlux, HighFlux")
    rgs.add_argument("--grouped", action="store_true")
    rgs.add_argument("--out-base", help="Output base path without extension ('.spo' and '.res' added)")
    rgs.add_argument("--dry-run", action="store_true", help="Resolve and print paths without conversion")
    rgs.add_argument("--overwrite", action="store_true")
    rgs.set_defaults(func=_rgs_command)

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        return args.func(args)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

