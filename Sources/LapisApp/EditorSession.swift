import CoreImage
import Foundation
import LapisCore
import Observation
import SwiftUI

enum CropAspectRatioPreset: String, CaseIterable, Identifiable {
    case freeform
    case square
    case portrait
    case landscape
    case widescreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .freeform: "Freeform"
        case .square: "1:1"
        case .portrait: "4:5"
        case .landscape: "3:2"
        case .widescreen: "16:9"
        }
    }

    var size: CGSize? {
        switch self {
        case .freeform: nil
        case .square: CGSize(width: 1, height: 1)
        case .portrait: CGSize(width: 4, height: 5)
        case .landscape: CGSize(width: 3, height: 2)
        case .widescreen: CGSize(width: 16, height: 9)
        }
    }

    func adjustedRect(from rect: CropRect) -> CropRect {
        guard let size else { return rect }
        let ratio = size.width / size.height
        let centerX = rect.x + (rect.width / 2)
        let centerY = rect.y + (rect.height / 2)
        var width = min(rect.width, 1)
        var height = width / ratio
        if height > 1 {
            height = 1
            width = height * ratio
        }
        return CropRect(
            x: min(max(centerX - (width / 2), 0), 1 - width),
            y: min(max(centerY - (height / 2), 0), 1 - height),
            width: width,
            height: height
        )
    }
}

@MainActor
@Observable
final class EditorSession {
    private struct PreviewRenderSignature: Equatable {
        let settings: DevelopSettings
        let maxPixelSize: Int?
    }

    enum ToolMode: String, CaseIterable, Identifiable {
        case adjust
        case crop

        var id: String { rawValue }
    }

    weak var state: AppState?
    let assetID: UUID
    let sourcePath: String
    let developProcessor: any DevelopProcessing
    let interactiveRenderContext: CIContext
    let sourcePixelSize: CGSize
    private let assetEditor: any AssetEditing

    var committedSettings: DevelopSettings
    var currentSettings: DevelopSettings
    var showOriginal = false
    var toolMode: ToolMode = .adjust
    var cropAspectRatio: CropAspectRatioPreset = .freeform
    var zoomScale: Double?
    var panOffset: CGSize = .zero
    var viewportSize: CGSize = .zero
    var displayImage: CIImage?
    var isPersisting = false
    var isRenderingPreview = false
    var lastError = ""

    private var saveTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var latestSaveID = UUID()
    private var latestRenderID = UUID()
    private var lastRenderedPreviewSignature: PreviewRenderSignature?

    init(state: AppState, asset: Asset) {
        self.state = state
        assetID = asset.id
        sourcePath = asset.sourcePath
        developProcessor = state.environment.developProcessor
        interactiveRenderContext = state.environment.developProcessor.interactiveContext
        sourcePixelSize = CGSize(width: max(asset.pixelWidth, 1), height: max(asset.pixelHeight, 1))
        assetEditor = state.environment.assetEditor
        committedSettings = asset.developSettings
        self.currentSettings = asset.developSettings
        displayImage = Self.bootstrapPreviewImage(previewPath: asset.previewPath)
        AppPerformanceMetrics.event(
            "editor.session.bootstrap",
            details: "asset=\(asset.id.uuidString) previewCached=\(displayImage != nil)"
        )
    }

    func flushPendingEdits() {
        saveTask?.cancel()
        renderTask?.cancel()
        isRenderingPreview = false
        guard currentSettings != committedSettings || isPersisting else {
            isPersisting = false
            return
        }
        persist(settings: currentSettings, saveID: beginPersistence())
    }

    var isFitZoom: Bool {
        zoomScale == nil
    }

    var zoomLabel: String {
        if let zoomScale {
            "\(Int((zoomScale * 100).rounded()))%"
        } else {
            "Fit"
        }
    }

    func update(_ transform: (inout DevelopSettings) -> Void) {
        transform(&currentSettings)
        clampSettings()
        queuePreviewRender(reason: "adjustment")
        schedulePersistence()
    }

    func resetAll() {
        currentSettings = .default
        queuePreviewRender(reason: "resetAll")
        schedulePersistence()
    }

    func reset(_ keyPath: WritableKeyPath<DevelopSettings, Double>) {
        currentSettings[keyPath: keyPath] = DevelopSettings.default[keyPath: keyPath]
        queuePreviewRender(reason: "resetControl")
        schedulePersistence()
    }

    func applyAutoEnhance() {
        do {
            let preservedLumaNoiseReductionAmount = currentSettings.luminanceNoiseReductionAmount
            let preservedChromaNoiseReductionAmount = currentSettings.chrominanceNoiseReductionAmount
            currentSettings = try developProcessor.suggestedSettings(
                for: URL(fileURLWithPath: sourcePath),
                current: currentSettings
            )
            currentSettings.luminanceNoiseReductionAmount = preservedLumaNoiseReductionAmount
            currentSettings.chrominanceNoiseReductionAmount = preservedChromaNoiseReductionAmount
            queuePreviewRender(reason: "autoEnhance")
            schedulePersistence()
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
        }
    }

    func applyAuto(_ control: AutoAdjustmentControl) {
        do {
            let value = try developProcessor.suggestedValue(
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
            queuePreviewRender(reason: "autoControl")
            schedulePersistence()
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
        }
    }

    func applyAutoOptics() {
        do {
            let analysis = try developProcessor.analysis(for: URL(fileURLWithPath: sourcePath))
            currentSettings.lensCorrectionAmount = analysis.lensCorrectionSuggested ? 1 : 0
            currentSettings.vignetteCorrectionAmount = max(currentSettings.vignetteCorrectionAmount, 0.25)
            queuePreviewRender(reason: "autoOptics")
            schedulePersistence()
        } catch {
            lastError = error.localizedDescription
            state?.statusMessage = error.localizedDescription
        }
    }

    func setCropRect(_ rect: CropRect) {
        currentSettings.cropRect = clampedCropRect(rect)
        if toolMode == .adjust {
            queuePreviewRender(reason: "cropRect")
        }
        schedulePersistence()
    }

    func resetCrop() {
        currentSettings.cropRect = .fullFrame
        if toolMode == .adjust {
            queuePreviewRender(reason: "resetCrop")
        }
        schedulePersistence()
    }

    func setToolMode(_ toolMode: ToolMode) {
        guard self.toolMode != toolMode else { return }
        self.toolMode = toolMode
        panOffset = .zero
        queuePreviewRender(delayMilliseconds: 0, reason: "toolMode")
    }

    func setShowOriginal(_ isShowingOriginal: Bool) {
        guard showOriginal != isShowingOriginal else { return }
        showOriginal = isShowingOriginal
        queuePreviewRender(delayMilliseconds: 0, reason: "showOriginal")
    }

    func updateViewportSize(_ viewportSize: CGSize) {
        guard abs(self.viewportSize.width - viewportSize.width) > 1 || abs(self.viewportSize.height - viewportSize.height) > 1 else {
            return
        }
        self.viewportSize = viewportSize

        let previewSettings = displayPreviewSettings()
        let previewSignature = PreviewRenderSignature(
            settings: previewSettings,
            maxPixelSize: requestedPreviewPixelSize(for: previewSettings)
        )
        if displayImage != nil, previewSignature == lastRenderedPreviewSignature {
            return
        }

        queuePreviewRender(delayMilliseconds: 0, reason: "viewport")
    }

    func setFitZoom() {
        zoomScale = nil
        panOffset = .zero
    }

    func setActualPixelsZoom() {
        zoomScale = 1
        panOffset = .zero
    }

    func toggleFitZoom() {
        if zoomScale == nil {
            setActualPixelsZoom()
        } else {
            setFitZoom()
        }
    }

    func stepZoomIn(at location: CGPoint? = nil, in containerSize: CGSize, imageExtent: CGRect? = nil) {
        zoom(by: 1.25, at: location, in: containerSize, imageExtent: imageExtent ?? currentImageExtent)
    }

    func stepZoomOut(at location: CGPoint? = nil, in containerSize: CGSize, imageExtent: CGRect? = nil) {
        zoom(by: 0.8, at: location, in: containerSize, imageExtent: imageExtent ?? currentImageExtent)
    }

    func zoomByScroll(deltaY: CGFloat, at location: CGPoint, in containerSize: CGSize, imageExtent: CGRect) {
        let factor = pow(1.0015, Double(deltaY * 10))
        zoom(by: factor, at: location, in: containerSize, imageExtent: imageExtent)
    }

    func zoomByMagnification(_ magnification: CGFloat, at location: CGPoint, in containerSize: CGSize, imageExtent: CGRect) {
        zoom(by: Double(1 + magnification), at: location, in: containerSize, imageExtent: imageExtent)
    }

    func pan(from baseOffset: CGSize, by translation: CGSize, in containerSize: CGSize, imageExtent: CGRect) {
        guard canPan(in: containerSize, imageExtent: imageExtent) else {
            panOffset = .zero
            return
        }

        let scale = resolvedScale(for: containerSize, imageExtent: imageExtent)
        let drawSize = CGSize(width: imageExtent.width * scale, height: imageExtent.height * scale)
        let allowedX = max((drawSize.width - containerSize.width) / 2, 0)
        let allowedY = max((drawSize.height - containerSize.height) / 2, 0)
        panOffset = CGSize(
            width: min(max(baseOffset.width + translation.width, -allowedX), allowedX),
            height: min(max(baseOffset.height + translation.height, -allowedY), allowedY)
        )
    }

    func canPan(in containerSize: CGSize, imageExtent: CGRect) -> Bool {
        resolvedScale(for: containerSize, imageExtent: imageExtent) > fitScale(for: containerSize, imageExtent: imageExtent) + 0.001
    }

    func displayPreviewSettings() -> DevelopSettings {
        var previewSettings = showOriginal ? .default : currentSettings
        if toolMode == .crop {
            previewSettings.cropRect = .fullFrame
        }
        return previewSettings
    }

    var currentImageExtent: CGRect {
        displayImage?.extent ?? CGRect(origin: .zero, size: sourcePixelSize)
    }

    private func zoom(by factor: Double, at location: CGPoint?, in containerSize: CGSize, imageExtent: CGRect) {
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let previousScale = resolvedScale(for: containerSize, imageExtent: imageExtent)
        let requestedScale = clampedZoomScale((zoomScale ?? fitScale(for: containerSize, imageExtent: imageExtent)) * factor)
        zoomScale = abs(requestedScale - fitScale(for: containerSize, imageExtent: imageExtent)) < 0.01 ? nil : requestedScale

        let nextScale = resolvedScale(for: containerSize, imageExtent: imageExtent)
        guard let location else {
            panOffset = clampedPanOffset(panOffset, in: containerSize, imageExtent: imageExtent, scale: nextScale)
            return
        }

        let previousRect = fittedImageRect(
            imageExtent: imageExtent,
            containerSize: containerSize,
            zoomScale: previousScale,
            panOffset: panOffset
        )
        let newDrawSize = CGSize(width: imageExtent.width * nextScale, height: imageExtent.height * nextScale)
        let normalizedX = previousRect.width > 0 ? (location.x - previousRect.minX) / previousRect.width : 0.5
        let normalizedY = previousRect.height > 0 ? (location.y - previousRect.minY) / previousRect.height : 0.5
        let centeredOrigin = CGPoint(
            x: (containerSize.width - newDrawSize.width) / 2,
            y: (containerSize.height - newDrawSize.height) / 2
        )
        let proposedPan = CGSize(
            width: location.x - (normalizedX * newDrawSize.width) - centeredOrigin.x,
            height: location.y - (normalizedY * newDrawSize.height) - centeredOrigin.y
        )
        panOffset = clampedPanOffset(proposedPan, in: containerSize, imageExtent: imageExtent, scale: nextScale)
    }

    private func queuePreviewRender(delayMilliseconds: UInt64 = 80, reason: String = "adjustment") {
        let renderID = UUID()
        latestRenderID = renderID
        isRenderingPreview = true
        renderTask?.cancel()
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let settings = displayPreviewSettings()
        let maxPixelSize = requestedPreviewPixelSize(for: settings)
        let previewSignature = PreviewRenderSignature(settings: settings, maxPixelSize: maxPixelSize)
        let developProcessor = self.developProcessor

        renderTask = Task.detached(priority: .userInitiated) { [developProcessor, weak self, weak state] in
            do {
                if delayMilliseconds > 0 {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                }
                if Task.isCancelled { return }
                let image = try developProcessor.previewImage(from: sourceURL, settings: settings, maxPixelSize: maxPixelSize)
                let elapsed = AppPerformanceMetrics.format(AppPerformanceMetrics.milliseconds(since: requestStartedAt))
                await MainActor.run {
                    guard self?.latestRenderID == renderID else { return }
                    self?.displayImage = image
                    self?.lastRenderedPreviewSignature = previewSignature
                    self?.isRenderingPreview = false
                    AppPerformanceMetrics.event(
                        "editor.preview.render",
                        details: "reason=\(reason) maxPixel=\(maxPixelSize ?? 0) status=ready elapsed_ms=\(elapsed)"
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                let elapsed = AppPerformanceMetrics.format(AppPerformanceMetrics.milliseconds(since: requestStartedAt))
                await MainActor.run {
                    guard self?.latestRenderID == renderID else { return }
                    self?.displayImage = nil
                    self?.lastRenderedPreviewSignature = nil
                    self?.isRenderingPreview = false
                    self?.lastError = error.localizedDescription
                    state?.statusMessage = error.localizedDescription
                    AppPerformanceMetrics.event(
                        "editor.preview.render",
                        details: "reason=\(reason) maxPixel=\(maxPixelSize ?? 0) status=failed elapsed_ms=\(elapsed)"
                    )
                }
            }
        }
    }

    private func requestedPreviewPixelSize(for settings: DevelopSettings) -> Int? {
        let viewportMax = max(viewportSize.width, viewportSize.height)
        guard viewportMax > 0 else { return 2048 }

        let imageExtent = CGRect(origin: .zero, size: sourcePixelSize)
        let scale = resolvedScale(for: viewportSize, imageExtent: imageExtent)
        let requested = Int((viewportMax * max(scale, 1) * 2).rounded(.up))
        let sourceMaxDimension = Int(max(sourcePixelSize.width, sourcePixelSize.height))
        return min(max(requested, 2048), max(sourceMaxDimension, 2048))
    }

    private func resolvedScale(for containerSize: CGSize, imageExtent: CGRect) -> Double {
        guard let zoomScale else {
            return fitScale(for: containerSize, imageExtent: imageExtent)
        }
        return clampedZoomScale(zoomScale)
    }

    private func fitScale(for containerSize: CGSize, imageExtent: CGRect) -> Double {
        guard imageExtent.width > 0, imageExtent.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return 1
        }
        return min(containerSize.width / imageExtent.width, containerSize.height / imageExtent.height)
    }

    private func clampedZoomScale(_ zoomScale: Double) -> Double {
        min(max(zoomScale, 0.25), 8)
    }

    private func clampedPanOffset(_ proposedPan: CGSize, in containerSize: CGSize, imageExtent: CGRect, scale: Double) -> CGSize {
        let drawSize = CGSize(width: imageExtent.width * scale, height: imageExtent.height * scale)
        let allowedX = max((drawSize.width - containerSize.width) / 2, 0)
        let allowedY = max((drawSize.height - containerSize.height) / 2, 0)
        return CGSize(
            width: min(max(proposedPan.width, -allowedX), allowedX),
            height: min(max(proposedPan.height, -allowedY), allowedY)
        )
    }

    private func schedulePersistence() {
        isPersisting = true
        saveTask?.cancel()
        let settings = currentSettings
        let saveID = beginPersistence()
        let request = makeEditRequest(settings: settings)
        let assetEditor = self.assetEditor
        saveTask = Task.detached(priority: .utility) { [assetEditor, weak state, weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                let result = try assetEditor.commit(request)
                guard await Self.isCurrentSave(saveID, session: self), !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.latestSaveID == saveID else { return }
                    state?.applyEditorCommit(
                        assetID: request.assetID,
                        settings: result.settings,
                        previewPath: result.previewPath,
                        previewStatus: result.previewStatus
                    )
                    self?.committedSettings = result.settings
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
        let request = makeEditRequest(settings: settings)
        let assetEditor = self.assetEditor
        Task.detached(priority: .utility) { [assetEditor, weak state, weak self] in
            do {
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                let result = try assetEditor.commit(request)
                guard await Self.isCurrentSave(saveID, session: self) else { return }
                await MainActor.run {
                    guard self?.latestSaveID == saveID else { return }
                    state?.applyEditorCommit(
                        assetID: request.assetID,
                        settings: result.settings,
                        previewPath: result.previewPath,
                        previewStatus: result.previewStatus
                    )
                    self?.committedSettings = result.settings
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

    private func makeEditRequest(settings: DevelopSettings) -> AssetEditRequest {
        AssetEditRequest(
            assetID: assetID,
            sourcePath: sourcePath,
            settings: settings,
            previewIdentifier: assetID.uuidString
        )
    }

    private func clampedCropRect(_ rect: CropRect) -> CropRect {
        let width = min(max(rect.width, 0.05), 1)
        let height = min(max(rect.height, 0.05), 1)
        let x = min(max(rect.x, 0), 1 - width)
        let y = min(max(rect.y, 0), 1 - height)
        return CropRect(x: x, y: y, width: width, height: height)
    }

    private static func bootstrapPreviewImage(previewPath: String?) -> CIImage? {
        guard let previewPath else { return nil }
        let url = URL(fileURLWithPath: previewPath)
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
}
