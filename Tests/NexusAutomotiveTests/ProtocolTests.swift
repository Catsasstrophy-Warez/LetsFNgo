import Foundation
import NexusAutomotive
import Testing

@Suite struct VINTests {
    @Test func checkDigitKnownVectors() throws {
        // 49 CFR 565's worked example uses "X" for a remainder of 10.
        #expect(VIN.checkDigit(for: "1M8GDM9AXKP042788") == "X")
        #expect(try VIN("1M8GDM9AXKP042788", requireCheckDigit: true).isCheckDigitValid)
        #expect(VIN.checkDigit(for: "11111111111111111") == "1")
        #expect(try VIN("1hgcm82633a004352", requireCheckDigit: true).rawValue == "1HGCM82633A004352")
        #expect(throws: VIN.ValidationError.checkDigitMismatch(expected: "3", found: "4")) {
            try VIN("1HGCM82643A004352", requireCheckDigit: true)
        }
        // Without enforcement a mismatch still parses, and reports itself.
        #expect(try !VIN("1HGCM82643A004352").isCheckDigitValid)
    }

    @Test func rejectsBadCharactersAndLengths() {
        #expect(throws: VIN.ValidationError.wrongLength(16)) { try VIN("1HGCM82633A00435") }
        #expect(throws: VIN.ValidationError.invalidCharacter("O", position: 5)) { try VIN("1HGCO82633A004352") }
        #expect(throws: VIN.ValidationError.invalidCharacter("I", position: 1)) { try VIN("IHGCM82633A004352") }
        #expect(throws: VIN.ValidationError.invalidCharacter("Q", position: 17)) { try VIN("1HGCM82633A00435Q") }
    }

    @Test func decodesWMIAndModelYear() throws {
        let honda = try VIN("1HGCM82633A004352")
        #expect(honda.wmi == "1HG" && honda.manufacturer == "Honda (USA)")
        #expect(honda.region == "North America" && honda.country == "United States")
        #expect(honda.modelYearCandidates == [2003, 2033] && honda.modelYear == 2003)
        #expect(honda.vehicleDescriptor == "CM826" && honda.plantCode == "A" && honda.serial == "004352")

        // A letter in position 7 selects the 2010–2039 cycle.
        let tesla = try VIN.make(prefix: "5YJ3E1EA", suffix: "KF317000")
        #expect(tesla.isCheckDigitValid && tesla.manufacturer == "Tesla" && tesla.modelYear == 2019)
        let bmw = try VIN("WBA3A5C51CF256985")
        #expect(bmw.region == "Europe" && bmw.country == "Germany" && bmw.manufacturer == "BMW" && bmw.modelYear == 2012)
        #expect(try VIN("JHMCM56557C404453").country == "Japan")
        #expect(try VIN("KMHDN46D16U123456").country == "South Korea")
    }
}

@Suite struct OBDTests {
    func value(_ hex: String) throws -> Double {
        try #require(try OBD.decodeMode01(try ELM327.hexBytes(hex)).first).value
    }

    @Test func mode01FormulasMatchJ1979() throws {
        #expect(try value("41 0C 1A F8") == 1726)  // (256·26 + 248) / 4 rpm
        #expect(try value("41 0D 32") == 50)  // km/h
        #expect(try value("41 05 7B") == 83)  // 123 − 40 °C
        #expect(try value("41 0F 44") == 28)
        #expect(try value("41 10 01 F4") == 5)  // 500 / 100 g/s
        #expect(try value("41 11 FF") == 100)
        #expect(try value("41 04 80") == 128.0 * 100 / 255)
        #expect(try value("41 06 80") == 0)
        #expect(try value("41 07 90") == 12.5)
        #expect(try value("41 08 70") == -12.5)
        #expect(try value("41 09 00") == -100)
        #expect(try value("41 0B 65") == 101)  // kPa
        #expect(try value("41 0E 80") == 0)  // 128/2 − 64 °
        #expect(try value("41 14 5A 80") == 0.45)
        #expect(OBD.oxygenSensorTrim([0x5A, 0x80]) == 0 && OBD.oxygenSensorTrim([0x5A, 0xFF]) == nil)
        #expect(try value("41 42 31 0B") == 12.555)  // mV / 1000
        #expect(try value("41 46 3C") == 20)
        #expect(try value("41 5C 82") == 90)
        #expect(try value("41 1F 01 2C") == 300)

        let rpm = try #require(OBD.pids[0x0C])
        #expect(rpm.unit == "rpm" && rpm.site == .engine && rpm.quantity == "engineSpeed")
        #expect(OBD.pids.count >= 30)
    }

    @Test func multiPIDRepliesAndErrors() throws {
        let readings = try OBD.decodeMode01(try ELM327.hexBytes("41 0C 1A F8 0D 32 05 7B"))
        #expect(readings.map(\.quantity) == ["engineSpeed", "vehicleSpeed", "coolantTemperature"])
        #expect(readings.map(\.value) == [1726, 50, 83])
        #expect(throws: OBDError.unexpectedMode(0x43)) { try OBD.decodeMode01([0x43, 0x01]) }
        #expect(throws: OBDError.unknownPID(0xA6)) { try OBD.decodeMode01([0x41, 0xA6, 0x00]) }
        #expect(throws: OBDError.truncated) { try OBD.decodeMode01([0x41, 0x0C, 0x1A]) }
    }

    @Test func supportedPIDsAndMonitorStatus() throws {
        let supported = try OBD.supportedPIDs(try ELM327.hexBytes("41 00 BE 1F A8 13"))
        #expect(supported == [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20])
        let status = try OBD.monitorStatus(try ELM327.hexBytes("41 01 83 07 65 04"))
        #expect(status.milOn && status.storedCodes == 3)
    }

    @Test func troubleCodesFromTwoBytes() throws {
        #expect(DTC(0x01, 0x33).code == "P0133")
        #expect(DTC(0x05, 0x62).code == "P0562")
        #expect(DTC(0x41, 0x23).code == "C0123")
        #expect(DTC(0x9A, 0xBC).code == "B1ABC")
        #expect(DTC(0xC1, 0x00).code == "U0100")
        for code in ["P0300", "C0035", "B1000", "U3FFF", "P2A00"] {
            let dtc = try #require(DTC(code))
            #expect(DTC(dtc.bytes.0, dtc.bytes.1) == dtc)
        }
        #expect(DTC("P4000") == nil && DTC("X0100") == nil && DTC("P010") == nil)
        #expect(DTC("P0420")!.isGeneric && !DTC("P1420")!.isGeneric && DTC("P3400")!.isGeneric && !DTC("P3000")!.isGeneric)
        #expect(DTC("U0100")!.system == .network && DTC("C0035")!.system == .chassis)

        // CAN: mode, count, pairs. Legacy: three pairs per frame, zero padding.
        let can = try OBD.decodeDTCs(try ELM327.hexBytes("43 02 05 62 C1 00"), hasCount: true)
        #expect(can.status == .stored && can.codes.map(\.code) == ["P0562", "U0100"])
        let legacy = try OBD.decodeDTCs(try ELM327.hexBytes("43 01 33 00 00 00 00"), hasCount: false)
        #expect(legacy.codes.map(\.code) == ["P0133"])
        #expect(try OBD.decodeDTCs(try ELM327.hexBytes("47 01 03 03"), hasCount: true).status == .pending)
        #expect(try OBD.decodeDTCs(try ELM327.hexBytes("4A 00"), hasCount: true).codes.isEmpty)
        #expect(throws: OBDError.truncated) { try OBD.decodeDTCs([0x43, 0x02, 0x05, 0x62], hasCount: true) }
    }

    @Test func mode09VINFromAllThreeLayouts() throws {
        let headersOff = try ELM327.parse("014\r0: 49 02 01 31 48 47\r1: 43 4D 38 32 36 33 33\r2: 41 30 30 34 33 35 32\r\r>")
        #expect(try OBD.decodeVIN(headersOff[0].bytes).rawValue == "1HGCM82633A004352")

        let headersOn = try ELM327.parse("7E8 10 14 49 02 01 31 48 47\r7E8 21 43 4D 38 32 36 33 33\r7E8 22 41 30 30 34 33 35 32", headers: .on)
        #expect(headersOn.map(\.ecu) == ["7E8"])
        #expect(try OBD.decodeVIN(headersOn[0].bytes).rawValue == "1HGCM82633A004352")

        let legacy = try ELM327.parse("49 02 01 00 00 00 31\r49 02 02 48 47 43 4D\r49 02 03 38 32 36 33\r49 02 04 33 41 30 30\r49 02 05 34 33 35 32")
        #expect(try OBD.decodeVIN(legacy.flatMap(\.bytes)).rawValue == "1HGCM82633A004352")
    }
}

@Suite struct ELM327Tests {
    @Test func headersOffVariants() throws {
        let expected = [ECUMessage(ecu: nil, bytes: [0x41, 0x0C, 0x1A, 0xF8])]
        #expect(try ELM327.parse("41 0C 1A F8\r\r>") == expected)
        #expect(try ELM327.parse("410C1AF8\r\n>") == expected)
        #expect(try ELM327.parse("010C\r41 0C 1A F8\r\r>", command: "010C") == expected)
        #expect(try ELM327.parse("SEARCHING...\r41 0C 1A F8\r>") == expected)
        // Two modules answering.
        let two = try ELM327.parse("41 00 BE 3F A8 13\r41 00 98 18 80 11\r>")
        #expect(two.count == 2)
    }

    @Test func headersOnVariants() throws {
        let can11 = try ELM327.parse("7E8 04 41 0C 1A F8\r7E9 03 41 0D 32\r>", headers: .on)
        #expect(can11 == [ECUMessage(ecu: "7E8", bytes: [0x41, 0x0C, 0x1A, 0xF8]), ECUMessage(ecu: "7E9", bytes: [0x41, 0x0D, 0x32])])
        #expect(try ELM327.parse("7E8044100BE3FA813", headers: .on) == [ECUMessage(ecu: "7E8", bytes: [0x41, 0x00, 0xBE, 0x3F])])
        let can29 = try ELM327.parse("18 DA F1 10 04 41 0C 1A F8", headers: .on)
        #expect(can29 == [ECUMessage(ecu: "18DAF110", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
        #expect(try ELM327.parse("18DAF110 04 41 0C 1A F8", headers: .on) == can29)
        let legacy = try ELM327.parse("48 6B 10 41 0C 1A F8 C4", headers: .on)
        #expect(legacy == [ECUMessage(ecu: "486B10", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    @Test func errorsAndAdapterVoltage() {
        #expect(throws: ELM327Error.noData) { try ELM327.parse("NO DATA\r\r>") }
        #expect(throws: ELM327Error.noData) { try ELM327.parse("SEARCHING...\rNO DATA\r>") }
        #expect(throws: ELM327Error.adapter("CAN ERROR")) { try ELM327.parse("CAN ERROR\r>") }
        #expect(throws: ELM327Error.adapter("UNABLE TO CONNECT")) { try ELM327.parse("UNABLE TO CONNECT\r>") }
        #expect(throws: ELM327Error.adapter("?")) { try ELM327.parse("?\r>") }
        #expect(throws: ELM327Error.malformed("41 0C 1A F")) { try ELM327.parse("41 0C 1A F") }
        #expect(throws: ELM327Error.self) { try ELM327.parse("7E8 21 00 00", headers: .on) }
        #expect(ELM327.parseVoltage("12.6V\r\r>") == 12.6)
        #expect(ELM327.parseVoltage("14.2 V") == 14.2)
        #expect(ELM327.parseVoltage("OK") == nil)
    }
}

@Suite struct CANTests {
    @Test func intelSignalsDecodeKnownVectors() throws {
        // J1939 EEC1 engine speed: bytes 4–5, 0.125 rpm/bit. 0x1368 = 4968 → 621 rpm.
        let speed = DBCSignal(name: "EngineSpeed", startBit: 24, length: 16, byteOrder: .littleEndian, factor: 0.125, unit: "rpm")
        #expect(try speed.decode([0xFF, 0xFF, 0xFF, 0x68, 0x13, 0xFF, 0xFF, 0xFF]) == 621)
        // Coolant, one byte with −40 offset.
        let coolant = DBCSignal(name: "Coolant", startBit: 0, length: 8, byteOrder: .littleEndian, offset: -40)
        #expect(try coolant.decode([0x7B]) == 83)
        // A 4-bit field inside a byte, and a signed byte.
        let nibble = DBCSignal(name: "Gear", startBit: 4, length: 4, byteOrder: .littleEndian)
        #expect(try nibble.decode([0xA5]) == 10)
        let signed = DBCSignal(name: "Torque", startBit: 0, length: 8, byteOrder: .littleEndian, isSigned: true)
        #expect(try signed.decode([0xFE]) == -2)
        // A 12-bit field spanning a byte boundary: bits 4–15.
        let wide = DBCSignal(name: "Wide", startBit: 4, length: 12, byteOrder: .littleEndian)
        #expect(try wide.decode([0x40, 0x12]) == 0x124)
    }

    @Test func motorolaSignalsDecodeKnownVectors() throws {
        let word = DBCSignal(name: "Word", startBit: 7, length: 16, byteOrder: .bigEndian)
        #expect(try word.decode([0x01, 0x02]) == 0x0102)
        let twelve = DBCSignal(name: "Twelve", startBit: 7, length: 12, byteOrder: .bigEndian)
        #expect(try twelve.decode([0x12, 0x34]) == 0x123)
        // Starts mid-byte: MSB at bit 3 of byte 0, 8 bits → low nibble of byte 0, high nibble of byte 1.
        let skewed = DBCSignal(name: "Skewed", startBit: 3, length: 8, byteOrder: .bigEndian)
        #expect(try skewed.decode([0xAB, 0xCD]) == 0xBC)
        let signed = DBCSignal(name: "Temp", startBit: 7, length: 16, byteOrder: .bigEndian, isSigned: true, factor: 0.1)
        #expect(abs(try signed.decode([0xFF, 0x38]) - -20) < 1e-9)
        #expect(throws: CANError.signalOutOfRange("Word")) { try word.decode([0x01]) }
    }

    @Test func encodingRoundTrips() throws {
        let signals = [
            DBCSignal(name: "A", startBit: 24, length: 16, byteOrder: .littleEndian, factor: 0.125),
            DBCSignal(name: "B", startBit: 3, length: 10, byteOrder: .bigEndian, isSigned: true, factor: 0.5, offset: 1),
            DBCSignal(name: "C", startBit: 44, length: 7, byteOrder: .littleEndian, isSigned: true),
        ]
        var data = [UInt8](repeating: 0, count: 8)
        try signals[0].encode(1234.5, into: &data)
        try signals[1].encode(-40, into: &data)
        try signals[2].encode(-17, into: &data)
        #expect(try signals.map { try $0.decode(data) } == [1234.5, -40, -17])
    }

    @Test func parsesADBCSubset() throws {
        let text = """
            VERSION ""

            NS_ :
                CM_

            BU_: Engine Dash

            BO_ 2364539904 EEC1: 8 Engine
             SG_ EngineSpeed : 24|16@1+ (0.125,0) [0|8031.875] "rpm" Dash
             SG_ DriverDemandTorque : 8|8@1+ (1,-125) [-125|125] "%" Vector__XXX

            BO_ 1280 BodyStatus: 4 Dash
             SG_ Mode M : 0|2@1+ (1,0) [0|3] "" Engine
             SG_ BatteryVolts : 15|12@0+ (0.01,0) [0|40.95] "V" Engine,Dash
             SG_ Ambient : 31|8@0- (0.5,0) [-64|63.5] "degC" Engine

            CM_ SG_ 2364539904 EngineSpeed "Actual engine speed";
            VAL_ 1280 Mode 0 "Off" 1 "On" ;
            """
        let database = try DBCDatabase.parse(text)
        #expect(database.messages.map(\.name) == ["EEC1", "BodyStatus"])
        let eec1 = try #require(database.message(named: "EEC1"))
        #expect(eec1.isExtended && eec1.canID == 0x0CF0_0400 && eec1.length == 8 && eec1.sender == "Engine")
        #expect(eec1.signals.map(\.name) == ["EngineSpeed", "DriverDemandTorque"])
        #expect(eec1.signals[0].unit == "rpm" && eec1.signals[0].receivers == ["Dash"] && eec1.signals[1].receivers.isEmpty)
        let body = try #require(database.message(named: "BodyStatus"))
        #expect(body.signals.map(\.byteOrder) == [.littleEndian, .bigEndian, .bigEndian])
        #expect(body.signals[2].isSigned && body.signals[1].receivers == ["Engine", "Dash"])

        let frame = CANFrame(id: 0x0CF0_0400, isExtended: true, data: [0x00, 0xAF, 0x00, 0x68, 0x13, 0x00, 0x00, 0x00])
        let values = try #require(try database.decode(frame))
        #expect(values["EngineSpeed"] == 621 && values["DriverDemandTorque"] == 50)
        // BatteryVolts: 12 bits from bit 15 (byte 1 MSB), big endian: 0x4E2 = 1250 → 12.5 V. Ambient −10 °C.
        let status = CANFrame(id: 1280, data: [0x01, 0x4E, 0x20, 0xEC])
        let decoded = try #require(try database.decode(status))
        #expect(abs(decoded["BatteryVolts"]! - 12.5) < 1e-9 && decoded["Ambient"] == -10 && decoded["Mode"] == 1)
        #expect(try database.decode(CANFrame(id: 0x7E8, data: [0x02])) == nil)

        #expect(throws: CANError.malformedDBC(line: 1, text: "SG_ Orphan : 0|8@1+ (1,0) [0|255] \"\" X")) {
            try DBCDatabase.parse("SG_ Orphan : 0|8@1+ (1,0) [0|255] \"\" X")
        }
        #expect(throws: CANError.self) { try DBCDatabase.parse("BO_ 100 Bad: 8 X\n SG_ S : 0|8@2+ (1,0) [0|1] \"\" X") }
    }
}

@Suite struct DTCKnowledgeBaseTests {
    @Test func bundledTableCoversCommonGenericCodes() throws {
        let base = DTCKnowledgeBase.generic
        #expect(base.definitions.count >= 40)
        #expect(base.definitions.keys.allSatisfy { $0.code.hasPrefix("P0") && $0.isGeneric })
        #expect(base[DTC("P0562")!]?.description == "System voltage low")
        #expect(base[DTC("P0562")!]?.likelyComponents.first == .alternator)
        #expect(base[DTC("P0303")!]?.description == "Cylinder 3 misfire detected")
        #expect(base.describe(DTC("P0999")!) == "Generic code, not in the bundled table")
        #expect(base.describe(DTC("P1456")!) == "Manufacturer-specific code")
    }
}
