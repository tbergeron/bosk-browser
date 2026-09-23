"""Prints hitches from an Animation Hitches trace, and which of them fall inside
Bosk's "Sidebar fold" signpost intervals or within 100 ms after a "Tab switch" event."""
import re
import subprocess
import sys

trace = sys.argv[1]


def export(schema):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    return subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                          capture_output=True, text=True).stdout


def rows(xml):
    """Each row as a list of (tag, display value, raw value). Resolves id/ref pairs."""
    ids = {}
    result = []
    for row in xml.split("<row>")[1:]:
        values = []
        for m in re.finditer(r'<([\w-]+) (?:id="(\d+)" fmt="([^"]*)"(?:>([^<]*))?|ref="(\d+)")', row):
            tag, ident, fmt, raw, ref = m.groups()
            if ref:
                values.append((tag,) + ids.get(ref, ("", "")))
            else:
                ids[ident] = (fmt, raw or "")
                values.append((tag, fmt, raw or ""))
        result.append(values)
    return result


def first(values, tag):
    return next((raw for t, _, raw in values if t == tag), None)


hitches = [(int(first(v, "start-time")), int(first(v, "duration")))
           for v in rows(export("hitches")) if first(v, "start-time")]

intervals, events = [], []
for v in rows(export("os-signpost")):
    names = [fmt for t, fmt, _ in v if t in ("string", "signpost-name")]
    kinds = [fmt for t, fmt, _ in v if t == "event-type"]
    time = first(v, "event-time") or first(v, "start-time")
    if not time or not names:
        continue
    name = next((n for n in names if n in ("Sidebar fold", "Tab switch")), None)
    if name == "Tab switch":
        events.append(int(time))
    elif name == "Sidebar fold":
        intervals.append((kinds[0] if kinds else "", int(time)))

folds, begin = [], None
for kind, time in sorted(intervals, key=lambda x: x[1]):
    if kind == "Begin":
        begin = time
    elif kind == "End" and begin is not None:
        folds.append((begin, time))
        begin = None

ms = lambda ns: round(ns / 1e6, 1)
print(f"{len(folds)} sidebar animations, {len(events)} tab switches, {len(hitches)} hitches in total")
during_fold = [(ms(s), ms(d)) for s, d in hitches if any(a - 20e6 <= s <= b for a, b in folds)]
after_switch = [(ms(s), ms(d)) for s, d in hitches if any(e <= s <= e + 100e6 for e in events)]
print("hitches during sidebar animations (start ms, duration ms):", during_fold)
print("hitches within 100 ms after a tab switch:", after_switch)
