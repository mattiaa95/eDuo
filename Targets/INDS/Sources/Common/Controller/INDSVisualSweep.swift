#if DEBUG
//
//  INDSVisualSweep.swift
//  eDuo
//
//  The visual sibling of `INDSLayoutSweep` (launch argument
//  `-iNDSVisualSweep`): instead of validating numbers it RENDERS the real
//  emulation screen — `DSDualScreenView` + `NDSControllerView`, the same
//  classes and the same production geometry — to PNGs inside synthetic
//  containers. It does NOT simulate any foldable device, its dimensions,
//  hinge or reserved regions. The PNGs are written to
//  `Documents/visual-sweep/` and the process exits.
//
//  Accepted limitation: it draws with `layer.render(in:)` off-window, so the
//  blurs behind the HUD pills do not come out. What is judged here is the
//  composition: screens, band and buttons.
//

import UIKit

enum INDSVisualSweep {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-iNDSVisualSweep") else { return }

        // Arbitrary container sizes in points, not hardware specifications.
        let cases: [(CGSize, String)] = [
            (CGSize(width: 430, height: 932), "compact-portrait"),
            (CGSize(width: 932, height: 430), "compact-landscape"),
            (CGSize(width: 700, height: 840), "expanded-portrait"),
            (CGSize(width: 840, height: 700), "expanded-landscape"),
            (CGSize(width: 800, height: 800), "square"),
            (CGSize(width: 1032, height: 1376), "large-portrait"),
            (CGSize(width: 1376, height: 1032), "large-landscape"),
            (CGSize(width: 507, height: 1376), "medium-window"),
            (CGSize(width: 375, height: 1112), "narrow-window"),
            // iPhone Duo, measured on the simulator 21-sep-2026 (the device
            // profile's `capabilities.plist`): inner 2007×2853 px @3 = 669×951
            // pt, outer 1398×2034 = 466×678. The 626×890 that was used here
            // before is not any display this device has. The hinge is not
            // drawn — what is judged is where the panels and controls land.
            (CGSize(width: 669, height: 951), "duo-inner-portrait"),
            (CGSize(width: 951, height: 669), "duo-inner-landscape"),
            // Lo que recibe una build con SDK anterior al 27.1.
            (CGSize(width: 669, height: 871), "duo-inner-portrait-sdk270"),
            (CGSize(width: 466, height: 678), "duo-outer-portrait"),
            (CGSize(width: 678, height: 466), "duo-outer-landscape"),
        ]

        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { exit(1) }
        let dir = docs.appendingPathComponent("visual-sweep", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (size, name) in cases {
            let image = render(size: size)
            let url = dir.appendingPathComponent("\(name)-\(Int(size.width))x\(Int(size.height)).png")
            try? image.pngData()?.write(to: url)
        }
        try? "done".write(to: dir.appendingPathComponent("DONE.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Composes the emulation screen from the production views and draws it
    /// off-screen. The real controls and HUD resolve their own layout.
    private static func render(size: CGSize) -> UIImage {
        let container = UIView(frame: CGRect(origin: .zero, size: size))
        container.backgroundColor = UIColor(white: 0.05, alpha: 1)

        let isPortrait = size.height >= size.width
        let mode: DSScreenLayoutMode = isPortrait || DSConsoleLayout(in: size) != nil ? .stacked : .sideBySide

        let dual = DSDualScreenView(frame: container.bounds)
        container.addSubview(dual)
        dual.topScreenView.image = testPattern(label: "TOP", base: UIColor(red: 0.55, green: 0.10, blue: 0.16, alpha: 1))
        dual.bottomScreenView.image = testPattern(label: "TOUCH", base: UIColor(red: 0.09, green: 0.32, blue: 0.36, alpha: 1))
        dual.applyLayout(mode: mode, swap: false, stretch: false, animated: false)

        let controller = NDSControllerView(frame: container.bounds)
        controller.screenLayoutMode = mode
        container.addSubview(controller)
        let hud = NDSHUDView(frame: container.bounds)
        hud.setLayoutIcon(mode)
        container.addSubview(hud)

        container.setNeedsLayout()
        container.layoutIfNeeded()
        // DSDualScreenView's layoutSubviews re-applies the mode with the
        // final bounds; an explicit second pass keeps us from being left with
        // the pre-layout frame.
        dual.applyLayout(mode: mode, swap: false, stretch: false, animated: false)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            container.layer.render(in: ctx.cgContext)
        }
    }

    /// A fake DS framebuffer (256×192): base colour, grid, border and a big
    /// label — enough to see where each screen lands, whether the 4:3 aspect
    /// holds and how much room it takes.
    private static func testPattern(label: String, base: UIColor) -> UIImage {
        let size = CGSize(width: 256, height: 192)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 1, alpha: 0.12).setStroke()
            let path = UIBezierPath()
            for x in stride(from: 0, through: 256, by: 32) {
                path.move(to: CGPoint(x: CGFloat(x), y: 0)); path.addLine(to: CGPoint(x: CGFloat(x), y: 192))
            }
            for y in stride(from: 0, through: 192, by: 32) {
                path.move(to: CGPoint(x: 0, y: CGFloat(y))); path.addLine(to: CGPoint(x: 256, y: CGFloat(y)))
            }
            path.stroke()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            let border = UIBezierPath(rect: CGRect(x: 1, y: 1, width: 254, height: 190))
            border.lineWidth = 2
            border.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let text = NSAttributedString(string: label, attributes: attrs)
            let bounds = text.boundingRect(with: size, options: [], context: nil)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
    }
}
#endif
