import Foundation
import ImageIO

public final class MetadataWritebackService: @unchecked Sendable {
    public init() {}

    public func writeXMPSidecar(for asset: Asset) throws -> URL {
        let sourceURL = URL(fileURLWithPath: asset.sourcePath)
        let sidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("xmp")
        let data = try xmpData(for: asset)
        try data.write(to: sidecarURL, options: .atomic)
        return sidecarURL
    }

    public func embeddedMetadata(for asset: Asset) throws -> CGImageMetadata? {
        let xmpData = try xmpData(for: asset)
        let metadata = CGImageMetadataCreateFromXMPData(xmpData as CFData)
            .flatMap(CGImageMetadataCreateMutableCopy)
            ?? CGImageMetadataCreateMutable()
        let properties = imageProperties(for: asset)

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for (key, value) in tiff {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, key, value as CFTypeRef)
            }
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for (key, value) in exif {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, key, value as CFTypeRef)
            }
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            for (key, value) in gps {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, key, value as CFTypeRef)
            }
        }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for (key, value) in iptc {
                _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, key, value as CFTypeRef)
            }
        }
        return metadata
    }

    public func imageProperties(for asset: Asset) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]

        var tiff: [CFString: Any] = [:]
        if let cameraMake = asset.cameraMake, !cameraMake.isEmpty {
            tiff[kCGImagePropertyTIFFMake] = cameraMake
        }
        if let cameraModel = asset.cameraModel, !cameraModel.isEmpty {
            tiff[kCGImagePropertyTIFFModel] = cameraModel
        }
        if !tiff.isEmpty {
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }

        var exif: [CFString: Any] = [:]
        if let captureDate = asset.captureDate {
            exif[kCGImagePropertyExifDateTimeOriginal] = exifDateFormatter.string(from: captureDate)
        }
        if let lensModel = asset.lensModel, !lensModel.isEmpty {
            exif[kCGImagePropertyExifLensModel] = lensModel
        }
        if !exif.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exif
        }

        if !asset.keywords.isEmpty {
            properties[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCKeywords: asset.keywords,
            ]
        }

        if let gpsCoordinate = asset.gpsCoordinate {
            let latitudeComponents = coordinateComponents(for: gpsCoordinate.latitude, positiveRef: "N", negativeRef: "S")
            let longitudeComponents = coordinateComponents(for: gpsCoordinate.longitude, positiveRef: "E", negativeRef: "W")
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(gpsCoordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: latitudeComponents.ref,
                kCGImagePropertyGPSLongitude: abs(gpsCoordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: longitudeComponents.ref,
                kCGImagePropertyGPSVersion: "2.3.0.0",
            ]
            if let altitude = gpsCoordinate.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        }

        return properties
    }

    public func xmpData(for asset: Asset) throws -> Data {
        let keywordsXML = asset.keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined()
        let gpsXML: String
        if let gps = asset.gpsCoordinate {
            let latitudeComponents = coordinateComponents(for: gps.latitude, positiveRef: "N", negativeRef: "S")
            let longitudeComponents = coordinateComponents(for: gps.longitude, positiveRef: "E", negativeRef: "W")
            let altitudeRef = (gps.altitude ?? 0) < 0 ? 1 : 0
            gpsXML = """
            <exif:GPSLatitude>\(latitudeComponents.value)</exif:GPSLatitude>
            <exif:GPSLatitudeRef>\(latitudeComponents.ref)</exif:GPSLatitudeRef>
            <exif:GPSLongitude>\(longitudeComponents.value)</exif:GPSLongitude>
            <exif:GPSLongitudeRef>\(longitudeComponents.ref)</exif:GPSLongitudeRef>
            <exif:GPSVersionID>2.3.0.0</exif:GPSVersionID>
            <exif:GPSAltitude>\(abs(gps.altitude ?? 0))</exif:GPSAltitude>
            <exif:GPSAltitudeRef>\(altitudeRef)</exif:GPSAltitudeRef>
            """
        } else {
            gpsXML = ""
        }

        let captureDateXML = asset.captureDate.map { "<photoshop:DateCreated>\(iso8601Formatter.string(from: $0))</photoshop:DateCreated>" } ?? ""
        let cameraMakeXML = asset.cameraMake.map { "<tiff:Make>\(escape($0))</tiff:Make>" } ?? ""
        let cameraModelXML = asset.cameraModel.map { "<tiff:Model>\(escape($0))</tiff:Model>" } ?? ""
        let lensModelXML = asset.lensModel.map { "<aux:Lens>\(escape($0))</aux:Lens>" } ?? ""

        let document = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:exif="http://ns.adobe.com/exif/1.0/"
              xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:aux="http://ns.adobe.com/exif/1.0/aux/">
              <xmp:Rating>\(asset.rating)</xmp:Rating>
              <xmp:Label>\(asset.flag.rawValue)</xmp:Label>
              \(captureDateXML)
              \(cameraMakeXML)
              \(cameraModelXML)
              \(lensModelXML)
              \(gpsXML)
              <dc:subject>
                <rdf:Bag>\(keywordsXML)</rdf:Bag>
              </dc:subject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        guard let data = document.data(using: .utf8) else {
            throw MetadataWritebackError.invalidXMP
        }
        return data
    }

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func coordinateComponents(for coordinate: Double, positiveRef: String, negativeRef: String) -> (value: String, ref: String) {
        let absolute = abs(coordinate)
        let degrees = Int(absolute)
        let minutesFloat = (absolute - Double(degrees)) * 60
        let minutes = Int(minutesFloat)
        let seconds = (minutesFloat - Double(minutes)) * 60
        let ref = coordinate >= 0 ? positiveRef : negativeRef
        return ("\(degrees),\(minutes),\(String(format: "%.3f", seconds))", ref)
    }
}

public enum MetadataWritebackError: Error, LocalizedError {
    case invalidXMP

    public var errorDescription: String? {
        switch self {
        case .invalidXMP:
            "Could not build XMP metadata"
        }
    }
}
