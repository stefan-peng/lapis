import CoreGraphics
import Foundation

public protocol RawDecoder: Sendable {
    func metadata(for fileURL: URL) throws -> ImportedAsset
    func renderThumbnail(for fileURL: URL, maxPixelSize: Int) throws -> CGImage
}
