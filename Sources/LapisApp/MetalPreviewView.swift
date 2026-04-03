import CoreImage
import MetalKit
import SwiftUI

struct MetalPreviewView: NSViewRepresentable {
    let context: CIContext
    let image: CIImage?
    let zoomScale: Double?
    let panOffset: CGSize
    let onScrollZoom: (CGPoint, CGFloat) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let onPanBegan: () -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context)
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = InteractiveMTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.onScrollZoom = onScrollZoom
        view.onMagnify = onMagnify
        view.onPanBegan = onPanBegan
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        context.coordinator.context = self.context
        context.coordinator.image = image
        context.coordinator.zoomScale = zoomScale
        context.coordinator.panOffset = panOffset
        nsView.onScrollZoom = onScrollZoom
        nsView.onMagnify = onMagnify
        nsView.onPanBegan = onPanBegan
        nsView.onPanChanged = onPanChanged
        nsView.onPanEnded = onPanEnded
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var context: CIContext
        var image: CIImage?
        var zoomScale: Double?
        var panOffset: CGSize = .zero
        private let commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()

        init(context: CIContext) {
            self.context = context
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let currentDrawable = view.currentDrawable else { return }

            let commandBuffer = commandQueue?.makeCommandBuffer()
            let destination = CIRenderDestination(
                mtlTexture: currentDrawable.texture,
                commandBuffer: commandBuffer
            )
            destination.isFlipped = true

            guard let image else {
                commandBuffer?.present(currentDrawable)
                commandBuffer?.commit()
                return
            }

            let targetRect = fittedImageRect(
                imageExtent: image.extent,
                containerSize: view.drawableSize,
                zoomScale: zoomScale,
                panOffset: panOffset
            )
            let background = CIImage(color: CIColor(red: 0.08, green: 0.09, blue: 0.11))
                .cropped(to: CGRect(origin: .zero, size: view.drawableSize))
            let transformed = transformedImage(image, targetRect: targetRect)
                .composited(over: background)
            do {
                try context.startTask(toRender: transformed, to: destination)
                commandBuffer?.present(currentDrawable)
                commandBuffer?.commit()
            } catch {
                commandBuffer?.present(currentDrawable)
                commandBuffer?.commit()
            }
        }

        private func transformedImage(_ image: CIImage, targetRect: CGRect) -> CIImage {
            let sourceRect = image.extent
            let normalized = CGAffineTransform(translationX: -sourceRect.origin.x, y: -sourceRect.origin.y)
            let scaled = normalized.concatenating(
                CGAffineTransform(scaleX: targetRect.width / sourceRect.width, y: targetRect.height / sourceRect.height)
            )
            let centered = scaled.concatenating(
                CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y)
            )
            return image.transformed(by: centered)
        }
    }
}

final class InteractiveMTKView: MTKView {
    var onScrollZoom: ((CGPoint, CGFloat) -> Void)?
    var onMagnify: ((CGPoint, CGFloat) -> Void)?
    var onPanBegan: (() -> Void)?
    var onPanChanged: ((CGSize) -> Void)?
    var onPanEnded: (() -> Void)?
    private var dragStartPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let deviceAdjustedDeltaY = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        onScrollZoom?(convert(event.locationInWindow, from: nil), deviceAdjustedDeltaY)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(convert(event.locationInWindow, from: nil), event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartPoint = convert(event.locationInWindow, from: nil)
        onPanBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }
        let location = convert(event.locationInWindow, from: nil)
        onPanChanged?(CGSize(width: location.x - dragStartPoint.x, height: dragStartPoint.y - location.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        onPanEnded?()
    }
}

func fittedImageRect(
    imageExtent: CGRect,
    containerSize: CGSize,
    zoomScale: Double?,
    panOffset: CGSize = .zero
) -> CGRect {
    guard imageExtent.width > 0, imageExtent.height > 0, containerSize.width > 0, containerSize.height > 0 else {
        return CGRect(origin: .zero, size: containerSize)
    }

    let fitScale = min(containerSize.width / imageExtent.width, containerSize.height / imageExtent.height)
    let scale = zoomScale ?? fitScale
    let drawSize = CGSize(width: imageExtent.width * scale, height: imageExtent.height * scale)
    return CGRect(
        x: ((containerSize.width - drawSize.width) / 2) + panOffset.width,
        y: ((containerSize.height - drawSize.height) / 2) + panOffset.height,
        width: drawSize.width,
        height: drawSize.height
    )
}
