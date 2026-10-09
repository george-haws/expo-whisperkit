import { NativeModule, requireOptionalNativeModule } from 'expo';

import type {
  Events,
  ModelStatus,
  NativeDecodingOptions,
  PermissionStatus,
  Transcription,
} from './ExpoWhisperKit.types';

type NativeEvents = { [K in keyof Events]: (payload: Events[K]) => void };

export declare class ExpoWhisperKitNativeModule extends NativeModule<NativeEvents> {
  getModelStatus(model: string): Promise<ModelStatus>;
  downloadModel(model: string): Promise<void>;
  deleteModel(model: string): Promise<void>;
  listDownloadedModels(): Promise<string[]>;
  loadModel(model: string): Promise<void>;
  unloadModel(): Promise<void>;
  transcribeFile(uri: string, options: NativeDecodingOptions): Promise<Transcription>;
  getMicrophonePermission(): Promise<PermissionStatus>;
  requestMicrophonePermission(): Promise<PermissionStatus>;
  startRecording(): Promise<void>;
  stopRecording(options: NativeDecodingOptions): Promise<Transcription>;
  cancelRecording(): Promise<void>;
  startStreaming(options: NativeDecodingOptions): Promise<void>;
  stopStreaming(): Promise<Transcription>;
  simulateMemoryWarningForTesting(): Promise<void>;
}

/** `null` on Android, web, and any build without the native module. */
export default requireOptionalNativeModule<ExpoWhisperKitNativeModule>('ExpoWhisperKit');
