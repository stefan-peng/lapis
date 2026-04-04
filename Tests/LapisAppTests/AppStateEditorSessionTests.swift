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

@Test @MainActor func editorScrollZoomUsesPositiveDeltaToZoomIn() throws {
    let (state, assets) = try makeAppState()
    let session = EditorSession(state: state, asset: assets[0])
    let viewport = CGSize(width: 900, height: 700)

    session.updateViewportSize(viewport)
    let startingScale = session.zoomScale ?? min(viewport.width / session.currentImageExtent.width, viewport.height / session.currentImageExtent.height)

    session.zoomByScroll(deltaY: 6, at: CGPoint(x: viewport.width / 2, y: viewport.height / 2), in: viewport, imageExtent: session.currentImageExtent)

    #expect((session.zoomScale ?? startingScale) > startingScale)
}

@Test @MainActor func editorZoomDoesNotQueueFreshPreviewRender() async throws {
    let (state, assets) = try makeAppState()
    let session = EditorSession(state: state, asset: assets[0])
    let viewport = CGSize(width: 900, height: 700)

    session.updateViewportSize(viewport)

    for _ in 0..<100 where session.isRenderingPreview {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(session.isRenderingPreview == false)

    session.stepZoomIn(in: viewport, imageExtent: session.currentImageExtent)

    #expect(session.isRenderingPreview == false)
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

@Test @MainActor func editorRapidAdjustmentsCoalescePreviewAndPersistenceWork() async throws {
    let renderSpy = PreviewRenderSpy()
    let assetEditorSpy = AssetEditorSpy()
    let processor = MockDevelopProcessor(renderSpy: renderSpy)
    let assetEditor = MockAssetEditor(spy: assetEditorSpy)
    let (state, assets) = try makeAppState(developProcessor: processor, assetEditor: assetEditor)
    let session = EditorSession(state: state, asset: assets[0])

    session.updateViewportSize(CGSize(width: 900, height: 700))
    try await waitUntil("initial preview render") { renderSpy.previewRenderCount == 1 && session.isRenderingPreview == false }

    session.update { $0.exposure = 0.1 }
    session.update { $0.exposure = 0.25 }
    session.update { $0.exposure = 0.4 }

    try await waitUntil("debounced preview render") { renderSpy.previewRenderCount == 2 && session.isRenderingPreview == false }
    try await waitUntil("debounced persistence") { assetEditorSpy.commitCount == 1 && session.isPersisting == false }

    let request = try #require(assetEditorSpy.lastRequest)
    #expect(request.settings.exposure == 0.4)
    #expect(renderSpy.previewRenderCount == 2)
    #expect(assetEditorSpy.commitCount == 1)
}

@Test @MainActor func editorViewportSizeIgnoresSubpixelChangesToAvoidPreviewThrash() async throws {
    let renderSpy = PreviewRenderSpy()
    let processor = MockDevelopProcessor(renderSpy: renderSpy)
    let (state, assets) = try makeAppState(developProcessor: processor)
    let session = EditorSession(state: state, asset: assets[0])

    session.updateViewportSize(CGSize(width: 900, height: 700))
    try await waitUntil("initial viewport render") { renderSpy.previewRenderCount == 1 && session.isRenderingPreview == false }

    session.updateViewportSize(CGSize(width: 900.5, height: 700.5))
    try await Task.sleep(for: .milliseconds(150))
    #expect(renderSpy.previewRenderCount == 1)

    session.updateViewportSize(CGSize(width: 902, height: 700))
    try await waitUntil("significant viewport render") { renderSpy.previewRenderCount == 2 && session.isRenderingPreview == false }
}

@Test @MainActor func editorFlushPendingEditsPersistsLatestSettingsBeforeSessionTeardown() async throws {
    let assetEditorSpy = AssetEditorSpy()
    let assetEditor = MockAssetEditor(spy: assetEditorSpy)
    let (state, assets) = try makeAppState(assetEditor: assetEditor)
    let session = EditorSession(state: state, asset: assets[0])

    session.update { $0.exposure = 0.55 }
    #expect(session.isPersisting)

    session.flushPendingEdits()

    try await waitUntil("flush persistence") { assetEditorSpy.commitCount == 1 && session.isPersisting == false }

    let request = try #require(assetEditorSpy.lastRequest)
    #expect(request.settings.exposure == 0.55)
}

@MainActor
private func makeAppState(
    developProcessor overrideDevelopProcessor: (any DevelopProcessing)? = nil,
    assetEditor overrideAssetEditor: (any AssetEditing)? = nil
) throws -> (AppState, [Asset]) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let databaseURL = directory.appending(path: "catalog.sqlite")
    let previewsURL = directory.appending(path: "previews", directoryHint: .isDirectory)
    let store = try GRDBCatalogStore(databaseURL: databaseURL)
    let previewService = try PreviewService(directoryURL: previewsURL)
    let renderer = CoreImageDevelopRenderer()
    let developProcessor = overrideDevelopProcessor ?? renderer
    let importer = AssetImporter(decoder: AppleRawDecoder(), previewService: previewService)
    let environment = AppEnvironment(
        catalogStore: store,
        importer: FolderImportService(importer: importer, catalogStore: store),
        gpxService: GPXApplicationService(catalogStore: store, parser: GPXParser(), matcher: TimestampGeotagMatcher()),
        developProcessor: developProcessor,
        assetEditor: overrideAssetEditor ?? AssetEditingService(catalogStore: store, renderer: developProcessor, previewCache: previewService),
        exportService: ExportService(renderer: developProcessor),
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

@MainActor
private func waitUntil(
    _ description: String,
    timeoutMilliseconds: Int = 2_000,
    pollMilliseconds: Int = 10,
    condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(pollMilliseconds))
    }
    Issue.record("Timed out waiting for \(description)")
}

private final class PreviewRenderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _previewRenderCount = 0

    var previewRenderCount: Int {
        lock.withLock { _previewRenderCount }
    }

    func recordPreviewRender() {
        lock.withLock {
            _previewRenderCount += 1
        }
    }
}

private final class AssetEditorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _commitRequests: [AssetEditRequest] = []

    var commitCount: Int {
        lock.withLock { _commitRequests.count }
    }

    var lastRequest: AssetEditRequest? {
        lock.withLock { _commitRequests.last }
    }

    func record(_ request: AssetEditRequest) {
        lock.withLock {
            _commitRequests.append(request)
        }
    }
}

private struct MockDevelopProcessor: DevelopProcessing, @unchecked Sendable {
    let renderSpy: PreviewRenderSpy
    let interactiveContext = CIContext()

    func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage {
        guard let image = makeSolidImage() else {
            throw RendererError.renderFailed(fileURL.path(percentEncoded: false))
        }
        return image
    }

    func previewImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CIImage {
        renderSpy.recordPreviewRender()
        return CIImage(cgImage: try renderImage(from: fileURL, settings: settings, maxPixelSize: maxPixelSize))
    }

    func analysis(for fileURL: URL) throws -> ImageAnalysis {
        ImageAnalysis(averageLuminance: 0.45, averageSaturation: 0.2, lensCorrectionSuggested: false)
    }

    func suggestedSettings(for fileURL: URL, current settings: DevelopSettings) throws -> DevelopSettings {
        settings
    }

    func suggestedValue(for control: AutoAdjustmentControl, fileURL: URL, current settings: DevelopSettings) throws -> Double {
        0
    }
}

private struct MockAssetEditor: AssetEditing, @unchecked Sendable {
    let spy: AssetEditorSpy

    func commit(_ request: AssetEditRequest) throws -> AssetEditResult {
        spy.record(request)
        return AssetEditResult(settings: request.settings, previewPath: nil, previewStatus: .ready)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
