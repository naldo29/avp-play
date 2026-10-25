# Custom APK edition

Choose **File → Import APK…** (⌘I), or **Import APK…** on a game's page. AVP Play reads the APK's Android package and version code and matches an existing recipe. The APK becomes an option under **Your imported APKs** in that same game's **Version** menu. Its filename and short SHA-256 identify it; two different APKs with the same version code remain separate.

Recognition selects the matching build recipe; it does not establish that arbitrary APK changes work. Unknown packages or versions require a matching recipe first. APKs stay in the local library and are never uploaded by importing.

**Include core mods** appears only for the supported Beat Saber 1.40.8 build with the exact pinned Unity, IL2CPP and metadata hashes. On uses the original Scotland2/SongCore/SongDownloader ten-mod profile plus the original BetterSongSearch 2.2.9 and Airbuds Search 2.0.2 ports. Airbuds Search needs a refresh token entered in its in-game settings. The search ports have host build validation; headset behavior and authenticated Airbuds calls have not been tested. Off uses the normal AVP Play toolchain. The selected APK and compatibility are checked again before a mod build. Fake ID is excluded. Existing installed imported builds keep their app identity when another custom APK is selected; signing records from ordinary store builds remain separate.

Complete local game inputs can be built without a Meta login. Downloads and purchased add-ons continue to use the normal store/account flow. Imports reuse only required local data whose size and SHA-256 match the recipe. Importing never grants add-on purchases. Installing an update preserves the app's Documents and Library; the startup screen and Settings use AVP Play's usual icon and artwork pipeline.

This custom Mac app bundles the normal public toolchain plus a separate audited core-mod source profile. It does not bundle any APK, OBB, songs, saves or signing identity. Core-mod dependencies are reconstructed from pinned public sources. The optional `.scotland2-avp-local.json` in an installed profile may name an existing verified dependency workspace/cache for offline builds; keep it private.

An ordinary imported-APK update keeps an existing unexpired provisioning profile. Its actual expiry is shown after installation; updating the APK does not extend it. Expired profiles and explicit renewal still require Xcode to obtain a fresh profile from the existing Apple account.

Build the core profile from the committed Klepton fork with `ports/scotland2/tools/source_package.py`, then `ports/scotland2/tools/package_avp.py --source-archive <source.zip> --graphics <verified-graphics-root> --output <profile.tar.gz>`. Set `AVPPLAY_COREMODS_ARCHIVE` to that archive when running `core/tools/make-app.sh`; the checksum sidecar is required. Set `AVPPLAY_TOOLCHAIN_ARCHIVE` for the ordinary toolchain and explicit `AVPPLAY_APP_VERSION`/`AVPPLAY_APP_BUILD`. Source archives and profile packages must pass their inspection checks before distribution. Owner artwork is generated locally after import.

The custom edition does not replace itself from the official update feed. Keep the original signed app as a rollback; rebuilding locally produces an ad-hoc-signed Mac app, not a notarized upstream release.

CLI: `avpplay import-apk <file.apk>`, then `avpplay prepare <id> --core-mods` for host preparation or `avpplay install <id> --core-mods --team <team>`. Explicit `--bundle-id` overrides the recorded imported identity. Do not change it when updating an existing installation whose saves you want to retain.
