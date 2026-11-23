#!/usr/bin/env bash
# Daily Morphe YouTube builder.
# Checks Morphe Desktop + Morphe Patches latest stable releases.
# If a release for the current combination does not exist yet in this repo,
# downloads the recommended stock YouTube APK, patches it for arm64-v8a
# (non-root, default patches incl. GmsCore support) and publishes a GitHub
# Release with the patched APK + Morphe MicroG-RE APK attached.
set -euo pipefail

ARCH="arm64-v8a"
STRIP_KEEP="arm64-v8a"
PKG="com.google.android.youtube"
FORCE="${FORCE:-false}"

WORK="$(pwd)/.build-work"
mkdir -p "$WORK" && cd "$WORK"

api() {
  # api <url> -> stdout (authenticated when GH_TOKEN is present)
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -sfL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$1"
  else
    curl -sfL "$1"
  fi
}

echo "== Checking Morphe Desktop (latest stable) =="
api "https://api.github.com/repos/MorpheApp/morphe-desktop/releases/latest" > desktop.json
DESKTOP_VER="$(python3 -c "import json;d=json.load(open('desktop.json'));print(d['tag_name'].lstrip('v'))")"
python3 - <<'PY' > desktop-asset.txt
import json
d = json.load(open('desktop.json'))
for a in d['assets']:
    if a['name'].endswith('-all.jar'):
        print(a['name'], a['browser_download_url'], a.get('digest',''))
        break
PY
read -r JAR_NAME JAR_URL JAR_DIGEST < desktop-asset.txt
echo "Morphe Desktop: v$DESKTOP_VER ($JAR_NAME)"

echo "== Checking Morphe Patches (latest stable) =="
api "https://api.github.com/repos/MorpheApp/morphe-patches/releases/latest" > patches.json
PATCHES_VER="$(python3 -c "import json;d=json.load(open('patches.json'));print(d['tag_name'].lstrip('v'))")"
python3 - <<'PY' > patches-asset.txt
import json
d = json.load(open('patches.json'))
for a in d['assets']:
    if a['name'].endswith('.mpp'):
        print(a['name'], a['browser_download_url'], a.get('digest',''))
        break
PY
read -r MPP_NAME MPP_URL MPP_DIGEST < patches-asset.txt
echo "Morphe Patches: v$PATCHES_VER ($MPP_NAME)"

curl -sfL -o "$JAR_NAME" "$JAR_URL"
curl -sfL -o "$MPP_NAME" "$MPP_URL"

verify_sha() { # verify_sha <file> <digest like sha256:abc...>
  if [ -n "$2" ]; then
    echo "${2#sha256:}  $1" | sha256sum -c -
  else
    echo "WARNING: no digest published for $1, skipping checksum verification"
  fi
}
verify_sha "$JAR_NAME" "$JAR_DIGEST"
verify_sha "$MPP_NAME" "$MPP_DIGEST"

echo "== Determining recommended YouTube version =="
java -jar "$JAR_NAME" list-versions --patches="$MPP_NAME" -f "$PKG" 2>/dev/null | tee versions.txt
YT_VER="$(grep -oE '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' versions.txt | head -1 | tr -d '[:space:]')"
if [ -z "$YT_VER" ]; then echo "ERROR: could not parse recommended YouTube version"; exit 1; fi
echo "Recommended YouTube: $YT_VER"

TAG="yt-${YT_VER}-patches-${PATCHES_VER}-desktop-${DESKTOP_VER}"
echo "Release tag for this combination: $TAG"

if [ "$FORCE" != "true" ] && gh release view "$TAG" >/dev/null 2>&1; then
  echo "UP-TO-DATE: release $TAG already exists in this repo. Nothing to build."
  exit 0
fi

echo "== Downloading stock YouTube $YT_VER (universal, from archive.org jhc-apks) =="
STOCK="stock-youtube-${YT_VER}.apk"
STOCK_PATH="apks/${PKG}/${PKG}-${YT_VER}-all.apk"
curl -sfL "https://archive.org/metadata/jhc-apks" > jhc.json
EXPECTED_SIZE="$(python3 -c "
import json
d = json.load(open('jhc.json'))
want = '$STOCK_PATH'
for f in d.get('files', []):
    if f['name'] == want:
        print(f['size']); break
else:
    print('')
")"
if [ -z "$EXPECTED_SIZE" ]; then
  echo "ERROR: stock APK for YouTube $YT_VER not found in archive.org jhc-apks yet ($STOCK_PATH)."
  echo "The daily run will retry tomorrow; APKMirror is the manual fallback."
  exit 1
fi
curl -sfL -o "$STOCK" "https://archive.org/download/jhc-apks/${STOCK_PATH}"
ACTUAL_SIZE="$(stat -c%s "$STOCK")"
if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
  echo "ERROR: stock APK size mismatch: got $ACTUAL_SIZE, expected $EXPECTED_SIZE"; exit 1
fi
python3 -c "import sys; sys.exit(0 if open('$STOCK','rb').read(2)==b'PK' else 1)" || { echo "ERROR: stock download is not an APK/ZIP"; exit 1; }
echo "Stock APK OK ($ACTUAL_SIZE bytes)"

echo "== Fetching Morphe MicroG-RE (needed for sign-in on non-root) =="
api "https://api.github.com/repos/MorpheApp/MicroG-RE/releases/latest" > microg.json
python3 - <<'PY' > microg-asset.txt
import json, re
d = json.load(open('microg.json'))
for a in d['assets']:
    if re.fullmatch(r'microg-[0-9.]+\.apk', a['name']):
        print(a['name'], a['browser_download_url'])
        break
PY
read -r MICROG_NAME MICROG_URL < microg-asset.txt
curl -sfL -o "$MICROG_NAME" "$MICROG_URL"
echo "MicroG-RE: $MICROG_NAME"

echo "== Preparing signing keystore =="
base64 -d "$(pwd)/../keystore/morphe.keystore.b64" > morphe.keystore 2>/dev/null || \
  base64 -d "${GITHUB_WORKSPACE:-..}/keystore/morphe.keystore.b64" > morphe.keystore

echo "== Patching (default patches, non-root, keep libs: $STRIP_KEEP) =="
OUT="YouTube-Morphe-${YT_VER}-${ARCH}.apk"
java -Xmx6g -jar "$JAR_NAME" patch \
  -p "$MPP_NAME" \
  --striplibs "$STRIP_KEEP" \
  --keystore="$(pwd)/morphe.keystore" \
  --keystore-password="morphe-builds" \
  --keystore-entry-password="morphe-builds" \
  --keystore-entry-alias="Morphe" \
  -o "$OUT" \
  "$STOCK"

python3 - <<PY
import zipfile, sys
z = zipfile.ZipFile('$OUT')
abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
print('Patched APK lib ABIs:', abis)
sys.exit(0 if abis == ['$ARCH'] else 1)
PY
OUT_SHA="$(sha256sum "$OUT" | awk '{print $1}')"
OUT_SIZE="$(du -h "$OUT" | cut -f1)"
echo "Patched APK: $OUT ($OUT_SIZE, sha256 $OUT_SHA)"

cat > notes.md <<EOF
## YouTube Morphe $YT_VER — arm64-v8a, non-root

Built automatically when a new Morphe release landed.

| Component | Version |
|---|---|
| YouTube (stock, recommended) | $YT_VER |
| Morphe Patches | v$PATCHES_VER |
| Morphe Desktop (CLI) | v$DESKTOP_VER |
| Architecture | arm64-v8a only (other ABIs stripped) |
| Patches | Default set (117), incl. GmsCore support for non-root |

**Patched APK:** \`$OUT\` ($OUT_SIZE)
**SHA-256:** \`$OUT_SHA\`

### Install
1. Install \`$MICROG_NAME\` first (Morphe MicroG-RE) — required to sign in on a non-root phone.
2. Install \`$OUT\`.
3. Open YouTube Morphe and sign in via MicroG.

Future builds are signed with the same keystore (see \`keystore/\` in this repo), so new releases install over this one without uninstalling.
EOF

echo "== Publishing release $TAG =="
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$OUT" "$MICROG_NAME" --clobber
  gh release edit "$TAG" --title "YouTube Morphe $YT_VER (patches v$PATCHES_VER)" --notes-file notes.md
else
  gh release create "$TAG" "$OUT" "$MICROG_NAME" \
    --title "YouTube Morphe $YT_VER (patches v$PATCHES_VER)" \
    --notes-file notes.md
fi
echo "DONE: release $TAG published."
