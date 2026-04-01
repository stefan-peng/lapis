import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public protocol DevelopRenderer: Sendable {
    func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage
}

public final class CoreImageDevelopRenderer: DevelopRenderer, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: true])

    public init() {}

    public func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage {
        guard let sourceImage = loadImage(fileURL: fileURL) else {
            throw RendererError.unreadableImage(fileURL.path(percentEncoded: false))
        }

        var image = sourceImage.oriented(forExifOrientation: 1)

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(settings.exposure)
        image = exposure.outputImage ?? image

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = image
        colorControls.contrast = Float(settings.contrast)
        colorControls.saturation = Float(settings.saturation + settings.vibrance)
        image = colorControls.outputImage ?? image

        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = image
        highlightShadow.highlightAmount = Float(1 - settings.highlights)
        highlightShadow.shadowAmount = Float(max(0, 1 + settings.shadows))
        image = highlightShadow.outputImage ?? image

        let temperatureAndTint = CIFilter.temperatureAndTint()
        temperatureAndTint.inputImage = image
        temperatureAndTint.neutral = CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint))
        temperatureAndTint.targetNeutral = CIVector(x: CGFloat(settings.temperature + (settings.whites * 500)), y: CGFloat(settings.tint + (settings.blacks * 100)))
        image = temperatureAndTint.outputImage ?? image

        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image
        toneCurve.point0 = CGPoint(x: 0, y: settings.toneCurve.inputPoint0)
        toneCurve.point1 = CGPoint(x: 0.25, y: settings.toneCurve.inputPoint1)
        toneCurve.point2 = CGPoint(x: 0.5, y: settings.toneCurve.inputPoint2)
        toneCurve.point3 = CGPoint(x: 0.75, y: settings.toneCurve.inputPoint3)
        toneCurve.point4 = CGPoint(x: 1, y: settings.toneCurve.inputPoint4)
        image = toneCurve.outputImage ?? image

        let noiseReduction = CIFilter.noiseReduction()
        noiseReduction.inputImage = image
        noiseReduction.noiseLevel = Float(settings.noiseReductionAmount)
        noiseReduction.sharpness = Float(max(0, settings.sharpenAmount))
        image = noiseReduction.outputImage ?? image

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = image
        sharpen.sharpness = Float(settings.sharpenAmount * 2)
        image = sharpen.outputImage ?? image

        if settings.straightenAngle != 0 {
            let transform = CGAffineTransform(rotationAngle: CGFloat(settings.straightenAngle * .pi / 180))
            image = image.transformed(by: transform)
        }

        if settings.cropRect != .fullFrame {
            let extent = image.extent
            let crop = CGRect(
                x: extent.origin.x + extent.width * settings.cropRect.x,
                y: extent.origin.y + extent.height * settings.cropRect.y,
                width: extent.width * settings.cropRect.width,
                height: extent.height * settings.cropRect.height
            )
            image = image.cropped(to: crop)
        }

        if let maxPixelSize {
            image = scaled(image: image, maxPixelSize: maxPixelSize)
        }

        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else {
            throw RendererError.renderFailed(fileURL.path(percentEncoded: false))
        }
        return cgImage
    }

    private func loadImage(fileURL: URL) -> CIImage? {
        CIImage(contentsOf: fileURL, options: [.applyOrientationProperty: true])
    }

    private func scaled(image: CIImage, maxPixelSize: Int) -> CIImage {
        let extent = image.extent
        let maxDimension = max(extent.width, extent.height)
        guard maxDimension > CGFloat(maxPixelSize), maxDimension > 0 else { return image }
        let scale = CGFloat(maxPixelSize) / maxDimension
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

public enum RendererError: Error, LocalizedError {
    case unreadableImage(String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableImage(path):
            "Could not read image at \(path)"
        case let .renderFailed(path):
            "Could not render image at \(path)"
        }
    }
}
