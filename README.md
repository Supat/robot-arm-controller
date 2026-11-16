# robot-arm-controller

EMG-driven assist arm: two surface-EMG channels (flexor, extensor) are turned into muscle
activation, a single-joint musculoskeletal model estimates the equilibrium elbow angle and
joint stiffness, and two Futaba RS servos mirror that angle with a compliance that follows
the stiffness.

```
apple/               macOS app (SwiftUI) + Swift package AssistArmKit — the current implementation
external/delsys-app  git submodule: Delsys Trigno SDK client (TrignoKit Swift package, Python mock server)
windows/             Windows app (C#/.NET, WPF) reading EMG through the Delsys API — a port of apple/, not yet run on hardware
legacy/              Windows/VS2019 originals (Assist_Demo, NI-DAQ + GLUT); git-ignored, kept for reference
```

```bash
git clone --recurse-submodules git@github.com:Supat/robot-arm-controller.git
# or, in an existing clone:
git submodule update --init
```

The EMG comes from a Delsys Trigno system through the Trigno SDK server, using the
`TrignoKit` package from the `delsys-app` submodule. See [`apple/README.md`](apple/README.md).

The Windows port in `windows/` takes the EMG from the base station over USB through the Delsys API
instead. See [`windows/README.md`](windows/README.md).
