import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// An AudioProcessing with no microphone. Tests `feed` samples; the Recorder reads them back.
final class FakeProcessor: AudioProcessing, @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Float] = []
  private var energy: [Float] = [0.5]
  private var _isRecording = false
  private var _startCalls = 0
  private var _stopCalls = 0
  private var _startError: Error?

  var relativeEnergyWindow: Int = 20

  var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return _isRecording }
  var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
  var stopCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopCalls }

  func setStartError(_ error: Error?) { lock.lock(); _startError = error; lock.unlock() }
  func setEnergy(_ values: [Float]) { lock.lock(); energy = values; lock.unlock() }

  /// Audio "captured" since the last start.
  func feed(_ values: [Float]) { lock.lock(); samples += values; lock.unlock() }

  var audioSamples: ContiguousArray<Float> {
    lock.lock(); defer { lock.unlock() }
    return ContiguousArray(samples)
  }

  func purgeAudioSamples(keepingLast keep: Int) {
    lock.lock(); samples = Array(samples.suffix(keep)); lock.unlock()
  }

  var relativeEnergy: [Float] { lock.lock(); defer { lock.unlock() }; return energy }

  func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
    lock.lock(); defer { lock.unlock() }
    _startCalls += 1
    if let error = _startError { throw error }
    _isRecording = true
  }

  func startStreamingRecordingLive(inputDeviceID: DeviceID?)
    -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation)
  {
    var continuation: AsyncThrowingStream<[Float], Error>.Continuation!
    let stream = AsyncThrowingStream<[Float], Error> { continuation = $0 }
    return (stream, continuation)
  }

  func pauseRecording() {}

  func stopRecording() {
    lock.lock(); _stopCalls += 1; _isRecording = false; lock.unlock()
  }

  func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {}

  func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int)
    -> (any AudioProcessorOutputType)?
  {
    nil
  }

  static func loadAudio(
    fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?,
    maxReadFrameSize: AVAudioFrameCount?
  ) throws -> AVAudioPCMBuffer {
    throw NSError(domain: "FakeProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "no files in tests"])
  }

  static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
    []
  }

  static func padOrTrimAudio(
    fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool
  ) -> MLMultiArray? {
    nil
  }
}
