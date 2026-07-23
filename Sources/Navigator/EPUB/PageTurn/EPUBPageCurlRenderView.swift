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
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let filter: CIFilter
    private var currentImage: CIImage
    private var targetImage: CIImage?
    private let backsideImage: CIImage
    private let imageExtent: CGRect
    private let curlAngle: CGFloat

    var progress: CGFloat = 0 {
        didSet {
            progress = min(max(progress, 0), 1)
            setNeedsDisplay()
        }
    }

    init?(
        currentImage: CGImage,
        paperColor: UIColor,
        physicalCompletionDirection: EPUBSpreadView.Direction
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
        backsideImage = CIImage(color: CIColor(color: paperColor)).cropped(to: extent)
        imageExtent = extent
        curlAngle = Self.angle(for: physicalCompletionDirection)

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

    static func angle(
        for physicalCompletionDirection: EPUBSpreadView.Direction
    ) -> CGFloat {
        physicalCompletionDirection == .left ? 0 : .pi
    }

    func setCurrentImage(_ image: CGImage) {
        currentImage = CIImage(cgImage: image)
        setNeedsDisplay()
    }

    func setTargetImage(_ image: CGImage) {
        targetImage = CIImage(cgImage: image)
        setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let output: CIImage
        if let targetImage {
            filter.setValue(currentImage, forKey: kCIInputImageKey)
            filter.setValue(targetImage, forKey: kCIInputTargetImageKey)
            filter.setValue(backsideImage, forKey: "inputBacksideImage")
            filter.setValue(CIVector(cgRect: imageExtent), forKey: kCIInputExtentKey)
            filter.setValue(progress, forKey: kCIInputTimeKey)
            filter.setValue(curlAngle, forKey: kCIInputAngleKey)
            filter.setValue(max(12, imageExtent.width * 0.04), forKey: kCIInputRadiusKey)
            output = filter.outputImage?.cropped(to: imageExtent) ?? currentImage
        } else {
            output = currentImage
        }

        context.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: imageExtent,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
