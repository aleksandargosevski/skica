import Foundation
import Testing
@testable import SkicaCore

@Suite struct DocumentArchiveTests {
    @Test func roundTripsTheSampleDocument() throws {
        let document = SampleDocuments.showcase()
        let data = try DocumentArchive.encode(document)
        #expect(try DocumentArchive.decode(data) == document)
    }

    @Test func rejectsFilesThatAreNotZip() {
        #expect(throws: DocumentError.notASkicaFile) {
            try DocumentArchive.decode(Data("hello".utf8))
        }
    }

    @Test func rejectsNewerFormats() throws {
        var document = Document()
        document.version = Document.currentVersion + 1
        let data = try DocumentArchive.encode(document)
        #expect(throws: DocumentError.newerVersion(Document.currentVersion + 1)) {
            try DocumentArchive.decode(data)
        }
    }

    @Test func rejectsMissingLayers() throws {
        var document = SampleDocuments.showcase()
        let missing = document.pages[0].layers[0]
        document.layers[missing] = nil
        let data = try DocumentArchive.encode(document)
        #expect(throws: DocumentError.self) {
            try DocumentArchive.decode(data)
        }
    }

    @Test func writesReadableJSON() throws {
        let json = try DocumentArchive.jsonEncoder.encode(SampleDocuments.showcase())
        let text = try #require(String(data: json, encoding: .utf8))
        #expect(text.contains("\"version\" : 1"))
        #expect(text.contains("\"#5B5BD6\""))
    }

    @Test func sampleDocumentsAreValid() throws {
        try SampleDocuments.showcase().validate()
        let stress = SampleDocuments.stress(count: 1_200)
        try stress.validate()
        #expect(stress.layers.count == 1_200 + 3)
    }
}

@Suite struct ColorTests {
    @Test func parsesHex() {
        #expect(Color(hex: "#fff") == .white)
        #expect(Color(hex: "000000") == .black)
        #expect(Color(hex: "#11223380") == Color(red: 0x11, green: 0x22, blue: 0x33, alpha: 0x80))
        #expect(Color(hex: "#12") == nil)
        #expect(Color(hex: "#zzzzzz") == nil)
    }

    @Test func formatsHex() {
        #expect(Color(red: 255, green: 102, blue: 0).hex == "#FF6600")
        #expect(Color(red: 255, green: 102, blue: 0, alpha: 128).hex == "#FF660080")
    }
}
