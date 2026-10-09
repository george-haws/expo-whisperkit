import { Asset } from 'expo-asset';
import * as WhisperKit from 'expo-whisperkit';
import { useEffect, useState } from 'react';
import { Button, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';

export default function App() {
  const [model, setModel] = useState(WhisperKit.DEFAULT_MODEL);
  const [status, setStatus] = useState<WhisperKit.ModelState | 'unknown'>('unknown');
  const [progress, setProgress] = useState<number | null>(null);
  const [transcript, setTranscript] = useState('');
  const [error, setError] = useState('');

  async function refresh() {
    try {
      setStatus((await WhisperKit.getModelStatus(model)).state);
    } catch (e) {
      setError(describe(e));
    }
  }

  useEffect(() => {
    refresh();
    const state = WhisperKit.addListener('modelState', (p) => {
      if (p.model === model) setStatus(p.state);
    });
    const dl = WhisperKit.addListener('downloadProgress', (p) => {
      if (p.model === model) setProgress(p.fraction >= 1 ? null : p.fraction);
    });
    return () => {
      state.remove();
      dl.remove();
    };
  }, [model]);

  async function run(label: string, fn: () => Promise<unknown>) {
    setError('');
    setTranscript('');
    try {
      const result = await fn();
      if (typeof result === 'object' && result && 'text' in result) {
        setTranscript((result as WhisperKit.Transcription).text);
      }
    } catch (e) {
      setError(`${label}: ${describe(e)}`);
    }
  }

  const [permission, setPermission] = useState<WhisperKit.PermissionStatus | 'unknown'>('unknown');
  const [capture, setCapture] = useState<'idle' | 'recording' | 'streaming'>('idle');
  const [level, setLevel] = useState(0);
  const [pttDone, setPttDone] = useState(false);

  useEffect(() => {
    WhisperKit.getMicrophonePermission().then(setPermission).catch(() => {});
    const sub = WhisperKit.addListener('audioLevel', (p) => setLevel(p.level));
    return () => sub.remove();
  }, []);

  async function startRecording() {
    setPttDone(false);
    await run('start', async () => {
      await WhisperKit.startRecording();
      setCapture('recording');
    });
  }

  async function stopRecording() {
    await run('stop', async () => {
      try {
        return await WhisperKit.stopRecording({ model });
      } finally {
        setCapture('idle');
        setPttDone(true);
      }
    });
  }

  const [confirmed, setConfirmed] = useState('');
  const [pending, setPending] = useState('');
  const [streamDone, setStreamDone] = useState(false);

  useEffect(() => {
    const sub = WhisperKit.addListener('streamingUpdate', (p) => {
      setConfirmed(p.confirmedText);
      setPending(p.pendingText);
    });
    return () => sub.remove();
  }, []);

  async function startStreaming() {
    setStreamDone(false);
    setConfirmed('');
    setPending('');
    await run('stream-start', async () => {
      await WhisperKit.startStreaming({ model });
      setCapture('streaming');
    });
  }

  async function stopStreaming() {
    await run('stream-stop', async () => {
      try {
        return await WhisperKit.stopStreaming();
      } finally {
        setCapture('idle');
        setStreamDone(true);
      }
    });
  }

  /** Deterministic push-to-talk for Maestro: two seconds of capture, then stop. */
  async function recordTwoSeconds() {
    await startRecording();
    await new Promise((r) => setTimeout(r, 2000));
    await stopRecording();
  }

  async function fixturePath() {
    const asset = Asset.fromModule(require('./assets/fixture.wav'));
    await asset.downloadAsync();
    return asset.localUri!;
  }

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.h1}>expo-whisperkit</Text>
        <Text testID="availability">{WhisperKit.isAvailable() ? 'available' : 'unavailable'}</Text>

        <Text style={styles.label}>Model</Text>
        <TextInput testID="model-input" style={styles.input} value={model} onChangeText={setModel} autoCapitalize="none" />
        <Text style={styles.label}>Status</Text>
        <Text testID="status" style={styles.status}>{status}</Text>
        {progress !== null && <Text testID="progress">{Math.round(progress * 100)}%</Text>}

        <View style={styles.row}>
          <Button testID="download" title="Download" onPress={() => run('download', () => WhisperKit.downloadModel(model))} />
          <Button testID="load" title="Load" onPress={() => run('load', () => WhisperKit.loadModel(model))} />
          <Button testID="unload" title="Unload" onPress={() => run('unload', () => WhisperKit.unloadModel())} />
          <Button testID="delete" title="Delete" onPress={() => run('delete', () => WhisperKit.deleteModel(model))} />
        </View>
        <View style={styles.row}>
          <Button
            testID="transcribe-fixture"
            title="Transcribe fixture"
            onPress={() => run('transcribe', async () => WhisperKit.transcribeFile(await fixturePath(), { model }))}
          />
          <Button testID="memory-warning" title="Memory warning" onPress={() => run('memory', () => WhisperKit.simulateMemoryWarningForTesting())} />
        </View>

        <Text style={styles.label}>Microphone</Text>
        <Text testID="permission">{permission}</Text>
        <Button
          testID="request-permission"
          title="Request permission"
          onPress={() => run('permission', async () => setPermission(await WhisperKit.requestMicrophonePermission()))}
        />
        <Text style={styles.label}>Capture</Text>
        <Text testID="capture">{capture}</Text>
        <Text testID="level">{`level ${Math.round(level * 100)}`}</Text>
        <View style={styles.row}>
          <Button testID="start-recording" title="Start" onPress={startRecording} />
          <Button testID="stop-recording" title="Stop" onPress={stopRecording} />
          <Button testID="record-2s" title="Record 2 s" onPress={recordTwoSeconds} />
          <Button
            testID="cancel-recording"
            title="Cancel"
            onPress={() => run('cancel', async () => { await WhisperKit.cancelRecording(); setCapture('idle'); })}
          />
        </View>
        {pttDone && <Text testID="ptt-done">push-to-talk finished</Text>}

        <Text style={styles.label}>Streaming</Text>
        <View style={styles.row}>
          <Button testID="start-streaming" title="Start streaming" onPress={startStreaming} />
          <Button testID="stop-streaming" title="Stop streaming" onPress={stopStreaming} />
        </View>
        <Text testID="streaming-confirmed">{confirmed}</Text>
        <Text testID="streaming-pending" style={{ color: '#888' }}>{pending}</Text>
        {streamDone && <Text testID="stream-done">streaming finished</Text>}

        <Text style={styles.label}>Transcript</Text>
        <Text testID="transcript" style={styles.transcript}>{transcript}</Text>
        {error !== '' && <Text testID="error" style={styles.error}>{error}</Text>}
      </ScrollView>
    </SafeAreaView>
  );
}

function describe(e: unknown): string {
  if (e instanceof WhisperKit.WhisperKitError) return `${e.code}: ${e.message}`;
  return e instanceof Error ? e.message : String(e);
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  content: { padding: 16, gap: 8 },
  h1: { fontSize: 24, fontWeight: '600' },
  label: { fontSize: 12, color: '#666', marginTop: 8 },
  input: { borderWidth: 1, borderColor: '#ccc', borderRadius: 6, padding: 8, fontSize: 16 },
  status: { fontSize: 18 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  transcript: { fontSize: 16, minHeight: 24 },
  error: { color: '#b00020' },
});
