import SwiftUI
import AVFoundation
import UIKit

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token = ""
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Theme.background()
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 40)
                    PiMark(size: 76)
                    Text("连接 Pi")
                        .appFont(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("在 Mac 上运行 pi-mobile gateway，扫描终端里的二维码，或粘贴完整 HTTPS 配对链接。")
                        .appFont(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    VStack(spacing: 14) {
                        Button {
                            showScanner = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "qrcode.viewfinder")
                                    .appFont(.system(size: 18, weight: .semibold))
                                Text("扫描二维码")
                                    .appFont(.headline)
                            }
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .piGlassCard(radius: 18, tint: Theme.ocean.opacity(0.22))
                        }
                        .buttonStyle(bouncy())

                        HStack(spacing: 10) {
                            TextField("粘贴完整配对链接", text: $token)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.textPrimary)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .piGlassCard(radius: 16)
                            Button("连接") {
                                model.pair(token: token)
                            }
                            .appFont(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .piGlassCard(radius: 16, tint: Theme.ocean.opacity(0.3))
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(18)
                    .piGlassCard(radius: 24)

                    if let error = model.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                            Spacer()
                            Button { model.clearError() } label: {
                                Image(systemName: "xmark")
                            }
                        }
                        .appFont(.footnote)
                        .foregroundStyle(Theme.coral)
                        .padding(12)
                        .piGlassCard(radius: 16, tint: Theme.coral.opacity(0.12))
                        .transition(PiMotion.bannerTransition)
                    }
                    Spacer(minLength: 40)
                }
                .animation(PiMotion.smooth(reduceMotion), value: model.errorMessage)
                .padding(24)
            }
        }
        .sheet(isPresented: $showScanner) {
            PairScanner { code in
                showScanner = false
                token = code
                model.pair(token: code)
            }
        }
    }
}

struct PairScanner: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanProgress: CGFloat = 0

    var body: some View {
        ZStack {
            ScannerView(onFound: onFound)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("扫描配对二维码")
                        .appFont(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    PiIconButton(systemName: "xmark") {
                        PiHaptics.tap()
                        dismiss()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.black.opacity(0.18))
                    if !reduceMotion {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Theme.ocean.opacity(0.8), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 2.5)
                            .shadow(color: Theme.ocean.opacity(0.75), radius: 6)
                            .offset(y: -110 + scanProgress * 220)
                    }
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Theme.mist.opacity(0.85), lineWidth: 2)
                }
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                        scanProgress = 1
                    }
                }
                Spacer()
                Text("把 Mac 终端里的二维码放进框内；无法使用相机时，返回粘贴完整配对链接。")
                    .appFont(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct ScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let statusLabel = UILabel()
    private var didFindCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupStatusLabel()
        startAfterPermissionCheck()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configurePreviewRotation(device: AVCaptureDevice, preview: AVCaptureVideoPreviewLayer) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = self?.previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    private func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.backgroundColor = UIColor(white: 0, alpha: 0.65)
        statusLabel.layer.cornerRadius = 12
        statusLabel.clipsToBounds = true
        statusLabel.isHidden = true
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func showStatus(_ text: String?) {
        guard let text, !text.isEmpty else {
            statusLabel.isHidden = true
            statusLabel.alpha = 0
            return
        }
        statusLabel.text = text
        statusLabel.isHidden = false
        statusLabel.alpha = 0
        UIView.animate(withDuration: 0.2) { self.statusLabel.alpha = 1 }
    }

    private func startAfterPermissionCheck() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            showStatus("正在请求相机权限…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startSession()
                    } else {
                        self.showStatus("没有相机权限。请在系统设置中允许 Pi Mobile 使用相机，或返回粘贴完整配对链接。")
                    }
                }
            }
        case .denied, .restricted:
            showStatus("没有相机权限。请在系统设置中允许 Pi Mobile 使用相机，或返回粘贴完整配对链接。")
        @unknown default:
            showStatus("无法使用相机，请返回粘贴完整配对链接。")
        }
    }

    private func startSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            showStatus("此设备没有可用的摄像头，请返回粘贴完整配对链接。")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                showStatus("无法启用摄像头，请返回粘贴完整配对链接。")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                showStatus("无法启用二维码识别，请返回粘贴完整配对链接。")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            configurePreviewRotation(device: device, preview: preview)

            output.setMetadataObjectsDelegate(self, queue: .main)
            session.startRunning()

            // 必须先 addOutput 再设置 metadataObjectTypes：输出未接入 session 时
            // availableMetadataObjectTypes 为空，直接设 [.qr] 会抛
            // NSInvalidArgumentException，扫码页一打开就闪退。
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                session.stopRunning()
                showStatus("此设备不支持二维码识别，请返回粘贴完整配对链接。")
                return
            }
            output.metadataObjectTypes = [.qr]
            showStatus(nil)
        } catch {
            showStatus("摄像头初始化失败：\(error.localizedDescription)")
        }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didFindCode,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty else { return }
        didFindCode = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        stopSession()
        onFound?(value)
    }
}
