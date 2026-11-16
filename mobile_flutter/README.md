# DS Bot phone app (Flutter)

The DS Bot app for Android and iOS, built with Flutter. It controls the Bot team that runs on your computer; nothing runs on the phone. It replaces the earlier Expo app; its package id is `com.dsbot`.

## What is in it

- `lib/link/`: the link to the computer. It is the Rust session in [../link/crates/client](../link/crates/client) (protocol v2: it reconnects and resumes by itself), reached through flutter_rust_bridge: `rust/` is the bridge crate, `rust_builder/` builds it into the app with Cargokit, and `lib/src/rust/` is the generated Dart. One process keeps one session per computer, so the app, the background service and notification actions share it.
- `lib/data/`: the team session (sync by revision, optimistic writes, notices, read times), one chat (pages, sending, streaming), the demo team.
- `lib/shared/`: what the phone shares with the desktop UI: themes, inks, the twenty characters, and a Dart port of deep-view's card formulas.
- `lib/ui/`: the design system (palette from the desktop themes, type, springs, glass surfaces, line icons, avatars, Markdown).
- `shaders/liquid_glass.frag`: the onboarding glass, run as a backdrop filter where the engine supports it (Impeller); elsewhere `LiquidGlass` falls back to a blur. Never fade an ancestor of it: in a fading layer the engine renders it offscreen and the shader loses its coordinates and backdrop, so it fades itself through `appear`.
- `lib/features/`: the screens. `lib/background/`: system notifications and the optional foreground service.

## Run

Needs Flutter 3.47 or later, Rust (through rustup) and Node 22 or later (for the tools). Android needs the Android SDK with API 37 and the NDK version Flutter asks for (28.2.13676358) under the SDK's `ndk/`; Cargokit adds the Rust Android targets itself. iOS needs Xcode on macOS.

```sh
flutter pub get
flutter run                               # on a connected phone or emulator
flutter run --dart-define=DSB_DEMO=1      # demo team, no computer needed
flutter analyze
flutter test --exclude-tags screenshot
```

Pair on the computer under DS Bot Settings → Phone: scan the QR code, paste its `dsbot://pair?…` link, or open the link on the phone.

## Tests

- Tests that make keys or read pairing links load the Rust library: `test/support/rust_link.dart` builds `rust/` for this computer with cargo first (a minute or two the first time). The link itself is tested in `../link`: `cargo test -p dsbot-link-client`.
- After a change in `rust/src/api/`, regenerate the Dart side with `flutter_rust_bridge_codegen generate` (version 2.13.0, the same as the `flutter_rust_bridge` dependencies).
- `test/shared/deep_view_test.dart` compares the formula port with cases from deep-view: `node tool/gen_deep_view_cases.mjs path/to/deep-view`.
- `test/screens/screenshot_test.dart` (tag `screenshot`) renders the demo screens to `build/screenshots/`. It needs a CJK font installed; set `SHOT_DARK=1` for dark mode.

## Performance

`integration_test/onboarding_perf_test.dart` runs the first-run flow on a connected phone in profile mode and writes frame times per phase (from the engine's `FrameTiming`, against the display's refresh rate) to `build/onboarding_perf.json`:

```sh
flutter drive --profile --driver=test_driver/perf_driver.dart --target=integration_test/onboarding_perf_test.dart
```

`flutter drive` installs a test build over the app; install the app again afterwards.

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

The version comes from `ds-bot/package.json`, and the versionCode follows the rule the Expo app used, so a pre-release stays below its release. Every update must be signed with the same key, or Android refuses it. `.github/workflows/flutter-mobile.yml` builds and checks the APK in CI, and `.github/workflows/release.yml` builds the signed one that a release offers.

## Background notifications

Settings → Notifications → Keep connected in the background starts an Android foreground service, so questions and approvals arrive as notifications you can answer from the notification itself. Android may still stop it to save battery; allowing the app to ignore battery optimization keeps it running. There is no push server: with the service off, notifications only come while the app is open.
