KEV_ANGSTROM = 12.398_419_75

def _build_pn_scan_grid(energy_min_keV: float, energy_max_keV: float, d_lambda_angstrom: float):
    energy = float(energy_min_keV)
    grid = []
    while energy < float(energy_max_keV):
        lam = KEV_ANGSTROM / energy
        grid.append((energy, lam))
        lam_next = lam - float(d_lambda_angstrom)
        if lam_next <= 0:
            break
        energy = KEV_ANGSTROM / lam_next
    return grid

grid = _build_pn_scan_grid(0.7, 7.0, 0.01)
print(len(grid))