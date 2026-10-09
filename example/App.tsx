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
    try {
      const result = await fn();
      if (typeof result === 'object' && result && 'text' in result) {
        setTranscript((result as WhisperKit.Transcription).text);
      }
    } catch (e) {
      setError(`${label}: ${describe(e)}`);
    } finally {
      refresh();
    }
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

        <Text style={styles.label}>Transcript</Text>
        <Text testID="transcript" style={styles.transcript}>{transcript}</Text>
        <Text testID="error" style={styles.error}>{error}</Text>
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
