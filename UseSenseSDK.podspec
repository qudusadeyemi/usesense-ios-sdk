Pod::Spec.new do |s|
  s.name             = 'UseSenseSDK'
  s.version          = '4.3.0'
  s.summary          = 'Human presence verification SDK for iOS.'
  s.description      = <<-DESC
    Native iOS SDK for human presence verification. Verify real humans,
    detect deepfakes, and prevent identity fraud with three independent
    verification pillars: DeepSense, LiveSense, and MatchSense.
    Includes on-device 3D liveness (Geometric Coherence), client-side
    presentation attack detection (Suspicion Engine), and inline step-up
    challenges (Flash Reflection, RMAS).
  DESC

  s.homepage         = 'https://github.com/qudusadeyemi/usesense-ios-sdk'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'UseSense' => 'support@usesense.ai' }
  s.source           = { :git => 'https://github.com/qudusadeyemi/usesense-ios-sdk.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  s.source_files     = 'Sources/UseSense/**/*.swift'
  s.resource_bundles = {
    'UseSenseSDK' => [
      'Sources/UseSense/Resources/**/*.xcprivacy',
      'Sources/UseSense/Resources/**/*.mlmodel',
      'Sources/UseSense/Resources/**/*.json',
      'Sources/UseSense/Resources/**/*.task',
      'Sources/UseSense/Resources/**/*.lproj'
    ]
  }

  s.frameworks       = 'AVFoundation', 'CoreMotion', 'UIKit', 'Accelerate'
  s.weak_frameworks  = 'LocalAuthentication', 'DeviceCheck', 'CryptoKit'

  # ──────────────────────────────────────────────────────────────────────
  # MediaPipe is an OPTIONAL transitive dependency, NOT declared here.
  # ──────────────────────────────────────────────────────────────────────
  # The on-device face-mesh feature (Geometric Coherence pillar) uses
  # Google's MediaPipeTasksVision CocoaPod. We can't declare it as a
  # `s.dependency` here because the upstream xcframework's Info.plist
  # is broken: it claims `LibraryPath: MediaPipeTasksCommon.a` but the
  # actual file on disk is a `.framework/` bundle, so CocoaPods emits
  # a `-lMediaPipeTasksCommon` linker flag that fails with
  # `ld: library 'MediaPipeTasksCommon' not found` during build/lint.
  # Both `pod lib lint` and `pod trunk push` reject the spec because
  # of this. There is no podspec-level workaround because:
  #
  #   * `prepare_command` runs in the podspec source directory, not
  #     the install sandbox, so it can't reach sibling pods' xcframeworks.
  #   * `script_phases` run during build, after CocoaPods has already
  #     baked the wrong linker flags into the .xcconfig files.
  #   * `--use-libraries` doesn't change the underlying issue.
  #
  # Until Google publishes a fixed upstream version (or we vendor the
  # patched xcframeworks ourselves as a follow-up), integrators who
  # want the face-mesh feature must add MediaPipeTasksVision to their
  # OWN Podfile alongside a `pre_install` hook that patches the
  # xcframework Info.plist. See the README's "Optional: Enable On-Device
  # Face Mesh" section for the Podfile snippet to copy-paste.
  #
  # The SDK itself uses `#if canImport(MediaPipeTasksVision)` to gate
  # the face-mesh code path, so it builds and runs cleanly with or
  # without the MediaPipe pod present. When MediaPipeTasksVision is
  # not linked, FaceMeshManager.setup() returns immediately with
  # isReady=false and processFrame returns nil — every other SDK
  # feature continues to work.

  s.exclude_files    = 'Tests/**/*', 'Example/**/*', 'UseSenseDemo/**/*'

  s.pod_target_xcconfig = {
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited)',
    'APPLICATION_EXTENSION_API_ONLY' => 'NO'
  }
end
