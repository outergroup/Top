//
//  ActivityMonitorPlugin.swift
//

import Foundation
import AppKit
import QuartzCore

struct TopBinaryReader {
    enum Failure: Error { case invalidPayload }
    let bytes: [UInt8]
    init(_ data: Data, magic: String, minimum: Int) throws {
        bytes = Array(data)
        guard bytes.count >= minimum, bytes.count <= 16 * 1024 * 1024,
              Array(bytes.prefix(4)) == Array(magic.utf8), try u32(4) == 1,
              try u32(8) == bytes.count else { throw Failure.invalidPayload }
    }
    func u32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset <= bytes.count - 4 else { throw Failure.invalidPayload }
        return (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
    }
    func u64(_ offset: Int) throws -> UInt64 {
        try UInt64(u32(offset)) | (UInt64(u32(offset + 4)) << 32)
    }
    func integer(_ offset: Int) throws -> Int {
        guard let result = Int(exactly: try u64(offset)) else { throw Failure.invalidPayload }
        return result
    }
    func number(_ offset: Int) throws -> Double {
        let value = Double(bitPattern: try u64(offset))
        guard value.isFinite, value >= 0 else { throw Failure.invalidPayload }
        return value
    }
    func string(_ field: Int, variable: Int) throws -> String {
        let offset = try u32(field), length = try u32(field + 4)
        guard offset >= variable, offset <= bytes.count, length <= bytes.count - offset else { throw Failure.invalidPayload }
        let value = bytes[offset..<(offset + length)]
        guard !value.contains(0) else { throw Failure.invalidPayload }
        return String(decoding: value, as: UTF8.self)
    }
}
struct TopCPUHistoryResponse {
    struct Sample {
        let timestamp: Double
        let hasCPU: Bool
        let userPercent: Double
        let systemPercent: Double
        let idlePercent: Double
    }
    let samples: [Sample]
    init(_ data: Data) throws {
        let reader = try TopBinaryReader(data, magic: "OTCH", minimum: 32)
        let count = try reader.u32(12)
        guard try reader.u32(16) == 40, try reader.u32(20) == 32, try reader.u64(24) == 0,
              count <= (data.count - 32) / 40, data.count == 32 + count * 40 else { throw TopBinaryReader.Failure.invalidPayload }
        samples = try (0..<count).map { index in
            let offset = 32 + index * 40
            let flags = try reader.u32(offset + 8)
            guard flags <= 1, try reader.u32(offset + 12) == 0 else { throw TopBinaryReader.Failure.invalidPayload }
            return try Sample(timestamp: reader.number(offset), hasCPU: flags == 1,
                              userPercent: reader.number(offset + 16), systemPercent: reader.number(offset + 24),
                              idlePercent: reader.number(offset + 32))
        }
    }
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
            if (try? TopBinaryReader(data, magic: "OTPD", minimum: 144)) != nil {
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

struct TopContainerSnapshot: Sendable {
    struct Process: Sendable {
        let target: String
        let container: String
        let pid: Int
        let start: String
        let command: String
        let user: String
        let memory: Int
        let ticks: UInt64
        let threads: Int
        var identity: String { "\(target):\(pid):\(start)" }
    }
    let timestamp: Double
    let clockTicks: Double
    let processes: [Process]
    let errors: [String]

    init(_ data: Data) throws {
        let reader = try TopBinaryReader(data, magic: "OETP", minimum: 80)
        let targetCount = try reader.u32(16), processCount = try reader.u32(28), errorCount = try reader.u32(40)
        let processOffset = try reader.u32(32), errorOffset = try reader.u32(44), variable = try reader.u32(52)
        guard try reader.u32(12) == 0, try reader.u32(20) == 80, try reader.u32(24) == 56,
              try reader.u32(36) == 112, try reader.u32(48) == 16,
              targetCount <= (data.count - 80) / 56, processOffset == 80 + targetCount * 56,
              processCount <= (data.count - processOffset) / 112, errorOffset == processOffset + processCount * 112,
              errorCount <= (data.count - errorOffset) / 16, variable == errorOffset + errorCount * 16,
              try reader.u32(64) > 0 else { throw TopBinaryReader.Failure.invalidPayload }
        let targets = try (0..<targetCount).map { index in
            (try reader.string(80 + index * 56, variable: variable), try reader.string(104 + index * 56, variable: variable))
        }
        timestamp = Double(try reader.u64(56)) / 1000
        clockTicks = Double(try reader.u32(64))
        processes = try (0..<processCount).map { index in
            let row = processOffset + index * 112, target = try reader.u32(row + 96)
            guard target < targets.count, try reader.u32(row) > 0 else { throw TopBinaryReader.Failure.invalidPayload }
            return try Process(target: targets[target].0, container: targets[target].1, pid: reader.u32(row),
                start: reader.string(row + 56, variable: variable), command: reader.string(row + 64, variable: variable),
                user: reader.string(row + 72, variable: variable), memory: reader.integer(row + 16),
                ticks: reader.u64(row + 24), threads: reader.u32(row + 40))
        }
        errors = try (0..<errorCount).map { index in
            "\(try reader.string(errorOffset + index * 16, variable: variable)): \(try reader.string(errorOffset + index * 16 + 8, variable: variable))"
        }
    }
}
