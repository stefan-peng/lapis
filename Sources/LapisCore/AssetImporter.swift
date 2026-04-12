import Foundation

public final class AssetImporter: @unchecked Sendable {
    private let decoder: RawDecoder
    private let previewService: PreviewService

    public init(decoder: RawDecoder, previewService: PreviewService) {
        self.decoder = decoder
        self.previewService = previewService
    }

    public func importFile(
        _ fileURL: URL,
        into catalog: CatalogStore,
        preferredID: UUID? = nil
    ) throws -> AssetImportDisposition {
        guard AssetFormat.from(fileExtension: fileURL.pathExtension) != nil else {
            throw DecoderError.unsupportedFile(fileURL.path(percentEncoded: false))
        }

        var importedAsset = try decoder.metadata(for: fileURL)
        importedAsset.id = preferredID
        if let importedPreview = try? decoder.renderThumbnail(for: fileURL, maxPixelSize: 768) {
            let previewURL = try previewService.cachePreview(named: preferredID?.uuidString ?? UUID().uuidString, image: importedPreview)
            importedAsset.previewPath = previewURL.path(percentEncoded: false)
        }
        return try catalog.importAsset(importedAsset)
    }

    public func importFolder(_ folderURL: URL, into catalog: CatalogStore) throws -> ImportJob {
        var job = ImportJob()
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            guard AssetFormat.from(fileExtension: fileURL.pathExtension) != nil else {
                job.skippedCount += 1
                continue
            }

            do {
                switch try importFile(fileURL, into: catalog) {
                case .imported:
                    job.importedCount += 1
                case .duplicate:
                    job.duplicateCount += 1
                }
            } catch {
                job.failures.append(error.localizedDescription)
            }
        }
        return job
    }
}
