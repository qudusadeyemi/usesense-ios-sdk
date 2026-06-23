Pod::Spec.new do |s|
  s.name             = 'UseSenseSDK'
  s.version          = '4.4.1'
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
  # On-device face mesh (Geometric Coherence pillar) — vendored MediaPipe.
  # ──────────────────────────────────────────────────────────────────────
  # The face-mesh feature uses Google's MediaPipeTasksVision. Google's upstream
  # xcframeworks ship a broken Info.plist (`LibraryPath: <NAME>.a` for a file
  # that is actually a `<NAME>.framework/`), which makes CocoaPods emit an
  # unresolvable `-l<NAME>` flag — so we cannot depend on the upstream pod
  # directly (`pod lib lint`/`pod trunk push` reject it). Instead UseSenseMediaPipe
  # vendors the SAME binaries with a corrected Info.plist (built by
  # scripts/vendor-mediapipe.sh at release time), so integrators get face mesh
  # transitively with NO per-app `pre_install` patch hook.
  #
  # The SDK still gates the code path behind `#if canImport(MediaPipeTasksVision)`,
  # so source builds (SwiftPM without the binary, etc.) degrade cleanly to
  # isReady=false rather than failing to compile.
  s.dependency 'UseSenseMediaPipe', "#{s.version}"

  s.exclude_files    = 'Tests/**/*', 'Example/**/*', 'UseSenseDemo/**/*'

  s.pod_target_xcconfig = {
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited)',
    'APPLICATION_EXTENSION_API_ONLY' => 'NO'
  }
  # MediaPipe ships static binaries, so UseSenseSDK integrates as a static
  # framework. This lets it carry the static MediaPipe deps under a normal
  # `use_frameworks!` (the Flutter default) without the app needing
  # `:linkage => :static`, and lets `pod trunk push` validate the static deps.
  s.static_framework = true
end
