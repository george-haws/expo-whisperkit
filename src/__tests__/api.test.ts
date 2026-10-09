// jest.mock is hoisted above the imports, so the mock is built inside the factory and read
// back through the (mocked) module import.
import mockedNative, { ExpoWhisperKitNativeModule } from '../ExpoWhisperKitModule';
import { WhisperKitError } from '../errors';
import * as api from '../index';

jest.mock('../ExpoWhisperKitModule', () => {
  const listeners: Record<string, ((payload: unknown) => void)[]> = {};
  const mockNative = {
    __listeners: listeners,
    getModelStatus: jest.fn(),
    downloadModel: jest.fn(),
    deleteModel: jest.fn(),
    listDownloadedModels: jest.fn(),
    loadModel: jest.fn(),
    unloadModel: jest.fn(),
    transcribeFile: jest.fn(),
    getMicrophonePermission: jest.fn(),
    requestMicrophonePermission: jest.fn(),
    startRecording: jest.fn(),
    stopRecording: jest.fn(),
    cancelRecording: jest.fn(),
    startStreaming: jest.fn(),
    stopStreaming: jest.fn(),
    simulateMemoryWarningForTesting: jest.fn(),
    addListener: jest.fn((name: string, fn: (payload: unknown) => void) => {
      (listeners[name] ??= []).push(fn);
      return { remove: jest.fn(() => listeners[name].splice(listeners[name].indexOf(fn), 1)) };
    }),
  };
  return { __esModule: true, default: mockNative };
});

const native = mockedNative as unknown as jest.Mocked<ExpoWhisperKitNativeModule> & {
  __listeners: Record<string, ((payload: unknown) => void)[]>;
};
const listeners = native.__listeners;

const TRANSCRIPTION = {
  text: 'hi',
  language: 'en',
  segments: [{ text: 'hi', start: 0, end: 0.5 }],
};

beforeEach(() => jest.clearAllMocks());

describe('availability', () => {
  it('isAvailable is true with a native module', () => {
    expect(api.isAvailable()).toBe(true);
  });
  it('exports DEFAULT_MODEL = base', () => {
    expect(api.DEFAULT_MODEL).toBe('base');
  });
});

describe('models', () => {
  it('getModelStatus defaults the model', async () => {
    native.getModelStatus.mockResolvedValue({ model: 'base', state: 'absent' });
    await expect(api.getModelStatus()).resolves.toEqual({ model: 'base', state: 'absent' });
    expect(native.getModelStatus).toHaveBeenCalledWith('base');
  });
  it('getModelStatus passes a named model', async () => {
    native.getModelStatus.mockResolvedValue({ model: 'small.en', state: 'present' });
    await api.getModelStatus('small.en');
    expect(native.getModelStatus).toHaveBeenCalledWith('small.en');
  });
  it('downloadModel, deleteModel, loadModel, unloadModel, listDownloadedModels forward', async () => {
    native.downloadModel.mockResolvedValue(undefined);
    native.deleteModel.mockResolvedValue(undefined);
    native.loadModel.mockResolvedValue(undefined);
    native.unloadModel.mockResolvedValue(undefined);
    native.listDownloadedModels.mockResolvedValue(['base']);
    await api.downloadModel();
    await api.deleteModel('base');
    await api.loadModel('small');
    await api.unloadModel();
    await expect(api.listDownloadedModels()).resolves.toEqual(['base']);
    expect(native.downloadModel).toHaveBeenCalledWith('base');
    expect(native.deleteModel).toHaveBeenCalledWith('base');
    expect(native.loadModel).toHaveBeenCalledWith('small');
    expect(native.unloadModel).toHaveBeenCalledWith();
  });
  it('maps a download failure', async () => {
    native.downloadModel.mockRejectedValue(
      Object.assign(new Error('offline'), { code: 'download-failed' })
    );
    await expect(api.downloadModel()).rejects.toMatchObject({
      code: 'download-failed',
      message: 'offline',
    });
  });
  it('rewraps an unknown load error as load-failed', async () => {
    native.loadModel.mockRejectedValue(new Error('corrupt'));
    const err = await api.loadModel().catch((e) => e);
    expect(err).toBeInstanceOf(WhisperKitError);
    expect(err.code).toBe('load-failed');
  });
});

describe('transcribeFile', () => {
  it('resolves option defaults', async () => {
    native.transcribeFile.mockResolvedValue(TRANSCRIPTION);
    await expect(api.transcribeFile('file:///a.wav')).resolves.toEqual(TRANSCRIPTION);
    expect(native.transcribeFile).toHaveBeenCalledWith('file:///a.wav', {
      model: 'base',
      download: true,
    });
  });
  it('passes every option through', async () => {
    native.transcribeFile.mockResolvedValue(TRANSCRIPTION);
    await api.transcribeFile('/a.wav', {
      model: 'small.en',
      language: 'en',
      task: 'translate',
      prompt: 'tahini',
      download: false,
    });
    expect(native.transcribeFile).toHaveBeenCalledWith('/a.wav', {
      model: 'small.en',
      language: 'en',
      task: 'translate',
      prompt: 'tahini',
      download: false,
    });
  });
  it('rewraps an unknown error as decode-failed', async () => {
    native.transcribeFile.mockRejectedValue(new Error('bad file'));
    await expect(api.transcribeFile('/a')).rejects.toMatchObject({ code: 'decode-failed' });
  });
});

describe('recording', () => {
  it('permission calls forward', async () => {
    native.getMicrophonePermission.mockResolvedValue('undetermined');
    native.requestMicrophonePermission.mockResolvedValue('granted');
    await expect(api.getMicrophonePermission()).resolves.toBe('undetermined');
    await expect(api.requestMicrophonePermission()).resolves.toBe('granted');
  });
  it('startRecording maps permission-denied', async () => {
    native.startRecording.mockRejectedValue(
      Object.assign(new Error('no mic'), { code: 'permission-denied' })
    );
    await expect(api.startRecording()).rejects.toMatchObject({ code: 'permission-denied' });
  });
  it('startRecording rewraps unknown errors as recording-failed', async () => {
    native.startRecording.mockRejectedValue(new Error('engine'));
    await expect(api.startRecording()).rejects.toMatchObject({ code: 'recording-failed' });
  });
  it('stopRecording resolves defaults and returns the transcription', async () => {
    native.stopRecording.mockResolvedValue(TRANSCRIPTION);
    await expect(api.stopRecording({ language: 'en' })).resolves.toEqual(TRANSCRIPTION);
    expect(native.stopRecording).toHaveBeenCalledWith({
      model: 'base',
      language: 'en',
      download: true,
    });
  });
  it('cancelRecording forwards', async () => {
    native.cancelRecording.mockResolvedValue(undefined);
    await api.cancelRecording();
    expect(native.cancelRecording).toHaveBeenCalled();
  });
});

describe('streaming', () => {
  it('startStreaming and stopStreaming forward', async () => {
    native.startStreaming.mockResolvedValue(undefined);
    native.stopStreaming.mockResolvedValue(TRANSCRIPTION);
    await api.startStreaming({ model: 'small' });
    await expect(api.stopStreaming()).resolves.toEqual(TRANSCRIPTION);
    expect(native.startStreaming).toHaveBeenCalledWith({ model: 'small', download: true });
  });
});

describe('events', () => {
  it('addListener subscribes and remove unsubscribes', () => {
    const fn = jest.fn();
    const sub = api.addListener('downloadProgress', fn);
    expect(native.addListener).toHaveBeenCalledWith('downloadProgress', fn);
    listeners.downloadProgress[0]({ model: 'base', fraction: 0.5 });
    expect(fn).toHaveBeenCalledWith({ model: 'base', fraction: 0.5 });
    sub.remove();
    expect(listeners.downloadProgress).toHaveLength(0);
  });
});
