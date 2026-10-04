import AudioToolbox
import AVFoundation
import Darwin
import Foundation
import RoughScoreCore

/// CAF writes are positional callbacks on the exclusively created inode. No native write opens a
/// stage pathname, so replacing its directory entry with a symlink cannot overwrite user media.
final class PinnedPCMWriter {
    private let file: OwnedArtifactCache.Stage.WritableFile
    private let context: UnsafeMutablePointer<Int32>
    private var audioID: AudioFileID?
    private var position: Int64 = 0
    private let channels: Int
    private let sampleRate: Double
    private var interleaved: [Float]
    init(file: OwnedArtifactCache.Stage.WritableFile, sampleRate: Double, channels: Int) throws {
        guard (1...2).contains(channels), sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { throw AudioIssue.unsupported }
        self.file = file; self.channels = channels; self.sampleRate = sampleRate
        interleaved = [Float](repeating: 0, count: 4096 * channels)
        context = .allocate(capacity: 1); context.initialize(to: file.descriptor)
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var created: AudioFileID?
        let status = AudioFileInitializeWithCallbacks(context, { context, position, count, buffer, actual in
            let result = pread(context.assumingMemoryBound(to: Int32.self).pointee, buffer, Int(count), off_t(position))
            guard result >= 0 else { actual.pointee = 0; return kAudioFileUnspecifiedError }
            actual.pointee = UInt32(result); return noErr
        }, { context, position, count, buffer, actual in
            let descriptor = context.assumingMemoryBound(to: Int32.self).pointee
            var written = 0
            while written < count {
                let result = pwrite(descriptor, buffer.advanced(by: written), Int(count) - written, off_t(position) + off_t(written))
                guard result > 0 else { actual.pointee = UInt32(written); return kAudioFileUnspecifiedError }
                written += result
            }
            actual.pointee = count; return noErr
        }, { context in
            var info = stat()
            return fstat(context.assumingMemoryBound(to: Int32.self).pointee, &info) == 0 ? info.st_size : 0
        }, { context, size in
            ftruncate(context.assumingMemoryBound(to: Int32.self).pointee, off_t(size)) == 0 ? noErr : kAudioFileUnspecifiedError
        }, kAudioFileCAFType, &format, [], &created)
        guard status == noErr, let created else {
            if let created { AudioFileClose(created) }
            context.deinitialize(count: 1); context.deallocate()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        audioID = created
    }
    deinit { close(); context.deinitialize(count: 1); context.deallocate() }
    func close() {
        if let audioID { AudioFileClose(audioID); self.audioID = nil }
    }
    func write(from buffer: AVAudioPCMBuffer) throws {
        guard let audioID, let samples = buffer.floatChannelData, buffer.frameLength > 0,
              buffer.frameLength <= 4096, buffer.format.sampleRate == sampleRate,
              Int(buffer.format.channelCount) == channels else { throw AudioIssue.unsupported }
        let frames = Int(buffer.frameLength)
        var count = buffer.frameLength
        let status: OSStatus
        if channels == 1 {
            status = AudioFileWritePackets(audioID, false, UInt32(frames * 4), nil, position, &count, samples[0])
        } else {
            for i in 0..<frames { for c in 0..<channels { interleaved[i * channels + c] = samples[c][i] } }
            status = interleaved.withUnsafeBytes {
                AudioFileWritePackets(audioID, false, UInt32(frames * channels * 4), nil, position, &count, $0.baseAddress!)
            }
        }
        guard status == noErr, count == buffer.frameLength else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        position += Int64(count)
    }
}
