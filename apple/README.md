# Assist Arm for macOS

Native port of the lab's `Assist_Demo` (the `Assist_Demo_hasegawa` live-EMG variant) from
Windows/NI-DAQ/GLUT to a SwiftUI app with Delsys Trigno EMG and a USB serial link to the
Futaba servos.

```
apple/
  project.yml          XcodeGen spec (source of truth); run `xcodegen generate`
  AssistArm.xcodeproj  generated
  AssistArmApp/        SwiftUI app (macOS 14+)
  AssistArmKit/        Swift package
    AssistArmCore      Koike filter, quasi-tension, min/max calibration, musculoskeletal model,
                       stiffness policy, control loop, telemetry CSV, synthetic EMG, simulated servos
    FutabaRS           Futaba RS packet codec, POSIX serial port, TCP serial bridge, servo driver
    TrignoEMG          EMG source on TrignoKit (Delsys Trigno SDK server over TCP)
    LSLEMG             EMG source on a Lab Streaming Layer inlet (liblsl via TrignoKit's CLSL)
    assist-arm         headless CLI for bench tests
```

## Signal path (what the legacy code did, kept 1:1 unless noted)

1. EMG at 2 kHz, two channels → rectify → mean of 10 samples (200 Hz) → Koike FIR
   (100 taps, `6.44(e^-10.8t − e^-16.52t)`, unit gain) = quasi-tension.
2. Calibration: min/max of quasi-tension per channel, first second discarded. Activation =
   clamp((qt − min)/(max − min), 0, 1).
3. Model (`param_eq.txt`, `param_trq.txt`, 9 parameters each, shipped as resources):
   equilibrium = −(p0 + Σ p_i u_i + Σ p_{n+i} u_i²)/(p_{2n+1} + Σ p_{2n+2+i} u_i) rad;
   stiffness = −denominator. Normalised stiffness 0…100.
   *Changed:* the 0…100 scale now spans the stiffness at activations (0,0) and (1,1). The legacy
   code evaluated it at the raw quasi-tension min/max while feeding normalised activations, so it
   depended on signal gain.
4. Servo goals: angle (deg, clamped ±90) × 10 units/deg + zero offset; the right servo is
   mirrored. *Changed:* legacy used 8 units/deg although Futaba positions are 0.1°. Adjustable
   under Mode › Advanced.
5. Compliance (Futaba slope, 0x1A/0x1B): soft 0xFF, stiff 0x32. Modes: low, high, high-or-low
   with threshold (legacy default 40), and linear. *Changed:* linear now interpolates soft→stiff
   from the threshold to 100; the legacy linear branch sent a stray pointer value.
6. Loop at 50 Hz (legacy ~10 ms timer + 100 ms sleep), status read-back at 5 Hz, CSV telemetry.

## Build

Requires Xcode 16+ (the SwiftUI macros are not in the Command Line Tools) and the
`delsys-app` checkout next to this repository (`../delsys-app/apple/TrignoKit`; override with
`ASSISTARM_TRIGNOKIT_PATH`). `delsys-app` must export the `CLSL` product (added in its
`Package.swift`).

```bash
brew install xcodegen
cd apple && xcodegen generate
open AssistArm.xcodeproj               # pick your team under Signing, then Run
# or from the terminal:
xcodebuild -project AssistArm.xcodeproj -scheme AssistArm -configuration Debug build CODE_SIGN_IDENTITY=-
```

If `xcode-select -p` points at the Command Line Tools, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` or run
`sudo xcode-select -s /Applications/Xcode.app`.

Package only (no UI), tests, and the CLI:

```bash
cd apple/AssistArmKit
swift build && swift test
swift run assist-arm ports                                   # list serial ports
swift run assist-arm servo --port /dev/cu.usbserial-XXXX     # read status, zero servos 1 and 2
swift run assist-arm run --calibrate 8 --duration 20          # synthetic EMG + simulated servos
swift run assist-arm run --source trigno --host 192.168.1.50 --slots 1,2 --servo /dev/cu.usbserial-XXXX --mode highOrLow --threshold 40 --log run.csv
swift run assist-arm run --source lsl --stream Delsys --columns 0,1 --servo mock
```

Without hardware, the Python mock TCU from `delsys-app` stands in for the Trigno server:

```bash
(cd ../delsys-app && python -m trigno mock-server --sensors 2)
swift run assist-arm run --source trigno --host 127.0.0.1
```

The app's debug build accepts `-autoConnect YES` (saved settings) and `-synthetic YES`
(synthetic EMG + simulated servos) as launch arguments.

## Using the app

1. **EMG**: choose Trigno SDK (IP of the PC running the Trigno Control Utility, sensor slots for
   flexor and extensor), LSL inlet (stream name and columns; the Trigno app's "Delsys" stream
   uses column n = slot n+1), or Synthetic. Connect.
2. **Servos**: pick the USB serial adapter (Futaba RS485 adapter shows up as `/dev/cu.usbserial-…`),
   or a TCP bridge, or Simulated. "Connect & zero" turns torque on, drives both servos to 0°,
   reads the resting angles as zero offsets, sets max torque 75 % and turns torque off, exactly
   like the legacy Init Servo button.
3. **Calibrate**: relax, then contract each muscle fully, then stop. The range is saved.
4. **Mode** and threshold, then **Start**. Telemetry goes to
   `~/Documents/AssistArm/Recordings/assist-<timestamp>.csv` (or the sandbox container's
   Documents when sandboxed).

## Hardware notes to verify on the bench

- The Futaba return packet with flag 0x09 is parsed as memory map 42–59 (position, time, speed,
  current, temperature, voltage), matching the legacy offsets. Echo from half-duplex RS-485
  adapters is skipped.
- Each goal and compliance change is a short packet per servo. The legacy long packets used a
  length field that did not match the record size, so they were not carried over.
- The sandbox entitlement `com.apple.security.device.serial` is set; if the adapter still cannot
  be opened, disable the sandbox in `project.yml` for lab use.

## iPad

iPadOS has no public API for arbitrary USB serial devices, so the servos cannot be driven
from an iPad over USB without a DriverKit extension (Apple entitlement, M-series iPad, a USB
CDC/FTDI driver of your own). The practical route is the `TCP bridge` servo link in this app:
a small board (ESP32, Raspberry Pi) or a Mac forwards TCP bytes to the RS-485 adapter. The
core, Futaba and Trigno packages already build for iOS 17.
