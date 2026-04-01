import AppKit
import Foundation
import LapisCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    enum WorkspaceMode: String, CaseIterable, Identifiable {
        case library
        case edit

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
    var showOriginalInEditor = false
    var filter = AssetFilter.default
    var importSummary = ""
    var statusMessage = ""
    var gpxTimezoneOffsetMinutes = 0
    var gpxCameraClockOffsetSeconds = 0
    var albumNameDraft = ""

    init(environment: AppEnvironment) throws {
        self.environment = environment
        try reload()
    }

    var selectedAssets: [Asset] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }

    var geotaggedAssets: [Asset] {
        assets.filter { $0.gpsCoordinate != nil }
    }

    var selectedAsset: Asset? {
        guard selectedAssetIDs.count == 1 else { return nil }
        return selectedAssets.first
    }

    var compareAssets: [Asset] {
        Array(selectedAssets.prefix(2))
    }

    func reload() throws {
        var activeFilter = filter
        activeFilter.albumID = selectedAlbumID
        assets = try environment.catalogStore.fetchAssets(filter: activeFilter)
        albums = try environment.catalogStore.fetchAlbums()
        selectedAssetIDs = selectedAssetIDs.intersection(Set(assets.map(\.id)))
    }

    func importFolders() {
        let panel = NSOpenPanel()
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        do {
            var totals = ImportJob()
            for folder in panel.urls {
                let job = try environment.importer.importFolder(folder, into: environment.catalogStore)
                totals.importedCount += job.importedCount
                totals.duplicateCount += job.duplicateCount
                totals.skippedCount += job.skippedCount
                totals.failures.append(contentsOf: job.failures)
            }
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
            let track = try environment.gpxParser.parse(data: data)
            let targetAssets = try gpxCandidateAssets()
            let matches = environment.geotagMatcher.match(
                assets: targetAssets,
                track: track,
                timezoneOffsetMinutes: gpxTimezoneOffsetMinutes,
                cameraClockOffsetSeconds: gpxCameraClockOffsetSeconds
            )
            let applied = try environment.catalogStore.geotagAssets(matches)
            statusMessage = "Applied GPX tags to \(applied) of \(targetAssets.count) candidate photos"
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
            try environment.catalogStore.saveDevelopSettings(assetID: asset.id, settings: asset.developSettings)
            try regeneratePreview(for: asset, settings: asset.developSettings)
            showOriginalInEditor = false
            try reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func resetSelectedAssetDevelopSettings() {
        guard let asset = selectedAsset else { return }
        do {
            try environment.catalogStore.saveDevelopSettings(assetID: asset.id, settings: .default)
            try regeneratePreview(for: asset, settings: .default)
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
            let url = try environment.writebackService.writeXMPSidecar(for: asset)
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

    private func gpxCandidateAssets() throws -> [Asset] {
        if !selectedAssetIDs.isEmpty {
            return selectedAssets
        }

        var scopeFilter = AssetFilter.default
        scopeFilter.albumID = selectedAlbumID
        return try environment.catalogStore.fetchAssets(filter: scopeFilter)
    }

    private func regeneratePreview(for asset: Asset, settings: DevelopSettings) throws {
        do {
            let rendered = try environment.renderer.renderImage(
                from: URL(fileURLWithPath: asset.sourcePath),
                settings: settings,
                maxPixelSize: 2048
            )
            let previewURL = try environment.previewService.cachePreview(named: asset.id.uuidString, image: rendered)
            try environment.catalogStore.updatePreview(
                assetID: asset.id,
                previewPath: previewURL.path(percentEncoded: false),
                status: .ready
            )
        } catch {
            try? environment.catalogStore.updatePreview(assetID: asset.id, previewPath: nil, status: .failed)
            throw error
        }
    }

    func applyEditorCommit(assetID: UUID, settings: DevelopSettings, previewPath: String?) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        assets[index].developSettings = settings
        if let previewPath {
            assets[index].previewPath = previewPath
            assets[index].previewStatus = .ready
        }
    }
}
