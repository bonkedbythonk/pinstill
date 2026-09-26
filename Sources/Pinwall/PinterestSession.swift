import Foundation
import os
import PinwallCore
import WebKit

enum SessionError: Error, CustomStringConvertible {
    case http(Int, resource: String)
    case badResult

    var description: String {
        switch self {
        case .http(let status, let resource): "Pinterest returned \(status) for \(resource)"
        case .badResult: "Pinterest page returned an unexpected result"
        }
    }
}

/// A persistent, logged-in pinterest.com web view. Its cookies live in the default WebKit
/// data store, so the login survives app restarts. API calls run `fetch` inside the page,
/// reusing Pinterest's own session — no cookies are ever copied out.
@MainActor
final class PinterestSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    /// Called after every finished navigation (used to notice a completed login).
    var onNavigationFinished: ((URL?) -> Void)?

    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private let log = Logger(subsystem: "Pinwall", category: "session")

    static let home = URL(string: "https://www.pinterest.com/")!
    static let login = URL(string: "https://www.pinterest.com/login/")!

    init(dataStore: WKWebsiteDataStore = .default()) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 800), configuration: config)
        // Pinterest serves a degraded page to unknown embedded browsers; present as Safari.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
    }

    /// Makes sure a pinterest.com page is loaded so same-origin `fetch` works.
    func ensureLoaded() async throws {
        if let host = webView.url?.host(), host.hasSuffix("pinterest.com"), !webView.isLoading { return }
        if !webView.isLoading { webView.load(URLRequest(url: Self.home)) }
        try await withCheckedThrowingContinuation { loadWaiters.append($0) }
    }

    func showLoginPage() {
        webView.load(URLRequest(url: Self.login))
    }

    /// Logged-in username, or nil when logged out.
    func username() async throws -> String? {
        do {
            return try PinterestAPI.parseUsername(await resource(PinterestAPI.userSettings, options: [:]))
        } catch SessionError.http(let status, _) where [401, 403, 404].contains(status) {
            return nil
        } catch is PinterestAPIError {
            return nil
        } catch is DecodingError {
            return nil // logged-out pages can answer with HTML instead of JSON
        }
    }

    func boards(username: String) async throws -> [Board] {
        try PinterestAPI.parseBoards(await resource(PinterestAPI.boards, options: PinterestAPI.boardsOptions(username: username)))
    }

    func boardPage(boardID: String, bookmark: String?) async throws -> BoardPage {
        try PinterestAPI.parseBoardFeed(await resource(
            PinterestAPI.boardFeed, options: PinterestAPI.boardFeedOptions(boardID: boardID, bookmark: bookmark)))
    }

    func logOut() async {
        let store = webView.configuration.websiteDataStore
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let pinterest = records.filter { $0.displayName.contains("pinterest") || $0.displayName.contains("pinimg") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: pinterest)
        webView.load(URLRequest(url: Self.home))
    }

    private func resource(_ name: String, options: [String: Any]) async throws -> Data {
        try await ensureLoaded()
        let script = """
            const url = `/resource/${name}/get/?data=${encodeURIComponent(JSON.stringify({ options }))}`;
            const response = await fetch(url, { headers, credentials: "include" });
            return { status: response.status, body: await response.text() };
            """
        let result = try await webView.callAsyncJavaScript(
            script, arguments: ["name": name, "options": options, "headers": PinterestAPI.headers],
            in: nil, contentWorld: .defaultClient)
        guard let dict = result as? [String: Any],
              let status = (dict["status"] as? NSNumber)?.intValue,
              let body = dict["body"] as? String else { throw SessionError.badResult }
        log.debug("\(name, privacy: .public) → \(status)")
        guard status == 200 else { throw SessionError.http(status, resource: name) }
        return Data(body.utf8)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeWaiters(with: nil)
        onNavigationFinished?(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeWaiters(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeWaiters(with: error)
    }

    private func resumeWaiters(with error: Error?) {
        // A navigation replaced by another (redirect, new load) reports "cancelled"; wait for the next one.
        if let error = error as? URLError, error.code == .cancelled { return }
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }
}
