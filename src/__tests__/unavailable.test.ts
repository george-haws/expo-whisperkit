import * as api from '../index';

jest.mock('../ExpoWhisperKitModule', () => ({ __esModule: true, default: null }));

describe('without a native module', () => {
  it('isAvailable is false', () => {
    expect(api.isAvailable()).toBe(false);
  });
  it('every call rejects with unsupported-platform', async () => {
    const calls = [
      () => api.getModelStatus(),
      () => api.downloadModel(),
      () => api.deleteModel('base'),
      () => api.listDownloadedModels(),
      () => api.loadModel(),
      () => api.unloadModel(),
      () => api.transcribeFile('/a'),
      () => api.getMicrophonePermission(),
      () => api.requestMicrophonePermission(),
      () => api.startRecording(),
      () => api.stopRecording(),
      () => api.cancelRecording(),
      () => api.startStreaming(),
      () => api.stopStreaming(),
    ];
    for (const call of calls) {
      await expect(call()).rejects.toMatchObject({
        name: 'WhisperKitError',
        code: 'unsupported-platform',
      });
    }
  });
  it('addListener returns a no-op subscription', () => {
    const sub = api.addListener('audioLevel', () => {});
    expect(() => sub.remove()).not.toThrow();
  });
});
