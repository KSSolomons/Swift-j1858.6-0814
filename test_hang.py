import xspec
xspec.Xset.chatter = 10
print("Defining model...")
m = xspec.Model("tbabs * (nthcomp + diskbb)")
print("Setting params...")
m(1).values = 0.25
print("Clearing models...")
xspec.AllModels.clear()
print("Suppressing chatter...")
xspec.Xset.chatter = 0
print("Redefining model...")
m2 = xspec.Model("tbabs * (nthcomp + diskbb)")
print("Done!")
