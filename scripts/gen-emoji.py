#!/usr/bin/env python3
"""Builds hop/Resources/emoji.json from Unicode data: emoji-test.txt (order, groups,
skin-tone variants) and CLDR annotations in English and Slovenian (names, keywords).

Usage: scripts/gen-emoji.py [download-dir]

Downloads into a temporary directory unless one with the files is given. Only the
generated JSON is committed. Unicode and CLDR data are under the Unicode license
(https://www.unicode.org/license.txt).

Output, minified:
  {"v": 1, "groups": [name, ...], "bases": [modifier-base code points],
   "e": [[emoji, name, group, "en kw|...", "sl name|sl kw|...", tones], ...]}
The Slovenian name slot is always there, empty when CLDR has none. `tones` is 1 when putting a skin-tone modifier after every modifier base (dropping a
following U+FE0F; not one between two ZWJs) gives a fully-qualified emoji for all
five tones.
"""
import json
import os
import re
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

SOURCES = {
    "emoji-test.txt": "https://unicode.org/Public/emoji/latest/emoji-test.txt",
    "en.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/en.xml",
    "sl.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/sl.xml",
    "en-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/en.xml",
    "sl-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/sl.xml",
}
TONES = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
OUT = os.path.join(os.path.dirname(__file__), "..", "hop", "Resources", "emoji.json")


def fetch(directory):
    for name, url in SOURCES.items():
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            print(f"downloading {url}", file=sys.stderr)
            urllib.request.urlretrieve(url, path)


def annotations(*paths):
    """cp -> (tts name, [keywords]), the first file that has an entry wins."""
    out = {}
    for path in paths:
        for a in ET.parse(path).getroot().iter("annotation"):
            cp = a.get("cp")
            entry = out.setdefault(cp, [None, None])
            if a.get("type") == "tts":
                entry[0] = entry[0] or a.text.strip()
            else:
                entry[1] = entry[1] or [k.strip() for k in a.text.split("|") if k.strip()]
    return out


def lookup(table, emoji):
    return table.get(emoji) or table.get(emoji.replace("️", "")) or [None, None]


def with_tone(cps, tone, bases):
    out = []
    i = 0
    while i < len(cps):
        out.append(cps[i])
        # 🤝 inside 🧑‍🤝‍🧑 stays untoned: only bases at the ends of a ZWJ link take one.
        inside = 0 < i < len(cps) - 1 and cps[i - 1] == 0x200D and cps[i + 1] == 0x200D
        if cps[i] in bases and not inside:
            out.append(tone)
            if i + 1 < len(cps) and cps[i + 1] == 0xFE0F:
                i += 1
        i += 1
    return tuple(out)


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="hop-emoji-")
    fetch(directory)
    groups, entries, qualified = [], [], set()
    group = None
    line_re = re.compile(r"^([0-9A-F ]+?)\s*;\s*([a-z-]+)\s*#\s*\S+\s+E[\d.]+\s+(.+)$")
    with open(os.path.join(directory, "emoji-test.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("# group:"):
                group = line.split(":", 1)[1].strip()
                continue
            m = line_re.match(line.strip())
            if not m or m.group(2) != "fully-qualified":
                continue
            cps = tuple(int(c, 16) for c in m.group(1).split())
            qualified.add(cps)
            if group == "Component" or any(c in TONES for c in cps):
                continue
            if group not in groups:
                groups.append(group)
            entries.append((cps, groups.index(group), m.group(3)))

    # A modifier base is a single code point with a toned variant.
    bases = sorted({cps[0] for cps in qualified if len(cps) == 2 and cps[1] in TONES})
    base_set = set(bases)

    d = os.path.join
    en = annotations(d(directory, "en.xml"), d(directory, "en-derived.xml"))
    sl = annotations(d(directory, "sl.xml"), d(directory, "sl-derived.xml"))

    def dedupe(keywords, name):
        words = set(re.split(r"[\s:,]+", name.lower()))
        seen, out = set(), []
        for k in keywords or []:
            k = k.lower()
            if k in words or k in seen or k == name.lower():
                continue
            seen.add(k)
            out.append(k)
        return out

    rows = []
    for cps, g, test_name in entries:
        emoji = "".join(chr(c) for c in cps)
        en_name, en_kw = lookup(en, emoji)
        sl_name, sl_kw = lookup(sl, emoji)
        name = en_name or test_name
        sl_part = [sl_name or ""]  # the name slot stays, empty when CLDR has none
        tones = int(any(c in base_set for c in cps)
                    and all(with_tone(cps, t, base_set) in qualified for t in TONES))
        rows.append([emoji, name, g, "|".join(dedupe(en_kw, name)),
                     "|".join(sl_part + dedupe(sl_kw, sl_name or "")), tones])

    data = {"v": 1, "groups": groups, "bases": bases, "e": rows}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(rows)} emoji, {sum(r[5] for r in rows)} with skin tones, "
          f"{os.path.getsize(OUT) // 1024} KB -> {os.path.normpath(OUT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
