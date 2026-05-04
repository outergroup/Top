//
//  OuterframeHost.swift
//  OuterframeSwiftMethods
//
//  Method-based API for browser communication, wrapping the socket protocol.
//

import AppKit
import Foundation
import Network
import QuartzCore

enum OuterframeHostError: LocalizedError {
    case apiFailure(String)

    var errorDescription: String? {
        switch self {
        case .apiFailure(let methodName):
            return "Missing method, the API may have changed: \(methodName)"
        }
    }
}

/// Delegate for receiving decoded messages from the browser.
@MainActor
protocol OuterframeHostDelegate: AnyObject {
    /// Called when a message is received from the browser.
    /// Note: Some messages (displayLinkFired, displayLinkCallbackRegistered, imageWithSystemSymbolName,
    /// accessibilitySnapshotRequest) are handled internally by OuterframeHost and will not be forwarded
    /// to this delegate.
    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage)

    /// Called when the connection to the browser is closed.
    func outerframeHostDidDisconnect(_ host: OuterframeHost)

    /// Called when the browser requests an accessibility snapshot.
    /// Return the current accessibility tree, or nil if not implemented.
    func outerframeHostAccessibilitySnapshot(_ host: OuterframeHost) -> OuterframeAccessibilitySnapshot?
}

/// Helper class providing method-based API for browser communication
@MainActor
final class OuterframeHost: SocketToBrowserDelegate {
    let socket: SocketToBrowser

    /// Delegate for receiving decoded messages from the browser.
    weak var delegate: OuterframeHostDelegate?

    /// The URL that was navigated to (e.g., "https://example.com/apps/top.outer?host=server1")
    private var _url: String?

    /// The URL where the plugin bundle was downloaded from
    private var _bundleUrl: String?

    // Display link callback management
    private var displayLinkCallbacks: [UUID: @MainActor @Sendable (CFTimeInterval) -> Void] = [:]
    private var pendingDisplayLinkCallbacks: [UUID: @MainActor @Sendable (CFTimeInterval) -> Void] = [:]
    private var callbackIdToBrowserId: [UUID: UUID] = [:]
    private var browserIdToCallbackId: [UUID: UUID] = [:]

    // SF Symbol request tracking
    private var imageRequests: [UUID: (Data?, UInt32, UInt32) -> Void] = [:]

    /// Creates an OuterframeHost and starts the socket.
    /// Call `configure()` after receiving the initializeContent message to set context and appearance.
    init(socketFD: Int32) {
        let socket = SocketToBrowser()
        self.socket = socket
        self._url = nil
        self._bundleUrl = nil

        // Set ourselves as the socket delegate to decode messages
        socket.delegate = self

        // Start the socket for plugin communication
        Task {
            await socket.start(withFileDescriptor: socketFD)
        }
    }

    // MARK: - SocketToBrowserDelegate

    nonisolated func socketToBrowser(_ socket: SocketToBrowser, didReceiveMessageType typeRaw: UInt16, payload: Data) {
        Task { @MainActor in
            handleRawMessage(typeRaw: typeRaw, payload: payload)
        }
    }

    nonisolated func socketToBrowserDidClose(_ socket: SocketToBrowser) {
        Task { @MainActor in
            delegate?.outerframeHostDidDisconnect(self)
        }
    }

    private func handleRawMessage(typeRaw: UInt16, payload: Data) {
        let message: BrowserToContentMessage
        do {
            message = try BrowserToContentMessage.decode(typeRaw: typeRaw, payload: payload)
        } catch {
            print("OuterframeHost: Failed to decode message (type \(typeRaw)): \(error)")
            return
        }

        // Handle internal messages that OuterframeHost manages
        switch message {
        case .displayLinkFired(_, let targetTimestamp):
            handleDisplayLinkFired(targetTimestamp: targetTimestamp)
            return

        case .displayLinkCallbackRegistered(let callbackId, let browserCallbackId):
            handleDisplayLinkCallbackRegistered(callbackId: callbackId, browserCallbackId: browserCallbackId)
            return

        case .imageWithSystemSymbolName(let requestId, let imageData, let width, let height, _, _):
            handleImageWithSystemSymbolNameResponse(requestId: requestId, imageData: imageData, width: width, height: height)
            return

        case .accessibilitySnapshotRequest(let requestId):
            handleAccessibilitySnapshotRequest(requestId: requestId)
            return

        default:
            break
        }

        // Forward all other messages to the delegate
        delegate?.outerframeHost(self, didReceiveMessage: message)
    }

    /// Configures the host with data from the initializeContent message.
    func configure(url: String,
                   bundleUrl: String,
                   proxyHost: String?,
                   proxyPort: UInt16,
                   proxyUsername: String?,
                   proxyPassword: String?) {
        self._url = url
        self._bundleUrl = bundleUrl
        self._networkProxyHost = proxyHost
        self._networkProxyPort = proxyPort
        self._networkProxyUsername = proxyUsername
        self._networkProxyPassword = proxyPassword
    }

    // MARK: - Cursor

    func setCursor(_ cursorType: PluginCursorType) {
        Task {
            try? await socket.send(ContentToBrowserMessage.cursorUpdate(cursorType: UInt8(cursorType.rawValue)).encode())
        }
    }

    // MARK: - Input Mode

    func setInputMode(_ inputMode: OuterframeContentInputMode) {
        Task {
            try? await socket.send(ContentToBrowserMessage.inputModeUpdate(inputMode: inputMode.rawValue).encode())
        }
    }

    // MARK: - Pasteboard Capabilities

    func setPasteboardCapabilities(_ capabilities: OuterframeContentEditingCapabilities) {
        Task {
            try? await socket.send(ContentToBrowserMessage.setPasteboardCapabilities(
                canCopy: capabilities.canCopy,
                canCut: capabilities.canCut,
                pasteboardTypes: capabilities.acceptablePasteboardTypeIdentifiers
            ).encode())
        }
    }

    // MARK: - Display Link

    func registerDisplayLinkCallback(_ callback: @MainActor @Sendable @escaping (CFTimeInterval) -> Void) -> UUID {
        let callbackId = UUID()
        pendingDisplayLinkCallbacks[callbackId] = callback

        Task {
            try? await socket.send(ContentToBrowserMessage.startDisplayLink(callbackId: callbackId).encode())
        }

        return callbackId
    }

    func stopDisplayLinkCallback(_ callbackId: UUID) {
        pendingDisplayLinkCallbacks.removeValue(forKey: callbackId)
        displayLinkCallbacks.removeValue(forKey: callbackId)

        if let browserId = callbackIdToBrowserId.removeValue(forKey: callbackId) {
            browserIdToCallbackId.removeValue(forKey: browserId)
            Task {
                try? await socket.send(ContentToBrowserMessage.stopDisplayLink(browserCallbackId: browserId).encode())
            }
        }
    }

    private func handleDisplayLinkCallbackRegistered(callbackId: UUID, browserCallbackId: UUID) {
        callbackIdToBrowserId[callbackId] = browserCallbackId
        browserIdToCallbackId[browserCallbackId] = callbackId

        if let callback = pendingDisplayLinkCallbacks.removeValue(forKey: callbackId) {
            displayLinkCallbacks[callbackId] = callback
        }
    }

    private func handleDisplayLinkFired(targetTimestamp: Double) {
        for callback in displayLinkCallbacks.values {
            callback(targetTimestamp)
        }
    }

    // MARK: - systemSymbolName image Requests

    func getImage(systemSymbolName: String,
                  pointSize: CGFloat,
                  weight: String,
                  scale: CGFloat,
                  tintColor: NSColor,
                  completion: @escaping (Data?, UInt32, UInt32) -> Void) {
        let requestId = UUID()
        imageRequests[requestId] = completion

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1

        if let converted = tintColor.usingColorSpace(.sRGB) {
            converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }

        Task {
            try? await socket.send(ContentToBrowserMessage.getImageWithSystemSymbolName(
                requestId: requestId,
                symbolName: systemSymbolName,
                pointSize: Float32(pointSize),
                weight: weight,
                scale: Float32(scale),
                tintRed: Float32(red),
                tintGreen: Float32(green),
                tintBlue: Float32(blue),
                tintAlpha: Float32(alpha)
            ).encode())
        }
    }

    private func handleImageWithSystemSymbolNameResponse(requestId: UUID, imageData: Data?, width: UInt32, height: UInt32) {
        if let completion = imageRequests.removeValue(forKey: requestId) {
            completion(imageData, width, height)
        }
    }

    // MARK: - Text Cursor

    func sendTextCursorUpdate(cursors: [[String: Any]]) {
        var snapshots: [OuterframeContentTextCursorSnapshot] = []
        for cursor in cursors {
            guard let fieldId = cursor["fieldId"] as? String,
                  let rect = cursor["rect"] as? CGRect,
                  let visible = cursor["visible"] as? Bool else {
                continue
            }
            snapshots.append(OuterframeContentTextCursorSnapshot(
                fieldId: fieldId,
                rectX: Float32(rect.origin.x),
                rectY: Float32(rect.origin.y),
                rectWidth: Float32(rect.width),
                rectHeight: Float32(rect.height),
                visible: visible
            ))
        }

        Task {
            try? await socket.send(ContentToBrowserMessage.textCursorUpdate(cursors: snapshots).encode())
        }
    }

    // MARK: - Navigation

    func openNewWindow(with url: URL, displayString: String?, preferredSize: CGSize?) {
        Task {
            try? await socket.send(ContentToBrowserMessage.openNewWindow(
                url: url.absoluteString,
                displayString: displayString,
                preferredWidth: preferredSize.map { Float32($0.width) },
                preferredHeight: preferredSize.map { Float32($0.height) }
            ).encode())
        }
    }

    func showContextMenu(for attributedText: NSAttributedString, at location: CGPoint) {
        guard let data = try? attributedText.data(from: NSRange(location: 0, length: attributedText.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            return
        }
        Task {
            try? await socket.send(ContentToBrowserMessage.showContextMenu(
                attributedTextData: data,
                locationX: Float32(location.x),
                locationY: Float32(location.y)
            ).encode())
        }
    }

    func showDefinition(for attributedText: NSAttributedString, at location: CGPoint) {
        guard let data = try? attributedText.data(from: NSRange(location: 0, length: attributedText.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            return
        }
        Task {
            try? await socket.send(ContentToBrowserMessage.showDefinition(
                attributedTextData: data,
                locationX: Float32(location.x),
                locationY: Float32(location.y)
            ).encode())
        }
    }

    // MARK: - Haptic Feedback

    func performHapticFeedback(_ style: OuterframeHapticFeedbackStyle) {
        Task {
            try? await socket.send(ContentToBrowserMessage.hapticFeedback(style: UInt8(style.rawValue)).encode())
        }
    }

    // MARK: - Accessibility

    private func handleAccessibilitySnapshotRequest(requestId: UUID) {
        let snapshot = delegate?.outerframeHostAccessibilitySnapshot(self)
            ?? OuterframeAccessibilitySnapshot.notImplementedSnapshot()
        Task {
            try? await socket.send(ContentToBrowserMessage.accessibilitySnapshotResponse(
                requestId: requestId,
                snapshotData: snapshot.serializedData()
            ).encode())
        }
    }

    // MARK: - Pasteboard

    /// Sends a copy selected pasteboard response to the browser.
    func sendCopySelectedPasteboardResponse(requestId: UUID, items: [OuterframeContentPasteboardItem]) {
        Task {
            try? await socket.send(ContentToBrowserMessage.copySelectedPasteboardResponse(
                requestId: requestId,
                items: items
            ).encode())
        }
    }

    // MARK: - Context URLs

    /// The full URL that was navigated to.
    func pluginURL() -> URL? {
        guard let urlString = _url else { return nil }
        return URL(string: urlString)
    }

    /// The security origin (scheme + host + port).
    func pluginOriginURL() -> URL? {
        guard let url = pluginURL(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The directory containing the .outer file.
    func pluginBaseURL() -> URL? {
        pluginURL()?.deletingLastPathComponent()
    }

    /// The URL where the plugin bundle was downloaded from.
    func pluginBundleURL() -> URL? {
        guard let urlString = _bundleUrl else { return nil }
        return URL(string: urlString)
    }

    // MARK: - Network Proxy (stored separately, set by host before passing to plugin)

    private var _networkProxyHost: String?
    private var _networkProxyPort: UInt16 = 0
    private var _networkProxyUsername: String?
    private var _networkProxyPassword: String?

    func networkProxyConfiguration() -> (host: String, port: UInt16, username: String, password: String)? {
        guard let host = _networkProxyHost,
              let username = _networkProxyUsername,
              let password = _networkProxyPassword else {
            return nil
        }
        return (host, _networkProxyPort, username, password)
    }

    func applyProxy(to configuration: URLSessionConfiguration) {
        guard let proxy = networkProxyConfiguration(),
              !proxy.host.isEmpty,
              proxy.port != 0,
              let endpointPort = NWEndpoint.Port(rawValue: proxy.port) else {
            return
        }

        var socksProxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host),
                                                                    port: endpointPort))
        socksProxy.applyCredential(username: proxy.username, password: proxy.password)
        socksProxy.allowFailover = false
        socksProxy.excludedDomains = []
        socksProxy.matchDomains = [""]
        configuration.proxyConfigurations = [socksProxy]
    }
}

/// Cursor types that plugins can request
enum PluginCursorType: Int {
    case arrow = 0
    case iBeam = 1
    case crosshair = 2
    case openHand = 3
    case closedHand = 4
    case pointingHand = 5
    case resizeLeft = 6
    case resizeRight = 7
    case resizeLeftRight = 8
    case resizeUp = 9
    case resizeDown = 10
    case resizeUpDown = 11
}

enum OuterframeHapticFeedbackStyle: Int {
    case generic = 0
    case alignment = 1
    case levelChange = 2
}

/// Input modes that plugins can request. Represented as a bitmask so modes can be combined.
struct OuterframeContentInputMode: OptionSet, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let textInput = OuterframeContentInputMode(rawValue: 1 << 0)   // Keyboard events interpreted as text
    static let rawKeys = OuterframeContentInputMode(rawValue: 1 << 1)     // Raw key events forwarded to the plugin
    static let none: OuterframeContentInputMode = []

    var allowsTextInput: Bool { contains(.textInput) }
    var allowsRawKeys: Bool { contains(.rawKeys) }
}

/// Describes whether the plugin can currently satisfy copy/paste commands.
struct OuterframeContentEditingCapabilities: Sendable {
    var canCopy: Bool
    var canCut: Bool
    var acceptablePasteboardTypeIdentifiers: [String]

    init(canCopy: Bool,
                canCut: Bool,
                acceptablePasteboardTypeIdentifiers: [String]) {
        self.canCopy = canCopy
        self.canCut = canCut
        self.acceptablePasteboardTypeIdentifiers = acceptablePasteboardTypeIdentifiers
    }
}
