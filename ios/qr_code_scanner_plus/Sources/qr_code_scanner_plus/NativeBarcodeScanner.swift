import AVFoundation
import UIKit

/// Camera position matching Flutter's expected rawValue mapping (0=back, 1=front).
enum CameraPosition: UInt {
    case back = 0
    case front = 1

    var capturePosition: AVCaptureDevice.Position {
        switch self {
        case .back: return .back
        case .front: return .front
        }
    }
}

/// A native AVFoundation barcode scanner that replaces MTBBarcodeScanner.
class NativeBarcodeScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {

    // MARK: - Public callbacks

    /// Called when barcodes are detected. Delivers the array of metadata objects.
    var onCodesDetected: (([AVMetadataMachineReadableCodeObject]) -> Void)?

    /// Called once after the capture session starts running.
    var onScanningStarted: (() -> Void)?

    // MARK: - Public properties

    /// The current camera position.
    private(set) var camera: CameraPosition

    /// The scan rect in preview-layer coordinates. Automatically converted to
    /// metadata output rect when set.
    var scanRect: CGRect? {
        didSet {
            applyScanRect()
        }
    }

    // MARK: - Private state

    private let previewView: UIView
    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?

    /// Stays `true` between startScanning and stopScanning, even while frozen.
    private var isSessionStarted = false

    /// `true` while the session is paused via freezeCapture.
    private var isFrozen = false

    /// Background queue for session start/stop to avoid UI blocking.
    private let sessionQueue = DispatchQueue(label: "NativeBarcodeScanner.session")

    // MARK: - Init

    init(previewView: UIView, cameraPosition: CameraPosition = .back) {
        self.previewView = previewView
        self.camera = cameraPosition
        super.init()
    }

    // MARK: - Permission

    static func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Scanning lifecycle

    func startScanning() throws {
        guard !isSessionStarted else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        // Input
        guard let device = captureDevice(for: camera.capturePosition) else {
            throw NSError(domain: "NativeBarcodeScanner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera available for position \(camera.rawValue)"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        // Metadata output
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes
        self.metadataOutput = output

        // Preview layer
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewView.bounds

        self.session = session
        self.previewLayer = layer
        self.isSessionStarted = true
        self.isFrozen = false

        DispatchQueue.main.async {
            self.previewView.layer.insertSublayer(layer, at: 0)
        }

        sessionQueue.async {
            session.startRunning()
            DispatchQueue.main.async {
                self.applyScanRect()
                self.onScanningStarted?()
            }
        }
    }

    func stopScanning() {
        guard isSessionStarted else { return }
        isSessionStarted = false
        isFrozen = false

        let sess = session
        sessionQueue.async {
            if sess?.isRunning == true {
                sess?.stopRunning()
            }
            DispatchQueue.main.async {
                _ = sess
            }
        }

        DispatchQueue.main.async {
            self.previewLayer?.removeFromSuperlayer()
            self.previewLayer = nil
        }

        session = nil
        metadataOutput = nil
    }

    // MARK: - Freeze / Unfreeze

    func freezeCapture() {
        guard isSessionStarted, !isFrozen else { return }
        isFrozen = true
        let sess = session
        sessionQueue.async {
            sess?.stopRunning()
        }
    }

    func unfreezeCapture() {
        guard isSessionStarted, isFrozen else { return }
        isFrozen = false
        let sess = session
        sessionQueue.async {
            sess?.startRunning()
        }
    }

    // MARK: - State queries

    func isScanning() -> Bool {
        return isSessionStarted && !isFrozen
    }

    // MARK: - Camera

    func flipCamera() {
        guard let session = session else { return }
        let newPosition: CameraPosition = (camera == .back) ? .front : .back
        guard let newDevice = captureDevice(for: newPosition.capturePosition) else { return }

        session.beginConfiguration()
        // Remove existing input
        if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
            session.removeInput(currentInput)
        }
        // Add new input
        if let newInput = try? AVCaptureDeviceInput(device: newDevice),
           session.canAddInput(newInput) {
            session.addInput(newInput)
            camera = newPosition
        }
        session.commitConfiguration()
    }

    func hasOppositeCamera() -> Bool {
        let opposite: AVCaptureDevice.Position = (camera == .back) ? .front : .back
        return captureDevice(for: opposite) != nil
    }

    // MARK: - Torch

    func toggleTorch() {
        guard let device = currentDevice(), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = (device.torchMode == .on) ? .off : .on
            device.unlockForConfiguration()
        } catch {
            // Silently fail — matches MTBBarcodeScanner behaviour.
        }
    }

    func hasTorch() -> Bool {
        return currentDevice()?.hasTorch ?? false
    }

    var isTorchOn: Bool {
        return currentDevice()?.torchMode == .on
    }

    // MARK: - Preview layer access

    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return previewLayer
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let codes = metadataObjects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }
        if !codes.isEmpty {
            onCodesDetected?(codes)
        }
    }

    // MARK: - Private helpers

    private func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discoverySession.devices.first
    }

    private func currentDevice() -> AVCaptureDevice? {
        return (session?.inputs.first as? AVCaptureDeviceInput)?.device
    }

    private func applyScanRect() {
        guard let layer = previewLayer, let rect = scanRect else {
            metadataOutput?.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        metadataOutput?.rectOfInterest = layer.metadataOutputRectConverted(fromLayerRect: rect)
    }
}
