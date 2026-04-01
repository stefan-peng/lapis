import AppKit
import LapisCore
import ImageIO
import MapKit
import CoreLocation
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @State private var showsInspector = true

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            contentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: inspectorPresented) {
            if let asset = state.selectedAsset {
                MetadataSidebarView(state: state, asset: asset)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
        }
        .navigationTitle("Lapis")
        .toolbar {
            ToolbarItemGroup {
                Picker("Mode", selection: $state.workspaceMode) {
                    ForEach(AppState.WorkspaceMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button("Import Folder", action: state.importFolders)
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Apply GPX", action: state.importGPX)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Export", action: state.exportSelection)
                    .keyboardShortcut("e", modifiers: [.command])
                Button("Write XMP", action: state.writeMetadataSidecar)
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button {
                    showsInspector.toggle()
                } label: {
                    Label(showsInspector ? "Hide Info" : "Show Info", systemImage: "sidebar.right")
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(state.selectedAsset == nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { showsInspector && state.selectedAsset != nil },
            set: { showsInspector = $0 }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Filters") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search", text: $state.filter.searchText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Keyword", text: Binding(
                        get: { state.filter.keyword ?? "" },
                        set: { state.filter.keyword = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Toggle("Picked only", isOn: $state.filter.flaggedOnly)
                    Toggle("Geotagged only", isOn: $state.filter.geotaggedOnly)
                    Stepper(
                        "Minimum rating: \(state.filter.minimumRating ?? 0)",
                        value: Binding(
                            get: { state.filter.minimumRating ?? 0 },
                            set: { state.filter.minimumRating = $0 == 0 ? nil : $0 }
                        ),
                        in: 0...5
                    )
                    TextField("Camera contains", text: Binding(
                        get: { state.filter.cameraContains ?? "" },
                        set: { state.filter.cameraContains = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Lens contains", text: Binding(
                        get: { state.filter.lensContains ?? "" },
                        set: { state.filter.lensContains = $0.isEmpty ? nil : $0 }
                    ))
                    optionalDateFilter(
                        title: "Captured After",
                        value: Binding(
                            get: { state.filter.capturedAfter },
                            set: { state.filter.capturedAfter = $0 }
                        )
                    )
                    optionalDateFilter(
                        title: "Captured Before",
                        value: Binding(
                            get: { state.filter.capturedBefore },
                            set: { state.filter.capturedBefore = $0 }
                        )
                    )
                }
                .onChange(of: state.filter.searchText) { _, _ in reload() }
                .onChange(of: state.filter.keyword) { _, _ in reload() }
                .onChange(of: state.filter.flaggedOnly) { _, _ in reload() }
                .onChange(of: state.filter.geotaggedOnly) { _, _ in reload() }
                .onChange(of: state.filter.minimumRating) { _, _ in reload() }
                .onChange(of: state.filter.cameraContains) { _, _ in reload() }
                .onChange(of: state.filter.lensContains) { _, _ in reload() }
                .onChange(of: state.filter.capturedAfter) { _, _ in reload() }
                .onChange(of: state.filter.capturedBefore) { _, _ in reload() }
            }

            GroupBox("Albums") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("All Photos") { state.selectAlbum(nil) }
                    ForEach(state.albums) { album in
                        Button(album.name) { state.selectAlbum(album.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(state.selectedAlbumID == album.id ? .primary : .secondary)
                    }
                    HStack {
                        TextField("New album", text: $state.albumNameDraft)
                        Button("Add", action: state.createAlbumFromDraft)
                    }
                }
            }

            GroupBox("GPX") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Timezone offset: \(state.gpxTimezoneOffsetMinutes) min", value: $state.gpxTimezoneOffsetMinutes, in: -720...720, step: 15)
                    Stepper("Camera offset: \(state.gpxCameraClockOffsetSeconds) sec", value: $state.gpxCameraClockOffsetSeconds, in: -43_200...43_200, step: 30)
                }
            }

            GroupBox("Export") {
                Picker("Preset", selection: $state.selectedExportPresetID) {
                    ForEach(state.exportPresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
            }
            Spacer()
        }
        .padding()
        .frame(minWidth: 250)
    }

    @ViewBuilder
    private var contentPane: some View {
        switch state.workspaceMode {
        case .library:
            libraryPane
        case .edit:
            editPane
        }
    }

    private var libraryPane: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(state.assets.count) photos")
                    .font(.headline)
                    .padding(.horizontal)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(state.assets) { asset in
                            AssetThumbnailView(asset: asset, isSelected: state.selectedAssetIDs.contains(asset.id))
                                .onTapGesture {
                                    if state.selectedAssetIDs.contains(asset.id) {
                                        state.selectedAssetIDs.remove(asset.id)
                                    } else {
                                        state.selectedAssetIDs.insert(asset.id)
                                    }
                                }
                                .onTapGesture(count: 2) {
                                    state.selectedAssetIDs = [asset.id]
                                    state.workspaceMode = .edit
                                }
                                .contextMenu {
                                    ForEach(state.albums) { album in
                                        Button("Add to \(album.name)") {
                                            state.selectedAssetIDs = [asset.id]
                                            state.addSelectionToAlbum(album)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            if state.selectedAsset == nil {
                librarySupplementPane
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var librarySupplementPane: some View {
        if state.compareAssets.count == 2 {
            HStack(spacing: 16) {
                ForEach(state.compareAssets) { asset in
                    AssetPreviewPanel(asset: asset)
                }
            }
            .padding()
        } else if !state.geotaggedAssets.isEmpty {
            MapBrowserView(state: state)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select one photo to inspect or two photos to compare.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var editPane: some View {
        if let asset = state.selectedAsset {
            EditorWorkspaceView(state: state, asset: asset)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select a single photo, then switch to Edit mode.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func optionalDateFilter(title: String, value: Binding<Date?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let wrappedValue = value.wrappedValue {
                DatePicker(
                    title,
                    selection: Binding(
                        get: { wrappedValue },
                        set: { value.wrappedValue = $0 }
                    ),
                    displayedComponents: .date
                )
                Button("Clear \(title)") {
                    value.wrappedValue = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
            } else {
                Button("Set \(title)") {
                    value.wrappedValue = .now
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reload() {
        do {
            try state.reload()
        } catch {
            state.statusMessage = error.localizedDescription
        }
    }
}

private struct MapBrowserView: View {
    @Bindable var state: AppState

    var body: some View {
        let coordinates = state.geotaggedAssets.compactMap(\.gpsCoordinate)
        let center = coordinates.isEmpty
            ? CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
            : CLLocationCoordinate2D(
                latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
                longitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            )

        VStack(alignment: .leading, spacing: 12) {
            Text("Map Browser")
                .font(.headline)
            Map(initialPosition: .region(.init(center: center, span: .init(latitudeDelta: 10, longitudeDelta: 10)))) {
                ForEach(state.geotaggedAssets) { asset in
                    if let coordinate = asset.gpsCoordinate {
                        Annotation(URL(fileURLWithPath: asset.sourcePath).lastPathComponent, coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude)) {
                            Button {
                                state.selectedAssetIDs = [asset.id]
                            } label: {
                                Circle()
                                    .fill(state.selectedAssetIDs.contains(asset.id) ? Color.accentColor : Color.blue)
                                    .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }
}

private struct AssetThumbnailView: View {
    let asset: Asset
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(URL(fileURLWithPath: asset.sourcePath).lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            HStack {
                Text(asset.format.rawValue.uppercased())
                Spacer()
                Text(String(repeating: "★", count: asset.rating))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var preview: some View {
        if
            let previewPath = asset.previewPath,
            let nsImage = NSImage(contentsOfFile: previewPath)
        {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AssetPreviewPanel: View {
    let asset: Asset
    var useOriginalPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(URL(fileURLWithPath: asset.sourcePath).lastPathComponent)
                .font(.headline)
            if let image = resolvedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Image(systemName: "photo"))
            }
        }
    }

    private var resolvedImage: NSImage? {
        if useOriginalPreview {
            return PreviewImageLoader.loadOriginalPreview(from: asset.sourcePath)
        }
        if
            let previewPath = asset.previewPath,
            let image = NSImage(contentsOfFile: previewPath)
        {
            return image
        }
        return PreviewImageLoader.loadOriginalPreview(from: asset.sourcePath)
    }
}

private struct MetadataSidebarView: View {
    @Bindable var state: AppState
    let asset: Asset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Metadata") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Camera", value: [asset.cameraMake, asset.cameraModel].compactMap { $0 }.joined(separator: " "))
                        LabeledContent("Lens", value: asset.lensModel ?? "Unknown")
                        LabeledContent("Size", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                        TextField("Keywords", text: Binding(
                            get: { asset.keywords.joined(separator: ", ") },
                            set: { state.updateSelectedAssetMetadata(keywords: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                        ))
                        Picker("Flag", selection: Binding(
                            get: { asset.flag },
                            set: { state.updateSelectedAssetMetadata(flag: $0) }
                        )) {
                            ForEach(AssetFlag.allCases, id: \.self) { flag in
                                Text(flag.rawValue.capitalized).tag(flag)
                            }
                        }
                        Stepper(
                            "Rating: \(asset.rating)",
                            value: Binding(
                                get: { asset.rating },
                                set: { state.updateSelectedAssetMetadata(rating: $0) }
                            ),
                            in: 0...5
                        )
                    }
                }

                if let coordinate = asset.gpsCoordinate {
                    GroupBox("Map") {
                        Map(initialPosition: .region(.init(
                            center: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        ))) {
                            Marker(URL(fileURLWithPath: asset.sourcePath).lastPathComponent, coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        }
                        .frame(height: 240)
                    }
                }
            }
            .padding()
        }
        .background(.regularMaterial)
    }
}

private struct EditorWorkspaceView: View {
    @Bindable var state: AppState
    let asset: Asset
    @State private var session: EditorSession
    @State private var cropAspectRatio = CropAspectRatioPreset.freeform
    @State private var panGestureStartOffset: CGSize = .zero

    init(state: AppState, asset: Asset) {
        self._state = Bindable(state)
        self.asset = asset
        _session = State(initialValue: EditorSession(state: state, asset: asset))
    }

    var body: some View {
        HSplitView {
            previewColumn
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            inspectorColumn
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onChange(of: asset.id) { _, _ in
            session.flushPendingEdits()
            session = EditorSession(state: state, asset: asset)
        }
        .onDisappear {
            session.flushPendingEdits()
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(URL(fileURLWithPath: asset.sourcePath).lastPathComponent)
                    .font(.title3.weight(.semibold))
                Spacer()
                if session.isPersisting {
                    Label("Saving", systemImage: "bolt.horizontal.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            previewCanvas
            HStack(spacing: 10) {
                Picker("Zoom", selection: Binding(
                    get: { session.zoomMode },
                    set: {
                        session.setZoomMode($0)
                        panGestureStartOffset = session.panOffset
                    }
                )) {
                    Text("Fit").tag(EditorSession.ZoomMode.fit)
                    Text("100%").tag(EditorSession.ZoomMode.actualPixels)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                Toggle("Original", isOn: $session.showOriginal)
                    .toggleStyle(.button)

                Spacer()

                Button("Auto Enhance") {
                    session.applyAutoEnhance()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Reset Edits") {
                    session.resetAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        .padding(18)
    }

    private var previewCanvas: some View {
        GeometryReader { proxy in
            let previewImage = session.previewImage(
                maxPixelSize: session.zoomMode == .fit ? max(2048, Int(max(proxy.size.width, proxy.size.height) * 2)) : nil
            )
            let imageExtent = previewImage?.extent ?? CGRect(
                x: 0,
                y: 0,
                width: CGFloat(max(asset.pixelWidth, 1)),
                height: CGFloat(max(asset.pixelHeight, 1))
            )
            let imageFrame = fittedImageRect(
                imageExtent: imageExtent,
                containerSize: proxy.size,
                zoomMode: session.zoomMode,
                panOffset: session.panOffset
            )

            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.black.opacity(0.9))
                MetalPreviewView(
                    context: session.renderer.interactiveContext,
                    image: previewImage,
                    zoomMode: session.zoomMode,
                    panOffset: session.panOffset
                )
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            session.pan(
                                from: panGestureStartOffset,
                                by: value.translation,
                                in: proxy.size,
                                imageExtent: imageExtent
                            )
                        }
                        .onEnded { _ in
                            panGestureStartOffset = session.panOffset
                        }
                )

                if !session.showOriginal {
                    CropOverlayView(
                        cropRect: session.currentSettings.cropRect,
                        imageFrame: imageFrame,
                        aspectRatio: cropAspectRatio,
                        onChange: { session.setCropRect($0) }
                    )
                    .allowsHitTesting(session.zoomMode == .fit)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EditorInspectorSection(title: "Light") {
                    sliderRow("Exposure", value: session.currentSettings.exposure, range: -4...4, defaultValue: DevelopSettings.default.exposure, autoControl: .exposure) { newValue in
                        session.update { $0.exposure = newValue }
                    } onReset: {
                        session.reset(\.exposure)
                    }
                    sliderRow("Contrast", value: session.currentSettings.contrast, range: 0.5...2, defaultValue: DevelopSettings.default.contrast) { newValue in
                        session.update { $0.contrast = newValue }
                    } onReset: {
                        session.reset(\.contrast)
                    }
                    sliderRow("Highlights", value: session.currentSettings.highlights, range: -1...1, defaultValue: DevelopSettings.default.highlights, autoControl: .highlights) { newValue in
                        session.update { $0.highlights = newValue }
                    } onReset: {
                        session.reset(\.highlights)
                    }
                    sliderRow("Shadows", value: session.currentSettings.shadows, range: -1...1, defaultValue: DevelopSettings.default.shadows, autoControl: .shadows) { newValue in
                        session.update { $0.shadows = newValue }
                    } onReset: {
                        session.reset(\.shadows)
                    }
                    sliderRow("Whites", value: session.currentSettings.whites, range: -1...1, defaultValue: DevelopSettings.default.whites, autoControl: .whites) { newValue in
                        session.update { $0.whites = newValue }
                    } onReset: {
                        session.reset(\.whites)
                    }
                    sliderRow("Blacks", value: session.currentSettings.blacks, range: -1...1, defaultValue: DevelopSettings.default.blacks, autoControl: .blacks) { newValue in
                        session.update { $0.blacks = newValue }
                    } onReset: {
                        session.reset(\.blacks)
                    }
                }

                EditorInspectorSection(title: "Color") {
                    sliderRow("Temperature", value: session.currentSettings.temperature, range: 2000...12000, defaultValue: DevelopSettings.default.temperature) { newValue in
                        session.update { $0.temperature = newValue }
                    } onReset: {
                        session.reset(\.temperature)
                    }
                    sliderRow("Tint", value: session.currentSettings.tint, range: -150...150, defaultValue: DevelopSettings.default.tint) { newValue in
                        session.update { $0.tint = newValue }
                    } onReset: {
                        session.reset(\.tint)
                    }
                    sliderRow("Vibrance", value: session.currentSettings.vibrance, range: -0.5...1.5, defaultValue: DevelopSettings.default.vibrance, autoControl: .vibrance) { newValue in
                        session.update { $0.vibrance = newValue }
                    } onReset: {
                        session.reset(\.vibrance)
                    }
                    sliderRow("Saturation", value: session.currentSettings.saturation, range: 0...2, defaultValue: DevelopSettings.default.saturation) { newValue in
                        session.update { $0.saturation = newValue }
                    } onReset: {
                        session.reset(\.saturation)
                    }
                    sliderRow("Curve Mid", value: session.currentSettings.toneCurve.inputPoint2, range: 0.2...0.8, defaultValue: DevelopSettings.default.toneCurve.inputPoint2) { newValue in
                        session.update { $0.toneCurve.inputPoint2 = newValue }
                    } onReset: {
                        session.update { $0.toneCurve.inputPoint2 = DevelopSettings.default.toneCurve.inputPoint2 }
                    }
                }

                EditorInspectorSection(title: "Detail") {
                    sliderRow("Sharpen", value: session.currentSettings.sharpenAmount, range: 0...2, defaultValue: DevelopSettings.default.sharpenAmount) { newValue in
                        session.update { $0.sharpenAmount = newValue }
                    } onReset: {
                        session.reset(\.sharpenAmount)
                    }
                    sliderRow("Luma NR", value: session.currentSettings.luminanceNoiseReductionAmount, range: 0...1, defaultValue: DevelopSettings.default.luminanceNoiseReductionAmount) { newValue in
                        session.update { $0.luminanceNoiseReductionAmount = newValue }
                    } onReset: {
                        session.reset(\.luminanceNoiseReductionAmount)
                    }
                    sliderRow("Chroma NR", value: session.currentSettings.chrominanceNoiseReductionAmount, range: 0...1, defaultValue: DevelopSettings.default.chrominanceNoiseReductionAmount) { newValue in
                        session.update { $0.chrominanceNoiseReductionAmount = newValue }
                    } onReset: {
                        session.reset(\.chrominanceNoiseReductionAmount)
                    }
                }

                EditorInspectorSection(title: "Optics") {
                    HStack {
                        Text("Auto optics")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") {
                            session.applyAutoOptics()
                        }
                        .buttonStyle(.borderless)
                    }
                    sliderRow("Lens Correction", value: session.currentSettings.lensCorrectionAmount, range: 0...1, defaultValue: DevelopSettings.default.lensCorrectionAmount) { newValue in
                        session.update { $0.lensCorrectionAmount = newValue }
                    } onReset: {
                        session.reset(\.lensCorrectionAmount)
                    }
                    sliderRow("Vignette", value: session.currentSettings.vignetteCorrectionAmount, range: 0...1, defaultValue: DevelopSettings.default.vignetteCorrectionAmount) { newValue in
                        session.update { $0.vignetteCorrectionAmount = newValue }
                    } onReset: {
                        session.reset(\.vignetteCorrectionAmount)
                    }
                    sliderRow("Straighten", value: session.currentSettings.straightenAngle, range: -15...15, defaultValue: DevelopSettings.default.straightenAngle) { newValue in
                        session.update { $0.straightenAngle = newValue }
                    } onReset: {
                        session.reset(\.straightenAngle)
                    }
                }

                EditorInspectorSection(title: "Crop") {
                    Picker("Aspect Ratio", selection: $cropAspectRatio) {
                        ForEach(CropAspectRatioPreset.allCases) { ratio in
                            Text(ratio.label).tag(ratio)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: cropAspectRatio) { _, newValue in
                        session.setCropRect(newValue.adjustedRect(from: session.currentSettings.cropRect))
                    }

                    Text("Drag inside the frame to move the crop. Drag the corners to resize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Reset Crop") {
                        cropAspectRatio = .freeform
                        session.resetCrop()
                    }
                }
            }
            .padding(18)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.vertical, 18)
        .padding(.trailing, 18)
    }

    private func sliderRow(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        defaultValue: Double,
        autoControl: AutoAdjustmentControl? = nil,
        onChange: @escaping (Double) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        EditorSliderRow(
            title: title,
            value: value,
            range: range,
            defaultValue: defaultValue,
            autoAction: autoControl.map { control in
                { session.applyAuto(control) }
            },
            onChange: onChange,
            onReset: onReset
        )
    }
}

private struct EditorInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct EditorSliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let autoAction: (() -> Void)?
    let onChange: (Double) -> Void
    let onReset: () -> Void

    private var isEdited: Bool {
        abs(value - defaultValue) > 0.0001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isEdited ? Color.accentColor : Color.clear)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let autoAction {
                    Button("Auto", action: autoAction)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Button("Reset", action: onReset)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(isEdited ? .secondary : .tertiary)
                    .disabled(!isEdited)
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { onChange($0) }
                ),
                in: range
            )
        }
    }
}

private enum CropAspectRatioPreset: String, CaseIterable, Identifiable {
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

private struct CropOverlayView: View {
    let cropRect: CropRect
    let imageFrame: CGRect
    let aspectRatio: CropAspectRatioPreset
    let onChange: (CropRect) -> Void

    var body: some View {
        let overlayRect = CGRect(
            x: imageFrame.minX + (cropRect.x * imageFrame.width),
            y: imageFrame.minY + (cropRect.y * imageFrame.height),
            width: cropRect.width * imageFrame.width,
            height: cropRect.height * imageFrame.height
        )

        ZStack {
            Path { path in
                path.addRect(imageFrame)
                path.addRect(overlayRect)
            }
            .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: overlayRect.width, height: overlayRect.height)
                .position(x: overlayRect.midX, y: overlayRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let deltaX = value.translation.width / imageFrame.width
                            let deltaY = value.translation.height / imageFrame.height
                            onChange(
                                CropRect(
                                    x: cropRect.x + deltaX,
                                    y: cropRect.y + deltaY,
                                    width: cropRect.width,
                                    height: cropRect.height
                                )
                            )
                        }
                )

            ForEach(CropHandle.allCases) { handle in
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(handle.position(in: overlayRect))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                onChange(handle.updatedRect(from: cropRect, translation: value.translation, imageFrame: imageFrame, aspectRatio: aspectRatio))
                            }
                    )
            }
        }
        .allowsHitTesting(imageFrame.width > 0 && imageFrame.height > 0)
    }
}

private enum CropHandle: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String {
        switch self {
        case .topLeft: "topLeft"
        case .topRight: "topRight"
        case .bottomLeft: "bottomLeft"
        case .bottomRight: "bottomRight"
        }
    }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func updatedRect(from rect: CropRect, translation: CGSize, imageFrame: CGRect, aspectRatio: CropAspectRatioPreset) -> CropRect {
        let dx = translation.width / imageFrame.width
        let dy = translation.height / imageFrame.height

        var next = rect
        switch self {
        case .topLeft:
            next.x += dx
            next.y += dy
            next.width -= dx
            next.height -= dy
        case .topRight:
            next.y += dy
            next.width += dx
            next.height -= dy
        case .bottomLeft:
            next.x += dx
            next.width -= dx
            next.height += dy
        case .bottomRight:
            next.width += dx
            next.height += dy
        }

        if let ratioSize = aspectRatio.size {
            let ratio = ratioSize.width / ratioSize.height
            next.height = next.width / ratio
            if self == .topLeft || self == .topRight {
                next.y = rect.y + rect.height - next.height
            }
        }

        let width = min(max(next.width, 0.05), 1)
        let height = min(max(next.height, 0.05), 1)
        let x = min(max(next.x, 0), 1 - width)
        let y = min(max(next.y, 0), 1 - height)
        return CropRect(x: x, y: y, width: width, height: height)
    }
}

private enum PreviewImageLoader {
    static func loadOriginalPreview(from sourcePath: String, maxPixelSize: Int = 2200) -> NSImage? {
        let url = URL(fileURLWithPath: sourcePath)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return NSImage(contentsOfFile: sourcePath)
        }

        return NSImage(cgImage: cgImage, size: .zero)
    }
}
