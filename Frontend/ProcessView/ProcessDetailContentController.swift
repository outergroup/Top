import AppKit
import CoreText
import Foundation
import QuartzCore

private struct ProcessMonitorConfiguration: Decodable {
    let apiURL: String?
    let apiPath: String?
    let pollIntervalSeconds: Double?
    let limit: Int?
}

private struct ProcessMonitorInitPayload: Decodable {
    let config: ProcessMonitorConfiguration?
    let processMonitor: ProcessMonitorConfiguration?
    let apiURL: String?
    let apiPath: String?
    let pollIntervalSeconds: Double?
    let limit: Int?
    let mode: String?
    let detail: ProcessDetailInitConfiguration?
}

private struct ProcessDetailInitConfiguration: Decodable {
    let pid: Int
    let detailAPIPath: String?
    let listAPIPath: String?
    let parentPID: Int?
    let parentCommand: String?
    let command: String?
    let isKernelThread: Bool?
    let snapshot: ProcessDetailInitSnapshot?
}

private struct DetailOpenFileEntry: Decodable, Equatable {
    let descriptor: String
    let type: String
    let name: String
}

private struct ProcessDetailInitSnapshot: Decodable {
    let pid: Int?
    let parentPID: Int?
    let parentCommand: String?
    let command: String?
    let openFiles: [DetailOpenFileEntry]?
    let openFilesError: String?
    let threadCount: Int?
    let launchTime: String?
    let cpuPercent: Double?
    let memoryKilobytes: Int?
    let isKernelThread: Bool?
    let cpuTimeMilliseconds: Int?
    let user: String?
}

private struct ProcessDetailResponse: Decodable {
    struct Process: Decodable {
        let pid: Int
        let parentPID: Int?
        let parentShortCommand: String?
        let cpuPercent: Double?
        let memoryKilobytes: Int?
        let virtualMemoryKilobytes: Int?
        let cpuTimeMilliseconds: Int?
        let isKernelThread: Bool?
        let user: String?
        let threadCount: Int?
        let launchTime: String?
        let command: String?
        let shortCommand: String?
        let openFiles: [DetailOpenFileEntry]?
        let openFilesError: String?
    }

    let timestamp: Double?
    let process: Process
}

private struct ProcessDetailSnapshot {
    let pid: Int
    let parentPID: Int?
    let parentShortCommand: String?
    let cpuPercent: Double?
    let memoryKilobytes: Int?
    let virtualMemoryKilobytes: Int?
    let cpuTimeMilliseconds: Int?
    let isKernelThread: Bool
    let user: String?
    let threadCount: Int?
    let launchTime: String?
    let command: String?
    let shortCommand: String?
    let openFiles: [DetailOpenFileEntry]
    let openFilesError: String?
}

private struct ProcessDetailConfig {
    let pid: Int
    let detailAPIPath: String?
    let listAPIPath: String?
    let parentPID: Int?
    let parentCommand: String?
    let command: String?
    let isKernelThread: Bool
}

private struct DetailOpenFileVisual {
    let container: CALayer
    let textLayer: CATextLayer
}

private enum DetailMetric: CaseIterable {
    case cpuPercent
    case cpuTime
    case memory
    case parent
    case threads
    case launched
}


private struct TerminationServerResponse: Decodable {
    let success: Bool
    let error: String?
}


private func makeTextLayer(font: NSFont, color: NSColor, alignment: CATextLayerAlignmentMode) -> CATextLayer {
    let textLayer = CATextLayer()
    textLayer.font = font
    textLayer.fontSize = font.pointSize
    textLayer.foregroundColor = CGColor.clear
    textLayer.alignmentMode = alignment
    textLayer.contentsScale = 2
    textLayer.truncationMode = .end
    return textLayer
}


private let commandBarButtonHeight: CGFloat = 28

private func makeCommandBarButton(title: String, symbolName: String) -> CommandBarButton {
    let container = CALayer()
    container.isGeometryFlipped = true
    container.backgroundColor = CGColor.clear

    let background = CALayer()
    background.cornerRadius = commandBarButtonHeight / 2
    background.masksToBounds = true
    background.backgroundColor = CGColor.clear
    background.borderWidth = 1
    background.borderColor = CGColor.clear
    container.addSublayer(background)

    let iconLayer = CALayer()
    iconLayer.contentsGravity = .resizeAspect
    iconLayer.contentsScale = 2
    container.addSublayer(iconLayer)

    let textLayer = makeTextLayer(font: NSFont.systemFont(ofSize: 13, weight: .regular),
                                  color: .black, alignment: .left)
    textLayer.truncationMode = .end
    textLayer.string = title
    container.addSublayer(textLayer)

    return CommandBarButton(container: container,
                            backgroundLayer: background,
                            iconLayer: iconLayer,
                            textLayer: textLayer,
                            symbolName: symbolName)
}


private func label(for metric: DetailMetric) -> String {
    switch metric {
    case .cpuPercent:
        return "% CPU"
    case .cpuTime:
        return "CPU Time"
    case .memory:
        return "Memory"
    case .parent:
        return "Parent"
    case .threads:
        return "Threads"
    case .launched:
        return "Launched"
    }
}

@MainActor
final class ProcessDetailContentController: NSObject, TopContentController {
    /// Override to disable handling of detail configurations.
    fileprivate var detailConfig: ProcessDetailConfig? = nil

    private struct CountsLayers {
        let container: CALayer
        let threadsValueLayer: CATextLayer
        let processesValueLayer: CATextLayer
        let threadsLabelLayer: CATextLayer
        let processesLabelLayer: CATextLayer
    }

    private struct DetailLayers {
        let containerLayer: CALayer
        let titleLayer: CATextLayer
        let subtitleLayer: CATextLayer
        let commandLayer: CATextLayer
        let metricsContainerLayer: CALayer
        var metricLayers: [DetailMetric: (value: CATextLayer, label: CATextLayer)]
        let buttonBarLayer: CALayer
        let quitButton: CommandBarButton
    }

    private struct OpenFilesLayers {
        let sectionLayer: CALayer
        let titleLayer: CATextLayer
        let viewportLayer: CALayer
        let contentLayer: CALayer
    }

    private final class Layers {
        let rootLayer: CALayer
        let statusLayer: CATextLayer
        var counts: CountsLayers?
        var detail: DetailLayers
        var openFiles: OpenFilesLayers
        var rowVisuals: [DetailOpenFileVisual]

        init(rootLayer: CALayer,
             statusLayer: CATextLayer,
             counts: CountsLayers?,
             detail: DetailLayers,
             openFiles: OpenFilesLayers,
             rowVisuals: [DetailOpenFileVisual]) {
            self.rootLayer = rootLayer
            self.statusLayer = statusLayer
            self.counts = counts
            self.detail = detail
            self.openFiles = openFiles
            self.rowVisuals = rowVisuals
        }
    }

    private var layers: Layers

    private var detailOpenFileEntries: [DetailOpenFileEntry] = []
    private var detailOpenFileLines: [String] = []
    private var detailOpenFilesVisibleRange: Range<Int> = 0..<0
    private var detailOpenFilesHasRealEntries = false
    private var quitConfirmationAlert: QuitConfirmationAlert?
    private var currentSize: CGSize = .zero
    private var appletOriginURL: URL?
    private var appletBaseURL: URL?
    private var appletOuterURL: URL?
    private var apiEndpoint: URL?
    private var detailAPIEndpoint: URL?
    private var endpointSpecifier: String?
    private var pollInterval: TimeInterval = 2.0
    private var detailPollWorkItem: DispatchWorkItem?
    private var configuredRowLimit: Int?
    private var currentScrollOffset: CGFloat = 0
    private var displayedRowCount: Int = 0
    private var selectedPID: Int?
    private var currentDetailSnapshot: ProcessDetailSnapshot?
    private var currentDetailStreamEntry: ProcessEntry?
    private var pendingDetailSnapshot: ProcessDetailSnapshot?
    private var urlSession: URLSession?
    private lazy var urlSessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ProcessMonitorStreamQueue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var streamTask: URLSessionDataTask?
    private var streamBuffer = Data()
    private let messageHeaderSize = MemoryLayout<Double>.size + MemoryLayout<UInt32>.size
    private let entryFixedSize = MemoryLayout<UInt32>.size
        + MemoryLayout<Float>.size
        + MemoryLayout<UInt64>.size * 2
        + MemoryLayout<UInt32>.size * 2
        + MemoryLayout<Int32>.size
        + MemoryLayout<UInt8>.size
    private let systemMetricsBlockSize = MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3 + MemoryLayout<UInt32>.size * 2
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var maintainStream = false
    private var streamGeneration: Int = 0
    private var currentStreamGeneration: Int = 0
    private let clientIdentifier = UUID().uuidString
    private let defaultAPIPath = "/api/processes"
    private let fallbackLocalhostEndpoint = URL(string: "http://127.0.0.1:8000/api/processes")
    let outerframeHost: OuterframeHost
    private(set) var effectiveAppearance: NSAppearance

    // Self-reference to prevent deallocation while socket is open
    private var retainedSelf: ProcessDetailContentController?

    private var detailScrollbarController: ScrollbarController<ProcessDetailContentController>!

    init?(outerframeHost: OuterframeHost, appearance: NSAppearance, windowIsActive: Bool, with data: Data, size: CGSize, appConnection hostAppConnection: OuterframeAppConnection) {

        currentSize = size
        self.isWindowActive = windowIsActive

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = CGColor.clear
        root.cornerRadius = 0

        guard let registerLayer = hostAppConnection.registerLayer else {
            return nil
        }
        registerLayer(root)

        self.outerframeHost = outerframeHost
        self.effectiveAppearance = appearance


        let status = makeTextLayer(font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                   color: .black,
                                   alignment: .left)
        status.alignmentMode = .left
        status.zPosition = 10
        status.isHidden = true
        root.addSublayer(status)

        let container = CALayer()
        container.backgroundColor = CGColor.clear
        container.isGeometryFlipped = true
        root.addSublayer(container)

        let titleLayer = makeTextLayer(font: detailTitleFont,
                                       color: .black,
                                       alignment: .left)
        titleLayer.alignmentMode = .left
        titleLayer.string = startPageTitle
        container.addSublayer(titleLayer)

        let subtitleLayer = makeTextLayer(font: detailSubtitleFont,
                                          color: .black,
                                          alignment: .left)
        subtitleLayer.alignmentMode = .left
        subtitleLayer.string = ""
        container.addSublayer(subtitleLayer)

        let commandLayer = makeTextLayer(font: detailCommandFont,
                                         color: .black,
                                         alignment: .left)
        commandLayer.alignmentMode = .left
        commandLayer.isWrapped = false
        commandLayer.string = ""
        commandLayer.isHidden = true
        container.addSublayer(commandLayer)

        let buttonBar = CALayer()
        buttonBar.backgroundColor = CGColor.clear
        buttonBar.isGeometryFlipped = true
        container.addSublayer(buttonBar)

        let quitButton = makeCommandBarButton(title: "Quit", symbolName: "xmark.circle")
        buttonBar.addSublayer(quitButton.container)

        let metricsContainer = CALayer()
        metricsContainer.backgroundColor = CGColor.clear
        metricsContainer.isGeometryFlipped = true
        container.addSublayer(metricsContainer)

        let openFilesSection = CALayer()
        openFilesSection.backgroundColor = CGColor.clear
        openFilesSection.isGeometryFlipped = true
        openFilesSection.isHidden = true
        openFilesSection.cornerRadius = rowBackgroundCornerRadius
        openFilesSection.borderWidth = 1
        openFilesSection.masksToBounds = true
        openFilesSection.contentsScale = 2
        container.addSublayer(openFilesSection)

        let openFilesTitle = makeTextLayer(font: detailOpenFilesTitleFont,
                                           color: .black,
                                           alignment: .left)
        openFilesTitle.alignmentMode = .left
        openFilesTitle.isWrapped = false
        openFilesTitle.string = "Open Files and Ports"
        openFilesSection.addSublayer(openFilesTitle)

        let openFilesViewport = CALayer()
        openFilesViewport.backgroundColor = CGColor.clear
        openFilesViewport.masksToBounds = true
        openFilesViewport.contentsScale = 2
        openFilesSection.addSublayer(openFilesViewport)

        let openFilesContent = CALayer()
        openFilesContent.backgroundColor = CGColor.clear
        openFilesContent.isGeometryFlipped = true
        openFilesViewport.addSublayer(openFilesContent)

        var metricLayers: [DetailMetric: (value: CATextLayer, label: CATextLayer)] = [:]
        for metric in DetailMetric.allCases {
            let valueLayer = makeTextLayer(font: detailMetricValueFont,
                                           color: .black,
                                           alignment: .left)
            valueLayer.alignmentMode = .left
            valueLayer.string = "—"
            let labelLayer = makeTextLayer(font: detailMetricLabelFont,
                                           color: .black,
                                            alignment: .left)
            labelLayer.alignmentMode = .left
            labelLayer.string = label(for: metric)
            metricsContainer.addSublayer(valueLayer)
            metricsContainer.addSublayer(labelLayer)
            metricLayers[metric] = (valueLayer, labelLayer)
        }

        let detail = DetailLayers(containerLayer: container,
                                   titleLayer: titleLayer,
                                   subtitleLayer: subtitleLayer,
                                   commandLayer: commandLayer,
                                   metricsContainerLayer: metricsContainer,
                                   metricLayers: metricLayers,
                                   buttonBarLayer: buttonBar,
                                   quitButton: quitButton)
        let openFiles = OpenFilesLayers(sectionLayer: openFilesSection,
                                         titleLayer: openFilesTitle,
                                         viewportLayer: openFilesViewport,
                                         contentLayer: openFilesContent)

        layers = Layers(rootLayer: root,
                        statusLayer: status,
                        counts: nil,
                        detail: detail,
                        openFiles: openFiles,
                        rowVisuals: [])
        detailOpenFileEntries = []
        detailOpenFileLines = []
        detailOpenFilesVisibleRange = 0..<0
        detailOpenFilesHasRealEntries = false

        super.init()

        detailScrollbarController = ScrollbarController(appConnection: outerframeHost,
                                                        viewportLayer: openFiles.viewportLayer,
                                                        appearance: appearance,
                                                        width: 8,
                                                        inset: 4,
                                                        scrollOffsetOrigin: .bottom)
        detailScrollbarController.delegate = self

        applyConfiguration(data: data)

        updateDetailDisplayedValues()

        // Configure URLs from connection
        configureAppletContextFromConnection()

        // Now continue with initialization
        appearanceDidChange()
        applyColorsToLayers()
        layoutLayers()
        updateMetaText()
        startStreamingIfPossible()

        detailScrollbarController.updateLayout(metrics: detailScrollbarMetrics())

        // Keep self alive until socket closes
        retainedSelf = self
    }

    private let startPageTitle = "Top"

    private var bodyTextColor: NSColor = .black
    private var selectedRowTextColor: NSColor = .white
    private var activeSelectionBackgroundColor: NSColor = NSColor.systemBlue
    private var inactiveSelectionBackgroundColor: NSColor = NSColor.systemBlue.withAlphaComponent(0.4)
    private var activeSelectionTextColor: NSColor = .white
    private var inactiveSelectionTextColor: NSColor = .black
    private var isWindowActive: Bool

    private let alertPanelCornerRadius: CGFloat = 12
    private let alertButtonHeight: CGFloat = 28
    private let alertButtonSpacing: CGFloat = 12
    private let alertButtonHorizontalPadding: CGFloat = 18
    private let alertPanelHorizontalPadding: CGFloat = 24
    private let alertPanelVerticalPadding: CGFloat = 24

    private let numericFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let commandFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let alertTitleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
    private let alertMessageFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let alertButtonFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let detailTitleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    private let detailSubtitleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private let detailCommandFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let detailMetricValueFont = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium)
    private let detailMetricLabelFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let detailMetricsPreferredHeight: CGFloat = 220
    private let detailMetricsMinimumHeight: CGFloat = 120
    private let detailOpenFilesMinimumHeight: CGFloat = 140
    private let detailOpenFilesTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let detailOpenFilesFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let detailOpenFilesRowHeight: CGFloat = 22
    private let detailOpenFilesTitleSpacing: CGFloat = 8
    private let detailOpenFilesSectionInset: CGFloat = 8
    private let detailOpenFilesTextHorizontalInset: CGFloat = 8
    private let detailOpenFilesTextVerticalInset: CGFloat = 3
    private let detailOpenFilesDescriptorColumnWidth = 6
    private let detailOpenFilesTypeColumnWidth = 7
    private var hasInitializedNumericGlyphCache = false
    private var hasInitializedCommandImageCache = false
    private var hasInitializedSelectedNumericGlyphCache = false
    private var hasInitializedSelectedCommandImageCache = false

    private lazy var numericGlyphCache: NumericGlyphCache = {
        hasInitializedNumericGlyphCache = true
        return NumericGlyphCache(
            font: numericFont,
            color: bodyTextColor,
            appearance: effectiveAppearance,
            contentsScale: 2
        )
    }()

    private lazy var commandImageCache: CommandImageCache = {
        hasInitializedCommandImageCache = true
        return CommandImageCache(
            font: commandFont,
            color: bodyTextColor,
            appearance: effectiveAppearance,
            contentsScale: 2
        )
    }()

    private lazy var selectedNumericGlyphCache: NumericGlyphCache = {
        hasInitializedSelectedNumericGlyphCache = true
        return NumericGlyphCache(
            font: numericFont,
            color: selectedRowTextColor,
            appearance: effectiveAppearance,
            contentsScale: 2
        )
    }()

    private lazy var selectedCommandImageCache: CommandImageCache = {
        hasInitializedSelectedCommandImageCache = true
        return CommandImageCache(
            font: commandFont,
            color: selectedRowTextColor,
            appearance: effectiveAppearance,
            contentsScale: 2
        )
    }()

    private lazy var streamDelegate = ProcessStreamDelegate(owner: self)

    private let commandBarHeight: CGFloat = 38
    private let commandBarHorizontalInset: CGFloat = 16
    private let commandBarItemSpacing: CGFloat = 12
    private let commandBarGroupSpacing: CGFloat = 16
    private let commandBarIconTextSpacing: CGFloat = 6
    private let commandBarButtonHorizontalPadding: CGFloat = 12
    private let commandBarDefaultIconSize = CGSize(width: 16, height: 16)
    private let searchFieldHeight: CGFloat = 28
    private let searchFieldMinWidth: CGFloat = 180
    private let searchFieldMaxWidth: CGFloat = 280
    private let searchFieldHorizontalPadding: CGFloat = 12
    private let searchFieldIconSpacing: CGFloat = 6
    private let searchFieldClearButtonSpacing: CGFloat = 6
    private let searchFieldCaretWidth: CGFloat = 1
    private let searchFieldClearButtonDefaultSize = CGSize(width: 14, height: 14)
    private let searchFieldClearSymbolName = "xmark.circle.fill"
    private let rowHeight: CGFloat = 28
    private let headerHeight: CGFloat = 28
    private let tableHorizontalInset: CGFloat = 0
    private let tableTopInset: CGFloat = 0
    private let tableBottomInset: CGFloat = 0
    private let rowContentHorizontalInset: CGFloat = 16
    private let rowBackgroundVerticalInset: CGFloat = 0
    private let rowBackgroundCornerRadius: CGFloat = 6
    private let cellContentHorizontalInset: CGFloat = 8
    private let headerFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let headerFontHighlighted = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let cpuTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let systemSectionPreferredHeight: CGFloat = 150
    private let systemSectionMinimumHeight: CGFloat = 110
    private let systemSectionContentPadding: CGFloat = 16
    private let systemSectionColumnSpacing: CGFloat = 24
    private let cpuStatsRowSpacing: CGFloat = 8
    private let cpuStatsValueSpacing: CGFloat = 8
    private let cpuStatsLabelFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let cpuStatsValueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private let countsLabelFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let maxCpuHistoryCount = 180
    private let detailContentHorizontalPadding: CGFloat = 24
    private let detailContentVerticalPadding: CGFloat = 18
    private let detailTitleSpacing: CGFloat = 6
    private let detailCommandSpacing: CGFloat = 14
    private let detailMetricsColumnSpacing: CGFloat = 32
    private let detailMetricsRowSpacing: CGFloat = 16
    private let detailSectionSpacing: CGFloat = 24
    private let detailMetricValueLabelSpacing: CGFloat = 4
    private let detailMinimumHeight: CGFloat = 220
    private let detailButtonSpacing: CGFloat = 12

    func cleanup() {
        cancelStream(triggerReconnect: false)
        cancelDetailPolling()
        urlSession?.invalidateAndCancel()
        urlSession = nil
        apiEndpoint = nil
        detailAPIEndpoint = nil
        endpointSpecifier = nil
        appletOriginURL = nil
        appletBaseURL = nil
        appletOuterURL = nil
        detailScrollbarController.cleanup()
        currentScrollOffset = 0
        selectedPID = nil
        isWindowActive = true
        reconnectAttempts = 0
        maintainStream = false
        streamBuffer.removeAll(keepingCapacity: false)
        quitConfirmationAlert?.overlayLayer.removeFromSuperlayer()
        quitConfirmationAlert = nil
        detailOpenFileEntries = []
        detailOpenFileLines = []
        detailOpenFilesVisibleRange = 0..<0
        detailOpenFilesHasRealEntries = false
        currentDetailSnapshot = nil
       currentDetailStreamEntry = nil
       pendingDetailSnapshot = nil
    }

    func accessibilitySnapshot() -> OuterframeAccessibilitySnapshot? {
        var nextId: UInt32 = 0
        func makeId() -> UInt32 {
            let id = nextId
            nextId += 1
            return id
        }

        let rootFrame = layers.rootLayer.bounds
        let rootLayer = layers.rootLayer

        func frameInRoot(_ layer: CALayer) -> CGRect {
            rootLayer.convert(layer.bounds, from: layer)
        }

        var children: [OuterframeAccessibilityNode] = []

        // Title
        let titleFrame = frameInRoot(layers.detail.titleLayer)
        let titleText = (layers.detail.titleLayer.string as? String) ?? ""
        if !titleText.isEmpty {
            let titleNode = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .staticText,
                frame: titleFrame,
                label: "Process name",
                value: titleText
            )
            children.append(titleNode)
        }

        // Subtitle (PID info)
        let subtitleFrame = frameInRoot(layers.detail.subtitleLayer)
        let subtitleText = (layers.detail.subtitleLayer.string as? String) ?? ""
        if !subtitleText.isEmpty {
            let subtitleNode = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .staticText,
                frame: subtitleFrame,
                label: "Process ID",
                value: subtitleText
            )
            children.append(subtitleNode)
        }

        // Command (full command line)
        if !layers.detail.commandLayer.isHidden {
            let commandFrame = frameInRoot(layers.detail.commandLayer)
            let commandText = (layers.detail.commandLayer.string as? String) ?? ""
            if !commandText.isEmpty {
                let commandNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .staticText,
                    frame: commandFrame,
                    label: "Command",
                    value: commandText
                )
                children.append(commandNode)
            }
        }

        // Quit button
        let quitButtonFrame = frameInRoot(layers.detail.quitButton.container)
        let quitButtonNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .button,
            frame: quitButtonFrame,
            label: "Quit",
            hint: "Quit the process"
        )
        children.append(quitButtonNode)

        // Metrics section
        if !layers.detail.metricsContainerLayer.isHidden {
            var metricNodes: [OuterframeAccessibilityNode] = []
            for metric in DetailMetric.allCases {
                guard let pair = layers.detail.metricLayers[metric] else { continue }

                let valueFrame = frameInRoot(pair.value)
                let valueText = (pair.value.string as? String) ?? "—"
                let labelFrame = frameInRoot(pair.label)
                let labelText = label(for: metric)

                let labelNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .staticText,
                    frame: labelFrame,
                    label: labelText
                )
                metricNodes.append(labelNode)

                let valueNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .staticText,
                    frame: valueFrame,
                    label: labelText,
                    value: valueText
                )
                metricNodes.append(valueNode)
            }

            let metricsFrame = frameInRoot(layers.detail.metricsContainerLayer)
            let metricsNode = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .container,
                frame: metricsFrame,
                label: "Process Metrics",
                children: metricNodes
            )
            children.append(metricsNode)
        }

        // Open Files section
        if !layers.openFiles.sectionLayer.isHidden {
            var openFilesChildren: [OuterframeAccessibilityNode] = []

            // Title
            let openFilesTitleFrame = frameInRoot(layers.openFiles.titleLayer)
            let openFilesTitleText = (layers.openFiles.titleLayer.string as? String) ?? "Open Files and Ports"
            let openFilesTitleNode = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .staticText,
                frame: openFilesTitleFrame,
                label: openFilesTitleText
            )
            openFilesChildren.append(openFilesTitleNode)

            // Visible rows
            let visibleRange = detailOpenFilesVisibleRange
            for (visualIndex, rowIndex) in visibleRange.enumerated() {
                guard visualIndex < layers.rowVisuals.count,
                      rowIndex < detailOpenFileLines.count else { continue }
                let visual = layers.rowVisuals[visualIndex]
                let lineText = detailOpenFileLines[rowIndex]

                let rowFrame = frameInRoot(visual.container)
                let rowNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .staticText,
                    frame: rowFrame,
                    label: "Open file",
                    value: lineText
                )
                openFilesChildren.append(rowNode)
            }

            let openFilesFrame = frameInRoot(layers.openFiles.sectionLayer)
            let totalCount = detailOpenFileLines.count
            let visibleCount = visibleRange.count
            let hint = totalCount > visibleCount ? "Showing \(visibleCount) of \(totalCount) entries" : nil
            let openFilesNode = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .container,
                frame: openFilesFrame,
                label: "Open Files and Ports",
                hint: hint,
                children: openFilesChildren
            )
            children.append(openFilesNode)
        }

        let rootNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .container,
            frame: rootFrame,
            label: "Process Details",
            children: children
        )

        return OuterframeAccessibilitySnapshot(rootNodes: [rootNode])
    }

    private func notifyAccessibilityTreeChanged() {
        let notification = OuterframeAccessibilityNotification.layoutChanged
        Task {
            try? await outerframeHost.socket.send(
                ContentToBrowserMessage.accessibilityTreeChanged(notificationMask: notification.rawValue).encode()
            )
        }
    }

    func appearanceDidChange() {
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            let controlBackground = NSColor.controlBackgroundColor
            let accent = NSColor.controlAccentColor
            let inactiveSelectionBase = NSColor.unemphasizedSelectedTextBackgroundColor
            let isLightTheme = controlBackground.am_brightness > 0.6

            let inactiveFallback = controlBackground.am_blended(withFraction: isLightTheme ? 0.08 : 0.14, toward: label)

            activeSelectionBackgroundColor = accent
            var inactiveSelectionColor = inactiveSelectionBase
            if inactiveSelectionColor.cgColor == accent.cgColor {
                inactiveSelectionColor = inactiveFallback
            }
            inactiveSelectionBackgroundColor = inactiveSelectionColor
            activeSelectionTextColor = .white
            inactiveSelectionTextColor = label

            bodyTextColor = label
        }

        if hasInitializedNumericGlyphCache {
            numericGlyphCache.updateColor(bodyTextColor, appearance: appearance)
        }
        if hasInitializedCommandImageCache {
            commandImageCache.updateColor(bodyTextColor, appearance: appearance)
        }
        if hasInitializedSelectedNumericGlyphCache {
            selectedNumericGlyphCache.updateColor(selectedRowTextColor, appearance: appearance)
        }
        if hasInitializedSelectedCommandImageCache {
            selectedCommandImageCache.updateColor(selectedRowTextColor, appearance: appearance)
        }

        applyColorsToLayers()
    }

    func setWindowActive(_ isActive: Bool) {
        if isWindowActive == isActive { return }
        isWindowActive = isActive
    }

    func resize(width: Int, height: Int) {
        currentSize = CGSize(width: width, height: height)
        layoutLayers()
    }

    func mouseDown(at point: CGPoint, modifierFlags: NSEvent.ModifierFlags, clickCount: Int) {

        let root = layers.rootLayer

        if handleAlertMouseDown(at: point) {
            return
        }

        let viewport = layers.openFiles.viewportLayer
        if detailScrollbarController.handleMouseDown(at: root.convert(point, to: viewport)) == true {
            return
        }

        if handleDetailButtonsMouseDown(at: point, modifierFlags: modifierFlags, clickCount: clickCount) {
            return
        }
    }

    func mouseDragged(to point: CGPoint, modifierFlags _: NSEvent.ModifierFlags) {

        let root = layers.rootLayer
        let viewport = layers.openFiles.viewportLayer
        _ = detailScrollbarController.handleMouseDragged(to: root.convert(point, to: viewport))
    }

    func mouseUp(at point: CGPoint, modifierFlags _: NSEvent.ModifierFlags) {

        let root = layers.rootLayer
        let viewport = layers.openFiles.viewportLayer
        _ = detailScrollbarController.handleMouseUp(at: root.convert(point, to: viewport))
    }

    func scrollWheel(delta: CGPoint,
                           at point: CGPoint,
                           modifierFlags _: NSEvent.ModifierFlags,
                           phase _: NSEvent.Phase,
                           momentumPhase _: NSEvent.Phase,
                           hasPreciseScrollingDeltas: Bool) {

        let root = layers.rootLayer
        let viewport = layers.openFiles.viewportLayer
        let pointInViewport = viewport.convert(point, from: root)
        guard viewport.bounds.contains(pointInViewport) else { return }
        let multiplier: CGFloat = hasPreciseScrollingDeltas ? 1.0 : detailOpenFilesRowHeight
        let adjustedDeltaY = delta.y * multiplier
        guard adjustedDeltaY != 0 else { return }
        detailScrollbarController.cancelAnimation()
        _ = scrollDetailOpenFiles(byAdjustedDeltaY: adjustedDeltaY)
    }

    // MARK: Private API

    private func applyConfiguration(data: Data) {
        // Reset to defaults before applying overrides
        pollInterval = 2.0
        configuredRowLimit = nil
        endpointSpecifier = nil
        apiEndpoint = nil
        detailAPIEndpoint = nil
        currentDetailSnapshot = nil
        currentDetailStreamEntry = nil
        currentScrollOffset = 0
        pendingDetailSnapshot = nil

        configureAppletContextFromConnection()

        guard !data.isEmpty else {
            ensureEndpointAvailable()
            return
        }

        let decoder = JSONDecoder()
        var pendingDetailConfig: ProcessDetailConfig?
        var pendingListSpecifier: String?

        if let payload = try? decoder.decode(ProcessMonitorInitPayload.self, from: data) {
            let rootConfig = ProcessMonitorConfiguration(
                apiURL: payload.apiURL,
                apiPath: payload.apiPath,
                pollIntervalSeconds: payload.pollIntervalSeconds,
                limit: payload.limit
            )

            let configChains: [ProcessMonitorConfiguration?] = [
                rootConfig,
                payload.config,
                payload.processMonitor
            ]

            for config in configChains.compactMap({ $0 }) {
                applyConfigurationDetails(config)
            }

            if let detailConfig = payload.detail {
                pendingDetailConfig = ProcessDetailConfig(
                    pid: detailConfig.pid,
                    detailAPIPath: detailConfig.detailAPIPath,
                    listAPIPath: detailConfig.listAPIPath,
                    parentPID: detailConfig.parentPID,
                    parentCommand: detailConfig.parentCommand,
                    command: detailConfig.command,
                    isKernelThread: detailConfig.isKernelThread ?? false
                )
                if let snapshot = detailConfig.snapshot {
                    let seededSnapshot = ProcessDetailSnapshot(
                        pid: snapshot.pid ?? detailConfig.pid,
                        parentPID: snapshot.parentPID ?? detailConfig.parentPID,
                        parentShortCommand: snapshot.parentCommand ?? detailConfig.parentCommand,
                        cpuPercent: snapshot.cpuPercent,
                        memoryKilobytes: snapshot.memoryKilobytes,
                        virtualMemoryKilobytes: nil,
                        cpuTimeMilliseconds: snapshot.cpuTimeMilliseconds,
                        isKernelThread: snapshot.isKernelThread ?? detailConfig.isKernelThread ?? false,
                        user: snapshot.user,
                        threadCount: snapshot.threadCount,
                        launchTime: snapshot.launchTime,
                        command: snapshot.command ?? detailConfig.command,
                        shortCommand: snapshot.command ?? detailConfig.command,
                        openFiles: snapshot.openFiles ?? [],
                        openFilesError: snapshot.openFilesError
                    )
                    pendingDetailSnapshot = seededSnapshot
                }
                if let listPath = detailConfig.listAPIPath,
                   !listPath.isEmpty {
                    pendingListSpecifier = listPath
                }
            }
        } else if let configuration = try? decoder.decode(ProcessMonitorConfiguration.self, from: data) {
            applyConfigurationDetails(configuration)
        }

        if let listSpecifier = pendingListSpecifier, endpointSpecifier == nil {
            endpointSpecifier = listSpecifier
        }

        ensureEndpointAvailable()

        let detailConfig = pendingDetailConfig!
        self.detailConfig = detailConfig

        detailAPIEndpoint = resolveDetailEndpoint(for: detailConfig)
        let initialSnapshot = pendingDetailSnapshot
        currentDetailSnapshot = ProcessDetailSnapshot(
            pid: detailConfig.pid,
            parentPID: detailConfig.parentPID,
            parentShortCommand: initialSnapshot?.parentShortCommand ?? detailConfig.parentCommand,
            cpuPercent: initialSnapshot?.cpuPercent,
            memoryKilobytes: initialSnapshot?.memoryKilobytes,
            virtualMemoryKilobytes: nil,
            cpuTimeMilliseconds: initialSnapshot?.cpuTimeMilliseconds,
            isKernelThread: initialSnapshot?.isKernelThread ?? detailConfig.isKernelThread,
            user: initialSnapshot?.user,
            threadCount: initialSnapshot?.threadCount,
            launchTime: initialSnapshot?.launchTime,
            command: detailConfig.command,
            shortCommand: detailConfig.command,
            openFiles: initialSnapshot?.openFiles ?? [],
            openFilesError: initialSnapshot?.openFilesError
        )
        currentDetailStreamEntry = nil
        pendingDetailSnapshot = nil
        updateDetailDisplayedValues()

        fetchDetailInfoIfNeeded()
    }

    private func configureAppletContextFromConnection() {
        appletOuterURL = outerframeHost.pluginURL()
        appletOriginURL = outerframeHost.pluginOriginURL()
        appletBaseURL = outerframeHost.pluginBaseURL()

        updateMetaText()
    }

    private func applyConfigurationDetails(_ configuration: ProcessMonitorConfiguration) {
        if let interval = configuration.pollIntervalSeconds {
            pollInterval = max(0.1, interval)
        }

        if let limit = configuration.limit, limit > 0 {
            configuredRowLimit = limit
        }

        if let apiPath = configuration.apiPath,
           !apiPath.isEmpty {
            endpointSpecifier = apiPath
        }

        if let apiURLString = configuration.apiURL,
           !apiURLString.isEmpty {
            endpointSpecifier = apiURLString
        }
    }

    private func ensureEndpointAvailable() {
        if let specifier = endpointSpecifier,
           let resolved = resolveEndpoint(from: specifier) {
            updateEndpoint(to: resolved)
            return
        }

        if let resolvedDefault = resolveEndpoint(from: defaultAPIPath) {
            updateEndpoint(to: resolvedDefault)
            return
        }

        updateEndpoint(to: fallbackLocalhostEndpoint)
    }

    private func updateEndpoint(to newEndpoint: URL?) {
        if apiEndpoint == newEndpoint {
            return
        }
        apiEndpoint = newEndpoint
        // In detail mode, we use polling instead of streaming since the backend
        // only allows one stream client and the list view is typically connected.
        // The polling is started via fetchDetailInfoIfNeeded() after config is applied.
        if detailConfig == nil {
            if let endpoint = newEndpoint {
                startProcessStream(with: endpoint)
            } else {
                cancelStream(triggerReconnect: false)
            }
        }
    }

    private func resolveEndpoint(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        if trimmed.hasPrefix("//"), let scheme = appletOriginURL?.scheme {
            return URL(string: "\(scheme):\(trimmed)")
        }

        if let base = appletBaseURL,
           let relativeToBase = URL(string: trimmed, relativeTo: base) {
            return relativeToBase.absoluteURL
        }

        if let origin = appletOriginURL,
           let relativeToOrigin = URL(string: trimmed, relativeTo: origin) {
            return relativeToOrigin.absoluteURL
        }

        return nil
    }

    private func resolveDetailEndpoint(for config: ProcessDetailConfig) -> URL? {
        if let detailSpecifier = config.detailAPIPath,
           let resolved = resolveEndpoint(from: detailSpecifier) {
            return resolved
        }

        let defaultDetailPath = "\(defaultAPIPath)/\(config.pid)"
        if let resolvedDefault = resolveEndpoint(from: defaultDetailPath) {
            return resolvedDefault
        }

        if let fallback = fallbackLocalhostEndpoint {
            return fallback.appendingPathComponent(String(config.pid))
        }

        return nil
    }

    private func normalizeOriginURL(from string: String) -> URL? {
        guard var components = URLComponents(string: string) else {
            return URL(string: string)
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func extractOrigin(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func updateDetailDisplayedValues() {

        let snapshot = currentDetailSnapshot
        let streamEntry = currentDetailStreamEntry

        updateDetailOpenFiles(with: snapshot)

        let detailConfig = detailConfig!
        let detailLayers = layers.detail

        let displayName: String
        if let name = snapshot?.shortCommand, !name.isEmpty {
            displayName = name
        } else if let command = snapshot?.command, !command.isEmpty {
            displayName = command
        } else {
            displayName = "PID \(detailConfig.pid)"
        }

        let titleText = "Process: \(displayName)"
        detailLayers.titleLayer.string = titleText

        let subtitle = detailSubtitle(for: snapshot, pid: detailConfig.pid)
        detailLayers.subtitleLayer.string = subtitle.isEmpty ? "PID \(detailConfig.pid)" : subtitle

        if let command = snapshot?.command, !command.isEmpty {
            detailLayers.commandLayer.isHidden = false
            detailLayers.commandLayer.string = command
        } else {
            detailLayers.commandLayer.isHidden = true
            detailLayers.commandLayer.string = ""
        }

        if let cpuPercent = streamEntry?.cpuPercent ?? snapshot?.cpuPercent {
            setDetailMetric(.cpuPercent, value: formattedSingleDecimal(cpuPercent) + "%")
        } else {
            setDetailMetric(.cpuPercent, value: "—")
        }

        if let cpuTime = streamEntry?.cpuTimeMilliseconds ?? snapshot?.cpuTimeMilliseconds {
            setDetailMetric(.cpuTime, value: formattedCpuTime(cpuTime))
        } else {
            setDetailMetric(.cpuTime, value: "—")
        }

        let isKernelThread = streamEntry?.isKernelThread ?? snapshot?.isKernelThread ?? false
        if let memory = streamEntry?.memoryKilobytes ?? snapshot?.memoryKilobytes {
            setDetailMetric(.memory, value: formattedMemory(kilobytes: memory, isKernelThread: isKernelThread))
        } else {
            setDetailMetric(.memory, value: "—")
        }

        if let parentCommand = snapshot?.parentShortCommand, let parentPID = snapshot?.parentPID {
            setDetailMetric(.parent, value: "\(parentCommand) (\(parentPID))")
        } else if let parentPID = snapshot?.parentPID {
            setDetailMetric(.parent, value: formattedInteger(parentPID))
        } else {
            setDetailMetric(.parent, value: "—")
        }

        if let threads = snapshot?.threadCount {
            setDetailMetric(.threads, value: formattedInteger(threads))
        } else {
            setDetailMetric(.threads, value: "—")
        }

        if let launch = snapshot?.launchTime, !launch.isEmpty {
            setDetailMetric(.launched, value: launch)
        } else {
            setDetailMetric(.launched, value: "—")
        }

        performWithoutAnimation {
            layoutLayers()
        }

        notifyAccessibilityTreeChanged()
    }

    private func setDetailMetric(_ metric: DetailMetric, value: String) {
        guard let pair = layers.detail.metricLayers[metric] else { return }
        pair.value.string = value
    }

    private func detailSubtitle(for snapshot: ProcessDetailSnapshot?, pid: Int) -> String {
        var parts: [String] = []
        if let user = snapshot?.user, !user.isEmpty {
            parts.append(user)
        }
        parts.append("PID \(pid)")
        if let threads = snapshot?.threadCount {
            parts.append("\(threads) threads")
        }
        return parts.joined(separator: " • ")
    }

    private func updateDetailOpenFiles(with snapshot: ProcessDetailSnapshot?) {
        let entries = snapshot?.openFiles ?? []
        detailOpenFilesHasRealEntries = !entries.isEmpty
        let errorMessage = snapshot?.openFilesError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholderLine: String
        if detailOpenFilesHasRealEntries {
            placeholderLine = ""
        } else if let message = errorMessage, !message.isEmpty {
            placeholderLine = message
        } else {
            placeholderLine = "No open files or ports found."
        }
        let formattedLines: [String]
        if detailOpenFilesHasRealEntries {
            formattedLines = entries.map { formattedDetailOpenFileLine($0) }
        } else {
            formattedLines = placeholderLine.isEmpty ? [] : [placeholderLine]
        }
        layers.openFiles.sectionLayer.isHidden = formattedLines.isEmpty

        let linesChanged = formattedLines != detailOpenFileLines
        detailOpenFileEntries = entries
        if !linesChanged {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                updateDetailOpenFilesTextColor(textColor: NSColor.textColor.cgColor, placeholderColor: NSColor.tertiaryLabelColor.cgColor)
            }
            return
        }

        detailOpenFileLines = formattedLines
        detailOpenFilesVisibleRange = 0..<0

        let targetOffset: CGFloat
        if formattedLines.count <= 1 {
            targetOffset = 0
        } else {
            let viewport = layers.openFiles.viewportLayer
            let viewportHeight = viewport.bounds.height
            let maxOffset = max(CGFloat(formattedLines.count) * detailOpenFilesRowHeight - viewportHeight, 0)
            targetOffset = min(currentScrollOffset, maxOffset)
        }

        detailScrollbarController.cancelAnimation()
        setDetailScrollOffset(targetOffset, forceLayout: true)
    }

    private func detailEntryForTermination() -> ProcessEntry? {
        let detailConfig = detailConfig!

        let snapshot = currentDetailSnapshot
        let streamEntry = currentDetailStreamEntry

        let commandText: String
        if let command = snapshot?.command, !command.isEmpty {
            commandText = command
        } else if let short = snapshot?.shortCommand, !short.isEmpty {
            commandText = short
        } else {
            commandText = "PID \(detailConfig.pid)"
        }

        let cpuPercent = streamEntry?.cpuPercent ?? snapshot?.cpuPercent ?? 0
        let memory = streamEntry?.memoryKilobytes ?? snapshot?.memoryKilobytes ?? 0
        let cpuTime = streamEntry?.cpuTimeMilliseconds ?? snapshot?.cpuTimeMilliseconds ?? 0
        let isKernelThread = streamEntry?.isKernelThread ?? snapshot?.isKernelThread ?? false
        let user = snapshot?.user ?? ""

        return ProcessEntry(
            pid: detailConfig.pid,
            cpuPercent: cpuPercent,
            memoryKilobytes: memory,
            cpuTimeMilliseconds: cpuTime,
            isKernelThread: isKernelThread,
            user: user,
            command: commandText,
            previousIndex: nil
        )
    }

    private func updateDetailFromStream(entries: [ProcessEntry], pid: Int) {
        if let match = entries.first(where: { $0.pid == pid }) {
            currentDetailStreamEntry = match
            showStatus(nil)
        } else {
            currentDetailStreamEntry = nil
            showStatus("Process \(pid) not found.")
        }

        updateDetailDisplayedValues()
    }

    private func applyColorsToLayers() {

        performWithoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let label = NSColor.labelColor
                let secondaryLabel = NSColor.secondaryLabelColor
                let tertiaryLabel = NSColor.tertiaryLabelColor
                let textBackground = NSColor.textBackgroundColor
                let separator = NSColor.separatorColor
                let status = NSColor.systemRed
                let controlBackground = NSColor.controlBackgroundColor
                let isLightTheme = controlBackground.am_brightness > 0.6

                layers.rootLayer.backgroundColor = CGColor.clear
                layers.statusLayer.foregroundColor = status.cgColor

                if let counts = layers.counts {
                    counts.threadsValueLayer.foregroundColor = label.cgColor
                    counts.processesValueLayer.foregroundColor = label.cgColor
                    counts.threadsLabelLayer.foregroundColor = tertiaryLabel.cgColor
                    counts.processesLabelLayer.foregroundColor = tertiaryLabel.cgColor
                }

                let detail = layers.detail
                detail.titleLayer.foregroundColor = label.cgColor
                detail.subtitleLayer.foregroundColor = secondaryLabel.cgColor
                detail.commandLayer.foregroundColor = tertiaryLabel.cgColor
                for metric in detail.metricLayers.values {
                    metric.value.foregroundColor = label.cgColor
                    metric.label.foregroundColor = tertiaryLabel.cgColor
                }

                let openFiles = layers.openFiles
                openFiles.titleLayer.foregroundColor = secondaryLabel.cgColor
                let openFileBackground = textBackground
                let openFileBackgroundAlpha: CGFloat = isLightTheme ? 0.88 : 0.55
                openFiles.viewportLayer.backgroundColor = openFileBackground.am_withAlpha(openFileBackgroundAlpha).cgColor
                openFiles.sectionLayer.borderColor = separator.am_withAlpha(isLightTheme ? 0.35 : 0.55).cgColor
                openFiles.sectionLayer.backgroundColor = openFileBackground.am_withAlpha(openFileBackgroundAlpha).cgColor
                updateDetailOpenFilesTextColor(textColor: NSColor.textColor.cgColor, placeholderColor: tertiaryLabel.cgColor)

                let quit = detail.quitButton
                quit.backgroundLayer.backgroundColor = NSColor.secondarySystemFill.cgColor
                quit.backgroundLayer.borderColor = separator.am_withAlpha(isLightTheme ? 0.18 : 0.28).cgColor
                quit.textLayer.foregroundColor = label.cgColor
            }

            detailScrollbarController.updateAppearance(effectiveAppearance)
        }
        updateQuitConfirmationColors()
    }

    private func startStreamingIfPossible() {
        guard streamTask == nil else { return }
        guard let endpoint = apiEndpoint else {
            showStatus("Missing process endpoint.")
            return
        }
        startProcessStream(with: endpoint)
    }

    private func makeRequestSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        outerframeHost.applyProxy(to: configuration)
        return URLSession(configuration: configuration)
    }

    private func performSingleRequest(_ request: URLRequest,
                                      completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        let session = makeRequestSession()
        session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
            session.finishTasksAndInvalidate()
        }.resume()
    }

    private func ensureURLSession() {
        if urlSession != nil { return }
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 60 * 60
        configuration.timeoutIntervalForResource = 60 * 60
        outerframeHost.applyProxy(to: configuration)
        urlSession = URLSession(configuration: configuration, delegate: streamDelegate, delegateQueue: urlSessionQueue)
    }

    private func startDetailPolling() {
        cancelDetailPolling()
        fetchDetailInfo()
    }

    private func cancelDetailPolling() {
        detailPollWorkItem?.cancel()
        detailPollWorkItem = nil
    }

    private func scheduleNextDetailPoll() {
        detailPollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fetchDetailInfo()
        }
        detailPollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: workItem)
    }

    private func fetchDetailInfo() {
        guard let endpoint = detailAPIEndpoint else {
            scheduleNextDetailPoll()
            return
        }

        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        performSingleRequest(request) { [weak self] data, response, error in
            guard let self else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if let error = error {
                    self.showStatus("Error: \(error.localizedDescription)")
                    self.scheduleNextDetailPoll()
                    return
                }

                guard let data = data,
                      let decoded = try? JSONDecoder().decode(ProcessDetailResponse.self, from: data) else {
                    self.scheduleNextDetailPoll()
                    return
                }

                let process = decoded.process
                let snapshot = ProcessDetailSnapshot(
                    pid: process.pid,
                    parentPID: process.parentPID,
                    parentShortCommand: process.parentShortCommand,
                    cpuPercent: process.cpuPercent,
                    memoryKilobytes: process.memoryKilobytes,
                    virtualMemoryKilobytes: process.virtualMemoryKilobytes,
                    cpuTimeMilliseconds: process.cpuTimeMilliseconds,
                    isKernelThread: process.isKernelThread ?? false,
                    user: process.user,
                    threadCount: process.threadCount,
                    launchTime: process.launchTime,
                    command: process.command,
                    shortCommand: process.shortCommand,
                    openFiles: process.openFiles ?? [],
                    openFilesError: process.openFilesError
                )

                self.currentDetailSnapshot = snapshot
                self.showStatus(nil)
                self.updateDetailDisplayedValues()
                self.scheduleNextDetailPoll()
            }
        }
    }

    private func fetchDetailInfoIfNeeded() {
        // Legacy method - now just starts polling
        startDetailPolling()
    }

    private func startProcessStream(with endpoint: URL) {
        guard let streamURL = makeStreamURL(from: endpoint) else {
            showStatus("Invalid process stream URL.")
            return
        }

        ensureURLSession()
        cancelStream(triggerReconnect: false)

        reconnectAttempts = 0
        streamBuffer.removeAll(keepingCapacity: false)

        var request = URLRequest(url: streamURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 * 60

        streamGeneration += 1
        let generation = streamGeneration

        guard let task = urlSession?.dataTask(with: request) else {
            maintainStream = false
            showStatus("Failed to start process stream.")
            updateMetaText()
            return
        }

        task.taskDescription = String(generation)
        streamTask = task
        currentStreamGeneration = generation
        maintainStream = true
        task.resume()

        fetchDetailInfoIfNeeded()

        updateMetaText()
        showStatus("Connecting to process stream…")
    }

    private func makeStreamURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if !path.hasSuffix("/stream") {
            if path.hasSuffix("/") {
                path.append("stream")
            } else {
                path.append("/stream")
            }
            components.path = path
        }
        // The stream endpoint requires a clientId parameter
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "clientId", value: clientIdentifier))
        components.queryItems = queryItems
        return components.url
    }

    private func detailURL(forPID pid: Int) -> URL? {
        guard let outerURL = appletOuterURL else { return nil }
        guard var components = URLComponents(url: outerURL, resolvingAgainstBaseURL: false) else { return nil }

        var items = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return name != "mode" && name != "pid"
        } ?? []
        items.append(URLQueryItem(name: "mode", value: "detail"))
        items.append(URLQueryItem(name: "pid", value: String(pid)))
        components.queryItems = items
        return components.url
    }

    private func cancelStream(triggerReconnect: Bool) {
        maintainStream = triggerReconnect
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        streamTask?.cancel()
        streamTask = nil
        streamBuffer.removeAll(keepingCapacity: false)
        updateMetaText()
    }

    func handleStreamResponse(_ response: URLResponse, for task: URLSessionDataTask) -> URLSession.ResponseDisposition {
        guard isCurrentStreamTask(task) else { return .cancel }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            showStatus("Stream error: HTTP \(httpResponse.statusCode)")
            updateMetaText()
            scheduleReconnect(with: nil)
            return .cancel
        }

        reconnectAttempts = 0
        showStatus(nil)
        updateMetaText()
        return .allow
    }

    func handleStreamData(_ data: Data, for task: URLSessionDataTask) {
        guard isCurrentStreamTask(task) else { return }
        streamBuffer.append(data)
        processStreamBuffer()
    }

    func handleStreamCompletion(_ error: Error?, for task: URLSessionTask) {
        guard isCurrentStreamTask(task) else { return }
        streamTask = nil
        updateMetaText()

        if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled && !maintainStream {
            return
        }

        scheduleReconnect(with: error)
    }

    private func isCurrentStreamTask(_ task: URLSessionTask) -> Bool {
        guard let description = task.taskDescription, let generation = Int(description) else { return false }
        return generation == currentStreamGeneration
    }

    private func scheduleReconnect(with error: Error?) {
        guard maintainStream else { return }
        reconnectWorkItem?.cancel()
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), maxReconnectDelay)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let endpoint = self.apiEndpoint else { return }
            self.startProcessStream(with: endpoint)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

        let delayString = String(format: "%.0f", delay)
        if let error = error as NSError?, error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled {
            showStatus("Connection lost (\(error.localizedDescription)). Reconnecting in \(delayString)s…")
        } else {
            showStatus("Connection lost. Reconnecting in \(delayString)s…")
        }
        updateMetaText()
    }

    private func processStreamBuffer() {
        while true {
            guard streamBuffer.count >= messageHeaderSize else { return }

            guard readDoubleLE(from: streamBuffer, offset: 0) != nil,  // timestamp
                  let entryCountRaw = readUInt32LE(from: streamBuffer, offset: MemoryLayout<Double>.size) else {
                streamBuffer.removeAll(keepingCapacity: true)
                return
            }

            var offset = messageHeaderSize
            let entryCount = Int(entryCountRaw)
            var entries: [ProcessEntry] = []
            entries.reserveCapacity(entryCount)

            var hasCompleteMessage = true

            for _ in 0..<entryCount {
                guard streamBuffer.count >= offset + entryFixedSize,
                      let pidValue = readUInt32LE(from: streamBuffer, offset: offset),
                      let cpuValue = readFloatLE(from: streamBuffer, offset: offset + MemoryLayout<UInt32>.size) else {
                    hasCompleteMessage = false
                    break
                }

                let memoryOffset = offset + MemoryLayout<UInt32>.size + MemoryLayout<Float>.size
                guard let memoryValue = readUInt64LE(from: streamBuffer, offset: memoryOffset),
                      let cpuTimeValue = readUInt64LE(from: streamBuffer, offset: memoryOffset + MemoryLayout<UInt64>.size),
                      let userLength = readUInt32LE(from: streamBuffer, offset: memoryOffset + MemoryLayout<UInt64>.size * 2),
                      let commandLength = readUInt32LE(from: streamBuffer, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size),
                      let flags = readUInt8(from: streamBuffer, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size * 2 + MemoryLayout<Int32>.size) else {
                    hasCompleteMessage = false
                    break
                }

                let userLengthInt = Int(userLength)
                let commandLengthInt = Int(commandLength)
                let totalLength = entryFixedSize + userLengthInt + commandLengthInt
                guard streamBuffer.count >= offset + totalLength else {
                    hasCompleteMessage = false
                    break
                }

                let userStart = offset + entryFixedSize
                let commandStart = userStart + userLengthInt
                guard let user = stringFromData(streamBuffer, offset: userStart, length: userLengthInt),
                      let command = stringFromData(streamBuffer, offset: commandStart, length: commandLengthInt) else {
                    hasCompleteMessage = false
                    break
                }

                let entry = ProcessEntry(
                    pid: Int(pidValue),
                    cpuPercent: Double(cpuValue),
                    memoryKilobytes: Int(memoryValue),
                    cpuTimeMilliseconds: Int(cpuTimeValue),
                    isKernelThread: (flags & 0x1) != 0,
                    user: user,
                    command: command,
                    previousIndex: nil
                )
                entries.append(entry)
                offset += totalLength
            }

            guard hasCompleteMessage else {
                return
            }

            guard streamBuffer.count >= offset + systemMetricsBlockSize,
                  readUInt8(from: streamBuffer, offset: offset) != nil, // metricsFlag
                  readFloatLE(from: streamBuffer, offset: offset + MemoryLayout<UInt8>.size) != nil, // userValue
                  readFloatLE(from: streamBuffer, offset: offset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size) != nil, // systemValue
                  readFloatLE(from: streamBuffer, offset: offset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 2) != nil, // idleValue
                  readUInt32LE(from: streamBuffer, offset: offset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3) != nil, // processCountValue
                  readUInt32LE(from: streamBuffer, offset: offset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3 + MemoryLayout<UInt32>.size) != nil // threadCountValue
            else {
                return
            }

            offset += systemMetricsBlockSize
            streamBuffer.removeSubrange(0..<offset)

            updateDetailFromStream(entries: entries, pid: detailConfig!.pid)

            updateMetaText()
        }
    }


    private func layoutLayers() {

        let root = layers.rootLayer
        let status = layers.statusLayer

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        root.frame = CGRect(origin: .zero, size: currentSize)

        layoutDetailLayers(statusLayer: status)
        CATransaction.commit()
    }


    private func layoutDetailLayers(statusLayer: CATextLayer) {

        let root = layers.rootLayer
        let detailContainer = layers.detail.containerLayer

        let availableWidth = root.bounds.width
        let availableHeight = root.bounds.height
        let contentHeight = availableHeight

        detailContainer.frame = CGRect(x: 0,
                                       y: 0,
                                       width: availableWidth,
                                       height: contentHeight)
        layoutDetailContents(in: detailContainer)

        if let counts = layers.counts {
            counts.container.isHidden = true
        }
    }

    private func layoutDetailContents(in detailContainer: CALayer) {

        let detailLayers = layers.detail
        let openFilesLayers = layers.openFiles

        let width = detailContainer.bounds.width
        let height = detailContainer.bounds.height
        guard width > 0, height > 0 else { return }

        let contentWidth = max(width - detailContentHorizontalPadding * 2, 0)
        let buttonBarWidth = layoutDetailButtonBar(in: detailContainer)
        let blockingWidth = buttonBarWidth > 0 ? buttonBarWidth + detailButtonSpacing : 0
        let textWidth = max(contentWidth - blockingWidth, 0)
        var currentY = detailContentVerticalPadding

        let titleHeight = detailLayers.titleLayer.preferredFrameSize().height
        detailLayers.titleLayer.frame = CGRect(x: detailContentHorizontalPadding,
                                               y: currentY,
                                               width: textWidth,
                                               height: titleHeight)
        currentY += titleHeight + detailTitleSpacing

        let subtitleHeight = detailLayers.subtitleLayer.preferredFrameSize().height
        detailLayers.subtitleLayer.frame = CGRect(x: detailContentHorizontalPadding,
                                                  y: currentY,
                                                  width: textWidth,
                                                  height: subtitleHeight)
        currentY += subtitleHeight + detailTitleSpacing

        if !detailLayers.commandLayer.isHidden {
            let commandHeight = detailLayers.commandLayer.preferredFrameSize().height
            detailLayers.commandLayer.frame = CGRect(x: detailContentHorizontalPadding,
                                                     y: currentY,
                                                     width: textWidth,
                                                     height: commandHeight)
            currentY += commandHeight + detailCommandSpacing
        }
        else {
            detailLayers.commandLayer.frame = .zero
        }

        let hasOpenFiles = !detailOpenFileLines.isEmpty
        let availableSectionHeight = max(height - currentY - detailContentVerticalPadding, 0)
        var metricsHeight = availableSectionHeight
        var openFilesHeight: CGFloat = 0
        var sectionSpacing: CGFloat = 0

        if hasOpenFiles {
            let metricsMin = detailMetricsMinimumHeight
            let metricsPreferred = detailMetricsPreferredHeight
            let titleLineHeight = detailOpenFilesTitleFont.ascender - detailOpenFilesTitleFont.descender
            let openContentMin = detailOpenFilesSectionInset * 2
                + titleLineHeight
                + detailOpenFilesTitleSpacing
                + (detailOpenFilesRowHeight + detailOpenFilesTextVerticalInset * 2)
            let openMinBase = max(detailOpenFilesMinimumHeight, openContentMin)
            let openMin = detailOpenFilesHasRealEntries ? openMinBase : openContentMin

            metricsHeight = min(metricsPreferred, availableSectionHeight)
            if metricsHeight < metricsMin && availableSectionHeight >= metricsMin {
                metricsHeight = min(metricsMin, availableSectionHeight)
            }
            metricsHeight = max(metricsHeight, 0)

            var remaining = max(availableSectionHeight - metricsHeight, 0)
            var spacing = (metricsHeight > 0 && remaining > 0) ? detailSectionSpacing : 0

            if spacing > 0 && remaining < spacing {
                let needed = spacing - remaining
                let reducible = max(metricsHeight - metricsMin, 0)
                let reduction = min(needed, reducible)
                metricsHeight = max(metricsHeight - reduction, 0)
                remaining = max(availableSectionHeight - metricsHeight, 0)
                spacing = (metricsHeight > 0 && remaining > 0) ? detailSectionSpacing : 0
            }

            if spacing > 0 {
                remaining = max(remaining - spacing, 0)
            }

            var openCandidate = max(remaining, 0)

            if openCandidate < openMin && availableSectionHeight >= openMin {
                let needed = openMin - openCandidate
                let reducible = max(metricsHeight - metricsMin, 0)
                let reduction = min(needed, reducible)
                metricsHeight = max(metricsHeight - reduction, 0)

                remaining = max(availableSectionHeight - metricsHeight, 0)
                spacing = (metricsHeight > 0 && remaining > 0) ? detailSectionSpacing : 0
                if spacing > 0 {
                    remaining = max(remaining - spacing, 0)
                }
                openCandidate = max(remaining, 0)
            }

            if openCandidate > 0 && openCandidate < openMin && availableSectionHeight >= openMin {
                openCandidate = min(openMin, availableSectionHeight)
            }

            openFilesHeight = max(openCandidate, 0)
            sectionSpacing = (metricsHeight > 0 && openFilesHeight > 0) ? detailSectionSpacing : 0
        } else {
            metricsHeight = availableSectionHeight
            sectionSpacing = 0
        }

        metricsHeight = max(metricsHeight, 0)
        if !hasOpenFiles {
            openFilesHeight = 0
        }

        var sectionY = currentY

        let metricsContainer = detailLayers.metricsContainerLayer
        metricsContainer.isHidden = metricsHeight <= 0
        metricsContainer.frame = CGRect(x: detailContentHorizontalPadding,
                                        y: sectionY,
                                        width: contentWidth,
                                        height: metricsHeight)
        if metricsHeight > 0 {
            layoutDetailMetrics(in: metricsContainer)
            sectionY += metricsHeight
        }

        if sectionSpacing > 0 {
            sectionY += sectionSpacing
        }

        let openFilesSection = openFilesLayers.sectionLayer
        let viewport = openFilesLayers.viewportLayer
        let titleLayer = openFilesLayers.titleLayer
        if hasOpenFiles && openFilesHeight > 0 {
            openFilesSection.isHidden = false
            openFilesSection.frame = CGRect(x: detailContentHorizontalPadding,
                                            y: sectionY,
                                            width: contentWidth,
                                            height: openFilesHeight)
            layoutDetailOpenFilesSection(in: openFilesSection)
            sectionY += openFilesHeight
        } else {
            openFilesSection.isHidden = true
            openFilesSection.frame = .zero
            viewport.frame = .zero
            titleLayer.frame = .zero
        }

        currentY = sectionY

        // The status layer is a sublayer of the root layer (not flipped),
        // so Y=0 is at the bottom. Position it near the bottom.
        let statusHeight: CGFloat = 18
        let statusWidth = max(width - detailContentHorizontalPadding * 2, 0)
        let statusY = detailContentVerticalPadding
        layers.statusLayer.frame = CGRect(x: detailContentHorizontalPadding,
                                          y: statusY,
                                          width: statusWidth,
                                          height: statusHeight)
    }

    private func layoutDetailMetrics(in container: CALayer) {
        let bounds = container.bounds
        let availableWidth = bounds.width
        let availableHeight = bounds.height
        guard availableWidth > 0, availableHeight >= 0 else {
            container.isHidden = true
            return
        }
        container.isHidden = false

        let columnCount = 2
        let columnSpacing = detailMetricsColumnSpacing
        let columnWidth = max((availableWidth - columnSpacing) / CGFloat(columnCount), 0)
        let metricMap = layers.detail.metricLayers
        let metrics = DetailMetric.allCases
        let rowCount = Int(ceil(Double(metrics.count) / Double(columnCount)))

        var yCursor: CGFloat = 0
        for rowIndex in 0..<rowCount {
            var rowMetrics: [DetailMetric] = []
            for columnIndex in 0..<columnCount {
                let metricIndex = rowIndex * columnCount + columnIndex
                if metricIndex < metrics.count {
                    rowMetrics.append(metrics[metricIndex])
                }
            }

            var rowHeight: CGFloat = 0
            var dimensionCache: [(metric: DetailMetric, valueHeight: CGFloat, labelHeight: CGFloat)] = []
            for metric in rowMetrics {
                guard let pair = metricMap[metric] else { continue }
                let valueHeight = pair.value.preferredFrameSize().height
                let labelHeight = pair.label.preferredFrameSize().height
                rowHeight = max(rowHeight, valueHeight + detailMetricValueLabelSpacing + labelHeight)
                dimensionCache.append((metric, valueHeight, labelHeight))
            }

            for (columnIndex, entry) in dimensionCache.enumerated() {
                guard let pair = metricMap[entry.metric] else { continue }
                let x = CGFloat(columnIndex) * (columnWidth + columnSpacing)
                pair.value.frame = CGRect(x: x,
                                          y: yCursor,
                                          width: columnWidth,
                                          height: entry.valueHeight)
                pair.label.frame = CGRect(x: x,
                                          y: yCursor + entry.valueHeight + detailMetricValueLabelSpacing,
                                          width: columnWidth,
                                          height: entry.labelHeight)
            }

            yCursor += rowHeight + detailMetricsRowSpacing
        }
    }

    private func layoutDetailOpenFilesSection(in section: CALayer) {

        let titleLayer = layers.openFiles.titleLayer
        let viewport = layers.openFiles.viewportLayer

        let bounds = section.bounds
        let width = bounds.width
        let height = bounds.height
        if width <= 0 || height <= 0 {
            titleLayer.frame = .zero
            viewport.frame = .zero
            layoutDetailOpenFilesRows(force: true)
            return
        }

        let inset = detailOpenFilesSectionInset
        let titleSize = titleLayer.preferredFrameSize()
        let titleHeight = min(titleSize.height, max(height - inset * 2, 0))
        let titleWidth = max(width - inset * 2, 0)
        let titleY = max(height - inset - titleHeight, inset)
        titleLayer.frame = CGRect(x: inset,
                                  y: titleY,
                                  width: titleWidth,
                                  height: titleHeight)

        let viewportHeight = max(titleY - detailOpenFilesTitleSpacing - inset, 0)
        let viewportWidth = titleWidth
        if viewportHeight <= 0 || viewportWidth <= 0 {
            viewport.frame = .zero
            layoutDetailOpenFilesRows(force: true)
            return
        }

        viewport.frame = CGRect(x: inset,
                                y: inset,
                                width: viewportWidth,
                                height: viewportHeight)

        layoutDetailOpenFilesRows(force: true)
    }

    private func layoutDetailOpenFilesRows(force: Bool = false) {

        let viewport = layers.openFiles.viewportLayer
        let content = layers.openFiles.contentLayer

        let viewportWidth = viewport.bounds.width
        let viewportHeight = viewport.bounds.height
        let entries = detailOpenFileLines
        let lineHeight = detailOpenFilesRowHeight
        let contentHeight = CGFloat(entries.count) * lineHeight

        if viewportWidth <= 0 || viewportHeight <= 0 {
            detailOpenFilesVisibleRange = 0..<0
            for visual in layers.rowVisuals {
                visual.container.isHidden = true
            }
            content.frame = .zero
            updateDetailScrollbarLayout()
            return
        }

        let clampedOffset = clampScrollOffset(currentScrollOffset,
                                              contentHeight: contentHeight,
                                              viewportHeight: viewportHeight)
        if abs(clampedOffset - currentScrollOffset) > 0.5 {
            currentScrollOffset = clampedOffset
        }

        let appliedContentHeight = max(contentHeight, viewportHeight)
        let originY: CGFloat
        if contentHeight < viewportHeight {
            originY = 0
        } else {
            originY = viewportHeight + currentScrollOffset - contentHeight
        }
        content.frame = CGRect(x: 0,
                               y: originY,
                               width: viewportWidth,
                               height: appliedContentHeight)

        if entries.isEmpty {
            detailOpenFilesVisibleRange = 0..<0
            for visual in layers.rowVisuals {
                visual.container.isHidden = true
                visual.container.frame = .zero
            }
            updateDetailScrollbarLayout()
            return
        }

        let visibleEstimate = max(Int(ceil(viewportHeight / lineHeight)) + 1, 1)
        let lowerBound = max(Int(floor(currentScrollOffset / lineHeight)), 0)
        let upperBound = min(entries.count, lowerBound + visibleEstimate)
        let newRange = lowerBound..<upperBound
        if !force && newRange == detailOpenFilesVisibleRange {
            updateDetailScrollbarLayout()
            return
        }

        detailOpenFilesVisibleRange = newRange
        ensureDetailOpenFileVisualCapacity(newRange.count)
        let visuals = layers.rowVisuals

        for (index, visual) in visuals.enumerated() {
            if index < newRange.count {
                let entryIndex = newRange.lowerBound + index
                guard entryIndex < entries.count else {
                    visual.container.isHidden = true
                    visual.container.frame = .zero
                    continue
                }
                let y = CGFloat(entryIndex) * lineHeight
                visual.container.isHidden = false
                visual.container.frame = CGRect(x: 0,
                                                y: y,
                                                width: viewportWidth,
                                                height: lineHeight)
                let textWidth = max(viewportWidth - detailOpenFilesTextHorizontalInset * 2, 0)
                let textHeight = max(lineHeight - detailOpenFilesTextVerticalInset * 2, 0)
                visual.textLayer.frame = CGRect(x: detailOpenFilesTextHorizontalInset,
                                                y: detailOpenFilesTextVerticalInset,
                                                width: textWidth,
                                                height: textHeight)
                visual.textLayer.string = entries[entryIndex]
            } else {
                visual.container.isHidden = true
                visual.container.frame = .zero
            }
        }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateDetailOpenFilesTextColor(textColor: NSColor.textColor.cgColor, placeholderColor: NSColor.tertiaryLabelColor.cgColor)
        }
        updateDetailScrollbarLayout()
    }

    private func detailScrollbarMetrics() -> ScrollbarController<ProcessDetailContentController>.Metrics {
        let viewport = layers.openFiles.viewportLayer
        let contentHeight = CGFloat(detailOpenFileLines.count) * detailOpenFilesRowHeight
        return ScrollbarController.Metrics(viewportSize: viewport.bounds.size,
                                           contentHeight: contentHeight,
                                           scrollOffset: currentScrollOffset)
    }

    private func maxDetailScrollOffset() -> CGFloat {
        let contentHeight = CGFloat(detailOpenFileLines.count) * detailOpenFilesRowHeight
        return max(contentHeight - layers.openFiles.viewportLayer.bounds.height, 0)
    }

    private func setDetailScrollOffset(_ value: CGFloat, forceLayout: Bool = false) {
        let contentHeight = CGFloat(detailOpenFileLines.count) * detailOpenFilesRowHeight
        let clamped = clampScrollOffset(value,
                                        contentHeight: contentHeight,
                                        viewportHeight: layers.openFiles.viewportLayer.bounds.height)
        if !forceLayout && abs(clamped - currentScrollOffset) < 0.0001 {
            currentScrollOffset = clamped
            updateDetailScrollbarLayout()
            return
        }

        currentScrollOffset = clamped
        performWithoutAnimation {
            layoutDetailOpenFilesRows(force: true)
        }
    }

    @discardableResult
    private func scrollDetailOpenFiles(byAdjustedDeltaY deltaY: CGFloat) -> Bool {
        let maxOffset = maxDetailScrollOffset()
        if maxOffset <= 0.0001 { return false }
        let proposed = max(min(currentScrollOffset - deltaY, maxOffset), 0)
        if abs(proposed - currentScrollOffset) < 0.0001 { return false }
        setDetailScrollOffset(proposed)
        return true
    }

    private func updateDetailScrollbarLayout() {
        detailScrollbarController.updateLayout(metrics: detailScrollbarMetrics())
    }

    private func ensureDetailOpenFileVisualCapacity(_ capacity: Int) {

        let content = layers.openFiles.contentLayer
        while layers.rowVisuals.count < capacity {
            let container = CALayer()
            container.isGeometryFlipped = true
            container.backgroundColor = CGColor.clear

            let textLayer = makeTextLayer(font: detailOpenFilesFont,
                                          color: .black,
                                          alignment: .left)
            textLayer.truncationMode = .end
            textLayer.isWrapped = false
            container.addSublayer(textLayer)

            layers.rowVisuals.append(DetailOpenFileVisual(container: container, textLayer: textLayer))
            content.addSublayer(container)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateDetailOpenFilesTextColor(textColor: NSColor.textColor.cgColor, placeholderColor: NSColor.tertiaryLabelColor.cgColor)
        }
    }

    private func layoutDetailButtonBar(in container: CALayer) -> CGFloat {
        let buttonBar = layers.detail.buttonBarLayer
        let quit = layers.detail.quitButton

        let spacing = commandBarItemSpacing
        let buttons: [CommandBarButton] = [quit]
        var sizes: [CGSize] = []
        var totalWidth: CGFloat = 0
        for button in buttons {
            let size = preferredCommandBarButtonSize(button)
            sizes.append(size)
            totalWidth += size.width
        }
        totalWidth += spacing * CGFloat(max(buttons.count - 1, 0))

        let padding = detailContentHorizontalPadding
        let maxWidth = max(container.bounds.width - padding * 2, 0)
        let clampedWidth = min(totalWidth, maxWidth)
        let originX = max(padding, container.bounds.width - padding - clampedWidth)
        let originY = detailContentVerticalPadding
        buttonBar.frame = CGRect(x: originX,
                                 y: originY,
                                 width: clampedWidth,
                                 height: commandBarButtonHeight)
        buttonBar.isHidden = false

        var currentX: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            let desiredWidth = sizes[index].width
            let remaining = clampedWidth - currentX
            let minimalRemainingForOthers = spacing * CGFloat(max(buttons.count - index - 1, 0))
            let available = max(remaining - minimalRemainingForOthers, commandBarButtonHeight)
            let width = min(desiredWidth, max(min(available, remaining), commandBarButtonHeight))
            let frame = CGRect(x: currentX,
                               y: 0,
                               width: width,
                               height: commandBarButtonHeight)
            layoutCommandBarButton(button, frame: frame)
            currentX += width + spacing
        }

        return clampedWidth
    }

    private func preferredCommandBarButtonSize(_ button: CommandBarButton) -> CGSize {
        let textSize = button.textLayer.preferredFrameSize()
        let iconHidden = button.iconLayer.isHidden || button.iconLayer.contents == nil
        let iconWidth = iconHidden ? 0 : max(button.iconLayer.bounds.width, commandBarDefaultIconSize.width)
        let iconSpacing = iconHidden ? 0 : commandBarIconTextSpacing
        let width = commandBarButtonHorizontalPadding * 2 + iconWidth + iconSpacing + textSize.width
        return CGSize(width: max(width, commandBarButtonHeight), height: commandBarButtonHeight)
    }

    private func layoutCommandBarButton(_ button: CommandBarButton, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else {
            button.container.isHidden = true
            button.container.frame = .zero
            button.backgroundLayer.frame = .zero
            button.iconLayer.frame = .zero
            button.textLayer.frame = .zero
            return
        }
        button.container.isHidden = false
        button.container.frame = frame
        button.backgroundLayer.frame = CGRect(origin: .zero, size: frame.size)
        button.backgroundLayer.cornerRadius = frame.height / 2

        let iconHidden = button.iconLayer.isHidden || button.iconLayer.contents == nil
        let iconWidth = iconHidden ? 0 : max(button.iconLayer.bounds.width, commandBarDefaultIconSize.width)
        let iconHeight = iconHidden ? 0 : max(button.iconLayer.bounds.height, commandBarDefaultIconSize.height)
        let iconX = commandBarButtonHorizontalPadding
        let iconY = max((frame.height - iconHeight) / 2, 0)
        if iconWidth > 0 && iconHeight > 0 {
            button.iconLayer.frame = CGRect(x: iconX, y: iconY, width: iconWidth, height: iconHeight)
        } else {
            button.iconLayer.frame = CGRect(x: iconX, y: max((frame.height - commandBarDefaultIconSize.height) / 2, 0), width: 0, height: 0)
        }

        let textStart = iconWidth > 0 ? iconX + iconWidth + commandBarIconTextSpacing : commandBarButtonHorizontalPadding
        let availableWidth = max(frame.width - textStart - commandBarButtonHorizontalPadding, 0)
        let preferredSize = button.textLayer.preferredFrameSize()
        let textHeight = min(preferredSize.height, frame.height)
        let textY = max((frame.height - textHeight) / 2, 0)
        button.textLayer.frame = CGRect(x: textStart,
                                        y: textY,
                                        width: availableWidth,
                                        height: textHeight)
    }


    private func utf16Offset(forCharacterIndex index: Int, in text: String) -> Int {
        let clamped = max(0, min(index, text.count))
        let stringIndex = text.index(text.startIndex, offsetBy: clamped)
        return text[text.startIndex..<stringIndex].utf16.count
    }

    private func characterIndex(forUTF16 offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.utf16.count))
        let stringIndex = String.Index(utf16Offset: clamped, in: text)
        return text.distance(from: text.startIndex, to: stringIndex)
    }

    private func handleDetailButtonsMouseDown(at point: CGPoint,
                                              modifierFlags: NSEvent.ModifierFlags,
                                              clickCount: Int) -> Bool {
        let root = layers.rootLayer
        let buttonBar = layers.detail.buttonBarLayer

        let localPoint = buttonBar.convert(point, from: root)
        guard buttonBar.bounds.contains(localPoint) else { return false }

        let quit = layers.detail.quitButton
        if quit.container.frame.contains(localPoint) {
            handleDetailQuitTapped()
            return true
        }

        return false
    }

    private func handleDetailQuitTapped() {
        guard let entry = detailEntryForTermination() else { return }
        presentQuitConfirmation(for: entry)
    }

    private func presentQuitConfirmation(for entry: ProcessEntry) {

        let root = layers.rootLayer
        let alert = ensureQuitConfirmationAlert(attachingTo: root)
        updateQuitConfirmationContent(entry: entry, for: alert)
        updateQuitConfirmationColors(alert)
        alert.overlayLayer.isHidden = false
        performWithoutAnimation {
            alert.overlayLayer.opacity = 1.0
        }
        layoutQuitConfirmationAlert()
    }

    private func ensureQuitConfirmationAlert(attachingTo root: CALayer) -> QuitConfirmationAlert {
        if let alert = quitConfirmationAlert, alert.overlayLayer.superlayer === root {
            return alert
        }
        let alert = createQuitConfirmationAlert(attachingTo: root)
        quitConfirmationAlert = alert
        return alert
    }

    private func createQuitConfirmationAlert(attachingTo root: CALayer) -> QuitConfirmationAlert {
        let overlay = CALayer()
        overlay.frame = root.bounds
        overlay.backgroundColor = CGColor.clear
        overlay.opacity = 0
        overlay.isHidden = true
        overlay.zPosition = 2000
        root.addSublayer(overlay)

        let panel = CALayer()
        panel.isGeometryFlipped = true
        panel.backgroundColor = CGColor.clear
        panel.cornerRadius = alertPanelCornerRadius
        panel.masksToBounds = false
        panel.borderColor = CGColor.clear
        panel.borderWidth = 1
        panel.shadowColor = CGColor.clear
        panel.shadowOpacity = 0.18
        panel.shadowRadius = 16
        panel.shadowOffset = CGSize(width: 0, height: 2)
        overlay.addSublayer(panel)

        let titleLayer = makeTextLayer(font: alertTitleFont, color: .black, alignment: .left)
        titleLayer.alignmentMode = .left
        panel.addSublayer(titleLayer)

        let messageLayer = makeTextLayer(font: alertMessageFont, color: .black, alignment: .left)
        messageLayer.alignmentMode = .left
        messageLayer.isWrapped = true
        messageLayer.truncationMode = .none
        panel.addSublayer(messageLayer)

        let definitions: [(QuitAlertAction, String)] = [
            (.cancel, "Cancel"),
            (.forceQuit, "Force Quit"),
            (.quit, "Quit")
        ]
        var buttons: [QuitAlertButton] = []
        for (action, title) in definitions {
            let container = CALayer()
            container.isGeometryFlipped = true
            panel.addSublayer(container)

            let background = CALayer()
            background.cornerRadius = alertButtonHeight / 2
            background.masksToBounds = true
            background.borderWidth = 1
            container.addSublayer(background)

            let textLayer = makeTextLayer(font: alertButtonFont, color: .black, alignment: .center)
            textLayer.alignmentMode = .center
            textLayer.string = title
            container.addSublayer(textLayer)

            buttons.append(QuitAlertButton(container: container,
                                           backgroundLayer: background,
                                           textLayer: textLayer,
                                           action: action))
        }

        let alert = QuitConfirmationAlert(overlayLayer: overlay,
                                          panelLayer: panel,
                                          titleLayer: titleLayer,
                                          messageLayer: messageLayer,
                                          buttons: buttons)
        return alert
    }

    private func updateQuitConfirmationContent(entry: ProcessEntry,
                                               for alert: QuitConfirmationAlert) {
        alert.pid = entry.pid
        alert.command = entry.command
        alert.titleLayer.string = "Are you sure you want to quit this process?"
        alert.messageLayer.string = "Do you really want to quit \"\(entry.command)\"?"
        for button in alert.buttons {
            switch button.action {
            case .cancel:
                button.textLayer.string = "Cancel"
            case .forceQuit:
                button.textLayer.string = "Force Quit"
            case .quit:
                button.textLayer.string = "Quit"
            }
        }
    }

    private func updateQuitConfirmationColors() {
        guard let alert = quitConfirmationAlert else { return }
        updateQuitConfirmationColors(alert)
    }

    private func updateQuitConfirmationColors(_ alert: QuitConfirmationAlert) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor

            alert.overlayLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.25).cgColor
            alert.panelLayer.backgroundColor = NSColor.white.cgColor
            alert.panelLayer.borderColor = NSColor(calibratedWhite: 0.0, alpha: 0.2).cgColor
            alert.panelLayer.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.5).cgColor
            alert.titleLayer.foregroundColor = label.cgColor
            alert.messageLayer.foregroundColor = NSColor(calibratedWhite: 0.25, alpha: 1.0).cgColor

            for button in alert.buttons {
                let isPrimary = button.action == .quit
                button.backgroundLayer.backgroundColor = isPrimary ? activeSelectionBackgroundColor.cgColor : NSColor(calibratedWhite: 0.87, alpha: 1.0).cgColor
                button.backgroundLayer.borderColor = isPrimary ? activeSelectionBackgroundColor.cgColor : NSColor(calibratedWhite: 0.0, alpha: 0.15).cgColor
                button.backgroundLayer.borderWidth = isPrimary ? 0 : 1
                button.textLayer.foregroundColor = (isPrimary ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1.0)).cgColor
            }
        }
    }

    private func layoutQuitConfirmationAlert() {
        guard let alert = quitConfirmationAlert else { return }

        let root = layers.rootLayer

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let bounds = root.bounds
        alert.overlayLayer.frame = bounds

        guard !alert.overlayLayer.isHidden else {
            CATransaction.commit()
            return
        }

        var buttonMetrics: [(QuitAlertButton, CGSize, CGFloat)] = []
        var totalButtonsWidth: CGFloat = 0
        for button in alert.buttons {
            let textSize = button.textLayer.preferredFrameSize()
            let width = max(textSize.width + alertButtonHorizontalPadding * 2, 96)
            buttonMetrics.append((button, textSize, width))
            totalButtonsWidth += width
        }
        let totalSpacing = CGFloat(max(alert.buttons.count - 1, 0)) * alertButtonSpacing
        let minimumPanelWidth = totalButtonsWidth + totalSpacing + alertPanelHorizontalPadding * 2
        let widthCap: CGFloat = 520
        let availableWidth = max(bounds.width - 40, minimumPanelWidth)
        let panelWidth = max(min(max(availableWidth, minimumPanelWidth), widthCap), minimumPanelWidth)
        let contentWidth = max(0, panelWidth - alertPanelHorizontalPadding * 2)

        let titleSize = alert.titleLayer.preferredFrameSize()
        let messageString: String
        if let string = alert.messageLayer.string as? String {
            messageString = string
        } else if let attributed = alert.messageLayer.string as? NSAttributedString {
            messageString = attributed.string
        } else {
            messageString = ""
        }
        let messageSize = boundingSize(for: messageString, font: alertMessageFont, width: contentWidth)

        let titleMessageSpacing: CGFloat = 8
        let buttonsTopSpacing: CGFloat = 20
        let buttonsY = alertPanelVerticalPadding + titleSize.height + titleMessageSpacing + messageSize.height + buttonsTopSpacing

        var layouts: [(QuitAlertButton, CGRect, CGSize)] = []
        var currentX = panelWidth - alertPanelHorizontalPadding
        let reversedMetrics = buttonMetrics.reversed()
        for (index, metric) in reversedMetrics.enumerated() {
            let button = metric.0
            let textSize = metric.1
            let buttonWidth = metric.2
            currentX -= buttonWidth
            let frame = CGRect(x: currentX,
                               y: buttonsY,
                               width: buttonWidth,
                               height: alertButtonHeight)
            layouts.append((button, frame, textSize))
            if index < buttonMetrics.count - 1 {
                currentX -= alertButtonSpacing
            }
        }

        let panelHeight = buttonsY + alertButtonHeight + alertPanelVerticalPadding
        let panelSize = CGSize(width: panelWidth, height: panelHeight)
        let panelOrigin = CGPoint(x: max((bounds.width - panelSize.width) / 2, 0),
                                  y: max((bounds.height - panelSize.height) / 2, 0))
        alert.panelLayer.frame = CGRect(origin: panelOrigin, size: panelSize)

        alert.titleLayer.frame = CGRect(x: alertPanelHorizontalPadding,
                                        y: alertPanelVerticalPadding,
                                        width: contentWidth,
                                        height: titleSize.height)

        alert.messageLayer.frame = CGRect(x: alertPanelHorizontalPadding,
                                          y: alertPanelVerticalPadding + titleSize.height + titleMessageSpacing,
                                          width: contentWidth,
                                          height: messageSize.height)

        for (button, frame, textSize) in layouts {
            button.container.frame = frame
            button.backgroundLayer.frame = button.container.bounds
            button.backgroundLayer.cornerRadius = alertButtonHeight / 2
            let textHeight = min(textSize.height, frame.height)
            let textY = max((frame.height - textHeight) / 2, 0)
            button.textLayer.frame = CGRect(x: 0,
                                            y: textY,
                                            width: frame.width,
                                            height: textHeight)
        }

        CATransaction.commit()
    }

    private func dismissQuitConfirmation() {
        guard let alert = quitConfirmationAlert else { return }
        performWithoutAnimation {
            alert.overlayLayer.opacity = 0
            alert.overlayLayer.isHidden = true
        }
    }

    private func handleAlertMouseDown(at point: CGPoint) -> Bool {
        guard let alert = quitConfirmationAlert,
              !alert.overlayLayer.isHidden else { return false }

        let root = layers.rootLayer

        let pointInOverlay = alert.overlayLayer.convert(point, from: root)
        if !alert.overlayLayer.bounds.contains(pointInOverlay) {
            return false
        }

        for button in alert.buttons {
            let localPoint = button.container.convert(point, from: root)
            if button.container.bounds.contains(localPoint) {
                handleQuitAlertAction(button.action)
                return true
            }
        }

        let pointInPanel = alert.panelLayer.convert(point, from: root)
        if alert.panelLayer.bounds.contains(pointInPanel) {
            return true
        }

        dismissQuitConfirmation()
        return true
    }

    private func handleQuitAlertAction(_ action: QuitAlertAction) {
        guard let alert = quitConfirmationAlert else { return }
        switch action {
        case .cancel:
            dismissQuitConfirmation()
        case .quit, .forceQuit:
            dismissQuitConfirmation()
            let pid = alert.pid
            let command = alert.command
            sendTerminationRequest(pid: pid, command: command, force: action == .forceQuit)
        }
    }

    private func sendTerminationRequest(pid: Int, command: String, force: Bool) {
        guard pid > 0 else { return }
        guard let endpoint = apiEndpoint else {
            showStatus("Unable to contact process server.")
            return
        }

        let actionPath = force ? "force-quit" : "quit"
        let requestURL = endpoint
            .appending(path: actionPath)
            .appending(queryItems: [URLQueryItem(name: "pid", value: String(pid))])
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"

        performSingleRequest(request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                self?.handleTerminationResponse(data: data,
                                                response: response as? HTTPURLResponse,
                                                error: error,
                                                pid: pid,
                                                command: command,
                                                force: force)
            }
        }
    }

    private func handleTerminationResponse(data: Data?,
                                           response: HTTPURLResponse?,
                                           error: Error?,
                                           pid: Int,
                                           command: String,
                                           force: Bool) {
        let actionName = force ? "force quit" : "quit"
        if let error = error {
            showStatus("Failed to \(actionName) \(terminationDisplayName(pid: pid, command: command)): \(error.localizedDescription)")
            return
        }

        guard let response else {
            showStatus("Failed to \(actionName) \(terminationDisplayName(pid: pid, command: command)).")
            return
        }

        if !(200...299).contains(response.statusCode) {
            let description = terminationErrorDescription(data: data, response: response)
            showStatus("Failed to \(actionName) \(terminationDisplayName(pid: pid, command: command)): \(description)")
            return
        }

        if let data, !data.isEmpty,
           let decoded = try? JSONDecoder().decode(TerminationServerResponse.self, from: data),
           !decoded.success {
            let detail = decoded.error?.isEmpty == false ? decoded.error! : "Unknown error"
            showStatus("Failed to \(actionName) \(terminationDisplayName(pid: pid, command: command)): \(detail)")
            return
        }

        showStatus(nil)
    }

    private func terminationDisplayName(pid: Int, command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "PID \(pid)"
        }
        return "\(trimmed) (\(pid))"
    }

    private func terminationErrorDescription(data: Data?, response: HTTPURLResponse) -> String {
        if let data,
           let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return body
        }
        return HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    }

    private func clampScrollOffset(_ offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return max(0, offset) }
        let maxOffset = max(contentHeight - viewportHeight, 0)
        if maxOffset <= 0 {
            return 0
        }
        return min(max(offset, 0), maxOffset)
    }

    private func updateMetaText() {}

    private func showStatus(_ message: String?) {
        performWithoutAnimation {
            if let message = message {
                layers.statusLayer.string = message
                layers.statusLayer.isHidden = false
            } else {
                layers.statusLayer.string = ""
                layers.statusLayer.isHidden = true
            }
        }
    }

    private func formattedCpuTime(_ milliseconds: Int) -> String {
        if milliseconds <= 0 {
            return "0:00"
        }

        let totalSeconds = max(milliseconds / 1000, 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var buffer = [CChar](repeating: 0, count: 24)
        var index = 0

        if hours > 0 {
            index += Int(fastItoa64(Int64(hours), &buffer[index], buffer.count - index))
            buffer[index] = 58
            index += 1
            buffer[index] = CChar(48 + minutes / 10)
            index += 1
            buffer[index] = CChar(48 + minutes % 10)
            index += 1
        } else {
            index += Int(fastItoa64(Int64(minutes), &buffer[index], buffer.count - index))
        }

        buffer[index] = 58
        index += 1
        buffer[index] = CChar(48 + seconds / 10)
        index += 1
        buffer[index] = CChar(48 + seconds % 10)
        index += 1

        return buffer.withUnsafeBufferPointer { pointer -> String in
            guard let base = pointer.baseAddress else { return "0:00" }
            let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: index)
            return String(decoding: raw, as: UTF8.self)
        }
    }

    private func formattedSingleDecimal(_ value: Double) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        let length = Int(formatNumberSingleDecimalFast(Float(value), &buffer, buffer.count))
        if length <= 0 {
            return "0.0"
        }
        return buffer.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress else { return "0.0" }
            let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: length)
            return String(decoding: raw, as: UTF8.self)
        }
    }

    private func formattedMemory(kilobytes value: Int, isKernelThread: Bool) -> String {
        if isKernelThread {
            return "kernel"
        }
        let clampedValue = max(value, 0)
        let kilobytes = Double(clampedValue)
        let kilobytesPerMegabyte = 1024.0
        let kilobytesPerGigabyte = kilobytesPerMegabyte * 1024.0

        let unit: String
        let displayValue: Double
        let fractionalDigits: Int

        if kilobytes >= kilobytesPerGigabyte {
            unit = "GB"
            displayValue = kilobytes / kilobytesPerGigabyte
            fractionalDigits = 2
        } else if kilobytes >= kilobytesPerMegabyte {
            unit = "MB"
            displayValue = kilobytes / kilobytesPerMegabyte
            fractionalDigits = 1
        } else {
            unit = "KB"
            displayValue = kilobytes
            fractionalDigits = 0
        }

        var buffer = [CChar](repeating: 0, count: 64)
        let length = Int(formatNumberWithFractionDigitsFast(displayValue, Int32(fractionalDigits), &buffer, buffer.count))
        let suffix = " \(unit)"
        if length <= 0 {
            return "0" + suffix
        }
        return buffer.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress else {
                return "0" + suffix
            }
            let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: length)
            let valueString = String(decoding: raw, as: UTF8.self)
            return valueString + suffix
        }
    }

    private func formattedInteger(_ value: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        let length = Int(fastItoa64(Int64(value), &buffer, buffer.count))
        if length <= 0 {
            return "0"
        }
        return buffer.withUnsafeBufferPointer { ptr -> String in
            guard let base = ptr.baseAddress else { return "0" }
            let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: length)
            return String(decoding: raw, as: UTF8.self)
        }
    }

    private func formattedDetailOpenFileLine(_ entry: DetailOpenFileEntry) -> String {
        let descriptor = paddedColumn(entry.descriptor, width: detailOpenFilesDescriptorColumnWidth)
        let type = paddedColumn(entry.type, width: detailOpenFilesTypeColumnWidth)
        if entry.type.isEmpty {
            return "\(descriptor)  \(entry.name)"
        }
        return "\(descriptor)  \(type)  \(entry.name)"
    }

    private func paddedColumn(_ value: String, width: Int) -> String {
        guard width > 0 else { return value }
        let count = value.count
        if count >= width {
            return value
        }
        let padding = String(repeating: " ", count: width - count)
        return value + padding
    }

    private func updateDetailOpenFilesTextColor(textColor: CGColor, placeholderColor: CGColor) {
        let color = detailOpenFilesHasRealEntries ? textColor : placeholderColor
        for visual in layers.rowVisuals {
            visual.textLayer.foregroundColor = color
        }
    }

    private func boundingSize(for text: String, font: NSFont, width: CGFloat) -> CGSize {
        guard width.isFinite, width > 0 else { return .zero }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let maxSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let rect = attributed.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    private func performWithoutAnimation(_ block: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block()
        CATransaction.commit()
    }
}

private func readUInt8(from data: Data, offset: Int) -> UInt8? {
    guard offset < data.count else { return nil }
    return data[offset]
}

private func readUInt32LE(from data: Data, offset: Int) -> UInt32? {
    guard offset + MemoryLayout<UInt32>.size <= data.count else { return nil }
    var value: UInt32 = 0
    _ = data.withUnsafeBytes { buffer in
        memcpy(&value, buffer.baseAddress!.advanced(by: offset), MemoryLayout<UInt32>.size)
    }
    return UInt32(littleEndian: value)
}

private func readUInt64LE(from data: Data, offset: Int) -> UInt64? {
    guard offset + MemoryLayout<UInt64>.size <= data.count else { return nil }
    var value: UInt64 = 0
    _ = data.withUnsafeBytes { buffer in
        memcpy(&value, buffer.baseAddress!.advanced(by: offset), MemoryLayout<UInt64>.size)
    }
    return UInt64(littleEndian: value)
}

private func readFloatLE(from data: Data, offset: Int) -> Float? {
    guard let bits: UInt32 = readUInt32LE(from: data, offset: offset) else { return nil }
    return Float(bitPattern: bits)
}

private func makeCGImageFromPNGData(_ data: Data) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(pngDataProviderSource: provider,
                   decode: nil,
                   shouldInterpolate: true,
                   intent: .defaultIntent)
}

private func readDoubleLE(from data: Data, offset: Int) -> Double? {
    guard let bits: UInt64 = readUInt64LE(from: data, offset: offset) else { return nil }
    return Double(bitPattern: bits)
}

private func stringFromData(_ data: Data, offset: Int, length: Int) -> String? {
    guard length >= 0, offset >= 0, offset + length <= data.count else { return nil }
    if length == 0 { return "" }
    return data.withUnsafeBytes { rawBuffer -> String? in
        guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let pointer = base.advanced(by: offset)
        let buffer = UnsafeBufferPointer(start: pointer, count: length)
        return String(decoding: buffer, as: UTF8.self)
    }
}

private struct GlyphInfo {
    let image: CGImage
    let size: CGSize
}

private final class NumericGlyphCache {
    private let font: NSFont
    private var color: NSColor
    private weak var appearance: NSAppearance?
    let contentsScale: CGFloat
    private var cache: [Character: GlyphInfo] = [:]

    init(font: NSFont, color: NSColor, appearance: NSAppearance, contentsScale: CGFloat) {
        self.font = font
        self.color = color
        self.appearance = appearance
        self.contentsScale = contentsScale
    }

    func glyph(for character: Character) -> GlyphInfo? {
        if let glyph = cache[character] {
            return glyph
        }
        guard let created = createGlyph(for: character) else { return nil }
        cache[character] = created
        return created
    }

    func updateColor(_ color: NSColor, appearance: NSAppearance) {
        self.color = color
        self.appearance = appearance
        cache.removeAll(keepingCapacity: false)
    }

    private func createGlyph(for character: Character) -> GlyphInfo? {
        let string = String(character)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        var size = attributed.size()
        size.width = ceil(max(size.width, 1))
        size.height = ceil(max(size.height, 1))

        var cgColor: CGColor!
        if let appearance = appearance {
            appearance.performAsCurrentDrawingAppearance {
                cgColor = color.cgColor
            }
        } else {
            cgColor = color.cgColor
        }

        let layer = CATextLayer()
        layer.contentsScale = contentsScale
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = cgColor
        layer.string = string
        layer.alignmentMode = .left
        layer.anchorPoint = CGPoint(x: 0, y: 0)
        layer.frame = CGRect(origin: .zero, size: size)

        let pixelWidth = Int(size.width * contentsScale)
        let pixelHeight = Int(size.height * contentsScale)

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.scaleBy(x: contentsScale, y: contentsScale)
        layer.render(in: context)

        guard let image = context.makeImage() else { return nil }
        return GlyphInfo(image: image, size: size)
    }
}

private final class CommandImageCache {
    private let font: NSFont
    private var color: NSColor
    private weak var appearance: NSAppearance?
    let contentsScale: CGFloat
    private var cache: [String: GlyphInfo] = [:]

    init(font: NSFont, color: NSColor, appearance: NSAppearance, contentsScale: CGFloat) {
        self.font = font
        self.color = color
        self.appearance = appearance
        self.contentsScale = contentsScale
    }

    func image(for string: String) -> GlyphInfo? {
        if let glyph = cache[string] {
            return glyph
        }
        guard !string.isEmpty else {
            let empty = GlyphInfo(image: transparentPixel(), size: .zero)
            cache[string] = empty
            return empty
        }
        guard let created = createImage(for: string) else { return nil }
        cache[string] = created
        return created
    }

    func updateColor(_ color: NSColor, appearance: NSAppearance) {
        self.color = color
        self.appearance = appearance
        cache.removeAll(keepingCapacity: false)
    }

    private func createImage(for string: String) -> GlyphInfo? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        var size = attributed.size()
        size.width = ceil(max(size.width, 1))
        size.height = ceil(max(size.height, 1))

        var cgColor: CGColor!
        if let appearance = appearance {
            appearance.performAsCurrentDrawingAppearance {
                cgColor = color.cgColor
            }
        } else {
            cgColor = color.cgColor
        }

        let textLayer = CATextLayer()
        textLayer.contentsScale = contentsScale
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = cgColor
        textLayer.alignmentMode = .left
        textLayer.anchorPoint = CGPoint(x: 0, y: 0)
        textLayer.string = string
        textLayer.frame = CGRect(origin: .zero, size: size)

        let pixelWidth = Int(size.width * contentsScale)
        let pixelHeight = Int(size.height * contentsScale)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return GlyphInfo(image: transparentPixel(), size: .zero)
        }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.scaleBy(x: contentsScale, y: contentsScale)
        textLayer.render(in: context)

        guard let image = context.makeImage() else { return nil }
        return GlyphInfo(image: image, size: size)
    }

    private func transparentPixel() -> CGImage {
        let pixel = [UInt8](repeating: 0, count: 4)
        let data = CFDataCreate(nil, pixel, 4)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private final class NumericCellRenderer {
    let layer: CALayer
    private var glyphLayers: [CALayer] = []
    private var glyphSizes: [CGSize] = []
    private var currentString: String = ""
    private let alignment: CATextLayerAlignmentMode
    private let normalCache: NumericGlyphCache
    private let selectedCache: NumericGlyphCache
    private var currentCache: NumericGlyphCache
    private var isSelected = false
    private var needsLayout = false

    init(alignment: CATextLayerAlignmentMode, normalCache: NumericGlyphCache, selectedCache: NumericGlyphCache) {
        self.alignment = alignment
        self.normalCache = normalCache
        self.selectedCache = selectedCache
        self.currentCache = normalCache
        self.layer = CALayer()
        self.layer.masksToBounds = true
        self.layer.contentsScale = normalCache.contentsScale
        self.layer.isGeometryFlipped = true
    }

    func update(with string: String) {
        if currentString == string { return }
        currentString = string

        ensureGlyphLayers(count: string.count)
        glyphSizes.removeAll(keepingCapacity: true)

        var index = 0
        for character in string {
            guard index < glyphLayers.count else { break }
            let glyphLayer = glyphLayers[index]
            if let glyph = currentCache.glyph(for: character) {
                glyphLayer.contents = glyph.image
                glyphLayer.isHidden = false
                glyphLayer.bounds = CGRect(origin: .zero, size: glyph.size)
                glyphSizes.append(glyph.size)
            } else {
                glyphLayer.isHidden = true
                glyphSizes.append(.zero)
            }
            index += 1
        }

        if index < glyphLayers.count {
            for i in index..<glyphLayers.count {
                glyphLayers[i].isHidden = true
            }
        }

        needsLayout = true
    }

    func setFrame(_ frame: CGRect) {
        if layer.bounds.size != frame.size {
            needsLayout = true
        }
        layer.frame = frame
        layoutGlyphsIfNeeded()
    }

    func setSelected(_ selected: Bool) {
        if selected == isSelected { return }
        isSelected = selected
        currentCache = selected ? selectedCache : normalCache
        updateGlyphLayerScales()
        refreshAppearance()
    }

    func refreshAppearance() {
        let string = currentString
        currentString = ""
        update(with: string)
        needsLayout = true
        updateGlyphLayerScales()
        setFrame(layer.frame)
    }

    private func ensureGlyphLayers(count: Int) {
        if glyphLayers.count >= count { return }
        let additional = count - glyphLayers.count
        for _ in 0..<additional {
            let glyphLayer = CALayer()
            glyphLayer.contentsScale = currentCache.contentsScale
            glyphLayer.isGeometryFlipped = true
            glyphLayer.isHidden = true
            layer.addSublayer(glyphLayer)
            glyphLayers.append(glyphLayer)
        }
    }

    private func layoutGlyphsIfNeeded() {
        guard needsLayout else { return }

        let bounds = layer.bounds
        guard !bounds.isEmpty else { return }

        let activeCount = min(glyphSizes.count, glyphLayers.count)
        guard activeCount > 0 else {
            needsLayout = false
            return
        }

        needsLayout = false

        let totalWidth = glyphSizes.prefix(activeCount).reduce(0) { $0 + $1.width }
        let startX: CGFloat
        switch alignment {
        case .right:
            startX = max(bounds.width - totalWidth, 0)
        case .center:
            startX = max((bounds.width - totalWidth) / 2, 0)
        default:
            startX = 0
        }

        var currentX = startX
        for index in 0..<activeCount {
            let glyphLayer = glyphLayers[index]
            if glyphLayer.isHidden { continue }
            let glyphSize = glyphSizes[index]
            let originY = max((bounds.height - glyphSize.height) / 2, 0)
            glyphLayer.frame = CGRect(x: currentX, y: originY, width: glyphSize.width, height: glyphSize.height)
            currentX += glyphSize.width
        }
    }

    private func updateGlyphLayerScales() {
        let scale = currentCache.contentsScale
        layer.contentsScale = scale
        for glyphLayer in glyphLayers {
            glyphLayer.contentsScale = scale
        }
    }
}

private enum QuitAlertAction {
    case quit
    case forceQuit
    case cancel
}

private struct QuitAlertButton {
    let container: CALayer
    let backgroundLayer: CALayer
    let textLayer: CATextLayer
    let action: QuitAlertAction
}

private final class QuitConfirmationAlert {
    let overlayLayer: CALayer
    let panelLayer: CALayer
    let titleLayer: CATextLayer
    let messageLayer: CATextLayer
    let buttons: [QuitAlertButton]
    var pid: Int = 0
    var command: String = ""

    init(overlayLayer: CALayer,
         panelLayer: CALayer,
         titleLayer: CATextLayer,
         messageLayer: CATextLayer,
         buttons: [QuitAlertButton]) {
        self.overlayLayer = overlayLayer
        self.panelLayer = panelLayer
        self.titleLayer = titleLayer
        self.messageLayer = messageLayer
        self.buttons = buttons
    }
}

private struct CommandBarButton {
    let container: CALayer
    let backgroundLayer: CALayer
    let iconLayer: CALayer
    let textLayer: CATextLayer
    let symbolName: String
}


private final class ProcessStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: ProcessDetailContentController?

    init(owner: ProcessDetailContentController) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let owner = owner else {
            completionHandler(.cancel)
            return
        }

        Task { @MainActor [weak owner] in
            guard let owner = owner else {
                completionHandler(.cancel)
                return
            }
            let disposition = owner.handleStreamResponse(response, for: dataTask)
            completionHandler(disposition)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let owner = owner else { return }
        Task { @MainActor [weak owner] in
            guard let owner = owner else { return }
            owner.handleStreamData(data, for: dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let owner = owner else { return }
        Task { @MainActor [weak owner] in
            guard let owner = owner else { return }
            owner.handleStreamCompletion(error, for: task)
        }
    }
}

private extension NSColor {
    var am_brightness: CGFloat {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3.0
    }

    func am_withAlpha(_ alpha: CGFloat) -> NSColor {
        withAlphaComponent(alpha)
    }

    func am_blended(withFraction fraction: CGFloat, toward other: NSColor) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }
}
// MARK: - OuterframeHostDelegate

extension ProcessDetailContentController: OuterframeHostDelegate {
    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage) {
        switch message {
        case .initializeContent:
            // Already handled during start, ignore if received again
            break

        case .resizeContent(let size):
            resize(width: Int(size.width), height: Int(size.height))

        case .mouseMoved:
            break

        case .mouseDown(let point, let modifierFlags, let clickCount):
            mouseDown(at: point, modifierFlags: modifierFlags, clickCount: clickCount)

        case .mouseUp(let point, let modifierFlags):
            mouseUp(at: point, modifierFlags: modifierFlags)

        case .mouseDragged(let point, let modifierFlags):
            mouseDragged(to: point, modifierFlags: modifierFlags)

        case .rightMouseDown, .rightMouseUp:
            break

        case .scrollWheelEvent(let point, let delta, let modifierFlags, let phase, let momentumPhase, let hasPreciseScrollingDeltas):
            scrollWheel(delta: delta,
                        at: point,
                        modifierFlags: modifierFlags,
                        phase: phase,
                        momentumPhase: momentumPhase,
                        hasPreciseScrollingDeltas: hasPreciseScrollingDeltas)

        case .keyDown, .keyUp:
            break

        case .systemAppearanceUpdate(let appearance):
            effectiveAppearance = appearance
            appearanceDidChange()

        case .viewFocusChanged:
            break

        case .magnification, .magnificationEnded, .quickLook:
            break

        case .textInput, .setMarkedText, .unmarkText, .textInputFocus, .textCommand, .setCursorPosition:
            break

        case .windowActiveUpdate(let isActive):
            setWindowActive(isActive)

        case .copySelectedPasteboardRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: [])

        case .pasteboardContentDelivered:
            break

        case .shutdown:
            print("Top: Received shutdown message, cleaning up...")
            cleanup()
            retainedSelf = nil
            exit(0)

        default:
            break
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
        cleanup()
        retainedSelf = nil
    }

    func outerframeHostAccessibilitySnapshot(_ host: OuterframeHost) -> OuterframeAccessibilitySnapshot? {
        accessibilitySnapshot()
    }
}

extension ProcessDetailContentController: ScrollbarControllerDelegate {
    func scrollbarDidChangeScrollOffset(_ offset: CGFloat) {
        setDetailScrollOffset(offset)
    }
}
