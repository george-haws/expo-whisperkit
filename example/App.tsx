import ExpoWhisperKit from 'expo-whisperkit';
import { SafeAreaView, Text } from 'react-native';

export default function App() {
  const name = ExpoWhisperKit ? ExpoWhisperKit.deviceName() : 'native module missing';
  return (
    <SafeAreaView style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}>
      <Text testID="device-name">{name}</Text>
    </SafeAreaView>
  );
}
