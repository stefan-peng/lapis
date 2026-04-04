import AppKit
import CoreLocation
import ImageIO
import LapisCore
import MapKit
import SwiftUI

struct ContentView: View {
    private enum SidebarSelection: Hashable {
        case allPhotos
        case album(UUID)
    }

    @Bindable var state: AppState
    @State private var showsInspector = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var editorSession: EditorSession?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            mainContentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: $showsInspector) {
            inspectorPane
                .controlSize(.small)
                .inspectorColumnWidth(min: 280, ideal: 300, max: 380)
        }
        .navigationTitle(navigationTitle)
        .navigationSplitViewStyle(.automatic)
        .searchable(text: $state.filter.searchText, prompt: "Search Library")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $state.workspaceMode) {
                    ForEach(AppState.WorkspaceMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.importFolders()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import a folder of photos")
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Menu {
                    Button("Apply GPX", action: state.importGPX)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("Export Selection", action: state.exportSelection)
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Write XMP Sidecar", action: state.writeMetadataSidecar)
                        .keyboardShortcut("x", modifiers: [.command, .shift])
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    state.activateCompareMode()
                } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                }
                .disabled(state.workspaceMode != .library || !state.canCompareSelection)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(showsInspector ? "Hide Inspector" : "Show Inspector")
                .keyboardShortcut("i", modifiers: [.command])
            }
        }
        .onChange(of: state.workspaceMode) { _, _ in syncEditorSession() }
        .onChange(of: state.selectedAsset?.id) { _, _ in syncEditorSession() }
        .onAppear { syncEditorSession() }
        .safeAreaInset(edge: .bottom) {
            if !state.statusMessage.isEmpty {
                LabeledContent {
                    Text(state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Status", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
    }

    private var navigationTitle: String {
        switch state.workspaceMode {
        case .library:
            if state.libraryDetailMode == .compare {
                return "Compare"
            }
            if let selectedAlbumID = state.selectedAlbumID,
               let album = state.albums.first(where: { $0.id == selectedAlbumID }) {
                return album.name
            }
            return "Library"
        case .edit:
            return "Edit"
        }
    }

    private func syncEditorSession() {
        if state.workspaceMode == .edit, let asset = state.selectedAsset {
            if editorSession?.assetID != asset.id {
                let span = AppPerformanceMetrics.begin("editor.session.sync", details: "asset=\(asset.id.uuidString)")
                editorSession?.flushPendingEdits()
                let session = EditorSession(state: state, asset: asset)
                editorSession = session

                if let startNanos = state.consumePendingEditOpenStartNanos() {
                    AppPerformanceMetrics.event(
                        "editor.open.completed",
                        details: "asset=\(asset.id.uuidString) bootstrapPreview=\(session.displayImage != nil) elapsed_ms=\(AppPerformanceMetrics.format(AppPerformanceMetrics.milliseconds(since: startNanos)))"
                    )
                }

                AppPerformanceMetrics.end(span, details: "bootstrapPreview=\(session.displayImage != nil)")
            }
        } else {
            if editorSession != nil {
                editorSession?.flushPendingEdits()
                editorSession = nil
            }
        }
    }

    @ViewBuilder
    private var mainContentPane: some View {
        switch state.workspaceMode {
        case .library:
            if state.libraryDetailMode == .compare {
                CompareView(state: state)
            } else {
                LibraryGridView(state: state)
            }
        case .edit:
            if let session = editorSession {
                EditorCanvasView(session: session)
            } else {
                ContentUnavailableView(
                    "Select One Photo",
                    systemImage: "slider.horizontal.3",
                    description: Text("Choose a single photo in Library, then enter Edit mode.")
                )
            }
        }
    }

    @ViewBuilder
    private var inspectorPane: some View {
        switch state.workspaceMode {
        case .library:
            LibraryInspectorView(state: state, asset: state.selectedAsset)
        case .edit:
            if let session = editorSession {
                EditorInspectorView(session: session)
            }
        }
    }

    private var sidebarSelection: Binding<SidebarSelection> {
        Binding(
            get: {
                if let selectedAlbumID = state.selectedAlbumID {
                    .album(selectedAlbumID)
                } else {
                    .allPhotos
                }
            },
            set: { selection in
                switch selection {
                case .allPhotos:
                    state.selectAlbum(nil)
                case .album(let albumID):
                    state.selectAlbum(albumID)
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarSelection.allPhotos)

                ForEach(state.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(SidebarSelection.album(album.id))
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.filter) { _, _ in reload() }
    }
    private func reload() {
        do {
            try state.reload()
        } catch {
            state.statusMessage = error.localizedDescription
        }
    }
}

private struct LibraryGridView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(state.assets.count) photos")
                    .font(.headline)
                Spacer()
                if state.selectedAssetIDs.count == 2 && state.libraryDetailMode != .compare {
                    Text("Choose Compare to inspect both photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, minHeight: 1)
                        .onTapGesture {
                            state.clearSelection()
                        }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(state.assets) { asset in
                            AssetThumbnailView(asset: asset, isSelected: state.selectedAssetIDs.contains(asset.id))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture {
                                    state.handleLibrarySelection(assetID: asset.id, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                                }
                                .onTapGesture(count: 2) {
                                    state.selectSingleAsset(asset.id)
                                    state.openSelectedAssetForEditing()
                                }
                                .contextMenu {
                                    ForEach(state.albums) { album in
                                        Button("Add to \(album.name)") {
                                            state.selectSingleAsset(asset.id)
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
            .background(
                Button("", action: state.openSelectedAssetForEditing)
                    .keyboardShortcut(.return, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompareView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 16) {
            ForEach(state.compareAssets) { asset in
                AssetPreviewPanel(asset: asset)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                state.selectSingleAsset(asset.id)
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
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var preview: some View {
        if
            let previewPath = asset.previewPath,
            let nsImage = PreviewImageLoader.loadPreviewImage(from: previewPath)
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
            let image = PreviewImageLoader.loadPreviewImage(from: previewPath)
        {
            return image
        }
        return PreviewImageLoader.loadOriginalPreview(from: asset.sourcePath)
    }
}

private struct LibraryInspectorView: View {
    @Bindable var state: AppState
    let asset: Asset?

    var body: some View {
        InspectorScrollView {
            if let asset {
                InspectorSection("Selection", showsDivider: false) {
                    Text(URL(fileURLWithPath: asset.sourcePath).lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("Photo details and adjustments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                InspectorSection("Metadata") {
                    InspectorValueRow("Camera", value: [asset.cameraMake, asset.cameraModel].compactMap { $0 }.joined(separator: " "))
                    InspectorValueRow("Lens", value: asset.lensModel ?? "Unknown")
                    InspectorValueRow("Size", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")

                    InspectorPropertyRow("Keywords") {
                        TextField("Add keywords", text: Binding(
                            get: { asset.keywords.joined(separator: ", ") },
                            set: { state.updateSelectedAssetMetadata(keywords: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                        ))
                    }

                    InspectorPropertyRow("Flag") {
                        Picker("Flag", selection: Binding(
                            get: { asset.flag },
                            set: { state.updateSelectedAssetMetadata(flag: $0) }
                        )) {
                            ForEach(AssetFlag.allCases, id: \.self) { flag in
                                Text(flag.rawValue.capitalized).tag(flag)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    InspectorPropertyRow("Rating") {
                        Stepper(
                            value: Binding(
                                get: { asset.rating },
                                set: { state.updateSelectedAssetMetadata(rating: $0) }
                            ),
                            in: 0...5
                        ) {
                            Text("\(asset.rating) star\(asset.rating == 1 ? "" : "s")")
                        }
                    }
                }

                if let coordinate = asset.gpsCoordinate {
                    InspectorSection("Map") {
                        InspectorMapSnapshotView(
                            coordinate: coordinate,
                            title: URL(fileURLWithPath: asset.sourcePath).lastPathComponent
                        )
                    }
                }
            } else {
                InspectorSection("Selection", showsDivider: false) {
                    Text("No Photo Selected")
                        .font(.body.weight(.medium))
                    Text("Select a photo to inspect it, or use the controls below to narrow the library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            InspectorSection("Filters") {
                Toggle("Picked only", isOn: $state.filter.flaggedOnly)
                Toggle("Geotagged only", isOn: $state.filter.geotaggedOnly)

                InspectorPropertyRow("Rating") {
                    Stepper(
                        value: Binding(
                            get: { state.filter.minimumRating ?? 0 },
                            set: { state.filter.minimumRating = $0 == 0 ? nil : $0 }
                        ),
                        in: 0...5
                    ) {
                        Text(state.filter.minimumRating.map { "\($0)+ stars" } ?? "Any")
                    }
                }

                InspectorPropertyRow("Keyword") {
                    TextField("Contains", text: Binding(
                        get: { state.filter.keyword ?? "" },
                        set: { state.filter.keyword = $0.isEmpty ? nil : $0 }
                    ))
                }

                InspectorPropertyRow("Camera") {
                    TextField("Contains", text: Binding(
                        get: { state.filter.cameraContains ?? "" },
                        set: { state.filter.cameraContains = $0.isEmpty ? nil : $0 }
                    ))
                }

                InspectorPropertyRow("Lens") {
                    TextField("Contains", text: Binding(
                        get: { state.filter.lensContains ?? "" },
                        set: { state.filter.lensContains = $0.isEmpty ? nil : $0 }
                    ))
                }

                optionalDateFilterRow(
                    "From",
                    value: Binding(
                        get: { state.filter.capturedAfter },
                        set: { state.filter.capturedAfter = $0 }
                    )
                )

                optionalDateFilterRow(
                    "To",
                    value: Binding(
                        get: { state.filter.capturedBefore },
                        set: { state.filter.capturedBefore = $0 }
                    )
                )
            }

            InspectorSection("Albums") {
                InspectorPropertyRow("Name") {
                    TextField("New album", text: $state.albumNameDraft)
                }
                Button("Create Album", action: state.createAlbumFromDraft)
                    .buttonStyle(.bordered)
                    .disabled(state.albumNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            InspectorSection("Export") {
                InspectorPropertyRow("Preset") {
                    Picker("Preset", selection: $state.selectedExportPresetID) {
                        ForEach(state.exportPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            InspectorSection("Geotagging") {
                InspectorPropertyRow("Timezone") {
                    Stepper(
                        value: $state.gpxTimezoneOffsetMinutes,
                        in: -720...720,
                        step: 15
                    ) {
                        Text("\(state.gpxTimezoneOffsetMinutes) min")
                    }
                }

                InspectorPropertyRow("Clock") {
                    Stepper(
                        value: $state.gpxCameraClockOffsetSeconds,
                        in: -43_200...43_200,
                        step: 30
                    ) {
                        Text("\(state.gpxCameraClockOffsetSeconds) sec")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func optionalDateFilterRow(_ label: String, value: Binding<Date?>) -> some View {
        InspectorPropertyRow(label) {
            if let wrappedValue = value.wrappedValue {
                HStack(spacing: 8) {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { wrappedValue },
                            set: { value.wrappedValue = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .labelsHidden()

                    Button("Clear") {
                        value.wrappedValue = nil
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button("Set") {
                    value.wrappedValue = .now
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct EditorCanvasView: View {
    @Bindable var session: EditorSession
    @State private var panGestureStartOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: session.sourcePath).lastPathComponent)
                        .font(.title3.weight(.semibold))
                    Text(session.toolMode == .adjust ? "Adjust" : "Crop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.isPersisting {
                    Label("Saving", systemImage: "bolt.horizontal.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.isRenderingPreview {
                    Label("Rendering", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            previewCanvas
            HStack(spacing: 10) {
                Button(session.isFitZoom ? "100%" : "Fit") {
                    session.toggleFitZoom()
                    panGestureStartOffset = session.panOffset
                }
                .keyboardShortcut("z", modifiers: [])

                Button {
                    session.stepZoomOut(in: session.viewportSize, imageExtent: session.currentImageExtent)
                    panGestureStartOffset = session.panOffset
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button {
                    session.stepZoomIn(in: session.viewportSize, imageExtent: session.currentImageExtent)
                    panGestureStartOffset = session.panOffset
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: [.command])

                Text(session.zoomLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)

                Toggle("Original", isOn: Binding(
                    get: { session.showOriginal },
                    set: { session.setShowOriginal($0) }
                ))
                .toggleStyle(.button)

                Spacer()

                if session.toolMode == .crop {
                    Button("Done") {
                        session.setToolMode(.adjust)
                    }
                } else {
                    Button("Auto Enhance") {
                        session.applyAutoEnhance()
                    }
                    .keyboardShortcut("e", modifiers: [.command])

                    Button("Reset Edits") {
                        session.resetAll()
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }
        .padding(18)
    }

    private var previewCanvas: some View {
        GeometryReader { proxy in
            let imageExtent = session.currentImageExtent
            let imageFrame = fittedImageRect(
                imageExtent: imageExtent,
                containerSize: proxy.size,
                zoomScale: session.zoomScale,
                panOffset: session.panOffset
            )

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.92))

                MetalPreviewView(
                    context: session.interactiveRenderContext,
                    image: session.displayImage,
                    zoomScale: session.zoomScale,
                    panOffset: session.panOffset,
                    onScrollZoom: { point, deltaY in
                        session.zoomByScroll(deltaY: deltaY, at: point, in: proxy.size, imageExtent: imageExtent)
                        panGestureStartOffset = session.panOffset
                    },
                    onMagnify: { point, magnification in
                        session.zoomByMagnification(magnification, at: point, in: proxy.size, imageExtent: imageExtent)
                        panGestureStartOffset = session.panOffset
                    },
                    onPanBegan: {
                        guard session.toolMode == .adjust else { return }
                        panGestureStartOffset = session.panOffset
                    },
                    onPanChanged: { translation in
                        guard session.toolMode == .adjust else { return }
                        session.pan(
                            from: panGestureStartOffset,
                            by: translation,
                            in: proxy.size,
                            imageExtent: imageExtent
                        )
                    },
                    onPanEnded: {
                        guard session.toolMode == .adjust else { return }
                        panGestureStartOffset = session.panOffset
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .contentShape(Rectangle())

                if session.toolMode == .crop, !session.showOriginal {
                    CropOverlayView(
                        cropRect: session.currentSettings.cropRect,
                        imageFrame: imageFrame,
                        aspectRatio: session.cropAspectRatio,
                        onChange: { session.setCropRect($0) }
                    )
                }
            }
            .onAppear {
                session.updateViewportSize(proxy.size)
            }
            .onChange(of: proxy.size) { _, newSize in
                session.updateViewportSize(newSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditorInspectorView: View {
    @Bindable var session: EditorSession

    var body: some View {
        InspectorScrollView {
            InspectorSection(nil, showsDivider: false) {
                Picker("Tool", selection: Binding(
                    get: { session.toolMode },
                    set: { session.setToolMode($0) }
                )) {
                    Text("Adjust").tag(EditorSession.ToolMode.adjust)
                    Text("Crop").tag(EditorSession.ToolMode.crop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if session.toolMode == .crop {
                    Text("Crops are applied after you leave Crop mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if session.toolMode == .adjust {
                adjustInspectorContent
            } else {
                cropInspectorContent
            }
        }
    }

    @ViewBuilder
    private var adjustInspectorContent: some View {
        InspectorSection("Light") {
            sliderRow("Exposure", value: session.currentSettings.exposure, spec: .exposure, autoControl: .exposure) { newValue in
                session.update { $0.exposure = newValue }
            } onReset: {
                session.reset(\.exposure)
            }
            sliderRow("Contrast", value: session.currentSettings.contrast, spec: .contrast) { newValue in
                session.update { $0.contrast = newValue }
            } onReset: {
                session.reset(\.contrast)
            }
            sliderRow("Highlights", value: session.currentSettings.highlights, spec: .tone, autoControl: .highlights) { newValue in
                session.update { $0.highlights = newValue }
            } onReset: {
                session.reset(\.highlights)
            }
            sliderRow("Shadows", value: session.currentSettings.shadows, spec: .tone, autoControl: .shadows) { newValue in
                session.update { $0.shadows = newValue }
            } onReset: {
                session.reset(\.shadows)
            }
            sliderRow("Whites", value: session.currentSettings.whites, spec: .tone, autoControl: .whites) { newValue in
                session.update { $0.whites = newValue }
            } onReset: {
                session.reset(\.whites)
            }
            sliderRow("Blacks", value: session.currentSettings.blacks, spec: .tone, autoControl: .blacks) { newValue in
                session.update { $0.blacks = newValue }
            } onReset: {
                session.reset(\.blacks)
            }
        }

        InspectorSection("Color") {
            sliderRow("Temperature", value: session.currentSettings.temperature, spec: .temperature) { newValue in
                session.update { $0.temperature = newValue }
            } onReset: {
                session.reset(\.temperature)
            }
            sliderRow("Tint", value: session.currentSettings.tint, spec: .tint) { newValue in
                session.update { $0.tint = newValue }
            } onReset: {
                session.reset(\.tint)
            }
            sliderRow("Vibrance", value: session.currentSettings.vibrance, spec: .vibrance, autoControl: .vibrance) { newValue in
                session.update { $0.vibrance = newValue }
            } onReset: {
                session.reset(\.vibrance)
            }
            sliderRow("Saturation", value: session.currentSettings.saturation, spec: .saturation) { newValue in
                session.update { $0.saturation = newValue }
            } onReset: {
                session.reset(\.saturation)
            }
            sliderRow("Curve Mid", value: session.currentSettings.toneCurve.inputPoint2, spec: .curveMid) { newValue in
                session.update { $0.toneCurve.inputPoint2 = newValue }
            } onReset: {
                session.update { $0.toneCurve.inputPoint2 = DevelopSettings.default.toneCurve.inputPoint2 }
            }
        }

        InspectorSection("Detail") {
            sliderRow("Sharpen", value: session.currentSettings.sharpenAmount, spec: .sharpen) { newValue in
                session.update { $0.sharpenAmount = newValue }
            } onReset: {
                session.reset(\.sharpenAmount)
            }
            sliderRow("Luma NR", value: session.currentSettings.luminanceNoiseReductionAmount, spec: .normalized) { newValue in
                session.update { $0.luminanceNoiseReductionAmount = newValue }
            } onReset: {
                session.reset(\.luminanceNoiseReductionAmount)
            }
            sliderRow("Chroma NR", value: session.currentSettings.chrominanceNoiseReductionAmount, spec: .normalized) { newValue in
                session.update { $0.chrominanceNoiseReductionAmount = newValue }
            } onReset: {
                session.reset(\.chrominanceNoiseReductionAmount)
            }
        }

        InspectorSection("Optics") {
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
            sliderRow("Lens Correction", value: session.currentSettings.lensCorrectionAmount, spec: .normalized) { newValue in
                session.update { $0.lensCorrectionAmount = newValue }
            } onReset: {
                session.reset(\.lensCorrectionAmount)
            }
            sliderRow("Vignette", value: session.currentSettings.vignetteCorrectionAmount, spec: .normalized) { newValue in
                session.update { $0.vignetteCorrectionAmount = newValue }
            } onReset: {
                session.reset(\.vignetteCorrectionAmount)
            }
        }
    }

    @ViewBuilder
    private var cropInspectorContent: some View {
        InspectorSection("Crop") {
            InspectorPropertyRow("Aspect Ratio") {
                Picker("Aspect Ratio", selection: $session.cropAspectRatio) {
                    ForEach(CropAspectRatioPreset.allCases) { ratio in
                        Text(ratio.label).tag(ratio)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: session.cropAspectRatio) { _, newValue in
                    session.setCropRect(newValue.adjustedRect(from: session.currentSettings.cropRect))
                }
            }

            Text("Drag inside the frame to move the crop. Drag the corners to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)

            sliderRow("Straighten", value: session.currentSettings.straightenAngle, spec: .straighten) { newValue in
                session.update { $0.straightenAngle = newValue }
            } onReset: {
                session.reset(\.straightenAngle)
            }

            HStack {
                Button("Reset Crop") {
                    session.cropAspectRatio = .freeform
                    session.resetCrop()
                }
                Spacer()
                Button("Done") {
                    session.setToolMode(.adjust)
                }
            }
        }
    }

    private func sliderRow(
        _ title: String,
        value: Double,
        spec: SliderControlSpec,
        autoControl: AutoAdjustmentControl? = nil,
        onChange: @escaping (Double) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        EditorSliderRow(
            title: title,
            value: value,
            spec: spec,
            defaultValue: defaultValue(for: title),
            autoAction: autoControl.map { control in
                { session.applyAuto(control) }
            },
            onChange: onChange,
            onReset: onReset
        )
    }

    private func defaultValue(for title: String) -> Double {
        switch title {
        case "Curve Mid":
            DevelopSettings.default.toneCurve.inputPoint2
        default:
            switch title {
            case "Exposure": DevelopSettings.default.exposure
            case "Contrast": DevelopSettings.default.contrast
            case "Highlights": DevelopSettings.default.highlights
            case "Shadows": DevelopSettings.default.shadows
            case "Whites": DevelopSettings.default.whites
            case "Blacks": DevelopSettings.default.blacks
            case "Temperature": DevelopSettings.default.temperature
            case "Tint": DevelopSettings.default.tint
            case "Vibrance": DevelopSettings.default.vibrance
            case "Saturation": DevelopSettings.default.saturation
            case "Sharpen": DevelopSettings.default.sharpenAmount
            case "Luma NR": DevelopSettings.default.luminanceNoiseReductionAmount
            case "Chroma NR": DevelopSettings.default.chrominanceNoiseReductionAmount
            case "Lens Correction": DevelopSettings.default.lensCorrectionAmount
            case "Vignette": DevelopSettings.default.vignetteCorrectionAmount
            case "Straighten": DevelopSettings.default.straightenAngle
            default: 0
            }
        }
    }
}

private struct InspectorScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
        .background(InspectorScrollViewConfigurator())
    }
}

private struct InspectorScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var currentView: NSView? = nsView
            while let view = currentView {
                if let scrollView = view.enclosingScrollView {
                    scrollView.borderType = .noBorder
                    scrollView.drawsBackground = false
                    scrollView.backgroundColor = .clear
                    break
                }
                currentView = view.superview
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String?
    let showsDivider: Bool
    @ViewBuilder let content: Content
    @State private var isExpanded: Bool

    init(_ title: String?, showsDivider: Bool = true, defaultExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content()
        _isExpanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    sectionContent
                        .padding(.top, 10)
                } label: {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                sectionContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorPropertyRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    @ViewBuilder let content: Content

    init(_ label: String, labelWidth: CGFloat = 88, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InspectorValueRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        InspectorPropertyRow(label) {
            Text(value.isEmpty ? "—" : value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private final class InspectorMapSnapshotCacheEntry: NSObject {
    let image: NSImage
    let markerPoint: CGPoint

    init(image: NSImage, markerPoint: CGPoint) {
        self.image = image
        self.markerPoint = markerPoint
    }
}

@MainActor
private struct InspectorMapSnapshotView: View {
    let coordinate: GPSCoordinate
    let title: String

    @State private var snapshotImage: NSImage?
    @State private var markerPoint = CGPoint(x: 160, y: 90)
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            if let snapshotImage {
                Image(nsImage: snapshotImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
            }

            if snapshotImage != nil {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red, .white)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                    .position(markerPoint)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .task(id: taskID) {
            await loadSnapshot()
        }
    }

    private var taskID: String {
        "\(coordinate.latitude),\(coordinate.longitude),\(title)"
    }

    private var cacheKey: NSString {
        "\(coordinate.latitude),\(coordinate.longitude),320x180" as NSString
    }

    @MainActor
    private func loadSnapshot() async {
        if let cached = Self.cache.object(forKey: cacheKey) {
            snapshotImage = cached.image
            markerPoint = cached.markerPoint
            isLoading = false
            AppPerformanceMetrics.event("inspector.mapSnapshot", details: "title=\(title) cached=true")
            return
        }

        let span = AppPerformanceMetrics.begin("inspector.mapSnapshot", details: "title=\(title) cached=false")
        isLoading = true
        snapshotImage = nil

        let size = CGSize(width: 320, height: 180)
        let mapCoordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.showsBuildings = true
        options.pointOfInterestFilter = .excludingAll
        options.region = MKCoordinateRegion(
            center: mapCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            snapshotImage = snapshot.image
            let point = snapshot.point(for: mapCoordinate)
            markerPoint = CGPoint(
                x: min(max(point.x, 14), size.width - 14),
                y: min(max(point.y, 14), size.height - 14)
            )
            Self.cache.setObject(
                InspectorMapSnapshotCacheEntry(image: snapshot.image, markerPoint: markerPoint),
                forKey: cacheKey
            )
            AppPerformanceMetrics.end(span, details: "status=ready")
        } catch {
            snapshotImage = nil
            AppPerformanceMetrics.end(span, details: "status=failed")
        }

        isLoading = false
    }

    private static let cache: NSCache<NSString, InspectorMapSnapshotCacheEntry> = {
        let cache = NSCache<NSString, InspectorMapSnapshotCacheEntry>()
        cache.countLimit = 128
        return cache
    }()
}

private struct SliderControlSpec {
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let fieldWidth: CGFloat

    static let exposure = SliderControlSpec(range: -3...3, step: 0.05, fractionDigits: 2, fieldWidth: 64)
    static let contrast = SliderControlSpec(range: 0.5...1.5, step: 0.01, fractionDigits: 2, fieldWidth: 64)
    static let tone = SliderControlSpec(range: -1...1, step: 0.02, fractionDigits: 2, fieldWidth: 64)
    static let temperature = SliderControlSpec(range: 2500...10_000, step: 50, fractionDigits: 0, fieldWidth: 72)
    static let tint = SliderControlSpec(range: -100...100, step: 1, fractionDigits: 0, fieldWidth: 64)
    static let vibrance = SliderControlSpec(range: -0.5...0.8, step: 0.02, fractionDigits: 2, fieldWidth: 64)
    static let saturation = SliderControlSpec(range: 0.5...1.5, step: 0.02, fractionDigits: 2, fieldWidth: 64)
    static let curveMid = SliderControlSpec(range: 0.3...0.7, step: 0.01, fractionDigits: 2, fieldWidth: 64)
    static let sharpen = SliderControlSpec(range: 0...1.5, step: 0.02, fractionDigits: 2, fieldWidth: 64)
    static let normalized = SliderControlSpec(range: 0...1, step: 0.02, fractionDigits: 2, fieldWidth: 64)
    static let straighten = SliderControlSpec(range: -10...10, step: 0.1, fractionDigits: 1, fieldWidth: 64)

    func formatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }

    func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct EditorSliderRow: View {
    let title: String
    let value: Double
    let spec: SliderControlSpec
    let defaultValue: Double
    let autoAction: (() -> Void)?
    let onChange: (Double) -> Void
    let onReset: () -> Void

    private var isEdited: Bool {
        abs(value - defaultValue) > 0.0001
    }

    private var numberFormatter: NumberFormatter {
        spec.formatter()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isEdited ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                if let autoAction {
                    Button("Auto", action: autoAction)
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
                Button("Reset", action: onReset)
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(isEdited ? .secondary : .tertiary)
                    .disabled(!isEdited)
            }

            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { onChange(spec.clamped($0)) }
                    ),
                    in: spec.range,
                    step: spec.step
                )
                TextField(
                    title,
                    value: Binding(
                        get: { value },
                        set: { onChange(spec.clamped($0)) }
                    ),
                    formatter: numberFormatter
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: spec.fieldWidth)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
            }
        }
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
            .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))

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

@MainActor
private enum PreviewImageLoader {
    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    static func loadPreviewImage(from previewPath: String) -> NSImage? {
        let cacheKey = "preview:\(previewPath)" as NSString
        if let image = imageCache.object(forKey: cacheKey) {
            AppPerformanceMetrics.event(
                "preview.image.load",
                details: "kind=preview name=\(URL(fileURLWithPath: previewPath).lastPathComponent) cached=true"
            )
            return image
        }

        let span = AppPerformanceMetrics.begin(
            "preview.image.load",
            details: "kind=preview name=\(URL(fileURLWithPath: previewPath).lastPathComponent) cached=false"
        )
        let image = NSImage(contentsOfFile: previewPath)
        if let image {
            imageCache.setObject(image, forKey: cacheKey)
        }
        AppPerformanceMetrics.end(span, details: "success=\(image != nil)")
        return image
    }

    static func loadOriginalPreview(from sourcePath: String, maxPixelSize: Int = 2200) -> NSImage? {
        let cacheKey = "original:\(sourcePath):\(maxPixelSize)" as NSString
        if let image = imageCache.object(forKey: cacheKey) {
            AppPerformanceMetrics.event(
                "preview.image.load",
                details: "kind=original name=\(URL(fileURLWithPath: sourcePath).lastPathComponent) cached=true"
            )
            return image
        }

        let span = AppPerformanceMetrics.begin(
            "preview.image.load",
            details: "kind=original name=\(URL(fileURLWithPath: sourcePath).lastPathComponent) cached=false"
        )
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
            let image = NSImage(contentsOfFile: sourcePath)
            if let image {
                imageCache.setObject(image, forKey: cacheKey)
            }
            AppPerformanceMetrics.end(span, details: "success=\(image != nil)")
            return image
        }

        let image = NSImage(cgImage: cgImage, size: .zero)
        imageCache.setObject(image, forKey: cacheKey)
        AppPerformanceMetrics.end(span, details: "success=true")
        return image
    }
}
