import Foundation
import LapisCore

struct AppEnvironment {
    let catalogStore: any CatalogStore
    let importer: any FolderImporting
    let gpxService: any GPXApplying
    let developProcessor: any DevelopProcessing
    let assetEditor: any AssetEditing
    let exportService: any AssetExporting
    let metadataWriter: any MetadataWriting

    static func live() throws -> AppEnvironment {
        let baseURL = try applicationSupportDirectory()
        let catalogURL = baseURL.appending(path: "Catalog.sqlite")
        let previewURL = baseURL.appending(path: "Previews", directoryHint: .isDirectory)

        let store = try GRDBCatalogStore(databaseURL: catalogURL)
        let previewService = try PreviewService(directoryURL: previewURL)
        let renderer = CoreImageDevelopRenderer()
        let rawImporter = AssetImporter(decoder: AppleRawDecoder(), previewService: previewService)

        return AppEnvironment(
            catalogStore: store,
            importer: FolderImportService(importer: rawImporter, catalogStore: store),
            gpxService: GPXApplicationService(
                catalogStore: store,
                parser: GPXParser(),
                matcher: TimestampGeotagMatcher()
            ),
            developProcessor: renderer,
            assetEditor: AssetEditingService(catalogStore: store, renderer: renderer, previewCache: previewService),
            exportService: ExportService(renderer: renderer),
            metadataWriter: MetadataWritebackService()
        )
    }

    private static func applicationSupportDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let lapisURL = baseURL.appending(path: "Lapis", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lapisURL, withIntermediateDirectories: true)
        return lapisURL
    }
}
