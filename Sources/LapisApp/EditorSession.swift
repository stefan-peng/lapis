import CoreImage
import Foundation
import LapisCore
import Observation
import SwiftUI

@MainActor
@Observable
final class EditorSession {
    enum ZoomMode: String, CaseIterable, Identifiable {
        case fit
        case actualPixels

        var id: String { rawValue }
    }

    weak var state: AppState?
    let assetID: UUID
    let sourcePath: String
    let renderer: CoreImageDevelopRenderer
    private let catalogStore: GRDBCatalogStore
    private let previewService: PreviewService

    var committedSettings: DevelopSettings
    var currentSettings: DevelopSettings
    var showOriginal = false
    var zoomMode: ZoomMode = .fit
    var panOffset: CGSize = .zero
    var isPersisting = false
    var lastError = ""

    private var saveTask: Task<Void, Never>?
    private var latestSaveID = UUID()

    init(state: AppState, asset: Asset) {
        self.state = state
        assetID = asset.id
        sourcePath = asset.sourcePath
        renderer = state.environment.renderer
        catalogStore = state.environment.catalogStore
        previewService = state.environment.previewService
        committedSettings = asset.developSettings
        currentSettings = asset.developSettings
    }

    func update(_ transform: (inout DevelopSettings) -> Void) {
        transform(&currentSettings)
        clampSettings()
        schedulePersistence()
    }

    func resetAll() {
        currentSettings = .default
        schedulePersistence()
    }

    func reset(_ keyPath: WritableKeyPath<DevelopSettings, Double>) {
        currentSettings[keyPath: keyPath] = DevelopSettings.default[keyPath: keyPath]
        schedulePersistence()
    }

    func applyAutoEnhance() {
        do {
            let preservedLumaNoiseReductionAmount = currentSettings.luminanceNoiseReductionAmount
            let preservedChromaNoiseReductionAmount = currentSettings.chrominanceNoiseReductionAmount
            currentSettings = try renderer.suggestedSettings(
                for: URL(fileURLWithPath: sourcePath),
                current: currentSettings
            )
            currentSettings.luminanceNoiseReductionAmount = preservedLumaNoiseReductionAmount
            currentSettings.chrominanceNoiseReductionAmount = preservedChromaNoiseReductionAmount
            schedulePersistence()
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
        }
    }

    func applyAuto(_ control: AutoAdjustmentControl) {
        do {
            let value = try renderer.suggestedValue(
                for: control,
                fileURL: URL(fileURLWithPath: sourcePath),
                current: currentSettings
            )
            switch control {
            case .exposure:
                currentSettings.exposure = value
            case .highlights:
                currentSettings.highlights = value
            case .shadows:
                currentSettings.shadows = value
            case .whites:
                currentSettings.whites = value
            case .blacks:
                currentSettings.blacks = value
            case .vibrance:
                currentSettings.vibrance = value
            }
            schedulePersistence()
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
        }
    }

    func applyAutoOptics() {
        do {
            let analysis = try renderer.analysis(for: URL(fileURLWithPath: sourcePath))
            currentSettings.lensCorrectionAmount = analysis.lensCorrectionSuggested ? 1 : 0
            currentSettings.vignetteCorrectionAmount = max(currentSettings.vignetteCorrectionAmount, 0.25)
            schedulePersistence()
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
        }
    }

    func setCropRect(_ rect: CropRect) {
        currentSettings.cropRect = clampedCropRect(rect)
        schedulePersistence()
    }

    func resetCrop() {
        currentSettings.cropRect = .fullFrame
        schedulePersistence()
    }

    func flushPendingEdits() {
        saveTask?.cancel()
        persist(settings: currentSettings, saveID: beginPersistence())
    }

    func previewImage(maxPixelSize: Int?) -> CIImage? {
        do {
            var previewSettings = currentSettings
            previewSettings.cropRect = .fullFrame
            return try renderer.previewImage(
                from: URL(fileURLWithPath: sourcePath),
                settings: showOriginal ? .default : previewSettings,
                maxPixelSize: maxPixelSize
            )
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
            return nil
        }
    }

    func setZoomMode(_ zoomMode: ZoomMode) {
        self.zoomMode = zoomMode
        if zoomMode == .fit {
            panOffset = .zero
        }
    }

    func pan(by translation: CGSize, in containerSize: CGSize, imageExtent: CGRect) {
        pan(from: .zero, by: translation, in: containerSize, imageExtent: imageExtent)
    }

    func pan(from baseOffset: CGSize, by translation: CGSize, in containerSize: CGSize, imageExtent: CGRect) {
        guard zoomMode == .actualPixels else {
            panOffset = .zero
            return
        }

        let allowedX = max((imageExtent.width - containerSize.width) / 2, 0)
        let allowedY = max((imageExtent.height - containerSize.height) / 2, 0)
        panOffset = CGSize(
            width: min(max(baseOffset.width + translation.width, -allowedX), allowedX),
            height: min(max(baseOffset.height + translation.height, -allowedY), allowedY)
        )
    }

    private func schedulePersistence() {
        isPersisting = true
        saveTask?.cancel()
        let settings = currentSettings
        let saveID = beginPersistence()
        saveTask = Task.detached(priority: .utility) { [catalogStore, previewService, renderer, sourcePath, assetID, weak state, weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                try catalogStore.saveDevelopSettings(assetID: assetID, settings: settings)
                guard await Self.isCurrentSave(saveID, session: self), !Task.isCancelled else { return }
                let rendered = try renderer.renderImage(
                    from: URL(fileURLWithPath: sourcePath),
                    settings: settings,
                    maxPixelSize: 2048
                )
                guard await Self.isCurrentSave(saveID, session: self), !Task.isCancelled else { return }
                let previewURL = try previewService.cachePreview(named: assetID.uuidString, image: rendered)
                guard await Self.isCurrentSave(saveID, session: self), !Task.isCancelled else { return }
                try catalogStore.updatePreview(
                    assetID: assetID,
                    previewPath: previewURL.path(percentEncoded: false),
                    status: .ready
                )
                await MainActor.run {
                    guard self?.latestSaveID == saveID else { return }
                    state?.applyEditorCommit(
                        assetID: assetID,
                        settings: settings,
                        previewPath: previewURL.path(percentEncoded: false)
                    )
                    self?.committedSettings = settings
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    state?.statusMessage = error.localizedDescription
                    self?.lastError = error.localizedDescription
                }
            }

            await MainActor.run {
                guard self?.latestSaveID == saveID else { return }
                self?.isPersisting = false
            }
        }
    }

    private func persist(settings: DevelopSettings, saveID: UUID) {
        isPersisting = true
        Task.detached(priority: .utility) { [catalogStore, previewService, renderer, sourcePath, assetID, weak state, weak self] in
            do {
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                try catalogStore.saveDevelopSettings(assetID: assetID, settings: settings)
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                let rendered = try renderer.renderImage(
                    from: URL(fileURLWithPath: sourcePath),
                    settings: settings,
                    maxPixelSize: 2048
                )
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                let previewURL = try previewService.cachePreview(named: assetID.uuidString, image: rendered)
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                try catalogStore.updatePreview(
                    assetID: assetID,
                    previewPath: previewURL.path(percentEncoded: false),
                    status: .ready
                )
                await MainActor.run {
                    guard self?.latestSaveID == saveID else { return }
                    state?.applyEditorCommit(
                        assetID: assetID,
                        settings: settings,
                        previewPath: previewURL.path(percentEncoded: false)
                    )
                    self?.committedSettings = settings
                    self?.isPersisting = false
                }
            } catch {
                await MainActor.run {
                    state?.statusMessage = error.localizedDescription
                    self?.lastError = error.localizedDescription
                    self?.isPersisting = false
                }
            }
        }
    }

    private func clampSettings() {
        currentSettings.cropRect = clampedCropRect(currentSettings.cropRect)
    }

    private func beginPersistence() -> UUID {
        let saveID = UUID()
        latestSaveID = saveID
        return saveID
    }

    private static func isCurrentSave(_ saveID: UUID, session: EditorSession?) async -> Bool {
        await MainActor.run {
            session?.latestSaveID == saveID
        }
    }

    private func clampedCropRect(_ rect: CropRect) -> CropRect {
        let width = min(max(rect.width, 0.05), 1)
        let height = min(max(rect.height, 0.05), 1)
        let x = min(max(rect.x, 0), 1 - width)
        let y = min(max(rect.y, 0), 1 - height)
        return CropRect(x: x, y: y, width: width, height: height)
    }
}
