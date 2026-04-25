import AppKit
import CoreLocation
import Foundation
import LapisCore
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    enum WorkspaceMode: String, CaseIterable, Identifiable {
        case library
        case edit

        var id: String { rawValue }
    }

    enum LibraryDetailMode: String, CaseIterable, Identifiable {
        case browse
        case compare

        var id: String { rawValue }
    }

    static let defaultExportPresets: [ExportPreset] = [
        ExportPreset(
            name: "High Quality JPEG",
            format: .jpeg,
            colorSpace: .sRGB,
            quality: 0.94,
            maxPixelSize: nil,
            outputSharpening: 0.2,
            fileNameTemplate: "{name}"
        ),
        ExportPreset(
            name: "Web JPEG",
            format: .jpeg,
            colorSpace: .sRGB,
            quality: 0.84,
            maxPixelSize: 2400,
            outputSharpening: 0.5,
            fileNameTemplate: "{name}-web"
        ),
        ExportPreset(
            name: "Full TIFF",
            format: .tiff,
            colorSpace: .displayP3,
            quality: 1,
            maxPixelSize: nil,
            outputSharpening: 0.2,
            fileNameTemplate: "{name}-master"
        ),
    ]

    let environment: AppEnvironment

    var assets: [Asset] = []
    var albums: [Album] = []
    var libraryFolderURLs: [URL] = []
    var selectedAssetIDs: Set<UUID> = []
    var selectedAlbumID: UUID?
    var selectedLibraryFolderURL: URL?
    var selectedExportPresetID: UUID = AppState.defaultExportPresets[0].id
    var exportPresets: [ExportPreset] = AppState.defaultExportPresets

    var workspaceMode: WorkspaceMode = .library
    var libraryDetailMode: LibraryDetailMode = .browse
    var showOriginalInEditor = false
    var isLoadingLibrary = false
    var libraryLoadStatus = ""
    var filter = AssetFilter.default
    var statusMessage = ""
    var gpxTimezoneOffsetMinutes = 0
    var gpxCameraClockOffsetSeconds = 0
    var albumNameDraft = ""
    var selectionAnchorAssetID: UUID?

    private var assetIndexByID: [UUID: Int] = [:]
    private var libraryAssets: [Asset] = []
    private var libraryLoadGeneration = 0
    private var pendingEditOpenStartNanos: UInt64?

    init(environment: AppEnvironment, shouldLoadLibrary: Bool = true) throws {
        self.environment = environment
        self.libraryFolderURLs = environment.libraryReferences.referencedFolderURLs()
        if shouldLoadLibrary {
            try reloadLibrary()
        }
    }

    var selectedAssets: [Asset] {
        selectedAssetIDs
            .compactMap { assetID in
                assetIndexByID[assetID].map { (index: $0, asset: assets[$0]) }
            }
            .sorted { $0.index < $1.index }
            .map(\.asset)
    }

    var geotaggedAssets: [Asset] {
        assets.filter { $0.gpsCoordinate != nil }
    }

    var selectedAsset: Asset? {
        guard selectedAssetIDs.count == 1, let selectedAssetID = selectedAssetIDs.first,
              let index = assetIndexByID[selectedAssetID] else { return nil }
        return assets[index]
    }

    var compareAssets: [Asset] {
        Array(selectedAssets.prefix(2))
    }

    var canCompareSelection: Bool {
        selectedAssetIDs.count == 2
    }

    func reload() throws {
        assets = filteredLibraryAssets()
        rebuildAssetIndex()
        albums = try environment.catalogStore.fetchAlbums()
        applySelection(selectedAssetIDs.intersection(Set(assets.map(\.id))), anchor: selectionAnchorAssetID)
    }

    func referenceFolders() {
        let panel = NSOpenPanel()
        panel.prompt = "Add Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        presentOpenPanel(panel) { [weak self] panel in
            guard let self else { return }
            do {
                self.libraryFolderURLs = self.mergedLibraryFolders(with: panel.urls)
                try self.environment.libraryReferences.saveReferencedFolderURLs(self.libraryFolderURLs)
                Task { @MainActor [weak self] in
                    await self?.reloadLibraryAsync(status: "Scanning selected folders...")
                }
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func importGPX() {
        let panel = NSOpenPanel()
        panel.prompt = "Apply GPX"
        panel.allowedContentTypes = [.xml] + [UTType(filenameExtension: "gpx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        presentOpenPanel(panel) { [weak self] panel in
            guard let self, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let targetAssets = try self.gpxCandidateAssets().map(self.ensureCatalogAsset(for:))
                let result = try self.environment.gpxService.applyGPX(
                    data: data,
                    to: targetAssets,
                    timezoneOffsetMinutes: self.gpxTimezoneOffsetMinutes,
                    cameraClockOffsetSeconds: self.gpxCameraClockOffsetSeconds
                )
                try self.refreshPersistedAssets(withIDs: targetAssets.map(\.id))
                self.statusMessage = "Applied GPX tags to \(result.appliedCount) of \(result.candidateCount) candidate photos"
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func updateSelectedAssetMetadata(rating: Int? = nil, flag: AssetFlag? = nil, keywords: [String]? = nil) {
        guard let asset = selectedAsset else { return }
        do {
            let persistedAsset = try ensureCatalogAsset(for: asset)
            try environment.catalogStore.updateMetadata(
                assetID: persistedAsset.id,
                rating: rating,
                flag: flag,
                keywords: keywords,
                gpsCoordinate: nil
            )
            try refreshPersistedAssets(withIDs: [persistedAsset.id])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func updateSelectedAssetDevelopSettings(_ transform: (inout DevelopSettings) -> Void) {
        guard let selectedAsset else { return }
        var asset = selectedAsset
        transform(&asset.developSettings)
        do {
            let persistedAsset = try ensureCatalogAsset(for: selectedAsset)
            let result = try environment.assetEditor.commit(
                AssetEditRequest(
                    assetID: persistedAsset.id,
                    sourcePath: persistedAsset.sourcePath,
                    settings: asset.developSettings,
                    previewIdentifier: persistedAsset.id.uuidString
                )
            )
            applyEditorCommit(
                assetID: persistedAsset.id,
                settings: result.settings,
                previewPath: result.previewPath,
                previewStatus: result.previewStatus
            )
            showOriginalInEditor = false
            try refreshPersistedAssets(withIDs: [persistedAsset.id])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resetSelectedAssetDevelopSettings() {
        guard let asset = selectedAsset else { return }
        do {
            let persistedAsset = try ensureCatalogAsset(for: asset)
            let result = try environment.assetEditor.commit(
                AssetEditRequest(
                    assetID: persistedAsset.id,
                    sourcePath: persistedAsset.sourcePath,
                    settings: .default,
                    previewIdentifier: persistedAsset.id.uuidString
                )
            )
            applyEditorCommit(
                assetID: persistedAsset.id,
                settings: result.settings,
                previewPath: result.previewPath,
                previewStatus: result.previewStatus
            )
            showOriginalInEditor = false
            try refreshPersistedAssets(withIDs: [persistedAsset.id])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createAlbumFromDraft() {
        let trimmed = albumNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let album = try environment.catalogStore.createAlbum(named: trimmed)
            albumNameDraft = ""
            albums.append(album)
            statusMessage = "Created album \(album.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addSelectionToAlbum(_ album: Album) {
        do {
            let ids = try selectedAssets.map { try ensureCatalogAsset(for: $0).id }
            guard !ids.isEmpty else { return }
            try environment.catalogStore.assignAssets(ids, to: album.id)
            try refreshPersistedAssets(withIDs: ids)
            statusMessage = "Added \(ids.count) photos to \(album.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportSelection() {
        let selection = selectedAssets
        guard !selection.isEmpty else {
            statusMessage = "Select at least one asset to export"
            return
        }
        guard let preset = exportPresets.first(where: { $0.id == selectedExportPresetID }) else {
            statusMessage = "Missing export preset"
            return
        }

        let panel = NSOpenPanel()
        panel.prompt = "Choose Destination"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        presentOpenPanel(panel) { [weak self] panel in
            guard let self, let destinationURL = panel.url else { return }
            do {
                let report = try self.environment.exportService.export(
                    assets: selection,
                    preset: preset,
                    destinationDirectory: destinationURL
                )
                if report.failures.isEmpty {
                    self.statusMessage = "Exported \(report.exportedURLs.count) photo(s)"
                } else {
                    self.statusMessage = "Exported \(report.exportedURLs.count) photo(s), \(report.failures.count) failed"
                }
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func writeMetadataSidecar() {
        guard let asset = selectedAsset else { return }
        do {
            let url = try environment.metadataWriter.writeXMPSidecar(for: asset)
            statusMessage = "Wrote sidecar to \(url.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectAlbum(_ albumID: UUID?) {
        selectedAlbumID = albumID
        selectedLibraryFolderURL = nil
        do {
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectLibraryFolder(_ folderURL: URL?) {
        selectedLibraryFolderURL = folderURL?.standardizedFileURL
        selectedAlbumID = nil
        do {
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func handleLibrarySelection(assetID: UUID, modifiers: NSEvent.ModifierFlags) {
        let intent: LibrarySelectionIntent
        if modifiers.contains(.shift) {
            intent = .extendRange(assetID)
        } else if modifiers.contains(.command) {
            intent = .toggle(assetID)
        } else {
            intent = .replace(assetID)
        }
        applySelectionIntent(intent)
    }

    func selectSingleAsset(_ assetID: UUID) {
        applySelectionIntent(.replace(assetID))
    }

    func toggleSelection(for assetID: UUID) {
        applySelectionIntent(.toggle(assetID))
    }

    func extendSelection(to assetID: UUID) {
        applySelectionIntent(.extendRange(assetID))
    }

    func clearSelection() {
        applySelectionIntent(.clear)
    }

    func activateCompareMode() {
        guard canCompareSelection else { return }
        libraryDetailMode = .compare
    }

    func exitCompareMode() {
        libraryDetailMode = .browse
    }

    func openSelectedAssetForEditing() {
        guard let selectedAsset else { return }
        do {
            let persistedAsset = try ensureCatalogAsset(for: selectedAsset)
            applySelection([persistedAsset.id], anchor: persistedAsset.id)
            pendingEditOpenStartNanos = DispatchTime.now().uptimeNanoseconds
            AppPerformanceMetrics.event("editor.open.requested", details: "selectedCount=\(selectedAssetIDs.count)")
            workspaceMode = .edit
            libraryDetailMode = .browse
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func showLibrary() {
        workspaceMode = .library
    }

    func gpxCandidateAssets() throws -> [Asset] {
        if !selectedAssetIDs.isEmpty {
            return selectedAssets
        }
        return filteredLibraryAssets()
    }

    func applyEditorCommit(assetID: UUID, settings: DevelopSettings, previewPath: String?, previewStatus: PreviewStatus) {
        guard let index = assetIndexByID[assetID] else { return }
        assets[index].developSettings = settings
        assets[index].previewPath = previewPath
        assets[index].previewStatus = previewStatus
    }

    private func applySelection(_ selection: Set<UUID>, anchor: UUID?) {
        selectedAssetIDs = selection
        selectionAnchorAssetID = anchor.flatMap { selection.contains($0) ? $0 : selection.first }
        if libraryDetailMode == .compare, selectedAssetIDs.count != 2 {
            libraryDetailMode = .browse
        }
    }

    private func applySelectionIntent(_ intent: LibrarySelectionIntent) {
        let span = AppPerformanceMetrics.begin(
            "library.selection",
            details: "mode=\(selectionMetricLabel(for: intent)) selectedBefore=\(selectedAssetIDs.count) assets=\(assets.count)"
        )
        let current = LibrarySelectionState(selectedAssetIDs: selectedAssetIDs, anchorAssetID: selectionAnchorAssetID)
        let next = current.applying(intent, orderedAssetIDs: assets.map(\.id))
        applySelection(next.selectedAssetIDs, anchor: next.anchorAssetID)
        AppPerformanceMetrics.end(span, details: "selectedAfter=\(selectedAssetIDs.count)")
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, onAccepted: @escaping @MainActor (NSOpenPanel) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            statusMessage = "Open the main Lapis window to continue."
            return
        }

        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            Task { @MainActor in
                onAccepted(panel)
            }
        }
    }

    private func rebuildAssetIndex() {
        assetIndexByID = Dictionary(uniqueKeysWithValues: assets.enumerated().map { index, asset in
            (asset.id, index)
        })
    }

    func consumePendingEditOpenStartNanos() -> UInt64? {
        let start = pendingEditOpenStartNanos
        pendingEditOpenStartNanos = nil
        return start
    }

    func reloadLibrary() throws {
        libraryLoadGeneration += 1
        isLoadingLibrary = false
        libraryLoadStatus = ""
        reconcileSelectedLibraryFolder()
        let catalogAssets = try environment.catalogStore.fetchAssets(filter: .default)
        libraryAssets = try environment.fileSystemLibrary.loadAssets(from: libraryFolderURLs, catalogAssets: catalogAssets)
        try reload()
        statusMessage = ""
    }

    func reloadLibraryAsync(status: String = "Scanning library...") async {
        libraryLoadGeneration += 1
        let generation = libraryLoadGeneration
        isLoadingLibrary = true
        libraryLoadStatus = status
        reconcileSelectedLibraryFolder()
        defer {
            if generation == libraryLoadGeneration {
                isLoadingLibrary = false
                libraryLoadStatus = ""
            }
        }

        do {
            let folderURLs = libraryFolderURLs
            let catalogAssets = try environment.catalogStore.fetchAssets(filter: .default)
            let fileSystemLibrary = environment.fileSystemLibrary
            let loadedAssets = try await Task.detached(priority: .userInitiated) {
                try fileSystemLibrary.loadAssets(from: folderURLs, catalogAssets: catalogAssets)
            }.value

            guard generation == libraryLoadGeneration else { return }

            libraryAssets = loadedAssets
            try reload()
            statusMessage = ""
        } catch is CancellationError {
            return
        } catch {
            guard generation == libraryLoadGeneration else { return }
            statusMessage = error.localizedDescription
        }
    }

    func removeLibraryFolders(at offsets: IndexSet) {
        let urlsToRemove: [URL] = offsets.compactMap { index in
            guard libraryFolderURLs.indices.contains(index) else { return nil }
            return libraryFolderURLs[index]
        }
        removeLibraryFolders(urlsToRemove)
    }

    func removeLibraryFolder(_ folderURL: URL) {
        removeLibraryFolders([folderURL])
    }

    private func ensureCatalogAsset(for asset: Asset) throws -> Asset {
        if let existingAsset = try environment.catalogStore.fetchAsset(sourcePath: asset.sourcePath) {
            replaceAsset(existingAsset)
            return existingAsset
        }

        let disposition = try environment.assetImporter.importFile(
            URL(fileURLWithPath: asset.sourcePath),
            into: environment.catalogStore,
            preferredID: asset.id
        )

        let persistedAsset: Asset
        switch disposition {
        case .imported(let asset), .duplicate(let asset):
            persistedAsset = asset
        }

        replaceAsset(persistedAsset)
        return persistedAsset
    }

    private func filteredLibraryAssets() -> [Asset] {
        var activeFilter = filter
        activeFilter.albumID = selectedAlbumID
        let selectedFolderURL = selectedLibraryFolderURL?.standardizedFileURL
        return libraryAssets
            .filter { asset in
                matchesSearchText(asset, searchText: activeFilter.searchText) &&
                matchesMinimumRating(asset, minimumRating: activeFilter.minimumRating) &&
                matchesFlag(asset, flaggedOnly: activeFilter.flaggedOnly) &&
                matchesKeyword(asset, keyword: activeFilter.keyword) &&
                matchesCamera(asset, cameraContains: activeFilter.cameraContains) &&
                matchesLens(asset, lensContains: activeFilter.lensContains) &&
                matchesGeotagging(asset, geotaggedOnly: activeFilter.geotaggedOnly) &&
                matchesCapturedAfter(asset, capturedAfter: activeFilter.capturedAfter) &&
                matchesCapturedBefore(asset, capturedBefore: activeFilter.capturedBefore) &&
                matchesLocation(asset, filter: activeFilter) &&
                matchesAlbum(asset, albumID: activeFilter.albumID) &&
                matchesLibraryFolder(asset, folderURL: selectedFolderURL)
            }
            .sorted(by: libraryAssetComparator)
    }

    private func mergedLibraryFolders(with newFolderURLs: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return (libraryFolderURLs + newFolderURLs)
            .map(\.standardizedFileURL)
            .filter { seenPaths.insert($0.path).inserted }
    }

    private func replaceAsset(_ asset: Asset) {
        let selectedAssetToReplace = selectedAssets.first(where: { $0.sourcePath == asset.sourcePath })
        replaceAsset(in: &libraryAssets, with: asset)
        replaceAsset(in: &assets, with: asset)

        if selectedAssetIDs.contains(asset.id) == false,
           let selectedAssetToReplace {
            selectedAssetIDs.remove(selectedAssetToReplace.id)
            selectedAssetIDs.insert(asset.id)
            if selectionAnchorAssetID == selectedAssetToReplace.id {
                selectionAnchorAssetID = asset.id
            }
        }

        rebuildAssetIndex()
    }

    private func replaceAsset(in targetAssets: inout [Asset], with asset: Asset) {
        guard let index = targetAssets.firstIndex(where: { $0.sourcePath == asset.sourcePath }) else { return }
        targetAssets[index] = asset
    }

    private func refreshPersistedAssets(withIDs assetIDs: [UUID]) throws {
        for assetID in Set(assetIDs) {
            guard let persistedAsset = try environment.catalogStore.fetchAsset(id: assetID) else { continue }
            replaceAsset(persistedAsset)
        }
        try reload()
    }

    private func removeLibraryFolders(_ folderURLsToRemove: [URL]) {
        let removalPaths = Set(folderURLsToRemove.map { $0.standardizedFileURL.path })
        guard !removalPaths.isEmpty else { return }

        do {
            libraryFolderURLs.removeAll { removalPaths.contains($0.standardizedFileURL.path) }
            if let selectedLibraryFolderURL,
               removalPaths.contains(selectedLibraryFolderURL.standardizedFileURL.path) {
                self.selectedLibraryFolderURL = nil
            }
            try environment.libraryReferences.saveReferencedFolderURLs(libraryFolderURLs)
            try reloadLibrary()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func reconcileSelectedLibraryFolder() {
        if let selectedLibraryFolderURL {
            let availablePaths = Set(libraryFolderURLs.map { $0.standardizedFileURL.path })
            if availablePaths.contains(selectedLibraryFolderURL.standardizedFileURL.path) == false {
                self.selectedLibraryFolderURL = nil
            }
        }
    }

    private func libraryAssetComparator(lhs: Asset, rhs: Asset) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate > rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.importedAt != rhs.importedAt {
                return lhs.importedAt > rhs.importedAt
            }
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.sourcePath.localizedStandardCompare(rhs.sourcePath) == .orderedAscending
        }
    }

    private func matchesSearchText(_ asset: Asset, searchText: String) -> Bool {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedSearchText.isEmpty else { return true }
        let candidates: [String] = [
            asset.sourcePath,
            asset.cameraMake ?? "",
            asset.cameraModel ?? "",
            asset.lensModel ?? "",
            asset.keywords.joined(separator: " "),
        ]
        return candidates.map { $0.lowercased() }.contains { $0.contains(trimmedSearchText) }
    }

    private func matchesMinimumRating(_ asset: Asset, minimumRating: Int?) -> Bool {
        guard let minimumRating else { return true }
        return asset.rating >= minimumRating
    }

    private func matchesFlag(_ asset: Asset, flaggedOnly: Bool) -> Bool {
        !flaggedOnly || asset.flag == .picked
    }

    private func matchesKeyword(_ asset: Asset, keyword: String?) -> Bool {
        guard let keyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !keyword.isEmpty else {
            return true
        }
        return asset.keywords.contains { $0.lowercased().contains(keyword) }
    }

    private func matchesCamera(_ asset: Asset, cameraContains: String?) -> Bool {
        guard let cameraContains = cameraContains?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !cameraContains.isEmpty else {
            return true
        }
        return [asset.cameraMake, asset.cameraModel]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(cameraContains) }
    }

    private func matchesLens(_ asset: Asset, lensContains: String?) -> Bool {
        guard let lensContains = lensContains?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !lensContains.isEmpty else {
            return true
        }
        return asset.lensModel?.lowercased().contains(lensContains) ?? false
    }

    private func matchesGeotagging(_ asset: Asset, geotaggedOnly: Bool) -> Bool {
        !geotaggedOnly || asset.gpsCoordinate != nil
    }

    private func matchesCapturedAfter(_ asset: Asset, capturedAfter: Date?) -> Bool {
        guard let capturedAfter else { return true }
        guard let captureDate = asset.captureDate else { return false }
        return captureDate >= capturedAfter
    }

    private func matchesCapturedBefore(_ asset: Asset, capturedBefore: Date?) -> Bool {
        guard let capturedBefore else { return true }
        guard let captureDate = asset.captureDate else { return false }
        return captureDate <= capturedBefore
    }

    private func matchesLocation(_ asset: Asset, filter: AssetFilter) -> Bool {
        guard
            let latitude = filter.locationLatitude,
            let longitude = filter.locationLongitude,
            let radiusKilometers = filter.locationRadiusKilometers,
            radiusKilometers > 0
        else {
            return true
        }

        guard let coordinate = asset.gpsCoordinate else { return false }
        let target = CLLocation(latitude: latitude, longitude: longitude)
        let assetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return target.distance(from: assetLocation) <= radiusKilometers * 1_000
    }

    private func matchesAlbum(_ asset: Asset, albumID: UUID?) -> Bool {
        guard let albumID else { return true }
        return asset.albumIDs.contains(albumID)
    }

    private func matchesLibraryFolder(_ asset: Asset, folderURL: URL?) -> Bool {
        guard let folderURL else { return true }
        let folderPath = folderURL.standardizedFileURL.path
        let assetPath = URL(fileURLWithPath: asset.sourcePath).standardizedFileURL.path
        return assetPath == folderPath || assetPath.hasPrefix(folderPath + "/")
    }

    private func selectionMetricLabel(for intent: LibrarySelectionIntent) -> String {
        switch intent {
        case .replace:
            "replace"
        case .toggle:
            "toggle"
        case .extendRange:
            "range"
        case .clear:
            "clear"
        }
    }
}

enum AppPerformanceMetrics {
    private static let logger = Logger(subsystem: "com.speng.lapis", category: "Performance")

    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment

        if arguments.contains("-LAPIS_PERF_LOGS") {
            return true
        }

        guard let rawValue = environment["LAPIS_PERF_LOGS"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return rawValue == "1" || rawValue == "true" || rawValue == "yes"
    }

    struct Span {
        let label: String
        let startNanos: UInt64
        let details: String
    }

    static func begin(_ label: String, details: String = "") -> Span? {
        guard isEnabled else { return nil }
        return Span(label: label, startNanos: DispatchTime.now().uptimeNanoseconds, details: details)
    }

    static func end(_ span: Span?, details: String = "") {
        guard let span else { return }
        let elapsed = milliseconds(since: span.startNanos)
        let mergedDetails = [span.details, details]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let message = mergedDetails.isEmpty
            ? "elapsed_ms=\(format(elapsed))"
            : "\(mergedDetails) elapsed_ms=\(format(elapsed))"
        emit("\(span.label) \(message)")
    }

    static func event(_ label: String, details: String = "") {
        guard isEnabled else { return }
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDetails.isEmpty {
            emit(label)
        } else {
            emit("\(label) \(trimmedDetails)")
        }
    }

    static func milliseconds(since startNanos: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000
    }

    static func format(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }

    private static func emit(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        NSLog("%@", "[LapisPerf] \(message)")
    }
}
