Pod::Spec.new do |s|
  s.name             = 'UseSenseMediaPipe'
  s.version          = '4.14.1'
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
  #   LICENSE, MEDIAPIPE_NOTICE.txt
  s.source = {
    :http => "https://github.com/qudusadeyemi/usesense-ios-sdk/releases/download/v#{s.version}/UseSenseMediaPipe.xcframeworks.zip"
  }
  s.vendored_frameworks = 'MediaPipeTasksVision.xcframework', 'MediaPipeTasksCommon.xcframework'
  s.preserve_paths      = 'MEDIAPIPE_NOTICE.txt'

  # The system frameworks and libraries the MediaPipe code needs, as in the
  # upstream MediaPipeTasks{Vision,Common} podspecs. No -force_load: the graph
  # archives are merged into MediaPipeTasksVision with every non-MPP* symbol
  # made local (scripts/isolate-mediapipe-symbols.sh), so MediaPipe's glog,
  # protobuf, absl, OpenCV and TFLite cannot clash with the app's (React Native
  # links its own glog).
  s.frameworks = 'Accelerate', 'CoreMedia', 'AssetsLibrary', 'CoreFoundation',
                 'CoreGraphics', 'CoreImage', 'QuartzCore', 'AVFoundation', 'CoreVideo'
  s.libraries  = 'c++'
end
