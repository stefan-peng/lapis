import Foundation

public final class MetadataWritebackService: @unchecked Sendable {
    public init() {}

    public func writeXMPSidecar(for asset: Asset) throws -> URL {
        let sourceURL = URL(fileURLWithPath: asset.sourcePath)
        let sidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("xmp")

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

        let document = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:exif="http://ns.adobe.com/exif/1.0/">
              <xmp:Rating>\(asset.rating)</xmp:Rating>
              <xmp:Label>\(asset.flag.rawValue)</xmp:Label>
              \(gpsXML)
              <dc:subject>
                <rdf:Bag>\(keywordsXML)</rdf:Bag>
              </dc:subject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        try document.write(to: sidecarURL, atomically: true, encoding: .utf8)
        return sidecarURL
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
