import Foundation
import NexusArchitecture
import NexusCore
import NexusModel
import NexusPersistence
import Testing

enum SpaceFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_790_553_600)  // 2026-09-28 UTC

    /// A small IFC4 file: project → site → building → two storeys → three
    /// spaces, a millimetre length unit, one space's quantities, a comment,
    /// a complex instance and a \X2\ escape. Placement and geometry omitted.
    static let ifc = """
        ISO-10303-21;
        HEADER;
        FILE_DESCRIPTION(('ViewDefinition [ReferenceView]'),'2;1');
        FILE_NAME('harbor-hq.ifc','2026-09-01T10:00:00',('Ana Silva'),('Harbor'),'IfcOpenShell 0.8','Revit 2026','');
        FILE_SCHEMA(('IFC4'));
        ENDSEC;
        DATA;
        /* units */
        #10=IFCSIUNIT(*,.LENGTHUNIT.,.MILLI.,.METRE.);
        #11=IFCSIUNIT(*,.AREAUNIT.,$,.SQUARE_METRE.);
        #12=(IFCLENGTHMEASURE(1.)IFCNAMEDUNIT(*,.LENGTHUNIT.));
        #1=IFCPROJECT('0YvctVUKr0kugbFTf53O9L',$,'Harbor HQ',$,$,$,$,$,$);
        #100=IFCSITE('1hqIFTRjfV6AWq_bMtnZwI',$,'Campus',$,$,$,$,'Harbor Campus Lisbon',.ELEMENT.,(38,42,0),(-9,-8,0),12.,$,$);
        #200=IFCBUILDING('2FCZDorxHDT8NI01kdXi8P',$,'HQ',$,$,$,$,'Harbor HQ',.ELEMENT.,$,$,$);
        #300=IFCBUILDINGSTOREY('3Pg$2o5EP4aBkdX1Qb4aV3',$,'Level 1',$,$,$,$,$,.ELEMENT.,0.);
        #301=IFCBUILDINGSTOREY('3Pg$2o5EP4aBkdX1Qb4aV4',$,'Level 2',$,$,$,$,$,.ELEMENT.,3500.);
        #400=IFCSPACE('4Ta9Xq1cL0ZfZrPqEo2WaA',$,'101',$,$,$,$,'Open office',.ELEMENT.,.INTERNAL.,$);
        #401=IFCSPACE('4Ta9Xq1cL0ZfZrPqEo2WaB',$,'102',$,$,$,$,'Sala \\X2\\00C9\\X0\\vora',.ELEMENT.,.INTERNAL.,$);
        #402=IFCSPACE('4Ta9Xq1cL0ZfZrPqEo2WaC',$,'201',$,$,$,$,'Lab''s bench room',.ELEMENT.,$,$);
        #500=IFCRELAGGREGATES('5a',$,$,$,#1,(#100));
        #501=IFCRELAGGREGATES('5b',$,$,$,#100,(#200));
        #502=IFCRELAGGREGATES('5c',$,$,$,#200,(#300,#301));
        #503=IFCRELAGGREGATES('5d',$,$,$,#300,(#400,#401));
        #504=IFCRELAGGREGATES('5e',$,$,$,#301,(#402));
        #600=IFCQUANTITYAREA('GrossFloorArea',$,$,92.,$);
        #601=IFCQUANTITYAREA('NetFloorArea',$,$,86.5,$);
        #602=IFCELEMENTQUANTITY('6a',$,'Qto_SpaceBaseQuantities',$,$,(#600,#601));
        #603=IFCRELDEFINESBYPROPERTIES('6b',$,$,$,(#400),#602);
        #604=IFCQUANTITYAREA('NetFloorArea',$,$,24.25,$);
        #605=IFCELEMENTQUANTITY('6c',$,'Qto_SpaceBaseQuantities',$,$,(#604));
        #606=IFCRELDEFINESBYPROPERTIES('6d',$,$,$,(#401,#402),#605);
        ENDSEC;
        END-ISO-10303-21;

        """

    static let csv = #"""
        Building,Level,Room No,Room Name,Area (sq ft),Seats,Use
        Annex,Ground,G01,Reception,"1,076",4,lobby
        Annex,Ground,G02,Workshop,538.2,,workshop
        Annex,First,101,"Meeting room ""North""",215.3,8,meeting

        """#
}

@Suite struct STEPTests {
    @Test func parsesEntitiesStringsAndHeader() throws {
        let file = try STEP.parse(SpaceFixtures.ifc)
        #expect(file.header("FILE_SCHEMA")?[0] == .list([.string("IFC4")]))
        #expect(file.entities[12] == nil, "Complex instances are skipped")
        let space = try #require(file.entities[401])
        #expect(space.type == "IFCSPACE" && space[7] == .string("Sala Évora") && space[8] == .enumeration("ELEMENT") && space[10] == .null)
        #expect(file.entities[402]?[7] == .string("Lab's bench room"))
        #expect(file.entities[100]?[9] == .list([.integer(38), .integer(42), .integer(0)]))
        #expect(file.entities[100]?[11] == .real(12))
        #expect(file.entities[10]?[0] == .derived)
        #expect(file.entities[502]?[5].references == [300, 301])
    }

    @Test func reportsMalformedFiles() {
        #expect(throws: ArchitectureError.malformedIFC(line: 1, reason: "missing ISO-10303-21 header")) { try STEP.parse("hello") }
        #expect(throws: ArchitectureError.malformedIFC(line: 3, reason: "missing END-ISO-10303-21")) {
            try STEP.parse("ISO-10303-21;\nDATA;\n#1=IFCWALL('a',$);")
        }
        #expect(throws: ArchitectureError.malformedIFC(line: 3, reason: "unterminated string")) {
            try STEP.parse("ISO-10303-21;\nDATA;\n#1=IFCWALL('a,$);\nENDSEC;\nEND-ISO-10303-21;")
        }
    }

    @Test func readsTheSpatialStructure() throws {
        let model = try IFCSpatialModel.read(SpaceFixtures.ifc)
        #expect(model.schema == "IFC4" && model.fileName == "harbor-hq.ifc" && model.application == "Revit 2026")
        #expect(model.nodes.map(\.level) == [.site, .building, .storey, .storey, .space, .space, .space])
        let site = model.nodes[0]
        #expect(site.parent == nil && site.title == "Harbor Campus Lisbon", "The IfcProject above the site is not spatial")
        #expect(model.nodes[3].elevation == 3.5, "Millimetres to metres")
        let office = model.nodes[4]
        #expect(office.title == "101 Open office" && office.parent == "3Pg$2o5EP4aBkdX1Qb4aV3")
        #expect(office.area == Quantity(86.5, AreaUnit.squareMetre), "Net area preferred over gross")
        #expect(model.nodes[6].area == Quantity(24.25, AreaUnit.squareMetre))
    }
}

@Suite struct SpaceImportTests {
    let person = Origin.user(id: "sam")

    @Test func importsIFCAsRecordedAndReimportsByGlobalID() throws {
        let clock = ManualClock(SpaceFixtures.t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let importer = SpaceImporter(store: store, clock: clock)
        let result = try importer.importIFC(Data(SpaceFixtures.ifc.utf8), named: "harbor-hq.ifc", by: person)
        #expect(result.created.count == 7)
        #expect(result.created.allSatisfy { $0.provenance.truth == .recorded && $0.provenance.origin == .importer(source: result.document.id) })
        let spaces = importer.spaces
        let building = try #require(try spaces.all(.building).first)
        #expect(try spaces.children(of: building.id).map(\.title) == ["Level 1", "Level 2"])
        let summary = try spaces.area(of: building.id)
        #expect(summary.spaces == 3 && summary.spacesWithoutArea == 0 && abs(summary.squareMetres - 135) < 1e-9 && summary.truth == .derived)
        let lab = try #require(try spaces.all(.space).map(Space.init).first { $0.number == "201" })
        #expect(try spaces.path(of: lab.id).map(\.title) == ["Harbor Campus Lisbon", "Harbor HQ", "Level 2", "201 Lab's bench room"])

        // A person corrects the lab's area; the next file's area does not replace it.
        try store.update(lab.id, by: person) {
            $0.attributes[SpaceKey.area] = Attribute(
                .quantity(Quantity(30, AreaUnit.squareMetre)), provenance: Provenance(origin: person, truth: .observed, timestamp: clock.now()))
        }
        let revised = SpaceFixtures.ifc.replacingOccurrences(of: "24.25", with: "25.")
        let again = try importer.importIFC(Data(revised.utf8), named: "harbor-hq-v2.ifc", by: person)
        #expect(again.created.isEmpty && again.updated.count == 1 && again.unchanged == 6, "Only room 102 takes the new area")
        #expect(try store.object(lab.id).map(Space.init)?.area?.value == 30)
    }

    @Test func importsASpaceListInSquareFeet() throws {
        let clock = ManualClock(SpaceFixtures.t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let importer = SpaceImporter(store: store, clock: clock)
        let rows = try SpaceList.parse(SpaceFixtures.csv)
        #expect(rows.count == 3 && rows[0].area == Quantity(1_076, AreaUnit.squareFoot) && rows[1].capacity == nil)
        #expect(rows[2].title == "101 Meeting room \"North\"" && rows[2].use == "meeting")

        let result = try importer.importSpaceList(Data(SpaceFixtures.csv.utf8), named: "annex.csv", by: person)
        #expect(result.created.count == 6, "One building, two storeys, three spaces")
        let annex = try #require(try importer.spaces.all(.building).first)
        #expect(annex.title == "Annex")
        #expect(abs(try importer.spaces.area(of: annex.id).squareMetres - 1_829.5 * AreaUnit.squareMetresPerSquareFoot) < 1e-6)

        let again = try importer.importSpaceList(Data(SpaceFixtures.csv.utf8), named: "annex.csv", by: person)
        #expect(again.created.isEmpty && again.unchanged == 3)
        #expect(throws: ArchitectureError.missingColumn("number or name")) { try SpaceList.parse("Building,Area\nA,10\n") }
        #expect(throws: ArchitectureError.malformedCSV(line: 2, reason: "bad area 'big'")) { try SpaceList.parse("Room,Area\n1,big\n") }
        #expect(SpaceList.parse(number: "1.234,5") == 1_234.5)
    }
}

extension SpaceList {
    static func parse(number text: String) -> Double? { try? parse("Room,Area\n1,\"\(text)\"\n").first?.area?.value }
}

@Suite struct AssetAndScheduleTests {
    let person = Origin.user(id: "sam")

    func setUp() throws -> (NexusStore, SpaceRuntime, ManualClock, building: ObjectID, office: Space, lab: Space) {
        let clock = ManualClock(SpaceFixtures.t0)
        let store = try NexusStore(.inMemory, clock: clock)
        let spaces = SpaceRuntime(store: store, clock: clock)
        let building = try spaces.add(.building, named: "HQ", by: person)
        let floor = try spaces.add(.storey, named: "Level 1", in: building.id, by: person)
        let office = try spaces.addSpace(number: "101", name: "Office", area: Quantity(40, AreaUnit.squareMetre), capacity: 6, in: floor.id, by: person)
        let lab = try spaces.addSpace(number: "102", name: "Lab", capacity: 12, in: floor.id, by: person)
        return (store, spaces, clock, building.id, office, lab)
    }

    @Test func assetsMoveBetweenSpacesWithHistory() throws {
        let (store, spaces, clock, building, office, lab) = try setUp()
        let pump = try store.create(
            ObjectRecord(type: .equipment, title: "Test bench pump", provenance: Provenance(origin: person, truth: .recorded, timestamp: clock.now())))
        try spaces.locate(pump.id, in: office.id, by: person)
        #expect(try spaces.location(of: pump.id)?.id == office.id)
        clock.advance(by: 3_600)
        try spaces.locate(pump.id, in: lab.id, by: person)
        #expect(try spaces.location(of: pump.id)?.id == lab.id)
        let history = try spaces.locationHistory(of: pump.id)
        #expect(history.map(\.to) == [office.id, lab.id] && history[0].validTo == clock.now() && history[1].validTo == nil)
        #expect(try spaces.assets(in: building).map(\.id) == [pump.id])
        #expect(try spaces.assets(in: office.id).isEmpty)
        #expect(throws: ArchitectureError.notAnAsset(office.id)) { try spaces.locate(office.id, in: lab.id, by: person) }
        #expect(throws: ArchitectureError.invalidNesting(child: .building, parent: .space)) {
            try spaces.add(.building, named: "Nope", in: office.id, by: person)
        }
        #expect(try spaces.area(of: building).spacesWithoutArea == 1)
    }

    @Test func roomSchedulesRefuseDoubleBookings() throws {
        let (_, spaces, _, building, office, lab) = try setUp()
        let nine = SpaceFixtures.t0.addingTimeInterval(9 * 3_600)
        let standup = try spaces.reserve(office.id, title: "Stand-up", from: nine, to: nine + 1_800, organizer: "Ana", by: person)
        #expect(standup.record.provenance.truth == .observed)
        try spaces.reserve(office.id, title: "Review", from: nine + 1_800, to: nine + 3_600, by: person)
        #expect(throws: ArchitectureError.doubleBooked(space: office.id, conflictsWith: [standup.id])) {
            try spaces.reserve(office.id, title: "Clash", from: nine + 600, to: nine + 900, by: person)
        }
        #expect(throws: ArchitectureError.invalidInterval(start: nine, end: nine)) { try spaces.reserve(lab.id, title: "x", from: nine, to: nine, by: person) }
        #expect(try spaces.reservations(of: office.id).map(\.title) == ["Stand-up", "Review"])
        let morning = DateInterval(start: nine, duration: 3_600)
        #expect(try spaces.freeSpaces(in: building, during: morning).map(\.id) == [lab.id])
        #expect(try spaces.freeSpaces(in: building, during: morning, capacity: 20).isEmpty)
        #expect(try spaces.freeSpaces(in: building, during: DateInterval(start: nine + 3_600, duration: 600), capacity: 6).count == 2)
    }
}
