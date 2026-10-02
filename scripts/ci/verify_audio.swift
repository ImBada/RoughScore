import AVFoundation
import AudioToolbox
import Foundation

// Independently check the generated lossy file before passing it to the app's
// existing integration test. Quiet/active windows are inside the tone edges so
// AAC padding and transient smearing cannot masquerade as channel swaps.
guard CommandLine.arguments.count == 2 else {
    fatalError("usage: verify_audio.swift GENERATED_M4A_PATH")
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
let format = file.processingFormat
guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
      format.channelCount == 2, abs(format.sampleRate - 48_000) < 1,
      abs(Double(file.length) / format.sampleRate - 2) < 0.05 else {
    fatalError("Generated compressed fixture has incorrect channels, sample rate or duration")
}
guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
    fatalError("Cannot allocate generated-fixture decode buffer")
}
try file.read(into: buffer)
guard let channels = buffer.floatChannelData, Int64(buffer.frameLength) == file.length else {
    fatalError("Generated compressed fixture did not decode completely")
}
func rms(_ channel: Int, _ start: Double, _ end: Double) -> Double {
    let lower = Int(start * format.sampleRate)
    let upper = Int(end * format.sampleRate)
    var energy = 0.0
    for frame in lower..<upper {
        let sample = Double(channels[channel][frame])
        guard sample.isFinite else { fatalError("Non-finite decoded sample") }
        energy += sample * sample
    }
    return sqrt(energy / Double(upper - lower))
}
let leftActive = rms(0, 0.3, 0.7)
let rightQuiet = rms(1, 0.3, 0.7)
let rightActive = rms(1, 1.3, 1.7)
let leftQuiet = rms(0, 1.3, 1.7)
guard leftActive > 0.15, rightActive > 0.15,
      rightQuiet < 0.01, leftQuiet < 0.01 else {
    fatalError("Generated AAC channel separation failed: \(leftActive), \(rightQuiet), \(rightActive), \(leftQuiet)")
}
let result: [String: Any] = [
    "status": "passed",
    "codec": "AAC",
    "coverage": "generated AAC decode and independent stereo activity; not real-guitar quality",
    "sampleRate": format.sampleRate,
    "decodedFrames": buffer.frameLength,
    "leftActiveRMS": leftActive, "rightQuietRMS": rightQuiet,
    "rightActiveRMS": rightActive, "leftQuietRMS": leftQuiet
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
