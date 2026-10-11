# The one place the WhisperKit version lives. Bumping it: change the tag and the commit it
# points at (`git ls-remote --tags https://github.com/argmaxinc/argmax-oss-swift.git 'v*'`),
# update `whisperKitVersion` in Package.swift and let SwiftPM refresh Package.resolved,
# rebuild the example app, run the Maestro flows, tag a release.
WHISPERKIT_GIT = 'https://github.com/argmaxinc/argmax-oss-swift.git'
WHISPERKIT_TAG = 'v1.1.1'
WHISPERKIT_COMMIT = '1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4'
