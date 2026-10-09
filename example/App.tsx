import * as WhisperKit from 'expo-whisperkit';
import { SafeAreaView, Text } from 'react-native';

export default function App() {
  return (
    <SafeAreaView style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}>
      <Text testID="device-name">{WhisperKit.isAvailable() ? 'available' : 'unavailable'}</Text>
    </SafeAreaView>
  );
}
