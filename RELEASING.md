# Releasing the UseSense SDKs

Five SDKs ship together: Android (`ai.usesense:sdk`), iOS (`UseSenseSDK` +
`UseSenseMediaPipe`), web (`@usesense/web-sdk`), Flutter (`usesense_flutter`)
and React Native (`react-native-usesense`). Flutter and React Native are thin
wrappers over the native SDKs and must always pin the latest native versions.

## One batch, one update

Customers should update once per batch of work. Hold a release until every
change planned for that platform in the batch is merged, and release the
wrappers once, after the native SDKs they need are published.

## Order

1. **Native first.** Merge to `main`, check every version constant (Android:
   `gradle.properties` `sdkVersion` and `DeviceSignalCollector.SDK_VERSION`;
   iOS: both podspecs and `UseSense.version`), then push the tag `vX.Y.Z`.
   `release-android.yml` publishes to Maven Central; `release-ios.yml` builds
   the isolated MediaPipe bundle, creates the GitHub release and pushes both pods
   to CocoaPods trunk. Web: tag `vX.Y.Z` in `usesense-web-sdk` (npm).
2. **Wait for the registries.** Maven Central and the CocoaPods CDN version
   index lag the publish by minutes (the index file is cached for up to 10
   minutes). `python3 scripts/native_pins.py wait` in a wrapper waits for both.
3. **Wrappers.** When a native release finishes, it dispatches
   `native-sdk-released` to both wrappers; their `bump-native-pins.yml` opens a
   `bot/native-pins` PR that moves every pin (Gradle, podspec, README, the React
   Native example `Podfile.lock`) to the latest native SDKs, bumps the wrapper's
   patch version and adds a CHANGELOG line. Merge it, then tag the wrapper
   (`release.yml`).

## Guards

- **`native-pins.yml`** (both wrappers): every PR, every push to `main` and
  daily, `scripts/native_pins.py check` fails if any native pin is behind the
  latest release. To ship a wrapper that intentionally lags, label the PR
  `native-pins-lag-ok`.
- Every place a wrapper names a native version is listed in `PINS` in
  `scripts/native_pins.py`. If you add another, add it there too, or the check
  reports it as missing.

## Secrets

One fine-grained GitHub token, saved as **`USESENSE_BOT_TOKEN`** in all four
repos (`usesense-android-sdk`, `usesense-ios-sdk`, `flutter-usesense`,
`react-native-usesense`), with access to `flutter-usesense` and
`react-native-usesense` and the permissions **Contents: read and write** and
**Pull requests: read and write**. The native repos use it to dispatch the bump;
the wrappers use it to open the bump PR so its CI runs (a PR opened with the
default `GITHUB_TOKEN` does not trigger workflows). Without it the daily run
still opens the PR, but you have to push to it once to start CI.
