import type {
  DecodingOptions,
  EventName,
  Events,
  ModelStatus,
  NativeDecodingOptions,
  PermissionStatus,
  Subscription,
  Transcription,
  WhisperKitErrorCode,
} from './ExpoWhisperKit.types';
import native from './ExpoWhisperKitModule';
import { toWhisperKitError, WhisperKitError } from './errors';

export * from './ExpoWhisperKit.types';
export { WhisperKitError, ERROR_CODES } from './errors';

export const DEFAULT_MODEL = 'base';

export function isAvailable(): boolean {
  return native !== null;
}

function requireNative() {
  if (native === null) {
    throw new WhisperKitError(
      'unsupported-platform',
      'expo-whisperkit is only available on iOS and iPadOS.'
    );
  }
  return native;
}

async function call<T>(
  fallback: WhisperKitErrorCode,
  fn: (n: NonNullable<typeof native>) => Promise<T>
): Promise<T> {
  let n: NonNullable<typeof native>;
  try {
    n = requireNative();
  } catch (e) {
    return Promise.reject(e);
  }
  try {
    return await fn(n);
  } catch (e) {
    throw toWhisperKitError(e, fallback);
  }
}

function resolveOptions(options?: DecodingOptions): NativeDecodingOptions {
  const resolved: NativeDecodingOptions = {
    model: options?.model ?? DEFAULT_MODEL,
    download: options?.download ?? true,
  };
  if (options?.language !== undefined) resolved.language = options.language;
  if (options?.task !== undefined) resolved.task = options.task;
  if (options?.prompt !== undefined) resolved.prompt = options.prompt;
  return resolved;
}

// Models

export function getModelStatus(model: string = DEFAULT_MODEL): Promise<ModelStatus> {
  return call('load-failed', (n) => n.getModelStatus(model));
}

export function downloadModel(model: string = DEFAULT_MODEL): Promise<void> {
  return call('download-failed', (n) => n.downloadModel(model));
}

export function deleteModel(model: string): Promise<void> {
  return call('load-failed', (n) => n.deleteModel(model));
}

export function listDownloadedModels(): Promise<string[]> {
  return call('load-failed', (n) => n.listDownloadedModels());
}

export function loadModel(model: string = DEFAULT_MODEL): Promise<void> {
  return call('load-failed', (n) => n.loadModel(model));
}

export function unloadModel(): Promise<void> {
  return call('load-failed', (n) => n.unloadModel());
}

// Transcription of a file

export function transcribeFile(uri: string, options?: DecodingOptions): Promise<Transcription> {
  return call('decode-failed', (n) => n.transcribeFile(uri, resolveOptions(options)));
}

// Push-to-talk

export function getMicrophonePermission(): Promise<PermissionStatus> {
  return call('permission-denied', (n) => n.getMicrophonePermission());
}

export function requestMicrophonePermission(): Promise<PermissionStatus> {
  return call('permission-denied', (n) => n.requestMicrophonePermission());
}

export function startRecording(): Promise<void> {
  return call('recording-failed', (n) => n.startRecording());
}

export function stopRecording(options?: DecodingOptions): Promise<Transcription> {
  return call('decode-failed', (n) => n.stopRecording(resolveOptions(options)));
}

export function cancelRecording(): Promise<void> {
  return call('recording-failed', (n) => n.cancelRecording());
}

// Streaming

export function startStreaming(options?: DecodingOptions): Promise<void> {
  return call('recording-failed', (n) => n.startStreaming(resolveOptions(options)));
}

export function stopStreaming(): Promise<Transcription> {
  return call('decode-failed', (n) => n.stopStreaming());
}

// Events

export function addListener<E extends EventName>(
  event: E,
  listener: (payload: Events[E]) => void
): Subscription {
  if (native === null) {
    return { remove() {} };
  }
  const sub = native.addListener(event, listener as never);
  return { remove: () => sub.remove() };
}

/** Test hook: posts a memory warning so the engine's unload path can be exercised. */
export function simulateMemoryWarningForTesting(): Promise<void> {
  return call('load-failed', (n) => n.simulateMemoryWarningForTesting());
}
