require_relative 'whisperkit_version'

Pod::Spec.new do |s|
  s.name             = 'ArgmaxCore'
  s.version          = WHISPERKIT_TAG.delete_prefix('v')
  s.summary          = 'ArgmaxCore (WhisperKit dependency), compiled from source by expo-whisperkit'
  s.homepage         = 'https://github.com/argmaxinc/argmax-oss-swift'
  s.license          = { :type => 'MIT' }
  s.author           = 'Argmax, Inc.'
  s.platforms        = { :ios => '16.0' }
  s.swift_version    = '5.10'
  s.source           = { :git => WHISPERKIT_GIT, :commit => WHISPERKIT_COMMIT }
  s.source_files     = 'Sources/ArgmaxCore/**/*.swift'
  s.static_framework = true
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_SWIFT_FLAGS' => '$(inherited) -enable-experimental-feature StrictConcurrency',
  }
end
