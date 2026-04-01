import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class PreviewService: @unchecked Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func cachePreview(named identifier: String = UUID().uuidString, image: CGImage) throws -> URL {
        let safeIdentifier = identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let targetURL = directoryURL.appending(path: "\(safeIdentifier).jpg")
        guard let destination = CGImageDestinationCreateWithURL(targetURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreviewError.destinationCreationFailed(targetURL.path(percentEncoded: false))
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewError.writeFailed(targetURL.path(percentEncoded: false))
        }
        return targetURL
    }
}

public enum PreviewError: Error, LocalizedError {
    case destinationCreationFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .destinationCreationFailed(path):
            "Could not create preview destination at \(path)"
        case let .writeFailed(path):
            "Could not write preview at \(path)"
        }
    }
}
