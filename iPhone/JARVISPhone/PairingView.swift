import AVFoundation
import SwiftUI

/// Pairing: the QR code or the code the Mac shows in Settings, iPhone section.
struct PairingView: View {
    @ObservedObject var assistant: Assistant
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var host = ""
    @State private var scanning = false
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sul Mac apri le Impostazioni di JARVIS, sezione iPhone: accendi il collegamento, premi Salva e mostra il codice.")
                        .font(.subheadline)
                    Button("Inquadra il QR") { scanning = true }
                }
                Section("Oppure scrivilo") {
                    TextField("Codice di abbinamento", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("Nome o indirizzo del Mac (facoltativo)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Abbina") {
                        assistant.pair(code: code, host: host)
                        dismiss()
                    }
                    .disabled(!PhoneLink.isValid(code))
                }
                if assistant.isPaired {
                    Section {
                        Toggle("Ascolta la parola Jarvis", isOn: $assistant.earEnabled)
                    } footer: {
                        Text("Solo con l'app aperta. Lo schermo resta acceso e il riconoscimento avviene qui: la voce parte per il Mac solo dopo il suono.")
                    }
                    Section {
                        if confirmForget {
                            Text("Per ricollegarti servirà di nuovo il codice.").font(.subheadline)
                            Button("Dimentica", role: .destructive) {
                                assistant.forget()
                                confirmForget = false
                            }
                            Button("Annulla") { confirmForget = false }
                        } else {
                            Button("Dimentica questo Mac", role: .destructive) { confirmForget = true }
                        }
                    }
                }
            }
            .navigationTitle("Abbinamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .onAppear {
                host = assistant.host
                #if targetEnvironment(simulator)
                // On the simulator you cannot paste: tests fill in the fields from here.
                let arguments = CommandLine.arguments
                if let i = arguments.firstIndex(of: "--test-prefill"), i + 2 < arguments.count {
                    code = arguments[i + 1]
                    host = arguments[i + 2]
                }
                #endif
            }
            .fullScreenCover(isPresented: $scanning) {
                ScannerScreen { value in
                    scanning = false
                    guard let parts = URLComponents(string: value), parts.scheme == "jarvis",
                          let scanned = parts.queryItems?.first(where: { $0.name == "code" })?.value,
                          PhoneLink.isValid(scanned) else { return }
                    let scannedHost = parts.queryItems?.first(where: { $0.name == "host" })?.value ?? ""
                    let outside = parts.queryItems?.first(where: { $0.name == "outside" })?.value ?? ""
                    assistant.pair(code: scanned, host: scannedHost, outside: outside)
                    dismiss()
                } onCancel: {
                    scanning = false
                }
            }
        }
    }
}

private struct ScannerScreen: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScanner(onCode: onCode).ignoresSafeArea()
            Button("Annulla", action: onCancel)
                .buttonStyle(.borderedProminent)
                .padding()
        }
    }
}

/// The camera is needed only here and turns off as soon as the QR code is read.
private struct QRScanner: UIViewRepresentable {
    let onCode: (String) -> Void

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            session.stopRunning()
            onCode(value)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.backgroundColor = .black
        let coordinator = context.coordinator
        view.previewLayer.session = coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        Task.detached {
            guard await AVCaptureDevice.requestAccess(for: .video),
                  let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera) else { return }
            let session = coordinator.session
            session.beginConfiguration()
            let output = AVCaptureMetadataOutput()
            if session.canAddInput(input), session.canAddOutput(output) {
                session.addInput(input)
                session.addOutput(output)
                output.setMetadataObjectsDelegate(coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            session.startRunning()
        }
        return view
    }

    func updateUIView(_ uiView: Preview, context: Context) {}

    static func dismantleUIView(_ uiView: Preview, coordinator: Coordinator) {
        coordinator.session.stopRunning()
    }
}
