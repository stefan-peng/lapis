import AppKit
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
    var selectedAssetIDs: Set<UUID> = []
    var selectedAlbumID: UUID?
    var selectedExportPresetID: UUID = AppState.defaultExportPresets[0].id
    var exportPresets: [ExportPreset] = AppState.defaultExportPresets

    var workspaceMode: WorkspaceMode = .library
    var libraryDetailMode: LibraryDetailMode = .browse
    var showOriginalInEditor = false
    var filter = AssetFilter.default
    var importSummary = ""
    var statusMessage = ""
    var gpxTimezoneOffsetMinutes = 0
    var gpxCameraClockOffsetSeconds = 0
    var albumNameDraft = ""
    var selectionAnchorAssetID: UUID?

    private var assetIndexByID: [UUID: Int] = [:]
    private var pendingEditOpenStartNanos: UInt64?

    init(environment: AppEnvironment) throws {
        self.environment = environment
        try reload()
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
        var activeFilter = filter
        activeFilter.albumID = selectedAlbumID
        assets = try environment.catalogStore.fetchAssets(filter: activeFilter)
        rebuildAssetIndex()
        albums = try environment.catalogStore.fetchAlbums()
        applySelection(selectedAssetIDs.intersection(Set(assets.map(\.id))), anchor: selectionAnchorAssetID)
    }

    func importFolders() {
        let panel = NSOpenPanel()
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        do {
            let totals = try environment.importer.importFolders(panel.urls)
            importSummary = "Imported \(totals.importedCount), duplicates \(totals.duplicateCount), skipped \(totals.skippedCount)"
            statusMessage = importSummary
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importGPX() {
        let panel = NSOpenPanel()
        panel.prompt = "Apply GPX"
        panel.allowedContentTypes = [.xml] + [UTType(filenameExtension: "gpx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let targetAssets = try gpxCandidateAssets()
            let result = try environment.gpxService.applyGPX(
                data: data,
                to: targetAssets,
                timezoneOffsetMinutes: gpxTimezoneOffsetMinutes,
                cameraClockOffsetSeconds: gpxCameraClockOffsetSeconds
            )
            statusMessage = "Applied GPX tags to \(result.appliedCount) of \(result.candidateCount) candidate photos"
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func updateSelectedAssetMetadata(rating: Int? = nil, flag: AssetFlag? = nil, keywords: [String]? = nil) {
        guard let asset = selectedAsset else { return }
        do {
            try environment.catalogStore.updateMetadata(
                assetID: asset.id,
                rating: rating,
                flag: flag,
                keywords: keywords,
                gpsCoordinate: nil
            )
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func updateSelectedAssetDevelopSettings(_ transform: (inout DevelopSettings) -> Void) {
        guard var asset = selectedAsset else { return }
        transform(&asset.developSettings)
        do {
            let result = try environment.assetEditor.commit(
                AssetEditRequest(
                    assetID: asset.id,
                    sourcePath: asset.sourcePath,
                    settings: asset.developSettings,
                    previewIdentifier: asset.id.uuidString
                )
            )
            applyEditorCommit(
                assetID: asset.id,
                settings: result.settings,
                previewPath: result.previewPath,
                previewStatus: result.previewStatus
            )
            showOriginalInEditor = false
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resetSelectedAssetDevelopSettings() {
        guard let asset = selectedAsset else { return }
        do {
            let result = try environment.assetEditor.commit(
                AssetEditRequest(
                    assetID: asset.id,
                    sourcePath: asset.sourcePath,
                    settings: .default,
                    previewIdentifier: asset.id.uuidString
                )
            )
            applyEditorCommit(
                assetID: asset.id,
                settings: result.settings,
                previewPath: result.previewPath,
                previewStatus: result.previewStatus
            )
            showOriginalInEditor = false
            try reload()
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
        let ids = Array(selectedAssetIDs)
        guard !ids.isEmpty else { return }
        do {
            try environment.catalogStore.assignAssets(ids, to: album.id)
            statusMessage = "Added \(ids.count) photos to \(album.name)"
            try reload()
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

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            let report = try environment.exportService.export(assets: selection, preset: preset, destinationDirectory: destinationURL)
            if report.failures.isEmpty {
                statusMessage = "Exported \(report.exportedURLs.count) photo(s)"
            } else {
                statusMessage = "Exported \(report.exportedURLs.count) photo(s), \(report.failures.count) failed"
            }
        } catch {
            statusMessage = error.localizedDescription
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
        guard selectedAsset != nil else { return }
        pendingEditOpenStartNanos = DispatchTime.now().uptimeNanoseconds
        AppPerformanceMetrics.event("editor.open.requested", details: "selectedCount=\(selectedAssetIDs.count)")
        workspaceMode = .edit
        libraryDetailMode = .browse
    }

    func showLibrary() {
        workspaceMode = .library
    }

    private func gpxCandidateAssets() throws -> [Asset] {
        if !selectedAssetIDs.isEmpty {
            return selectedAssets
        }

        var scopeFilter = AssetFilter.default
        scopeFilter.albumID = selectedAlbumID
        return try environment.catalogStore.fetchAssets(filter: scopeFilter)
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
