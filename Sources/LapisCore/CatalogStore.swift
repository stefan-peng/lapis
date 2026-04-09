import Foundation

public protocol CatalogStore: Sendable {
    func importAsset(_ importedAsset: ImportedAsset) throws -> AssetImportDisposition
    func fetchAssets(filter: AssetFilter) throws -> [Asset]
    func fetchAsset(id: UUID) throws -> Asset?
    func fetchAlbums() throws -> [Album]
    func createAlbum(named name: String) throws -> Album
    func assignAssets(_ assetIDs: [UUID], to albumID: UUID) throws
    func updateMetadata(
        assetID: UUID,
        rating: Int?,
        flag: AssetFlag?,
        keywords: [String]?,
        gpsCoordinate: GPSCoordinate?
    ) throws
    func saveEdit(
        assetID: UUID,
        settings: DevelopSettings,
        previewPath: String?,
        status: PreviewStatus
    ) throws
    func saveDevelopSettings(assetID: UUID, settings: DevelopSettings) throws
    func updatePreview(assetID: UUID, previewPath: String?, status: PreviewStatus) throws
    func geotagAssets(_ matches: [GeotagMatch]) throws -> Int
}

public enum AssetImportDisposition: Sendable {
    case imported(Asset)
    case duplicate(Asset)
}

public protocol FolderImporting: Sendable {
    func importFolders(_ folderURLs: [URL]) throws -> ImportJob
}

public struct GPXApplicationResult: Sendable {
    public var appliedCount: Int
    public var candidateCount: Int

    public init(appliedCount: Int, candidateCount: Int) {
        self.appliedCount = appliedCount
        self.candidateCount = candidateCount
    }
}

public protocol GPXApplying: Sendable {
    func applyGPX(
        data: Data,
        to assets: [Asset],
        timezoneOffsetMinutes: Int,
        cameraClockOffsetSeconds: Int
    ) throws -> GPXApplicationResult
}

public struct AssetEditRequest: Sendable {
    public var assetID: UUID
    public var sourcePath: String
    public var settings: DevelopSettings
    public var previewIdentifier: String
    public var previewMaxPixelSize: Int?

    public init(
        assetID: UUID,
        sourcePath: String,
        settings: DevelopSettings,
        previewIdentifier: String,
        previewMaxPixelSize: Int? = 2048
    ) {
        self.assetID = assetID
        self.sourcePath = sourcePath
        self.settings = settings
        self.previewIdentifier = previewIdentifier
        self.previewMaxPixelSize = previewMaxPixelSize
    }
}

public struct AssetEditResult: Sendable {
    public var settings: DevelopSettings
    public var previewPath: String?
    public var previewStatus: PreviewStatus

    public init(settings: DevelopSettings, previewPath: String?, previewStatus: PreviewStatus) {
        self.settings = settings
        self.previewPath = previewPath
        self.previewStatus = previewStatus
    }
}

public protocol AssetEditing: Sendable {
    func commit(_ request: AssetEditRequest) throws -> AssetEditResult
}

public final class FolderImportService: FolderImporting, @unchecked Sendable {
    private let importer: AssetImporter
    private let catalogStore: any CatalogStore

    public init(importer: AssetImporter, catalogStore: any CatalogStore) {
        self.importer = importer
        self.catalogStore = catalogStore
    }

    public func importFolders(_ folderURLs: [URL]) throws -> ImportJob {
        var totals = ImportJob()
        for folderURL in folderURLs {
            let job = try importer.importFolder(folderURL, into: catalogStore)
            totals.importedCount += job.importedCount
            totals.duplicateCount += job.duplicateCount
            totals.skippedCount += job.skippedCount
            totals.failures.append(contentsOf: job.failures)
        }
        return totals
    }
}

public final class GPXApplicationService: GPXApplying, @unchecked Sendable {
    private let catalogStore: any CatalogStore
    private let parser: any GPXParsing
    private let matcher: any GeotagMatcher

    public init(catalogStore: any CatalogStore, parser: any GPXParsing, matcher: any GeotagMatcher) {
        self.catalogStore = catalogStore
        self.parser = parser
        self.matcher = matcher
    }

    public func applyGPX(
        data: Data,
        to assets: [Asset],
        timezoneOffsetMinutes: Int,
        cameraClockOffsetSeconds: Int
    ) throws -> GPXApplicationResult {
        let track = try parser.parse(data: data)
        let matches = matcher.match(
            assets: assets,
            track: track,
            timezoneOffsetMinutes: timezoneOffsetMinutes,
            cameraClockOffsetSeconds: cameraClockOffsetSeconds
        )
        let appliedCount = try catalogStore.geotagAssets(matches)
        return GPXApplicationResult(appliedCount: appliedCount, candidateCount: assets.count)
    }
}

public final class AssetEditingService: AssetEditing, @unchecked Sendable {
    private let catalogStore: any CatalogStore
    private let renderer: any DevelopRenderer
    private let previewCache: any PreviewCaching

    public init(
        catalogStore: any CatalogStore,
        renderer: any DevelopRenderer,
        previewCache: any PreviewCaching
    ) {
        self.catalogStore = catalogStore
        self.renderer = renderer
        self.previewCache = previewCache
    }

    public func commit(_ request: AssetEditRequest) throws -> AssetEditResult {
        let rendered = try renderer.renderImage(
            from: URL(fileURLWithPath: request.sourcePath),
            settings: request.settings,
            maxPixelSize: request.previewMaxPixelSize
        )
        let previewURL = try previewCache.cachePreview(named: request.previewIdentifier, image: rendered)
        let previewPath = previewURL.path(percentEncoded: false)
        try catalogStore.saveEdit(
            assetID: request.assetID,
            settings: request.settings,
            previewPath: previewPath,
            status: .ready
        )
        return AssetEditResult(settings: request.settings, previewPath: previewPath, previewStatus: .ready)
    }
}
