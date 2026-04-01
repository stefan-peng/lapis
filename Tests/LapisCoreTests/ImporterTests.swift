import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import LapisCore

@Test func timestampGeotagMatcherUsesNearestPointAfterOffsets() throws {
    let asset = Asset(
        sourcePath: "/tmp/photo.cr3",
        fileIdentity: "asset-1",
        fileSize: 1,
        modifiedAt: .now,
        captureDate: Date(timeIntervalSince1970: 1_000),
        cameraMake: nil,
        cameraModel: nil,
        lensModel: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        format: .cr3,
        gpsCoordinate: nil
    )

    let track = GPXTrack(points: [
        GPXPoint(timestamp: Date(timeIntervalSince1970: 940), coordinate: GPSCoordinate(latitude: 10, longitude: 20)),
        GPXPoint(timestamp: Date(timeIntervalSince1970: 1_020), coordinate: GPSCoordinate(latitude: 30, longitude: 40)),
    ])

    let matches = TimestampGeotagMatcher().match(
        assets: [asset],
        track: track,
        timezoneOffsetMinutes: 0,
        cameraClockOffsetSeconds: 10
    )

    #expect(matches.count == 1)
    #expect(matches.first?.coordinate == GPSCoordinate(latitude: 30, longitude: 40))
}

@Test func gpxParserParsesTrackPoints() throws {
    let xml = """
    <gpx>
      <trk><trkseg>
        <trkpt lat="1.0" lon="2.0"><ele>10</ele><time>2024-01-01T00:00:00Z</time></trkpt>
        <trkpt lat="3.0" lon="4.0"><time>2024-01-01T01:00:00Z</time></trkpt>
      </trkseg></trk>
    </gpx>
    """

    let track = try GPXParser().parse(data: Data(xml.utf8))
    #expect(track.points.count == 2)
    #expect(track.points.first?.coordinate == GPSCoordinate(latitude: 1, longitude: 2, altitude: 10))
}

@Test func catalogStoreAvoidsDuplicatePaths() throws {
    let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("sqlite")
    let store = try GRDBCatalogStore(databaseURL: tempURL)

    let imported = ImportedAsset(
        sourceURL: URL(fileURLWithPath: "/tmp/test.cr2"),
        fileIdentity: "same-file",
        fileSize: 10,
        modifiedAt: .now,
        captureDate: .now,
        cameraMake: "Canon",
        cameraModel: "R6",
        lensModel: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        format: .cr2,
        gpsCoordinate: nil
    )

    let first = try store.importAsset(imported)
    let second = try store.importAsset(imported)

    if case .imported = first {} else {
        Issue.record("First import should insert the asset")
    }
    if case .duplicate = second {} else {
        Issue.record("Second import should be treated as duplicate")
    }
}

@Test func assetImporterRecognizesJpgAndSkipsUnsupportedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let supported = root.appending(path: "photo.jpg")
    let unsupported = root.appending(path: "notes.txt")
    FileManager.default.createFile(atPath: supported.path(percentEncoded: false), contents: Data())
    FileManager.default.createFile(atPath: unsupported.path(percentEncoded: false), contents: Data())

    let previewURL = root.appending(path: "previews", directoryHint: .isDirectory)
    let previewService = try PreviewService(directoryURL: previewURL)
    let decoder = MockDecoder(results: [
        "photo.jpg": ImportedAsset(
            sourceURL: supported,
            fileIdentity: "photo-jpg",
            fileSize: 10,
            modifiedAt: .now,
            captureDate: .now,
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            pixelWidth: 100,
            pixelHeight: 50,
            format: .jpeg,
            gpsCoordinate: nil
        )
    ])
    let store = MockCatalogStore()
    let importer = AssetImporter(decoder: decoder, previewService: previewService)

    let job = try importer.importFolder(root, into: store)

    #expect(job.importedCount == 1)
    #expect(job.skippedCount == 1)
    #expect(store.importedAssets.count == 1)
}

@Test func exportServiceUsesRequestedColorSpace() throws {
    let renderer = MockRenderer()
    let service = ExportService(renderer: renderer)
    let image = try #require(makeSolidImage())
    let preset = ExportPreset(
        name: "Adobe Export",
        format: .jpeg,
        colorSpace: .adobeRGB,
        quality: 0.9,
        maxPixelSize: nil,
        outputSharpening: 0,
        fileNameTemplate: "{name}"
    )

    let processed = try service.postProcess(image: image, preset: preset)

    #expect(processed.colorSpace?.name as String? == ExportService.colorSpace(for: .adobeRGB).name as String?)
}

private struct MockDecoder: RawDecoder {
    let results: [String: ImportedAsset]

    func metadata(for fileURL: URL) throws -> ImportedAsset {
        guard let imported = results[fileURL.lastPathComponent] else {
            throw DecoderError.unsupportedFile(fileURL.lastPathComponent)
        }
        return imported
    }

    func renderThumbnail(for fileURL: URL, maxPixelSize: Int) throws -> CGImage {
        throw DecoderError.thumbnailGenerationFailed(fileURL.lastPathComponent)
    }
}

private struct MockRenderer: DevelopRenderer {
    func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage {
        try #require(makeSolidImage())
    }
}

private func makeSolidImage() -> CGImage? {
    let ciImage = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75))
        .cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
    let context = CIContext()
    return context.createCGImage(ciImage, from: ciImage.extent)
}

private final class MockCatalogStore: CatalogStore, @unchecked Sendable {
    private(set) var importedAssets: [ImportedAsset] = []

    func importAsset(_ importedAsset: ImportedAsset) throws -> AssetImportDisposition {
        importedAssets.append(importedAsset)
        return .imported(
            Asset(
                sourcePath: importedAsset.sourceURL.path(percentEncoded: false),
                fileIdentity: importedAsset.fileIdentity,
                fileSize: importedAsset.fileSize,
                modifiedAt: importedAsset.modifiedAt,
                captureDate: importedAsset.captureDate,
                cameraMake: importedAsset.cameraMake,
                cameraModel: importedAsset.cameraModel,
                lensModel: importedAsset.lensModel,
                pixelWidth: importedAsset.pixelWidth,
                pixelHeight: importedAsset.pixelHeight,
                format: importedAsset.format,
                gpsCoordinate: importedAsset.gpsCoordinate,
                previewStatus: importedAsset.previewPath == nil ? .missing : .ready,
                previewPath: importedAsset.previewPath
            )
        )
    }

    func fetchAssets(filter: AssetFilter) throws -> [Asset] { [] }
    func fetchAsset(id: UUID) throws -> Asset? { nil }
    func fetchAlbums() throws -> [Album] { [] }
    func createAlbum(named name: String) throws -> Album { Album(name: name) }
    func assignAssets(_ assetIDs: [UUID], to albumID: UUID) throws {}
    func updateMetadata(assetID: UUID, rating: Int?, flag: AssetFlag?, keywords: [String]?, gpsCoordinate: GPSCoordinate?) throws {}
    func saveDevelopSettings(assetID: UUID, settings: DevelopSettings) throws {}
    func geotagAssets(_ matches: [GeotagMatch]) throws -> Int { matches.count }
}
