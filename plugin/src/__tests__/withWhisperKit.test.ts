import withWhisperKit, {
  addPodfileBlock,
  DEFAULT_MICROPHONE_PERMISSION,
  setMicrophoneUsage,
} from '../withWhisperKit';

const PODFILE = `platform :ios, '16.4'

target 'example' do
  use_expo_modules!

  config = use_native_modules!(config_command)
end
`;

describe('addPodfileBlock', () => {
  it('inserts the two pods after use_expo_modules! with the target indentation', () => {
    const out = addPodfileBlock(PODFILE, '../node_modules/expo-whisperkit/ios');
    expect(out).toContain(
      '  use_expo_modules!\n  # expo-whisperkit (begin)\n' +
        "  pod 'ArgmaxCore', :podspec => '../node_modules/expo-whisperkit/ios/ArgmaxCore.podspec'\n" +
        "  pod 'WhisperKit', :podspec => '../node_modules/expo-whisperkit/ios/WhisperKit.podspec'\n" +
        '  # expo-whisperkit (end)\n'
    );
  });

  it('is idempotent', () => {
    const once = addPodfileBlock(PODFILE, '../node_modules/expo-whisperkit/ios');
    const twice = addPodfileBlock(once, '../node_modules/expo-whisperkit/ios');
    expect(twice).toBe(once);
    expect(twice.match(/expo-whisperkit \(begin\)/g)).toHaveLength(1);
  });

  it('throws a clear error when use_expo_modules! is missing', () => {
    expect(() => addPodfileBlock("target 'x' do\nend\n", '../x')).toThrow(/use_expo_modules!/);
  });
});

describe('setMicrophoneUsage', () => {
  it('sets the default string when none is given', () => {
    expect(setMicrophoneUsage({})).toEqual({
      NSMicrophoneUsageDescription: DEFAULT_MICROPHONE_PERMISSION,
    });
  });

  it('uses a custom string and keeps other keys', () => {
    expect(setMicrophoneUsage({ CFBundleName: 'x' }, 'Talk to me')).toEqual({
      CFBundleName: 'x',
      NSMicrophoneUsageDescription: 'Talk to me',
    });
  });
});

describe('withWhisperKit', () => {
  it('registers the infoPlist and podfile mods', () => {
    const config = withWhisperKit({ name: 'app', slug: 'app' }, {});
    const mods = (config as { mods?: { ios?: Record<string, unknown> } }).mods;
    expect(mods?.ios?.infoPlist).toBeDefined();
    expect(mods?.ios?.podfile).toBeDefined();
  });
});
