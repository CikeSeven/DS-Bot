# DS Bot phone app (Flutter)

The DS Bot app for Android and iOS, built with Flutter. It controls the Bot team that runs on your computer; nothing runs on the phone. It lives beside the Expo app in [../mobile](../mobile) and talks to the same computer side, with its own package id (`io.github.cikeseven.dsbot`), so both can be installed at once. A phone paired with one is not paired with the other.

## What is in it

- `lib/link/`: the encrypted link, a byte-for-byte Dart port of [../link/src](../link/src) (Noise IK over the Relay Server, DSBF fragments, RPC).
- `lib/data/`: the team session (sync by revision, optimistic writes, notices, read times), one chat (pages, sending, streaming), the demo team.
- `lib/shared/`: what the phone shares with the desktop UI: themes, inks, the twenty characters, and a Dart port of deep-view's card formulas.
- `lib/ui/`: the design system (palette from the desktop themes, type, springs, glass surfaces, line icons, avatars, Markdown).
- `lib/features/`: the screens. `lib/background/`: system notifications and the optional foreground service.

## Run

Needs Flutter 3.47 or later and Node 22 or later (for the tools and the link tests). Android needs the Android SDK with API 37; iOS needs Xcode on macOS.

```sh
flutter pub get
flutter run                               # on a connected phone or emulator
flutter run --dart-define=DSB_DEMO=1      # demo team, no computer needed
flutter analyze
flutter test --exclude-tags screenshot
```

Pair on the computer under DS Bot Settings → Phone: scan the QR code, paste its `dsbot://pair?…` link, or open the link on the phone.

## Tests

- `test/link/vectors_test.dart` compares the Dart link with vectors from the TypeScript one. After a change in `../link/src`, run `npm ci` in `../link`, then `node tool/gen_link_vectors.mjs`.
- `test/link/relay_integration_test.dart` (tag `integration`) runs the Dart client against the real Relay Server and computer side from `../link` (`tool/link_test_host.mjs`).
- `test/shared/deep_view_test.dart` compares the formula port with cases from deep-view: `node tool/gen_deep_view_cases.mjs path/to/deep-view`.
- `test/screens/screenshot_test.dart` (tag `screenshot`) renders the demo screens to `build/screenshots/`. It needs a CJK font installed; set `SHOT_DARK=1` for dark mode.

## Shared files

`assets/shared/shared.json` and `assets/i18n/zh.json` come from the desktop UI. After a change in `ds-bot/src/client` (themes, inks, characters, the Chinese dictionary) run `node tool/sync_shared.mjs`. Copy only the phone uses goes in `lib/ui/app_zh.dart`; `node tool/check_zh.mjs` lists any interface string without Chinese.

## Release builds

`flutter build apk --release` signs with the key these variables name, and with the debug key (and a warning) without them:

```sh
export DSBOT_ANDROID_KEYSTORE=/path/to/upload.jks
export DSBOT_ANDROID_KEYSTORE_PASSWORD=…
export DSBOT_ANDROID_KEY_ALIAS=…
export DSBOT_ANDROID_KEY_PASSWORD=…   # defaults to the store password
```

The version comes from `ds-bot/package.json`, and the versionCode follows the Expo app's rule, so a pre-release stays below its release. Every update must be signed with the same key, or Android refuses it. `.github/workflows/flutter-mobile.yml` builds and checks a signed APK in CI.

## Background notifications

Settings → Notifications → Keep connected in the background starts an Android foreground service, so questions and approvals arrive as notifications you can answer from the notification itself. Android may still stop it to save battery; allowing the app to ignore battery optimization keeps it running. There is no push server: with the service off, notifications only come while the app is open.
