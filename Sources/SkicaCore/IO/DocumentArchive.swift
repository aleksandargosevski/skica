import Foundation
import ZIPFoundation

/// Reads and writes `.skica` files: a zip archive with `document.json` and `images/<sha256>.<ext>`.
public enum DocumentArchive {
    static let documentEntry = "document.json"
    static let imagesFolder = "images/"

    public static func encode(_ document: Document) throws -> Data {
        let json: Data
        do {
            json = try jsonEncoder.encode(document)
        } catch {
            throw DocumentError.couldNotWrite(error.localizedDescription)
        }

        do {
            let archive = try Archive(accessMode: .create)
            try add(json, as: documentEntry, compressed: true, to: archive)
            // Only images some layer shows are written; the rest were removed or undone.
            for hash in document.referencedImages.sorted() {
                guard let data = document.images[hash] else { continue }
                // Image formats are already compressed.
                try add(data, as: imagesFolder + hash + "." + ImageData.fileExtension(of: data), compressed: false, to: archive)
            }
            guard let data = archive.data else { throw DocumentError.couldNotWrite("The archive is empty.") }
            return data
        } catch let error as DocumentError {
            throw error
        } catch {
            throw DocumentError.couldNotWrite(error.localizedDescription)
        }
    }

    public static func decode(_ data: Data) throws -> Document {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentError.notASkicaFile
        }
        guard let entry = archive[documentEntry] else { throw DocumentError.missingDocument }

        var json = Data()
        do {
            _ = try archive.extract(entry) { json.append($0) }
        } catch {
            throw DocumentError.corrupt("document.json could not be unpacked (\(error.localizedDescription)).")
        }
        var document = try DocumentMigrations.decode(json)
        for entry in archive where entry.path.hasPrefix(imagesFolder) {
            let name = String(entry.path.dropFirst(imagesFolder.count))
            let hash = name.split(separator: ".").first.map(String.init) ?? name
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                throw DocumentError.corrupt("Image \(name) could not be unpacked (\(error.localizedDescription)).")
            }
            document.images[hash] = data
        }
        return document
    }

    private static func add(_ data: Data, as path: String, compressed: Bool, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressed ? .deflate : .none,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }

    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Upgrades `document.json` written by older versions before decoding it.
enum DocumentMigrations {
    private struct VersionProbe: Decodable {
        let version: Int
    }

    static func decode(_ json: Data) throws -> Document {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: json) else {
            throw DocumentError.corrupt("document.json has no format version.")
        }
        if probe.version > Document.currentVersion {
            throw DocumentError.newerVersion(probe.version)
        }
        // Migrations from older versions go here, one step per version, on the JSON object.

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: json)
        } catch let error as DecodingError {
            throw DocumentError.corrupt(describe(error))
        }
        try document.validate()
        return document
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing \"\(key.stringValue)\" at \(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))."
        @unknown default:
            return error.localizedDescription
        }
    }
}
