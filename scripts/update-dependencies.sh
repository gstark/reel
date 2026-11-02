#!/bin/bash
# Move libmpv, FFmpeg, and the other media libraries to their newest versions.
# They all come from one MPVKit release, so this changes the MPVKit version in project.yml.
# Usage: scripts/update-dependencies.sh [tag]   (no tag = newest MPVKit release)
#
# MPVKit marks its FFmpeg update builds (tags like 1.1.0-n9.0.2) as prereleases,
# so this takes the newest release of any kind, not GitHub's "latest".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
API=https://api.github.com/repos/mpvkit/MPVKit/releases

if [ $# -gt 0 ]; then
    release=$(/usr/bin/curl -fsSL "$API/tags/$1")
else
    release=$(/usr/bin/curl -fsSL "$API?per_page=1")
fi
# Prints the tag on the first line, then the version lines from the release notes.
summary=$(echo "$release" | /usr/bin/python3 -c '
import json, re, sys
r = json.load(sys.stdin)
r = r[0] if isinstance(r, list) else r
print(r["tag_name"])
for line in r.get("body", "").splitlines():
    m = re.match(r"\s*\*\s*(\w[\w ]*) version:\s*(\S+)", line)
    if m:
        print(f"  {m.group(1)}: {m.group(2)}")
')
current=$(/usr/bin/sed -n 's/^ *exactVersion: *//p' project.yml)
latest=$(echo "$summary" | /usr/bin/head -1)

if [ "$current" = "$latest" ]; then
    echo "MPVKit is already at $current:"
    echo "$summary" | /usr/bin/tail -n +2
    exit 0
fi

/usr/bin/sed -i '' "s/^\( *exactVersion: *\).*/\1$latest/" project.yml
/opt/homebrew/bin/xcodegen generate --quiet
/usr/bin/xcodebuild -resolvePackageDependencies -project Reel.xcodeproj -scheme Reel -derivedDataPath build -quiet
echo "MPVKit: $current -> $latest"
echo "$summary" | /usr/bin/tail -n +2
echo "Release notes: https://github.com/mpvkit/MPVKit/releases/tag/$latest"
