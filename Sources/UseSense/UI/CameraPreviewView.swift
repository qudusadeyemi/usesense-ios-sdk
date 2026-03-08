#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import AVFoundation

/// Hosts the AVCaptureVideoPreviewLayer inside a UIView whose `layoutSubviews`
/// keeps the layer frame in sync with the view bounds, avoiding the black-frame
/// flash caused by the zero-bounds race in UIViewRepresentable.
private class PreviewHostView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // CALayer does not participate in Auto Layout – keep it in sync manually.
        previewLayer.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewHostView {
        PreviewHostView(previewLayer: previewLayer)
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        // layoutSubviews handles frame updates automatically.
    }
}
#endif
