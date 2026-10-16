import Foundation
import Testing
@testable import GandalfCore

@Suite struct JSONTests {
    @Test func compactSerializationSortsKeys() throws {
        let v = try JSON.parse(#"{"b": [1, 2, {"x": null}], "a": "s", "e": {}, "f": [], "t": true}"#)
        #expect(v.serialized() == #"{"a":"s","b":[1,2,{"x":null}],"e":{},"f":[],"t":true}"#)
    }

    @Test func prettySerialization() throws {
        let v = try JSON.parse(#"{"c": {}, "a": [1, {"b": 2}], "d": []}"#)
        let expected = """
        {
          "a": [
            1,
            {
              "b": 2
            }
          ],
          "c": {},
          "d": []
        }
        """
        #expect(v.serialized(pretty: true) == expected)
    }

    @Test func stringEscapes() throws {
        let s = JSON.string("q\"b\\n\nr\rt\tc\u{01}ü\u{2028}")
        let out = s.serialized()
        #expect(out == #""q\"b\\n\nr\rt\tc\u0001ü"# + "\u{2028}\"")
        #expect(try JSON.parse(out) == s)
    }

    @Test func parsesEscapesAndSurrogates() throws {
        let v = try JSON.parse(#""aé😀\/\b""#)
        #expect(v.stringValue == "aé😀/\u{08}")
    }

    @Test func numbersRoundTrip() throws {
        #expect(try JSON.parse("123456789012345678") == .int(123456789012345678))
        #expect(try JSON.parse("1.5e3") == .double(1500))
        #expect(JSON.double(1500).serialized() == "1500.0")
        #expect(JSON.double(.infinity).serialized() == "null")
        #expect(JSON.double(2.0).intValue == 2)
        #expect(JSON.double(2.5).intValue == nil)
        #expect(JSON.string("2").intValue == nil)
    }

    @Test func descriptionAndTruth() {
        #expect(JSON.null.description == "null")
        #expect(JSON.bool(true).description == "true")
        #expect(JSON.int(7).description == "7")
        #expect(JSON.string("x").description == "x")
        #expect(JSON.array([.int(1)]).description == "[1]")
        #expect(JSON.bool(true).isTrue)
        #expect(!JSON.int(1).isTrue)
        #expect(!JSON.string("true").isTrue)
    }

    @Test func parseErrors() {
        #expect(throws: JSON.ParseError.self) { try JSON.parse("not json") }
        #expect(throws: JSON.ParseError.self) { try JSON.parse("[1, 2") }
        #expect(throws: JSON.ParseError.self) { try JSON.parse("{} x") }
        #expect(throws: JSON.ParseError.self) { try JSON.parse(#"{"a" 1}"#) }
        do {
            _ = try JSON.parse("{} x")
        } catch let e as JSON.ParseError {
            #expect(e.description == "invalid JSON: trailing data at offset 3")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func subscriptOnNonObjectIsNull() {
        #expect(JSON.array([])["x"].isNull)
        #expect(JSON.string("s")["x"].isNull)
        #expect(JSON.object(["k": .int(1)])["k"] == .int(1))
        #expect(JSON.object(["k": .int(1)])["missing"].isNull)
    }
}
