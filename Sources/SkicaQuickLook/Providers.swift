import AppKit
import Quartz
import QuickLookThumbnailing
import SkicaCore
import SkicaRender
import UniformTypeIdentifiers

/// Finder icons of .skica files: the first page with layers.
@objc(SkicaThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let document = try DocumentArchive.decode(Data(contentsOf: request.fileURL))
            guard let size = PagePreview.size(of: document, fitting: request.maximumSize) else {
                return handler(nil, ExportError.nothingToExport)
            }
            handler(QLThumbnailReply(contextSize: size) { context in
                PagePreview.draw(document, in: context, size: size)
            }, nil)
        } catch {
            handler(nil, error)
        }
    }
}

/// The space-bar preview of .skica files.
@objc(SkicaPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let document = try DocumentArchive.decode(Data(contentsOf: request.fileURL))
        let data = try PagePreview.png(of: document, maximumSide: 2400)
        let size = PagePreview.size(of: document, fitting: CGSize(width: 1200, height: 900)) ?? CGSize(width: 800, height: 600)
        return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in data }
    }
}
