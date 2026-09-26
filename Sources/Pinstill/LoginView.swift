import SwiftUI

/// Pinterest's own login page in the session's web view. Calls `onLoggedIn` once logged in.
struct LoginView: View {
    let onLoggedIn: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            LoginNotice()
                .padding(10)
            Divider()
            WebViewHost(webView: model.session.webView)
        }
        .frame(minWidth: 420, minHeight: 600)
        .loginWatcher(onLoggedIn: onLoggedIn)
    }
}

/// "Your password goes to Pinterest, not Pinstill."
struct LoginNotice: View {
    var body: some View {
        Label("You're logging in on pinterest.com. Pinstill never sees your password; it only keeps the session cookie on this Mac.",
              systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Loads Pinterest's login page and reports when the session is logged in.
    func loginWatcher(onLoggedIn: @escaping () -> Void) -> some View {
        modifier(LoginWatcher(onLoggedIn: onLoggedIn))
    }
}

private struct LoginWatcher: ViewModifier {
    let onLoggedIn: () -> Void
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.session.showLoginPage() }
            .task {
                // Some logins (QR code) finish without a page load; check periodically as a fallback.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if case .loggedIn = model.account { break }
                    await model.checkAccount()
                }
            }
            .onChange(of: model.account) { _, account in
                if case .loggedIn = account { onLoggedIn() }
            }
    }
}
