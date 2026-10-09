export type ModelState = 'absent' | 'downloading' | 'present' | 'loaded';

export interface ModelStatus {
  model: string;
  state: ModelState;
}

export type PermissionStatus = 'granted' | 'denied' | 'undetermined';

export type DecodingTask = 'transcribe' | 'translate';

export interface DecodingOptions {
  /** WhisperKit variant name. Default `DEFAULT_MODEL`. */
  model?: string;
  /** ISO 639-1 code. Omitted: auto-detect. */
  language?: string;
  task?: DecodingTask;
  /** Vocabulary hint fed to the decoder as a prompt. */
  prompt?: string;
  /** Fetch the model if absent. Default true; false rejects with `model-missing`. */
  download?: boolean;
}

/** What crosses the bridge: every default resolved. */
export interface NativeDecodingOptions {
  model: string;
  language?: string;
  task?: DecodingTask;
  prompt?: string;
  download: boolean;
}

export interface Segment {
  text: string;
  /** Seconds from the start of the audio. */
  start: number;
  end: number;
}

export interface Transcription {
  text: string;
  language: string;
  segments: Segment[];
}

export interface Events {
  downloadProgress: { model: string; fraction: number };
  modelState: { model: string; state: ModelState };
  audioLevel: { level: number };
  streamingUpdate: { confirmedText: string; pendingText: string };
}

export type EventName = keyof Events;

export interface Subscription {
  remove(): void;
}

export type WhisperKitErrorCode =
  | 'unsupported-platform'
  | 'model-missing'
  | 'download-failed'
  | 'load-failed'
  | 'permission-denied'
  | 'recording-failed'
  | 'decode-failed'
  | 'busy'
  | 'cancelled';
