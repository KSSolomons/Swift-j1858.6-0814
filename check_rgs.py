import xspec

xspec.Xset.chatter = 10
xspec.AllData("1:1 products/0865600201/rgs/time_intervals/Full/rgs1_src_o1_Full_grp.pha")
xspec.AllData(1).response = "products/0865600201/rgs/time_intervals/Full/rgs1_o1_Full.rmf"

# Print noticed channels initially
print("Initial noticed:", xspec.AllData(1).noticed)

xspec.Plot.xAxis = "ang"
xspec.AllData.ignore("**-5.0 25.0-**")
print("After ignore ang:", xspec.AllData(1).noticed)

xspec.AllData.notice("all")
xspec.Plot.xAxis = "keV"
xspec.AllData.ignore("**-0.496 2.48-**")
print("After ignore keV:", xspec.AllData(1).noticed)
