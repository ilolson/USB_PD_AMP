# HUB75 Audio Matrix

macOS SwiftUI + Metal simulator for a 64x64 HUB75 RGB matrix panel driven by live system audio captured with ScreenCaptureKit.

## Features

- 64x64 logical RGB framebuffer and 1/32-scan HUB75 simulation.
- GPIO trace decoder for CLK, LAT/STB, OE, row address, and upper/lower RGB data lines.
- ScreenCaptureKit system-audio capture with 48 kHz stereo preference and optional exclusion of this app's audio.
- Accelerate-based RMS, peak, envelope, FFT spectrum, frequency bands, smoothing, noise floor, and AGC.
- Working framebuffer visualizers: spectrum bars, oscilloscope, and bass-reactive glow, plus additional diagnostic modes.
- Metal compute upload path and instanced LED renderer with fallback-friendly 2D/lens/object/ray-preview modes.

## Hardware Notes

HUB75 GPIO mapping follows the board schematic:

- R0/G0/B0: GPIO16/GPIO17/GPIO18
- R1/G1/B1: GPIO19/GPIO27/GPIO29
- ROW_E: GPIO28
- ROW_A/B/C/D: GPIO31/GPIO32/GPIO33/GPIO34
- CLK/LAT/OE: GPIO35/GPIO36/GPIO37

Audio codec pins:

- I2S DIN/DOUT/FSYNC/BCLK: GPIO0/GPIO1/GPIO2/GPIO3
- I2C SDA/SCL: GPIO4/GPIO5
- TAD5112 interrupt/event input: GPIO6
- AMP power: GPIO7

Do not use GPIO4/GPIO5 SDA/SCL as event interrupt lines. Codec events should interrupt on GPIO6, then firmware should read status registers over I2C.

## Build

Open `Hub75AudioMatrix.xcodeproj` in Xcode and run the `Hub75AudioMatrix` scheme on macOS 14 or newer. On first audio capture, macOS may prompt for screen and system audio recording permission.
