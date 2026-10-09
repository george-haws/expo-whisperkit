import { ERROR_CODES, toWhisperKitError, WhisperKitError } from '../errors';

describe('WhisperKitError', () => {
  it('carries code, message and cause', () => {
    const cause = new Error('boom');
    const err = new WhisperKitError('busy', 'Already running', cause);
    expect(err).toBeInstanceOf(Error);
    expect(err.name).toBe('WhisperKitError');
    expect(err.code).toBe('busy');
    expect(err.message).toBe('Already running');
    expect(err.cause).toBe(cause);
  });

  it('lists all nine codes', () => {
    expect(ERROR_CODES).toEqual([
      'unsupported-platform',
      'model-missing',
      'download-failed',
      'load-failed',
      'permission-denied',
      'recording-failed',
      'decode-failed',
      'busy',
      'cancelled',
    ]);
  });
});

describe('toWhisperKitError', () => {
  it('returns a WhisperKitError unchanged', () => {
    const err = new WhisperKitError('cancelled', 'x');
    expect(toWhisperKitError(err, 'decode-failed')).toBe(err);
  });

  it('keeps a known native code', () => {
    const native = Object.assign(new Error('Model base is not downloaded'), {
      code: 'model-missing',
    });
    const err = toWhisperKitError(native, 'decode-failed');
    expect(err.code).toBe('model-missing');
    expect(err.message).toBe('Model base is not downloaded');
    expect(err.cause).toBe(native);
  });

  it('rewraps an unknown native code with the fallback', () => {
    const native = Object.assign(new Error('weird'), { code: 'ERR_SOMETHING' });
    const err = toWhisperKitError(native, 'load-failed');
    expect(err.code).toBe('load-failed');
    expect(err.message).toBe('weird');
    expect(err.cause).toBe(native);
  });

  it('wraps a non-Error value', () => {
    const err = toWhisperKitError('nope', 'recording-failed');
    expect(err.code).toBe('recording-failed');
    expect(err.message).toBe('nope');
  });
});
