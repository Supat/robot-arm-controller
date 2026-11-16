# Assist Arm for Windows (Delsys API)

A C#/.NET port of the macOS app in `../apple`, for a Windows PC that has the Trigno base
station and the servo adapter plugged into it. EMG comes through the **Delsys API** (the
`DelsysAPI` .NET library), not through the Trigno Control Utility's SDK server that the macOS
app uses.

The signal chain, joint model, calibration, control loop, Futaba protocol and telemetry format
are line-for-line ports of the Swift code, with the same tests.

## Status

Checked on a Mac (the only machine available while writing this):

- `AssistArm.Core` builds and its 19 tests pass.
- The command-line tool runs calibration and control end to end with synthetic EMG and
  simulated servos.
- `AssistArm.Delsys` and the WPF app compile against Delsys's real `DelsysAPI` 2.9.7 package.

Not yet run anywhere:

- The WPF window. It compiles, but it has never been launched.
- Anything that touches the Delsys API at run time. It needs Windows, a base station and a
  licence. The calls follow Delsys's own example application.
- The serial servo link on Windows (`COMx`). The packets are the same as on macOS.

Expect a round of fixes the first time this runs on the bench.

## Requirements

- Windows 10 or 11, x64.
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (or Visual Studio 2022 with the
  ".NET desktop development" workload).
- A Delsys API key and licence string, issued by Delsys to the lab. They are separate from the
  Trigno SDK.
- Delsys's USB driver for the base station. Installing Trigno Discover installs it.
- Futaba's driver for the RSC-U485 adapter, so that it shows up as a COM port. Set the port's
  latency timer to 1 ms (Device Manager → the COM port → Port Settings → Advanced).

## Set up

```powershell
cd windows
.\fetch-delsys-packages.ps1      # downloads Delsys's NuGet packages into .\packages
dotnet build AssistArm.sln
dotnet test AssistArm.sln
dotnet run --project src\AssistArm.App
```

`fetch-delsys-packages` takes the four packages from Delsys's public
[Example-Applications](https://github.com/delsys-inc/Example-Applications) repository. They are
Delsys's binaries, so they are downloaded rather than committed here.

## Using the app

1. **Close the Trigno Control Utility.** The Delsys API talks to the base over USB itself and only
   one program can hold it.
2. **EMG → Delsys API licence**: paste the key and the licence, then *Save licence*. They are
   stored in `%APPDATA%\AssistArm\delsys-license.json`, outside the repository.
3. Pick the **flexor** and **extensor** sensors by their pair numbers and press **Connect**. The
   app loads the base, scans for sensors that are already paired, selects those two and starts
   streaming. Leave *Sample mode* blank to keep each sensor's current mode; after the first
   connect the list offers the modes the flexor sensor supports.
4. **Servos**: choose the COM port, then **Connect & zero** with the arm hanging at rest.
5. **Calibrate**, load the subject's **Model** parameters, choose a **Mode**, and **Start control**.

Telemetry goes to `Documents\AssistArm\Recordings\assist-<timestamp>.csv`, in the same columns
as the macOS app. Settings are kept in `%APPDATA%\AssistArm\settings.json`.

The app does not pair sensors. Pair them once with Trigno Discover; the base remembers them.

## Command line

```powershell
dotnet run --project src\AssistArm.Cli -- ports
dotnet run --project src\AssistArm.Cli -- status --port COM3        # read both servos, no motion
dotnet run --project src\AssistArm.Cli -- sensors --modes          # scan through the Delsys API
dotnet run --project src\AssistArm.Cli -- run --source delsys --sensors 1,2 --servo COM3 --params ..\profiles\hasegawa-2016
dotnet run --project src\AssistArm.Cli -- run                      # synthetic EMG, simulated servos
```

`sensors --verbose` and `run --verbose` print the Delsys API's own debug output, which is the
first thing to look at when the base or a sensor is not found.

## Layout

| Project | Contents |
|---|---|
| `src/AssistArm.Core` | Signal chain, joint model, pipeline, calibrator, controller, Futaba driver, telemetry. No Windows or Delsys dependency. |
| `src/AssistArm.Delsys` | `DelsysSession` and `DelsysEmgSource`: the Delsys API behind the `IEmgSource` interface. |
| `src/AssistArm.App` | The WPF window. |
| `src/AssistArm.Cli` | `assist-arm`, the headless controller. |
| `tests/AssistArm.Core.Tests` | xunit ports of the Swift tests. |

## Differences from the macOS app

- **EMG source**: Delsys API over USB instead of the Trigno SDK over TCP. No LSL inlet.
- **Units**: the Delsys API reports EMG in millivolts for most sensors. `DelsysEmgSource` converts
  to volts, so calibration ranges and the legacy stiffness scaling behave as on macOS.
- **Sample rate**: taken from the sensor's EMG channel in its current mode (1926 Hz or 2148 Hz
  on Avanti sensors, for example). The quasi-tension stage decimates to about 200 Hz either way.
- **Servo adapter**: a COM port through Futaba's driver, instead of the direct USB access the
  macOS app uses.
- **Timing**: the control loop runs on its own thread with a 1 ms system timer, because
  `Task.Delay` on Windows is only accurate to about 15 ms.

## Things to check on the bench

- Whether the Delsys API accepts this base station and these sensors at all. The package
  contains classes for legacy sensors, but a third-party integration guide lists only
  Avanti-generation sensors and a newer base firmware than `MA2909` as supported. If the scan
  finds nothing, run `sensors --verbose` and compare the firmware it reports.
- That the pair numbers shown by `sensors` match the sensor numbers used in the Trigno Control
  Utility.
- The EMG unit and scale: compare a calibration range here with one from the macOS app for the
  same contraction.
