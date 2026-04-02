import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LapisApp
@testable import LapisCore

@Test @MainActor func libraryPlainClickSelectsSingleAsset() throws {
    let (state, assets) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    #expect(state.selectedAssetIDs == [assets[0].id])

    state.handleLibrarySelection(assetID: assets[1].id, modifiers: [])
    #expect(state.selectedAssetIDs == [assets[1].id])
    #expect(state.selectedAsset?.id == assets[1].id)
}

@Test @MainActor func libraryCommandClickTogglesSelection() throws {
    let (state, assets) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    state.handleLibrarySelection(assetID: assets[1].id, modifiers: [.command])
    #expect(state.selectedAssetIDs == [assets[0].id, assets[1].id])

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [.command])
    #expect(state.selectedAssetIDs == [assets[1].id])
}

@Test @MainActor func libraryShiftClickExtendsSelectionRange() throws {
    let (state, assets) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    state.handleLibrarySelection(assetID: assets[2].id, modifiers: [.shift])

    #expect(state.selectedAssetIDs == Set([assets[0].id, assets[1].id, assets[2].id]))
}

@Test @MainActor func compareModeRequiresExplicitActionAndExitsWhenSelectionChanges() throws {
    let (state, assets) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    state.handleLibrarySelection(assetID: assets[1].id, modifiers: [.command])

    #expect(state.libraryDetailMode == .browse)
    state.activateCompareMode()
    #expect(state.libraryDetailMode == .compare)

    state.handleLibrarySelection(assetID: assets[2].id, modifiers: [])
    #expect(state.libraryDetailMode == .browse)
    #expect(state.selectedAssetIDs == [assets[2].id])
}

@Test @MainActor func editorZoomClampsAndFitResetsPan() throws {
    let (state, assets) = try makeAppState()
    let session = EditorSession(state: state, asset: assets[0])
    let viewport = CGSize(width: 900, height: 700)

    session.updateViewportSize(viewport)
    for _ in 0..<24 {
        session.stepZoomIn(in: viewport, imageExtent: session.currentImageExtent)
    }

    #expect((session.zoomScale ?? 0) <= 8)

    session.pan(from: .zero, by: CGSize(width: 5_000, height: 5_000), in: viewport, imageExtent: session.currentImageExtent)
    #expect(session.panOffset != .zero)

    session.setFitZoom()
    #expect(session.zoomScale == nil)
    #expect(session.panOffset == .zero)
}

@Test @MainActor func editorPreviewUsesCropOnlyInAdjustMode() throws {
    let (state, assets) = try makeAppState()
    let session = EditorSession(state: state, asset: assets[0])
    let cropRect = CropRect(x: 0.1, y: 0.1, width: 0.75, height: 0.7)

    session.currentSettings.cropRect = cropRect
    #expect(session.displayPreviewSettings().cropRect == cropRect)

    session.setToolMode(.crop)
    #expect(session.displayPreviewSettings().cropRect == .fullFrame)
}

@MainActor
private func makeAppState() throws -> (AppState, [Asset]) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let databaseURL = directory.appending(path: "catalog.sqlite")
    let previewsURL = directory.appending(path: "previews", directoryHint: .isDirectory)
    let store = try GRDBCatalogStore(databaseURL: databaseURL)
    let previewService = try PreviewService(directoryURL: previewsURL)
    let renderer = CoreImageDevelopRenderer()
    let importer = AssetImporter(decoder: AppleRawDecoder(), previewService: previewService)
    let environment = AppEnvironment(
        catalogStore: store,
        importer: FolderImportService(importer: importer, catalogStore: store),
        gpxService: GPXApplicationService(catalogStore: store, parser: GPXParser(), matcher: TimestampGeotagMatcher()),
        developProcessor: renderer,
        assetEditor: AssetEditingService(catalogStore: store, renderer: renderer, previewCache: previewService),
        exportService: ExportService(renderer: renderer),
        metadataWriter: MetadataWritebackService()
    )

    for index in 1...3 {
        let imageURL = try writeJPEG(in: directory, name: "asset-\(index).jpg")
        let imported = ImportedAsset(
            sourceURL: imageURL,
            fileIdentity: "asset-\(index)",
            fileSize: 1,
            modifiedAt: .now,
            captureDate: Date(timeIntervalSince1970: 1_000 + Double(index)),
            cameraMake: "Apple",
            cameraModel: "Test Camera",
            lensModel: "Test Lens",
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            format: .jpeg,
            gpsCoordinate: nil
        )
        _ = try store.importAsset(imported)
    }

    let state = try AppState(environment: environment)
    return (state, state.assets)
}

private func writeJPEG(in directory: URL, name: String) throws -> URL {
    let url = directory.appending(path: name)
    let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, try #require(makeSolidImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

private func makeSolidImage() -> CGImage? {
    let ciImage = CIImage(color: CIColor(red: 0.3, green: 0.45, blue: 0.7))
        .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
    return CIContext().createCGImage(ciImage, from: ciImage.extent)
}
