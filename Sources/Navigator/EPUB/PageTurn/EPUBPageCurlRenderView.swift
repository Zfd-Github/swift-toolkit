//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreImage
import Metal
import MetalKit
import UIKit

@MainActor
final class EPUBPageCurlRenderView: MTKView, MTKViewDelegate {
    /// Left-spine hinge used for both forward peel and reverse uncurl.
    static let leftHingeAngle: CGFloat = .pi

    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let filter: CIFilter
    private var currentImage: CIImage
    private var targetImage: CIImage?
    private let imageExtent: CGRect
    /// Forward peels the current page away; reverse uncurls the target page over it.
    private let isForward: Bool

    var progress: CGFloat = 0 {
        didSet {
            progress = min(max(progress, 0), 1)
            setNeedsDisplay()
        }
    }

    init?(
        currentImage: CGImage,
        paperColor: UIColor,
        isForward: Bool
    ) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let filter = CIFilter(name: "CIPageCurlWithShadowTransition")
        else {
            return nil
        }

        let extent = CGRect(
            x: 0,
            y: 0,
            width: currentImage.width,
            height: currentImage.height
        )
        self.commandQueue = commandQueue
        context = CIContext(mtlDevice: device)
        self.filter = filter
        self.currentImage = CIImage(cgImage: currentImage)
        imageExtent = extent
        self.isForward = isForward

        super.init(frame: extent, device: device)
        autoResizeDrawable = false
        drawableSize = extent.size
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        isOpaque = true
        backgroundColor = paperColor
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        paperColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        clearColor = MTLClearColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Curl hinge is always the left edge (book spine at `.min`).
    static func angle(isForward _: Bool) -> CGFloat {
        leftHingeAngle
    }

    func setCurrentImage(_ image: CGImage) {
        currentImage = CIImage(cgImage: image)
        setNeedsDisplay()
    }

    func setTargetImage(_ image: CGImage) {
        targetImage = CIImage(cgImage: image)
        setNeedsDisplay()
    }

    func outputImage() -> CIImage {
        guard let targetImage else {
            return currentImage
        }
        // Forward: peel current away to reveal target (left hinge).
        // Backward: uncurl target over current so the previous page covers.
        let curlingImage = isForward ? currentImage : targetImage
        let revealedImage = isForward ? targetImage : currentImage
        let time = isForward ? progress : 1 - progress
        filter.setValue(curlingImage, forKey: kCIInputImageKey)
        filter.setValue(revealedImage, forKey: kCIInputTargetImageKey)
        filter.setValue(
            Self.mirroredBacksideImage(from: curlingImage),
            forKey: "inputBacksideImage"
        )
        filter.setValue(CIVector(cgRect: imageExtent), forKey: kCIInputExtentKey)
        filter.setValue(time, forKey: kCIInputTimeKey)
        filter.setValue(Self.leftHingeAngle, forKey: kCIInputAngleKey)
        filter.setValue(max(12, imageExtent.width * 0.04), forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: imageExtent) ?? currentImage
    }

    func backsideImageForRendering() -> CIImage {
        let curlingImage = isForward ? currentImage : (targetImage ?? currentImage)
        return Self.mirroredBacksideImage(from: curlingImage)
    }

    private static func mirroredBacksideImage(from image: CIImage) -> CIImage {
        image.oriented(.upMirrored).cropped(to: image.extent)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        context.render(
            outputImage(),
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: imageExtent,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
