import AppKit
import CoreLocation
import ImageIO
import LapisCore
import MapKit
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @State private var showsInspector = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            contentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: inspectorPresented) {
            if let asset = state.selectedAsset, state.workspaceMode == .library {
                MetadataSidebarView(state: state, asset: asset)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
        }
        .navigationTitle("Lapis")
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $state.filter.searchText, placement: .sidebar, prompt: "Search Library")
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
                .labelStyle(.titleAndIcon)
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
                .labelStyle(.titleAndIcon)
            }

            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    state.activateCompareMode()
                } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                }
                .labelStyle(.titleAndIcon)
                .disabled(state.workspaceMode != .library || !state.canCompareSelection)

                Button {
                    showsInspector.toggle()
                } label: {
                    Label(showsInspector ? "Hide Info" : "Show Info", systemImage: "info.circle")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(state.workspaceMode != .library || state.selectedAsset == nil)
            }
        }
        .onChange(of: state.filter.searchText) { _, _ in reload() }
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

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { state.workspaceMode == .library && showsInspector && state.selectedAsset != nil },
            set: { showsInspector = $0 }
        )
    }

    private var sidebar: some View {
        List {
            Section("Library") {
                Button {
                    state.selectAlbum(nil)
                } label: {
                    sidebarRowLabel(
                        "All Photos",
                        systemImage: "photo.on.rectangle.angled",
                        isSelected: state.selectedAlbumID == nil
                    )
                }
                .buttonStyle(.plain)

                ForEach(state.albums) { album in
                    Button {
                        state.selectAlbum(album.id)
                    } label: {
                        sidebarRowLabel(
                            album.name,
                            systemImage: "rectangle.stack",
                            isSelected: state.selectedAlbumID == album.id
                        )
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    TextField("New Album", text: $state.albumNameDraft)
                    Button("Add", action: state.createAlbumFromDraft)
                        .disabled(state.albumNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Filters") {
                Toggle("Picked Only", isOn: $state.filter.flaggedOnly)
                Toggle("Geotagged Only", isOn: $state.filter.geotaggedOnly)
                Stepper(
                    "Minimum Rating: \(state.filter.minimumRating ?? 0)",
                    value: Binding(
                        get: { state.filter.minimumRating ?? 0 },
                        set: { state.filter.minimumRating = $0 == 0 ? nil : $0 }
                    ),
                    in: 0...5
                )
            }

            Section("Metadata") {
                TextField("Keyword", text: Binding(
                    get: { state.filter.keyword ?? "" },
                    set: { state.filter.keyword = $0.isEmpty ? nil : $0 }
                ))
                TextField("Camera Contains", text: Binding(
                    get: { state.filter.cameraContains ?? "" },
                    set: { state.filter.cameraContains = $0.isEmpty ? nil : $0 }
                ))
                TextField("Lens Contains", text: Binding(
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

            Section("Export") {
                Picker("Preset", selection: $state.selectedExportPresetID) {
                    ForEach(state.exportPresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
            }

            Section("Geotagging") {
                Stepper(
                    "Timezone Offset: \(state.gpxTimezoneOffsetMinutes) min",
                    value: $state.gpxTimezoneOffsetMinutes,
                    in: -720...720,
                    step: 15
                )
                Stepper(
                    "Camera Offset: \(state.gpxCameraClockOffsetSeconds) sec",
                    value: $state.gpxCameraClockOffsetSeconds,
                    in: -43_200...43_200,
                    step: 30
                )
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .onChange(of: state.filter.keyword) { _, _ in reload() }
        .onChange(of: state.filter.flaggedOnly) { _, _ in reload() }
        .onChange(of: state.filter.geotaggedOnly) { _, _ in reload() }
        .onChange(of: state.filter.minimumRating) { _, _ in reload() }
        .onChange(of: state.filter.cameraContains) { _, _ in reload() }
        .onChange(of: state.filter.lensContains) { _, _ in reload() }
        .onChange(of: state.filter.capturedAfter) { _, _ in reload() }
        .onChange(of: state.filter.capturedBefore) { _, _ in reload() }
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
                                        state.handleLibrarySelection(assetID: asset.id, modifiers: currentEventModifiers())
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
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

            if shouldShowLibrarySupplementPane {
                librarySupplementPane
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
            }
        }
    }

    private var shouldShowLibrarySupplementPane: Bool {
        state.libraryDetailMode == .compare || state.selectedAsset == nil
    }

    @ViewBuilder
    private var librarySupplementPane: some View {
        if state.libraryDetailMode == .compare, state.compareAssets.count == 2 {
            HStack(spacing: 16) {
                ForEach(state.compareAssets) { asset in
                    AssetPreviewPanel(asset: asset)
                }
            }
            .padding()
        } else if state.selectedAssetIDs.count == 2 {
            ContentUnavailableView(
                "Compare Ready",
                systemImage: "rectangle.split.2x1",
                description: Text("Use Compare in the toolbar to inspect the two selected photos side by side.")
            )
        } else if !state.geotaggedAssets.isEmpty {
            MapBrowserView(state: state)
        } else {
            ContentUnavailableView(
                "No Photo Selected",
                systemImage: "camera.aperture",
                description: Text("Select a photo to inspect it, or select two photos and choose Compare.")
            )
        }
    }

    @ViewBuilder
    private var editPane: some View {
        if let asset = state.selectedAsset {
            EditorWorkspaceView(state: state, asset: asset)
        } else {
            ContentUnavailableView(
                "Select One Photo",
                systemImage: "slider.horizontal.3",
                description: Text("Choose a single photo in Library, then enter Edit mode.")
            )
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

    private func sidebarRowLabel(_ title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func reload() {
        do {
            try state.reload()
        } catch {
            state.statusMessage = error.localizedDescription
        }
    }

    private func currentEventModifiers() -> NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? []
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
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
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
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            inspectorColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: asset.id) { _, _ in
            session.flushPendingEdits()
            session = EditorSession(state: state, asset: asset)
            cropAspectRatio = .freeform
            panGestureStartOffset = .zero
        }
        .onDisappear {
            session.flushPendingEdits()
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: asset.sourcePath).lastPathComponent)
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
                    context: session.renderer.interactiveContext,
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
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .contentShape(Rectangle())
                .gesture(
                    session.toolMode == .adjust
                    ? DragGesture()
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
                    : nil
                )

                if session.toolMode == .crop, !session.showOriginal {
                    CropOverlayView(
                        cropRect: session.currentSettings.cropRect,
                        imageFrame: imageFrame,
                        aspectRatio: cropAspectRatio,
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
        .background(Color.black.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var inspectorColumn: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Picker("Tool", selection: Binding(
                    get: { session.toolMode },
                    set: { session.setToolMode($0) }
                )) {
                    Text("Adjust").tag(EditorSession.ToolMode.adjust)
                    Text("Crop").tag(EditorSession.ToolMode.crop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)

                Spacer()
                if session.toolMode == .crop {
                    Text("Crops are applied after you leave Crop mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.toolMode == .adjust {
                        adjustInspectorContent
                    } else {
                        cropInspectorContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .padding(.leading, 18)
                .padding(.bottom, 18)
                .padding(.trailing, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var adjustInspectorContent: some View {
        EditorInspectorSection(title: "Light") {
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

        EditorInspectorSection(title: "Color") {
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

        EditorInspectorSection(title: "Detail") {
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

            sliderRow("Straighten", value: session.currentSettings.straightenAngle, spec: .straighten) { newValue in
                session.update { $0.straightenAngle = newValue }
            } onReset: {
                session.reset(\.straightenAngle)
            }

            HStack {
                Button("Reset Crop") {
                    cropAspectRatio = .freeform
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

private struct EditorInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        label: {
            Text(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
        VStack(alignment: .leading, spacing: 8) {
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
