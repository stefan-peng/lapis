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
    func saveDevelopSettings(assetID: UUID, settings: DevelopSettings) throws
    func updatePreview(assetID: UUID, previewPath: String?, status: PreviewStatus) throws
    func geotagAssets(_ matches: [GeotagMatch]) throws -> Int
}

public enum AssetImportDisposition: Sendable {
    case imported(Asset)
    case duplicate(Asset)
}
