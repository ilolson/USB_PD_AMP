import Foundation

struct GPIOPins {
    static let r0 = 16
    static let g0 = 17
    static let b0 = 18
    static let r1 = 19
    static let g1 = 27
    static let rowE = 28
    static let b1 = 29
    static let rowA = 31
    static let rowB = 32
    static let rowC = 33
    static let rowD = 34
    static let clk = 35
    static let lat = 36
    static let oe = 37

    static let tadI2SDin = 0
    static let tadI2SDout = 1
    static let tadI2SFsync = 2
    static let tadI2SBclk = 3
    static let tadI2CSda = 4
    static let tadI2CScl = 5
    static let tadInterrupt = 6
    static let ampPower = 7
}

struct GPIOStateChange {
    var timestamp: TimeInterval
    var gpio: Int
    var isHigh: Bool
}

struct GPIODecoderDiagnostics {
    var rowDwellTime: Double = 0
    var refreshRate: Double = 0
    var missedClocks: Int = 0
    var latchEvents: Int = 0
    var oeDutyCycle: Double = 0
}

struct GPIODecodeResult {
    var framebuffer: [RGBPixel]
    var diagnostics: GPIODecoderDiagnostics
}

final class GPIOTraceDecoder {
    private var state = [Int: Bool]()
    private var shiftUpper = Array(repeating: RGBPixel.black, count: 64)
    private var shiftLower = Array(repeating: RGBPixel.black, count: 64)
    private var shiftIndex = 0
    private var framebuffer = Array(repeating: RGBPixel.black, count: 64 * 64)
    private var lastClock = false
    private var lastLatch = false
    private var lastOEToggle: TimeInterval?
    private var oeActiveTime: Double = 0

    func decode(changes: [GPIOStateChange], settings: Hub75Settings) -> GPIODecodeResult {
        var diagnostics = GPIODecoderDiagnostics()

        for change in changes.sorted(by: { $0.timestamp < $1.timestamp }) {
            let previous = state[change.gpio] ?? false
            state[change.gpio] = change.isHigh

            if change.gpio == GPIOPins.oe {
                updateOEDuty(timestamp: change.timestamp, settings: settings)
            }

            if change.gpio == GPIOPins.clk {
                let rising = !previous && change.isHigh
                if rising {
                    clockPixel()
                    if shiftIndex > 64 {
                        diagnostics.missedClocks += 1
                    }
                }
                lastClock = change.isHigh
            }

            if change.gpio == GPIOPins.lat {
                let activeEdge = settings.latRisingEdge ? (!previous && change.isHigh) : (previous && !change.isHigh)
                if activeEdge {
                    latch()
                    diagnostics.latchEvents += 1
                }
                lastLatch = change.isHigh
            }
        }

        if let first = changes.first?.timestamp, let last = changes.last?.timestamp, last > first {
            diagnostics.oeDutyCycle = oeActiveTime / (last - first)
            diagnostics.refreshRate = Double(diagnostics.latchEvents) / max(0.001, last - first) / 32.0
            diagnostics.rowDwellTime = (last - first) / max(1, Double(diagnostics.latchEvents))
        }

        return GPIODecodeResult(framebuffer: framebuffer, diagnostics: diagnostics)
    }

    private func clockPixel() {
        guard shiftIndex < 64 else {
            shiftIndex += 1
            return
        }

        shiftUpper[shiftIndex] = RGBPixel(r: high(GPIOPins.r0) ? 1 : 0,
                                          g: high(GPIOPins.g0) ? 1 : 0,
                                          b: high(GPIOPins.b0) ? 1 : 0)
        shiftLower[shiftIndex] = RGBPixel(r: high(GPIOPins.r1) ? 1 : 0,
                                          g: high(GPIOPins.g1) ? 1 : 0,
                                          b: high(GPIOPins.b1) ? 1 : 0)
        shiftIndex += 1
    }

    private func latch() {
        let row = activeRow()
        guard row >= 0, row < 32 else { return }
        for x in 0..<64 {
            framebuffer[row * 64 + x] = shiftUpper[x]
            framebuffer[(row + 32) * 64 + x] = shiftLower[x]
        }
        shiftIndex = 0
        shiftUpper = Array(repeating: .black, count: 64)
        shiftLower = Array(repeating: .black, count: 64)
    }

    private func activeRow() -> Int {
        (high(GPIOPins.rowA) ? 1 : 0)
        | (high(GPIOPins.rowB) ? 2 : 0)
        | (high(GPIOPins.rowC) ? 4 : 0)
        | (high(GPIOPins.rowD) ? 8 : 0)
        | (high(GPIOPins.rowE) ? 16 : 0)
    }

    private func updateOEDuty(timestamp: TimeInterval, settings: Hub75Settings) {
        defer { lastOEToggle = timestamp }
        guard let lastOEToggle else { return }
        let wasActive = settings.oeActiveLow ? !(state[GPIOPins.oe] ?? true) : (state[GPIOPins.oe] ?? false)
        if wasActive {
            oeActiveTime += timestamp - lastOEToggle
        }
    }

    private func high(_ pin: Int) -> Bool {
        state[pin] ?? false
    }
}
