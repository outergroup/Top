//
//  ActivityMonitorPlugin.swift
//

import Foundation
import AppKit
import QuartzCore

private struct ProcessMonitorConfigurationProbe: Decodable {
    struct Detail: Decodable {}
    let detail: Detail?
}

func makeSystemSymbolImage(systemSymbolName: String,
                           pointSize: CGFloat,
                           weight: NSFont.Weight,
                           scale: CGFloat,
                           tintColor: NSColor,
                           appearance: NSAppearance) -> CGImage? {
    guard let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil) else {
        return nil
    }

    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: tintColor))
    guard let configuredImage = image.withSymbolConfiguration(config) else {
        return nil
    }

    let imageSize = configuredImage.size
    let renderScale = max(scale, 1)
    let pixelWidth = max(Int(ceil(imageSize.width * renderScale)), 1)
    let pixelHeight = max(Int(ceil(imageSize.height * renderScale)), 1)
    let rgbaBytesPerRow = pixelWidth * 4
    var rgbaData = Data(count: rgbaBytesPerRow * pixelHeight)

    return rgbaData.withUnsafeMutableBytes { bytes -> CGImage? in
        guard let baseAddress = bytes.baseAddress else {
            return nil
        }

        guard let context = CGContext(data: baseAddress,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: rgbaBytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        var outputImage: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.clear.set()
            NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
            context.scaleBy(x: renderScale, y: renderScale)
            configuredImage.draw(in: NSRect(origin: .zero, size: imageSize),
                                 from: .zero,
                                 operation: .sourceOver,
                                 fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            outputImage = context.makeImage()
        }
        return outputImage
    }
}

/// Handles the initial initializeContent message before we know which controller to create.
/// Once initializeContent is received, creates the appropriate controller and hands off the delegate.
@MainActor
private final class TopInitHandler: NSObject, OuterframeHostDelegate {
    private let outerframeHost: OuterframeHost
    private let appConnection: OuterframeAppConnection
    private var retainedSelf: TopInitHandler?

    init(outerframeHost: OuterframeHost, appConnection: OuterframeAppConnection) {
        self.outerframeHost = outerframeHost
        self.appConnection = appConnection
        super.init()
        self.retainedSelf = self
    }

    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage) {
        // If we already have a controller, this shouldn't happen (delegate should have been reassigned)
        guard retainedSelf != nil else {
            print("Top: InitHandler received message after controller was created")
            return
        }

        switch message {
        case .accessibilitySnapshotRequest(let requestID):
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID, snapshot: nil)

        case .selectionToPasteboardCopyRequest(let requestID),
             .selectionToPasteboardCutRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: [])

        case .editCommandValidationRequest(let requestID, _):
            outerframeHost.sendEditCommandValidationResponse(requestID: requestID, enabledCommands: [])

        case .initializeContent(let arguments):
            let data = arguments.data ?? Data()
            let size = arguments.contentSize ?? .zero

            // Configure the OuterframeHost with the received data
            outerframeHost.configure(url: arguments.url ?? "",
                                     bundleUrl: arguments.bundleUrl ?? "",
                                     proxyHost: arguments.proxy?.host,
                                     proxyPort: arguments.proxy?.port ?? 0,
                                     proxyUsername: arguments.proxy?.username,
                                     proxyPassword: arguments.proxy?.password)
            outerframeHost.setTitle("Top")
            outerframeHost.setIcon(.bundleResource(path: "Contents/Resources/app-icon.png"))

            let appearance_: NSAppearance = arguments.appearance ?? NSAppearance.currentDrawing()
            let windowIsActive = arguments.windowIsActive ?? true

            // Determine which controller type to create based on pluginData
            if let probe = try? JSONDecoder().decode(ProcessMonitorConfigurationProbe.self, from: data),
               probe.detail != nil {
                if let controller = ProcessDetailContentController(outerframeHost: outerframeHost,
                                                                   appearance: appearance_,
                                                                   windowIsActive: windowIsActive,
                                                                   with: data,
                                                                   size: size,
                                                                   appConnection: appConnection) {
                    outerframeHost.delegate = controller
                }
            } else {
                if let controller = ProcessMonitorListContentController(outerframeHost: outerframeHost,
                                                                        appearance: appearance_,
                                                                        windowIsActive: windowIsActive,
                                                                        with: data,
                                                                        size: size,
                                                                        appConnection: appConnection) {
                    outerframeHost.delegate = controller
                }
            }

            // Clear our self-retention - the controller now retains itself
            retainedSelf = nil

        default:
            print("Top: Expected initializeContent but received \(message)")
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
        print("Top: Socket closed during init")
        retainedSelf = nil
    }
}

@MainActor
@objc public final class TopContent: NSObject, OuterframeContentLibrary {

    @objc public static func start(
        socketFD: Int32,
        appConnection: OuterframeAppConnection
    ) -> Int32 {
        // Create OuterframeHost - it will be configured when initializeContent arrives
        let outerframeHost = OuterframeHost(socketFD: socketFD)

        // Create init handler to receive initializeContent and create the appropriate controller
        let initHandler = TopInitHandler(outerframeHost: outerframeHost, appConnection: appConnection)
        outerframeHost.delegate = initHandler

        return 0
    }
}

// Protocol for content controllers that can handle browser messages
@MainActor
protocol TopContentController: OuterframeHostDelegate {
    var outerframeHost: OuterframeHost { get }
}
