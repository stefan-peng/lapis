import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LapisApp
@testable import LapisCore

@Test @MainActor func libraryPlainClickSelectsSingleAsset() throws {
    let (state, assets, _) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    #expect(state.selectedAssetIDs == [assets[0].id])

    state.handleLibrarySelection(assetID: assets[1].id, modifiers: [])
    #expect(state.selectedAssetIDs == [assets[1].id])
    #expect(state.selectedAsset?.id == assets[1].id)
}

@Test @MainActor func libraryCommandClickTogglesSelection() throws {
    let (state, assets, _) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    state.handleLibrarySelection(assetID: assets[1].id, modifiers: [.command])
    #expect(state.selectedAssetIDs == [assets[0].id, assets[1].id])

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [.command])
    #expect(state.selectedAssetIDs == [assets[1].id])
}

@Test @MainActor func libraryShiftClickExtendsSelectionRange() throws {
    let (state, assets, _) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    state.handleLibrarySelection(assetID: assets[2].id, modifiers: [.shift])

    #expect(state.selectedAssetIDs == Set([assets[0].id, assets[1].id, assets[2].id]))
}

@Test @MainActor func compareModeRequiresExplicitActionAndExitsWhenSelectionChanges() throws {
    let (state, assets, _) = try makeAppState()

    state.handleLibrarySelection(assetID: assets[0].id, modifiers: [])
    state.handleLibrarySelection(assetID: assets[1].id, modifiers: [.command])

    #expect(state.libraryDetailMode == .browse)
    state.activateCompareMode()
    #expect(state.libraryDetailMode == .compare)

    state.handleLibrarySelection(assetID: assets[2].id, modifiers: [])
    #expect(state.libraryDetailMode == .browse)
    #expect(state.selectedAssetIDs == [assets[2].id])
}

@Test @MainActor func gpxCandidatesRespectActiveFilterWhenNothingIsSelected() throws {
    let (state, assets, _) = try makeAppState()

    state.filter.searchText = "asset-2"
    try state.reload()

    let candidates = try state.gpxCandidateAssets()

    #expect(candidates.map(\.id) == [assets[1].id])
}

@Test @MainActor func libraryLoadsReferencedFilesystemAssetsWithoutCatalogSeedAndPersistsOnDemand() throws {
    let (state, assets, store) = try makeAppState(seedCatalog: false)

    #expect(assets.count == 3)
    #expect(try store.fetchAssets(filter: .default).isEmpty)

    state.selectSingleAsset(assets[0].id)
    state.updateSelectedAssetMetadata(rating: 4)

    let persistedAssets = try store.fetchAssets(filter: .default)
    #expect(persistedAssets.count == 1)
    #expect(persistedAssets[0].sourcePath == assets[0].sourcePath)
    #expect(persistedAssets[0].rating == 4)
}

@Test func missingStoredLibraryPathsDoNotFallBackToPictures() {
    let suiteName = "UserDefaultsLibraryReferenceStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(["/tmp/does-not-exist-\(UUID().uuidString)"], forKey: "library.referencePaths")
    let store = UserDefaultsLibraryReferenceStore(defaults: defaults)

    #expect(store.referencedFolderURLs().isEmpty)

    defaults.removePersistentDomain(forName: suiteName)
}

@Test @MainActor func metadataUpdatesDoNotRescanUnchangedFilesystemAssets() throws {
    let decoder = CountingRawDecoder()
    let (state, assets, _) = try makeAppState(seedCatalog: false, rawDecoder: decoder)

    #expect(decoder.metadataCallCount == 3)

    state.selectSingleAsset(assets[0].id)
    state.updateSelectedAssetMetadata(rating: 5)

    #expect(decoder.metadataCallCount == 4)
}

@Test func changedFilesInvalidateStalePreviewsAndDevelopSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = try writeJPEG(in: directory, name: "asset.jpg")
    let existingAsset = Asset(
        sourcePath: fileURL.path(percentEncoded: false),
        fileIdentity: "old",
        fileSize: 10,
        modifiedAt: Date(timeIntervalSince1970: 100),
        importedAt: Date(timeIntervalSince1970: 50),
        captureDate: Date(timeIntervalSince1970: 25),
        cameraMake: "Apple",
        cameraModel: "Old Camera",
        lensModel: "Old Lens",
        pixelWidth: 4_000,
        pixelHeight: 3_000,
        format: .jpeg,
        gpsCoordinate: GPSCoordinate(latitude: 1, longitude: 2, altitude: nil),
        previewStatus: .ready,
        previewPath: "/tmp/preview.jpg",
        rating: 4,
        flag: .picked,
        keywords: ["kept"],
        albumIDs: [UUID()],
        developSettings: {
            var settings = DevelopSettings.default
            settings.exposure = 0.8
            return settings
        }()
    )
    let importedAsset = ImportedAsset(
        sourceURL: fileURL,
        fileIdentity: "new",
        fileSize: 12,
        modifiedAt: Date(timeIntervalSince1970: 200),
        captureDate: Date(timeIntervalSince1970: 30),
        cameraMake: "Apple",
        cameraModel: "New Camera",
        lensModel: "New Lens",
        pixelWidth: 6_000,
        pixelHeight: 4_000,
        format: .jpeg,
        gpsCoordinate: nil
    )
    let decoder = StubRawDecoder(importedAssets: [fileURL.path(percentEncoded: false): importedAsset])
    let library = FileSystemLibraryService(decoder: decoder)

    let loadedAssets = try library.loadAssets(from: [directory], catalogAssets: [existingAsset])
    let mergedAsset = try #require(loadedAssets.first)

    #expect(mergedAsset.previewStatus == PreviewStatus.missing)
    #expect(mergedAsset.previewPath == nil)
    #expect(mergedAsset.developSettings == .default)
    #expect(mergedAsset.rating == 4)
}

@Test @MainActor func removingReferencedFolderUpdatesVisibleAssets() throws {
    let primaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let secondaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondaryDirectory, withIntermediateDirectories: true)
    _ = try writeJPEG(in: primaryDirectory, name: "primary.jpg")
    _ = try writeJPEG(in: secondaryDirectory, name: "secondary.jpg")

    let referenceStore = MutableLibraryReferenceStore(folderURLs: [primaryDirectory, secondaryDirectory])
    let decoder = CountingRawDecoder()
    let environment = try makeEnvironment(
        libraryRoot: primaryDirectory,
        rawDecoder: decoder,
        libraryReferences: referenceStore
    )
    let state = try AppState(environment: environment)

    #expect(state.assets.count == 2)

    state.removeLibraryFolder(primaryDirectory)

    #expect(state.libraryFolderURLs == [secondaryDirectory.standardizedFileURL])
    #expect(state.assets.count == 1)
    #expect(state.assets[0].sourcePath == secondaryDirectory.appending(path: "secondary.jpg").path(percentEncoded: false))
    #expect(referenceStore.savedFolderURLs == [secondaryDirectory.standardizedFileURL])
}

@Test @MainActor func selectingReferencedFolderFiltersVisibleAssets() throws {
    let primaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let secondaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondaryDirectory, withIntermediateDirectories: true)
    _ = try writeJPEG(in: primaryDirectory, name: "primary.jpg")
    _ = try writeJPEG(in: secondaryDirectory, name: "secondary.jpg")

    let referenceStore = MutableLibraryReferenceStore(folderURLs: [primaryDirectory, secondaryDirectory])
    let environment = try makeEnvironment(
        libraryRoot: primaryDirectory,
        rawDecoder: CountingRawDecoder(),
        libraryReferences: referenceStore
    )
    let state = try AppState(environment: environment)

    state.selectLibraryFolder(secondaryDirectory)

    #expect(state.selectedLibraryFolderURL == secondaryDirectory.standardizedFileURL)
    #expect(state.selectedAlbumID == nil)
    #expect(state.assets.count == 1)
    #expect(state.assets[0].sourcePath == secondaryDirectory.appending(path: "secondary.jpg").path(percentEncoded: false))
}

@Test @MainActor func removingSelectedReferencedFolderClearsFolderFilter() throws {
    let primaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let secondaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondaryDirectory, withIntermediateDirectories: true)
    _ = try writeJPEG(in: primaryDirectory, name: "primary.jpg")
    _ = try writeJPEG(in: secondaryDirectory, name: "secondary.jpg")

    let referenceStore = MutableLibraryReferenceStore(folderURLs: [primaryDirectory, secondaryDirectory])
    let environment = try makeEnvironment(
        libraryRoot: primaryDirectory,
        rawDecoder: CountingRawDecoder(),
        libraryReferences: referenceStore
    )
    let state = try AppState(environment: environment)

    state.selectLibraryFolder(primaryDirectory)
    state.removeLibraryFolder(primaryDirectory)

    #expect(state.selectedLibraryFolderURL == nil)
    #expect(state.libraryFolderURLs == [secondaryDirectory.standardizedFileURL])
    #expect(state.assets.count == 1)
    #expect(state.assets[0].sourcePath == secondaryDirectory.appending(path: "secondary.jpg").path(percentEncoded: false))
}

@Test @MainActor func editorZoomClampsAndFitResetsPan() throws {
    let (state, assets, _) = try makeAppState()
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
    let (state, assets, _) = try makeAppState()
    let session = EditorSession(state: state, asset: assets[0])
    let viewport = CGSize(width: 900, height: 700)

    session.updateViewportSize(viewport)
    let startingScale = session.zoomScale ?? min(viewport.width / session.currentImageExtent.width, viewport.height / session.currentImageExtent.height)

    session.zoomByScroll(deltaY: 6, at: CGPoint(x: viewport.width / 2, y: viewport.height / 2), in: viewport, imageExtent: session.currentImageExtent)

    #expect((session.zoomScale ?? startingScale) > startingScale)
}

@Test @MainActor func editorZoomDoesNotQueueFreshPreviewRender() async throws {
    let (state, assets, _) = try makeAppState()
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
    let (state, assets, _) = try makeAppState()
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
    let (state, assets, _) = try makeAppState(developProcessor: processor, assetEditor: assetEditor)
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
    let (state, assets, _) = try makeAppState(developProcessor: processor)
    let session = EditorSession(state: state, asset: assets[0])

    session.updateViewportSize(CGSize(width: 900, height: 700))
    try await waitUntil("initial viewport render") { renderSpy.previewRenderCount == 1 && session.isRenderingPreview == false }

    session.updateViewportSize(CGSize(width: 900.5, height: 700.5))
    try await Task.sleep(for: .milliseconds(150))
    #expect(renderSpy.previewRenderCount == 1)

    session.updateViewportSize(CGSize(width: 902, height: 700))
    try await Task.sleep(for: .milliseconds(150))
    #expect(renderSpy.previewRenderCount == 1)
}

@Test @MainActor func editorViewportResizeSkipsRerenderWhenPreviewResolutionIsUnchanged() async throws {
    let renderSpy = PreviewRenderSpy()
    let processor = MockDevelopProcessor(renderSpy: renderSpy)
    let (state, assets, _) = try makeAppState(developProcessor: processor)
    let session = EditorSession(state: state, asset: assets[0])

    session.updateViewportSize(CGSize(width: 900, height: 700))
    try await waitUntil("initial viewport render") { renderSpy.previewRenderCount == 1 && session.isRenderingPreview == false }

    session.updateViewportSize(CGSize(width: 960, height: 740))
    try await Task.sleep(for: .milliseconds(150))
    #expect(renderSpy.previewRenderCount == 1)

    session.updateViewportSize(CGSize(width: 1200, height: 740))
    try await waitUntil("higher resolution viewport render") { renderSpy.previewRenderCount == 2 && session.isRenderingPreview == false }
}

@Test @MainActor func editorFlushPendingEditsPersistsLatestSettingsBeforeSessionTeardown() async throws {
    let assetEditorSpy = AssetEditorSpy()
    let assetEditor = MockAssetEditor(spy: assetEditorSpy)
    let (state, assets, _) = try makeAppState(assetEditor: assetEditor)
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
    seedCatalog: Bool = true,
    rawDecoder overrideRawDecoder: (any RawDecoder)? = nil,
    libraryReferences overrideLibraryReferences: (any LibraryReferencing)? = nil,
    developProcessor overrideDevelopProcessor: (any DevelopProcessing)? = nil,
    assetEditor overrideAssetEditor: (any AssetEditing)? = nil
) throws -> (AppState, [Asset], GRDBCatalogStore) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let environment = try makeEnvironment(
        libraryRoot: directory,
        rawDecoder: overrideRawDecoder ?? AppleRawDecoder(),
        libraryReferences: overrideLibraryReferences ?? FixedLibraryReferenceStore(folderURLs: [directory]),
        developProcessor: overrideDevelopProcessor,
        assetEditor: overrideAssetEditor
    )
    let store = try #require(environment.catalogStore as? GRDBCatalogStore)

    for index in 1...3 {
        let imageURL = try writeJPEG(in: directory, name: "asset-\(index).jpg")
        if seedCatalog {
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
    }

    let state = try AppState(environment: environment)
    return (state, state.assets, store)
}

@MainActor
private func makeEnvironment(
    libraryRoot: URL,
    rawDecoder: any RawDecoder,
    libraryReferences: any LibraryReferencing,
    developProcessor overrideDevelopProcessor: (any DevelopProcessing)? = nil,
    assetEditor overrideAssetEditor: (any AssetEditing)? = nil
) throws -> AppEnvironment {
    let databaseURL = libraryRoot.appending(path: "catalog.sqlite")
    let previewsURL = libraryRoot.appending(path: "previews", directoryHint: .isDirectory)
    let store = try GRDBCatalogStore(databaseURL: databaseURL)
    let previewService = try PreviewService(directoryURL: previewsURL)
    let renderer = CoreImageDevelopRenderer()
    let developProcessor = overrideDevelopProcessor ?? renderer
    let importer = AssetImporter(decoder: rawDecoder, previewService: previewService)

    return AppEnvironment(
        catalogStore: store,
        assetImporter: importer,
        fileSystemLibrary: FileSystemLibraryService(decoder: rawDecoder),
        libraryReferences: libraryReferences,
        gpxService: GPXApplicationService(catalogStore: store, parser: GPXParser(), matcher: TimestampGeotagMatcher()),
        developProcessor: developProcessor,
        assetEditor: overrideAssetEditor ?? AssetEditingService(catalogStore: store, renderer: developProcessor, previewCache: previewService),
        exportService: ExportService(renderer: developProcessor),
        metadataWriter: MetadataWritebackService()
    )
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
        .cropped(to: CGRect(x: 0, y: 0, width: 4_000, height: 3_000))
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

private struct FixedLibraryReferenceStore: LibraryReferencing {
    let folderURLs: [URL]

    func referencedFolderURLs() -> [URL] {
        folderURLs
    }

    func saveReferencedFolderURLs(_ folderURLs: [URL]) throws {}
}

private final class MutableLibraryReferenceStore: LibraryReferencing, @unchecked Sendable {
    var folderURLs: [URL]
    var savedFolderURLs: [URL] = []

    init(folderURLs: [URL]) {
        self.folderURLs = folderURLs
        self.savedFolderURLs = folderURLs
    }

    func referencedFolderURLs() -> [URL] {
        folderURLs
    }

    func saveReferencedFolderURLs(_ folderURLs: [URL]) throws {
        self.folderURLs = folderURLs
        savedFolderURLs = folderURLs
    }
}

private final class CountingRawDecoder: RawDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var importedAssets: [String: ImportedAsset] = [:]
    private var _metadataCallCount = 0

    var metadataCallCount: Int {
        lock.withLock { _metadataCallCount }
    }

    func metadata(for fileURL: URL) throws -> ImportedAsset {
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        return try lock.withLock {
            _metadataCallCount += 1
            if let importedAsset = importedAssets[path] {
                return importedAsset
            }
            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let importedAsset = ImportedAsset(
                sourceURL: fileURL.standardizedFileURL,
                fileIdentity: path,
                fileSize: Int64(resourceValues.fileSize ?? 0),
                modifiedAt: resourceValues.contentModificationDate ?? .now,
                captureDate: captureDate(for: fileURL),
                cameraMake: "Apple",
                cameraModel: "Test Camera",
                lensModel: "Test Lens",
                pixelWidth: 4_000,
                pixelHeight: 3_000,
                format: .jpeg,
                gpsCoordinate: nil
            )
            importedAssets[path] = importedAsset
            return importedAsset
        }
    }

    func renderThumbnail(for fileURL: URL, maxPixelSize: Int) throws -> CGImage {
        try #require(makeSolidImage())
    }

    private func captureDate(for fileURL: URL) -> Date {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let suffix = fileName.split(separator: "-").last.map(String.init).flatMap(Int.init) ?? 0
        return Date(timeIntervalSince1970: 1_000 + Double(suffix))
    }
}

private struct StubRawDecoder: RawDecoder, Sendable {
    let importedAssets: [String: ImportedAsset]

    func metadata(for fileURL: URL) throws -> ImportedAsset {
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        return try #require(importedAssets[path])
    }

    func renderThumbnail(for fileURL: URL, maxPixelSize: Int) throws -> CGImage {
        try #require(makeSolidImage())
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
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
