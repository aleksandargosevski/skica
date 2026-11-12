import Foundation

/// The Figma personal access token: `FIGMA_TOKEN`, or `~/.config/skica/figma-token` (readable
/// only by the user).
public enum FigmaToken {
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/skica/figma-token")
    }

    public static func load() -> String? {
        if let token = ProcessInfo.processInfo.environment["FIGMA_TOKEN"], !token.isEmpty { return token }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public static func save(_ token: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
