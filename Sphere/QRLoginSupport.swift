import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum SphereQRLoginImage {
    static func uiImage(payload: String, dimension: CGFloat = 240) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct SphereQRLoginQRImage: View {
    let payload: String

    var body: some View {
        if let ui = SphereQRLoginImage.uiImage(payload: payload, dimension: 240) {
            Image(uiImage: ui)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 240, height: 240)
        }
    }
}

/// Scans QR codes and returns the raw string payload (e.g. `sphere://qr-login?...`).
struct SphereQRCodeScannerView: UIViewControllerRepresentable {
    var onPayload: (String) -> Void
    var onError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload, onError: onError)
    }

    func makeUIViewController(context: Context) -> QRScannerHostController {
        let vc = QRScannerHostController(coordinator: context.coordinator)
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerHostController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onPayload: (String) -> Void
        let onError: ((String) -> Void)?
        init(onPayload: @escaping (String) -> Void, onError: ((String) -> Void)?) {
            self.onPayload = onPayload
            self.onError = onError
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let s = obj.stringValue, !s.isEmpty else { return }
            onPayload(s)
        }
    }

    final class QRScannerHostController: UIViewController {
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                coordinator?.onError?("Camera unavailable")
                return
            }
            guard session.canAddInput(input) else {
                coordinator?.onError?("Cannot open camera input")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output), let coord = coordinator else {
                self.coordinator?.onError?("Camera output failed")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coord, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            previewLayer = layer
            view.layer.insertSublayer(layer, at: 0)

            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }
    }
}
