require_relative 'whisperkit_version'

Pod::Spec.new do |s|
  s.name             = 'WhisperKit'
  s.version          = WHISPERKIT_TAG.delete_prefix('v')
  s.summary          = 'WhisperKit, compiled from source by expo-whisperkit'
  s.homepage         = 'https://github.com/argmaxinc/argmax-oss-swift'
  s.license          = { :type => 'MIT' }
  s.author           = 'Argmax, Inc.'
  s.platforms        = { :ios => '16.0' }
  s.swift_version    = '5.10'
  s.source           = { :git => WHISPERKIT_GIT, :tag => WHISPERKIT_TAG }
  s.source_files     = 'Sources/WhisperKit/**/*.swift'
  s.frameworks       = 'CoreML', 'AVFoundation', 'Accelerate'
  s.static_framework = true
  s.dependency 'ArgmaxCore'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_SWIFT_FLAGS' => '$(inherited) -enable-experimental-feature StrictConcurrency',
  }
end
