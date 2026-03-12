Pod::Spec.new do |s|
  s.name             = 'UseSenseSDK'
  s.version          = '1.0.0'
  s.summary          = 'Human presence verification SDK for iOS.'
  s.description      = <<-DESC
    Native iOS SDK for human presence verification. Verify real humans,
    detect deepfakes, and prevent identity fraud with three independent
    verification pillars: DeepSense, LiveSense, and MatchSense.
  DESC

  s.homepage         = 'https://github.com/usesense/usesense-ios-sdk'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'UseSense' => 'support@usesense.ai' }
  s.source           = { :git => 'https://github.com/usesense/usesense-ios-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.9'

  s.source_files     = 'Sources/UseSense/**/*.swift'
  s.resource_bundles = {
    'UseSenseSDK' => [
      'Sources/UseSense/Resources/**/*.xcprivacy',
      'Sources/UseSense/Resources/**/*.mlmodel',
      'Sources/UseSense/Resources/**/*.json',
      'Sources/UseSense/Resources/**/*.lproj'
    ]
  }

  s.frameworks       = 'AVFoundation', 'CoreMotion', 'UIKit', 'Accelerate'
  s.weak_frameworks  = 'LocalAuthentication', 'DeviceCheck', 'CryptoKit'

  s.exclude_files    = 'Tests/**/*', 'Example/**/*', 'UseSenseDemo/**/*'

  s.pod_target_xcconfig = {
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited)',
    'APPLICATION_EXTENSION_API_ONLY' => 'NO'
  }
end
