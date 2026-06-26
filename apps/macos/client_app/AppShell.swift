import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

final class MacClientAppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var fallbackView: NSView!
    private var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        loadStationUrlIfAvailable()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "plushpalLog")
        userContentController.addUserScript(WKUserScript(
            source: """
            (() => {
              const stringify = (value) => {
                try {
                  if (value instanceof Error) return value.stack || value.message;
                  if (typeof value === 'string') return value;
                  return JSON.stringify(value);
                } catch (_) {
                  return String(value);
                }
              };
              const send = (level, values) => {
                try {
                  window.webkit.messageHandlers.plushpalLog.postMessage({
                    level,
                    message: Array.from(values).map(stringify).join(' '),
                    url: window.location.href,
                  });
                } catch (_) {}
              };
              for (const level of ['log', 'warn', 'error']) {
                const original = console[level];
                console[level] = function(...args) {
                  send(`console.${level}`, args);
                  return original.apply(this, args);
                };
              }
              window.addEventListener('error', (event) => {
                send('window.error', [
                  event.message,
                  `${event.filename || ''}:${event.lineno || 0}:${event.colno || 0}`,
                ]);
              });
              window.addEventListener('unhandledrejection', (event) => {
                send('window.unhandledrejection', [event.reason]);
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true

        fallbackView = NSView()
        fallbackView.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Open PlushBuddy from Station")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(wrappingLabelWithString: """
        PlushBuddy is the Mac client UI. Start PlushBuddy Station first so it can prepare voice services, then click “Open PlushBuddy Mac app” in Station.
        """)
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let openStationButton = NSButton(title: "Open PlushBuddy Station", target: self, action: #selector(openStation))
        openStationButton.bezelStyle = .rounded
        openStationButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, statusLabel, openStationButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        fallbackView.addSubview(stack)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fallbackView)
        content.addSubview(webView)

        NSLayoutConstraint.activate([
            fallbackView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fallbackView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fallbackView.topAnchor.constraint(equalTo: content.topAnchor),
            fallbackView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: fallbackView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fallbackView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: fallbackView.leadingAnchor, constant: 60),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: fallbackView.trailingAnchor, constant: -60),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            openStationButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PlushBuddy"
        window.minSize = NSSize(width: 820, height: 600)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
    }

    private func loadStationUrlIfAvailable() {
        if let url = stationUrlFromArguments() ?? persistedStationUrl() {
            load(url)
        } else {
            fallbackView.isHidden = false
            webView.isHidden = true
        }
    }

    private func load(_ url: URL) {
        appendLog("client-app.log", "loading station url \(url.absoluteString)")
        fallbackView.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: url))
    }

    private func stationUrlFromArguments() -> URL? {
        let args = CommandLine.arguments
        for index in args.indices {
            guard args[index] == "--station-url", args.indices.contains(index + 1) else { continue }
            return URL(string: args[index + 1])
        }
        if let value = ProcessInfo.processInfo.environment["PLUSHBUDDY_STATION_URL"] {
            return URL(string: value)
        }
        return nil
    }

    private func persistedStationUrl() -> URL? {
        let file = applicationSupportDirectory()
            .appendingPathComponent("Station", isDirectory: true)
            .appendingPathComponent("latest-client-url.txt", isDirectory: false)
        guard let text = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return URL(string: text)
    }

    @objc private func openStation() {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PlushBuddy Station.app", isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PlushPal.app", isDirectory: true),
        ]
        if let station = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.openApplication(at: station, configuration: NSWorkspace.OpenConfiguration())
        } else {
            statusLabel.stringValue = "I could not find PlushBuddy Station next to this app. Open Station manually, then launch this app from Station."
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendLog("client-app.log", "navigation finished \(webView.url?.absoluteString ?? "<unknown>")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    private func showLoadFailure(_ error: Error) {
        appendLog("client-app.log", "navigation failed \(error.localizedDescription)")
        fallbackView.isHidden = false
        webView.isHidden = true
        statusLabel.stringValue = "PlushBuddy could not connect to Station: \(error.localizedDescription). Start Station and try again."
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        appendLog("client-web.log", "\(message.body)")
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose voice sample or character photo"
        panel.prompt = "Choose file"
        panel.message = "Choose a voice sample or character photo."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                .image,
                .mpeg4Audio,
                .wav,
                .mp3,
                .audio,
                UTType(filenameExtension: "aac") ?? .audio,
                UTType(filenameExtension: "ogg") ?? .audio,
                UTType(filenameExtension: "webm") ?? .audio,
            ]
        } else {
            panel.allowedFileTypes = ["png", "jpg", "jpeg", "webp", "heic", "m4a", "mp4", "aac", "wav", "mp3", "ogg", "webm"]
        }
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    private func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlushPal", isDirectory: true)
    }

    private func appendLog(_ fileName: String, _ message: String) {
        let line = "[\(Date())] \(message)\n"
        let logs = applicationSupportDirectory().appendingPathComponent("logs", isDirectory: true)
        let file = logs.appendingPathComponent(fileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path),
               let handle = try? FileHandle(forWritingTo: file) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging must never block the client UI.
        }
    }
}

let application = NSApplication.shared
let delegate = MacClientAppDelegate()
application.delegate = delegate
application.run()
