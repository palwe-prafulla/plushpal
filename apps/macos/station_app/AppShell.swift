import AppKit
import CoreImage
import Foundation
import Security
import UniformTypeIdentifiers
import WebKit

private enum StartupState {
    case preparingVoiceRuntime
    case startingHost
    case loadingApp
    case stationReady(URL, conversationReady: Bool)
    case ready
    case failed(String)
}

private struct StartupFailure: Error {
    let message: String
}

class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

final class PlushBuddyHubBackgroundView: FlippedContentView {
    private var isDarkTheme = false

    func updateTheme(isDark: Bool) {
        isDarkTheme = isDark
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = isDarkTheme
            ? NSColor(calibratedRed: 0.09, green: 0.07, blue: 0.12, alpha: 1.0)
            : NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.95, alpha: 1.0)
        background.setFill()
        bounds.fill()

        let blobs: [(NSColor, NSRect)] = [
            (
                NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.82, alpha: isDarkTheme ? 0.20 : 0.30),
                NSRect(x: bounds.minX - 120, y: bounds.minY - 110, width: 360, height: 360)
            ),
            (
                NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: isDarkTheme ? 0.24 : 0.22),
                NSRect(x: bounds.maxX - 300, y: bounds.minY - 90, width: 390, height: 390)
            ),
            (
                NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: isDarkTheme ? 0.18 : 0.24),
                NSRect(x: bounds.maxX - 250, y: bounds.maxY - 250, width: 330, height: 330)
            ),
            (
                NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.28, alpha: isDarkTheme ? 0.11 : 0.20),
                NSRect(x: bounds.minX + 90, y: bounds.maxY - 210, width: 260, height: 260)
            ),
        ]

        for (color, rect) in blobs {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

final class PlushBuddyLogoView: NSView {
    private var shadowColor = NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 0.25)

    override var isFlipped: Bool { true }

    func updateShadow(isDark: Bool) {
        shadowColor = isDark
            ? NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.82, alpha: 0.20)
            : NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 0.25)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let side = min(bounds.width, bounds.height)
        let rect = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        ).insetBy(dx: 3, dy: 3)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.26, yRadius: side * 0.26)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.82, alpha: 1.0),
            NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0),
            NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 1.0),
        ])
        gradient?.draw(in: path, angle: -35)
        NSGraphicsContext.current?.restoreGraphicsState()

        let bearColor = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.84, alpha: 1.0)
        let muzzleColor = NSColor.white.withAlphaComponent(0.96)
        let featureColor = NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.22, alpha: 1.0)
        bearColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - side * 0.30, y: rect.midY - side * 0.34, width: side * 0.22, height: side * 0.22)).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX + side * 0.08, y: rect.midY - side * 0.34, width: side * 0.22, height: side * 0.22)).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - side * 0.27, y: rect.midY - side * 0.22, width: side * 0.54, height: side * 0.50)).fill()
        muzzleColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - side * 0.18, y: rect.midY + side * 0.01, width: side * 0.36, height: side * 0.22)).fill()
        featureColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - side * 0.12, y: rect.midY - side * 0.06, width: side * 0.055, height: side * 0.055)).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX + side * 0.065, y: rect.midY - side * 0.06, width: side * 0.055, height: side * 0.055)).fill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - side * 0.055, y: rect.midY + side * 0.045, width: side * 0.11, height: side * 0.075)).fill()
        let smile = NSBezierPath()
        smile.lineWidth = max(2, side * 0.026)
        smile.move(to: NSPoint(x: rect.midX - side * 0.08, y: rect.midY + side * 0.14))
        smile.curve(
            to: NSPoint(x: rect.midX + side * 0.08, y: rect.midY + side * 0.14),
            controlPoint1: NSPoint(x: rect.midX - side * 0.04, y: rect.midY + side * 0.20),
            controlPoint2: NSPoint(x: rect.midX + side * 0.04, y: rect.midY + side * 0.20)
        )
        featureColor.setStroke()
        smile.stroke()

        let badgeRect = NSRect(
            x: rect.maxX - side * 0.34,
            y: rect.maxY - side * 0.34,
            width: side * 0.28,
            height: side * 0.28
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: 4, dy: 4)).fill()
        let sparkleText = "✦" as NSString
        let sparkleFont = NSFont.systemFont(ofSize: side * 0.16, weight: .black)
        let sparkleAttributes: [NSAttributedString.Key: Any] = [
            .font: sparkleFont,
            .foregroundColor: NSColor.white,
        ]
        let sparkleSize = sparkleText.size(withAttributes: sparkleAttributes)
        sparkleText.draw(
            at: NSPoint(x: badgeRect.midX - sparkleSize.width / 2, y: badgeRect.midY - sparkleSize.height / 2),
            withAttributes: sparkleAttributes
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var splashScrollView: NSScrollView!
    private var splashView: NSView!
    private var logoView: PlushBuddyLogoView!
    private var titleLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var serviceStatusStack: NSStackView!
    private var setupPanel: NSStackView!
    private var storageStatusIcon: NSImageView!
    private var reasoningStatusIcon: NSImageView!
    private var voiceStatusIcon: NSImageView!
    private var sttStatusIcon: NSImageView!
    private var hostStatusIcon: NSImageView!
    private var browserStatusIcon: NSImageView!
    private var storageStatusLabel: NSTextField!
    private var reasoningStatusLabel: NSTextField!
    private var voiceStatusLabel: NSTextField!
    private var sttStatusLabel: NSTextField!
    private var hostStatusLabel: NSTextField!
    private var browserStatusLabel: NSTextField!
    private var retryButton: NSButton!
    private var quitButton: NSButton!
    private var openBrowserButton: NSButton!
    private var pairAndroidButton: NSButton!
    private var openInAppButton: NSButton!
    private var runtimeModeButton: NSButton!
    private var themeModeButton: NSButton!
    private var parentSetupButton: NSButton!
    private var configureCloudLlmButton: NSButton!
    private var pairedDevicesButton: NSButton!
    private var copyDiagnosticsButton: NSButton!
    private var openLogsButton: NSButton!
    private var resetVoiceRuntimeButton: NSButton!
    private var pairingWindow: NSWindow?
    private var currentPairingUrlText: String?
    private var hostProcess: Process?
    private var installProcess: Process?
    private var hostPipe: Pipe?
    private var installPipe: Pipe?
    private var hostOutput = Data()
    private var setupOutput = Data()
    private var didLoadHostUrl = false
    private var hostUrl: URL?
    private var parsedHostUrlText: String?
    private var lanPairingUrl: URL?
    private var stationSessionCookieValue: String?
    private var isTerminating = false
    private var healthWaitGeneration = 0
    private let healthMaxAttempts = 900
    private let logQueue = DispatchQueue(label: "com.plushpal.app-shell.logs")
    private var themedPanels: [NSView] = []
    private var sectionTitleLabels: [NSTextField] = []
    private var helperTextLabels: [NSTextField] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.prepareAndStart()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        installPipe?.fileHandleForReading.readabilityHandler = nil
        hostPipe?.fileHandleForReading.readabilityHandler = nil
        installProcess?.terminate()
        hostProcess?.terminate()
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

        splashScrollView = NSScrollView()
        splashScrollView.translatesAutoresizingMaskIntoConstraints = false
        splashScrollView.drawsBackground = false
        splashScrollView.hasVerticalScroller = true
        splashScrollView.hasHorizontalScroller = false
        splashScrollView.autohidesScrollers = true
        splashScrollView.horizontalScrollElasticity = .none
        splashScrollView.borderType = .noBorder

        splashView = PlushBuddyHubBackgroundView()
        splashView.translatesAutoresizingMaskIntoConstraints = false
        splashScrollView.documentView = splashView

        logoView = PlushBuddyLogoView(frame: NSRect(x: 0, y: 0, width: 86, height: 86))
        logoView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "Starting PlushBuddy Hub")
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "Preparing the local Hub on this Mac…")
        detailLabel.font = .systemFont(ofSize: 15, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.cell?.wraps = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .regular
        progress.isDisplayedWhenStopped = false
        progress.startAnimation(nil)
        progress.translatesAutoresizingMaskIntoConstraints = false

        func makeStatusIcon() -> NSImageView {
            let icon = NSImageView(image: NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            icon.contentTintColor = .secondaryLabelColor
            return icon
        }

        storageStatusIcon = makeStatusIcon()
        reasoningStatusIcon = makeStatusIcon()
        voiceStatusIcon = makeStatusIcon()
        sttStatusIcon = makeStatusIcon()
        hostStatusIcon = makeStatusIcon()
        browserStatusIcon = makeStatusIcon()

        storageStatusLabel = NSTextField(labelWithString: "Secure storage: getting ready")
        reasoningStatusLabel = NSTextField(labelWithString: "Conversations: checking")
        voiceStatusLabel = NSTextField(labelWithString: "Buddy voices: checking")
        sttStatusLabel = NSTextField(labelWithString: "Listening helper: checking")
        hostStatusLabel = NSTextField(labelWithString: "Hub: starting")
        browserStatusLabel = NSTextField(labelWithString: "Apps: waiting")
        for label in [storageStatusLabel, reasoningStatusLabel, voiceStatusLabel, sttStatusLabel, hostStatusLabel, browserStatusLabel] {
            label?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label?.textColor = .secondaryLabelColor
            label?.alignment = .left
            label?.lineBreakMode = .byTruncatingMiddle
            label?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label?.translatesAutoresizingMaskIntoConstraints = false
        }

        func statusRow(icon: NSImageView, label: NSTextField) -> NSStackView {
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
            ])
            return row
        }

        serviceStatusStack = NSStackView(views: [
            statusRow(icon: storageStatusIcon, label: storageStatusLabel),
            statusRow(icon: reasoningStatusIcon, label: reasoningStatusLabel),
            statusRow(icon: voiceStatusIcon, label: voiceStatusLabel),
            statusRow(icon: sttStatusIcon, label: sttStatusLabel),
            statusRow(icon: hostStatusIcon, label: hostStatusLabel),
            statusRow(icon: browserStatusIcon, label: browserStatusLabel),
        ])
        serviceStatusStack.orientation = .vertical
        serviceStatusStack.alignment = .leading
        serviceStatusStack.distribution = .fill
        serviceStatusStack.spacing = 8
        serviceStatusStack.translatesAutoresizingMaskIntoConstraints = false

        retryButton = NSButton(title: "Retry health checks", target: self, action: #selector(retryStartup))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        quitButton = NSButton(title: "Quit Hub", target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.isHidden = true
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        openBrowserButton = NSButton(title: "Open browser client", target: self, action: #selector(openPlushPalInBrowser))
        openBrowserButton.bezelStyle = .rounded
        openBrowserButton.isHidden = true
        openBrowserButton.translatesAutoresizingMaskIntoConstraints = false

        pairAndroidButton = NSButton(title: "Pair phone with QR code", target: self, action: #selector(showAndroidPairingLink))
        pairAndroidButton.bezelStyle = .rounded
        pairAndroidButton.isHidden = true
        pairAndroidButton.translatesAutoresizingMaskIntoConstraints = false

        openInAppButton = NSButton(title: "Open Mac client", target: self, action: #selector(openPlushPalInApp))
        openInAppButton.bezelStyle = .rounded
        openInAppButton.isHidden = true
        openInAppButton.translatesAutoresizingMaskIntoConstraints = false

        runtimeModeButton = NSButton(title: "Change runtime mode", target: self, action: #selector(configureRuntimeMode))
        runtimeModeButton.bezelStyle = .rounded
        runtimeModeButton.isHidden = true
        runtimeModeButton.translatesAutoresizingMaskIntoConstraints = false

        themeModeButton = NSButton(title: "Theme: System", target: self, action: #selector(cycleThemeMode))
        themeModeButton.bezelStyle = .rounded
        themeModeButton.isHidden = true
        themeModeButton.translatesAutoresizingMaskIntoConstraints = false

        parentSetupButton = NSButton(title: "Set parent PIN", target: self, action: #selector(configureParentPin))
        parentSetupButton.bezelStyle = .rounded
        parentSetupButton.isHidden = true
        parentSetupButton.translatesAutoresizingMaskIntoConstraints = false

        configureCloudLlmButton = NSButton(title: "Configure Cloud AI model", target: self, action: #selector(configureCloudLlmKey))
        configureCloudLlmButton.bezelStyle = .rounded
        configureCloudLlmButton.isHidden = true
        configureCloudLlmButton.translatesAutoresizingMaskIntoConstraints = false

        pairedDevicesButton = NSButton(title: "Manage paired devices", target: self, action: #selector(managePairedDevices))
        pairedDevicesButton.bezelStyle = .rounded
        pairedDevicesButton.isHidden = true
        pairedDevicesButton.translatesAutoresizingMaskIntoConstraints = false

        copyDiagnosticsButton = NSButton(title: "Copy diagnostics", target: self, action: #selector(copyDiagnostics))
        copyDiagnosticsButton.bezelStyle = .rounded
        copyDiagnosticsButton.isHidden = true
        copyDiagnosticsButton.translatesAutoresizingMaskIntoConstraints = false

        openLogsButton = NSButton(title: "Open logs", target: self, action: #selector(openLogFolder))
        openLogsButton.bezelStyle = .rounded
        openLogsButton.isHidden = true
        openLogsButton.translatesAutoresizingMaskIntoConstraints = false

        resetVoiceRuntimeButton = NSButton(title: "Reset voice runtime", target: self, action: #selector(resetVoiceRuntime))
        resetVoiceRuntimeButton.bezelStyle = .rounded
        resetVoiceRuntimeButton.isHidden = true
        resetVoiceRuntimeButton.translatesAutoresizingMaskIntoConstraints = false

        for button in [
            retryButton,
            quitButton,
            openBrowserButton,
            pairAndroidButton,
            openInAppButton,
            runtimeModeButton,
            themeModeButton,
            parentSetupButton,
            configureCloudLlmButton,
            pairedDevicesButton,
            copyDiagnosticsButton,
            openLogsButton,
            resetVoiceRuntimeButton,
        ] {
            button?.alignment = .left
            button?.imagePosition = .imageLeading
        }

        func sectionTitle(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            label.textColor = .labelColor
            label.alignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            self.sectionTitleLabels.append(label)
            return label
        }

        func helperText(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.alignment = .left
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            self.helperTextLabels.append(label)
            return label
        }

        func verticalPanel(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.wantsLayer = true
            stack.layer?.cornerRadius = 14
            stack.layer?.borderWidth = 1
            self.themedPanels.append(stack)
            return stack
        }

        let statusPanel = verticalPanel([
            sectionTitle("Today’s status"),
            helperText("Keep this Mac awake while your phone or Mac client is using buddy voices."),
            serviceStatusStack,
        ])

        setupPanel = verticalPanel([
            sectionTitle("Setup checklist"),
            helperText("Do these once, in order. The parent PIN protects sensitive settings such as Cloud AI model keys."),
            parentSetupButton,
            configureCloudLlmButton,
            sectionTitle("Connect clients"),
            helperText("Phones pair by QR code. Local Mac and browser clients connect directly to this Hub."),
            pairAndroidButton,
            pairedDevicesButton,
            openBrowserButton,
            openInAppButton,
            sectionTitle("Look & feel"),
            helperText("Use the same PlushBuddy colors as the phone app."),
            themeModeButton,
        ])

        let mainPanel = NSStackView(views: [statusPanel, setupPanel])
        mainPanel.orientation = .horizontal
        mainPanel.alignment = .top
        mainPanel.distribution = .fillEqually
        mainPanel.spacing = 24
        mainPanel.translatesAutoresizingMaskIntoConstraints = false

        let advancedFirstRow = NSStackView(views: [
            runtimeModeButton,
            retryButton,
            copyDiagnosticsButton,
        ])
        advancedFirstRow.orientation = .horizontal
        advancedFirstRow.alignment = .centerY
        advancedFirstRow.distribution = .fillEqually
        advancedFirstRow.spacing = 10
        advancedFirstRow.translatesAutoresizingMaskIntoConstraints = false

        let advancedSecondRow = NSStackView(views: [
            openLogsButton,
            resetVoiceRuntimeButton,
            quitButton,
        ])
        advancedSecondRow.orientation = .horizontal
        advancedSecondRow.alignment = .centerY
        advancedSecondRow.distribution = .fillEqually
        advancedSecondRow.spacing = 10
        advancedSecondRow.translatesAutoresizingMaskIntoConstraints = false

        let advancedButtonStack = NSStackView(views: [
            advancedFirstRow,
            advancedSecondRow,
        ])
        advancedButtonStack.orientation = .vertical
        advancedButtonStack.alignment = .leading
        advancedButtonStack.distribution = .fill
        advancedButtonStack.spacing = 10
        advancedButtonStack.translatesAutoresizingMaskIntoConstraints = false

        let advancedPanel = verticalPanel([
            sectionTitle("Advanced / troubleshooting"),
            helperText("Use these only when setup is stuck or you are changing local/cloud runtime behavior."),
            advancedButtonStack,
        ])

        splashView.addSubview(logoView)
        splashView.addSubview(titleLabel)
        splashView.addSubview(detailLabel)
        splashView.addSubview(progress)
        splashView.addSubview(mainPanel)
        splashView.addSubview(advancedPanel)

        let content = NSView()
        content.addSubview(webView)
        content.addSubview(splashScrollView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            splashScrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splashScrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splashScrollView.topAnchor.constraint(equalTo: content.topAnchor),
            splashScrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            splashView.leadingAnchor.constraint(equalTo: splashScrollView.contentView.leadingAnchor),
            splashView.trailingAnchor.constraint(equalTo: splashScrollView.contentView.trailingAnchor),
            splashView.topAnchor.constraint(equalTo: splashScrollView.contentView.topAnchor),
            splashView.widthAnchor.constraint(equalTo: splashScrollView.contentView.widthAnchor),
            splashView.heightAnchor.constraint(greaterThanOrEqualToConstant: 900),

            logoView.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            logoView.topAnchor.constraint(equalTo: splashView.topAnchor, constant: 72),
            logoView.widthAnchor.constraint(equalToConstant: 86),
            logoView.heightAnchor.constraint(equalToConstant: 86),
            progress.centerXAnchor.constraint(equalTo: splashView.centerXAnchor),
            progress.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: splashView.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: splashView.trailingAnchor, constant: -40),
            titleLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 24),
            detailLabel.leadingAnchor.constraint(equalTo: splashView.leadingAnchor, constant: 72),
            detailLabel.trailingAnchor.constraint(equalTo: splashView.trailingAnchor, constant: -72),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            mainPanel.leadingAnchor.constraint(equalTo: splashView.leadingAnchor, constant: 72),
            mainPanel.trailingAnchor.constraint(equalTo: splashView.trailingAnchor, constant: -72),
            mainPanel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 24),
            advancedPanel.leadingAnchor.constraint(equalTo: splashView.leadingAnchor, constant: 72),
            advancedPanel.trailingAnchor.constraint(equalTo: splashView.trailingAnchor, constant: -72),
            advancedPanel.topAnchor.constraint(equalTo: mainPanel.bottomAnchor, constant: 18),
            advancedPanel.bottomAnchor.constraint(lessThanOrEqualTo: splashView.bottomAnchor, constant: -72),
            serviceStatusStack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            parentSetupButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            configureCloudLlmButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            openBrowserButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            pairAndroidButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            pairedDevicesButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            openInAppButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            runtimeModeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            copyDiagnosticsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            openLogsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            resetVoiceRuntimeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            themeModeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PlushBuddy Hub"
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.contentView = content
        applyThemePreference()
        window.makeKeyAndOrderFront(nil)
    }

    private func prepareAndStart() {
        appendLog("app-shell.log", "prepareAndStart")
        update(.preparingVoiceRuntime)
        setupOutput.removeAll()
        updateServiceStatuses(
            storage: "✓ Secure storage: ready",
            reasoning: "○ Conversations: checking",
            voice: "○ Buddy voices: checking",
            stt: "○ Listening helper: checking",
            host: "○ Hub: starting",
            browser: "○ Apps: waiting"
        )
        let voiceRuntime: VoiceRuntime?
        switch prepareVoiceRuntime() {
        case .success(let runtime):
            voiceRuntime = runtime
            updateServiceStatuses(
                storage: nil,
                reasoning: "○ Conversations: waiting",
                voice: runtime == nil ? "△ Buddy voices: demo mode" : "✓ Buddy voices: ready",
                stt: nil,
                host: "○ Hub: starting",
                browser: "○ Apps: waiting"
            )
        case .failure(let failure):
            updateServiceStatuses(
                storage: nil,
                reasoning: "○ Conversations: waiting",
                voice: "✕ Buddy voices: setup failed",
                stt: nil,
                host: "○ Hub: waiting",
                browser: "○ Apps: waiting"
            )
            update(.failed(failure.message))
            return
        }
        let sttRuntime = prepareSpeechToTextRuntime()
        updateServiceStatuses(
            storage: nil,
            reasoning: nil,
            voice: nil,
            stt: sttRuntime == nil ? "△ Listening helper: phone will listen" : "✓ Listening helper: ready",
            host: "○ Hub: starting",
            browser: nil
        )
        update(.startingHost)
        startHost(voiceRuntime: voiceRuntime, speechToTextRuntime: sttRuntime)
    }

    private func prepareVoiceRuntime() -> Result<VoiceRuntime?, StartupFailure> {
        if let lux = prepareLuxTtsRuntime() {
            return lux
        }
        if ProcessInfo.processInfo.environment["PLUSHPAL_ENABLE_CHATTERBOX_FALLBACK"] == nil {
            return .failure(StartupFailure(message: "The local LuxTTS voice runtime is missing from the PlushBuddy Hub app bundle."))
        }
        return prepareChatterboxRuntime()
    }

    private func prepareLuxTtsRuntime() -> Result<VoiceRuntime?, StartupFailure>? {
        let bundle = Bundle.main
        let script = bundle.resourceURL?
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent("luxtts_tts.py")
        let installer = bundle.resourceURL?
            .appendingPathComponent("install_luxtts_runtime.sh")

        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            return nil
        }

        let support = applicationSupportDirectory()
        let venv = support.appendingPathComponent("luxtts-venv", isDirectory: true)
        let python = venv.appendingPathComponent("bin/python")
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin/python3")

        if let bundledPython,
           FileManager.default.isExecutableFile(atPath: bundledPython.path),
           isLuxTtsRuntimeReady(python: bundledPython, script: script) {
            return .success(VoiceRuntime(engine: "luxtts", python: bundledPython, script: script))
        }

        if FileManager.default.isExecutableFile(atPath: python.path),
           isLuxTtsRuntimeReady(python: python, script: script) {
            return .success(VoiceRuntime(engine: "luxtts", python: python, script: script))
        }

        if ProcessInfo.processInfo.environment["PLUSHPAL_SKIP_LUXTTS_INSTALL"] != nil {
            return .success(nil)
        }

        guard let installer, FileManager.default.isExecutableFile(atPath: installer.path) else {
            return .failure(StartupFailure(message: "The local LuxTTS installer is missing from the PlushBuddy Hub app bundle."))
        }

        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [installer.path, venv.path]
            process.environment = mergedEnvironment(extra: [
                "PLUSHPAL_LUXTTS_SCRIPT": script.path,
                "PLUSHPAL_BUNDLED_PYTHON": Bundle.main.resourceURL?
                    .appendingPathComponent("python", isDirectory: true)
                    .appendingPathComponent("bin/python3")
                    .path ?? "",
            ])

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            installProcess = process
            installPipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.setupOutput.append(data)
                self?.appendLogData("setup.log", data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                let line = text.split(separator: "\n").last.map(String.init) ?? text
                self?.updateDetail("Installing LuxTTS local voice support… \(line)")
            }
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            installProcess = nil
            installPipe = nil

            if process.terminationStatus == 0,
               FileManager.default.isExecutableFile(atPath: python.path),
               isLuxTtsRuntimeReady(python: python, script: script) {
                return .success(VoiceRuntime(engine: "luxtts", python: python, script: script))
            }
            return .failure(StartupFailure(message: "PlushBuddy Hub could not finish installing LuxTTS voice support. \(setupDiagnosticTail())"))
        } catch {
            installProcess = nil
            installPipe = nil
            return .failure(StartupFailure(message: "PlushBuddy Hub could not install LuxTTS voice support: \(error.localizedDescription)\n\n\(setupDiagnosticTail())"))
        }
    }

    private func prepareChatterboxRuntime() -> Result<VoiceRuntime?, StartupFailure> {
        let bundle = Bundle.main
        let script = bundle.resourceURL?
            .appendingPathComponent("voice", isDirectory: true)
            .appendingPathComponent("chatterbox_tts.py")
        let installer = bundle.resourceURL?
            .appendingPathComponent("install_chatterbox_runtime.sh")

        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            return .failure(StartupFailure(message: "The local voice setup script is missing from the PlushBuddy Hub app bundle."))
        }

        let support = applicationSupportDirectory()
        let venv = support.appendingPathComponent("chatterbox-venv", isDirectory: true)
        let python = venv.appendingPathComponent("bin/python")
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin/python3")

        if let bundledPython,
           FileManager.default.isExecutableFile(atPath: bundledPython.path),
           isChatterboxRuntimeImportReady(python: bundledPython) {
            return .success(VoiceRuntime(engine: "chatterbox", python: bundledPython, script: script))
        }

        if FileManager.default.isExecutableFile(atPath: python.path),
           isChatterboxRuntimeImportReady(python: python) {
            return .success(VoiceRuntime(engine: "chatterbox", python: python, script: script))
        }

        if ProcessInfo.processInfo.environment["PLUSHPAL_SKIP_CHATTERBOX_INSTALL"] != nil {
            return .success(nil)
        }

        guard let installer, FileManager.default.isExecutableFile(atPath: installer.path) else {
            return .failure(StartupFailure(message: "The local voice installer is missing from the PlushBuddy Hub app bundle."))
        }

        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [installer.path, venv.path]
            process.environment = mergedEnvironment(extra: [
                "PLUSHPAL_CHATTERBOX_SCRIPT": script.path,
                "PLUSHPAL_BUNDLED_PYTHON": Bundle.main.resourceURL?
                    .appendingPathComponent("python", isDirectory: true)
                    .appendingPathComponent("bin/python3")
                    .path ?? "",
            ])

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            installProcess = process
            installPipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.setupOutput.append(data)
                self?.appendLogData("setup.log", data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                let line = text.split(separator: "\n").last.map(String.init) ?? text
                self?.updateDetail("Installing local voice support… \(line)")
            }
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            installProcess = nil
            installPipe = nil

            if process.terminationStatus == 0,
               FileManager.default.isExecutableFile(atPath: python.path),
               isChatterboxRuntimeImportReady(python: python) {
                return .success(VoiceRuntime(engine: "chatterbox", python: python, script: script))
            }
            return .failure(StartupFailure(message: "PlushBuddy Hub could not finish installing local voice support. \(setupDiagnosticTail())"))
        } catch {
            installProcess = nil
            installPipe = nil
            return .failure(StartupFailure(message: "PlushBuddy Hub could not install local voice support: \(error.localizedDescription)\n\n\(setupDiagnosticTail())"))
        }
    }

    private func isLuxTtsRuntimeReady(python: URL, script: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--healthcheck"]
        process.environment = mergedEnvironment(extra: [:])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isChatterboxRuntimeImportReady(python: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-c",
            "import torch, torchaudio; from chatterbox.tts import ChatterboxTTS",
        ]
        process.environment = mergedEnvironment(extra: [:])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func prepareSpeechToTextRuntime() -> SpeechToTextRuntime? {
        guard ProcessInfo.processInfo.environment["PLUSHPAL_DISABLE_HUB_STT"] == nil else {
            appendLog("app-shell.log", "Hub STT fallback disabled by environment")
            return nil
        }
        let script = Bundle.main.resourceURL?
            .appendingPathComponent("stt", isDirectory: true)
            .appendingPathComponent("whisper_transcribe.py", isDirectory: false)
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin/python3", isDirectory: false)
        guard let script,
              FileManager.default.fileExists(atPath: script.path),
              let bundledPython,
              FileManager.default.isExecutableFile(atPath: bundledPython.path) else {
            appendLog("app-shell.log", "Hub STT fallback is not bundled")
            return nil
        }
        if let command = writeSpeechToTextCommandWrapper(python: bundledPython, script: script) {
            appendLog("app-shell.log", "Hub STT fallback wrapper prepared")
            return SpeechToTextRuntime(command: command)
        }
        appendLog("app-shell.log", "Hub STT fallback script exists but wrapper creation failed")
        return nil
    }

    private func writeSpeechToTextCommandWrapper(python: URL, script: URL) -> URL? {
        let directory = applicationSupportDirectory()
            .appendingPathComponent("stt-runtime", isDirectory: true)
        let command = directory.appendingPathComponent("whisper-transcribe", isDirectory: false)
        let bundledHfHome = Bundle.main.resourceURL?
            .appendingPathComponent("model-cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        let cacheExports: String
        if let bundledHfHome,
           FileManager.default.fileExists(atPath: bundledHfHome.appendingPathComponent("hub", isDirectory: true).path) {
            cacheExports = """
            export HF_HOME=\(shellQuote(bundledHfHome.path))
            export HF_HUB_CACHE=\(shellQuote(bundledHfHome.appendingPathComponent("hub", isDirectory: true).path))
            export TRANSFORMERS_CACHE=\(shellQuote(bundledHfHome.appendingPathComponent("hub", isDirectory: true).path))
            export HF_HUB_OFFLINE=1
            export TRANSFORMERS_OFFLINE=1
            export HF_HUB_DISABLE_TELEMETRY=1
            """
        } else {
            cacheExports = ""
        }
        let contents = """
        #!/bin/sh
        \(cacheExports)
        exec \(shellQuote(python.path)) \(shellQuote(script.path)) "$@"
        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            return command
        } catch {
            appendLog("app-shell.log", "could not write STT wrapper: \(error.localizedDescription)")
            return nil
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func isSpeechToTextRuntimeReady(python: URL, script: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--healthcheck"]
        process.environment = mergedEnvironment(extra: [:])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func startHost(voiceRuntime: VoiceRuntime?, speechToTextRuntime: SpeechToTextRuntime?) {
        guard let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("plushpal-desktop-host", isDirectory: false) as URL?,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            update(.failed("The PlushBuddy Hub local service is missing from the app bundle."))
            return
        }

        let process = Process()
        process.executableURL = helper
        process.currentDirectoryURL = Bundle.main.resourceURL
        var extra = [
            "PLUSHPAL_NO_BROWSER": "1",
            "PLUSHPAL_PRINT_BOOTSTRAP_URL": "1",
            "PLUSHPAL_PORT": "0",
            "PLUSHPAL_RUNTIME_MODE": selectedRuntimeMode(),
            "PLUSHPAL_CLOUD_LLM_PROVIDER": selectedCloudLlmProvider(),
        ]
        if let lanAddress = preferredLanIPv4Address() {
            extra["PLUSHPAL_ENABLE_LAN"] = "1"
            extra["PLUSHPAL_LAN_HOST"] = lanAddress
            appendLog("app-shell.log", "LAN pairing candidate \(lanAddress)")
        }
        if let voiceRuntime {
            extra["PLUSHPAL_VOICE_ENGINE"] = voiceRuntime.engine
            if voiceRuntime.engine == "luxtts" {
                extra["PLUSHPAL_LUXTTS_PYTHON"] = voiceRuntime.python.path
                extra["PLUSHPAL_LUXTTS_SCRIPT"] = voiceRuntime.script.path
                extra["PLUSHPAL_LUXTTS_NUM_STEPS"] = "8"
                extra["PLUSHPAL_LUXTTS_SPEED"] = "0.88"
                extra["PLUSHPAL_LUXTTS_SEED"] = "11"
                extra["PLUSHPAL_LUXTTS_REF_DURATION"] = "180"
            } else {
                extra["PLUSHPAL_CHATTERBOX_PYTHON"] = voiceRuntime.python.path
                extra["PLUSHPAL_CHATTERBOX_SCRIPT"] = voiceRuntime.script.path
                extra["PLUSHPAL_CHATTERBOX_ENGINE"] = "standard"
            }
        }
        if let speechToTextRuntime {
            extra["PLUSHPAL_STT_COMMAND"] = speechToTextRuntime.command.path
            extra["PLUSHPAL_STT_MODEL"] = "openai/whisper-base"
            extra["PLUSHPAL_STT_DEVICE"] = "auto"
        }
        process.environment = mergedEnvironment(extra: extra)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        hostProcess = process
        hostPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeHostOutput(data)
        }
        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.hostPipe?.fileHandleForReading.readabilityHandler = nil
                self.hostPipe = nil
                self.hostProcess = nil
                let diagnostic = self.hostDiagnosticTail()
                let suffix = diagnostic.isEmpty ? "" : "\n\n\(diagnostic)"
                self.appendLog("app-shell.log", "host terminated status=\(terminated.terminationStatus) reason=\(terminated.terminationReason.rawValue) didLoadHostUrl=\(self.didLoadHostUrl)")
                if self.didLoadHostUrl {
                    self.update(.failed("The local PlushBuddy Hub service stopped unexpectedly. Exit code \(terminated.terminationStatus).\(suffix)"))
                } else {
                    self.update(.failed("The local PlushBuddy Hub service stopped before the app was ready. Exit code \(terminated.terminationStatus).\(suffix)"))
                }
            }
        }

        do {
            try process.run()
        } catch {
            update(.failed("Could not start the local PlushBuddy Hub service: \(error.localizedDescription)"))
        }
    }

    @objc private func retryStartup() {
        if let existingHostUrl = hostUrl, hostProcess?.isRunning == true {
            appendLog("app-shell.log", "retryStartup resumes existing host \(existingHostUrl.absoluteString)")
            update(.startingHost)
            updateServiceStatuses(
                storage: nil,
                reasoning: "○ Conversations: checking",
                voice: "○ Buddy voices: checking",
                stt: "○ Listening helper: checking",
                host: "○ Hub: checking",
                browser: "○ Apps: waiting"
            )
            waitForStationHealth(existingHostUrl)
            return
        }
        installProcess?.terminate()
        hostProcess?.terminate()
        installProcess = nil
        hostProcess = nil
        installPipe = nil
        hostPipe = nil
        hostOutput.removeAll()
        didLoadHostUrl = false
        hostUrl = nil
        parsedHostUrlText = nil
        lanPairingUrl = nil
        stationSessionCookieValue = nil
        update(.preparingVoiceRuntime)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.prepareAndStart()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openLogFolder() {
        let directory = logDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func copyDiagnostics() {
        let diagnostics = diagnosticSnapshot()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Diagnostics copied"
        alert.informativeText = "A redacted startup report was copied to the clipboard. It includes service status and recent log tails, but not API keys, PINs, pairing tokens, or audio/text content."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func resetVoiceRuntime() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset local voice runtime?"
        alert.informativeText = "This removes the local LuxTTS Python environment so PlushBuddy Hub can rebuild it. It does not delete kids, characters, conversations, API keys, voice profiles, or downloaded model caches."
        alert.addButton(withTitle: "Reset voice runtime")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        installPipe?.fileHandleForReading.readabilityHandler = nil
        hostPipe?.fileHandleForReading.readabilityHandler = nil
        installProcess?.terminate()
        hostProcess?.terminate()

        let support = applicationSupportDirectory()
        let targets = [
            support.appendingPathComponent("luxtts-venv", isDirectory: true),
        ]
        do {
            for target in targets where FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            appendLog("app-shell.log", "reset LuxTTS voice runtime")
            retryStartup()
        } catch {
            appendLog("app-shell.log", "failed to reset LuxTTS voice runtime: \(error.localizedDescription)")
            update(.failed("Could not reset the local voice runtime: \(error.localizedDescription)\n\nOpen logs or copy diagnostics for details."))
        }
    }

    @objc private func openPlushPalInBrowser() {
        guard let hostUrl else { return }
        persistStationClientUrl(hostUrl)
        NSWorkspace.shared.open(hostUrl)
    }

    @objc private func showAndroidPairingLink() {
        guard let pairingUrl = lanPairingUrl ?? hostUrl else { return }
        let isLanUrl = lanPairingUrl != nil
        currentPairingUrlText = pairingUrl.absoluteString

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Android pairing"
        panel.isReleasedWhenClosed = false
        panel.center()

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let title = NSTextField(labelWithString: "Pair phone with PlushBuddy Hub")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let instructions = NSTextField(wrappingLabelWithString: """
        \(isLanUrl ? "Keep this Mac awake and on the same Wi‑Fi as the Android phone." : "No LAN address was detected, so this fallback address only works on this Mac.")

        In the Android or iPhone app, tap Pair Hub and scan this QR code.
        """)
        instructions.font = .systemFont(ofSize: 14)
        instructions.textColor = .secondaryLabelColor
        instructions.alignment = .center
        instructions.translatesAutoresizingMaskIntoConstraints = false

        let qrContainer = NSView()
        qrContainer.wantsLayer = true
        qrContainer.layer?.backgroundColor = NSColor.white.cgColor
        qrContainer.layer?.cornerRadius = 16
        qrContainer.translatesAutoresizingMaskIntoConstraints = false
        if let image = qrCodeImage(for: pairingUrl.absoluteString, size: 300) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            qrContainer.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: qrContainer.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: qrContainer.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 300),
                imageView.heightAnchor.constraint(equalToConstant: 300),
            ])
        }

        let closeButton = NSButton(title: "Done", target: self, action: #selector(closePairingWindow))
        closeButton.bezelStyle = .rounded
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, instructions, qrContainer, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            qrContainer.widthAnchor.constraint(equalToConstant: 340),
            qrContainer.heightAnchor.constraint(equalToConstant: 340),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])

        pairingWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func copyCurrentPairingUrl() {
        guard let currentPairingUrlText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPairingUrlText, forType: .string)
    }

    @objc private func closePairingWindow() {
        pairingWindow?.close()
        pairingWindow = nil
    }

    private func qrCodeImage(for text: String, size: CGFloat) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let colored = CIFilter(name: "CIFalseColor")
        colored?.setValue(output, forKey: kCIInputImageKey)
        colored?.setValue(CIColor(color: .black), forKey: "inputColor0")
        colored?.setValue(CIColor(color: .white), forKey: "inputColor1")
        let finalImage = colored?.outputImage ?? output
        let scale = size / max(output.extent.width, output.extent.height)
        let transformed = finalImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    @objc private func openPlushPalInApp() {
        guard let hostUrl else { return }
        persistStationClientUrl(hostUrl)
        guard let clientAppUrl = bundledClientAppUrl() else {
            appendLog("app-shell.log", "missing PlushBuddy Mac client app; falling back to browser \(hostUrl.absoluteString)")
            NSWorkspace.shared.open(hostUrl)
            return
        }

        appendLog("app-shell.log", "opening PlushBuddy Mac client \(clientAppUrl.path) url=\(hostUrl.absoluteString)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--station-url", hostUrl.absoluteString]
        NSWorkspace.shared.openApplication(at: clientAppUrl, configuration: configuration) { [weak self] _, error in
            if let error {
                self?.appendLog("app-shell.log", "failed to open PlushBuddy Mac client: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Could not open PlushBuddy"
                    alert.informativeText = "Hub is healthy, but the Mac client app could not be opened. Opening the browser version instead."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    NSWorkspace.shared.open(hostUrl)
                }
            }
        }
    }

    private func bundledClientAppUrl() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("PlushBuddy.app", isDirectory: true),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PlushBuddy.app", isDirectory: true),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persistStationClientUrl(_ url: URL) {
        let directory = applicationSupportDirectory()
            .appendingPathComponent("Hub", isDirectory: true)
        let file = directory.appendingPathComponent("latest-client-url.txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try url.absoluteString.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            appendLog("app-shell.log", "could not persist latest client url: \(error.localizedDescription)")
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PlushBuddy Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func cycleThemeMode() {
        let next = switch selectedThemeMode() {
        case "system": "light"
        case "light": "dark"
        default: "system"
        }
        UserDefaults.standard.set(next, forKey: "PlushBuddyHubThemeMode")
        applyThemePreference()
    }

    private func selectedThemeMode() -> String {
        if let stored = UserDefaults.standard.string(forKey: "PlushBuddyHubThemeMode"),
           ["system", "light", "dark"].contains(stored) {
            return stored
        }
        return "system"
    }

    private func themeDisplayName(_ mode: String) -> String {
        switch mode {
        case "light":
            return "Light"
        case "dark":
            return "Dark"
        default:
            return "System"
        }
    }

    private func applyThemePreference() {
        let mode = selectedThemeMode()
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
        window?.appearance = NSApp.appearance
        themeModeButton?.title = "Theme: \(themeDisplayName(mode))"
        applyThemeColors()
    }

    private func applyThemeColors() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
        let isDark = bestMatch == .darkAqua
        let panelBackgrounds: [NSColor] = isDark
            ? [
                NSColor(calibratedRed: 0.14, green: 0.10, blue: 0.19, alpha: 0.94),
                NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.22, alpha: 0.94),
                NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.08, alpha: 0.94),
            ]
            : [
                NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.99, alpha: 0.92),
                NSColor(calibratedRed: 0.94, green: 0.98, blue: 1.00, alpha: 0.92),
                NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.84, alpha: 0.90),
            ]
        let panelBorders: [NSColor] = [
            NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.82, alpha: isDark ? 0.32 : 0.34),
            NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: isDark ? 0.34 : 0.36),
            NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: isDark ? 0.32 : 0.26),
        ]
        let titleColor = isDark ? NSColor.white : NSColor(calibratedRed: 0.14, green: 0.10, blue: 0.18, alpha: 1.0)
        let helperColor = isDark
            ? NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.90, alpha: 1.0)
            : NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.42, alpha: 1.0)
        let accent = NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0)

        (splashView as? PlushBuddyHubBackgroundView)?.updateTheme(isDark: isDark)
        logoView?.updateShadow(isDark: isDark)
        titleLabel?.textColor = titleColor
        detailLabel?.textColor = helperColor
        for label in sectionTitleLabels {
            label.textColor = titleColor
        }
        for label in helperTextLabels {
            label.textColor = helperColor
        }
        for label in [storageStatusLabel, reasoningStatusLabel, voiceStatusLabel, sttStatusLabel, hostStatusLabel, browserStatusLabel] {
            label?.textColor = helperColor
        }
        for (index, panel) in themedPanels.enumerated() {
            panel.layer?.backgroundColor = panelBackgrounds[min(index, panelBackgrounds.count - 1)].cgColor
            panel.layer?.borderColor = panelBorders[min(index, panelBorders.count - 1)].cgColor
        }
        for button in [parentSetupButton, configureCloudLlmButton, pairAndroidButton, pairedDevicesButton, openBrowserButton, openInAppButton, themeModeButton] {
            button?.contentTintColor = accent
        }
        refreshChecklistButtons()
    }

    @objc private func configureParentPin() {
        if UserDefaults.standard.bool(forKey: "PlushBuddyHubParentPinConfigured") {
            let manage = NSAlert()
            manage.messageText = "Parent PIN is already set"
            manage.informativeText = "Use the current PIN to update it. If you do not want to change it, you can leave it as is."
            manage.addButton(withTitle: "Update PIN")
            manage.addButton(withTitle: "Cancel")
            guard manage.runModal() == .alertFirstButtonReturn else { return }
            updateParentPin()
            return
        }

        let pinInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        pinInput.placeholderString = "Parent PIN"
        let confirmInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        confirmInput.placeholderString = "Confirm PIN"

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Parent PIN"),
            pinInput,
            NSTextField(labelWithString: "Confirm PIN"),
            confirmInput,
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.setFrameSize(NSSize(width: 360, height: 104))

        let alert = NSAlert()
        alert.messageText = "Set parent PIN"
        alert.informativeText = "The parent PIN protects Hub settings such as Cloud AI model keys."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save PIN")
        alert.addButton(withTitle: "Cancel")
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(pinInput)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pin = pinInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmation = confirmInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty, pin == confirmation else {
            showInfoAlert(title: "Parent PIN was not saved", message: "Both PIN fields must match.")
            return
        }
        do {
            try saveParentPinToHub(pin: pin)
            UserDefaults.standard.set(true, forKey: "PlushBuddyHubParentPinConfigured")
            refreshChecklistButtons()
            appendLog("app-shell.log", "parent PIN configured or verified")
            showInfoAlert(title: "Parent PIN ready", message: "Hub parent settings are protected. Next, configure your Cloud AI model if you want cloud conversation mode.")
        } catch {
            showInfoAlert(title: "Parent PIN setup failed", message: error.localizedDescription)
        }
    }

    private func updateParentPin() {
        let currentInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        currentInput.placeholderString = "Current parent PIN"
        let newInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        newInput.placeholderString = "New parent PIN"
        let confirmInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        confirmInput.placeholderString = "Confirm new PIN"

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Current PIN"),
            currentInput,
            NSTextField(labelWithString: "New PIN"),
            newInput,
            NSTextField(labelWithString: "Confirm new PIN"),
            confirmInput,
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.setFrameSize(NSSize(width: 380, height: 156))

        let alert = NSAlert()
        alert.messageText = "Update parent PIN"
        alert.informativeText = "Enter the current PIN, then choose a new PIN."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Update PIN")
        alert.addButton(withTitle: "Cancel")
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(currentInput)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let current = currentInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPin = newInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmation = confirmInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !newPin.isEmpty, newPin == confirmation else {
            showInfoAlert(title: "Parent PIN was not updated", message: "Enter the current PIN and make sure both new PIN fields match.")
            return
        }
        do {
            try updateParentPinInHub(currentPin: current, newPin: newPin)
            UserDefaults.standard.set(true, forKey: "PlushBuddyHubParentPinConfigured")
            refreshChecklistButtons()
            appendLog("app-shell.log", "parent PIN updated")
            showInfoAlert(title: "Parent PIN updated", message: "Use the new PIN for future parent settings.")
        } catch {
            showInfoAlert(title: "Parent PIN update failed", message: error.localizedDescription)
        }
    }

    @objc private func configureCloudLlmKey() {
        let status = (try? cloudAiModelStatus()) ?? CloudAiModelStatus(
            provider: selectedCloudLlmProvider(),
            configured: UserDefaults.standard.bool(forKey: "PlushBuddyHubCloudLlmConfigured"),
            displayName: cloudLlmProviderDisplayName(selectedCloudLlmProvider()),
            configuredProviders: UserDefaults.standard.bool(forKey: "PlushBuddyHubCloudLlmConfigured")
                ? [selectedCloudLlmProvider()]
                : []
        )
        if status.configured || !status.configuredProviders.isEmpty {
            manageCloudAiModel(status: status)
            return
        }
        addOrUpdateCloudAiModelKey(initialProvider: status.provider)
    }

    private func manageCloudAiModel(status: CloudAiModelStatus) {
        let available = status.configuredProviders.isEmpty
            ? "None yet"
            : status.configuredProviders.map(cloudLlmProviderDisplayName).joined(separator: ", ")
        let active = status.configured
            ? "\(status.displayName) active"
            : "\(status.displayName) selected but missing a key"

        let alert = NSAlert()
        alert.messageText = "Manage Cloud AI model"
        alert.informativeText = """
        Active model: \(active)
        Available keys: \(available)

        Add or update a Gemini/OpenAI key, or switch to a provider that already has a saved key.
        """
        alert.addButton(withTitle: "Add / update key")
        let switchProvider = status.configuredProviders.first { $0 != status.provider }
        if let switchProvider {
            alert.addButton(withTitle: "Use \(cloudLlmProviderDisplayName(switchProvider))")
        }
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            addOrUpdateCloudAiModelKey(initialProvider: status.provider)
        } else if choice == .alertSecondButtonReturn, let switchProvider {
            selectCloudAiProvider(switchProvider)
        }
    }

    private func addOrUpdateCloudAiModelKey(initialProvider: String) {
        let providerPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 26), pullsDown: false)
        providerPopup.addItems(withTitles: ["Gemini", "OpenAI"])
        providerPopup.selectItem(withTitle: cloudLlmProviderDisplayName(initialProvider))

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 520, height: 24))
        input.placeholderString = "Paste provider API key"
        let pinInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        pinInput.placeholderString = "Parent PIN"

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Cloud AI provider"),
            providerPopup,
            NSTextField(labelWithString: "API key"),
            input,
            NSTextField(labelWithString: "Parent PIN"),
            pinInput,
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.setFrameSize(NSSize(width: 520, height: 150))

        let alert = NSAlert()
        alert.messageText = "Add or update Cloud AI model"
        alert.informativeText = "Choose Gemini or OpenAI. The key is stored in the Hub encrypted SQLCipher database. Saving a key also makes that provider active."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(input)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let provider = cloudLlmProviderValue(providerPopup.selectedItem?.title)
        let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = pinInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard !pin.isEmpty else { return }
        do {
            try saveCloudLlmKeyToHub(provider: provider, key: key, pin: pin)
            UserDefaults.standard.set(provider, forKey: "PlushBuddyCloudLlmProvider")
            UserDefaults.standard.set(true, forKey: "PlushBuddyHubCloudLlmConfigured")
            refreshChecklistButtons(conversationReady: true)
            removeLegacyGeminiKeyFile()
            appendLog("app-shell.log", "\(cloudLlmProviderDisplayName(provider)) key saved to encrypted Hub database")
            showInfoAlert(title: "Cloud AI model saved", message: "\(cloudLlmProviderDisplayName(provider)) is now active for conversation mode.")
            if let hostUrl {
                waitForStationHealth(hostUrl)
            }
        } catch {
            showInfoAlert(title: "Cloud AI model was not saved", message: error.localizedDescription)
        }
    }

    private func selectCloudAiProvider(_ provider: String) {
        let pinInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        pinInput.placeholderString = "Parent PIN"
        let alert = NSAlert()
        alert.messageText = "Use \(cloudLlmProviderDisplayName(provider))?"
        alert.informativeText = "Enter the parent PIN to make \(cloudLlmProviderDisplayName(provider)) the active Cloud AI model."
        alert.accessoryView = pinInput
        alert.addButton(withTitle: "Use \(cloudLlmProviderDisplayName(provider))")
        alert.addButton(withTitle: "Cancel")
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(pinInput)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pin = pinInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { return }
        do {
            try selectCloudAiProviderInHub(provider: provider, pin: pin)
            UserDefaults.standard.set(provider, forKey: "PlushBuddyCloudLlmProvider")
            UserDefaults.standard.set(true, forKey: "PlushBuddyHubCloudLlmConfigured")
            refreshChecklistButtons(conversationReady: true)
            appendLog("app-shell.log", "\(cloudLlmProviderDisplayName(provider)) selected as active Cloud AI model")
            showInfoAlert(title: "Cloud AI model updated", message: "\(cloudLlmProviderDisplayName(provider)) is now active.")
            if let hostUrl {
                waitForStationHealth(hostUrl)
            }
        } catch {
            showInfoAlert(title: "Cloud AI model was not changed", message: error.localizedDescription)
        }
    }

    private struct PairedDevice {
        let clientId: String
        let platform: String
        let label: String?
        let lastSeenAt: Int
        let lastSeenIp: String?
        let revokedAt: Int?

        var isActive: Bool { revokedAt == nil }

        var shortId: String {
            let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 10 else { return trimmed }
            return "\(trimmed.prefix(6))…\(trimmed.suffix(4))"
        }
    }

    @objc private func managePairedDevices() {
        let pinInput = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pinInput.placeholderString = "Parent PIN"
        let pinAlert = NSAlert()
        pinAlert.messageText = "Review paired devices"
        pinAlert.informativeText = "Enter the parent PIN to review phones and apps paired with this Hub."
        pinAlert.accessoryView = pinInput
        pinAlert.addButton(withTitle: "Review")
        pinAlert.addButton(withTitle: "Cancel")
        DispatchQueue.main.async {
            pinAlert.window.makeFirstResponder(pinInput)
        }
        guard pinAlert.runModal() == .alertFirstButtonReturn else { return }
        let pin = pinInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { return }

        do {
            let devices = try pairedDevices(pin: pin)
            guard !devices.isEmpty else {
                showInfoAlert(title: "No paired devices yet", message: "Pair an Android or iPhone app with the QR code. Local Mac and browser clients connect directly.")
                return
            }
            showPairedDevices(devices, pin: pin)
        } catch {
            showInfoAlert(title: "Could not load paired devices", message: error.localizedDescription)
        }
    }

    private func showPairedDevices(_ devices: [PairedDevice], pin: String) {
        let activeDevices = devices.filter(\.isActive)
        let displayDevices = activeDevices.isEmpty ? devices : activeDevices
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 28), pullsDown: false)
        for device in displayDevices {
            popup.addItem(withTitle: pairedDeviceTitle(device))
        }
        let summary = displayDevices.map(pairedDeviceSummary).joined(separator: "\n")
        let stack = NSStackView(views: [
            NSTextField(wrappingLabelWithString: summary),
            NSTextField(labelWithString: "Selected device"),
            popup,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.setFrameSize(NSSize(width: 540, height: min(340, 90 + (displayDevices.count * 38))))

        let alert = NSAlert()
        alert.messageText = "Paired devices"
        alert.informativeText = "These devices stay paired after the Hub closes and reopens. Forget a device if it should pair again."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Forget selected")
        alert.addButton(withTitle: "Close")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedIndex = popup.indexOfSelectedItem
        guard selectedIndex >= 0, selectedIndex < displayDevices.count else { return }
        let selected = displayDevices[selectedIndex]

        let confirm = NSAlert()
        confirm.messageText = "Forget \(pairedDeviceTitle(selected))?"
        confirm.informativeText = "This device will need to scan the Hub QR code again before it can use buddy voices."
        confirm.addButton(withTitle: "Forget device")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try revokePairedDevice(pin: pin, clientId: selected.clientId)
            showInfoAlert(title: "Device forgotten", message: "\(pairedDeviceTitle(selected)) was removed from this Hub.")
        } catch {
            showInfoAlert(title: "Could not forget device", message: error.localizedDescription)
        }
    }

    private func pairedDeviceTitle(_ device: PairedDevice) -> String {
        let label = device.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (label?.isEmpty == false ? label : nil) ?? device.platform.capitalized
        return "\(name) (\(device.shortId))"
    }

    private func pairedDeviceSummary(_ device: PairedDevice) -> String {
        let status = device.isActive ? "paired" : "forgotten"
        let ip = device.lastSeenIp.map { " • \($0)" } ?? ""
        return "• \(pairedDeviceTitle(device)) — \(status) • last seen \(formatUnixSeconds(device.lastSeenAt))\(ip)"
    }

    private func formatUnixSeconds(_ seconds: Int) -> String {
        guard seconds > 0 else { return "unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    @objc private func configureRuntimeMode() {
        let current = selectedRuntimeMode()
        let alert = NSAlert()
        alert.messageText = "Choose PlushBuddy runtime mode"
        alert.informativeText = """
        Cloud LLM mode uses Gemini/OpenAI for answers after Hub redaction and keeps voice, storage, profiles, and audio local.

        Privacy local-first mode avoids cloud LLM calls and uses local models when installed. It is more private, but needs more memory and may be less capable until local model setup is complete.

        Current mode: \(runtimeModeDisplayName(current))
        """
        alert.addButton(withTitle: "Cloud LLM")
        alert.addButton(withTitle: "Privacy local-first")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        let next: String?
        switch choice {
        case .alertFirstButtonReturn:
            next = "cloud_llm"
        case .alertSecondButtonReturn:
            next = "privacy_local_first"
        default:
            next = nil
        }
        guard let next, next != current else { return }
        UserDefaults.standard.set(next, forKey: "PlushBuddyRuntimeMode")
        appendLog("app-shell.log", "runtime mode changed to \(next)")
        retryStartup()
    }

    private func selectedRuntimeMode() -> String {
        if let override = ProcessInfo.processInfo.environment["PLUSHPAL_RUNTIME_MODE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        if let stored = UserDefaults.standard.string(forKey: "PlushBuddyRuntimeMode"),
           ["cloud_llm", "privacy_local_first"].contains(stored) {
            return stored
        }
        return "cloud_llm"
    }

    private func runtimeModeDisplayName(_ mode: String) -> String {
        switch mode {
        case "privacy_local_first":
            return "Privacy local-first"
        case "cloud_llm":
            return "Cloud LLM"
        default:
            return mode
        }
    }

    private func selectedCloudLlmProvider() -> String {
        if let override = ProcessInfo.processInfo.environment["PLUSHPAL_CLOUD_LLM_PROVIDER"] {
            let normalized = cloudLlmProviderValue(override)
            if ["gemini", "openai"].contains(normalized) {
                return normalized
            }
        }
        if let stored = UserDefaults.standard.string(forKey: "PlushBuddyCloudLlmProvider") {
            let normalized = cloudLlmProviderValue(stored)
            if ["gemini", "openai"].contains(normalized) {
                return normalized
            }
        }
        return "gemini"
    }

    private func cloudLlmProviderValue(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai", "open ai":
            return "openai"
        default:
            return "gemini"
        }
    }

    private func cloudLlmProviderDisplayName(_ provider: String) -> String {
        provider == "openai" ? "OpenAI" : "Gemini"
    }

    private struct CloudAiModelStatus {
        let provider: String
        let configured: Bool
        let displayName: String
        let configuredProviders: [String]

        var availableDescription: String {
            configuredProviders.isEmpty
                ? ""
                : configuredProviders.map { $0 == "openai" ? "OpenAI" : "Gemini" }.joined(separator: " + ")
        }
    }

    private func refreshChecklistButtons(conversationReady: Bool? = nil) {
        let parentPinReady = UserDefaults.standard.bool(forKey: "PlushBuddyHubParentPinConfigured")
        let status = try? cloudAiModelStatus()
        if let status {
            UserDefaults.standard.set(status.provider, forKey: "PlushBuddyCloudLlmProvider")
            UserDefaults.standard.set(status.configured, forKey: "PlushBuddyHubCloudLlmConfigured")
        }
        let cloudReady = conversationReady == true || status?.configured == true || UserDefaults.standard.bool(forKey: "PlushBuddyHubCloudLlmConfigured")
        let providerName = status?.displayName ?? cloudLlmProviderDisplayName(selectedCloudLlmProvider())
        let available = status?.availableDescription ?? ""
        let cloudTitle: String
        if cloudReady {
            cloudTitle = available.isEmpty || available == providerName
                ? "Cloud AI model: \(providerName) active"
                : "Cloud AI model: \(providerName) active • \(available) available"
        } else {
            cloudTitle = "Configure Cloud AI model"
        }
        setChecklistButton(parentSetupButton, title: parentPinReady ? "Parent PIN done" : "Set parent PIN", complete: parentPinReady)
        setChecklistButton(configureCloudLlmButton, title: cloudTitle, complete: cloudReady)
    }

    private func setChecklistButton(_ button: NSButton?, title: String, complete: Bool) {
        guard let button else { return }
        button.title = title
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        button.alignment = .left
        button.imagePosition = .imageLeading
        if complete {
            button.image = tintedSymbolImage(
                "checkmark.seal.fill",
                color: NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.30, alpha: 1.0)
            )
            button.contentTintColor = nil
            button.bezelColor = nil
        } else {
            button.image = nil
            button.contentTintColor = NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0)
            button.bezelColor = nil
        }
    }

    private func tintedSymbolImage(_ symbolName: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }
        let image = NSImage(size: base.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: base.size)
        color.setFill()
        rect.fill()
        base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func saveParentPinToHub(pin: String) throws {
        guard pin.count >= 4 else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Parent PIN must be at least 4 characters."]
            )
        }
        let statusCode = try postJsonToHub(path: "/api/v1/parent-pin/configure", body: [
            "pin": pin,
            "age_band": "4-5",
            "character_alias": "Buddy",
            "character_traits": ["gentle", "playful"],
            "retention_days": 1,
        ])
        guard (200..<300).contains(statusCode) else {
            let message: String
            switch statusCode {
            case 401:
                message = "That PIN did not match the existing parent PIN."
            case 400:
                message = "The Hub rejected the PIN settings."
            default:
                message = "Hub returned HTTP \(statusCode)."
            }
            throw NSError(
                domain: "PlushBuddyHub",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func updateParentPinInHub(currentPin: String, newPin: String) throws {
        guard newPin.count >= 4 else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "New parent PIN must be at least 4 characters."]
            )
        }
        let statusCode = try postJsonToHub(path: "/api/v1/parent-pin/update", body: [
            "current_pin": currentPin,
            "new_pin": newPin,
        ])
        guard (200..<300).contains(statusCode) else {
            let message: String
            switch statusCode {
            case 401:
                message = "The current parent PIN was incorrect."
            case 400:
                message = "The new PIN was rejected. Use at least 4 characters."
            case 428:
                message = "No parent PIN is configured yet."
            default:
                message = "Hub returned HTTP \(statusCode)."
            }
            throw NSError(domain: "PlushBuddyHub", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func saveCloudLlmKeyToHub(provider: String, key: String, pin: String) throws {
        guard key.utf8.count >= 16 else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(cloudLlmProviderDisplayName(provider)) API key looks too short."]
            )
        }
        let statusCode = try postJsonToHub(path: "/api/v1/provider/api-key", body: [
            "pin": pin,
            "provider": provider,
            "api_key": key,
        ])

        guard (200..<300).contains(statusCode) else {
            let message: String
            switch statusCode {
            case 401:
                message = "Parent PIN was incorrect, or no parent PIN is configured yet. Use “Set or verify parent PIN” first."
            case 400:
                message = "The selected provider or API key was rejected."
            case 501:
                message = "Encrypted Hub storage is not available."
            default:
                message = "Hub returned HTTP \(statusCode)."
            }
            throw NSError(
                domain: "PlushBuddyHub",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func selectCloudAiProviderInHub(provider: String, pin: String) throws {
        let statusCode = try postJsonToHub(path: "/api/v1/provider/select", body: [
            "pin": pin,
            "provider": provider,
        ])
        guard (200..<300).contains(statusCode) else {
            let message: String
            switch statusCode {
            case 401:
                message = "Parent PIN was incorrect."
            case 400:
                message = "The selected provider was rejected."
            case 428:
                message = "\(cloudLlmProviderDisplayName(provider)) does not have a saved key yet."
            default:
                message = "Hub returned HTTP \(statusCode)."
            }
            throw NSError(domain: "PlushBuddyHub", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func cloudAiModelStatus() throws -> CloudAiModelStatus {
        let object = try getJsonFromHub(path: "/api/v1/provider/status")
        let provider = cloudLlmProviderValue(object["provider"] as? String)
        let configured = object["configured"] as? Bool ?? false
        let displayName = object["display_name"] as? String ?? cloudLlmProviderDisplayName(provider)
        let configuredProviders = (object["configured_providers"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map(cloudLlmProviderValue)
        return CloudAiModelStatus(
            provider: provider,
            configured: configured,
            displayName: displayName,
            configuredProviders: configuredProviders
        )
    }

    private func pairedDevices(pin: String) throws -> [PairedDevice] {
        let rows = try postJsonToHubForArray(path: "/api/v1/paired-clients", body: ["pin": pin])
        return rows.compactMap { row in
            guard let clientId = row["client_id"] as? String else { return nil }
            return PairedDevice(
                clientId: clientId,
                platform: row["platform"] as? String ?? "device",
                label: row["label"] as? String,
                lastSeenAt: row["last_seen_at"] as? Int ?? 0,
                lastSeenIp: row["last_seen_ip"] as? String,
                revokedAt: row["revoked_at"] as? Int
            )
        }
    }

    private func revokePairedDevice(pin: String, clientId: String) throws {
        let statusCode = try postJsonToHub(path: "/api/v1/paired-clients/revoke", body: [
            "pin": pin,
            "client_id": clientId,
        ])
        guard (200..<300).contains(statusCode) else {
            let message: String
            switch statusCode {
            case 401:
                message = "Parent PIN was incorrect."
            case 400:
                message = "The selected device could not be removed."
            default:
                message = "Hub returned HTTP \(statusCode)."
            }
            throw NSError(domain: "PlushBuddyHub", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func postJsonToHub(path: String, body: [String: Any]) throws -> Int {
        let cookie = try stationSessionCookie()
        let endpoint = try stationApiUrl(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(try stationOrigin(), forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return blockingHttpStatus(request).statusCode
    }

    private func getJsonFromHub(path: String) throws -> [String: Any] {
        let cookie = try stationSessionCookie()
        let endpoint = try stationApiUrl(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(try stationOrigin(), forHTTPHeaderField: "Origin")
        let result = blockingHttpData(request)
        guard (200..<300).contains(result.statusCode) else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: result.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Hub returned HTTP \(result.statusCode)."]
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Hub returned an invalid JSON response."]
            )
        }
        return object
    }

    private func postJsonToHubForArray(path: String, body: [String: Any]) throws -> [[String: Any]] {
        let cookie = try stationSessionCookie()
        let endpoint = try stationApiUrl(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(try stationOrigin(), forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result = blockingHttpData(request)
        guard (200..<300).contains(result.statusCode) else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: result.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Hub returned HTTP \(result.statusCode)."]
            )
        }
        return (try JSONSerialization.jsonObject(with: result.data) as? [[String: Any]]) ?? []
    }

    private func stationApiUrl(path: String) throws -> URL {
        guard let hostUrl else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Hub is not running yet."]
            )
        }
        var components = URLComponents()
        components.scheme = hostUrl.scheme
        components.host = hostUrl.host
        components.port = hostUrl.port
        components.path = path
        guard let url = components.url else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Hub URL is invalid."]
            )
        }
        return url
    }

    private func stationOrigin() throws -> String {
        guard let hostUrl,
              let scheme = hostUrl.scheme,
              let host = hostUrl.host else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Hub origin is invalid."]
            )
        }
        if let port = hostUrl.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private func stationSessionCookie() throws -> String {
        if let cached = stationSessionCookieValue, !cached.isEmpty {
            return cached
        }
        guard let hostUrl,
              let fragment = hostUrl.fragment,
              let token = fragment
                  .split(separator: "&")
                  .compactMap({ part -> String? in
                      let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                      return pieces.count == 2 && pieces[0] == "bootstrap" ? pieces[1] : nil
                  })
                  .first,
              !token.isEmpty else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Hub pairing session is missing. Restart Hub and try again."]
            )
        }
        let endpoint = try stationApiUrl(path: "/api/v1/bootstrap")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(token, forHTTPHeaderField: "x-plushpal-bootstrap")
        request.setValue(try stationOrigin(), forHTTPHeaderField: "Origin")
        let result = blockingHttpStatus(request)
        guard (200..<300).contains(result.statusCode),
              let setCookie = result.headers["Set-Cookie"] as? String,
              let cookie = setCookie.split(separator: ";").first.map(String.init),
              cookie.hasPrefix("pp_session=") else {
            throw NSError(
                domain: "PlushBuddyHub",
                code: result.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Could not open an authenticated Hub session. Restart Hub and try again."]
            )
        }
        stationSessionCookieValue = cookie
        return cookie
    }

    private func blockingHttpStatus(_ request: URLRequest) -> (statusCode: Int, headers: [AnyHashable: Any]) {
        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = 0
        var headers: [AnyHashable: Any] = [:]
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let response = response as? HTTPURLResponse {
                statusCode = response.statusCode
                headers = response.allHeaderFields
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return (statusCode, headers)
    }

    private func blockingHttpData(_ request: URLRequest) -> (statusCode: Int, headers: [AnyHashable: Any], data: Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = 0
        var headers: [AnyHashable: Any] = [:]
        var responseData = Data()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse {
                statusCode = response.statusCode
                headers = response.allHeaderFields
            }
            responseData = data ?? Data()
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return (statusCode, headers, responseData)
    }

    private func showInfoAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            if let window = self.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func removeLegacyGeminiKeyFile() {
        let secretsDirectory = applicationSupportDirectory().appendingPathComponent("secrets", isDirectory: true)
        let file = secretsDirectory.appendingPathComponent("gemini_api_key", isDirectory: false)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: secretsDirectory)
    }

    private func consumeHostOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        hostOutput.append(data)
        appendLogData("host.log", data)
        guard let text = String(data: hostOutput, encoding: .utf8) else { return }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("PlushPal test bootstrap URL:") {
                let urlText = line.replacingOccurrences(of: "PlushPal test bootstrap URL:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard parsedHostUrlText != urlText else { continue }
                if let url = URL(string: urlText) {
                    parsedHostUrlText = urlText
                    didLoadHostUrl = true
                    hostUrl = url
                    stationSessionCookieValue = nil
                    appendLog("app-shell.log", "station host url \(urlText)")
                    DispatchQueue.main.async { [weak self] in
                        self?.updateServiceStatuses(
                            storage: nil,
                            reasoning: nil,
                            voice: nil,
                            stt: nil,
                            host: "○ Hub: waking up",
                            browser: "○ Apps: waiting"
                        )
                    }
                    waitForStationHealth(url)
                }
            } else if line.contains("PlushPal LAN bootstrap URL:") {
                let urlText = line.replacingOccurrences(of: "PlushPal LAN bootstrap URL:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: urlText), lanPairingUrl?.absoluteString != urlText {
                    lanPairingUrl = url
                    appendLog("app-shell.log", "station LAN pairing url \(urlText)")
                }
            }
        }
    }

    private func preferredLanIPv4Address() -> String? {
        let addresses = Host.current().addresses
        let privatePrefixes = ["10.", "172.", "192.168."]
        return addresses.first { candidate in
            guard candidate.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else {
                return false
            }
            guard !candidate.hasPrefix("127."), !candidate.hasPrefix("169.254.") else {
                return false
            }
            return privatePrefixes.contains { candidate.hasPrefix($0) }
        } ?? addresses.first { candidate in
            candidate.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil &&
                !candidate.hasPrefix("127.") &&
                !candidate.hasPrefix("169.254.")
        }
    }

    private func waitForStationHealth(_ hostUrl: URL) {
        guard let healthUrl = healthEndpoint(for: hostUrl) else {
            update(.failed("The local PlushBuddy Hub service returned an invalid health-check URL."))
            return
        }
        healthWaitGeneration += 1
        let generation = healthWaitGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for _ in 1...self.healthMaxAttempts {
                guard generation == self.healthWaitGeneration else { return }
                if let health = self.stationHealthSnapshot(healthUrl),
                   self.isStationCoreReady(health) {
                    let conversationReady = self.isConversationEngineReady(health)
                    self.appendLog("app-shell.log", "station health ready \(healthUrl.absoluteString)")
                    DispatchQueue.main.async { [weak self] in
                        self?.updateServiceStatuses(
                            storage: nil,
                            reasoning: self?.reasoningStatusLine(from: health),
                            voice: "✓ Buddy voices: ready",
                            stt: self?.sttStatusLine(from: health),
                            host: "✓ Hub: ready",
                            browser: "✓ Apps: ready to connect"
                        )
                        self?.update(.stationReady(hostUrl, conversationReady: conversationReady))
                    }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.updateServiceStatuses(
                        storage: nil,
                        reasoning: "○ Conversations: checking",
                        voice: "○ Buddy voices: warming up",
                        stt: "○ Listening helper: warming up",
                        host: "○ Hub: waking up",
                        browser: "○ Apps: waiting"
                    )
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            DispatchQueue.main.async { [weak self] in
                self?.updateServiceStatuses(
                    storage: nil,
                    reasoning: "△ Conversations: needs setup",
                    voice: "△ Buddy voices: still waking up",
                    stt: "△ Listening helper: unavailable",
                    host: "✕ Hub: needs attention",
                    browser: "○ Apps: waiting"
                )
                self?.update(.failed("PlushBuddy Hub is still not fully healthy after 15 minutes. If logs show model loading, click Retry setup to resume health checks without restarting. If it is stuck, use Reset voice runtime."))
            }
        }
    }

    private func healthEndpoint(for hostUrl: URL) -> URL? {
        var components = URLComponents()
        components.scheme = hostUrl.scheme
        components.host = hostUrl.host
        components.port = hostUrl.port
        components.path = "/api/v1/health"
        return components.url
    }

    private func stationHealthSnapshot(_ healthUrl: URL) -> [String: Any]? {
        var request = URLRequest(url: healthUrl)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        var snapshot: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard
                let status = (response as? HTTPURLResponse)?.statusCode,
                status == 200,
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return
            }
            snapshot = json
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return snapshot
    }

    private func isStationCoreReady(_ health: [String: Any]) -> Bool {
        health["local_service_ready"] as? Bool == true &&
            health["voice_engine_ready"] as? Bool == true &&
            health["browser_ui_ready"] as? Bool == true
    }

    private func isConversationEngineReady(_ health: [String: Any]) -> Bool {
        health["conversation_engine_ready"] as? Bool == true
    }

    private func reasoningStatusLine(from health: [String: Any]) -> String {
        if isConversationEngineReady(health) {
            return "✓ Conversations: ready"
        }
        return "△ Conversations: configure Cloud LLM or local mode in Hub"
    }

    private func sttStatusLine(from health: [String: Any]) -> String {
        if health["speech_to_text_ready"] as? Bool == true {
            return "✓ Listening helper: ready"
        }
        return "△ Listening helper: phone will listen"
    }

    private func hostDiagnosticTail() -> String {
        guard let text = String(data: hostOutput, encoding: .utf8) else { return "" }
        let lines = text
            .split(separator: "\n")
            .suffix(6)
            .map(String.init)
        return lines.joined(separator: "\n")
    }

    private func setupDiagnosticTail() -> String {
        guard let text = String(data: setupOutput, encoding: .utf8) else { return "Click Retry setup to try again." }
        let lines = text
            .split(separator: "\n")
            .suffix(8)
            .map(String.init)
        return lines.isEmpty ? "Click Retry setup to try again." : lines.joined(separator: "\n")
    }

    private func diagnosticSnapshot() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let lines = [
            "PlushBuddy Hub diagnostics",
            "timestamp: \(timestamp)",
            "app_support: \(applicationSupportDirectory().path)",
            "logs: \(logDirectory().path)",
            "host_url: \(redactedUrl(hostUrl))",
            "lan_pairing_url: \(redactedUrl(lanPairingUrl))",
            "parsed_host_url: \(redactedUrlText(parsedHostUrlText))",
            "storage_status: \(storageStatusLabel.stringValue)",
            "reasoning_status: \(reasoningStatusLabel.stringValue)",
            "voice_status: \(voiceStatusLabel.stringValue)",
            "host_status: \(hostStatusLabel.stringValue)",
            "browser_status: \(browserStatusLabel.stringValue)",
            "",
            "setup_log_tail:",
            redactedDiagnosticText(setupDiagnosticTail()),
            "",
            "host_log_tail:",
            redactedDiagnosticText(hostDiagnosticTail()),
        ]
        return lines.joined(separator: "\n")
    }

    private func redactedUrl(_ url: URL?) -> String {
        guard let url else { return "none" }
        return redactedUrlText(url.absoluteString)
    }

    private func redactedUrlText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "none" }
        guard var components = URLComponents(string: text) else {
            return redactedDiagnosticText(text)
        }
        components.fragment = nil
        return redactedDiagnosticText(components.string ?? text)
    }

    private func redactedDiagnosticText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"#bootstrap=[A-Za-z0-9._~+/=-]+"#,
                with: "#bootstrap=[REDACTED]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"bootstrap=[A-Za-z0-9._~+/=-]+"#,
                with: "bootstrap=[REDACTED]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"AIza[0-9A-Za-z_-]{20,}"#,
                with: "[REDACTED_GOOGLE_API_KEY]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"sk-[0-9A-Za-z_-]{20,}"#,
                with: "[REDACTED_OPENAI_API_KEY]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"github_pat_[0-9A-Za-z_]{20,}"#,
                with: "[REDACTED_GITHUB_TOKEN]",
                options: .regularExpression
            )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendLog("app-shell.log", "webView didFinish \(webView.url?.absoluteString ?? "unknown-url")")
        update(.ready)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        appendLog("app-shell.log", "webView didFail \(error.localizedDescription)")
        update(.failed("Could not load PlushBuddy: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        appendLog("app-shell.log", "webView didFailProvisional \(error.localizedDescription)")
        update(.failed("Could not load PlushBuddy: \(error.localizedDescription)"))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "plushpalLog" else { return }
        if let body = message.body as? [String: Any] {
            let level = body["level"] as? String ?? "browser"
            let text = body["message"] as? String ?? ""
            let url = body["url"] as? String ?? ""
            appendLog("browser.log", "[\(level)] \(url) \(text)")
        } else {
            appendLog("browser.log", "\(message.body)")
        }
    }

    private func appendLogData(_ fileName: String, _ data: Data) {
        guard !data.isEmpty else { return }
        logQueue.async { [weak self] in
            guard let self else { return }
            let file = self.logFile(fileName)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }

    private func appendLog(_ fileName: String, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        appendLogData(fileName, Data("[\(timestamp)] \(message)\n".utf8))
    }

    private func logFile(_ fileName: String) -> URL {
        logDirectory()
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func logDirectory() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("logs", isDirectory: true)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Choose voice sample"
        panel.prompt = "Choose audio file"
        panel.message = "Choose a clean 15-second to 3-minute M4A, WAV, MP3, AAC, OGG, or WebM recording."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [
                .mpeg4Audio,
                .wav,
                .mp3,
                .audio,
                UTType(filenameExtension: "aac") ?? .audio,
                UTType(filenameExtension: "ogg") ?? .audio,
                UTType(filenameExtension: "webm") ?? .audio,
            ]
        } else {
            panel.allowedFileTypes = ["m4a", "mp4", "aac", "wav", "mp3", "ogg", "webm"]
        }
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    private func update(_ state: StartupState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .preparingVoiceRuntime:
                self.setupPanel.isHidden = true
                self.titleLabel.stringValue = "Preparing PlushBuddy Hub"
                self.detailLabel.stringValue = "Checking app storage, local voice support, and cached downloads. First launch can take a few minutes; later launches reuse what is already installed."
                self.progress.isHidden = false
                self.progress.startAnimation(nil)
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.pairedDevicesButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.runtimeModeButton.isHidden = true
                self.themeModeButton.isHidden = true
                self.parentSetupButton.isHidden = true
                self.configureCloudLlmButton.isHidden = true
                self.copyDiagnosticsButton.isHidden = true
                self.openLogsButton.isHidden = true
                self.resetVoiceRuntimeButton.isHidden = true
            case .startingHost:
                self.setupPanel.isHidden = true
                self.titleLabel.stringValue = "Starting Hub service"
                self.detailLabel.stringValue = "Starting the local PlushBuddy Hub service. Client options will appear after health checks pass."
                self.progress.isHidden = false
                self.progress.startAnimation(nil)
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.pairedDevicesButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.runtimeModeButton.isHidden = true
                self.themeModeButton.isHidden = true
                self.parentSetupButton.isHidden = true
                self.configureCloudLlmButton.isHidden = true
                self.copyDiagnosticsButton.isHidden = true
                self.openLogsButton.isHidden = true
                self.resetVoiceRuntimeButton.isHidden = true
            case .loadingApp:
                self.setupPanel.isHidden = true
                self.titleLabel.stringValue = "Loading PlushBuddy Hub"
                self.detailLabel.stringValue = "Almost ready…"
                self.progress.isHidden = false
                self.progress.startAnimation(nil)
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.pairedDevicesButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.runtimeModeButton.isHidden = true
                self.themeModeButton.isHidden = true
                self.parentSetupButton.isHidden = true
                self.configureCloudLlmButton.isHidden = true
                self.copyDiagnosticsButton.isHidden = true
                self.openLogsButton.isHidden = true
                self.resetVoiceRuntimeButton.isHidden = true
            case .stationReady(let url, let conversationReady):
                self.setupPanel.isHidden = false
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                self.refreshChecklistButtons(conversationReady: conversationReady)
                self.titleLabel.stringValue = "PlushBuddy Hub is ready"
                self.detailLabel.stringValue = conversationReady
                    ? "All required local services are healthy. Set parent controls, connect a phone, or open a local client."
                    : "Voice, storage, and pairing are ready. Set or verify the parent PIN, then configure a Cloud AI model before real conversations."
                self.splashScrollView.isHidden = false
                self.webView.isHidden = true
                self.retryButton.isHidden = false
                self.quitButton.isHidden = false
                self.openBrowserButton.isHidden = false
                self.pairAndroidButton.isHidden = false
                self.pairedDevicesButton.isHidden = false
                self.openInAppButton.isHidden = false
                self.runtimeModeButton.isHidden = false
                self.themeModeButton.isHidden = false
                self.parentSetupButton.isHidden = false
                self.configureCloudLlmButton.isHidden = false
                self.copyDiagnosticsButton.isHidden = false
                self.openLogsButton.isHidden = false
                self.resetVoiceRuntimeButton.isHidden = false
                self.hostUrl = url
                self.persistStationClientUrl(url)
            case .ready:
                self.setupPanel.isHidden = true
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                self.splashScrollView.isHidden = true
                self.webView.isHidden = false
                self.retryButton.isHidden = true
                self.quitButton.isHidden = true
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.pairedDevicesButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.runtimeModeButton.isHidden = true
                self.themeModeButton.isHidden = true
                self.parentSetupButton.isHidden = true
                self.configureCloudLlmButton.isHidden = true
                self.copyDiagnosticsButton.isHidden = true
                self.openLogsButton.isHidden = true
                self.resetVoiceRuntimeButton.isHidden = true
            case .failed(let message):
                self.setupPanel.isHidden = true
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                self.titleLabel.stringValue = "PlushBuddy Hub needs setup"
                self.detailLabel.stringValue = message
                self.splashScrollView.isHidden = false
                self.webView.isHidden = true
                self.retryButton.isHidden = false
                self.quitButton.isHidden = false
                self.openBrowserButton.isHidden = true
                self.pairAndroidButton.isHidden = true
                self.pairedDevicesButton.isHidden = true
                self.openInAppButton.isHidden = true
                self.runtimeModeButton.isHidden = false
                self.themeModeButton.isHidden = false
                self.parentSetupButton.isHidden = true
                self.configureCloudLlmButton.isHidden = true
                self.copyDiagnosticsButton.isHidden = false
                self.openLogsButton.isHidden = false
                self.resetVoiceRuntimeButton.isHidden = false
            }
        }
    }

    private func updateServiceStatuses(
        storage: String?,
        reasoning: String?,
        voice: String?,
        stt: String?,
        host: String?,
        browser: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let storage { self.updateStatusLabel(self.storageStatusLabel, text: storage) }
            if let reasoning { self.updateStatusLabel(self.reasoningStatusLabel, text: reasoning) }
            if let voice { self.updateStatusLabel(self.voiceStatusLabel, text: voice) }
            if let stt { self.updateStatusLabel(self.sttStatusLabel, text: stt) }
            if let host { self.updateStatusLabel(self.hostStatusLabel, text: host) }
            if let browser { self.updateStatusLabel(self.browserStatusLabel, text: browser) }
        }
    }

    private func updateStatusLabel(_ label: NSTextField, text: String) {
        let state = statusState(from: text)
        label.stringValue = statusTextWithoutPrefix(text)
        label.textColor = .secondaryLabelColor
        guard let icon = statusIcon(for: label) else { return }
        icon.image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentTintColor = state.color
    }

    private func statusTextWithoutPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusPrefixes: Set<Character> = ["✓", "●", "○", "△", "✕"]
        guard let first = trimmed.first, statusPrefixes.contains(first) else {
            return trimmed
        }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func statusState(from text: String) -> (symbolName: String, color: NSColor) {
        if text.hasPrefix("✓") || text.hasPrefix("●") {
            return ("checkmark.seal.fill", NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.30, alpha: 1.0))
        }
        if text.hasPrefix("△") {
            return ("exclamationmark.triangle.fill", NSColor(calibratedRed: 0.92, green: 0.56, blue: 0.05, alpha: 1.0))
        }
        if text.hasPrefix("✕") {
            return ("xmark.octagon.fill", NSColor.systemRed)
        }
        return ("clock.fill", .secondaryLabelColor)
    }

    private func statusIcon(for label: NSTextField) -> NSImageView? {
        if label === storageStatusLabel { return storageStatusIcon }
        if label === reasoningStatusLabel { return reasoningStatusIcon }
        if label === voiceStatusLabel { return voiceStatusIcon }
        if label === sttStatusLabel { return sttStatusIcon }
        if label === hostStatusLabel { return hostStatusIcon }
        if label === browserStatusLabel { return browserStatusIcon }
        return nil
    }

    private func updateDetail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.detailLabel.stringValue = message
        }
    }

    private func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlushPal", isDirectory: true)
    }

    private func mergedEnvironment(extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let cache = applicationSupportDirectory().appendingPathComponent("cache", isDirectory: true)
        let applicationHuggingFaceCache = cache.appendingPathComponent("huggingface", isDirectory: true)
        let applicationHuggingFaceHubCache = applicationHuggingFaceCache.appendingPathComponent("hub", isDirectory: true)
        let bundledHuggingFaceCache = Bundle.main.resourceURL?
            .appendingPathComponent("model-cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        let numbaCache = cache.appendingPathComponent("numba", isDirectory: true)
        let matplotlibCache = cache.appendingPathComponent("matplotlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: applicationHuggingFaceCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: applicationHuggingFaceHubCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: numbaCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: matplotlibCache, withIntermediateDirectories: true)
        let huggingFaceCache: URL
        let effectiveHubCache: URL
        if let bundledHuggingFaceCache,
           FileManager.default.fileExists(atPath: bundledHuggingFaceCache.path) {
            huggingFaceCache = bundledHuggingFaceCache
            effectiveHubCache = bundledHuggingFaceCache.appendingPathComponent("hub", isDirectory: true)
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        } else {
            huggingFaceCache = applicationHuggingFaceCache
            effectiveHubCache = applicationHuggingFaceHubCache
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["XDG_CACHE_HOME"] = cache.path
        environment["HF_HOME"] = huggingFaceCache.path
        environment["HF_HUB_CACHE"] = effectiveHubCache.path
        environment["TRANSFORMERS_CACHE"] = effectiveHubCache.path
        environment["NUMBA_CACHE_DIR"] = numbaCache.path
        environment["MPLCONFIGDIR"] = matplotlibCache.path
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }
}

private struct VoiceRuntime {
    let engine: String
    let python: URL
    let script: URL
}

private struct SpeechToTextRuntime {
    let command: URL
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
