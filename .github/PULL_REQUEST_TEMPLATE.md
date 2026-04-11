<!--
  Thanks for contributing to the UseSense iOS SDK.

  External code contributions are not accepted at this time; this
  template is primarily for internal maintainers and sanctioned
  partners. If you're filing a bug report or feature request,
  please open an issue instead.
-->

## Summary

<!-- 1-3 sentences: what does this PR change and why? -->

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that changes existing public API)
- [ ] Documentation or tooling only
- [ ] Release prep (version bump + CHANGELOG entry)

## Checklist

- [ ] `swift build` passes locally
- [ ] `pod lib lint UseSenseSDK.podspec --allow-warnings` passes locally
- [ ] `xcodebuild archive` against `XCFrameworkBuild/UseSenseSDK.xcodeproj` produces a working `.framework` if any build config changed (see CONTRIBUTING.md → Maintainer notes for the exact command)
- [ ] Unit tests under `Tests/UseSenseTests/` pass
- [ ] Any new public API has doc comments
- [ ] `CHANGELOG.md` has been updated for user-visible changes
- [ ] README install snippets still reference the correct version
- [ ] No em dashes in new text (workspace convention)
- [ ] No secrets, API keys, or code-signing identities committed

## Testing notes

<!--
  Describe how you tested this locally. For SDK changes, note which
  iOS versions you smoke-tested on (the minimum supported is 15.0).
  For release / CI changes, note how you validated the Gradle,
  podspec, or XcodeGen config.
-->

## Related issues

<!-- Closes #123, relates to #456 -->
