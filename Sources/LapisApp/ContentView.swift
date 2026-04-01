import LapisCore
import MapKit
import CoreLocation
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            libraryPane
        } detail: {
            detailPane
        }
        .navigationTitle("Lapis")
        .toolbar {
            ToolbarItemGroup {
                Button("Import Folder", action: state.importFolders)
                Button("Apply GPX", action: state.importGPX)
                Button("Export", action: state.exportSelection)
                Button("Write XMP", action: state.writeMetadataSidecar)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Filters") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search", text: $state.filter.searchText)
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
                }
                .onChange(of: state.filter.searchText) { _, _ in reload() }
                .onChange(of: state.filter.flaggedOnly) { _, _ in reload() }
                .onChange(of: state.filter.geotaggedOnly) { _, _ in reload() }
                .onChange(of: state.filter.minimumRating) { _, _ in reload() }
                .onChange(of: state.filter.cameraContains) { _, _ in reload() }
                .onChange(of: state.filter.lensContains) { _, _ in reload() }
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

    private var libraryPane: some View {
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
    }

    @ViewBuilder
    private var detailPane: some View {
        if state.compareAssets.count == 2 {
            HStack(spacing: 16) {
                ForEach(state.compareAssets) { asset in
                    AssetPreviewPanel(asset: asset)
                }
            }
            .padding()
        } else if let asset = state.selectedAsset {
            InspectorView(state: state, asset: asset)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(URL(fileURLWithPath: asset.sourcePath).lastPathComponent)
                .font(.headline)
            if
                let previewPath = asset.previewPath,
                let image = NSImage(contentsOfFile: previewPath)
            {
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
}

private struct InspectorView: View {
    @Bindable var state: AppState
    let asset: Asset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AssetPreviewPanel(asset: asset)
                    .frame(height: 380)

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

                GroupBox("Develop") {
                    VStack(spacing: 10) {
                        slider(title: "Exposure", value: asset.developSettings.exposure, range: -4...4) { $0.exposure = $1 }
                        slider(title: "Contrast", value: asset.developSettings.contrast, range: 0.5...2) { $0.contrast = $1 }
                        slider(title: "Highlights", value: asset.developSettings.highlights, range: -1...1) { $0.highlights = $1 }
                        slider(title: "Shadows", value: asset.developSettings.shadows, range: -1...1) { $0.shadows = $1 }
                        slider(title: "Whites", value: asset.developSettings.whites, range: -1...1) { $0.whites = $1 }
                        slider(title: "Blacks", value: asset.developSettings.blacks, range: -1...1) { $0.blacks = $1 }
                        slider(title: "Vibrance", value: asset.developSettings.vibrance, range: -0.5...1.5) { $0.vibrance = $1 }
                        slider(title: "Saturation", value: asset.developSettings.saturation, range: 0...2) { $0.saturation = $1 }
                        slider(title: "Temperature", value: asset.developSettings.temperature, range: 2000...12000) { $0.temperature = $1 }
                        slider(title: "Tint", value: asset.developSettings.tint, range: -150...150) { $0.tint = $1 }
                        slider(title: "Straighten", value: asset.developSettings.straightenAngle, range: -15...15) { $0.straightenAngle = $1 }
                        slider(title: "Curve Mid", value: asset.developSettings.toneCurve.inputPoint2, range: 0.2...0.8) { $0.toneCurve.inputPoint2 = $1 }
                        slider(title: "Lens Correction", value: asset.developSettings.lensCorrectionAmount, range: 0...1) { $0.lensCorrectionAmount = $1 }
                        slider(title: "Sharpen", value: asset.developSettings.sharpenAmount, range: 0...2) { $0.sharpenAmount = $1 }
                        slider(title: "Noise Reduction", value: asset.developSettings.noiseReductionAmount, range: 0...1) { $0.noiseReductionAmount = $1 }
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
    }

    private func slider(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        update: @escaping (inout DevelopSettings, Double) -> Void
    ) -> some View {
        EditorSlider(title: title, value: value, range: range) { newValue in
            state.updateSelectedAssetDevelopSettings { update(&$0, newValue) }
        }
    }
}

private struct EditorSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        Task { @MainActor in
                            onChange(newValue)
                        }
                    }
                ),
                in: range
            )
        }
    }
}
