#!/usr/bin/env python3
"""Checks Localization/<lang>/*.strings.
  scripts/loc-check.py [lang]        keys translated differently in two files of that language (the merged table keeps
                                     only the last one)
  scripts/loc-check.py --all         the above for every language, plus each language against vi (the reference set):
                                     missing / extra keys and format specifiers (%@, %d, %%…) that don't match the key
Exit 1 when something is wrong."""
import re, sys, glob, os, collections
pair = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)
spec = re.compile(r'%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfFeEgGcCsSpaA%]')

def load(lang):
    seen = collections.defaultdict(dict)
    for f in sorted(glob.glob(f"Localization/{lang}/*.strings")):
        if f.endswith("InfoPlist.strings"): continue
        for k, v in pair.findall(open(f, encoding="utf-8").read()):
            seen[k][os.path.basename(f)] = v
    return seen

def conflicts(lang, seen):
    bad = {k: d for k, d in seen.items() if len(set(d.values())) > 1}
    for k, d in sorted(bad.items()):
        print(f'[{lang}] "{k}"'); [print(f"    {f}: {v}") for f, v in d.items()]
    return len(bad)

def specs(s): return sorted(re.sub(r'^%\d+\$', '%', x) for x in spec.findall(s))

def against_reference(lang, seen, ref):
    problems = 0
    for k in sorted(set(ref) - set(seen)): print(f'[{lang}] missing: "{k}"'); problems += 1
    for k in sorted(set(seen) - set(ref)): print(f'[{lang}] extra (not in vi): "{k}"'); problems += 1
    for k, d in seen.items():
        for f, v in d.items():
            if specs(k) != specs(v): print(f'[{lang}] format mismatch in {f}: "{k}" → "{v}"'); problems += 1
    return problems

if __name__ == "__main__":
    langs = [os.path.basename(d.rstrip("/")) for d in sorted(glob.glob("Localization/*/"))] if "--all" in sys.argv else [next((a for a in sys.argv[1:]), "vi")]
    ref = load("vi"); total = 0
    for lang in langs:
        seen = load(lang)
        n = conflicts(lang, seen) + (against_reference(lang, seen, ref) if "--all" in sys.argv and lang != "vi" else 0)
        if "--all" in sys.argv and lang == "vi":
            n += sum(1 for k, d in seen.items() for v in d.values() if specs(k) != specs(v) and not print(f'[vi] format mismatch: "{k}" → "{v}"'))
        print(f"{lang}: {len(seen)} keys, {n} problems"); total += n
    sys.exit(1 if total else 0)
