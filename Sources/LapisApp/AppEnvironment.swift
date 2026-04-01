import Foundation
import LapisCore

struct AppEnvironment {
    let catalogStore: GRDBCatalogStore
    let importer: AssetImporter
    let geotagMatcher: TimestampGeotagMatcher
    let gpxParser: GPXParser
    let renderer: CoreImageDevelopRenderer
    let previewService: PreviewService
    let exportService: ExportService
    let writebackService: MetadataWritebackService

    static func live() throws -> AppEnvironment {
        let baseURL = try applicationSupportDirectory()
        let catalogURL = baseURL.appending(path: "Catalog.sqlite")
        let previewURL = baseURL.appending(path: "Previews", directoryHint: .isDirectory)

        let store = try GRDBCatalogStore(databaseURL: catalogURL)
        let previewService = try PreviewService(directoryURL: previewURL)
        let renderer = CoreImageDevelopRenderer()

        return AppEnvironment(
            catalogStore: store,
            importer: AssetImporter(decoder: AppleRawDecoder(), previewService: previewService),
            geotagMatcher: TimestampGeotagMatcher(),
            gpxParser: GPXParser(),
            renderer: renderer,
            previewService: previewService,
            exportService: ExportService(renderer: renderer),
            writebackService: MetadataWritebackService()
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
