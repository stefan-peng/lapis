import CoreGraphics
import CoreImage
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
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

@Test func librarySelectionStateAppliesReplaceToggleAndRangeSelection() {
    let ids = [UUID(), UUID(), UUID(), UUID()]

    let replaced = LibrarySelectionState()
        .applying(.replace(ids[1]), orderedAssetIDs: ids)
    #expect(replaced.selectedAssetIDs == [ids[1]])
    #expect(replaced.anchorAssetID == ids[1])

    let toggled = replaced.applying(.toggle(ids[2]), orderedAssetIDs: ids)
    #expect(toggled.selectedAssetIDs == Set([ids[1], ids[2]]))
    #expect(toggled.anchorAssetID == ids[2])

    let ranged = replaced.applying(.extendRange(ids[3]), orderedAssetIDs: ids)
    #expect(ranged.selectedAssetIDs == Set([ids[1], ids[2], ids[3]]))
    #expect(ranged.anchorAssetID == ids[1])
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

@Test func catalogStoreFiltersByDateAndLocationBounds() throws {
    let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("sqlite")
    let store = try GRDBCatalogStore(databaseURL: tempURL)

    let firstAsset = ImportedAsset(
        sourceURL: URL(fileURLWithPath: "/tmp/dated-1.dng"),
        fileIdentity: "dated-1",
        fileSize: 10,
        modifiedAt: .now,
        captureDate: Date(timeIntervalSince1970: 1_000),
        cameraMake: "Ricoh",
        cameraModel: "GR III",
        lensModel: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        format: .dng,
        gpsCoordinate: GPSCoordinate(latitude: 40.7128, longitude: -74.0060)
    )
    let secondAsset = ImportedAsset(
        sourceURL: URL(fileURLWithPath: "/tmp/dated-2.cr3"),
        fileIdentity: "dated-2",
        fileSize: 10,
        modifiedAt: .now,
        captureDate: Date(timeIntervalSince1970: 2_000),
        cameraMake: "Canon",
        cameraModel: "R6",
        lensModel: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        format: .cr3,
        gpsCoordinate: GPSCoordinate(latitude: 34.0522, longitude: -118.2437)
    )

    _ = try store.importAsset(firstAsset)
    _ = try store.importAsset(secondAsset)

    let dateFiltered = try store.fetchAssets(filter: AssetFilter(capturedAfter: Date(timeIntervalSince1970: 1_500)))
    #expect(dateFiltered.count == 1)
    #expect(dateFiltered.first?.fileIdentity == "dated-2")

    let locationFiltered = try store.fetchAssets(filter: AssetFilter(locationLatitude: 40.7128, locationLongitude: -74.0060, locationRadiusKilometers: 5))
    #expect(locationFiltered.count == 1)
    #expect(locationFiltered.first?.fileIdentity == "dated-1")
}

@Test func metadataWritebackIncludesGpsRefsAndAltitude() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let imageURL = directory.appending(path: "frame.dng")
    FileManager.default.createFile(atPath: imageURL.path(percentEncoded: false), contents: Data())

    let asset = Asset(
        sourcePath: imageURL.path(percentEncoded: false),
        fileIdentity: "gps-xmp",
        fileSize: 1,
        modifiedAt: .now,
        captureDate: .now,
        cameraMake: nil,
        cameraModel: nil,
        lensModel: nil,
        pixelWidth: 10,
        pixelHeight: 10,
        format: .dng,
        gpsCoordinate: GPSCoordinate(latitude: -33.8688, longitude: 151.2093, altitude: 27),
        keywords: ["travel"]
    )

    let sidecarURL = try MetadataWritebackService().writeXMPSidecar(for: asset)
    let contents = try String(contentsOf: sidecarURL)

    #expect(contents.contains("<exif:GPSLatitudeRef>S</exif:GPSLatitudeRef>"))
    #expect(contents.contains("<exif:GPSLongitudeRef>E</exif:GPSLongitudeRef>"))
    #expect(contents.contains("<exif:GPSAltitude>27.0</exif:GPSAltitude>"))
}

@Test func catalogStorePersistsExpandedDevelopSettings() throws {
    let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("sqlite")
    let store = try GRDBCatalogStore(databaseURL: tempURL)

    let imported = ImportedAsset(
        sourceURL: URL(fileURLWithPath: "/tmp/edited.cr3"),
        fileIdentity: "edited-asset",
        fileSize: 10,
        modifiedAt: .now,
        captureDate: .now,
        cameraMake: "Canon",
        cameraModel: "R6",
        lensModel: "24-70",
        pixelWidth: 100,
        pixelHeight: 100,
        format: .cr3,
        gpsCoordinate: nil
    )

    let disposition = try store.importAsset(imported)
    guard case let .imported(asset) = disposition else {
        Issue.record("Expected imported asset")
        return
    }

    let settings = DevelopSettings(
        temperature: 6000,
        tint: 12,
        exposure: 0.35,
        contrast: 1.15,
        highlights: -0.2,
        shadows: 0.3,
        whites: 0.1,
        blacks: -0.15,
        vibrance: 0.25,
        saturation: 1.05,
        straightenAngle: 1.5,
        cropRect: CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7),
        toneCurve: ToneCurve(inputPoint0: 0, inputPoint1: 0.2, inputPoint2: 0.45, inputPoint3: 0.78, inputPoint4: 1),
        lensCorrectionAmount: 0.8,
        vignetteCorrectionAmount: 0.3,
        sharpenAmount: 0.9,
        luminanceNoiseReductionAmount: 0.22,
        chrominanceNoiseReductionAmount: 0.41
    )

    try store.saveDevelopSettings(assetID: asset.id, settings: settings)
    let fetched = try #require(try store.fetchAsset(id: asset.id))

    #expect(fetched.developSettings.vignetteCorrectionAmount == 0.3)
    #expect(fetched.developSettings.luminanceNoiseReductionAmount == 0.22)
    #expect(fetched.developSettings.chrominanceNoiseReductionAmount == 0.41)
    #expect(fetched.developSettings.cropRect == settings.cropRect)
}

@Test func assetEditingServiceLeavesCatalogUnchangedWhenRenderFails() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appending(path: "catalog.sqlite")
    let previewsURL = directory.appending(path: "previews", directoryHint: .isDirectory)
    let store = try GRDBCatalogStore(databaseURL: databaseURL)
    let previewCache = try PreviewService(directoryURL: previewsURL)
    let imageURL = try writeTemporaryJPEG()

    let disposition = try store.importAsset(
        ImportedAsset(
            sourceURL: imageURL,
            fileIdentity: "atomic-edit",
            fileSize: 10,
            modifiedAt: .now,
            captureDate: .now,
            cameraMake: "Canon",
            cameraModel: "R6",
            lensModel: "24-70",
            pixelWidth: 100,
            pixelHeight: 100,
            format: .jpeg,
            gpsCoordinate: nil,
            previewPath: "/tmp/original-preview.jpg"
        )
    )
    guard case let .imported(asset) = disposition else {
        Issue.record("Expected imported asset")
        return
    }

    var updatedSettings = asset.developSettings
    updatedSettings.exposure = 0.75

    let service = AssetEditingService(
        catalogStore: store,
        renderer: FailingRenderer(),
        previewCache: previewCache
    )

    #expect(throws: RenderFailure.self) {
        try service.commit(
            AssetEditRequest(
                assetID: asset.id,
                sourcePath: imageURL.path(percentEncoded: false),
                settings: updatedSettings,
                previewIdentifier: asset.id.uuidString
            )
        )
    }

    let fetched = try #require(try store.fetchAsset(id: asset.id))
    #expect(fetched.developSettings == asset.developSettings)
    #expect(fetched.previewPath == "/tmp/original-preview.jpg")
    #expect(fetched.previewStatus == .ready)
}

@Test func developSettingsDecodesLegacyNoiseReductionShape() throws {
    let legacyJSON = """
    {
      "temperature": 6500,
      "tint": 0,
      "exposure": 0,
      "contrast": 1,
      "highlights": 0,
      "shadows": 0,
      "whites": 0,
      "blacks": 0,
      "vibrance": 0,
      "saturation": 1,
      "straightenAngle": 0,
      "cropRect": { "x": 0, "y": 0, "width": 1, "height": 1 },
      "toneCurve": {
        "inputPoint0": 0,
        "inputPoint1": 0.25,
        "inputPoint2": 0.5,
        "inputPoint3": 0.75,
        "inputPoint4": 1
      },
      "lensCorrectionAmount": 0,
      "sharpenAmount": 0.4,
      "noiseReductionAmount": 0.1
    }
    """

    let settings = try JSONDecoder().decode(DevelopSettings.self, from: Data(legacyJSON.utf8))

    #expect(settings.luminanceNoiseReductionAmount == 0.1)
    #expect(settings.chrominanceNoiseReductionAmount == 0.05)
    #expect(settings.vignetteCorrectionAmount == 0)
    let reencodedJSON = try String(decoding: JSONEncoder().encode(settings), as: UTF8.self)
    #expect(reencodedJSON.contains("\"schemaVersion\":2"))
}

@Test func catalogMigrationRewritesLegacyDevelopSettingsJSON() throws {
    let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("sqlite")
    let store = try GRDBCatalogStore(databaseURL: tempURL)

    let imported = ImportedAsset(
        sourceURL: URL(fileURLWithPath: "/tmp/migrate.cr3"),
        fileIdentity: "migrate-asset",
        fileSize: 10,
        modifiedAt: .now,
        captureDate: .now,
        cameraMake: nil,
        cameraModel: nil,
        lensModel: nil,
        pixelWidth: 100,
        pixelHeight: 100,
        format: .cr3,
        gpsCoordinate: nil
    )

    let disposition = try store.importAsset(imported)
    guard case let .imported(asset) = disposition else {
        Issue.record("Expected imported asset")
        return
    }

    let legacyJSON = """
    {"whites":0,"highlights":0,"shadows":0,"straightenAngle":0,"temperature":6500,"tint":0,"cropRect":{"x":0,"width":1,"y":0,"height":1},"toneCurve":{"inputPoint3":0.75,"inputPoint2":0.5,"inputPoint4":1,"inputPoint1":0.25,"inputPoint0":0},"noiseReductionAmount":0.1,"sharpenAmount":0.4,"exposure":0,"saturation":1,"contrast":1,"lensCorrectionAmount":0,"blacks":0,"vibrance":0}
    """
    let dbQueue = try GRDB.DatabaseQueue(path: tempURL.path(percentEncoded: false))
    try dbQueue.write { db in
        try db.execute(
            sql: "UPDATE assets SET develop_settings_json = ? WHERE id = ?",
            arguments: [legacyJSON, asset.id.uuidString]
        )
        try db.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
            arguments: ["migrateDevelopSettingsSchemaV2"]
        )
    }

    _ = try GRDBCatalogStore(databaseURL: tempURL)

    let migratedJSON = try dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT develop_settings_json FROM assets WHERE id = ?", arguments: [asset.id.uuidString])
    }
    let fetched = try #require(try GRDBCatalogStore(databaseURL: tempURL).fetchAsset(id: asset.id))

    #expect((migratedJSON ?? "").contains("\"schemaVersion\":2"))
    #expect(fetched.developSettings.luminanceNoiseReductionAmount == 0.1)
    #expect(fetched.developSettings.chrominanceNoiseReductionAmount == 0.05)
}

@Test func exportServiceEmbedsMetadataIntoExports() throws {
    let renderer = MockRenderer()
    let service = ExportService(renderer: renderer)
    let destinationDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    let asset = Asset(
        sourcePath: "/tmp/exported.jpg",
        fileIdentity: "exported-asset",
        fileSize: 1,
        modifiedAt: .now,
        captureDate: Date(timeIntervalSince1970: 1_700_000_000),
        cameraMake: "Fuji",
        cameraModel: "X-T5",
        lensModel: "33mm",
        pixelWidth: 10,
        pixelHeight: 10,
        format: .jpeg,
        gpsCoordinate: GPSCoordinate(latitude: 40.7128, longitude: -74.0060, altitude: 14),
        rating: 4,
        flag: .picked,
        keywords: ["city", "night"]
    )

    let preset = ExportPreset(
        name: "JPEG",
        format: .jpeg,
        colorSpace: .sRGB,
        quality: 0.85,
        maxPixelSize: nil,
        outputSharpening: 0,
        fileNameTemplate: "{name}"
    )

    let report = try service.export(assets: [asset], preset: preset, destinationDirectory: destinationDirectory)
    let exportedURL = try #require(report.exportedURLs.first)
    let source = try #require(CGImageSourceCreateWithURL(exportedURL as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))

    let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    let iptc = try #require(properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
    let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])

    #expect(tiff[kCGImagePropertyTIFFMake] as? String == "Fuji")
    #expect(tiff[kCGImagePropertyTIFFModel] as? String == "X-T5")
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2023:11:14 22:13:20")
    #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "aux:Lens" as CFString) as String? == "33mm")
    #expect((iptc[kCGImagePropertyIPTCKeywords] as? [String])?.contains("night") == true)
    #expect(abs((gps[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 40.7128) < 0.001)
}

@Test func autoEnhancePreservesNoiseReductionSettings() throws {
    let renderer = CoreImageDevelopRenderer()
    let imageURL = try writeTemporaryJPEG()
    var settings = DevelopSettings.default
    settings.luminanceNoiseReductionAmount = 0.42
    settings.chrominanceNoiseReductionAmount = 0.27

    let suggested = try renderer.suggestedSettings(for: imageURL, current: settings)

    #expect(suggested.luminanceNoiseReductionAmount == 0.42)
    #expect(suggested.chrominanceNoiseReductionAmount == 0.27)
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

private func writeTemporaryJPEG() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "auto-enhance.jpg")
    let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, try #require(makeSolidImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
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
    func saveEdit(assetID: UUID, settings: DevelopSettings, previewPath: String?, status: PreviewStatus) throws {}
    func saveDevelopSettings(assetID: UUID, settings: DevelopSettings) throws {}
    func updatePreview(assetID: UUID, previewPath: String?, status: PreviewStatus) throws {}
    func geotagAssets(_ matches: [GeotagMatch]) throws -> Int { matches.count }
}

private struct FailingRenderer: DevelopRenderer {
    func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage {
        throw RenderFailure()
    }
}

private struct RenderFailure: Error {}
