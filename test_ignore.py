import xspec

xspec.Xset.chatter = 10
print("Loading data...")
xspec.AllData("1:1 products/0865600201/rgs/rgs1_src_o1_Full_grp.pha")
s1 = xspec.AllData(1)
s1.response = "products/0865600201/rgs/rgs1_o1_Full.rmf"

print("Setting xAxis to ang...")
xspec.Plot.xAxis = "ang"
print("Ignoring **-5.0 25.0-** using AllData.ignore...")
xspec.AllData.ignore("**-5.0 25.0-**")

print("Noticed channels:")
print(s1.noticed)
