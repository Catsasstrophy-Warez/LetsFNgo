import ControlsPLC
import ControlsReasoning
import Foundation
import NexusCore
import NexusModel
import Testing
@testable import NexusMeasurement

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let tech = Origin.user(id: "tech-1")
private let point = ObjectID.make()

private func close(_ a: Double?, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance * max(1, abs(b))
}

private func reading(
    _ value: Double, _ unit: String, pm uncertainty: Double?, confidence: Double? = nil, at offset: TimeInterval = 0
) -> MeasurementRecord {
    MeasurementRecord(
        quantityName: "q", value: Quantity(value, unit), uncertainty: uncertainty, testPoint: point, sampledAt: t0 + offset,
        provenance: Provenance(origin: .instrument(id: point), truth: .observed, timestamp: t0 + offset, confidence: confidence)
    )
}

@Suite struct UnitTests {
    @Test func convertsWithinADimension() throws {
        #expect(close(try MeasurementUnit.convert(12, from: "mA", to: "A"), 0.012))
        #expect(close(try MeasurementUnit.convert(1.5, from: "kOhm", to: "Ohm"), 1_500))
        #expect(close(try MeasurementUnit.convert(2.5, from: "bar", to: "kPa"), 250))
        #expect(close(try MeasurementUnit.convert(250, from: "ms", to: "s"), 0.25))
        #expect(close(try MeasurementUnit.convert(50, from: "%", to: "1"), 0.5))
        #expect(close(try MeasurementUnit.convert(50, from: "%", to: "value"), 0.5))
        #expect(close(try MeasurementUnit.convert(1, from: "V/mA", to: "kOhm"), 1))
        #expect(close(try MeasurementUnit.convert(20, from: "V.A", to: "W"), 20))
        #expect(close(try MeasurementUnit.convert(60, from: "Hz", to: "s-1"), 60))
        #expect(close(try MeasurementUnit.convert(60, from: "Hz", to: "/min"), 3_600))
        #expect(close(try MeasurementUnit.convert(1, from: "bool", to: "bool"), 1))
    }

    @Test func temperatureOffsetsApplyToValuesNotIntervals() throws {
        let celsius = try MeasurementUnit("degC")
        let kelvin = try MeasurementUnit("K")
        #expect(close(try celsius.convert(25, to: kelvin), 298.15))
        #expect(close(try kelvin.convert(273.15, to: celsius), 0))
        #expect(close(try celsius.convertInterval(0.5, to: kelvin), 0.5))
    }

    @Test func dimensionsAreChecked() throws {
        #expect(try MeasurementUnit("V").dimension == MeasurementUnit("Ohm.A").dimension)
        #expect(try MeasurementUnit("Pa").isCommensurable(with: MeasurementUnit("bar")))
        #expect(try !MeasurementUnit("value").isCommensurable(with: MeasurementUnit("bool")))
        #expect(throws: UnitError.incompatible(from: "V", to: "A")) { try MeasurementUnit.convert(1, from: "V", to: "A") }
        #expect(throws: UnitError.incompatible(from: "bool", to: "value")) { try MeasurementUnit.convert(1, from: "bool", to: "value") }
    }

    @Test func mechanicalAndFlowUnitsConvert() throws {
        #expect(abs(try MeasurementUnit.convert(1_800, from: "rpm", to: "Hz") - 30) < 1e-12)
        #expect(abs(try MeasurementUnit.convert(1, from: "psi", to: "kPa") - 6.894_757) < 1e-6)
        #expect(abs(try MeasurementUnit.convert(1, from: "bar", to: "psi") - 14.503_77) < 1e-4)
        #expect(try MeasurementUnit.convert(1_250, from: "mm", to: "m") == 1.25)
        #expect(try MeasurementUnit.convert(2, from: "kg", to: "g") == 2_000)
        #expect(abs(try MeasurementUnit.convert(60, from: "L/min", to: "L/s") - 1) < 1e-12)
        #expect(try MeasurementUnit("L").isCommensurable(with: MeasurementUnit("m3")))
        #expect(try MeasurementUnit("N").dimension == MeasurementUnit("kg.m/s2").dimension)
        #expect(try MeasurementUnit("mA").isCommensurable(with: MeasurementUnit("A")))
        #expect(try MeasurementUnit("min").dimension == MeasurementUnit("s").dimension)
    }

    @Test func malformedCodesAreRejected() {
        #expect(throws: UnitError.unknownUnit("volt")) { try MeasurementUnit("volt") }
        #expect(throws: UnitError.unknownUnit("kpsi")) { try MeasurementUnit("kpsi") }
        #expect(throws: UnitError.unknownUnit("krpm")) { try MeasurementUnit("krpm") }
        #expect(throws: UnitError.unknownUnit("kdegC")) { try MeasurementUnit("kdegC") }
        #expect(throws: UnitError.offsetUnitInCompound("degC.A")) { try MeasurementUnit("degC.A") }
        #expect(throws: UnitError.notNumeric("bool/s")) { try MeasurementUnit("bool/s") }
        #expect(throws: UnitError.syntax("V.", position: 2)) { try MeasurementUnit("V.") }
        #expect(throws: UnitError.syntax("(V", position: 2)) { try MeasurementUnit("(V") }
        #expect(throws: UnitError.syntax("", position: 0)) { try MeasurementUnit("") }
    }
}

@Suite struct MeasurementMathTests {
    let math = MeasurementMath(author: tech, clock: ManualClock(t0))

    @Test func additionConvertsAndAddsInQuadrature() throws {
        // 10 V ± 0.03 V + 2000 mV ± 40 mV = 12 V ± √(0.03² + 0.04²) = 12 V ± 0.05 V
        let a = reading(10, "V", pm: 0.03)
        let b = reading(2_000, "mV", pm: 40, at: 5)
        let sum = try math.add(a, b, as: "supply")
        #expect(sum.value == Quantity(12, "V"))
        #expect(close(sum.uncertainty, 0.05))
        #expect(sum.truth == .derived)
        #expect(sum.provenance.origin == tech)
        #expect(sum.provenance.dependencies == [a.id, b.id])
        #expect(sum.provenance.method == MeasurementMath.method)
        #expect(sum.sampledAt == t0 + 5)
        #expect(sum.quantityName == "supply")

        let difference = try math.subtract(a, b)
        #expect(close(difference.value.value, 8))
        #expect(close(difference.uncertainty, 0.05))
    }

    @Test func aRecordCombinedWithItselfIsFullyCorrelated() throws {
        let a = reading(10, "V", pm: 0.03)
        let zero = try math.subtract(a, a)
        #expect(zero.value.value == 0)
        #expect(zero.uncertainty == 0)
        #expect(zero.provenance.dependencies == [a.id])
        #expect(close(try math.add(a, a).uncertainty, 0.06))
    }

    @Test func productAndQuotientPropagateRelativeErrors() throws {
        // P = V·I = 10 V × 2 A; u = √((2 × 0.3)² + (10 × 0.08)²) = √(0.36 + 0.64) = 1
        let power = try math.multiply(reading(10, "V", pm: 0.3), reading(2, "A", pm: 0.08), as: "power")
        #expect(power.value == Quantity(20, "V.A"))
        #expect(close(power.uncertainty, 1))
        #expect(close(try MeasurementUnit.convert(power.value.value, from: power.value.unit, to: "W"), 20))

        // R = V/I = 12 V / 0.02 A = 600 Ω; u = √((0.036/0.02)² + (12 × 0.00008/0.02²)²) = √(1.8² + 2.4²) = 3
        let resistance = try math.divide(reading(12, "V", pm: 0.036), reading(0.02, "A", pm: 0.00008), as: "loop resistance")
        #expect(resistance.value.unit == "V/A")
        #expect(close(resistance.value.value, 600))
        #expect(close(resistance.uncertainty, 3))
        let kilohms = try math.convert(resistance, to: "kOhm")
        #expect(close(kilohms.value.value, 0.6))
        #expect(close(kilohms.uncertainty, 0.003))
        #expect(kilohms.provenance.dependencies == [resistance.id])

        #expect(throws: MeasurementMathError.divisionByZero) {
            try math.divide(reading(1, "V", pm: 0.1), reading(0, "A", pm: 0.1), as: "r")
        }
        // b is converted into a's unit, so the error names that conversion.
        #expect(throws: UnitError.incompatible(from: "A", to: "V")) {
            try math.add(reading(1, "V", pm: 0.1), reading(1, "A", pm: 0.1))
        }
    }

    @Test func compoundUnitsAreParenthesised() throws {
        let rate = try math.divide(reading(1, "V/A", pm: nil), reading(2, "s.A", pm: nil), as: "x")
        #expect(rate.value.unit == "V/A/(s.A)")
        #expect(try MeasurementUnit("V/A/(s.A)").dimension == MeasurementUnit("Ohm/s/A").dimension)
    }

    @Test func fourToTwentyMilliampsMapsToPercent() throws {
        // 12 mA on 4–20 mA → 50 %; slope 100/16 = 6.25 %/mA, so ±0.02 mA → ±0.125 %
        let scale = try LinearScale.fourToTwentyMilliamps(to: 0...100, "%")
        let percent = try math.map(reading(12, "mA", pm: 0.02), through: scale, as: "level")
        #expect(percent.value == Quantity(50, "%"))
        #expect(close(percent.uncertainty, 0.125))
        #expect(percent.provenance.transformation == "linear 4.0…20.0 mA → 0.0…100.0 %")

        // The same current in amps gives the same answer.
        let fromAmps = try math.map(reading(0.012, "A", pm: 0.00002), through: scale, as: "level")
        #expect(close(fromAmps.value.value, 50))
        #expect(close(fromAmps.uncertainty, 0.125))

        // And back: 75 % ± 0.25 % → 16 mA ± 0.04 mA.
        let current = try math.map(reading(75, "%", pm: 0.25), through: scale.inverted(), as: "loop current")
        #expect(close(current.value.value, 16))
        #expect(current.value.unit == "mA")
        #expect(close(current.uncertainty, 0.04))

        // Reverse acting: 8 mA → 75 %.
        let reverse = try LinearScale(inputLow: 4, inputHigh: 20, inputUnit: "mA", outputLow: 100, outputHigh: 0, outputUnit: "%")
        #expect(close(reverse.apply(8), 75))
        #expect(close(try math.map(reading(8, "mA", pm: 0.02), through: reverse, as: "level").uncertainty, 0.125))

        #expect(throws: MeasurementMathError.degenerateScale) {
            try LinearScale(inputLow: 4, inputHigh: 4, inputUnit: "mA", outputLow: 0, outputHigh: 100, outputUnit: "%")
        }
        #expect(throws: MeasurementMathError.degenerateScale) {
            try LinearScale(inputLow: 4, inputHigh: 20, inputUnit: "mA", outputLow: 5, outputHigh: 5, outputUnit: "%").inverted()
        }
    }

    @Test func scalingUnknownsAndConfidence() throws {
        let scaled = try math.scale(reading(3, "V", pm: 0.1), by: -2)
        #expect(scaled.value.value == -6)
        #expect(close(scaled.uncertainty, 0.2))

        // Unknown stays unknown.
        #expect(try math.add(reading(1, "V", pm: nil), reading(1, "V", pm: 0.1)).uncertainty == nil)

        // The derived value is only as trusted as its weakest input.
        let mixed = try math.add(reading(1, "V", pm: 0.1, confidence: 0.9), reading(1, "V", pm: 0.1, confidence: 0.6))
        #expect(mixed.provenance.confidence == 0.6)
        #expect(try math.add(reading(1, "V", pm: 0.1, confidence: 0.9), reading(1, "V", pm: 0.1)).provenance.confidence == nil)

        #expect(throws: UnitError.notNumeric("bool")) {
            try math.add(reading(1, "bool", pm: nil), reading(1, "bool", pm: nil))
        }
    }
}

@Suite struct InstrumentTests {
    /// A 6000-count DMM on its 60 V range: ±(0.5 % + 2), 0.01 V resolution.
    let spec = AccuracySpec(percentOfReading: 0.5, digits: 2, resolution: Quantity(0.01, "V"), rangeLow: -60, rangeHigh: 60)

    @Test func accuracySpecGivesTheReadingUncertainty() throws {
        // 10.00 V × 0.5 % + 2 × 0.01 V = 0.05 + 0.02 = 0.07 V
        #expect(close(try spec.uncertainty(for: Quantity(10, "V")), 0.07))
        // In millivolts: 10000 × 0.5 % + 2 × 10 mV = 70 mV
        #expect(close(try spec.uncertainty(for: Quantity(10_000, "mV")), 70))
        // Negative readings use their magnitude.
        #expect(close(try spec.uncertainty(for: Quantity(-24, "V")), 0.14))
    }

    @Test func instrumentObjectsProduceObservedReadings() throws {
        let record = InstrumentModel.makeRecord(
            title: "Fluke 87V", spec: spec,
            provenance: Provenance(origin: tech, truth: .claimed, timestamp: t0, method: "manufacturer datasheet")
        )
        let meter = try InstrumentModel(record: record)
        #expect(meter.spec == spec)

        let measured = try meter.reading(Quantity(10.8, "V"), of: "terminal voltage", at: point, loading: "under load", sampledAt: t0)
        #expect(measured.truth == .observed)
        #expect(measured.provenance.origin == .instrument(id: record.id))
        #expect(measured.instrument == record.id)
        #expect(close(measured.uncertainty, 10.8 * 0.005 + 0.02))
        #expect(close(measured.resolution, 0.01))
        #expect(measured.rangeLow == -60 && measured.rangeHigh == 60)

        #expect(throws: InstrumentError.overRange(record.id, reading: 75, unit: "V")) {
            try meter.reading(Quantity(75, "V"), of: "terminal voltage", at: point, sampledAt: t0)
        }
        #expect(throws: InstrumentError.missingAccuracySpec(point)) {
            try InstrumentModel(record: ObjectRecord(
                id: point, type: .instrument, title: "Unknown meter", provenance: Provenance(origin: tech, truth: .recorded, timestamp: t0)
            ))
        }
    }
}

@Suite struct TrainerAdapterTests {
    @Test func confidenceLevelsMapMonotonicallyAndKeepThePruningLine() {
        let values = EvidenceConfidence.allCases.sorted().map(TrainerEvidenceAdapter.confidence)
        #expect(values == [0.25, 0.5, 0.8, 0.95])
        for level in EvidenceConfidence.allCases {
            #expect(level.supportsHardPruning == (TrainerEvidenceAdapter.confidence(level) >= TrainerEvidenceAdapter.hardPruningThreshold))
            #expect(TrainerEvidenceAdapter.level(forConfidence: TrainerEvidenceAdapter.confidence(level)) == level)
        }
        #expect(TrainerEvidenceAdapter.level(forConfidence: 0.1) == .low)
        #expect(TrainerEvidenceAdapter.level(forConfidence: 0.9) == .high)
    }

    @Test func observationsBecomeMeasurementsWithTheRightTruth() throws {
        let learner = TroubleshootingObservation(
            sequence: 3, target: "TB-4 voltage", value: .real(10.8), source: .learnerMeasurement,
            kind: .measurement, confidence: .medium, condition: .underLoad
        )
        let measured = try #require(try TrainerEvidenceAdapter.measurement(learner, at: point, unit: "V", sampledAt: t0, origin: tech))
        #expect(measured.value == Quantity(10.8, "V"))
        #expect(measured.truth == .observed)
        #expect(measured.loading == "under load")
        #expect(measured.provenance.confidence == 0.5)
        #expect(measured.uncertainty == nil)

        let simulated = TroubleshootingObservation(sequence: 4, target: "X1", value: .bool(true), source: .simulator)
        let modeled = try #require(try TrainerEvidenceAdapter.measurement(simulated, at: point, sampledAt: t0, origin: .simulation(run: point)))
        #expect(modeled.value == Quantity(1, "bool"))
        #expect(modeled.truth == .modeled)

        let instructor = TroubleshootingObservation(sequence: 5, target: "Fuse F2", value: .dint(1), source: .instructor, kind: .fact)
        #expect(try TrainerEvidenceAdapter.measurement(instructor, at: point, sampledAt: t0, origin: tech)?.truth == .recorded)

        let guess = TroubleshootingObservation(sequence: 6, target: "X1", value: .bool(false), kind: .assumption)
        #expect(try TrainerEvidenceAdapter.measurement(guess, at: point, sampledAt: t0, origin: tech) == nil)
        let timer = TroubleshootingObservation(sequence: 7, target: "T1", value: .timer(TimerValue()))
        #expect(try TrainerEvidenceAdapter.measurement(timer, at: point, sampledAt: t0, origin: tech) == nil)
    }

    @Test func temporalTracesBecomeTimedSamples() throws {
        let trace = TemporalObservation(target: "PE-3", samples: [
            TimedEvidenceSample(milliseconds: 20, value: .bool(false)),
            TimedEvidenceSample(milliseconds: 0, value: .bool(false)),
            TimedEvidenceSample(milliseconds: 10, value: .bool(true), confidence: .verified),
        ])
        let records = try TrainerEvidenceAdapter.measurements(trace, at: point, start: t0, origin: .simulation(run: point))
        #expect(records.map(\.value.value) == [0, 1, 0])
        #expect(records.map(\.sampledAt) == [t0, t0 + 0.01, t0 + 0.02])
        #expect(records.allSatisfy { $0.sampleRateHz == 100 && $0.truth == .modeled && $0.value.unit == "bool" })
        #expect(records[1].provenance.confidence == 0.95)

        let uneven = TemporalObservation(target: "FT-1", samples: [
            TimedEvidenceSample(milliseconds: 0, value: .real(4.1), condition: .unloaded),
            TimedEvidenceSample(milliseconds: 15, value: .real(4.3), condition: .unloaded),
            TimedEvidenceSample(milliseconds: 20, value: .real(4.2), condition: .unloaded),
        ], source: .learnerMeasurement)
        let current = try TrainerEvidenceAdapter.measurements(uneven, at: point, unit: "mA", start: t0, origin: tech)
        #expect(current.allSatisfy { $0.sampleRateHz == nil && $0.truth == .observed && $0.loading == "unloaded" })
        #expect(throws: UnitError.unknownUnit("milliamps")) {
            try TrainerEvidenceAdapter.measurements(uneven, at: point, unit: "milliamps", start: t0, origin: tech)
        }
    }
}
