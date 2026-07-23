//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumNavigator
import SwiftUI
import UIKit

class ReaderViewController: UIViewController {
    private let navigator: VisualNavigator & UIViewController
    private let viewModel: ReaderViewModel
    private let topChrome = UILabel()
    private let bottomChrome = UILabel()

    init(viewModel: ReaderViewModel) {
        navigator = viewModel.navigator
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        topChrome.text = "TOP|waiting"
        topChrome.accessibilityIdentifier = AccessibilityID.pageTurnTopChrome.rawValue
        topChrome.backgroundColor = UIColor(red: 0.08, green: 0.62, blue: 0.86, alpha: 1)
        topChrome.textColor = .white
        bottomChrome.text = "BOTTOM|waiting"
        bottomChrome.accessibilityIdentifier = AccessibilityID.pageTurnBottomChrome.rawValue
        bottomChrome.backgroundColor = UIColor(red: 0.95, green: 0.62, blue: 0.08, alpha: 1)
        bottomChrome.textColor = .black

        addChild(navigator)
        navigator.view.accessibilityIdentifier = AccessibilityID.readerViewport.rawValue
        view.addSubview(topChrome)
        view.addSubview(navigator.view)
        view.addSubview(bottomChrome)
        navigator.didMove(toParent: self)

        viewModel.pageTurnRootView = view
        viewModel.pageTurnTopChrome = topChrome
        viewModel.pageTurnBottomChrome = bottomChrome
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topHeight: CGFloat = 64
        let bottomHeight: CGFloat = 44
        topChrome.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: topHeight)
        navigator.view.frame = CGRect(
            x: 0,
            y: topHeight,
            width: view.bounds.width,
            height: max(0, view.bounds.height - topHeight - bottomHeight)
        )
        bottomChrome.frame = CGRect(
            x: 0,
            y: max(0, view.bounds.height - bottomHeight),
            width: view.bounds.width,
            height: bottomHeight
        )
    }
}

struct ReaderViewControllerWrapper: UIViewControllerRepresentable {
    let viewModel: ReaderViewModel

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(viewModel: viewModel)
    }

    func updateUIViewController(_ uiViewController: ReaderViewController, context: Context) {}
}
