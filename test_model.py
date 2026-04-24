import sys
print("Importing xspec...", flush=True)
import xspec
print("Clearing data...", flush=True)
xspec.AllData.clear()
xspec.AllModels.clear()
print("Loading model...", flush=True)
m = xspec.Model("tbabs * (nthcomp + diskbb)")
print("Done loading model!", flush=True)
