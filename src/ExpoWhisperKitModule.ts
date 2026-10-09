import { NativeModule, requireOptionalNativeModule } from 'expo';

declare class ExpoWhisperKitModule extends NativeModule<Record<string, never>> {
  deviceName(): string;
}

export default requireOptionalNativeModule<ExpoWhisperKitModule>('ExpoWhisperKit');
