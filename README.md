# Morphe_Builds

Automated Morphe-patched YouTube APKs for my phone — **arm64-v8a, non-root**.

## How it works

A GitHub Actions workflow (`.github/workflows/build-youtube-morphe.yml`) runs
**daily at 09:00 IST** and:

1. Checks the latest stable releases of
   [Morphe Desktop](https://github.com/MorpheApp/morphe-desktop) and
   [Morphe Patches](https://github.com/MorpheApp/morphe-patches)
   (downloads are verified against the SHA-256 digests GitHub publishes).
2. Asks the Morphe CLI which YouTube version the patches recommend
   (`list-versions`, currently **21.30.216**).
3. If that combination hasn't been released here yet, downloads the stock
   YouTube APK from the archive.org `jhc-apks` archive (the same source the
   community builders use), patches it with the default patch set
   (incl. GmsCore support for non-root), strips every ABI except
   **arm64-v8a**, and signs it.
4. Publishes a **GitHub Release** with the patched APK and the matching
   Morphe MicroG-RE APK attached.

If nothing changed, the run ends with "up to date" and publishes nothing.
You can also trigger a build manually from the **Actions** tab
(*Build YouTube Morphe → Run workflow*, with an optional force-rebuild).

The build logic lives in [`scripts/build.sh`](scripts/build.sh).

## Install on the phone

1. From the latest release, install the **MicroG-RE** APK first
   (required for Google sign-in on non-root).
2. Install **YouTube-Morphe-\<version\>-arm64-v8a.apk**.
3. Open it and sign in via MicroG.

## Signing

All builds are signed with the keystore in [`keystore/`](keystore/)
(base64-encoded so it can live in git; password `morphe-builds`, alias
`Morphe`). Using one fixed keystore means every new release installs over
the previous one — no uninstall/reinstall dance. This key only signs these
personal sideload builds; don't reuse it for anything else.

## Notes

- For personal use. YouTube is a trademark of Google; Morphe patches are
  GPLv3, from the MorpheApp project.
- If a run fails because a brand-new recommended YouTube version isn't in
  the stock archive yet, the next daily run retries automatically.
