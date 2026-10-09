import { NativeModule, requireOptionalNativeModule } from 'expo';

import { ExpoWhisperKitModuleEvents } from './ExpoWhisperKit.types';

declare class ExpoWhisperKitModule extends NativeModule<ExpoWhisperKitModuleEvents> {
  setValueAsync(value: string): Promise<void>;
}

export default requireOptionalNativeModule<ExpoWhisperKitModule>('ExpoWhisperKit');
