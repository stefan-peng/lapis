import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal

public protocol DevelopRenderer: Sendable {
    func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage
}

public protocol DevelopProcessing: DevelopRenderer {
    var interactiveContext: CIContext { get }
    func previewImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CIImage
    func analysis(for fileURL: URL) throws -> ImageAnalysis
    func suggestedSettings(for fileURL: URL, current settings: DevelopSettings) throws -> DevelopSettings
    func suggestedValue(for control: AutoAdjustmentControl, fileURL: URL, current settings: DevelopSettings) throws -> Double
}

public struct ImageAnalysis: Sendable {
    public var averageLuminance: Double
    public var averageSaturation: Double
    public var lensCorrectionSuggested: Bool

    public init(averageLuminance: Double, averageSaturation: Double, lensCorrectionSuggested: Bool) {
        self.averageLuminance = averageLuminance
        self.averageSaturation = averageSaturation
        self.lensCorrectionSuggested = lensCorrectionSuggested
    }
}

public final class CoreImageDevelopRenderer: DevelopProcessing, @unchecked Sendable {
    private final class CachedImageBox: NSObject {
        let image: CIImage

        init(image: CIImage) {
            self.image = image
        }
    }

    private static let chromaReductionKernel = CIColorKernel(
        source:
        """
        kernel vec4 chromaReduce(__sample original, __sample blurred, float amount) {
            float originalLum = dot(original.rgb, vec3(0.299, 0.587, 0.114));
            float blurredLum = dot(blurred.rgb, vec3(0.299, 0.587, 0.114));
            vec3 originalChroma = original.rgb - vec3(originalLum);
            vec3 blurredChroma = blurred.rgb - vec3(blurredLum);
            vec3 outputColor = vec3(originalLum) + mix(originalChroma, blurredChroma, clamp(amount, 0.0, 1.0));
            return vec4(clamp(outputColor, 0.0, 1.0), original.a);
        }
        """
    )

    public let metalDevice: MTLDevice?
    public let interactiveContext: CIContext
    private let outputContext: CIContext
    private let sourceImageCache = NSCache<NSString, CachedImageBox>()
    private let lensCorrectionSupportCache = NSCache<NSString, NSNumber>()

    public init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        self.metalDevice = metalDevice
        if let metalDevice {
            interactiveContext = CIContext(
                mtlDevice: metalDevice,
                options: [
                    .cacheIntermediates: true,
                    .priorityRequestLow: false,
                ]
            )
        } else {
            interactiveContext = CIContext(options: [.cacheIntermediates: true])
        }
        outputContext = interactiveContext
    }

    public func renderImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CGImage {
        let image = try previewImage(from: fileURL, settings: settings, maxPixelSize: maxPixelSize)
        guard let cgImage = outputContext.createCGImage(image, from: image.extent.integral) else {
            throw RendererError.renderFailed(fileURL.path(percentEncoded: false))
        }
        return cgImage
    }

    public func previewImage(from fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CIImage {
        try processedImage(from: loadImage(fileURL: fileURL, settings: settings), fileURL: fileURL, settings: settings, maxPixelSize: maxPixelSize)
    }

    public func analysis(for fileURL: URL) throws -> ImageAnalysis {
        let sourceImage = try loadImage(fileURL: fileURL, settings: .default)
        let average = CIFilter.areaAverage()
        average.inputImage = sourceImage
        average.extent = sourceImage.extent

        guard
            let outputImage = average.outputImage,
            let cgImage = outputContext.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
            let data = cgImage.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.renderFailed(fileURL.path(percentEncoded: false))
        }

        let red = Double(bytes[0]) / 255
        let green = Double(bytes[1]) / 255
        let blue = Double(bytes[2]) / 255
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
        let lensSuggested = supportsLensCorrection(for: fileURL)

        return ImageAnalysis(
            averageLuminance: luminance,
            averageSaturation: saturation,
            lensCorrectionSuggested: lensSuggested
        )
    }

    public func suggestedSettings(for fileURL: URL, current settings: DevelopSettings) throws -> DevelopSettings {
        let analysis = try analysis(for: fileURL)
        var updated = settings
        updated.exposure = try suggestedValue(for: .exposure, fileURL: fileURL, current: settings)
        updated.highlights = try suggestedValue(for: .highlights, fileURL: fileURL, current: settings)
        updated.shadows = try suggestedValue(for: .shadows, fileURL: fileURL, current: settings)
        updated.whites = try suggestedValue(for: .whites, fileURL: fileURL, current: settings)
        updated.blacks = try suggestedValue(for: .blacks, fileURL: fileURL, current: settings)
        updated.vibrance = max(settings.vibrance, try suggestedValue(for: .vibrance, fileURL: fileURL, current: settings))
        if analysis.lensCorrectionSuggested {
            updated.lensCorrectionAmount = max(updated.lensCorrectionAmount, 1)
        }
        updated.vignetteCorrectionAmount = max(updated.vignetteCorrectionAmount, 0.25)
        return updated
    }

    public func suggestedValue(for control: AutoAdjustmentControl, fileURL: URL, current settings: DevelopSettings) throws -> Double {
        let analysis = try analysis(for: fileURL)
        switch control {
        case .exposure:
            let targetLuminance = 0.48
            return clamp(log2(targetLuminance / max(analysis.averageLuminance, 0.08)), -1.5, 1.5)
        case .highlights:
            return clamp((0.55 - analysis.averageLuminance) * 0.6, -0.6, 0.4)
        case .shadows:
            return clamp((0.52 - analysis.averageLuminance) * 1.3, -0.3, 0.75)
        case .whites:
            return clamp((0.58 - analysis.averageLuminance) * 0.8, -0.35, 0.4)
        case .blacks:
            return clamp((0.35 - analysis.averageLuminance) * 0.9, -0.45, 0.3)
        case .vibrance:
            return clamp((0.33 - analysis.averageSaturation) * 1.6, 0, 0.6)
        }
    }

    private func loadImage(fileURL: URL, settings: DevelopSettings) throws -> CIImage {
        if isRawFile(fileURL) {
            if
                let rawFilter = CIRAWFilter(imageURL: fileURL)
            {
                if rawFilter.isLensCorrectionSupported {
                    rawFilter.isLensCorrectionEnabled = settings.lensCorrectionAmount > 0
                }
                if let outputImage = rawFilter.outputImage {
                    return outputImage
                }
            }
        }

        let cacheKey = fileURL.path(percentEncoded: false) as NSString
        if let cached = sourceImageCache.object(forKey: cacheKey) {
            return cached.image
        }

        let image = CIImage(contentsOf: fileURL, options: [.applyOrientationProperty: true])

        guard let image else {
            throw RendererError.unreadableImage(fileURL.path(percentEncoded: false))
        }
        sourceImageCache.setObject(CachedImageBox(image: image), forKey: cacheKey)
        return image
    }

    private func processedImage(from sourceImage: CIImage, fileURL: URL, settings: DevelopSettings, maxPixelSize: Int?) throws -> CIImage {
        var image = sourceImage

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(settings.exposure)
        image = exposure.outputImage ?? image

        if settings.vibrance != 0, let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(image, forKey: kCIInputImageKey)
            vibrance.setValue(settings.vibrance, forKey: "inputAmount")
            image = (vibrance.outputImage ?? image)
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = image
        colorControls.contrast = Float(settings.contrast)
        colorControls.saturation = Float(settings.saturation)
        image = colorControls.outputImage ?? image

        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = image
        highlightShadow.highlightAmount = Float(1 - settings.highlights)
        highlightShadow.shadowAmount = Float(max(0, 1 + settings.shadows))
        image = highlightShadow.outputImage ?? image

        let temperatureAndTint = CIFilter.temperatureAndTint()
        temperatureAndTint.inputImage = image
        temperatureAndTint.neutral = CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint))
        temperatureAndTint.targetNeutral = CIVector(
            x: CGFloat(settings.temperature + (settings.whites * 500)),
            y: CGFloat(settings.tint + (settings.blacks * 100))
        )
        image = temperatureAndTint.outputImage ?? image

        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = image
        toneCurve.point0 = CGPoint(x: 0, y: settings.toneCurve.inputPoint0)
        toneCurve.point1 = CGPoint(x: 0.25, y: settings.toneCurve.inputPoint1)
        toneCurve.point2 = CGPoint(x: 0.5, y: settings.toneCurve.inputPoint2)
        toneCurve.point3 = CGPoint(x: 0.75, y: settings.toneCurve.inputPoint3)
        toneCurve.point4 = CGPoint(x: 1, y: settings.toneCurve.inputPoint4)
        image = toneCurve.outputImage ?? image

        image = applyNoiseReduction(to: image, settings: settings)

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = image
        sharpen.sharpness = Float(settings.sharpenAmount * 2)
        image = sharpen.outputImage ?? image

        if settings.straightenAngle != 0 {
            let transform = CGAffineTransform(rotationAngle: CGFloat(settings.straightenAngle * .pi / 180))
            image = image.transformed(by: transform)
        }

        if settings.lensCorrectionAmount > 0, !supportsLensCorrection(for: fileURL) {
            image = applyLensCorrection(to: image, amount: settings.lensCorrectionAmount)
        }

        if settings.vignetteCorrectionAmount > 0 {
            image = applyVignetteCorrection(to: image, amount: settings.vignetteCorrectionAmount)
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

        return image
    }

    private func applyNoiseReduction(to image: CIImage, settings: DevelopSettings) -> CIImage {
        var output = image

        if settings.luminanceNoiseReductionAmount > 0 {
            let noiseReduction = CIFilter.noiseReduction()
            noiseReduction.inputImage = output
            noiseReduction.noiseLevel = Float(settings.luminanceNoiseReductionAmount)
            noiseReduction.sharpness = 0
            output = noiseReduction.outputImage ?? output
        }

        guard settings.chrominanceNoiseReductionAmount > 0 else {
            return output
        }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = output
        blur.radius = Float(0.8 + (settings.chrominanceNoiseReductionAmount * 5))
        let blurred = blur.outputImage?.cropped(to: output.extent) ?? output

        return Self.chromaReductionKernel?
            .apply(extent: output.extent, arguments: [output, blurred, settings.chrominanceNoiseReductionAmount])
            ?? output
    }

    private func scaled(image: CIImage, maxPixelSize: Int) -> CIImage {
        let extent = image.extent
        let maxDimension = max(extent.width, extent.height)
        guard maxDimension > CGFloat(maxPixelSize), maxDimension > 0 else { return image }
        let scale = CGFloat(maxPixelSize) / maxDimension
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func applyLensCorrection(to image: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.torusLensDistortion()
        filter.inputImage = image
        filter.center = CGPoint(x: image.extent.midX, y: image.extent.midY)
        filter.radius = Float(max(image.extent.width, image.extent.height) * 0.65)
        filter.width = Float(max(image.extent.width, image.extent.height) * 0.35)
        filter.refraction = Float(1 + amount * 0.12)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private func applyVignetteCorrection(to image: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = Float(-amount)
        filter.radius = Float(max(image.extent.width, image.extent.height) * 0.6)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        min(max(value, minValue), maxValue)
    }

    private func supportsLensCorrection(for fileURL: URL) -> Bool {
        let cacheKey = fileURL.path(percentEncoded: false) as NSString
        if let cached = lensCorrectionSupportCache.object(forKey: cacheKey) {
            return cached.boolValue
        }

        let supported: Bool
        if isRawFile(fileURL), let rawFilter = CIRAWFilter(imageURL: fileURL) {
            supported = rawFilter.isLensCorrectionSupported
        } else {
            supported = false
        }
        lensCorrectionSupportCache.setObject(NSNumber(value: supported), forKey: cacheKey)
        return supported
    }

    private func isRawFile(_ fileURL: URL) -> Bool {
        guard let format = AssetFormat.from(fileExtension: fileURL.pathExtension) else { return false }
        return [.cr2, .cr3, .dng].contains(format)
    }
}

public enum AutoAdjustmentControl: String, CaseIterable, Sendable {
    case exposure
    case highlights
    case shadows
    case whites
    case blacks
    case vibrance
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
