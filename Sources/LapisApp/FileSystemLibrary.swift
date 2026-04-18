import CryptoKit
import Foundation
import LapisCore

protocol LibraryReferencing: Sendable {
    func referencedFolderURLs() -> [URL]
    func saveReferencedFolderURLs(_ folderURLs: [URL]) throws
}

final class UserDefaultsLibraryReferenceStore: LibraryReferencing, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "library.referencePaths") {
        self.defaults = defaults
        self.key = key
    }

    func referencedFolderURLs() -> [URL] {
        if let storedPaths = defaults.stringArray(forKey: key) {
            return Self.resolvedDirectoryURLs(from: storedPaths.map { URL(fileURLWithPath: $0) })
        }

        guard
            let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first,
            let resolvedPicturesURL = Self.resolvedDirectoryURL(from: picturesURL)
        else {
            return []
        }

        return [resolvedPicturesURL]
    }

    func saveReferencedFolderURLs(_ folderURLs: [URL]) throws {
        defaults.set(Self.resolvedDirectoryURLs(from: folderURLs).map(\.path), forKey: key)
    }

    private static func resolvedDirectoryURLs(from folderURLs: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return folderURLs.compactMap { folderURL in
            guard let resolvedURL = resolvedDirectoryURL(from: folderURL) else { return nil }
            let path = resolvedURL.path
            guard seenPaths.insert(path).inserted else { return nil }
            return resolvedURL
        }
    }

    private static func resolvedDirectoryURL(from folderURL: URL) -> URL? {
        let standardizedURL = folderURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return standardizedURL
    }
}

struct FileSystemLibraryService: Sendable {
    let decoder: any RawDecoder

    func loadAssets(from folderURLs: [URL], catalogAssets: [Asset]) throws -> [Asset] {
        let catalogAssetsByPath = Dictionary(uniqueKeysWithValues: catalogAssets.map { ($0.sourcePath, $0) })
        var discoveredAssets: [Asset] = []
        var seenPaths = Set<String>()
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        for folderURL in folderURLs {
            let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard AssetFormat.from(fileExtension: fileURL.pathExtension) != nil else { continue }

                do {
                    let standardizedURL = fileURL.standardizedFileURL
                    let sourcePath = standardizedURL.path
                    guard seenPaths.insert(sourcePath).inserted else { continue }

                    let resourceValues = try standardizedURL.resourceValues(forKeys: resourceKeys)
                    guard resourceValues.isRegularFile == true else { continue }

                    let existingAsset = catalogAssetsByPath[sourcePath]
                    if let existingAsset,
                       existingAsset.fileSize == Int64(resourceValues.fileSize ?? 0),
                       existingAsset.modifiedAt == (resourceValues.contentModificationDate ?? existingAsset.modifiedAt) {
                        discoveredAssets.append(existingAsset)
                        continue
                    }

                    let importedAsset = try decoder.metadata(for: standardizedURL)
                    discoveredAssets.append(mergedAsset(importedAsset: importedAsset, existingAsset: existingAsset))
                } catch {
                    continue
                }
            }
        }

        return discoveredAssets.sorted(by: assetSortComparator)
    }

    private func mergedAsset(importedAsset: ImportedAsset, existingAsset: Asset?) -> Asset {
        let hasChangedOnDisk = existingAsset != nil
        return Asset(
            id: existingAsset?.id ?? stableAssetID(for: importedAsset.sourceURL.path(percentEncoded: false)),
            sourcePath: importedAsset.sourceURL.path(percentEncoded: false),
            fileIdentity: importedAsset.fileIdentity,
            fileSize: importedAsset.fileSize,
            modifiedAt: importedAsset.modifiedAt,
            importedAt: existingAsset?.importedAt ?? importedAsset.modifiedAt,
            captureDate: importedAsset.captureDate,
            cameraMake: importedAsset.cameraMake,
            cameraModel: importedAsset.cameraModel,
            lensModel: importedAsset.lensModel,
            pixelWidth: importedAsset.pixelWidth,
            pixelHeight: importedAsset.pixelHeight,
            format: importedAsset.format,
            gpsCoordinate: existingAsset?.gpsCoordinate ?? importedAsset.gpsCoordinate,
            previewStatus: hasChangedOnDisk ? .missing : (existingAsset?.previewStatus ?? .missing),
            previewPath: hasChangedOnDisk ? nil : existingAsset?.previewPath,
            rating: existingAsset?.rating ?? 0,
            flag: existingAsset?.flag ?? .none,
            keywords: existingAsset?.keywords ?? [],
            albumIDs: existingAsset?.albumIDs ?? [],
            developSettings: hasChangedOnDisk ? .default : (existingAsset?.developSettings ?? .default)
        )
    }

    private func stableAssetID(for sourcePath: String) -> UUID {
        let digest = SHA256.hash(data: Data(sourcePath.utf8))
        let bytes = Array(digest.prefix(16))
        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private func assetSortComparator(lhs: Asset, rhs: Asset) -> Bool {
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
}
