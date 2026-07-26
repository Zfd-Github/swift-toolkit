//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import QuartzCore
import UIKit

@MainActor
final class EPUBPageCurlController {
    let view: EPUBPageCurlRenderView
    private(set) var hasTarget = false
    private var activeFrameWaiter: PageTurnAnimationFrameWaiter?

    var progress: CGFloat {
        view.progress
    }

    init?(
        currentImage: CGImage,
        paperColor: UIColor,
        isForward: Bool
    ) {
        guard let view = EPUBPageCurlRenderView(
            currentImage: currentImage,
            paperColor: paperColor,
            isForward: isForward
        ) else {
            return nil
        }
        self.view = view
    }

    static func rasterize(_ view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(for: view.traitCollection)
        format.scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        format.opaque = view.isOpaque
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            if view.window == nil {
                view.layer.render(in: context.cgContext)
            } else if !view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) {
                view.layer.render(in: context.cgContext)
            }
        }
    }

    func setCurrentImage(_ image: CGImage) {
        view.setCurrentImage(image)
    }

    func setTargetImage(_ image: CGImage) {
        hasTarget = true
        view.setTargetImage(image)
        view.progress = progress
    }

    func render(progress: CGFloat) {
        view.progress = progress
    }

    func cancelAnimation() {
        activeFrameWaiter?.cancel()
        activeFrameWaiter = nil
    }

    func animate(
        to targetProgress: CGFloat,
        duration: TimeInterval,
        scheduleDisplayFrame: (@MainActor (PageTurnAnimationFrameWaiter) -> Void)? = nil,
        shouldContinue: @MainActor () -> Bool = { true }
    ) async -> Bool {
        let startProgress = progress
        guard duration > 0 else {
            guard shouldContinue() else { return false }
            render(progress: targetProgress)
            return true
        }
        // Cancelled tasks make frame waits return immediately; snap instead of
        // spinning on the main actor until wall-clock duration elapses.
        if Task.isCancelled {
            render(progress: targetProgress)
            return shouldContinue()
        }
        let startTime = CACurrentMediaTime()
        var elapsed: TimeInterval = 0
        while elapsed < duration {
            guard shouldContinue() else { return false }
            if Task.isCancelled {
                render(progress: targetProgress)
                return shouldContinue()
            }
            if let scheduleDisplayFrame {
                await PageTurnAnimationFrameWaiter.wait(
                    scheduleDisplayFrame: scheduleDisplayFrame,
                    registerWaiter: { self.activeFrameWaiter = $0 }
                )
            } else {
                await PageTurnAnimationFrameWaiter.wait(
                    registerWaiter: { self.activeFrameWaiter = $0 }
                )
            }
            activeFrameWaiter = nil
            if Task.isCancelled {
                render(progress: targetProgress)
                return shouldContinue()
            }
            guard shouldContinue() else { return false }
            elapsed = CACurrentMediaTime() - startTime
            let fraction = min(max(elapsed / duration, 0), 1)
            let eased = 1 - pow(1 - fraction, 3)
            render(progress: startProgress + (targetProgress - startProgress) * eased)
        }
        render(progress: targetProgress)
        return true
    }
}
