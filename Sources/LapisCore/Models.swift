import Foundation

public enum AssetFormat: String, Codable, CaseIterable, Sendable {
    case cr2
    case cr3
    case dng
    case jpeg
    case tiff
    case png
    case heic

    public static func from(fileExtension: String) -> AssetFormat? {
        switch fileExtension.lowercased() {
        case "cr2": .cr2
        case "cr3": .cr3
        case "dng": .dng
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        case "png": .png
        case "heic", "heif": .heic
        default: nil
        }
    }
}

public enum AssetFlag: String, Codable, CaseIterable, Sendable {
    case none
    case picked
    case rejected
}

public enum PreviewStatus: String, Codable, CaseIterable, Sendable {
    case missing
    case ready
    case failed
}

public enum CatalogWritebackPolicy: String, Codable, Sendable {
    case catalogFirst
}

public struct GPSCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct CropRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let fullFrame = CropRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ToneCurve: Codable, Hashable, Sendable {
    public var inputPoint0: Double
    public var inputPoint1: Double
    public var inputPoint2: Double
    public var inputPoint3: Double
    public var inputPoint4: Double

    public static let linear = ToneCurve(inputPoint0: 0, inputPoint1: 0.25, inputPoint2: 0.5, inputPoint3: 0.75, inputPoint4: 1)

    public init(
        inputPoint0: Double,
        inputPoint1: Double,
        inputPoint2: Double,
        inputPoint3: Double,
        inputPoint4: Double
    ) {
        self.inputPoint0 = inputPoint0
        self.inputPoint1 = inputPoint1
        self.inputPoint2 = inputPoint2
        self.inputPoint3 = inputPoint3
        self.inputPoint4 = inputPoint4
    }
}

public struct DevelopSettings: Codable, Hashable, Sendable {
    public static let latestSchemaVersion = 2

    public var temperature: Double
    public var tint: Double
    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var vibrance: Double
    public var saturation: Double
    public var straightenAngle: Double
    public var cropRect: CropRect
    public var toneCurve: ToneCurve
    public var lensCorrectionAmount: Double
    public var vignetteCorrectionAmount: Double
    public var sharpenAmount: Double
    public var luminanceNoiseReductionAmount: Double
    public var chrominanceNoiseReductionAmount: Double

    public static let `default` = DevelopSettings(
        temperature: 6500,
        tint: 0,
        exposure: 0,
        contrast: 1,
        highlights: 0,
        shadows: 0,
        whites: 0,
        blacks: 0,
        vibrance: 0,
        saturation: 1,
        straightenAngle: 0,
        cropRect: .fullFrame,
        toneCurve: .linear,
        lensCorrectionAmount: 0,
        vignetteCorrectionAmount: 0,
        sharpenAmount: 0.4,
        luminanceNoiseReductionAmount: 0,
        chrominanceNoiseReductionAmount: 0.05
    )

    public init(
        temperature: Double,
        tint: Double,
        exposure: Double,
        contrast: Double,
        highlights: Double,
        shadows: Double,
        whites: Double,
        blacks: Double,
        vibrance: Double,
        saturation: Double,
        straightenAngle: Double,
        cropRect: CropRect,
        toneCurve: ToneCurve,
        lensCorrectionAmount: Double,
        vignetteCorrectionAmount: Double,
        sharpenAmount: Double,
        luminanceNoiseReductionAmount: Double,
        chrominanceNoiseReductionAmount: Double
    ) {
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.vibrance = vibrance
        self.saturation = saturation
        self.straightenAngle = straightenAngle
        self.cropRect = cropRect
        self.toneCurve = toneCurve
        self.lensCorrectionAmount = lensCorrectionAmount
        self.vignetteCorrectionAmount = vignetteCorrectionAmount
        self.sharpenAmount = sharpenAmount
        self.luminanceNoiseReductionAmount = luminanceNoiseReductionAmount
        self.chrominanceNoiseReductionAmount = chrominanceNoiseReductionAmount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case temperature
        case tint
        case exposure
        case contrast
        case highlights
        case shadows
        case whites
        case blacks
        case vibrance
        case saturation
        case straightenAngle
        case cropRect
        case toneCurve
        case lensCorrectionAmount
        case vignetteCorrectionAmount
        case sharpenAmount
        case luminanceNoiseReductionAmount
        case chrominanceNoiseReductionAmount
        case noiseReductionAmount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0

        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? Self.default.temperature
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? Self.default.tint
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? Self.default.exposure
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? Self.default.contrast
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? Self.default.highlights
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? Self.default.shadows
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? Self.default.whites
        blacks = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? Self.default.blacks
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? Self.default.vibrance
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? Self.default.saturation
        straightenAngle = try container.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? Self.default.straightenAngle
        cropRect = try container.decodeIfPresent(CropRect.self, forKey: .cropRect) ?? Self.default.cropRect
        toneCurve = try container.decodeIfPresent(ToneCurve.self, forKey: .toneCurve) ?? Self.default.toneCurve
        lensCorrectionAmount = try container.decodeIfPresent(Double.self, forKey: .lensCorrectionAmount) ?? Self.default.lensCorrectionAmount
        vignetteCorrectionAmount = try container.decodeIfPresent(Double.self, forKey: .vignetteCorrectionAmount) ?? Self.default.vignetteCorrectionAmount
        sharpenAmount = try container.decodeIfPresent(Double.self, forKey: .sharpenAmount) ?? Self.default.sharpenAmount

        let legacyNoiseReductionAmount = try container.decodeIfPresent(Double.self, forKey: .noiseReductionAmount)
        luminanceNoiseReductionAmount = try container.decodeIfPresent(Double.self, forKey: .luminanceNoiseReductionAmount)
            ?? legacyNoiseReductionAmount
            ?? Self.default.luminanceNoiseReductionAmount
        chrominanceNoiseReductionAmount = try container.decodeIfPresent(Double.self, forKey: .chrominanceNoiseReductionAmount)
            ?? min(max((legacyNoiseReductionAmount ?? Self.default.chrominanceNoiseReductionAmount) * 0.5, 0), 1)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.latestSchemaVersion, forKey: .schemaVersion)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(straightenAngle, forKey: .straightenAngle)
        try container.encode(cropRect, forKey: .cropRect)
        try container.encode(toneCurve, forKey: .toneCurve)
        try container.encode(lensCorrectionAmount, forKey: .lensCorrectionAmount)
        try container.encode(vignetteCorrectionAmount, forKey: .vignetteCorrectionAmount)
        try container.encode(sharpenAmount, forKey: .sharpenAmount)
        try container.encode(luminanceNoiseReductionAmount, forKey: .luminanceNoiseReductionAmount)
        try container.encode(chrominanceNoiseReductionAmount, forKey: .chrominanceNoiseReductionAmount)
    }
}

public struct Asset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourcePath: String
    public var fileIdentity: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var importedAt: Date
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var format: AssetFormat
    public var gpsCoordinate: GPSCoordinate?
    public var previewStatus: PreviewStatus
    public var previewPath: String?
    public var rating: Int
    public var flag: AssetFlag
    public var keywords: [String]
    public var albumIDs: [UUID]
    public var developSettings: DevelopSettings

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        fileIdentity: String,
        fileSize: Int64,
        modifiedAt: Date,
        importedAt: Date = Date(),
        captureDate: Date?,
        cameraMake: String?,
        cameraModel: String?,
        lensModel: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        format: AssetFormat,
        gpsCoordinate: GPSCoordinate?,
        previewStatus: PreviewStatus = .missing,
        previewPath: String? = nil,
        rating: Int = 0,
        flag: AssetFlag = .none,
        keywords: [String] = [],
        albumIDs: [UUID] = [],
        developSettings: DevelopSettings = .default
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.fileIdentity = fileIdentity
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.importedAt = importedAt
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.format = format
        self.gpsCoordinate = gpsCoordinate
        self.previewStatus = previewStatus
        self.previewPath = previewPath
        self.rating = rating
        self.flag = flag
        self.keywords = keywords
        self.albumIDs = albumIDs
        self.developSettings = developSettings
    }
}

public struct Album: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct AssetFilter: Sendable {
    public var searchText: String
    public var minimumRating: Int?
    public var flaggedOnly: Bool
    public var keyword: String?
    public var cameraContains: String?
    public var lensContains: String?
    public var geotaggedOnly: Bool
    public var capturedAfter: Date?
    public var capturedBefore: Date?
    public var locationLatitude: Double?
    public var locationLongitude: Double?
    public var locationRadiusKilometers: Double?
    public var albumID: UUID?

    public static let `default` = AssetFilter(
        searchText: "",
        minimumRating: nil,
        flaggedOnly: false,
        keyword: nil,
        cameraContains: nil,
        lensContains: nil,
        geotaggedOnly: false,
        capturedAfter: nil,
        capturedBefore: nil,
        locationLatitude: nil,
        locationLongitude: nil,
        locationRadiusKilometers: nil,
        albumID: nil
    )

    public init(
        searchText: String = "",
        minimumRating: Int? = nil,
        flaggedOnly: Bool = false,
        keyword: String? = nil,
        cameraContains: String? = nil,
        lensContains: String? = nil,
        geotaggedOnly: Bool = false,
        capturedAfter: Date? = nil,
        capturedBefore: Date? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        locationRadiusKilometers: Double? = nil,
        albumID: UUID? = nil
    ) {
        self.searchText = searchText
        self.minimumRating = minimumRating
        self.flaggedOnly = flaggedOnly
        self.keyword = keyword
        self.cameraContains = cameraContains
        self.lensContains = lensContains
        self.geotaggedOnly = geotaggedOnly
        self.capturedAfter = capturedAfter
        self.capturedBefore = capturedBefore
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.locationRadiusKilometers = locationRadiusKilometers
        self.albumID = albumID
    }
}

public struct ImportJob: Codable, Sendable {
    public var importedCount: Int
    public var duplicateCount: Int
    public var skippedCount: Int
    public var failures: [String]

    public init(importedCount: Int = 0, duplicateCount: Int = 0, skippedCount: Int = 0, failures: [String] = []) {
        self.importedCount = importedCount
        self.duplicateCount = duplicateCount
        self.skippedCount = skippedCount
        self.failures = failures
    }
}

public struct PreviewJob: Codable, Sendable {
    public var assetID: UUID
    public var previewPath: String
    public var generatedAt: Date

    public init(assetID: UUID, previewPath: String, generatedAt: Date = Date()) {
        self.assetID = assetID
        self.previewPath = previewPath
        self.generatedAt = generatedAt
    }
}

public struct ExportPreset: Identifiable, Codable, Hashable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg
        case tiff
    }

    public enum ColorSpace: String, Codable, CaseIterable, Sendable {
        case sRGB
        case displayP3
        case adobeRGB
    }

    public var id: UUID
    public var name: String
    public var format: Format
    public var colorSpace: ColorSpace
    public var quality: Double
    public var maxPixelSize: Int?
    public var outputSharpening: Double
    public var fileNameTemplate: String

    public init(
        id: UUID = UUID(),
        name: String,
        format: Format,
        colorSpace: ColorSpace,
        quality: Double,
        maxPixelSize: Int?,
        outputSharpening: Double,
        fileNameTemplate: String
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.colorSpace = colorSpace
        self.quality = quality
        self.maxPixelSize = maxPixelSize
        self.outputSharpening = outputSharpening
        self.fileNameTemplate = fileNameTemplate
    }
}

public struct ExportJob: Codable, Sendable {
    public var preset: ExportPreset
    public var assetIDs: [UUID]
    public var destinationDirectory: String
    public var createdAt: Date

    public init(preset: ExportPreset, assetIDs: [UUID], destinationDirectory: String, createdAt: Date = Date()) {
        self.preset = preset
        self.assetIDs = assetIDs
        self.destinationDirectory = destinationDirectory
        self.createdAt = createdAt
    }
}

public struct ExportFailure: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var sourcePath: String
    public var message: String

    public init(assetID: UUID, sourcePath: String, message: String) {
        self.assetID = assetID
        self.sourcePath = sourcePath
        self.message = message
    }
}

public struct ExportReport: Codable, Hashable, Sendable {
    public var exportedURLs: [URL]
    public var failures: [ExportFailure]

    public init(exportedURLs: [URL] = [], failures: [ExportFailure] = []) {
        self.exportedURLs = exportedURLs
        self.failures = failures
    }
}

public struct GeotagJob: Codable, Sendable {
    public var trackFilePath: String
    public var timezoneOffsetMinutes: Int
    public var cameraClockOffsetSeconds: Int
    public var appliedCount: Int
    public var skippedCount: Int

    public init(
        trackFilePath: String,
        timezoneOffsetMinutes: Int,
        cameraClockOffsetSeconds: Int,
        appliedCount: Int = 0,
        skippedCount: Int = 0
    ) {
        self.trackFilePath = trackFilePath
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.cameraClockOffsetSeconds = cameraClockOffsetSeconds
        self.appliedCount = appliedCount
        self.skippedCount = skippedCount
    }
}

public struct ImportedAsset: Sendable {
    public var sourceURL: URL
    public var fileIdentity: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var format: AssetFormat
    public var gpsCoordinate: GPSCoordinate?
    public var previewPath: String?

    public init(
        sourceURL: URL,
        fileIdentity: String,
        fileSize: Int64,
        modifiedAt: Date,
        captureDate: Date?,
        cameraMake: String?,
        cameraModel: String?,
        lensModel: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        format: AssetFormat,
        gpsCoordinate: GPSCoordinate?,
        previewPath: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.fileIdentity = fileIdentity
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.format = format
        self.gpsCoordinate = gpsCoordinate
        self.previewPath = previewPath
    }
}

public enum LibrarySelectionIntent: Sendable {
    case replace(UUID)
    case toggle(UUID)
    case extendRange(UUID)
    case clear
}

public struct LibrarySelectionState: Equatable, Sendable {
    public var selectedAssetIDs: Set<UUID>
    public var anchorAssetID: UUID?

    public init(selectedAssetIDs: Set<UUID> = [], anchorAssetID: UUID? = nil) {
        self.selectedAssetIDs = selectedAssetIDs
        self.anchorAssetID = anchorAssetID
    }

    public func applying(_ intent: LibrarySelectionIntent, orderedAssetIDs: [UUID]) -> LibrarySelectionState {
        switch intent {
        case let .replace(assetID):
            return LibrarySelectionState(selectedAssetIDs: [assetID], anchorAssetID: assetID)
        case let .toggle(assetID):
            var nextSelection = selectedAssetIDs
            if nextSelection.contains(assetID) {
                nextSelection.remove(assetID)
            } else {
                nextSelection.insert(assetID)
            }
            return LibrarySelectionState(
                selectedAssetIDs: nextSelection,
                anchorAssetID: Self.normalizedAnchor(assetID, within: nextSelection)
            )
        case let .extendRange(assetID):
            guard
                let anchorAssetID,
                let anchorIndex = orderedAssetIDs.firstIndex(of: anchorAssetID),
                let targetIndex = orderedAssetIDs.firstIndex(of: assetID)
            else {
                return LibrarySelectionState(selectedAssetIDs: [assetID], anchorAssetID: assetID)
            }

            let lowerBound = min(anchorIndex, targetIndex)
            let upperBound = max(anchorIndex, targetIndex)
            let rangeIDs = Set(orderedAssetIDs[lowerBound...upperBound])
            return LibrarySelectionState(selectedAssetIDs: rangeIDs, anchorAssetID: anchorAssetID)
        case .clear:
            return LibrarySelectionState()
        }
    }

    private static func normalizedAnchor(_ preferredAnchor: UUID?, within selection: Set<UUID>) -> UUID? {
        preferredAnchor.flatMap { selection.contains($0) ? $0 : selection.first }
    }
}
