# Subject parameter profiles

Each folder is one legacy `parameter/` directory: the `param_eq.txt` / `param_trq.txt`
pair that `MSJointStateShin` loads (equilibrium-angle model and stiffness model). Load a
folder from the app's **Parameters → Choose…** button, or on the command line with
`assist-arm run --params profiles/<name>`.

File format: line 1 is the parameter count (9), lines 2–9 are the model coefficients, and
line 10 is the centre angle, which the legacy code parses but never uses.

| Folder | Source | Notes |
|---|---|---|
| `original-2009` | `*/Release/parameter/` in every legacy snapshot | Files dated 2009‑02‑23. Centre angle 0.430399. |
| `hasegawa-2016` | `*/assist demo/parameter/` in every legacy snapshot | `param_eq.txt` edited 2016‑04‑12 to set the centre angle to 0.0; `param_trq.txt` is byte‑identical to the 2009 one. This is the pair bundled in the app. |

The two profiles are the same subject's identification; because the centre angle is unused,
they behave identically. No other parameter sets exist in the legacy snapshots.
