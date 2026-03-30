#if canImport(SwiftUI)
import SwiftUI
import AuthenticationServices

// MARK: - SignInView
//
// Shown as a sheet when the user is not authenticated.
// Uses Google OAuth 2.0 via ASWebAuthenticationSession.

public struct SignInView: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // App icon / logo
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text("SmartTube")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Sign in to access your subscriptions,\nhistory and playlists.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                // Sign-in button
                GoogleSignInButton {
                    signIn()
                }
                .frame(height: 50)
                .padding(.horizontal, 40)

                Button("Continue without signing in") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Sign-In Failed", isPresented: .constant(auth.error != nil), presenting: auth.error) { _ in
                Button("OK", role: .cancel) {}
            } message: { err in
                Text(err.localizedDescription)
            }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }

    private func signIn() {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first
        else { return }
        Task { await auth.signIn(presentationAnchor: window) }
        #elseif os(macOS)
        guard let window = NSApp.windows.first else { return }
        Task { await auth.signIn(presentationAnchor: window) }
        #endif
    }
}

// MARK: - GoogleSignInButton

struct GoogleSignInButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "g.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                Text("Sign in with Google")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.separator), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
#endif
