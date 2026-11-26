#!/usr/bin/env bash
# Copies the assets of a published GitHub release to the Cloudreve mirror the app updates from (WebDAV).
#
#   WEBDAV_URL=… WEBDAV_USER=… WEBDAV_PASS=… GH_TOKEN=… scripts/mirror_release.sh v1.2.3
#
# Layout of the WebDAV root (the shared release folder):
#   v1.2.3/<asset>   every asset of the release
#   version.json     the tag's version.json plus "assets": name → size and SHA-256; written last, and only when the
#                    tag is not older than what it already names
#   <platform>/<asset>  one shared folder per build holding only the newest release's file, for people who download
#                    by hand; refreshed along with version.json
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

# Names of the release folders on the mirror, oldest first.
folders() {
  dav -X PROPFIND -H 'Depth: 1' "$base/" | python3 -c '
import re, sys, urllib.parse
names = {urllib.parse.unquote(m).rstrip("/").split("/")[-1] for m in re.findall(r"<[^>]*href>([^<]+)</", sys.stdin.read())}
tags = sorted((n for n in names if re.fullmatch(r"v\d+\.\d+\.\d+", n)), key=lambda n: tuple(map(int, n[1:].split("."))))
print("\n".join(tags))
'
}
newer_or_same() { python3 -c 'import sys; a,b=(tuple(map(int,x[1:].split("."))) for x in sys.argv[1:]); sys.exit(a<b)' "$1" "$2"; }

# A tag older than every kept folder would be pruned right after its upload.
listing=$(folders)
mapfile -t existing <<< "$listing"
[[ -n "$listing" ]] || existing=()
if (( ${#existing[@]} >= keep )) && ! newer_or_same "$tag" "${existing[-keep]}"; then
  echo "$tag is older than the $keep newest mirrored releases; nothing to do"
  exit 0
fi

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
info["published"] = release["published_at"]
json.dump(info, open(f"{work}/version.json", "w"), ensure_ascii=False, indent=2)
print(f"{tag}: {len(assets)} assets")
EOF

# MKCOL answers 405 when the folder exists: no retries for it.
curl -sS -u "$WEBDAV_USER:$WEBDAV_PASS" -X MKCOL "$base/$tag/" -o /dev/null

# Uploads a file and checks the size the mirror reports for it.
copy_checked() {
  local file=$1 path=$2 size expected
  dav -T "$file" "$base/$path" -o /dev/null
  dav -X PROPFIND -H 'Depth: 0' "$base/$path" > "$work/prop.xml"
  size=$(python3 -c '
import re, sys
m = re.search(r"getcontentlength[^>]*>\s*(\d+)\s*<", open(sys.argv[1], errors="replace").read(), re.I)
print(m.group(1) if m else "")
' "$work/prop.xml")
  expected=$(stat -c %s "$file")
  if [[ "$size" != "$expected" ]]; then
    echo "$path: uploaded size '$size', expected $expected" >&2
    head -c 1500 "$work/prop.xml" >&2
    exit 1
  fi
  echo "uploaded $path"
}

# The release's file goes in next to nothing else: every other file in the folder is removed after it is in place.
declare -A platform=(
  [tsdm_client-arm64_v8a.apk]=Android-arm64
  [tsdm_client-universal.apk]=Android-universal
  [tsdm_client-armeabi_v7a.apk]=Android-armeabi-v7a
  [tsdm_client.ipa]=iOS
  [tsdm_client-windows.zip]=Windows
  [tsdm_client-universal.dmg]=macOS
  [tsdm_client-linux.tar.gz]=Linux
)
latest_folders() {
  local version=${tag#v} name folder file stale
  for name in "${!platform[@]}"; do
    folder=${platform[$name]}
    [[ -f "$work/assets/$name" ]] || continue
    file=${name/tsdm_client/tsdm_client-$version}
    curl -sS -u "$WEBDAV_USER:$WEBDAV_PASS" -X MKCOL "$base/$folder/" -o /dev/null
    copy_checked "$work/assets/$name" "$folder/$file"
    dav -X PROPFIND -H 'Depth: 1' "$base/$folder/" | python3 -c '
import re, sys, urllib.parse
folder, keep = sys.argv[1], sys.argv[2]
for href in re.findall(r"<[^>]*href>([^<]+)</", sys.stdin.read()):
    name = urllib.parse.unquote(href).rstrip("/").split("/")[-1]
    if name not in (folder, keep):
        print(name)
' "$folder" "$file" | while IFS= read -r stale; do
      dav -X DELETE "$base/$folder/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$stale")" -o /dev/null
      echo "removed $folder/$stale"
    done
  done
}

for file in "$work"/assets/*; do
  copy_checked "$file" "$tag/$(basename "$file")"
done

# Only a missing version.json counts as build 0; any other failure stops here rather than risk going back.
status=$(curl -sS --retry 3 -u "$WEBDAV_USER:$WEBDAV_PASS" -o "$work/current.json" -w '%{http_code}' "$base/version.json")
case $status in
  200) current=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versionCode"])' "$work/current.json") ;;
  404) current=0 ;;
  *) echo "reading the mirror's version.json: HTTP $status" >&2; exit 1 ;;
esac
new=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versionCode"])' "$work/version.json")
if (( new >= current )); then
  dav -T "$work/version.json" "$base/version.json" -o /dev/null
  echo "version.json → $tag"
  latest_folders
else
  echo "version.json kept: mirror already names build $current"
fi

# Prune release folders beyond the newest $keep.
listing=$(folders)
mapfile -t existing <<< "$listing"
[[ -n "$listing" ]] || existing=()
(( ${#existing[@]} > keep )) || exit 0
for old in "${existing[@]:0:${#existing[@]}-keep}"; do
  [[ "$old" == "$tag" ]] && continue
  dav -X DELETE "$base/$old/" -o /dev/null
  echo "removed $old"
done
