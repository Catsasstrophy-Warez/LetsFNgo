import Foundation
import NexusCore
import NexusModel
import Testing
@testable import NexusAI

@Suite struct JSONTests {
    @Test func parsesEveryShape() throws {
        let json = try JSONValue(parsing: #" { "a": [1, -2.5, 3e2, true, false, null], "b": {"c": "d"}, "e": 9007199254740993 } "#)
        #expect(json == .object([
            "a": .array([.int(1), .double(-2.5), .double(300), .bool(true), .bool(false), .null]),
            "b": .object(["c": .string("d")]),
            "e": .int(9_007_199_254_740_993),
        ]))
    }

    @Test func stringsUnescapeAndReescape() throws {
        let json = try JSONValue(parsing: #""quote \" slash \\ \/ nl \n tab \t e é emoji 😀 ctl \u0001""#)
        #expect(json == .string("quote \" slash \\ / nl \n tab \t e é emoji 😀 ctl \u{01}"))
        #expect(json.serialized == #""quote \" slash \\ / nl \n tab \t e é emoji 😀 ctl \u0001""#)
        #expect(try JSONValue(parsing: json.serialized) == json)
    }

    @Test func serializationIsCompactAndSorted() {
        let value = JSONValue.object(["b": .array([.int(1), .double(2.5), .null]), "a": .bool(true), "c": .double(.nan)])
        #expect(value.serialized == #"{"a":true,"b":[1,2.5,null],"c":null}"#)
    }

    @Test func malformedInputIsRejected() {
        for text in ["", "{", "[1,]", #"{"a" 1}"#, "tru", #""unterminated"#, "1 2", #""\ud800""#, "\"a\u{01}\""] {
            #expect(throws: JSONError.self, "\(text)") { try JSONValue(parsing: text) }
        }
    }

    @Test func rawMemberReturnsExactSourceText() throws {
        let data = Data(#"{"id":"m","content": [ {"b":1,  "a":"é"} ] ,"x":null}"#.utf8)
        #expect(try JSONValue.rawMember("content", in: data) == #"[ {"b":1,  "a":"é"} ]"#)
        #expect(try JSONValue.rawMember("x", in: data) == "null")
        #expect(try JSONValue.rawMember("missing", in: data) == nil)
        #expect(try JSONValue.rawMember("content", in: Data("[1]".utf8)) == nil)
    }

    @Test func worldValuesConvertBothWays() throws {
        let id = ObjectID.make()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let value = Value.map([
            "s": .string("x"), "i": .int(-3), "d": .double(0.25), "b": .bool(false), "n": .null,
            "l": .list([.int(1), .string("two")]), "r": .reference(id), "q": .quantity(Quantity(12, "V")), "t": .date(date),
        ])
        let json = JSONValue(value)
        #expect(json["r"] == .string(id.description))
        #expect(json["q"] == .object(["value": .double(12), "unit": .string("V")]))
        #expect(json["t"] == .string("2023-11-14T22:13:20Z"))

        // Plain JSON shapes survive a round trip exactly.
        let plain = Value.map(["s": .string("x"), "i": .int(-3), "d": .double(0.25), "b": .bool(false), "n": .null, "l": .list([.int(1)])])
        #expect(try JSONValue(parsing: JSONValue(plain).serialized).value == plain)
    }
}
