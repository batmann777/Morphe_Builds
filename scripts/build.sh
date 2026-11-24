#!/usr/bin/env bash
# Daily Morphe multi-app builder — ONE combined release.
# Checks Morphe Desktop + patch bundle releases, resolves the recommended
# version of each app, patches whatever is new (arm64-v8a, non-root, default
# patches) and publishes everything in a SINGLE GitHub Release per
# patch-bundle combination, tagged:
#   build-<desktopVer>-<morphePatchesVer>-<devancedVer>
#
# Apps:
#   YouTube       com.google.android.youtube             Morphe patches
#   YT Music      com.google.android.apps.youtube.music  Morphe patches
#   Reddit        com.reddit.frontpage                   Morphe patches
#   Google Photos com.google.android.apps.photos         De-Vanced patches
#                 (Photos is not covered by official Morphe patches)
set -uo pipefail

ARCH="arm64-v8a"
FORCE="${FORCE:-false}"
REPO="${GITHUB_REPOSITORY:-batmann777/Morphe_Builds}"
FAILED=()
BUILT=()
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

fetch_bundle() { # fetch_bundle <repo> <json-out> -> prints "<ver> <file> <url> <digest>"
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

TAG="build-${DESKTOP_VER}-${MORPHE_PATCHES_VER}-${DEVANCED_VER}"
TITLE="Morphe Builds — Desktop v${DESKTOP_VER} · Patches v${MORPHE_PATCHES_VER} · De-Vanced v${DEVANCED_VER}"
echo "Combined release tag: $TAG"

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
echo "MicroG-RE: $MICROG_NAME"

echo "== Preparing signing keystore =="
base64 -d "$(pwd)/../keystore/morphe.keystore.b64" > morphe.keystore 2>/dev/null || \
  base64 -d "${GITHUB_WORKSPACE:-..}/keystore/morphe.keystore.b64" > morphe.keystore || { echo "ERROR: cannot decode keystore"; exit 1; }

recommended_version() { # recommended_version <bundle-file> <package>
  java -jar "$JAR_NAME" list-versions --patches="$1" -f "$2" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1
}

echo "== Checking existing combined release =="
EXISTING_ASSETS=""
RELEASE_EXISTS="no"
if api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" > existing-release.json 2>/dev/null; then
  RELEASE_EXISTS="yes"
  EXISTING_ASSETS="$(python3 -c "
import json
d = json.load(open('existing-release.json'))
print('\n'.join(a['name'] for a in d.get('assets', [])))
")"
  echo "Release $TAG exists with assets:"
  echo "$EXISTING_ASSETS"
else
  echo "Release $TAG does not exist yet."
fi

asset_present() { # asset_present <filename>
  [ "$RELEASE_EXISTS" = "yes" ] && printf '%s\n' "$EXISTING_ASSETS" | grep -qxF "$1"
}

# build_one <slug> <display> <prefix> <package> <bundle-file> <stock-suffix>
# On success: sets global OUT_FILE. On skip: returns 2. On failure: returns 1.
build_one() {
  local slug="$1" display="$2" prefix="$3" pkg="$4" bundle="$5" suffix="$6"
  echo ""
  echo "######## $display ########"

  local ver
  ver="$(recommended_version "$bundle" "$pkg")"
  if [ -z "$ver" ]; then echo "ERROR: no recommended version for $pkg"; return 1; fi
  echo "Recommended $display: $ver"
  eval "VER_${slug}=\"$ver\""

  OUT_FILE="${prefix}-Morphe-${ver}-${ARCH}.apk"
  if [ "$FORCE" != "true" ] && asset_present "$OUT_FILE"; then
    echo "UP-TO-DATE: $OUT_FILE already in release $TAG. Skipping."
    SKIPPED+=("$display $ver")
    return 2
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
  # Keep the real extension (.apk/.apkm): the patcher detects bundles by extension.
  local stock="stock-${slug}-${ver}.${suffix##*.}"
  curl -sfL -o "$stock" "https://archive.org/download/jhc-apks/${stock_path}" || { echo "ERROR: stock download failed"; return 1; }
  local actual
  actual="$(stat -c%s "$stock")"
  if [ "$actual" != "$expected" ]; then echo "ERROR: stock size mismatch: $actual != $expected"; return 1; fi
  python3 -c "import sys; sys.exit(0 if open('$stock','rb').read(2)==b'PK' else 1)" || { echo "ERROR: stock file is not an APK/bundle"; return 1; }
  echo "Stock OK ($actual bytes)"

  java -Xmx6g -jar "$JAR_NAME" patch \
    -p "$bundle" \
    --striplibs "$ARCH" \
    --keystore="$(pwd)/morphe.keystore" \
    --keystore-password="morphe-builds" \
    --keystore-entry-password="morphe-builds" \
    --keystore-entry-alias="Morphe" \
    -o "$OUT_FILE" \
    "$stock" || { echo "ERROR: patching $display failed"; return 1; }

  python3 - "$OUT_FILE" <<'PY' || { echo "ERROR: patched APK ABI check failed"; return 1; }
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1])
abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
print('Patched APK lib ABIs:', abis)
sys.exit(0 if all(a == 'arm64-v8a' for a in abis) else 1)
PY

  echo "Patched: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
  BUILT+=("$display $ver")
  return 0
}

UPLOADS=()
STALE_PREFIXES=()

run_app() { # run_app <slug> <display> <prefix> <package> <bundle> <suffix>
  local slug="$1" display="$2" prefix="$3"
  build_one "$@"
  local rc=$?
  if [ $rc -eq 0 ]; then
    UPLOADS+=("$OUT_FILE")
    STALE_PREFIXES+=("$prefix")
  elif [ $rc -eq 1 ]; then
    FAILED+=("$display")
  fi
}

run_app "yt"     "YouTube"       "YouTube" "com.google.android.youtube"             "$MPP_NAME" "all.apk"
run_app "ytmusic" "YT Music"      "YTMusic" "com.google.android.apps.youtube.music" "$MPP_NAME" "arm64-v8a.apk"
run_app "reddit" "Reddit"        "Reddit"  "com.reddit.frontpage"                  "$MPP_NAME" "all.apkm"
run_app "photos" "Google Photos" "Photos"  "com.google.android.apps.photos"        "$DV_NAME"  "all.apk"

# MicroG goes into the combined release once.
MICROG_STALE="no"
if [ "$FORCE" = "true" ] || ! asset_present "$MICROG_NAME"; then
  curl -sfL -o "$MICROG_NAME" "$MICROG_URL" || { echo "ERROR: cannot download MicroG"; FAILED+=("MicroG"); }
  if [ -f "$MICROG_NAME" ]; then
    UPLOADS+=("$MICROG_NAME")
    MICROG_STALE="yes"
  fi
else
  echo "MicroG $MICROG_NAME already in release. Skipping."
fi

if [ "${#UPLOADS[@]}" -eq 0 ] && [ "${#FAILED[@]}" -eq 0 ]; then
  echo ""
  echo "UP-TO-DATE: combined release $TAG already has every current app. Nothing to do."
  exit 0
fi

if [ "${#UPLOADS[@]}" -eq 0 ]; then
  echo ""
  echo "ERROR: every build failed; not touching the release."
  exit 1
fi

echo ""
echo "== Publishing combined release $TAG =="
if [ "$RELEASE_EXISTS" != "yes" ]; then
  gh release create "$TAG" --title "$TITLE" --notes "Building…" || { echo "ERROR: cannot create release"; exit 1; }
  RELEASE_EXISTS="yes"
fi

# Remove stale assets for rebuilt apps (older versions of the same app).
if [ "$RELEASE_EXISTS" = "yes" ] && [ -n "$EXISTING_ASSETS" ]; then
  while IFS= read -r old; do
    [ -z "$old" ] && continue
    for p in "${STALE_PREFIXES[@]}"; do
      case "$old" in
        "${p}-Morphe-"*)
          keep="no"
          for u in "${UPLOADS[@]}"; do [ "$u" = "$old" ] && keep="yes"; done
          if [ "$keep" = "no" ]; then
            echo "Deleting stale asset: $old"
            gh release delete-asset "$TAG" "$old" --yes 2>/dev/null || gh release delete-asset "$TAG" "$old" || true
          fi
          ;;
      esac
    done
    if [ "$MICROG_STALE" = "yes" ]; then
      case "$old" in
        microg-*.apk)
          if [ "$old" != "$MICROG_NAME" ]; then
            echo "Deleting stale MicroG asset: $old"
            gh release delete-asset "$TAG" "$old" --yes 2>/dev/null || gh release delete-asset "$TAG" "$old" || true
          fi
          ;;
      esac
    fi
  done <<< "$EXISTING_ASSETS"
fi

gh release upload "$TAG" "${UPLOADS[@]}" --clobber || { echo "ERROR: asset upload failed"; exit 1; }

echo "== Writing combined release notes =="
api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" > final-release.json || { echo "ERROR: cannot read back release"; exit 1; }
python3 - > notes.md <<PY
import json
d = json.load(open('final-release.json'))
assets = {a['name']: a for a in d.get('assets', [])}
apps = [
    ("YouTube", "Morphe Patches v$MORPHE_PATCHES_VER", "${VER_yt:-}"),
    ("YT Music", "Morphe Patches v$MORPHE_PATCHES_VER", "${VER_ytmusic:-}"),
    ("Reddit", "Morphe Patches v$MORPHE_PATCHES_VER", "${VER_reddit:-}"),
    ("Google Photos", "De-Vanced Patches v$DEVANCED_VER", "${VER_photos:-}"),
]
prefix = {"YouTube": "YouTube", "YT Music": "YTMusic", "Reddit": "Reddit", "Google Photos": "Photos"}
print("## Morphe Builds — all apps, one release")
print()
print("Patched APKs for **arm64-v8a, non-root**, built automatically by the daily Morphe builder.")
print()
print(f"| Component | Version |")
print(f"|---|---|")
print(f"| Morphe Desktop (CLI) | v$DESKTOP_VER |")
print(f"| Morphe Patches | v$MORPHE_PATCHES_VER |")
print(f"| De-Vanced Patches (Photos) | v$DEVANCED_VER |")
print()
print("| App | Version | File | Size | SHA-256 |")
print("|---|---|---|---|---|")
for display, src, ver in apps:
    name = f"{prefix[display]}-Morphe-{ver}-arm64-v8a.apk"
    a = assets.get(name)
    if a:
        size = f"{a['size']/1e6:.1f} MB"
        digest = (a.get('digest') or '').removeprefix('sha256:')
        print(f"| {display} | {ver} | \`{name}\` | {size} | \`{digest}\` |")
    else:
        print(f"| {display} | {ver} | build pending/failed — retried on the next daily run | | |")
mg = assets.get("$MICROG_NAME")
if mg:
    print(f"| MicroG-RE | sign-in for non-root | \`$MICROG_NAME\` | {mg['size']/1e6:.1f} MB | \`{(mg.get('digest') or '').removeprefix('sha256:')}\` |")
print()
print("### Install")
print("- **YouTube / YT Music / Google Photos:** install MicroG-RE first, then the app's APK, then sign in via MicroG.")
print("- **Reddit:** install the APK and sign in as usual.")
print()
print("All builds are signed with the same keystore (see \`keystore/\` in this repo), so new releases install over previous ones.")
PY
gh release edit "$TAG" --title "$TITLE" --notes-file notes.md || { echo "ERROR: cannot update release notes"; exit 1; }

echo ""
echo "================ SUMMARY ================"
echo "Release: $TAG"
echo "Built & uploaded: ${BUILT[*]:-none}"
echo "Up-to-date: ${SKIPPED[*]:-none}"
echo "Failed: ${FAILED[*]:-none}"
if [ "${#FAILED[@]}" -gt 0 ]; then exit 1; fi
echo "All apps OK."
