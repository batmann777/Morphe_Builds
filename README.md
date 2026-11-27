# Morphe_Builds

Automated Morphe-patched APKs for my phone — **arm64-v8a, non-root**.

## Apps built

| App | Recommended version | Patches source |
|---|---|---|
| YouTube | 21.30.216 | Morphe Patches (117 patches) |
| YT Music | 9.30.53 | Morphe Patches (56 patches) |
| Reddit | 2026.40.0 | Morphe Patches (30 patches) |
| Google Photos | 7.92.0.977185651 | De-Vanced Patches (3 patches — Photos isn't covered by official Morphe patches) |
| Gboard | 18.6.3.1002251336 | PixelBoard Patches (4 patches; installs as PixelBoard, `com.akshaykadam.pixelboard`, alongside the official Gboard) |

Versions are not hardcoded — the builder asks the Morphe CLI
(`list-versions`) what each patch bundle currently recommends.

## How it works

A GitHub Actions workflow (`.github/workflows/build-youtube-morphe.yml`) runs
**daily at 12:00 AM IST (midnight)** and executes [`scripts/build.sh`](scripts/build.sh),
which for each app:

1. Checks the latest stable releases of
   [Morphe Desktop](https://github.com/MorpheApp/morphe-desktop),
   [Morphe Patches](https://github.com/MorpheApp/morphe-patches),
   [De-Vanced Patches](https://github.com/RookieEnough/De-Vanced) and
   [PixelBoard Patches](https://github.com/Akshayykadam/PixelBoard)
   (downloads verified against the SHA-256 digests GitHub publishes).
2. Works out the recommended app version for the current patch bundles.
3. Downloads the stock APK from the archive.org `jhc-apks` archive (the
   same source the community builders use; size-verified), patches it with
   the default patch set, strips every ABI except **arm64-v8a**, verifies
   the result, and signs it. Exception: Gboard stock is **self-hosted** in
   this repo (releases tagged `stock-gboard-<version>`) because the APK
   mirrors block CI downloads behind Cloudflare; if PixelBoard ever
   requires a newer Gboard base, that one stock file has to be refreshed
   manually and the Gboard build retries until it appears.
4. Publishes everything in **one combined GitHub Release** per
   patch-bundle combination, tagged
   `build-<desktopver>-<morphepatchver>-<devancedver>-<pixelboardver>`,
   containing all five patched APKs plus a single copy of Morphe MicroG-RE.

Apps already current in the combined release are skipped. If one app
fails (e.g. a new recommended version isn't in the stock archive yet),
the others still publish into the release and the failed one retries on
the next daily run. You can also trigger a build manually from the
**Actions** tab (*Build YouTube Morphe → Run workflow*, with an optional
force-rebuild).

## Install on the phone

- **YouTube / YT Music / Google Photos:** install the **MicroG-RE** APK
  from the release first (required for Google sign-in on non-root), then
  the patched APK, then sign in via MicroG.
- **Reddit:** just install the patched APK and sign in as usual.
- **Gboard (PixelBoard):** install the APK, then enable PixelBoard under
  Settings > System > Languages & input > On-screen keyboard. It lives
  alongside the official Gboard as a separate keyboard; no MicroG needed.

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
