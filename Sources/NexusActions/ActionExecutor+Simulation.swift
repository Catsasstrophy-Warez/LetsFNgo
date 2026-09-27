import Foundation
import NexusCore
import NexusGraph
import NexusModel
import NexusPersistence
import NexusSimulation

extension ActionExecutor {
    static let physical: Set<ObjectType> = [.equipment, .component, .sensor, .signal, .testPoint]

    /// Readings a loop run stores as modeled measurements.
    static func modeledSignals(of loop: InstrumentLoop) -> [(key: StateKey, unit: String)] {
        [(loop.terminalVoltage, "V"), (loop.loopCurrent, "mA"), (loop.measuredLevel, "%"), (loop.level, "%")]
    }

    /// Runs the loop `id` belongs to and stores what the model says.
    ///
    /// A healthy run gives the modeled expectation to compare field readings
    /// with; `faults` are injected for what-if runs and put on the timeline
    /// as `faultInjected`. The run's terminal voltage, loop current,
    /// measured level and tank level are stored as modeled measurements (they
    /// sit beside observed readings and never replace them) and a
    /// `simulated` event is recorded.
    ///
    /// Objects outside a simulated loop get `.unsupported` with the reason.
    @discardableResult
    public func runSimulation(on id: ObjectID, seconds: Double = 600, faults: [SimulatedFault] = []) throws -> ActionResult<SimulationOutcome> {
        let record = try require(id)
        guard seconds > 0, seconds.isFinite else { throw ActionError.invalidValue(.seconds, reason: "Run time must be positive") }
        guard let binding = try binding(for: id) else {
            let reason =
                Self.physical.contains(record.type)
                ? "\(record.title) is not part of a loop Nexus can simulate yet (instrument loops only)."
                : "Simulation is not available for a \(record.type.rawValue); select equipment in a simulated loop."
            let unsupported = Unsupported(command: .simulate, subject: id, type: record.type, reason: reason)
            return ActionResult(detail: .unsupported(unsupported), screen: Self.screen(for: record.type), focus: id, summary: reason)
        }
        let loop = binding.loop
        let runtime = try SimulationRuntime(dt: 0.5, state: loop.healthyState(), solvers: loop.solvers)
        for fault in faults {
            runtime.inject(fault)
        }
        try runtime.start()
        try runtime.run(for: seconds)

        return try store.batch { store in
            let now = clock.now()
            let modeled = Provenance(origin: .simulation(run: runtime.run), truth: .modeled, timestamp: now, method: "instrument loop simulation")
            for fault in faults {
                try store.record(
                    Event(
                        at: now, kind: .faultInjected, subjects: [fault.parameter.object], summary: fault.summary,
                        payload: [fault.parameter.quantity: .double(fault.value), "run": .reference(runtime.run)], provenance: modeled
                    ))
            }
            let method = faults.isEmpty ? "healthy twin" : "what-if with \(faults.count) fault\(faults.count == 1 ? "" : "s")"
            var readings: [MeasurementRecord] = []
            for (key, unit) in Self.modeledSignals(of: loop) {
                let reading = try runtime.measurement(of: key, unit: unit, at: now, method: method)
                try store.add(reading)
                readings.append(reading)
            }
            let values = runtime.state.values.filter { $0.key.object == id }.reduce(into: [String: Double]()) { $0[$1.key.quantity] = $1.value }
            try store.record(
                Event(
                    at: now, kind: .simulated, subjects: [id] + readings.map(\.id),
                    summary: "Simulated \(record.title) for \(Int(seconds)) s (\(method))",
                    payload: ["run": .reference(runtime.run), "seconds": .double(seconds), "faults": .int(Int64(faults.count))],
                    provenance: modeled
                ))
            let run = SimulationRun(run: runtime.run, loop: loop, seconds: seconds, faults: faults, values: values, modeled: readings)
            return ActionResult(
                detail: .ran(run), produced: readings.map(\.id), screen: .simulation, focus: id,
                summary: "Simulated \(record.title) (\(method))"
            )
        }
    }

    /// Follows signal connections (`connectedTo`) up- and downstream of a
    /// physical object, plus what contains it. Writes nothing.
    public func trace(from id: ObjectID) throws -> ActionResult<TraceOutcome> {
        let record = try require(id)
        func unsupported(_ reason: String) -> ActionResult<TraceOutcome> {
            ActionResult(
                detail: .unsupported(Unsupported(command: .trace, subject: id, type: record.type, reason: reason)),
                screen: Self.screen(for: record.type), focus: id, summary: reason
            )
        }
        guard Self.physical.contains(record.type) else {
            return unsupported("Trace follows signal connections between physical objects; a \(record.type.rawValue) has none.")
        }
        let upstream = try graph.traverse(from: id, kinds: [.connectedTo], direction: .incoming)
        let downstream = try graph.traverse(from: id, kinds: [.connectedTo], direction: .outgoing)
        guard !upstream.isEmpty || !downstream.isEmpty else {
            return unsupported("\(record.title) has no signal connections to trace.")
        }
        let containers = try graph.traverse(from: id, kinds: [.contains], direction: .incoming)
            .filter { try store.object($0.id)?.type != .project }
            .map(\.id)
        let trace = SignalTrace(origin: id, upstream: upstream, downstream: downstream, containers: containers, loop: try binding(for: id)?.loop)
        return ActionResult(
            detail: .traced(trace), screen: .simulation, focus: id,
            summary: "\(record.title): \(upstream.count) upstream, \(downstream.count) downstream"
        )
    }

    /// The registered binding for a loop containing `id`, or a loop found in
    /// the graph: an equipment `contains` a sensor wired `connectedTo`
    /// test point → card → controller → valve.
    public func binding(for id: ObjectID) throws -> LoopBinding? {
        if let bound = loops.first(where: { $0.members.contains(id) }) { return bound }
        return try discoverLoop(around: id).map { LoopBinding(loop: $0) }
    }

    private func discoverLoop(around id: ObjectID) throws -> InstrumentLoop? {
        guard let record = try store.object(id), Self.physical.contains(record.type) else { return nil }
        var starts = [id]
        if record.type == .equipment {
            starts += try graph.edges(of: id, kinds: [.contains], direction: .outgoing).map(\.neighbor)
        }
        var candidates: [ObjectID] = []
        for start in starts {
            let reached = [start] + (try graph.traverse(from: start, kinds: [.connectedTo], direction: .both, maxDepth: 6).map(\.id))
            for sensor in try store.objects(reached).filter({ $0.type == .sensor }).map(\.id) where !candidates.contains(sensor) {
                candidates.append(sensor)
            }
        }
        func next(_ from: ObjectID, _ type: ObjectType) throws -> ObjectID? {
            let ids = try graph.edges(of: from, kinds: [.connectedTo], direction: .outgoing).map(\.neighbor)
            return try store.objects(ids).first { $0.type == type }?.id
        }
        for sensor in candidates {
            guard let terminal = try next(sensor, .testPoint), let card = try next(terminal, .component),
                let controller = try next(card, .component), let valve = try next(controller, .component),
                let tank = try store.objects(try graph.edges(of: sensor, kinds: [.contains], direction: .incoming).map(\.neighbor))
                    .first(where: { $0.type == .equipment })?.id
            else { continue }
            let loop = InstrumentLoop(tank: tank, transmitter: sensor, terminal: terminal, card: card, controller: controller, valve: valve)
            if LoopBinding(loop: loop).members.contains(id) { return loop }
        }
        return nil
    }
}
