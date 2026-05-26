import re

text = """
 Fit method        : Classical Levenberg-Marquardt
 Fit statistic     : C-statistic
 Fit statistic used:     61484.84
 C-statistic       :     61484.84
 Expected C-stat   :       596.43 +/-        34.55
 Chi-squared value :     46511.81
 Degrees of freedom:       590
 W-statistic       :     35667.26
"""

_STAT_PATTERNS = {
    "cstat": re.compile(r"(?i)(?:c-statistic|cstat)[^\n:]*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "chisq": re.compile(r"(?i)(?:chi-squared|chi2)[^\n:]*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "wstat": re.compile(r"(?i)(?:w-statistic|wstat)[^\n:]*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "dof": re.compile(r"(?i)(?:degrees of freedom|dof)[^\n:]*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
    "nfree": re.compile(r"(?i)(?:free\s*parameters|n\s*free)[^\n:]*[:=]\s*([+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)"),
}

for k, pat in _STAT_PATTERNS.items():
    m = pat.search(text)
    print(f"{k}: {m.group(1) if m else None}")
