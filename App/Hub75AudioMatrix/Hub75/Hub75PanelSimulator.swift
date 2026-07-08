import Foundation

struct Hub75Settings {
    var brightness: Double = 0.85
    var gamma: Double = 2.2
    var bitDepth: Int = 6
    var scanRateHz: Double = 2_400
    var oeActiveLow = true
    var latRisingEdge = true
    var serpentineRows = false
    var ghosting: Double = 0.04
    var ledBleed: Double = 0.08
    var temporalExposure: Double = 0.7
}

struct Hub75Diagnostics {
    var refreshRate: Double = 0
    var rowScanRate: Double = 0
    var oeDuty: Double = 0
    var missedClocks: Int = 0
    var latchEvents: Int = 0

    var refreshRateText: String { "\(Int(refreshRate)) Hz" }
    var rowScanRateText: String { "\(Int(rowScanRate)) rows/s" }
    var oeDutyText: String { "\(Int(oeDuty * 100))%" }
}

@MainActor
final class Hub75PanelSimulator: ObservableObject {
    @Published var settings = Hub75Settings()
    @Published private(set) var diagnostics = Hub75Diagnostics()

    private var logicalFramebuffer = Array(repeating: RGBPixel.black, count: 64 * 64)
    private var previousIntensity = Array(repeating: RGBPixel.black, count: 64 * 64)
    private let gpioDecoder = GPIOTraceDecoder()

    func setFramebuffer(_ framebuffer: [RGBPixel]) {
        guard framebuffer.count == 64 * 64 else { return }
        logicalFramebuffer = framebuffer
    }

    func ingestGPIOTrace(_ changes: [GPIOStateChange]) {
        let decoded = gpioDecoder.decode(changes: changes, settings: settings)
        logicalFramebuffer = decoded.framebuffer
        diagnostics.missedClocks = decoded.diagnostics.missedClocks
        diagnostics.latchEvents = decoded.diagnostics.latchEvents
    }

    func simulateOutput(deltaTime: Double) -> [RGBPixel] {
        let bitDepth = max(1, min(8, settings.bitDepth))
        let rowPairs = 32.0
        let rowScanRate = settings.scanRateHz
        let refreshRate = rowScanRate / rowPairs / Double(bitDepth)
        let oeDuty = min(1, max(0, 0.82 - settings.ghosting * 0.6))

        diagnostics.refreshRate = refreshRate
        diagnostics.rowScanRate = rowScanRate
        diagnostics.oeDuty = oeDuty

        var output = Array(repeating: RGBPixel.black, count: 64 * 64)
        for rowPair in 0..<32 {
            for plane in 0..<bitDepth {
                let weight = Float(1 << plane) / Float((1 << bitDepth) - 1)
                accumulate(row: rowPair, planeWeight: weight, into: &output)
                accumulate(row: rowPair + 32, planeWeight: weight, into: &output)
            }
        }

        let exposure = Float(settings.temporalExposure)
        let brightness = Float(settings.brightness * oeDuty)
        let gamma = Float(settings.gamma)
        let ghost = Float(settings.ghosting)
        let bleed = Float(settings.ledBleed)

        for i in output.indices {
            var pixel = output[i] * brightness
            pixel = RGBPixel(r: pow(max(0, pixel.r), gamma),
                             g: pow(max(0, pixel.g), gamma),
                             b: pow(max(0, pixel.b), gamma))

            if ghost > 0 {
                pixel = pixel + previousIntensity[i] * ghost
            }
            if bleed > 0 {
                pixel = applyBleed(index: i, source: output, base: pixel, amount: bleed)
            }

            output[i] = previousIntensity[i] * (1 - exposure) + pixel * exposure
        }

        previousIntensity = output
        return output
    }

    func rawFramebuffer() -> [RGBPixel] {
        logicalFramebuffer
    }

    private func accumulate(row: Int, planeWeight: Float, into output: inout [RGBPixel]) {
        let y = settings.serpentineRows && row % 2 == 1 ? 63 - row : row
        for x in 0..<64 {
            let src = logicalFramebuffer[y * 64 + x]
            output[y * 64 + x] = output[y * 64 + x] + src * planeWeight
        }
    }

    private func applyBleed(index: Int, source: [RGBPixel], base: RGBPixel, amount: Float) -> RGBPixel {
        let x = index % 64
        let y = index / 64
        var sum = RGBPixel.black
        var count: Float = 0
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let xx = x + dx
                let yy = y + dy
                if xx >= 0, xx < 64, yy >= 0, yy < 64 {
                    sum = sum + source[yy * 64 + xx]
                    count += 1
                }
            }
        }
        guard count > 0 else { return base }
        return base * (1 - amount) + sum * (amount / count)
    }
}
