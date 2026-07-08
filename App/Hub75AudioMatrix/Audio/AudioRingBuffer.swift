import Foundation

final class AudioRingBuffer: ObservableObject {
    private let lock = NSLock()
    private var storage: [Float]
    private var writeIndex = 0
    private var availableFrames = 0
    private(set) var channels: Int
    let sampleRate: Double

    @Published private(set) var overrunCount = 0
    @Published private(set) var underrunCount = 0

    init(seconds: Double = 8.0, sampleRate: Double = 48_000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.storage = Array(repeating: 0, count: max(1, Int(seconds * sampleRate) * channels))
    }

    var statusText: String {
        lock.lock()
        let frames = availableFrames
        let overruns = overrunCount
        let underruns = underrunCount
        lock.unlock()
        return "\(frames) frames, OVR \(overruns), UND \(underruns)"
    }

    func push(interleaved samples: [Float], channels newChannelCount: Int) {
        guard newChannelCount > 0 else { return }
        lock.lock()
        channels = newChannelCount
        let frameCount = samples.count / newChannelCount
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
        }
        availableFrames = min(storage.count / newChannelCount, availableFrames + frameCount)
        if frameCount * newChannelCount >= storage.count {
            overrunCount += 1
        }
        lock.unlock()
    }

    func latestMono(frameCount requestedFrames: Int) -> [Float] {
        lock.lock()
        let currentChannels = max(1, channels)
        let readableFrames = min(requestedFrames, availableFrames, storage.count / currentChannels)
        if readableFrames < requestedFrames {
            underrunCount += 1
        }

        let totalSamples = readableFrames * currentChannels
        let start = (writeIndex - totalSamples + storage.count) % storage.count
        var mono = Array(repeating: Float(0), count: requestedFrames)

        for frame in 0..<readableFrames {
            var sum: Float = 0
            for channel in 0..<currentChannels {
                let index = (start + frame * currentChannels + channel) % storage.count
                sum += storage[index]
            }
            mono[requestedFrames - readableFrames + frame] = sum / Float(currentChannels)
        }

        lock.unlock()
        return mono
    }

    func latestStereoLevels(frameCount requestedFrames: Int) -> (left: Float, right: Float) {
        lock.lock()
        let currentChannels = max(1, channels)
        let readableFrames = min(requestedFrames, availableFrames, storage.count / currentChannels)
        let totalSamples = readableFrames * currentChannels
        let start = (writeIndex - totalSamples + storage.count) % storage.count
        var leftPeak: Float = 0
        var rightPeak: Float = 0

        for frame in 0..<readableFrames {
            let left = abs(storage[(start + frame * currentChannels) % storage.count])
            let rightIndex = currentChannels > 1 ? 1 : 0
            let right = abs(storage[(start + frame * currentChannels + rightIndex) % storage.count])
            leftPeak = max(leftPeak, left)
            rightPeak = max(rightPeak, right)
        }

        lock.unlock()
        return (leftPeak, rightPeak)
    }
}
