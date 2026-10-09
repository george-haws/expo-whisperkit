// Reexport the native module. On web, it will be resolved to ExpoWhisperKitModule.web.ts
// and on native platforms to ExpoWhisperKitModule.ts
export { default } from './ExpoWhisperKitModule';
export * from './ExpoWhisperKit.types';
