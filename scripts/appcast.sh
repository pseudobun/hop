#!/usr/bin/env bash
# Puts a release at the top of a Sparkle appcast, keeping the newest 20.
# Usage: scripts/appcast.sh <appcast.xml> <version> <build> <zip url> <"sparkle:edSignature=… length=…"> [notes.md]
# notes.md (this version's CHANGELOG section) becomes the notes Sparkle shows; without it, a link.
# A prerelease (a version with "-") goes into Sparkle's `beta` channel, which only hops following
# betas see (`updates.channel`); stable versions stay in the default channel everyone sees. Until
# the appcast has a stable version, betas stay in the default channel too: every hop out there is
# a beta then, and those before 0.1.0 don't know channels.
set -euo pipefail
file="$1" version="$2" build="$3" url="$4" sig="$5" notes_md="${6:-}"
channel=""
case "$version" in *-*) channel="
      <sparkle:channel>beta</sparkle:channel>" ;; esac
min_os="26.0"
date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
notes="https://github.com/pseudobun/hop/releases/tag/v$version"

item="    <item>
      <title>hop $version</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>$channel
      @NOTES@
      <enclosure url=\"$url\" type=\"application/octet-stream\" $sig/>
    </item>"

if [ ! -s "$file" ]; then
  cat > "$file" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>hop</title>
    <link>https://github.com/pseudobun/hop</link>
    <description>hop releases</description>
    <language>en</language>
  </channel>
</rss>
XML
fi

python3 - "$file" "$item" "$version" "$notes" "$notes_md" <<'PY'
import html, re, sys
path, item, version, link, notes_md = sys.argv[1:]

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)

def to_html(md):
    out, in_list, para = [], False, []
    def flush():
        nonlocal para
        if para: out.append("<p>" + inline(" ".join(para)) + "</p>"); para = []
    for raw in md.splitlines():
        line = raw.rstrip()
        m = re.match(r"^\s*[-*] (.*)", line)
        if m:
            flush()
            if not in_list: out.append("<ul>"); in_list = True
            out.append("<li>" + inline(m.group(1)) + "</li>")
            continue
        if raw.startswith("  ") and in_list and line.strip():
            out[-1] = out[-1][:-5] + " " + inline(line.strip()) + "</li>"
            continue
        if in_list and not line.strip():
            continue
        if in_list: out.append("</ul>"); in_list = False
        h = re.match(r"^(#{2,4}) (.*)", line)
        if h:
            flush(); out.append("<h3>" + inline(h.group(2)) + "</h3>")
        elif line.strip():
            para.append(line.strip())
        else:
            flush()
    flush()
    if in_list: out.append("</ul>")
    return "\n".join(out)

style = ("<style>body{font:13px -apple-system,sans-serif;margin:12px 14px;color:#222}"
         "h3{font-size:13px;margin:12px 0 4px}ul{padding-left:18px;margin:4px 0}li{margin:2px 0}"
         "code{font:12px ui-monospace,monospace}a{color:#0a64d0}"
         "@media(prefers-color-scheme:dark){body{color:#ddd}a{color:#6ab0ff}}</style>")
if notes_md and open(notes_md).read().strip():
    body = style + to_html(open(notes_md).read()) + f'<p><a href="{link}">Release on GitHub</a></p>'
    notes = "<description><![CDATA[" + body.replace("]]>", "]]&gt;") + "]]></description>"
else:
    notes = f"<sparkle:releaseNotesLink>{link}</sparkle:releaseNotesLink>"
item = item.replace("@NOTES@", notes)
xml = open(path).read()
items = re.findall(r"    <item>.*?</item>\n", xml, re.S)
if not re.search(r"<sparkle:shortVersionString>[^<-]+</sparkle:shortVersionString>", "".join(items)):
    item = re.sub(r"\n *<sparkle:channel>beta</sparkle:channel>", "", item)
items = [i for i in items if f"<sparkle:shortVersionString>{version}<" not in i]
items = ([item + "\n"] + items)[:20]
head = re.sub(r"    <item>.*?</item>\n", "", xml, flags=re.S)
xml = head.replace("  </channel>", "".join(items) + "  </channel>")
open(path, "w").write(xml)
PY
