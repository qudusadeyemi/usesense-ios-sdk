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
3. **Wrappers.** Every hour, each wrapper's `bump-native-pins.yml` checks the
   registries. Once a newer native release is installable it opens (or
   refreshes) a `bot/native-pins` PR that moves every pin (Gradle, podspec,
   README, the React Native example `Podfile.lock`) to it, bumps the wrapper's
   patch version, adds a CHANGELOG line and starts CI on the branch. Merge it,
   then tag the wrapper (`release.yml`). To skip the wait, run the workflow by
   hand (Actions, Bump native SDK pins, Run workflow).

## Guards

- **`native-pins.yml`** (both wrappers): every PR, every push to `main` and
  daily, `scripts/native_pins.py check` fails if any native pin is behind the
  latest release. To ship a wrapper that intentionally lags, label the PR
  `native-pins-lag-ok`.
- Every place a wrapper names a native version is listed in `PINS` in
  `scripts/native_pins.py`. If you add another, add it there too, or the check
  reports it as missing.

## No stored tokens

The automation uses only each run's built-in `GITHUB_TOKEN` (scoped to that
repo, expires with the run). There is no personal or cross-repo token to leak.
A PR opened with `GITHUB_TOKEN` does not start `pull_request` workflows, so the
bump run starts `ci.yml` and `native-pins.yml` on its branch with
`workflow_dispatch`; their checks show on the PR.

Publishing stays in your hands: pushing a `v*` tag is what releases each SDK.
Protect `v*` tags and `main` in every SDK repo (Settings, Rules, Rulesets) so
only maintainers can tag or merge.
