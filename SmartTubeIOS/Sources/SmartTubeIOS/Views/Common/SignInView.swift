import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - SignInView
//
// Google Device Authorization Grant sign-in UI (mirrors Android's equivalent).
// No browser redirect — the user enters a short code at youtube.com/activate.

public struct SignInView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let info = auth.pendingActivation {
                    activationView(info: info)
                } else {
                    loadingView
                }
            }
            .navigationTitle("Sign In")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        auth.cancelSignIn()
                        dismiss()
                    }
                }
            }
            .alert("Sign-In Failed", isPresented: $showError, presenting: auth.error) { _ in
                Button("Try Again") { Task { await auth.beginSignIn() } }
                Button("Cancel", role: .cancel) { auth.error = nil }
            } message: { err in
                Text(err.localizedDescription)
            }
            .onChange(of: auth.error == nil ? 0 : 1) { _, hasError in
                if hasError == 1 { showError = true }
            }
        }
        .task {
            await auth.beginSignIn()
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }

    // MARK: - Loading screen

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to Google…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Activation code screen

    /// Builds the URL that Google accepts to auto-fill the user code:
    /// https://www.google.com/device?user_code=XXXX-XXXX
    private func activationQRURL(info: AuthService.ActivationInfo) -> String {
        guard var components = URLComponents(url: info.verificationURL, resolvingAgainstBaseURL: false) else {
            return info.verificationURL.absoluteString
        }
        let existing = components.queryItems ?? []
        components.queryItems = existing + [URLQueryItem(name: "user_code", value: info.userCode)]
        return components.url?.absoluteString ?? info.verificationURL.absoluteString
    }

    private func activationView(info: AuthService.ActivationInfo) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)

                VStack(spacing: 6) {
                    Text("Activate SmartTube")
                        .font(.title2).fontWeight(.bold)
                    Text("On any device, open the link below and enter the code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // QR code — scan to open the activation URL with code pre-filled
                QRCodeView(content: activationQRURL(info: info))
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)

                VStack(spacing: 4) {
                    Text("Scan to open activation page")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(info.verificationURL.absoluteString,
                         destination: URL(string: activationQRURL(info: info)) ?? info.verificationURL)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                // User code box
                Text(info.userCode)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .padding(.vertical, 20)
                    .padding(.horizontal, 32)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = info.userCode
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.userCode, forType: .string)
                    #endif
                } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                // Countdown
                CountdownView(expiresAt: info.expiresAt) {
                    // Code expired — restart
                    Task { await auth.beginSignIn() }
                }

                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for authorisation…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                Button(role: .cancel) {
                    auth.cancelSignIn()
                } label: {
                    Text("Use a different account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
    }
}

// MARK: - QRCodeView

private struct QRCodeView: View {
    let content: String

    var body: some View {
        if let img = makeQRImage() {
            GeometryReader { geo in
                img
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private func makeQRImage() -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.correctionLevel = "M"
        guard let data = content.data(using: .utf8) else { return nil }
        filter.message = data

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up so the QR is crisp at any display size
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: scale)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        #if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        return Image(nsImage: nsImage)
        #else
        let uiImage = UIImage(cgImage: cgImage)
        return Image(uiImage: uiImage)
        #endif
    }
}

// MARK: - CountdownView

private struct CountdownView: View {
    let expiresAt: Date
    let onExpired: () -> Void

    @State private var remaining: TimeInterval = 0

    var body: some View {
        Group {
            if remaining > 0 {
                Label(timeString, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Code expired")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            remaining = max(0, expiresAt.timeIntervalSinceNow)
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                remaining = max(0, expiresAt.timeIntervalSinceNow)
            }
            onExpired()
        }
    }

    private var timeString: String {
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "Code expires in %d:%02d", mins, secs)
    }
}
