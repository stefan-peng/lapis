import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class ExportService: @unchecked Sendable {
    private let renderer: DevelopRenderer
    private let context = CIContext(options: [.cacheIntermediates: true])

    public init(renderer: DevelopRenderer) {
        self.renderer = renderer
    }

    public func export(assets: [Asset], preset: ExportPreset, destinationDirectory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        return try assets.map { asset in
            let sourceURL = URL(fileURLWithPath: asset.sourcePath)
            let image = try renderer.renderImage(from: sourceURL, settings: asset.developSettings, maxPixelSize: preset.maxPixelSize)
            let fileName = preset.fileNameTemplate
                .replacingOccurrences(of: "{name}", with: sourceURL.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{id}", with: asset.id.uuidString.prefix(8).description)

            let fileExtension = preset.format == .jpeg ? "jpg" : "tif"
            let destinationURL = destinationDirectory.appending(path: "\(fileName).\(fileExtension)")
            try write(image: image, preset: preset, destinationURL: destinationURL)
            return destinationURL
        }
    }

    private func write(image: CGImage, preset: ExportPreset, destinationURL: URL) throws {
        let type: CFString = preset.format == .jpeg ? UTType.jpeg.identifier as CFString : UTType.tiff.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil) else {
            throw ExportError.destinationCreationFailed(destinationURL.path(percentEncoded: false))
        }

        let processedImage = try postProcess(image: image, preset: preset)
        var options: [CFString: Any] = [:]
        if preset.format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = preset.quality
        }
        CGImageDestinationAddImage(destination, processedImage, options as CFDictionary)
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

    public var errorDescription: String? {
        switch self {
        case let .destinationCreationFailed(path):
            "Could not create export destination at \(path)"
        case let .writeFailed(path):
            "Could not write export at \(path)"
        }
    }
}
