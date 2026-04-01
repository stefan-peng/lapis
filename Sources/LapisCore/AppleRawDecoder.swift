import CoreGraphics
import Foundation
import ImageIO

public final class AppleRawDecoder: RawDecoder, @unchecked Sendable {
    public init() {}

    public func metadata(for fileURL: URL) throws -> ImportedAsset {
        let path = fileURL.path(percentEncoded: false)
        guard
            let format = AssetFormat.from(fileExtension: fileURL.pathExtension),
            let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw DecoderError.unsupportedFile(path)
        }

        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gpsDictionary = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let fileIdentity = resourceValues.fileResourceIdentifier.map { String(describing: $0) } ?? path

        return ImportedAsset(
            sourceURL: fileURL,
            fileIdentity: fileIdentity,
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modifiedAt: resourceValues.contentModificationDate ?? Date(),
            captureDate: Self.captureDate(exif: exif),
            cameraMake: tiff?[kCGImagePropertyTIFFMake] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            format: format,
            gpsCoordinate: Self.coordinate(from: gpsDictionary)
        )
    }

    public func renderThumbnail(for fileURL: URL, maxPixelSize: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard
            let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw DecoderError.thumbnailGenerationFailed(fileURL.path(percentEncoded: false))
        }
        return thumbnail
    }

    private static func captureDate(exif: [CFString: Any]?) -> Date? {
        guard let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateString)
    }

    private static func coordinate(from gpsDictionary: [CFString: Any]?) -> GPSCoordinate? {
        guard
            let gpsDictionary,
            let latitude = gpsDictionary[kCGImagePropertyGPSLatitude] as? Double,
            let longitude = gpsDictionary[kCGImagePropertyGPSLongitude] as? Double
        else {
            return nil
        }

        let latRef = (gpsDictionary[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let lonRef = (gpsDictionary[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
        let correctedLatitude = latRef == "S" ? -latitude : latitude
        let correctedLongitude = lonRef == "W" ? -longitude : longitude
        let altitude = gpsDictionary[kCGImagePropertyGPSAltitude] as? Double
        return GPSCoordinate(latitude: correctedLatitude, longitude: correctedLongitude, altitude: altitude)
    }
}

public enum DecoderError: Error, LocalizedError {
    case unsupportedFile(String)
    case thumbnailGenerationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFile(path):
            "Unsupported or unreadable image at \(path)"
        case let .thumbnailGenerationFailed(path):
            "Could not build thumbnail for \(path)"
        }
    }
}
