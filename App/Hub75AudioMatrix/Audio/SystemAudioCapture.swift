import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class SystemAudioCapture: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var statusText = "Idle"
    @Published var excludesCurrentProcessAudio = true

    let ringBuffer = AudioRingBuffer()

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "SystemAudioCapture.audio")

    func start() async {
        guard !isCapturing else { return }
        statusText = "Starting"

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                statusText = "No display"
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = excludesCurrentProcessAudio
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let output = AudioStreamOutput(ringBuffer: ringBuffer) { [weak self] text in
                Task { @MainActor in self?.statusText = text }
            }

            let newStream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: captureQueue)
            try await newStream.startCapture()

            stream = newStream
            streamOutput = output
            isCapturing = true
            statusText = "Capturing"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
            isCapturing = false
        }
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            statusText = "Stop error: \(error.localizedDescription)"
        }
        self.stream = nil
        streamOutput = nil
        isCapturing = false
        if !statusText.hasPrefix("Stop error") {
            statusText = "Stopped"
        }
    }

    private var streamOutput: AudioStreamOutput?
}

private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let ringBuffer: AudioRingBuffer
    private let status: (String) -> Void

    init(ringBuffer: AudioRingBuffer, status: @escaping (String) -> Void) {
        self.ringBuffer = ringBuffer
        self.status = status
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        status("Stream error: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let asbd = asbdPointer.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, asbd.mChannelsPerFrame > 0 else { return }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let format = makeAVFormat(from: asbd)
        guard let pcmFormat = format,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            status("Unsupported audio format")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let statusCode = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard statusCode == noErr else {
            status("PCM copy failed \(statusCode)")
            return
        }

        if let floats = pcmBuffer.floatChannelData {
            var interleaved = Array(repeating: Float(0), count: frameCount * channelCount)
            for channel in 0..<channelCount {
                let src = floats[channel]
                for frame in 0..<frameCount {
                    interleaved[frame * channelCount + channel] = src[frame]
                }
            }
            ringBuffer.push(interleaved: interleaved, channels: channelCount)
        } else if let ints = pcmBuffer.int16ChannelData {
            var interleaved = Array(repeating: Float(0), count: frameCount * channelCount)
            let scale = Float(Int16.max)
            for channel in 0..<channelCount {
                let src = ints[channel]
                for frame in 0..<frameCount {
                    interleaved[frame * channelCount + channel] = Float(src[frame]) / scale
                }
            }
            ringBuffer.push(interleaved: interleaved, channels: channelCount)
        }
    }

    private func makeAVFormat(from asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let commonFormat: AVAudioCommonFormat = isFloat ? .pcmFormatFloat32 : .pcmFormatInt16
        return AVAudioFormat(commonFormat: commonFormat,
                             sampleRate: asbd.mSampleRate,
                             channels: asbd.mChannelsPerFrame,
                             interleaved: !isNonInterleaved)
    }
}
