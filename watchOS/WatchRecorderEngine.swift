import Foundation
import AVFoundation

/// The engine keeps running across file boundaries. A bounded writer queue never
/// drops samples silently: overload stops capture and preserves the saved prefix.
final class WatchRecorderEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer = DispatchQueue(label: "xinlika.watch.audio-disk")
    private let lock = NSLock()
    private var pending = 0
    private var failed = false
    private var installed = false
    private var audioFrames = 0
    private var savedMilliseconds = 0
    var capturedMilliseconds: Int { lock.lock(); defer { lock.unlock() }; return savedMilliseconds }
    private var converter: AVAudioConverter?
    private var lastUpdate = 0.0
    var changed: (@Sendable (Double, Float) -> Void)?
    var failure: (@Sendable (Error) -> Void)?
    private let archive: WatchCaptureArchive
    private let recordingID: UUID
    init(archive: WatchCaptureArchive, recordingID: UUID) { self.archive = archive; self.recordingID = recordingID }
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { throw WatchCaptureError.invalidEvidence }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, target: target, converter: converter)
        }
        installed = true
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
    }
    private func consume(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat, converter: AVAudioConverter) {
        lock.lock(); let shouldStop = failed; lock.unlock(); if shouldStop { return }
        guard let output = AVAudioPCMBuffer(pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64)
        else { report(WatchCaptureError.storage); return }
        var fed = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return buffer
        }
        if let error { report(error); return }
        guard status != .error, let samples = output.int16ChannelData, output.frameLength > 0 else { return }
        let data = Data(bytes: samples[0], count: Int(output.frameLength) * 2)
        let offset = audioFrames / 16
        audioFrames += Int(output.frameLength)
        let elapsed = Double(audioFrames) / 16_000
        lock.lock()
        guard pending < 8 else { lock.unlock(); report(WatchCaptureError.storage); return }
        pending += 1; lock.unlock()
        let progress = elapsed - lastUpdate >= 1
        if progress { lastUpdate = elapsed }
        var peak: Float = 0
        for i in 0..<Int(output.frameLength) { peak = max(peak, Float(abs(Int(samples[0][i]))) / 32768) }
        writer.async { [weak self] in
            guard let self else { return }
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do { try archive.append(data, recording: recordingID, offsetMilliseconds: offset)
                lock.lock(); savedMilliseconds = offset + data.count / 32; lock.unlock()
                if progress { changed?(elapsed, peak) }
            } catch { report(error) }
        }
    }
    private func report(_ error: Error) {
        lock.lock(); let first = !failed; failed = true; lock.unlock()
        if first { failure?(error) }
    }
    func stop() {
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        engine.stop(); writer.sync {}
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
