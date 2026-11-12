import Foundation
import SkicaCore
import SkicaRender

/// `skica`: list, export and convert design files from the terminal.
let usage = """
Usage:
  skica list <file>
  skica export <file> [options]
  skica import <file.sketch|file.svg|figma link> <file.skica>   convert to a Skica document
  skica sample <file.skica>       write the sample document, to try things out
  skica shortcuts [--html]        list every command and its keys (Sketch and Figma presets)

<file> is a .skica, .sketch or .svg file. Figma links need a personal access token in
FIGMA_TOKEN or ~/.config/skica/figma-token.

Export options:
  -o, --output <folder>     where to write files (default: the current folder)
  -f, --format <format>     png, jpg, webp, heic, avif, pdf or svg (default: png)
  -s, --scale <size>        2x, 0.5x, 512w or 300h (default: 1x)
  -p, --page <name>         only artboards on this page
  -a, --artboard <name>     only this artboard (repeatable)
      --exportables         layers marked for export, with their own presets
      --single-pdf <file>   all exported artboards as pages of one PDF

Without --artboard or --exportables, every artboard is exported.
"""

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch let error as UsageError {
    let help = error.showsUsage ? "\n\(usage)\n" : ""
    FileHandle.standardError.write(Data("skica: \(error.message)\n\(help)".utf8))
    exit(error.showsUsage ? 64 : 1)
} catch {
    FileHandle.standardError.write(Data("skica: \(error.localizedDescription)\n".utf8))
    exit(1)
}

struct UsageError: Error {
    let message: String
    /// False for problems with the file's contents rather than with the command.
    var showsUsage = true
}

func run(_ arguments: [String]) throws {
    guard let command = arguments.first else { throw UsageError(message: "missing command") }
    switch command {
    case "list": try list(Array(arguments.dropFirst()))
    case "export": try export(Array(arguments.dropFirst()))
    case "import":
        guard arguments.count == 3 else { throw UsageError(message: "import takes a source file and a .skica file") }
        let document = try arguments[1].contains("figma.com") ? importFigma(arguments[1]) : open(arguments[1])
        let url = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath)
        try write(DocumentArchive.encode(document), to: url)
        print(url.path)
    case "sample":
        guard arguments.count == 2 else { throw UsageError(message: "sample takes one file") }
        let url = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        try write(DocumentArchive.encode(SampleDocuments.showcase()), to: url)
        print(url.path)
    case "shortcuts": print(shortcuts(html: arguments.dropFirst().contains("--html")))
    case "-h", "--help", "help": print(usage)
    default: throw UsageError(message: "unknown command \"\(command)\"")
    }
}

func open(_ path: String) throws -> Document {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do {
        return try DocumentImport.document(at: url)
    } catch let error as DocumentError {
        throw error
    } catch let error as ImportError {
        throw error
    } catch {
        throw UsageError(message: "cannot read \(path): \(error.localizedDescription)", showsUsage: false)
    }
}

func list(_ arguments: [String]) throws {
    guard arguments.count == 1 else { throw UsageError(message: "list takes one file") }
    let document = try open(arguments[0])
    for page in document.pages {
        print("\(page.name)")
        for id in document.artboards(on: page) {
            guard let layer = document.layers[id] else { continue }
            let presets = layer.exports.map { "\($0.size)\($0.suffix.isEmpty ? "" : " \($0.suffix)") \($0.format.title)" }
            let exports = presets.isEmpty ? "" : "   exports: " + presets.joined(separator: ", ")
            print("  \(layer.name)   \(Int(layer.frame.width))×\(Int(layer.frame.height))\(exports)")
        }
    }
    let exportables = document.exportableLayers.filter { document.layers[$0]?.isArtboard == false }
    if !exportables.isEmpty {
        print("Other layers marked for export:")
        for id in exportables { print("  \(document.exportName(of: id))") }
    }
}

func export(_ arguments: [String]) throws {
    var file: String?
    var output = FileManager.default.currentDirectoryPath
    var format = ExportPreset.Format.png
    var size = ExportPreset.Size.scale(1)
    var pageName: String?
    var artboardNames: [String] = []
    var exportables = false
    var singlePDF: String?

    var remaining = arguments[...]
    func value(for option: String) throws -> String {
        guard let next = remaining.popFirst() else { throw UsageError(message: "\(option) needs a value") }
        return next
    }
    while let argument = remaining.popFirst() {
        switch argument {
        case "-o", "--output": output = (try value(for: argument) as NSString).expandingTildeInPath
        case "-f", "--format":
            let text = try value(for: argument)
            guard let parsed = ExportPreset.Format(rawValue: text.lowercased() == "jpeg" ? "jpg" : text.lowercased()) else {
                throw UsageError(message: "unknown format \"\(text)\"")
            }
            format = parsed
        case "-s", "--scale":
            let text = try value(for: argument)
            guard let parsed = ExportPreset.Size(parsing: text) else { throw UsageError(message: "invalid size \"\(text)\"") }
            size = parsed
        case "-p", "--page": pageName = try value(for: argument)
        case "-a", "--artboard": artboardNames.append(try value(for: argument))
        case "--exportables": exportables = true
        case "--single-pdf": singlePDF = (try value(for: argument) as NSString).expandingTildeInPath
        default:
            if argument.hasPrefix("-") || file != nil { throw UsageError(message: "unexpected \"\(argument)\"") }
            file = argument
        }
    }
    guard let file else { throw UsageError(message: "export needs a file") }
    let document = try open(file)

    let pages = try pageName.map { name in
        guard let page = document.pages.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw UsageError(message: "no page named \"\(name)\"", showsUsage: false)
        }
        return [page]
    } ?? document.pages

    var targets: [LayerID]
    if exportables {
        let onPages = Set(pages.flatMap(document.listOrder(of:)))
        targets = document.exportableLayers.filter(onPages.contains)
    } else {
        targets = pages.flatMap(document.artboards(on:))
        if !artboardNames.isEmpty {
            let wanted = Set(artboardNames.map { $0.lowercased() })
            targets = targets.filter { wanted.contains(document.layers[$0]?.name.lowercased() ?? "") }
            let found = Set(targets.compactMap { document.layers[$0]?.name.lowercased() })
            if let missing = artboardNames.first(where: { !found.contains($0.lowercased()) }) {
                throw UsageError(message: "no artboard named \"\(missing)\"", showsUsage: false)
            }
        }
    }
    guard !targets.isEmpty else { throw UsageError(message: "nothing to export (no artboards or exportable layers found)", showsUsage: false) }

    if let singlePDF {
        let data = try Exporter.pdf(of: targets, in: document)
        try write(data, to: URL(fileURLWithPath: singlePDF))
        print(singlePDF)
        return
    }

    let preset = ExportPreset(size: size, suffix: ExportPreset.defaultSuffix(for: size), format: format)
    let files = try Exporter.files(for: targets, in: document, presets: exportables ? nil : [preset])
    let folder = URL(fileURLWithPath: output, isDirectory: true)
    for exported in files {
        let url = folder.appendingPathComponent(exported.path)
        try write(exported.data, to: url)
        print(url.path)
    }
}

func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func importFigma(_ link: String) throws -> Document {
    guard let key = FigmaImporter.fileKey(from: link) else { throw UsageError(message: "not a Figma file link: \(link)") }
    guard let token = FigmaToken.load() else {
        throw UsageError(message: "set FIGMA_TOKEN or write the token to \(FigmaToken.fileURL.path)", showsUsage: false)
    }
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<Document, Error> = .failure(UsageError(message: "the import did not finish"))
    Task {
        do { result = .success(try await FigmaImporter.document(fileKey: key, token: token)) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

/// The default shortcuts of every command by category; the Figma column only where it differs.
func shortcuts(html: Bool) -> String {
    let sketch = Keymap(preset: .sketch)
    let figma = Keymap(preset: .figma)
    func keys(_ keymap: Keymap, _ command: CommandID) -> [String] {
        keymap.sequences(for: command).map { $0.chords.map { $0.symbols.joined() }.joined(separator: " ") }
    }
    var output = html ? "<table class=\"shortcuts\">\n<thead><tr><th>Command</th><th>Keys</th><th>Figma preset</th></tr></thead>\n" : ""
    for category in CommandCategory.allCases {
        let commands = CommandID.allCases.filter { $0.category == category }
        guard !commands.isEmpty else { continue }
        output += html ? "<tbody><tr class=\"category\"><th colspan=\"3\">\(category.rawValue)</th></tr>\n" : "\n\(category.rawValue)\n"
        for command in commands {
            let main = keys(sketch, command)
            let other = keys(figma, command)
            let differs = other != main
            if html {
                let cell = { (keys: [String]) in keys.isEmpty ? "<span class=\"none\">⌘P</span>" : keys.map { "<kbd>\(escape($0))</kbd>" }.joined(separator: " ") }
                output += "<tr><td>\(escape(command.title))</td><td>\(cell(main))</td><td>\(differs ? cell(other) : "")</td></tr>\n"
            } else {
                let title = command.title.padding(toLength: 34, withPad: " ", startingAt: 0)
                output += "  \(title)\(main.isEmpty ? "(⌘P)" : main.joined(separator: ", "))\(differs ? "   figma: \(other.joined(separator: ", "))" : "")\n"
            }
        }
        if html { output += "</tbody>\n" }
    }
    return html ? output + "</table>" : output
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
