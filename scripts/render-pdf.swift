// Prints an HTML page to a paginated A4 PDF with WebKit (no browser needed).
// Usage: swift scripts/render-pdf.swift <input.html> <output.pdf>
import AppKit
import WebKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: render-pdf.swift <input.html> <output.pdf>\n".utf8))
    exit(64)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard FileManager.default.fileExists(atPath: input.path) else {
    FileHandle.standardError.write(Data("render-pdf: \(input.path) does not exist\n".utf8))
    exit(1)
}

@MainActor
final class Printer: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let webView: WKWebView

    override init() {
        // A4 at 72 dpi minus the margins below, so pages lay out at their printed width.
        let frame = NSRect(x: 0, y: 0, width: 595 - 72, height: 842 - 72)
        webView = WKWebView(frame: frame)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
        webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let images decode before printing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.print() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func print() {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: output])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        for edge in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: edge] = 36 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printed(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard success else { return fail(CocoaError(.fileWriteUnknown)) }
        Swift.print(output.path)
        exit(0)
    }

    private func fail(_ error: Error) {
        FileHandle.standardError.write(Data("render-pdf: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let printer = MainActor.assumeIsolated { Printer() }
app.run()
