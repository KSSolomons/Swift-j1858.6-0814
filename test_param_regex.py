import re

lines = """
   1    1 hot  15   Abundance P           1.000000     frozen    0.0      1.00E+10
   1    2 xabs nh   X-Column (1E28/m**2) 9.8607700E-07 thawn     0.0      1.00E+20
   1    2 xabs xil  Log xi (1E-9 Wm)     -4.000000     thawn    -4.0       5.0
   1    4 pow  norm Norm (1E44 ph/s/keV)  793.4676     thawn     0.0      1.00E+20
   1    4 pow  gamm Photon index          2.000000     frozen   -10.       10.
"""

# Common report-table style rows for par show free
pattern = re.compile(
    r"^\s*(?P<sect>\d+)\s+(?P<comp>\d+)\s+(?P<mod>[A-Za-z][\w-]*)\s+(?P<name>[A-Za-z0-9_]+)\s+"
    r"(?P<desc>.*?)\s+"
    r"(?P<value>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)\s+"
    r"(?P<status>thawn|frozen)\s+"
    r"(?P<min>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)\s+"
    r"(?P<max>[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)$"
)

for line in lines.strip().splitlines():
    m = pattern.match(line)
    if m:
        print(f"Match: {m.groupdict()}")
    else:
        print(f"No match: '{line}'")

