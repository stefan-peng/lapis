import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class ExportService: @unchecked Sendable {
    private let renderer: DevelopRenderer
    private let metadataWritebackService: MetadataWritebackService
    private let context = CIContext(options: [.cacheIntermediates: true])

    public init(renderer: DevelopRenderer, metadataWritebackService: MetadataWritebackService = MetadataWritebackService()) {
        self.renderer = renderer
        self.metadataWritebackService = metadataWritebackService
    }

    public func export(assets: [Asset], preset: ExportPreset, destinationDirectory: URL) throws -> ExportReport {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var report = ExportReport()

        for asset in assets {
            do {
                let sourceURL = URL(fileURLWithPath: asset.sourcePath)
                let image = try renderer.renderImage(from: sourceURL, settings: asset.developSettings, maxPixelSize: preset.maxPixelSize)
                let fileName = preset.fileNameTemplate
                    .replacingOccurrences(of: "{name}", with: sourceURL.deletingPathExtension().lastPathComponent)
                    .replacingOccurrences(of: "{id}", with: asset.id.uuidString.prefix(8).description)

                let fileExtension = preset.format == .jpeg ? "jpg" : "tif"
                let destinationURL = uniqueDestinationURL(
                    for: destinationDirectory.appending(path: "\(fileName).\(fileExtension)")
                )
                try write(image: image, preset: preset, destinationURL: destinationURL, asset: asset)
                report.exportedURLs.append(destinationURL)
            } catch {
                report.failures.append(
                    ExportFailure(
                        assetID: asset.id,
                        sourcePath: asset.sourcePath,
                        message: error.localizedDescription
                    )
                )
            }
        }

        if report.exportedURLs.isEmpty, let firstFailure = report.failures.first {
            throw ExportError.exportFailed(firstFailure.message)
        }

        return report
    }

    private func write(image: CGImage, preset: ExportPreset, destinationURL: URL, asset: Asset) throws {
        let type: CFString = preset.format == .jpeg ? UTType.jpeg.identifier as CFString : UTType.tiff.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil) else {
            throw ExportError.destinationCreationFailed(destinationURL.path(percentEncoded: false))
        }

        let processedImage = try postProcess(image: image, preset: preset)
        var options: [CFString: Any] = [:]
        if preset.format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = preset.quality
        }
        let metadata = try metadataWritebackService.embeddedMetadata(for: asset)
        CGImageDestinationAddImageAndMetadata(destination, processedImage, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed(destinationURL.path(percentEncoded: false))
        }
    }

    func postProcess(image: CGImage, preset: ExportPreset) throws -> CGImage {
        let workingColorSpace = Self.colorSpace(for: preset.colorSpace)
        var ciImage = CIImage(cgImage: image).matchedToWorkingSpace(from: image.colorSpace ?? workingColorSpace)
            ?? CIImage(cgImage: image)

        if preset.outputSharpening > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = ciImage
            sharpen.sharpness = Float(preset.outputSharpening * 2)
            ciImage = sharpen.outputImage ?? ciImage
        }

        guard let output = context.createCGImage(ciImage, from: ciImage.extent.integral, format: .RGBA8, colorSpace: workingColorSpace) else {
            throw ExportError.writeFailed("processed image")
        }
        return output
    }

    private func uniqueDestinationURL(for preferredURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: preferredURL.path(percentEncoded: false)) else {
            return preferredURL
        }

        let directory = preferredURL.deletingLastPathComponent()
        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let pathExtension = preferredURL.pathExtension

        for index in 2...10_000 {
            let candidateURL = directory.appending(path: "\(baseName)-\(index).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
                return candidateURL
            }
        }

        return preferredURL
    }

    static func colorSpace(for value: ExportPreset.ColorSpace) -> CGColorSpace {
        switch value {
        case .sRGB:
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        case .adobeRGB:
            return CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? CGColorSpaceCreateDeviceRGB()
        }
    }
}

public enum ExportError: Error, LocalizedError {
    case destinationCreationFailed(String)
    case writeFailed(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .destinationCreationFailed(path):
            "Could not create export destination at \(path)"
        case let .writeFailed(path):
            "Could not write export at \(path)"
        case let .exportFailed(message):
            message
        }
    }
}
