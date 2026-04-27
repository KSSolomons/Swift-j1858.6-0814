"""Render a CLI-only SPEX batch workflow.

This module writes human-readable SPEX batch scripts and keeps the repository's
run-directory layout consistent across observations.

Grouping is always performed inside SPEX via `obin` rather than during the
OGIP-to-SPEX conversion step.  The converted .spo/.res files therefore
contain ungrouped (channel-level) data.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class WorkflowConfig:
    obsid: str
    instrument: str
    interval: str = "Full"

    thermal_model: str = "dbb"
    fit_iter_cap: int | None = 100
    spex_threads: int | None = 4
    overwrite_conversion: bool = False
    blind_search_run: bool = False
    blind_search_dlam: float = 0.05
    blind_search_max_points: int | None = 120
    blind_search_iter_cap: int | None = 8
    blind_search_refit_baseline: bool = False
    blind_search_make_plot: bool = False
    use_scientific_notation: bool = True


@dataclass(frozen=True)
class WorkflowPaths:
    repo_root: Path
    products_root: Path
    spex_out_base: Path
    interval_tag: str
    fit_artifact_dir: Path
    artifact_dirs: dict[str, Path] = field(default_factory=dict)


_GAL_NH = 0.002
_GAL_HOT_KT = 8.0e-4
_THERMAL_KT = 0.1
_THERMAL_NORM = 1.0e-3
_XABS_NH = 0.003
_XABS_XI = 2.0
_XABS_FCOV = 0.7
_POW_GAMMA = 2.0
_POW_NORM = 2.0e-2


def resolve_paths(repo_root: Path, cfg: WorkflowConfig) -> WorkflowPaths:
    spex_out_base = (
        repo_root / "products" / cfg.obsid / cfg.instrument / "spex"
        / f"{cfg.instrument}_{cfg.interval}_spex"
    )
    interval_tag = cfg.interval
    fit_artifact_dir = spex_out_base.parent / interval_tag
    artifact_dirs = {
        "logs": fit_artifact_dir / "logs",
        "tables": fit_artifact_dir / "fit_tables",
        "summaries": fit_artifact_dir / "summaries",
        "line_search": fit_artifact_dir / "line_search",
        "plots": fit_artifact_dir / "plots",
        "commands": fit_artifact_dir / "commands",
    }
    return WorkflowPaths(
        repo_root=repo_root,
        products_root=repo_root / "products",
        spex_out_base=spex_out_base,
        interval_tag=interval_tag,
        fit_artifact_dir=fit_artifact_dir,
        artifact_dirs=artifact_dirs,
    )


def _quote(path: Path) -> str:
    return f'"{path.as_posix()}"'


def _join_lines(lines: Iterable[str]) -> str:
    return "\n".join(lines).rstrip() + "\n"


def render_fit_script(cfg: WorkflowConfig, paths: WorkflowPaths) -> str:
    base_name = paths.spex_out_base.name
    log_filename = f"spex_output_{cfg.instrument}_{paths.interval_tag}.log"

    lines: list[str] = [
        "# Auto-generated SPEX batch script",
        f"# obsid={cfg.obsid} instrument={cfg.instrument} interval={cfg.interval}",
        f"# Grouping is performed by SPEX (obin) — input data is ungrouped.",
        f"# base_name={base_name}",
        "",
        f"log out {log_filename}",
        "",
        f"data ../{base_name} ../{base_name}",
        "",
    ]

    if cfg.instrument == "pn":
        lines += [
            "ign 0.0:0.8 unit k",
            "ign 7.0:100.0 unit k",
            "obin 1 1 0.8:7.0 unit k",
        ]
    elif cfg.instrument == "rgs":
        lines += [
            "ign  ins 1:4 0.0:5.0 unit a",
            "ign ins 1:4 25.0:100.0 unit a",
            "obin ins 1:4 5.0:25.0 unit a",
        ]
    else:
        raise ValueError("instrument must be 'pn' or 'rgs'")

    lines += [
        "var calc qc",
        "ions nmax all 5",
        "fit print 0",
        "",
        "com hot",
        "com xabs",
        "com dbb",
        "com pow",
        "com rel 3 1,2",
        "com rel 4 1,2",
        "par 1 1 t v 0.0008",
        "par 1 1 t stat frozen",
        "par 1 1 nh v 0.002",
        "par 1 1 nh stat frozen",
        "par 1 2 nh v 0.003",
        "par 1 2 nh stat frozen",
        "par 1 2 xil v 2.0",
        "par 1 2 xil stat frozen",
        "par 1 2 fcov v 0.7",
        "par 1 2 fcov stat frozen",
        "par 1 3 t v 0.2",
        "par 1 3 t stat frozen",
        "par 1 3 norm v 0.001",
        "par 1 3 norm stat frozen",
        "par 1 4 gamm v 2.0",
        "par 1 4 gamm stat frozen",
        "par 1 4 norm v 0.02",
        "par 1 4 norm stat thawn",
        "fit stat cstat",
        "fit iter 100",
        "fit",
        "",
        "# Stage 0b: thaw thermal component",
        "par 1 3 norm v 0.001",
        "par 1 3 norm stat thawn",
        "par 1 3 t stat thawn",
        "fit iter 100",
        "fit",
        "",
        "# Stage 1: thaw xabs NH",
        "par 1 2 nh v 0.003",
        "par 1 2 nh stat thawn",
        "fit iter 100",
        "fit",
        "",
        "# Stage 2: thaw xabs ionization",
        "par 1 2 xil v 2.0",
        "par 1 2 xil stat thawn",
    ]
    if cfg.fit_iter_cap is not None:
        lines.append(f"fit iter {int(cfg.fit_iter_cap)}")
    lines.append("fit")

    lines += [
        "",
        "# Stage 3: thaw xabs covering fraction",
        f"par 1 2 fcov v {_XABS_FCOV}",
        "par 1 2 fcov stat thawn",
    ]
    if cfg.fit_iter_cap is not None:
        lines.append(f"fit iter {int(cfg.fit_iter_cap)}")
    lines.append("fit")

    lines += [
        "",
        "# Best-effort report commands; adjust if your SPEX build uses different table output syntax.",
        "par show free",
        "",
        "# Save the final fit parameters",
        "par write ../best_fit_model overwrite",
        "",
        "# Create a plot and save it to a postscript file",
        "plot dev cps ../plots/fit_plot.ps",
        "plot type data",
        "plot x log",
        "plot y log",
        "plot set 1",
        "plot data col 1",
        "plot model col 2",
        "plot frame new",
        "plot frame 2",
        "plot type chi",
        "plot x log",
        "plot view def f",
        "plot view x 0.08:0.92",
        "plot view y 0.1:0.3",
        "plot frame 1",
        "plot view def f",
        "plot view x 0.08:0.92",
        "plot view y 0.3:0.9",
        "plot box numlab bot f",
        "plot",
        "plot close 1",
        "",
        "log close out",
        "quit",
    ]

    if cfg.blind_search_run:
        lines += [
            "",
            "# Blind-search scaffold: this is intentionally a placeholder batch section.",
            f"# d_lambda_angstrom={cfg.blind_search_dlam}",
            f"# max_grid_points={cfg.blind_search_max_points}",
            f"# fit_iter_cap={cfg.blind_search_iter_cap}",
            f"# refit_baseline={cfg.blind_search_refit_baseline}",
            f"# make_plot={cfg.blind_search_make_plot}",
            "# Expand this section with your local SPEX line-scan macro once your CLI syntax is locked down.",
        ]

    return _join_lines(lines)


def build_workflow(repo_root: Path, cfg: WorkflowConfig) -> tuple[WorkflowPaths, str]:
    paths = resolve_paths(repo_root, cfg)
    script = render_fit_script(cfg, paths)
    return paths, script


