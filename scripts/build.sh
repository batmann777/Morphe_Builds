#!/usr/bin/env bash
# Daily Morphe multi-app builder.
# Checks Morphe Desktop + patch bundle releases. For each app, if a release
# for the current combination does not exist yet in this repo, downloads the
# recommended stock APK, patches it for arm64-v8a (non-root, default patches)
# and publishes a GitHub Release.
#
# Apps:
#   YouTube      com.google.android.youtube             Morphe patches
#   YT Music     com.google.android.apps.youtube.music  Morphe patches
#   Reddit       com.reddit.frontpage                   Morphe patches
#   Google Photos com.google.android.apps.photos        De-Vanced patches
#                 (Photos is not covered by official Morphe patches)
set -uo pipefail

ARCH="arm64-v8a"
FORCE="${FORCE:-false}"
FAILED=()
SUCCEEDED=()
SKIPPED=()

WORK="$(pwd)/.build-work"
mkdir -p "$WORK" && cd "$WORK"

api() {
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -sfL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$1"
  else
    curl -sfL "$1"
  fi
}

verify_sha() { # verify_sha <file> <digest like sha256:abc...>
  if [ -n "$2" ]; then
    echo "${2#sha256:}  $1" | sha256sum -c -
  else
    echo "WARNING: no digest published for $1, skipping checksum verification"
  fi
}

echo "== Checking Morphe Desktop (latest stable) =="
api "https://api.github.com/repos/MorpheApp/morphe-desktop/releases/latest" > desktop.json || { echo "ERROR: cannot fetch Morphe Desktop release"; exit 1; }
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
curl -sfL -o "$JAR_NAME" "$JAR_URL" || { echo "ERROR: cannot download $JAR_NAME"; exit 1; }
verify_sha "$JAR_NAME" "$JAR_DIGEST" || { echo "ERROR: jar checksum mismatch"; exit 1; }
echo "Morphe Desktop: v$DESKTOP_VER"

fetch_bundle() { # fetch_bundle <repo> <json-out> -> prints "<ver> <file>"
  local repo="$1" out="$2"
  api "https://api.github.com/repos/${repo}/releases/latest" > "$out" || return 1
  python3 - "$out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ver = d['tag_name'].lstrip('v')
for a in d['assets']:
    if a['name'].endswith('.mpp'):
        print(ver, a['name'], a['browser_download_url'], a.get('digest',''))
        break
PY
}

echo "== Checking Morphe Patches (latest stable) =="
read -r MORPHE_PATCHES_VER MPP_NAME MPP_URL MPP_DIGEST < <(fetch_bundle "MorpheApp/morphe-patches" morphe-patches.json) || { echo "ERROR: cannot fetch Morphe patches"; exit 1; }
curl -sfL -o "$MPP_NAME" "$MPP_URL" || { echo "ERROR: cannot download $MPP_NAME"; exit 1; }
verify_sha "$MPP_NAME" "$MPP_DIGEST" || { echo "ERROR: patches checksum mismatch"; exit 1; }
echo "Morphe Patches: v$MORPHE_PATCHES_VER"

echo "== Checking De-Vanced Patches (for Google Photos) =="
read -r DEVANCED_VER DV_NAME DV_URL DV_DIGEST < <(fetch_bundle "RookieEnough/De-Vanced" devanced.json) || { echo "ERROR: cannot fetch De-Vanced patches"; exit 1; }
curl -sfL -o "$DV_NAME" "$DV_URL" || { echo "ERROR: cannot download $DV_NAME"; exit 1; }
verify_sha "$DV_NAME" "$DV_DIGEST" || { echo "ERROR: De-Vanced checksum mismatch"; exit 1; }
echo "De-Vanced Patches: v$DEVANCED_VER"

echo "== Fetching stock archive index (archive.org jhc-apks) =="
curl -sfL "https://archive.org/metadata/jhc-apks" > jhc.json || { echo "ERROR: cannot fetch archive index"; exit 1; }

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
curl -sfL -o "$MICROG_NAME" "$MICROG_URL" || { echo "ERROR: cannot download MicroG"; exit 1; }
echo "MicroG-RE: $MICROG_NAME"

echo "== Preparing signing keystore =="
base64 -d "$(pwd)/../keystore/morphe.keystore.b64" > morphe.keystore 2>/dev/null || \
  base64 -d "${GITHUB_WORKSPACE:-..}/keystore/morphe.keystore.b64" > morphe.keystore || { echo "ERROR: cannot decode keystore"; exit 1; }

recommended_version() { # recommended_version <bundle-file> <package>
  java -jar "$JAR_NAME" list-versions --patches="$1" -f "$2" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1
}

# build_app <slug> <display> <package> <bundle-file> <bundle-ver> <stock-suffix> <attach-microg:yes|no>
build_app() {
  local slug="$1" display="$2" pkg="$3" bundle="$4" bundle_ver="$5" suffix="$6" microg="$7"
  echo ""
  echo "######## $display ########"

  local ver
  ver="$(recommended_version "$bundle" "$pkg")"
  if [ -z "$ver" ]; then echo "ERROR: no recommended version for $pkg"; return 1; fi
  echo "Recommended $display: $ver"

  local tag="${slug}-${ver}-patches-${bundle_ver}-desktop-${DESKTOP_VER}"
  echo "Release tag: $tag"
  if [ "$FORCE" != "true" ] && gh release view "$tag" >/dev/null 2>&1; then
    echo "UP-TO-DATE: $tag already released. Skipping."
    SKIPPED+=("$display $ver")
    return 0
  fi

  local stock_path="apks/${pkg}/${pkg}-${ver}-${suffix}"
  local expected
  expected="$(python3 -c "
import json
d = json.load(open('jhc.json'))
for f in d.get('files', []):
    if f['name'] == '$stock_path':
        print(f['size']); break
else:
    print('')
")"
  if [ -z "$expected" ]; then
    echo "ERROR: stock file not in archive yet: $stock_path (daily run retries tomorrow)"
    return 1
  fi
  local stock="stock-${slug}-${ver}"
  curl -sfL -o "$stock" "https://archive.org/download/jhc-apks/${stock_path}" || { echo "ERROR: stock download failed"; return 1; }
  local actual
  actual="$(stat -c%s "$stock")"
  if [ "$actual" != "$expected" ]; then echo "ERROR: stock size mismatch: $actual != $expected"; return 1; fi
  python3 -c "import sys; sys.exit(0 if open('$stock','rb').read(2)==b'PK' else 1)" || { echo "ERROR: stock file is not an APK/bundle"; return 1; }
  echo "Stock OK ($actual bytes)"

  local out
  out="$(echo "$display" | tr -d ' ')-Morphe-${ver}-${ARCH}.apk"
  if [ "$display" = "YT Music" ]; then out="YTMusic-Morphe-${ver}-${ARCH}.apk"; fi
  if [ "$display" = "Google Photos" ]; then out="Photos-Morphe-${ver}-${ARCH}.apk"; fi

  java -Xmx6g -jar "$JAR_NAME" patch \
    -p "$bundle" \
    --striplibs "$ARCH" \
    --keystore="$(pwd)/morphe.keystore" \
    --keystore-password="morphe-builds" \
    --keystore-entry-password="morphe-builds" \
    --keystore-entry-alias="Morphe" \
    -o "$out" \
    "$stock" || { echo "ERROR: patching $display failed"; return 1; }

  python3 - "$out" <<'PY' || { echo "ERROR: patched APK ABI check failed"; return 1; }
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
print('Patched APK lib ABIs:', abis)
sys.exit(0 if all(a == 'arm64-v8a' for a in abis) else 1)
PY

  local out_sha out_size
  out_sha="$(sha256sum "$out" | awk '{print $1}')"
  out_size="$(du -h "$out" | cut -f1)"
  echo "Patched: $out ($out_size, sha256 $out_sha)"

  local notes="notes-${slug}.md"
  {
    echo "## $display Morphe $ver — arm64-v8a, non-root"
    echo ""
    echo "Built automatically by the daily Morphe builder."
    echo ""
    echo "| Component | Version |"
    echo "|---|---|"
    echo "| $display (stock, recommended) | $ver |"
    if [ "$bundle" = "$MPP_NAME" ]; then
      echo "| Morphe Patches | v$bundle_ver |"
    else
      echo "| De-Vanced Patches | v$bundle_ver |"
    fi
    echo "| Morphe Desktop (CLI) | v$DESKTOP_VER |"
    echo "| Architecture | arm64-v8a only (other ABIs stripped) |"
    echo ""
    echo "**Patched APK:** \`$out\` ($out_size)"
    echo "**SHA-256:** \`$out_sha\`"
    echo ""
    echo "### Install"
    if [ "$microg" = "yes" ]; then
      echo "1. Install \`$MICROG_NAME\` first (Morphe MicroG-RE) — required to sign in on a non-root phone."
      echo "2. Install \`$out\`."
      echo "3. Open the app and sign in via MicroG."
    else
      echo "1. Install \`$out\`."
      echo "2. Open the app and sign in with your account as usual."
    fi
    echo ""
    echo "All builds are signed with the same keystore (see \`keystore/\` in this repo), so new releases install over previous ones."
  } > "$notes"

  local assets=("$out")
  if [ "$microg" = "yes" ]; then assets+=("$MICROG_NAME"); fi

  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "${assets[@]}" --clobber || return 1
    gh release edit "$tag" --title "$display Morphe $ver (patches v$bundle_ver)" --notes-file "$notes" || return 1
  else
    gh release create "$tag" "${assets[@]}" \
      --title "$display Morphe $ver (patches v$bundle_ver)" \
      --notes-file "$notes" || return 1
  fi
  echo "PUBLISHED: $tag"
  SUCCEEDED+=("$display $ver")
  return 0
}

build_app "yt"     "YouTube"       "com.google.android.youtube"             "$MPP_NAME" "$MORPHE_PATCHES_VER" "all.apk"       "yes" || FAILED+=("YouTube")
build_app "ytmusic" "YT Music"      "com.google.android.apps.youtube.music" "$MPP_NAME" "$MORPHE_PATCHES_VER" "arm64-v8a.apk" "yes" || FAILED+=("YT Music")
build_app "reddit" "Reddit"        "com.reddit.frontpage"                  "$MPP_NAME" "$MORPHE_PATCHES_VER" "all.apkm"      "no"  || FAILED+=("Reddit")
build_app "photos" "Google Photos" "com.google.android.apps.photos"        "$DV_NAME"  "$DEVANCED_VER"       "all.apk"       "yes" || FAILED+=("Google Photos")

echo ""
echo "================ SUMMARY ================"
echo "Published: ${SUCCEEDED[*]:-none}"
echo "Up-to-date: ${SKIPPED[*]:-none}"
echo "Failed: ${FAILED[*]:-none}"
if [ "${#FAILED[@]}" -gt 0 ]; then exit 1; fi
echo "All apps OK."
