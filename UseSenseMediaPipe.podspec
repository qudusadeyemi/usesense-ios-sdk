Pod::Spec.new do |s|
  s.name             = 'UseSenseMediaPipe'
  s.version          = '4.7.0'
  s.summary          = 'Patched MediaPipe Tasks xcframeworks vendored for UseSenseSDK on-device face mesh.'
  s.description      = <<-DESC
    Redistributes Google's MediaPipeTasksVision + MediaPipeTasksCommon
    xcframeworks with a corrected top-level Info.plist LibraryPath
    (".a" -> ".framework") so CocoaPods links them as frameworks instead of
    emitting an unresolvable `-l<NAME>` flag. This lets UseSenseSDK depend on
    MediaPipe normally -- integrators no longer need a per-app `pre_install`
    Info.plist patch hook. Built by scripts/vendor-mediapipe.sh at release time.
  DESC

  s.homepage         = 'https://github.com/qudusadeyemi/usesense-ios-sdk'
  # MediaPipe Tasks is Apache-2.0; the upstream LICENSE travels in the bundle.
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'UseSense' => 'support@usesense.ai' }

  s.ios.deployment_target = '15.0'

  # Prebuilt, patched bundle produced by scripts/vendor-mediapipe.sh and attached
  # to the matching GitHub Release. The zip root contains:
  #   MediaPipeTasksVision.xcframework, MediaPipeTasksCommon.xcframework
  #   graph_libraries/libMediaPipeTasksCommon_{device,simulator}_graph.a
  #   LICENSE, MEDIAPIPE_NOTICE.txt
  s.source = {
    :http => "https://github.com/qudusadeyemi/usesense-ios-sdk/releases/download/v#{s.version}/UseSenseMediaPipe.xcframeworks.zip"
  }
  s.vendored_frameworks = 'MediaPipeTasksVision.xcframework', 'MediaPipeTasksCommon.xcframework'
  s.preserve_paths      = 'graph_libraries/*.a', 'MEDIAPIPE_NOTICE.txt'

  # These mirror the upstream MediaPipeTasks{Vision,Common} podspecs exactly — the
  # frameworks/libraries the binaries need, plus the -force_load of the static
  # graph archives that carry the graph runtime symbols. Without the force_load
  # the link fails with undefined symbols (and a benign auto-link warning for
  # 'UIUtilities'). Paths resolve to this pod's extracted root under PODS_ROOT.
  s.frameworks = 'Accelerate', 'CoreMedia', 'AssetsLibrary', 'CoreFoundation',
                 'CoreGraphics', 'CoreImage', 'QuartzCore', 'AVFoundation', 'CoreVideo'
  s.libraries  = 'c++'
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '$(inherited) -force_load "${PODS_ROOT}/UseSenseMediaPipe/graph_libraries/libMediaPipeTasksCommon_simulator_graph.a"',
    'OTHER_LDFLAGS[sdk=iphoneos*]'        => '$(inherited) -force_load "${PODS_ROOT}/UseSenseMediaPipe/graph_libraries/libMediaPipeTasksCommon_device_graph.a"'
  }
end
