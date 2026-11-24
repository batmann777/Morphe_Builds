# Morphe_Builds

Automated Morphe-patched APKs for my phone — **arm64-v8a, non-root**.

## Apps built

| App | Recommended version | Patches source |
|---|---|---|
| YouTube | 21.30.216 | Morphe Patches (117 patches) |
| YT Music | 9.30.53 | Morphe Patches (56 patches) |
| Reddit | 2026.40.0 | Morphe Patches (30 patches) |
| Google Photos | 7.92.0.977185651 | De-Vanced Patches (3 patches — Photos isn't covered by official Morphe patches) |

Versions are not hardcoded — the builder asks the Morphe CLI
(`list-versions`) what each patch bundle currently recommends.

## How it works

A GitHub Actions workflow (`.github/workflows/build-youtube-morphe.yml`) runs
**daily at 09:00 IST** and executes [`scripts/build.sh`](scripts/build.sh),
which for each app:

1. Checks the latest stable releases of
   [Morphe Desktop](https://github.com/MorpheApp/morphe-desktop),
   [Morphe Patches](https://github.com/MorpheApp/morphe-patches) and
   [De-Vanced Patches](https://github.com/RookieEnough/De-Vanced)
   (downloads verified against the SHA-256 digests GitHub publishes).
2. Works out the recommended app version for the current patch bundles.
3. If that combination hasn't been released here yet, downloads the stock
   APK from the archive.org `jhc-apks` archive (the same source the
   community builders use; size-verified), patches it with the default
   patch set, strips every ABI except **arm64-v8a**, verifies the result,
   and signs it.
4. Publishes a **GitHub Release** per app, tagged
   `<app>-<version>-patches-<patchver>-desktop-<desktopver>`, with the
   patched APK attached (plus Morphe MicroG-RE for the apps that need it
   for sign-in: YouTube, YT Music, Google Photos).

If nothing changed for an app, it's skipped. If one app fails (e.g. a new
recommended version isn't in the stock archive yet), the others still
publish and the failed one retries on the next daily run. You can also
trigger a build manually from the **Actions** tab
(*Build YouTube Morphe → Run workflow*, with an optional force-rebuild).

## Install on the phone

- **YouTube / YT Music / Google Photos:** install the **MicroG-RE** APK
  from the release first (required for Google sign-in on non-root), then
  the patched APK, then sign in via MicroG.
- **Reddit:** just install the patched APK and sign in as usual.

## Signing

All builds are signed with the keystore in [`keystore/`](keystore/)
(base64-encoded so it can live in git; password `morphe-builds`, alias
`Morphe`). Using one fixed keystore means every new release installs over
the previous one — no uninstall/reinstall dance. This key only signs these
personal sideload builds; don't reuse it for anything else.

## Notes

- For personal use. YouTube, YT Music, Google Photos and Reddit are
  trademarks of their respective owners; Morphe patches are GPLv3, from
  the MorpheApp project; De-Vanced patches are by RookieEnough.
