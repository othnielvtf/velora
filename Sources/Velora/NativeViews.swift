import SwiftUI
import AVKit

struct SlimVolumeSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeCoordinator() -> Coordinator { Coordinator($value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = SlimVolumeSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.controlSize = .mini
        slider.isEnabled = context.environment.isEnabled
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("Volume")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.isEnabled = context.environment.isEnabled
        if abs(slider.doubleValue - value) > 0.0001 { slider.doubleValue = value }
        slider.setAccessibilityValueDescription("\(Int(value * 100)) percent")
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(_ value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
    }
}

private final class SlimVolumeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let centerY = controlView?.bounds.midY ?? rect.midY
        let handle = knobRect(flipped: flipped)
        let track = NSRect(x: rect.minX + handle.width / 2, y: centerY - 1,
                           width: max(0, rect.width - handle.width), height: 2)
        NSColor(white: 1, alpha: isEnabled ? 0.2 : 0.08).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        let fill = NSRect(x: track.minX, y: track.minY, width: min(track.width, max(0, handle.midX - track.minX)), height: 2)
        NSColor(red: 0.68, green: 0.59, blue: 1, alpha: isEnabled ? 0.8 : 0.3).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let centerY = controlView?.bounds.midY ?? knobRect.midY
        let knob = NSRect(x: knobRect.midX - 3, y: centerY - 3, width: 6, height: 6)
        NSColor(white: 1, alpha: isEnabled ? 0.88 : 0.3).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}

struct MovieSurface: NSViewRepresentable {
    let player: AVPlayer
    var liftCaptions = false
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        if context.coordinator.item !== player.currentItem || context.coordinator.lifted != liftCaptions {
            // Keep native captions above the floating controls, and restore source
            // placement when those controls fade or the window leaves fullscreen.
            let rule = liftCaptions ? AVTextStyleRule(textMarkupAttributes: [
                kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String: 84
            ]) : nil
            player.currentItem?.textStyleRules = rule.map { [$0] }
            context.coordinator.item = player.currentItem
            context.coordinator.lifted = liftCaptions
        }
    }

    final class Coordinator {
        weak var item: AVPlayerItem?
        var lifted: Bool?
    }
}

struct AirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    var onPresentationChange: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(onPresentationChange) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.delegate = context.coordinator
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor(red: 0.68, green: 0.58, blue: 1, alpha: 1), for: .active)
        view.setAccessibilityLabel("Choose an AirPlay TV")
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
        context.coordinator.onPresentationChange = onPresentationChange
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentationChange: (Bool) -> Void
        init(_ onPresentationChange: @escaping (Bool) -> Void) { self.onPresentationChange = onPresentationChange }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresentationChange(true) }
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresentationChange(false) }
    }
}
