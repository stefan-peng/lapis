import Foundation

public struct GPXPoint: Sendable, Hashable {
    public var timestamp: Date
    public var coordinate: GPSCoordinate

    public init(timestamp: Date, coordinate: GPSCoordinate) {
        self.timestamp = timestamp
        self.coordinate = coordinate
    }
}

public struct GPXTrack: Sendable, Hashable {
    public var points: [GPXPoint]

    public init(points: [GPXPoint]) {
        self.points = points.sorted(by: { $0.timestamp < $1.timestamp })
    }
}

public struct GeotagMatch: Sendable, Hashable {
    public var assetID: UUID
    public var sourceTimestamp: Date
    public var coordinate: GPSCoordinate?

    public init(assetID: UUID, sourceTimestamp: Date, coordinate: GPSCoordinate?) {
        self.assetID = assetID
        self.sourceTimestamp = sourceTimestamp
        self.coordinate = coordinate
    }
}

public protocol GeotagMatcher: Sendable {
    func match(
        assets: [Asset],
        track: GPXTrack,
        timezoneOffsetMinutes: Int,
        cameraClockOffsetSeconds: Int
    ) -> [GeotagMatch]
}

public protocol GPXParsing: Sendable {
    func parse(data: Data) throws -> GPXTrack
}

public struct TimestampGeotagMatcher: GeotagMatcher {
    public init() {}

    public func match(
        assets: [Asset],
        track: GPXTrack,
        timezoneOffsetMinutes: Int,
        cameraClockOffsetSeconds: Int
    ) -> [GeotagMatch] {
        guard !track.points.isEmpty else { return [] }

        return assets.compactMap { asset in
            guard let captureDate = asset.captureDate else { return nil }
            let adjustedCapture = captureDate
                .addingTimeInterval(TimeInterval(timezoneOffsetMinutes * 60))
                .addingTimeInterval(TimeInterval(cameraClockOffsetSeconds))

            let nearest = track.points.min { lhs, rhs in
                abs(lhs.timestamp.timeIntervalSince(adjustedCapture)) < abs(rhs.timestamp.timeIntervalSince(adjustedCapture))
            }
            return GeotagMatch(assetID: asset.id, sourceTimestamp: captureDate, coordinate: nearest?.coordinate)
        }
    }
}

public final class GPXParser: NSObject, GPXParsing, XMLParserDelegate, @unchecked Sendable {
    private var parsedPoints: [GPXPoint] = []
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentElevation: Double?
    private var currentElement = ""
    private var currentTimeString = ""
    private var currentElevationString = ""

    public override init() {}

    public func parse(data: Data) throws -> GPXTrack {
        parsedPoints = []
        currentLatitude = nil
        currentLongitude = nil
        currentElevation = nil
        currentElement = ""
        currentTimeString = ""
        currentElevationString = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw GPXError.parseFailed(parser.parserError?.localizedDescription ?? "Unknown GPX parse error")
        }
        return GPXTrack(points: parsedPoints)
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "trkpt" {
            currentLatitude = attributeDict["lat"].flatMap(Double.init)
            currentLongitude = attributeDict["lon"].flatMap(Double.init)
            currentElevation = nil
            currentTimeString = ""
            currentElevationString = ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "time":
            currentTimeString += string
        case "ele":
            currentElevationString += string
        default:
            break
        }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "ele" {
            currentElevation = Double(currentElevationString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if elementName == "trkpt" {
            let formatter = ISO8601DateFormatter()
            if
                let latitude = currentLatitude,
                let longitude = currentLongitude,
                let timestamp = formatter.date(from: currentTimeString.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                parsedPoints.append(
                    GPXPoint(
                        timestamp: timestamp,
                        coordinate: GPSCoordinate(latitude: latitude, longitude: longitude, altitude: currentElevation)
                    )
                )
            }
        }
        currentElement = ""
    }
}

public enum GPXError: Error, LocalizedError {
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .parseFailed(message):
            "GPX parse failed: \(message)"
        }
    }
}
