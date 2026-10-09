import { ConfigPlugin, withInfoPlist, withPodfile } from 'expo/config-plugins';
import path from 'path';

export type WhisperKitPluginProps = {
  /** Text shown in the iOS microphone permission prompt. */
  microphonePermission?: string;
};

export const DEFAULT_MICROPHONE_PERMISSION =
  'Allow $(PRODUCT_NAME) to use the microphone for speech to text.';

const BEGIN = '# expo-whisperkit (begin)';
const END = '# expo-whisperkit (end)';
const ANCHOR = /^([ \t]*)use_expo_modules![ \t]*$/m;

/** Inserts the two source-pod lines after `use_expo_modules!`. Idempotent. */
export function addPodfileBlock(contents: string, relativeIosDir: string): string {
  if (contents.includes(BEGIN)) {
    return contents;
  }
  const match = ANCHOR.exec(contents);
  if (!match || match.index === undefined) {
    throw new Error(
      'expo-whisperkit: could not find `use_expo_modules!` in the Podfile. ' +
        'Add the ArgmaxCore and WhisperKit pods by hand (see the README).'
    );
  }
  const indent = match[1];
  const lines = [
    BEGIN,
    `pod 'ArgmaxCore', :podspec => '${relativeIosDir}/ArgmaxCore.podspec'`,
    `pod 'WhisperKit', :podspec => '${relativeIosDir}/WhisperKit.podspec'`,
    END,
  ].map((line) => indent + line);
  const insertAt = match.index + match[0].length;
  return contents.slice(0, insertAt) + '\n' + lines.join('\n') + contents.slice(insertAt);
}

export function setMicrophoneUsage(
  plist: Record<string, unknown>,
  text?: string
): Record<string, unknown> {
  return { ...plist, NSMicrophoneUsageDescription: text ?? DEFAULT_MICROPHONE_PERMISSION };
}

/** Absolute path of this package's `ios/` folder, from either `plugin/build` or `plugin/src`. */
export function packageIosDir(): string {
  return path.resolve(__dirname, '..', '..', 'ios');
}

const withWhisperKit: ConfigPlugin<WhisperKitPluginProps | void> = (config, props) => {
  config = withInfoPlist(config, (c) => {
    c.modResults = setMicrophoneUsage(
      c.modResults as Record<string, unknown>,
      props?.microphonePermission
    ) as typeof c.modResults;
    return c;
  });
  config = withPodfile(config, (c) => {
    const iosProjectDir = path.dirname(c.modResults.path);
    const relative = path.relative(iosProjectDir, packageIosDir()).split(path.sep).join('/');
    c.modResults.contents = addPodfileBlock(c.modResults.contents, relative);
    return c;
  });
  return config;
};

export default withWhisperKit;
