#!/usr/bin/env bash
# Copies the assets of a published GitHub release to the Cloudreve mirror the app updates from (WebDAV).
#
#   WEBDAV_URL=… WEBDAV_USER=… WEBDAV_PASS=… GH_TOKEN=… scripts/mirror_release.sh v1.2.3
#
# Layout of the WebDAV root (the shared release folder):
#   v1.2.3/<asset>   every asset of the release
#   version.json     the tag's version.json plus "assets": name → size and SHA-256; written last, and only when the
#                    tag is not older than what it already names
# Only the newest KEEP release folders are kept.
set -euo pipefail

tag=${1:?usage: mirror_release.sh <tag>}
keep=${KEEP:-5}
repo=${GITHUB_REPOSITORY:-Carinoasd/tsdm_client}
: "${WEBDAV_URL:?}" "${WEBDAV_USER:?}" "${WEBDAV_PASS:?}"
base=${WEBDAV_URL%/}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dav() { curl -fsS --retry 3 --retry-all-errors -u "$WEBDAV_USER:$WEBDAV_PASS" "$@"; }

gh api "repos/$repo/releases/tags/$tag" > "$work/release.json"
mkdir "$work/assets"
gh release download "$tag" -R "$repo" -D "$work/assets"
git show "$tag:version.json" > "$work/repo-version.json"

# The mirror's version.json; every file must match GitHub's published size and digest.
python3 - "$tag" "$work" <<'EOF'
import hashlib, json, os, sys
tag, work = sys.argv[1], sys.argv[2]
release = json.load(open(f"{work}/release.json"))
info = json.load(open(f"{work}/repo-version.json"))
if release["tag_name"] != tag or release["draft"] or release["prerelease"] or info["version"] != tag[1:]:
    sys.exit(f"{tag}: not a published release of version.json's version")
assets = {}
for asset in release["assets"]:
    name = asset["name"]
    data = open(f"{work}/assets/{name}", "rb").read()
    sha = hashlib.sha256(data).hexdigest()
    if len(data) != asset["size"] or asset.get("digest") != f"sha256:{sha}":
        sys.exit(f"{name}: does not match the release")
    assets[name] = {"size": len(data), "sha256": sha}
info["assets"] = assets
json.dump(info, open(f"{work}/version.json", "w"), ensure_ascii=False, indent=2)
print(f"{tag}: {len(assets)} assets")
EOF

# MKCOL answers 405 when the folder exists.
dav -X MKCOL "$base/$tag/" -o /dev/null || true
for file in "$work"/assets/*; do
  name=$(basename "$file")
  dav -T "$file" "$base/$tag/$name" -o /dev/null
  size=$(dav -X PROPFIND -H 'Depth: 0' "$base/$tag/$name" | grep -o '<[^>]*getcontentlength>[0-9]*<' | grep -o '[0-9]*<' | tr -d '<')
  [[ "$size" == "$(stat -c %s "$file")" ]] || { echo "$name: uploaded size $size" >&2; exit 1; }
  echo "uploaded $tag/$name"
done

current=$(dav "$base/version.json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["versionCode"])' || echo 0)
new=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versionCode"])' "$work/version.json")
if (( new >= current )); then
  dav -T "$work/version.json" "$base/version.json" -o /dev/null
  echo "version.json → $tag"
else
  echo "version.json kept: mirror already names build $current"
fi

# Prune release folders beyond the newest $keep.
dav -X PROPFIND -H 'Depth: 1' "$base/" | python3 -c '
import re, sys, urllib.parse
names = {urllib.parse.unquote(m).rstrip("/").split("/")[-1] for m in re.findall(r"<[^>]*href>([^<]+)</", sys.stdin.read())}
tags = sorted((n for n in names if re.fullmatch(r"v\d+\.\d+\.\d+", n)), key=lambda n: tuple(map(int, n[1:].split("."))))
print("\n".join(tags[:-int(sys.argv[1])]))
' "$keep" | while read -r old; do
  [[ -n "$old" ]] || continue
  dav -X DELETE "$base/$old/" -o /dev/null
  echo "removed $old"
done
