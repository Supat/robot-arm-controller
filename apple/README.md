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
    FutabaRS           Futaba RS packet codec, POSIX serial port, direct-USB FTDI transport, TCP serial bridge, servo driver
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
`delsys-app` submodule (`git submodule update --init`), which provides TrignoKit at
`external/delsys-app/apple/TrignoKit`. Set `ASSISTARM_TRIGNOKIT_PATH` to build against a
different checkout. To move to a newer delsys-app, `cd external/delsys-app && git pull`, then
commit the submodule pointer here.

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
swift run assist-arm ports                                   # list serial ports and direct-USB adapters
swift run assist-arm status --port usb://1115:0008            # read servo status only (no motion)
swift run assist-arm bench --port usb://1115:0008             # move-then-read timing matrix (no motion)
swift run assist-arm inspect --port usb://1115:0008 --id 1    # ROM/RAM dump around ±20° test moves
swift run assist-arm track --port usb://1115:0008 --ids 1,2 --sine 1 --repeat 50   # goal tracking test
swift run assist-arm servo --port usb://1115:0008             # read status, zero servos 1 and 2
swift run assist-arm run --calibrate 8 --duration 20          # synthetic EMG + simulated servos
swift run assist-arm run --source trigno --host 192.168.1.50 --slots 1,2 --servo usb://1115:0008 --mode highOrLow --threshold 40 --log run.csv
swift run assist-arm run --source lsl --stream Delsys --columns 0,1 --servo mock
```

Without hardware, the Python mock TCU from `delsys-app` stands in for the Trigno server:

```bash
(cd ../../external/delsys-app && python -m trigno mock-server --sensors 2)
swift run assist-arm run --source trigno --host 127.0.0.1
```

The app's debug build accepts `-autoConnect YES` (saved settings) and `-synthetic YES`
(synthetic EMG + simulated servos) as launch arguments.

## Using the app

1. **EMG**: choose Trigno SDK (IP of the PC running the Trigno Control Utility, sensor slots for
   flexor and extensor), LSL inlet (stream name and columns; the Trigno app's "Delsys" stream
   uses column n = slot n+1), or Synthetic. Connect.
2. **Servos**: pick the adapter. The Futaba RSC-U485 appears as "USB <-> Serial Cable (direct USB)";
   a generic FTDI/CP210x adapter appears as `/dev/cu.usbserial-…`. Or use a TCP bridge, or Simulated. "Connect & zero" turns torque on, drives both servos to 0°,
   reads the resting angles as zero offsets, sets max torque 75 % and turns torque off, exactly
   like the legacy Init Servo button.
3. **Calibrate**: relax, then contract each muscle fully, then stop. The range is saved.
4. **Mode** and threshold, then **Start**. Telemetry goes to
   `~/Documents/AssistArm/Recordings/assist-<timestamp>.csv`.

## Hardware notes to verify on the bench

- The Futaba return packet (header `FD DF`, flag 0x09) is parsed as memory map 42–59 (position,
  time, speed, current, temperature, voltage), matching the legacy offsets. Echo from half-duplex
  RS-485 adapters is skipped. `assist-arm status` prints the raw 18 bytes for checking the field
  layout of a particular servo model.
- Futaba RS servos restart their motion on every goal command. Writing goals at the 50 Hz loop
  rate makes them crawl at a fraction of full speed, so goals are written at `goalUpdateRate`
  (20 Hz by default, "Goal write rate" under Advanced); 10–20 Hz tracked a sweeping goal with
  about 0.2 s lag on the bench. `assist-arm track` reproduces the measurement.
- Compliance slope is in degrees: 0xFF means torque ramps over 255° (very soft), 0x32 over 50°.
  Under load the servo settles several degrees short of its goal at 0x32; that is the legacy
  "stiff" setting, not a fault.
- Each goal and compliance change is a short packet per servo. The legacy long packets used a
  length field that did not match the record size, so they were not carried over.
- The Futaba RSC-U485 is an FTDI FT232R with Futaba's own USB IDs (vendor 0x1115, product
  0x0008), so macOS never attaches a serial driver and no `/dev/cu.*` node appears. `FTDIUSBTransport`
  drives it directly through `IOUSBHost` (FTDI vendor requests for 115200 8N1, 1 ms latency timer,
  bulk endpoints 0x81/0x02 with the two status bytes stripped from each packet). No driver install,
  no kernel extension, no sandbox entitlement; the app is not sandboxed. The adapter must be free
  (close any other program using it) and the servos need their own power supply to answer.

## iPad

iPadOS has no public API for arbitrary USB serial devices, so the servos cannot be driven
from an iPad over USB without a DriverKit extension (Apple entitlement, M-series iPad, a USB
CDC/FTDI driver of your own). The practical route is the `TCP bridge` servo link in this app:
a small board (ESP32, Raspberry Pi) or a Mac forwards TCP bytes to the RS-485 adapter. The
core, Futaba and Trigno packages already build for iOS 17.
