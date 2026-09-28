# Automotive (second domain)

`Sources/NexusAutomotive` is the domain core for the second vertical slice chosen in `docs/decisions/0002-second-domain.md`. It has no UI and no store of its own. Vehicles, components, trouble codes, service visits and readings are ordinary objects, relationships, events and measurements in `NexusStore`, each with a truth class and provenance. Diagnosis runs on the same `InvestigationRuntime`, `SimulationRuntime` and report as the instrument-loop Golden Slice.

| Piece | Where | Notes |
|---|---|---|
| Vocabulary | `Vocabulary.swift` | These are added to NexusModel's open vocabularies. `ObjectType.vehicle` and `.vehicleNetwork` are new types. `RelationKind.hasFault`, `.reportedBy` and `.serviced` are new relations. `EventKind.service`, `.troubleCodesRead` and `.odometerReading` are new events. Parts use the shared `component` and `sensor` types with a `role` attribute, codes are `fault` objects, and repairs are `procedure` objects. |
| VIN | `VIN.swift` | ISO 3779 check digit (weights 8…2, 10, 0, 9…2; mod 11, X for 10). It decodes region, country, manufacturer (a small WMI table) and model year (30-year cycle, position-7 rule). |
| Garage | `VehicleRuntime.swift` | `addVehicle(vin:)` enforces the check digit for North American VINs and builds the topology, with `contains` and `connectedTo` wired like the loop. It also holds service history (procedure object + `service` event + odometer that never decreases in time), trouble codes as faults, and PID readings. |
| OBD-II | `OBD.swift` | Mode 01 PIDs use the SAE J1979 formulas: 04–11, 14–1B, 1F, 21, 2F, 31, 33, 42, 46, 5C, supported-PID bitmaps and monitor status. Modes 03/07/0A read codes with or without the CAN count byte; Mode 09 reads the VIN. |
| ELM327 | `ELM327.swift` | Headers off, including the `014` / `0:` multi-frame layout, and headers on for 11-bit CAN, 29-bit CAN and legacy protocols. It handles ISO-TP reassembly, echo, prompts, `SEARCHING...`, `NO DATA`, adapter errors, and `ATRV`. |
| CAN | `CAN.swift` | Frames, and DBC-lite signals: Intel and Motorola layouts, signed values, factor and offset, encode and decode. The parser reads `BO_` and `SG_` lines and skips other sections. |
| Adapter link | `OBDTransport.swift`, `ELM327Session.swift`, `OBDLinkError.swift` | `OBDTransport` moves bytes; `ELM327Session` (an actor) runs `ATZ ATE0 ATL0 ATS0 ATH1 ATSP0`, `ATRV`, `0100` (protocol search) and `ATDPN`/`ATDP`. It frames replies on `>`, drops echoes and junk bytes, runs one command at a time, times out and retries (timeouts, `STOPPED`, `BUS BUSY`, `CAN ERROR`…), and turns `NO DATA`, `UNABLE TO CONNECT`, `?` and `7F` refusals into typed errors. Clones that refuse `ATS0`, `ATH1`, `ATRV` or `ATDPN`, or keep echoing, still work. `MockOBDTransport` replays scripted adapters for tests. |
| Poller | `OBDPoller.swift` | Supported PIDs (bitmaps 00, 20, 40…), one PID per request, codes 03/07/0A (count byte on CAN only), freeze frame (02, frame 0), VIN (09 02; CAN or five legacy frames), `ATRV`. Clearing (04) takes a `ClearCodesConfirmation`, which only a person (`Origin.user`) can make, for one vehicle, valid five minutes. |
| Drive recorder | `OBDDriveRecorder.swift` | Picks or adds the vehicle by VIN (and refuses a VIN that doesn't match the chosen vehicle), stores the adapter as an `instrument` object, streams PIDs into NexusTelemetry channels on the vehicle (NaN for dropouts), records codes and freeze frames through `VehicleRuntime`, and writes an `obdSession` event at the start and end of each drive. |
| BLE and Wi-Fi | `Sources/NexusOBDTransports` (Apple only) | CoreBluetooth: scans without a service filter, prefers FFE0/FFE1, FFF0/FFF1+FFF2, 18F0/2AF0+2AF1 and the Microchip UART service, otherwise any notify + write pair. Network: TCP, default 192.168.0.10:35000. |
| DTC table | `DTCKnowledgeBase.swift` | 48 generic P0 codes with SAE J2012 titles and likely components. |
| Charging solver | `ChargingSystem.swift` | `ChargingSystemSolver` for NexusSimulation's `Solver`: battery EMF from state of charge, internal and polarization resistance, alternator regulator and output limit by rpm, starter resistance, ground-strap resistance. `ChargingFaultKind` and the standard check `ChargingProtocol` live here too. |
| Diagnosis fixture | `ChargingDiagnosis.swift` | Opens "Cranks slowly / battery light on" with four hypotheses. Their prediction intervals are simulated, as in the loop dataset. The file also provides test options, the first divergence against a healthy twin, and observed/modeled reading pairs. |

## Truth classes for scan-tool data

| Value | Truth class | Origin | Why |
|---|---|---|---|
| Mode 01 PID (RPM, coolant, PID 42 voltage…) | **display** | `importer(source: ECU)` | The ECU reports what its own sensors read, and the scan tool relays it. The spec defines Display Truth as a "value shown by a device". The ECU may be wrong, and catching a wrong ECU value is part of diagnosis. Display readings are judged but never counted as evidence, and never overwrite a meter reading. |
| Scan tool's own voltmeter (`ATRV`) | **observed** | `instrument(scan tool)` | The adapter measures it itself. A caller may also label a PID `observed` when it has checked that channel independently (`record(_:truth: .observed)`). |
| Live PIDs from a connected adapter (telemetry channels, freeze frames) | **observed** by default | `instrument(adapter)` | `OBDDriveRecorder(liveTruth:)`. The adapter read them off the bus during this drive; the channel's method names the chip, link, protocol, PID and module. Pass `.display` to keep the imported-log convention above. |
| Stored/pending/permanent codes | **recorded** | `importer(source: ECU)` | The ECU's own record of its monitors, from a trusted external system. |
| A code's generic meaning | **claimed** | `system`, "SAE J2012 generic definition" | A general statement about the code, not about this car. |
| VIN-decoded manufacturer, year, region | **derived** | `system`, "VIN decode" | Calculated from the recorded VIN. |
| Healthy-twin values | **modeled** | `simulation(run:)` | |
| Meter readings in the fixture | **observed** | `instrument(meter)` | Training-world convention: the faulted solver run plays the field. |

## The slice test

`Tests/NexusAutomotiveTests/AutomotiveSliceTests.swift` runs the second domain end to end on one SQLite file. It proves the architecture expands without a parallel truth path. The steps:

1. Decode the VIN from a Mode 09 ELM327 reply and add the vehicle with its topology and service history.
2. Read P0562 from a Mode 03 reply as a recorded fault, a PID 42 value as display truth, and `ATRV` as observed truth.
3. Open the investigation with four solver-predicted hypotheses. The display value is judged, not counted.
4. Take the ranked tests. Cranking voltage comes first and splits the causes three ways; it rejects the weak battery and the bad ground. Charging voltage comes second and rejects the parasitic draw.
5. Find the first divergence: alternator output 12.24 V against the twin's 14.4 V at t = 0. Record it with an observed reading and a modeled one.
6. Confirm the cause. An agent's confirmation is refused, a technician's is accepted, and an agent's attempt to rewrite the recorded code is refused.
7. Create the repair task, and record the alternator replacement as a service visit with the odometer. An odometer reading that goes backwards is refused.
8. Verify charging above 14.1 V at 2000 rpm, clear the fault (archived, not deleted), and close the investigation.
9. Generate the report. It cites every observed and modeled figure and never the display value.
10. Save and reload. Objects, relationships, revisions, hypotheses, measurements, the timeline and the report are identical.

## Follow-ups

- Hardware acquisition: ELM327 over BLE and Wi-Fi is built (above; the live sheet is "Connect adapter" on a vehicle). Still to do: verify on real adapters, classic-Bluetooth (SPP) adapters on macOS, multi-PID requests on CAN for faster polling, and a CAN interface for raw frames.
- Misfire and fuel-trim solvers for the P0303 slice sketched in the decision record.
- Garage and telemetry screens in NexusUI.
- Turning a closed automotive investigation into a `NexusLearning` training scenario.
