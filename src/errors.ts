import type { WhisperKitErrorCode } from './ExpoWhisperKit.types';

export const ERROR_CODES: readonly WhisperKitErrorCode[] = [
  'unsupported-platform',
  'model-missing',
  'download-failed',
  'load-failed',
  'permission-denied',
  'recording-failed',
  'decode-failed',
  'busy',
  'cancelled',
];

export class WhisperKitError extends Error {
  readonly code: WhisperKitErrorCode;
  readonly cause?: unknown;

  constructor(code: WhisperKitErrorCode, message: string, cause?: unknown) {
    super(message);
    this.name = 'WhisperKitError';
    this.code = code;
    this.cause = cause;
  }
}

export function isWhisperKitErrorCode(value: unknown): value is WhisperKitErrorCode {
  return typeof value === 'string' && (ERROR_CODES as readonly string[]).includes(value);
}

/** Every rejection leaving this package is a WhisperKitError. */
export function toWhisperKitError(error: unknown, fallback: WhisperKitErrorCode): WhisperKitError {
  if (error instanceof WhisperKitError) {
    return error;
  }
  const code = (error as { code?: unknown } | null)?.code;
  const message = error instanceof Error ? error.message : String(error);
  return new WhisperKitError(isWhisperKitErrorCode(code) ? code : fallback, message, error);
}
