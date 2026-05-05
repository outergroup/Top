import AppKit
import CoreText
import Foundation
import QuartzCore

private let API_MISMATCH: Int32 = -35

@MainActor
class ProcessMonitorListContentController: NSObject, TopContentController, @MainActor SingleLineTextInputControllerDelegate {

    private struct Layers {
        let rootLayer: CALayer
        let statusLayer: CATextLayer
        var system: SystemMetricsLayers
        let tableContainerLayer: CALayer
        let commandBarLayer: CALayer
        let stopButton: CommandBarButton
        let inspectButton: CommandBarButton
        let searchField: CommandBarSearchField
    }

    private var layers: Layers?

    private var currentSize: CGSize = .zero
    private var appletOriginURL: URL?
    private var appletBaseURL: URL?
    private var appletOuterURL: URL?
    private var apiEndpoint: URL?
    private var pollInterval: TimeInterval = 2.0


    private var latestSnapshotTimestamp: TimeInterval = 0

    private let model: ProcessMonitorListModel
    private var viewHasFocus: Bool = true
    private var urlSession: URLSession?
    private lazy var urlSessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ProcessMonitorStreamQueue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var streamTask: URLSessionDataTask?

    private let defaultViewportLength = 40

    private static let defaultTimeWindowDuration: TimeInterval = 60

    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var maintainStream = false
    private var streamGeneration: Int = 0
    private var currentStreamGeneration: Int = 0
    private let clientIdentifier = UUID().uuidString
    private var lastMetricsSnapshotIndex: UInt64 = 0

    private var historicalRequestInFlight = false
    private var pendingHistoricalRange: ClosedRange<TimeInterval>?
    private var historicalRequestCounter: Int = 0
    private var activeHistoricalRequestID: Int = 0

    // Socket-based browser communication
    let outerframeHost: OuterframeHost

    // Self-reference to prevent deallocation while socket is open
    private var retainedSelf: ProcessMonitorListContentController?

    private var quitDialog: ProcessQuitDialog?
    private var cpuChart: CPUHistoryChart?
    private var processTable: ProcessTable?

    private var lastSentViewportState: ProcessMonitorListModel.ViewportState?
    private var pendingViewportAnnouncementTask: Task<Void, Never>?
    private var cachedSelectionQueryItems: (selection: CPUHistoryChart.Selection, items: [URLQueryItem])?

    private var currentStatusText: String? = nil

    private var currentSnapshotIndex: UInt64 = 0

    private static let viewportAnnouncementDelayNanoseconds: UInt64 = 16_000_000
    private static let selectionValueLocale = Locale(identifier: "en_US_POSIX")

    init?(outerframeHost: OuterframeHost, appearance: NSAppearance, windowIsActive: Bool, with data: Data, size: CGSize, appConnection hostAppConnection: OuterframeAppConnection) {
        self.searchFieldInputController = .init(identifier: Self.searchFieldID)
        self.model = ProcessMonitorListModel(appearance: appearance)

        model.selection = .range(range: .moving(ago: Self.defaultTimeWindowDuration))
        model.isWindowActive = windowIsActive

        lastMetricsSnapshotIndex = 0
        lastSentViewportState = nil
        model.logicalCpuCount = 1

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = CGColor.clear
        root.cornerRadius = 0

        guard let registerLayer = hostAppConnection.registerLayer else {
            return nil
        }
        registerLayer(root)

        self.outerframeHost = outerframeHost

        super.init()
        searchFieldInputController.delegate = self
        // Note: socket.delegate is set by TopInitHandler after init returns

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Set up URLs
        if let url = outerframeHost.pluginURL() {
            appletOuterURL = url
            appletBaseURL = outerframeHost.pluginBaseURL()
            appletOriginURL = outerframeHost.pluginOriginURL()

            if let base = appletBaseURL {
                let relativeToBase = URL(string: "/api/processes", relativeTo: base)!
                apiEndpoint = relativeToBase.absoluteURL
            }
        }

        currentSize = size
        searchFieldInputController.delegate = self

        startProcessStream()

        updateEditingCapabilities()

        model.effectiveAppearance.performAsCurrentDrawingAppearance {

            let status = makeTextLayer(font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                       color: .black,
                                       alignment: .left)
            status.alignmentMode = .left
            status.zPosition = 10
            status.isHidden = true
            root.addSublayer(status)

            //
            // TABLE CONTAINER
            //

            let tableContainer = CALayer()
            tableContainer.backgroundColor = CGColor.clear
            tableContainer.cornerRadius = 0
            tableContainer.shadowOpacity = 0
            root.addSublayer(tableContainer)

            //
            // COMMAND BAR (direct sublayer of root for easy toolbar positioning)
            //

            let commandBar = CALayer()
            commandBar.backgroundColor = CGColor.clear
            root.addSublayer(commandBar)

            let stop = makeCommandBarButton(title: "Stop", symbolName: "xmark.circle")
            commandBar.addSublayer(stop.container)

            let inspect = makeCommandBarButton(title: "Inspect", symbolName: "info.circle")
            commandBar.addSublayer(inspect.container)

            let search = makeSearchField(symbolName: "magnifyingglass", placeholder: "Search")
            commandBar.addSublayer(search.container)

            //
            // SYSTEM METRICS
            //
            let metrics = CALayer()
            metrics.backgroundColor = CGColor.clear
            root.addSublayer(metrics)

            let divider = CALayer()
            divider.backgroundColor = CGColor.clear
            metrics.addSublayer(divider)

            let cpuStatsSection = CPUStatsSection(
                appConnection: appConnection,
                model: model,
                mainController: self,
                hostLayer: metrics,
                titleFont: cpuTitleFont,
                labelFont: cpuStatsLabelFont,
                valueFont: cpuStatsValueFont,
                rowSpacing: cpuStatsRowSpacing)

            let cpuChartSection = CALayer()
            cpuChartSection.isGeometryFlipped = true
            metrics.addSublayer(cpuChartSection)

            let cpuChartHost = CALayer()
            cpuChartHost.isGeometryFlipped = true
            cpuChartHost.masksToBounds = false
            cpuChartHost.cornerRadius = 6
            cpuChartHost.backgroundColor = CGColor.clear
            cpuChartSection.addSublayer(cpuChartHost)

            let countsSection = CALayer()
            countsSection.isGeometryFlipped = true
            metrics.addSublayer(countsSection)

            let threadsValue = makeTextLayer(font: numericFont,
                                             color: .black,
                                             alignment: .right)
            threadsValue.alignmentMode = .right
            threadsValue.string = "—"
            countsSection.addSublayer(threadsValue)

            let threadsLabel = makeTextLayer(font: countsLabelFont,
                                             color: .black,
                                             alignment: .right)
            threadsLabel.alignmentMode = .right
            threadsLabel.string = "Visible Threads"
            countsSection.addSublayer(threadsLabel)

            let processesValue = makeTextLayer(font: numericFont,
                                               color: .black,
                                               alignment: .right)
            processesValue.alignmentMode = .right
            processesValue.string = "—"
            countsSection.addSublayer(processesValue)

            let processesLabel = makeTextLayer(font: countsLabelFont,
                                               color: .black,
                                               alignment: .right)
            processesLabel.alignmentMode = .right
            processesLabel.string = "Processes"
            countsSection.addSublayer(processesLabel)

            let layers = Layers(rootLayer: root,
                                statusLayer: status,
                                system: SystemMetricsLayers(containerLayer: metrics, machineDividerLayer: divider, cpuStatsSection: cpuStatsSection, cpuChartSectionLayer: cpuChartSection, cpuChartHostLayer: cpuChartHost, countsSectionLayer: countsSection, threadsValueLayer: threadsValue, processesValueLayer: processesValue, threadsLabelLayer: threadsLabel, processesLabelLayer: processesLabel),
                                tableContainerLayer: tableContainer,
                                commandBarLayer: commandBar,
                                stopButton: stop,
                                inspectButton: inspect,
                                searchField: search)
            self.layers = layers

            cpuChart = CPUHistoryChart(
                appConnection: appConnection,
                model: model,
                hostLayer: layers.system.cpuChartHostLayer,
                userColor: cpuUserColor,
                systemColor: cpuSystemColor,
                mainController: self
                )

            processTable = ProcessTable(appConnection: appConnection, model: model, tableContainer: tableContainer, position: .init(x: 0, y: 0), mainController: self)

            refreshAggregatedSystemDisplay()

            refreshCommandBarIcons()
            updateCommandBarActionButtonsState(force: true)

            applyColorsToLayers()
            layoutLayers()
        }

        CATransaction.commit()

        startProcessStream()

        // Keep self alive until socket closes
        retainedSelf = self
    }

    // MARK: - App Connection Helpers

    private var appConnection: OuterframeHost {
        outerframeHost
    }

    private lazy var streamDelegate = ProcessStreamDelegate(owner: self)

    private let maxCpuHistoryDuration: TimeInterval = 180

    private let numericFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)


    func cleanup() {
        cancelStream(triggerReconnect: false)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        processTable?.cleanup()
        pendingViewportAnnouncementTask?.cancel()
        pendingViewportAnnouncementTask = nil
        cachedSelectionQueryItems = nil
        lastMetricsSnapshotIndex = 0
        lastSentViewportState = nil
        commandBarActionButtonsEnabled = false
        reconnectAttempts = 0
        maintainStream = false
        currentSystemMetrics = nil
        model.cpuHistory.removeAll(keepingCapacity: false)
        countHistory.removeAll(keepingCapacity: false)
        historicalRequestInFlight = false
        pendingHistoricalRange = nil
        activeHistoricalRequestID = 0
        model.logicalCpuCount = 1
        model.selection = .range(range: .moving(ago: Self.defaultTimeWindowDuration))
        quitDialog?.dismiss()
        quitDialog = nil
        cpuChart?.rootLayer.removeFromSuperlayer()
        cpuChart = nil
        layers = nil
        searchFieldInputController.delegate = nil
        lastSearchFilterText = ""
        appConnection.sendTextCursorUpdate(cursors: [])
    }

    func accessibilitySnapshot() -> OuterframeAccessibilitySnapshot? {
        guard let layers else { return nil }

        var nextId: UInt32 = 0
        func makeId() -> UInt32 {
            let id = nextId
            nextId += 1
            return id
        }

        let rootFrame = layers.rootLayer.bounds
        let rootLayer = layers.rootLayer

        // Convert frames to root layer coordinate system
        func frameInRoot(_ layer: CALayer) -> CGRect {
            rootLayer.convert(layer.bounds, from: layer)
        }

        // Stop button node
        let stopButtonFrame = frameInRoot(layers.stopButton.container)
        let stopButtonNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .button,
            frame: stopButtonFrame,
            label: "Stop",
            hint: "Stop the selected process"
        )

        // Inspect button node
        let inspectButtonFrame = frameInRoot(layers.inspectButton.container)
        let inspectButtonNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .button,
            frame: inspectButtonFrame,
            label: "Inspect",
            hint: "Inspect the selected process"
        )

        // Search field node
        let searchFieldFrame = frameInRoot(layers.searchField.container)
        let searchText = searchFieldInputController.text
        let searchFieldNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .textField,
            frame: searchFieldFrame,
            label: "Search processes",
            value: searchText.isEmpty ? nil : searchText
        )

        // CPU Usage section with Idle/User/System
        var cpuUsageChildren: [OuterframeAccessibilityNode] = []
        if let cpuInfo = layers.system.cpuStatsSection.accessibilityInfo() {
            // Helper to convert frame from cpuStatsSection.rootLayer to root layer
            func cpuFrameInRoot(_ frameInCpuSection: CGRect) -> CGRect {
                let converted = layers.rootLayer.convert(frameInCpuSection, from: layers.system.cpuStatsSectionLayer)
                return converted
            }

            // Title "CPU Usage"
            let titleNode = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .staticText,
                frame: cpuFrameInRoot(cpuInfo.titleFrame),
                label: "CPU Usage"
            )
            cpuUsageChildren.append(titleNode)

            // Helper for CPU stat rows
            func makeCpuRowNodes(row: CPUStatsSection.AccessibilityRowInfo) -> [OuterframeAccessibilityNode] {
                var nodes: [OuterframeAccessibilityNode] = []
                let labelNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .staticText,
                    frame: cpuFrameInRoot(row.labelFrame),
                    label: row.labelText
                )
                nodes.append(labelNode)

                let valueText: String
                if let value = row.currentValue {
                    valueText = String(format: "%.1f%%", value)
                } else {
                    valueText = "—"
                }
                let valueNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .staticText,
                    frame: cpuFrameInRoot(row.valueFrame),
                    label: "\(row.labelText) CPU",
                    value: valueText
                )
                nodes.append(valueNode)
                return nodes
            }

            cpuUsageChildren.append(contentsOf: makeCpuRowNodes(row: cpuInfo.idleRow))
            cpuUsageChildren.append(contentsOf: makeCpuRowNodes(row: cpuInfo.userRow))
            cpuUsageChildren.append(contentsOf: makeCpuRowNodes(row: cpuInfo.systemRow))
        }

        let cpuUsageSectionFrame = frameInRoot(layers.system.cpuStatsSectionLayer)
        let cpuUsageNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .container,
            frame: cpuUsageSectionFrame,
            label: "CPU Usage",
            children: cpuUsageChildren
        )

        // CPU chart node
        let cpuChartFrame = frameInRoot(layers.system.cpuChartSectionLayer)
        let cpuChartNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .container,
            frame: cpuChartFrame,
            label: "CPU History Chart"
        )

        // Threads and Processes counts
        let countsSectionFrame = frameInRoot(layers.system.countsSectionLayer)

        let threadsValueFrame = frameInRoot(layers.system.threadsValueLayer)
        let threadsValueText = (layers.system.threadsValueLayer.string as? String) ?? "—"
        let threadsValueNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .staticText,
            frame: threadsValueFrame,
            label: "Visible Threads",
            value: threadsValueText
        )

        let threadsLabelFrame = frameInRoot(layers.system.threadsLabelLayer)
        let threadsLabelNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .staticText,
            frame: threadsLabelFrame,
            label: "Visible Threads"
        )

        let processesValueFrame = frameInRoot(layers.system.processesValueLayer)
        let processesValueText = (layers.system.processesValueLayer.string as? String) ?? "—"
        let processesValueNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .staticText,
            frame: processesValueFrame,
            label: "Processes",
            value: processesValueText
        )

        let processesLabelFrame = frameInRoot(layers.system.processesLabelLayer)
        let processesLabelNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .staticText,
            frame: processesLabelFrame,
            label: "Processes"
        )

        let countsNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .container,
            frame: countsSectionFrame,
            label: "System Counts",
            children: [threadsValueNode, threadsLabelNode, processesValueNode, processesLabelNode]
        )

        // Process table
        let tableFrame = frameInRoot(layers.tableContainerLayer)
        let totalRowCount = model.displayedRowCount
        let columnCount = 6 // Command, User, % CPU, CPU Time, Memory, PID

        // Build header row node
        var tableChildren: [OuterframeAccessibilityNode] = []
        if let headerInfo = processTable?.headerForAccessibility() {
            let adjustedHeaderFrame = headerInfo.frame.offsetBy(dx: tableFrame.origin.x, dy: tableFrame.origin.y)

            var headerCells: [OuterframeAccessibilityNode] = []
            for (title, isSorted, columnFrame) in headerInfo.columns {
                let adjustedColumnFrame = columnFrame.offsetBy(dx: tableFrame.origin.x, dy: tableFrame.origin.y)
                let cellLabel = isSorted ? "\(title), sorted" : title
                let headerCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .button,
                    frame: adjustedColumnFrame,
                    label: cellLabel,
                    hint: "Click to sort by \(title)"
                )
                headerCells.append(headerCell)
            }

            let headerRow = OuterframeAccessibilityNode(
                identifier: makeId(),
                role: .row,
                frame: adjustedHeaderFrame,
                label: "Header row",
                children: headerCells
            )
            tableChildren.append(headerRow)
        }

        // Build row nodes for visible/loaded rows only
        var visibleRowCount = 0
        let columnLayout = processTable?.columnLayoutForAccessibility() ?? []
        if let loadedEntries = processTable?.loadedEntriesForAccessibility() {
            visibleRowCount = loadedEntries.count
            for (_, process, rowFrame) in loadedEntries {
                let adjustedRowFrame = rowFrame.offsetBy(dx: tableFrame.origin.x, dy: tableFrame.origin.y)

                // Helper to create cell frame for a specific column
                func cellFrame(columnIndex: Int) -> CGRect {
                    guard columnIndex < columnLayout.count else { return adjustedRowFrame }
                    let col = columnLayout[columnIndex]
                    return CGRect(
                        x: tableFrame.origin.x + col.offset,
                        y: adjustedRowFrame.origin.y,
                        width: col.width,
                        height: adjustedRowFrame.height
                    )
                }

                // Create cells for this row (columns: Command, User, % CPU, CPU Time, Memory, PID)
                let commandCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .cell,
                    frame: cellFrame(columnIndex: 0),
                    label: "Command",
                    value: process.command
                )
                let userCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .cell,
                    frame: cellFrame(columnIndex: 1),
                    label: "User",
                    value: process.user
                )
                let cpuCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .cell,
                    frame: cellFrame(columnIndex: 2),
                    label: "CPU",
                    value: String(format: "%.1f%%", process.cpuPercent)
                )
                let cpuTimeCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .cell,
                    frame: cellFrame(columnIndex: 3),
                    label: cpuTimeColumnTitle(),
                    value: formatCPUTime(milliseconds: process.cpuTimeMilliseconds)
                )
                let memoryCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .cell,
                    frame: cellFrame(columnIndex: 4),
                    label: "Memory",
                    value: formatMemory(kilobytes: process.memoryKilobytes,
                                        isKernelThread: process.isKernelThread)
                )
                let pidCell = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .cell,
                    frame: cellFrame(columnIndex: 5),
                    label: "PID",
                    value: String(process.pid)
                )

                let rowNode = OuterframeAccessibilityNode(
                    identifier: makeId(),
                    role: .row,
                    frame: adjustedRowFrame,
                    label: "\(process.command) (PID \(process.pid))",
                    value: "CPU: \(String(format: "%.1f%%", process.cpuPercent)), Memory: \(formatMemory(kilobytes: process.memoryKilobytes, isKernelThread: process.isKernelThread))",
                    children: [commandCell, userCell, cpuCell, cpuTimeCell, memoryCell, pidCell]
                )
                tableChildren.append(rowNode)
            }
        }

        let tableNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .table,
            frame: tableFrame,
            label: "Process List",
            hint: totalRowCount > visibleRowCount ? "Showing \(visibleRowCount) of \(totalRowCount) processes" : nil,
            children: tableChildren,
            rowCount: totalRowCount,
            columnCount: columnCount
        )

        // Root container
        let rootNode = OuterframeAccessibilityNode(
            identifier: makeId(),
            role: .container,
            frame: rootFrame,
            label: "Activity Monitor",
            children: [stopButtonNode, inspectButtonNode, searchFieldNode, cpuUsageNode, cpuChartNode, countsNode, tableNode]
        )

        return OuterframeAccessibilitySnapshot(rootNodes: [rootNode])
    }

    private func formatCPUTime(milliseconds: Int) -> String {
        let ms = milliseconds % 1000
        let totalSeconds = milliseconds / 1000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalSeconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, ms)
        } else {
            return String(format: "%d:%02d.%03d", minutes, seconds, ms)
        }
    }

    private func cpuTimeColumnTitle() -> String {
        model.selection.historical ? "CPU Time" : "Total CPU Time"
    }

    private func formatMemory(kilobytes: Int, isKernelThread: Bool) -> String {
        if isKernelThread {
            return "kernel"
        }
        if kilobytes < 1024 {
            return "\(kilobytes) KB"
        } else if kilobytes < 1024 * 1024 - 512 {
            // MB with one decimal place
            let fullUnits = kilobytes >> 10
            let remainder = kilobytes & 0x3FF
            var tenths = Int(round((Float(remainder) / 1024.0) * 10))
            let adjustedUnits = fullUnits + (tenths == 10 ? 1 : 0)
            tenths %= 10
            return String(format: "%d.%d MB", adjustedUnits, tenths)
        } else {
            // GB with two decimal places
            let fullUnits = kilobytes >> 20
            let remainder = kilobytes & 0xFFFFF
            var hundredths = Int(round((Float(remainder) / Float(1 << 20)) * 100))
            let adjustedUnits = fullUnits + (hundredths == 100 ? 1 : 0)
            hundredths %= 100
            return String(format: "%d.%02d GB", adjustedUnits, hundredths)
        }
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
        let appearance = model.effectiveAppearance

        appearance.performAsCurrentDrawingAppearance {
            updateSearchFieldFocusAppearance()
            updateSearchFieldDisplay()
            processTable?.appearanceDidChange()
            applyColorsToLayers()
            updateSelectionOverlayColors()
            refreshCommandBarIcons()
        }
    }

    func setWindowActive(_ isActive: Bool) {
        if model.isWindowActive == isActive { return }
        model.isWindowActive = isActive
        processTable?.updateSelectionAppearance()
        if isActive {
            if restoreSearchFieldFocusOnWindowActivation {
                restoreSearchFieldFocusOnWindowActivation = false
                focusSearchField()
            }
        } else {
            if searchFieldInputController.isFocused {
                restoreSearchFieldFocusOnWindowActivation = true
                blurSearchField()
            }
        }
        updateSearchFieldFocusAppearance()
        updateSearchFieldDisplay()
    }

    func viewFocusChanged(_ isFocused: Bool) {
        viewHasFocus = isFocused
        updateTableFirstResponderState()
        if !isFocused && searchFieldInputController.isFocused {
            blurSearchField()
        }
    }

    private func updateTableFirstResponderState() {
        // Table is first responder when view has focus and search field is not focused
        let tableIsFirstResponder = viewHasFocus && !searchFieldInputController.isFocused
        if model.isTableFirstResponder != tableIsFirstResponder {
            model.isTableFirstResponder = tableIsFirstResponder
            processTable?.updateSelectionAppearance()
        }
    }

    func resize(width: Int, height: Int) {
        currentSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        processTable?.onResize()
        CATransaction.commit()
    }

    // TODO: no human has verified that this makes any sense.
    func textInputControllerDidChangeState() {
        let currentFilter = searchFieldInputController.text
        let filterChanged = currentFilter != lastSearchFilterText

        updateTableFirstResponderState()
        updateSearchFieldFocusAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateSearchFieldDisplay()
        updateInputMode()
        updateEditingCapabilities()
        sendSearchFieldCursorUpdate()
        CATransaction.commit()
        if filterChanged {
            lastSearchFilterText = currentFilter
            processTable?.onSearchFilterChanged()
            refreshResultsForCurrentSearchFilter()
        }
    }

    private func refreshResultsForCurrentSearchFilter() {
        if model.selection.historical,
           let lastSample = model.cpuHistory.last,
           let timeBasedRange = model.selection.timeBasedRange(boundEnd: lastSample.timestamp) {
            fetchHistoricalSnapshot(for: timeBasedRange, force: true)
            return
        }

        announceViewportToServer(immediate: true, force: true)
    }

    func selectedTextForCopy() -> String? {
        guard searchFieldInputController.isFocused else { return nil }
        return searchFieldInputController.selectedTextContent()
    }

    func pasteboardItemsForCopy() -> [OuterframeContentPasteboardItem] {
        guard searchFieldInputController.isFocused,
              let selectedText = searchFieldInputController.selectedTextContent(),
              !selectedText.isEmpty else {
            return []
        }
        return [
            OuterframeContentPasteboardItem(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                       data: Data(selectedText.utf8))
        ]
    }

    func handlePasteboardItemsForPaste(_ items: [OuterframeContentPasteboardItem]) {
        guard searchFieldInputController.isFocused else { return }
        for item in items {
            if item.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue,
               let stringValue = String(data: item.data, encoding: .utf8) {
                searchFieldInputController.insertText(stringValue)
                return
            }

            if item.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue,
               let attributed = try? NSAttributedString(data: item.data,
                                                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                        documentAttributes: nil) {
                searchFieldInputController.insertText(attributed.string)
                return
            }
        }
    }

    func mouseDown(at point: CGPoint, modifierFlags: NSEvent.ModifierFlags, clickCount: Int) {
        guard let layers = layers else { return }
        let root = layers.rootLayer
        let rootPoint = point

        if quitDialog?.handleMouseDown(at: rootPoint) == true {
            return
        }

        if let chart = cpuChart {
            let pointInChart = chart.rootLayer.convert(rootPoint, from: root)
            if chart.handleMouseDown(at: pointInChart) {
                if searchFieldInputController.isFocused {
                    blurSearchField()
                }
                return
            }
        }

        if let processTable,
           processTable.mouseDown(at: rootPoint, modifierFlags: modifierFlags, clickCount: clickCount, rootLayer: root) {
            if searchFieldInputController.isFocused {
                blurSearchField()
            }
            return
        }


        if handleCommandBarMouseDown(at: rootPoint, modifierFlags: modifierFlags, clickCount: clickCount) {
            return
        }

        clearSelectedProcess()
    }

    func mouseDragged(to point: CGPoint, modifierFlags: NSEvent.ModifierFlags) {
        guard let layers = layers else { return }
        let root = layers.rootLayer
        if quitDialog?.handleMouseDragged(at: point) == true {
            return
        }
        if let chart = cpuChart {
            let pointInChart = chart.rootLayer.convert(point, from: root)
            if chart.handleMouseDragged(at: pointInChart) {
                return
            }
        }

        _ = processTable?.mouseDragged(at: point, modifierFlags: modifierFlags, rootLayer: root)
    }

    func mouseUp(at point: CGPoint, modifierFlags: NSEvent.ModifierFlags) {
        guard let layers = layers else { return }
        let root = layers.rootLayer
        if quitDialog?.handleMouseUp(at: point) == true {
            return
        }
        if let chart = cpuChart {
            let pointInChart = chart.rootLayer.convert(point, from: root)
            if chart.handleMouseUp(at: pointInChart) {
                return
            }
        }

        _ = processTable?.mouseUp(at: point, modifierFlags: modifierFlags, rootLayer: root)
    }

    func mouseMoved(to point: CGPoint, modifierFlags _: NSEvent.ModifierFlags) {
        if let chart = cpuChart, let rootLayer = layers?.rootLayer {
            let pointInChart = chart.rootLayer.convert(point, from: rootLayer)
            if chart.handleMouseMoved(at: pointInChart) {
                return
            }
        }
    }

    func rightMouseDown(at point: CGPoint, modifierFlags: NSEvent.ModifierFlags, clickCount: Int) {
        guard handleCommandBarRightMouseDown(at: point,
                                             modifierFlags: modifierFlags,
                                             clickCount: clickCount) else {
            return
        }
    }

    func stateUpdateOnSelectionChange() {
        if model.selection.historical {
            guard let lastSample = model.cpuHistory.last,
                  let timeBasedRange = model.selection.timeBasedRange(boundEnd: lastSample.timestamp) else {
                return
            }

            model.isShowingHistoricalData = true
            fetchHistoricalSnapshot(for: timeBasedRange, force: true)
        } else {
            if model.isShowingHistoricalData || historicalRequestInFlight {
                model.isShowingHistoricalData = false
                historicalRequestInFlight = false
                pendingHistoricalRange = nil
                activeHistoricalRequestID = 0
            }
            announceViewportToServer(immediate: true, force: true)
        }
    }

    func immediateUpdatesOnSelectionChange(isInTransaction: Bool) {
        if !isInTransaction {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }

        processTable?.selectionModeDidChange()
        refreshAggregatedSystemDisplay()

        if !isInTransaction {
            CATransaction.commit()
        }
    }

    func animatedUpdatesOnSelectionChange(isInTransaction: Bool) {
        let newStatusText: String?
        if model.selection.historical {
            newStatusText = "Loading historical data…"
        } else {
            newStatusText = nil
        }

        if currentStatusText != newStatusText {
            if !isInTransaction {
                CATransaction.begin()
            }

            showStatus(newStatusText)

            if !isInTransaction {
                CATransaction.commit()
            }
        }
    }

    private func fetchHistoricalSnapshot(for range: ClosedRange<TimeInterval>, force: Bool = false) {
        if !force,
           let pending = pendingHistoricalRange,
           Swift.abs(pending.lowerBound - range.lowerBound) + Swift.abs(pending.upperBound - range.upperBound) < 0.05 {
            return
        }

        var queryItems = selectionQueryItems(for: .range(range: .absolute(range: range)))
        let trimmedSearch = searchFieldInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        queryItems.append(.init(name: "search", value: trimmedSearch))

        let requestRange = requestedViewportRange()
        queryItems.append(URLQueryItem(name: "start", value: String(requestRange.lowerBound)))
        queryItems.append(URLQueryItem(name: "end", value: String(requestRange.upperBound)))
        if let column = model.sortColumn {
            queryItems.append(URLQueryItem(name: "sort", value: serverSortParameter(for: column)))
            queryItems.append(URLQueryItem(name: "direction", value: model.sortAscending ? "asc" : "desc"))
        }

        guard let apiEndpoint else { return }
        let url = apiEndpoint.appending(path: "history").appending(queryItems: queryItems)

        pendingHistoricalRange = range
        historicalRequestCounter += 1
        let requestID = historicalRequestCounter
        activeHistoricalRequestID = requestID
        model.isShowingHistoricalData = true
        historicalRequestInFlight = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        performSingleRequest(request) { [weak self] data, response, error in

            guard let self else { return }

            if let error {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard activeHistoricalRequestID == requestID else { return }
                    self.historicalRequestInFlight = false
                    self.model.isShowingHistoricalData = false
                    self.pendingHistoricalRange = nil
                    self.activeHistoricalRequestID = 0
                    self.showStatus("Failed to load history: \(error.localizedDescription)")
                }
                return
            }

            guard let data else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard activeHistoricalRequestID == requestID else { return }

                    self.model.isShowingHistoricalData = false
                    self.pendingHistoricalRange = nil
                    self.activeHistoricalRequestID = 0
                    self.showStatus("Historical data unavailable.")
                }
                return
            }

            // Parse data on this background thread before moving to main actor
            guard let (snapshotFrame, _) = parseFullViewportContents(data) else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeHistoricalRequestID == requestID else { return }
                self.historicalRequestInFlight = false
                self.model.isShowingHistoricalData = true

                guard self.pendingHistoricalRange != nil else {
                    self.model.isShowingHistoricalData = false
                    return
                }

                latestSnapshotTimestamp = snapshotFrame.snapshotTimestamp

                currentSystemMetrics = snapshotFrame.systemMetrics

                // TODO: use more sane logic for getting the logical CPU count once
                if let logical = snapshotFrame.systemMetrics?.logicalCpuCount,
                    logical > 0,
                    logical != model.logicalCpuCount {
                    model.logicalCpuCount = logical
                }


                CATransaction.begin()
                CATransaction.setDisableActions(true)

                refreshAggregatedSystemDisplay()

                let isNewSnapshot = snapshotFrame.snapshotIndex != currentSnapshotIndex || snapshotFrame.windowTotal != model.displayedRowCount

                if isNewSnapshot {
                    currentSnapshotIndex = snapshotFrame.snapshotIndex
                }

                // This method ends the current non-animated transaction and starts a new animated one
                if isNewSnapshot {
                    processTable?.updateProcessTableRows(startIndex: snapshotFrame.windowStart,
                                                         totalCount: snapshotFrame.windowTotal,
                                                         entries: snapshotFrame.entries,
                                                         additionalEntries: snapshotFrame.additionalEntries,
                                                         snapshotIndex: snapshotFrame.snapshotIndex)
                } else {
                    // TODO: dead code?
                    processTable?.updateProcessTableRowsOnScroll(startIndex: snapshotFrame.windowStart,
                                                                 entries: snapshotFrame.entries,
                                                                 additionalEntries: snapshotFrame.additionalEntries)
                }
                notifyAccessibilityTreeChanged()

                pendingHistoricalRange = nil
                activeHistoricalRequestID = 0
                showStatus("Viewing historical data")
                CATransaction.commit()
            }
        }
    }

    func scrollWheel(delta: CGPoint,
                           at point: CGPoint,
                           modifierFlags _: NSEvent.ModifierFlags,
                           phase _: NSEvent.Phase,
                           momentumPhase _: NSEvent.Phase,
                           isMomentum _: Bool,
                           isPrecise: Bool) {
        guard let layers = layers else { return }
        _ = processTable?.scrollWheel(delta: delta, at: point, isPrecise: isPrecise, rootLayer: layers.rootLayer)
    }

    // MARK: - Text Input Handling (independent of any particular control)

    func insertText(_ text: String) {
        if searchFieldInputController.isFocused {
            searchFieldInputController.insertText(text)
        }
    }

    func performTextCommand(_ command: String) {
        if searchFieldInputController.isFocused {
            searchFieldInputController.performCommand(command)
        }
    }

    func setCursorPosition(fieldID: UUID, position: Int, modifySelection: Bool) {
        guard fieldID == Self.searchFieldID else { return }
        focusSearchField()
        searchFieldInputController.setCursorPosition(position, modifySelection: modifySelection)
    }

    func textInputFocus(fieldID: UUID, hasFocus: Bool) {
        guard fieldID == Self.searchFieldID else { return }
        if hasFocus {
            focusSearchField()
        } else {
            blurSearchField()
        }
    }

    func keyDown(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, modifierFlags: NSEvent.ModifierFlags, isRepeat: Bool) {
        if searchFieldInputController.isFocused {
            return
        }

        _ = processTable?.keyDown(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, modifierFlags: modifierFlags, isRepeat: isRepeat)
    }

    // MARK: Colors

    private func updateSelectionOverlayColors() {
        cpuChart?.updateAppearance()
    }

    private func applyColorsToLayers() {
        guard let layers = layers else { return }

        CATransaction.begin()

        model.effectiveAppearance.performAsCurrentDrawingAppearance {

            layers.rootLayer.backgroundColor = CGColor.clear
            layers.tableContainerLayer.backgroundColor = CGColor.clear

            let label = NSColor.labelColor.cgColor
            let separator = NSColor.separatorColor
            let isLightTheme = NSColor.controlBackgroundColor.am_brightness > 0.6
            let commandBarBorder = commandBarBorderColor(separator: separator, isLightTheme: isLightTheme)
            let commandBarBackground = commandBarCapsuleBackgroundColor()
            layers.statusLayer.foregroundColor = NSColor.systemRed.cgColor
            layers.system.machineDividerLayer.backgroundColor = separator.withAlphaComponent(isLightTheme ? 0.35 : 0.55).cgColor

            layers.system.cpuStatsSection.setColors(title: NSColor.labelColor,
                                                    label: NSColor.labelColor,
                                                    user: cpuUserColor,
                                                    system: cpuSystemColor,
                                                    idle: cpuIdleColor)

            layers.system.threadsValueLayer.foregroundColor = label
            layers.system.processesValueLayer.foregroundColor = label
            let secondaryLabel = NSColor.secondaryLabelColor.cgColor
            layers.system.threadsLabelLayer.foregroundColor = secondaryLabel
            layers.system.processesLabelLayer.foregroundColor = secondaryLabel

            let stop = layers.stopButton
            stop.backgroundLayer.backgroundColor = commandBarBackground
            stop.backgroundLayer.borderColor = commandBarBorder
            stop.textLayer.foregroundColor = label

            let inspect = layers.inspectButton
            inspect.backgroundLayer.backgroundColor = commandBarBackground
            inspect.backgroundLayer.borderColor = commandBarBorder
            inspect.textLayer.foregroundColor = label

            let search = layers.searchField
            search.backgroundLayer.backgroundColor = commandBarBackground
            search.backgroundLayer.borderColor = commandBarBorder
            search.placeholderLayer.foregroundColor = NSColor.placeholderTextColor.cgColor
            search.textLayer.foregroundColor = NSColor.textColor.cgColor
            search.selectionLayer.backgroundColor = (searchFieldInputController.isFocused && model.isWindowActive ?
                                                     NSColor.selectedTextBackgroundColor.cgColor : NSColor.unemphasizedSelectedTextBackgroundColor.withAlphaComponent(isLightTheme ? 0.75 : 0.9).cgColor)
            quitDialog?.updateAppearance()
            cpuChart?.updateAppearance()
        }

        updateCommandBarActionButtonsState(force: true)
        updateSearchFieldFocusAppearance()
        updateSearchFieldDisplay()
        CATransaction.commit()
    }

    private func performSingleRequest(_ request: URLRequest,
                                      completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        appConnection.applyProxy(to: configuration)
        let session =  URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
            session.finishTasksAndInvalidate()
        }.resume()
    }


    private func startProcessStream() {
        guard let apiEndpoint else { return }
        var cpuHistoryRequest = URLRequest(url: apiEndpoint.appending(path: "cpu_history"))
        cpuHistoryRequest.timeoutInterval = 20
        performSingleRequest(cpuHistoryRequest) { [weak self] data, _, error in
            struct CpuHistoryResponse: Decodable {
                struct Sample: Decodable {
                    let timestamp: TimeInterval
                    let hasCPU: Bool
                    let userPercent: Double
                    let systemPercent: Double
                    let idlePercent: Double

                    enum CodingKeys: String, CodingKey {
                        case timestamp
                        case hasCPU
                        case userPercent
                        case systemPercent
                        case idlePercent
                    }
                }

                let samples: [Sample]
            }

            guard let data, error == nil else { return }

            let decoder = JSONDecoder()
            guard let response = try? decoder.decode(CpuHistoryResponse.self, from: data) else {
                return
            }

            guard !response.samples.isEmpty else {
                return
            }
            var converted: [CPUSample] = []
            converted.reserveCapacity(response.samples.count)
            for sample in response.samples where sample.hasCPU {
                converted.append(CPUSample(timestamp: sample.timestamp,
                                           user: sample.userPercent,
                                           system: sample.systemPercent,
                                           idle: sample.idlePercent))
            }
            guard !converted.isEmpty else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }

                if let lastTimestamp = converted.last?.timestamp {
                    let epsilon: TimeInterval = 0.0001
                    let trailing = model.cpuHistory.filter { $0.timestamp > lastTimestamp + epsilon }
                    if !trailing.isEmpty {
                        converted.append(contentsOf: trailing)
                    }
                } else if !model.cpuHistory.isEmpty {
                    converted.append(contentsOf: model.cpuHistory)
                }
                model.cpuHistory = converted
                if trimHistory() {
                    if clampSelectionToBounds() {
                        cpuChart?.setSelection(selection: model.selection)
                    }
                }

                refreshAggregatedSystemDisplay()
            }
        }

        let desiredEnd = max(defaultViewportLength, model.visibleRowRange.count)
        let trimmedSearch = searchFieldInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var queryItems = [
            URLQueryItem(name: "clientId", value: clientIdentifier),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "end", value: String(desiredEnd)),
            URLQueryItem(name: "search", value: trimmedSearch),
            URLQueryItem(name: "snapshot", value: String(currentSnapshotIndex))
        ]

        if let sortColumn = model.sortColumn {
            queryItems.append(URLQueryItem(name: "sort", value: serverSortParameter(for: sortColumn)))
            queryItems.append(URLQueryItem(name: "direction", value: model.sortAscending ? "asc" : "desc"))
        }

        queryItems.append(contentsOf: selectionQueryItems(for: model.selection))
        let streamURL = apiEndpoint.appending(path: "stream").appending(queryItems: queryItems)

        let urlSession: URLSession
        if let session = self.urlSession {
            urlSession = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 1
            configuration.timeoutIntervalForRequest = 60 * 60
            configuration.timeoutIntervalForResource = 60 * 60
            appConnection.applyProxy(to: configuration)
            urlSession = URLSession(configuration: configuration, delegate: streamDelegate, delegateQueue: urlSessionQueue)
            self.urlSession = urlSession
        }

        cancelStream(triggerReconnect: false)

        reconnectAttempts = 0

        var request = URLRequest(url: streamURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 * 60

        streamGeneration += 1
        let generation = streamGeneration

        let task = urlSession.dataTask(with: request)

        task.taskDescription = String(generation)
        streamTask = task
        currentStreamGeneration = generation
        maintainStream = true
        task.resume()

        showStatus("Connecting to process stream…")

        let state = makeViewportState(forcedRange: 0..<max(defaultViewportLength, model.visibleRowRange.count))
        guard let url = makeViewportURL(state: state, immediate: true) else { return }
        lastSentViewportState = state
        var initialViewportRequest = URLRequest(url: url)
        initialViewportRequest.timeoutInterval = 15
        performSingleRequest(initialViewportRequest) { _, _, _ in }
    }

    private func makeViewportURL(state: ProcessMonitorListModel.ViewportState, immediate: Bool) -> URL? {
        var queryItems: [URLQueryItem] = [
            .init(name: "clientId", value: clientIdentifier),
            .init(name: "start", value: String(state.startIndex)),
            .init(name: "end", value: String(state.endIndex)),
            .init(name: "search", value: state.searchText),
            .init(name: "snapshot", value: String(state.snapshotIndex)),
            .init(name: "immediate", value: immediate ? "1" : "0")
        ]

        queryItems.append(contentsOf: selectionQueryItems(for: model.selection))
        if let column = state.sortColumn {
            queryItems.append(.init(name: "sort", value: serverSortParameter(for: column)))
            queryItems.append(.init(name: "direction", value: state.sortAscending ? "asc" : "desc"))
        }

        return apiEndpoint?.appending(path: "viewport").appending(queryItems: queryItems)
    }

    private func selectionQueryItems(for selection: CPUHistoryChart.Selection) -> [URLQueryItem] {
        if let cachedSelectionQueryItems, cachedSelectionQueryItems.selection == selection {
            return cachedSelectionQueryItems.items
        }

        func formattedSelectionValue(_ value: TimeInterval) -> String {
            return String(format: "%.3f", locale: Self.selectionValueLocale, value)
        }

        let items: [URLQueryItem]
        switch selection {
        case .range(let range):
            switch range {
            case .absolute(let actualRange):
                items = [
                    URLQueryItem(name: "timeMode", value: "fixed"),
                    URLQueryItem(name: "timeStart", value: formattedSelectionValue(actualRange.lowerBound)),
                    URLQueryItem(name: "timeEnd", value: formattedSelectionValue(actualRange.upperBound))
                ]
            case .moving(let duration):
                items = [
                    URLQueryItem(name: "timeMode", value: "trailing"),
                    URLQueryItem(name: "timeDuration", value: formattedSelectionValue(duration))
                ]
            }
        case .point(let time):
            switch time {
            case .absolute(let actualTime):
                items = [
                    URLQueryItem(name: "timeMode", value: "fixed"),
                    URLQueryItem(name: "timeStart", value: formattedSelectionValue(actualTime - 1)),
                    URLQueryItem(name: "timeEnd", value: formattedSelectionValue(actualTime))
                ]
            case .now:
                items = [
                    URLQueryItem(name: "timeMode", value: "trailing"),
                    URLQueryItem(name: "timeDuration", value: formattedSelectionValue(1))
                ]
            }
        case .none:
            items = []
        }

        cachedSelectionQueryItems = (selection, items)
        return items
    }

    private func serverSortParameter(for column: ProcessMonitorListModel.SortColumn) -> String {
        switch column {
        case .pid:
            return "pid"
        case .command:
            return "command"
        case .user:
            return "user"
        case .cpu:
            return "cpu"
        case .cpuTime:
            return "cputime"
        case .memory:
            return "memory"
        }
    }

    private func requestedViewportRange() -> Range<Int> {
        let lower = max(0, model.visibleRowRange.lowerBound)
        let desiredLength = max(defaultViewportLength, model.visibleRowRange.count)
        let upper = max(lower + 1, lower + desiredLength)
        return lower..<upper
    }

    private func makeViewportState(forcedRange: Range<Int>? = nil) -> ProcessMonitorListModel.ViewportState {
        let trimmedSearch = searchFieldInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let forcedRange {
            let safeEnd = max(forcedRange.lowerBound, forcedRange.upperBound)
            return .init(startIndex: forcedRange.lowerBound,
                         endIndex: safeEnd,
                         sortColumn: model.sortColumn,
                         sortAscending: model.sortAscending,
                         searchText: trimmedSearch,
                         snapshotIndex: currentSnapshotIndex)
        }

        let requestRange = requestedViewportRange()
        return .init(startIndex: requestRange.lowerBound,
                     endIndex: requestRange.upperBound,
                     sortColumn: model.sortColumn,
                     sortAscending: model.sortAscending,
                     searchText: trimmedSearch,
                     snapshotIndex: currentSnapshotIndex)
    }

    func announceViewportToServer(immediate: Bool, force: Bool = false) {
        if model.isShowingHistoricalData {
            pendingViewportAnnouncementTask?.cancel()
            pendingViewportAnnouncementTask = nil
            fetchHistoricalViewportUpdate()
            return
        }

        if force {
            pendingViewportAnnouncementTask?.cancel()
            pendingViewportAnnouncementTask = nil
            sendViewportToServer(immediate: immediate, force: true)
            return
        }

        if immediate {
            pendingViewportAnnouncementTask?.cancel()
            pendingViewportAnnouncementTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.viewportAnnouncementDelayNanoseconds)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.pendingViewportAnnouncementTask = nil
                self.sendViewportToServer(immediate: true, force: false)
            }
            return
        }

        sendViewportToServer(immediate: immediate, force: false)
    }

    private func sendViewportToServer(immediate: Bool, force: Bool) {
        let state = makeViewportState()
        if !force, lastSentViewportState == state {
            return
        }
        guard let url = makeViewportURL(state: state, immediate: immediate) else { return }
        lastSentViewportState = state
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
//        logViewportEvent("send viewport start \(state.startIndex) end \(state.endIndex) snap \(state.snapshotIndex) immediate \(immediate) force \(force)")
        performSingleRequest(request) { _, _, _ in }
    }

    private func fetchHistoricalViewportUpdate() {
        guard model.selection.timeBasedRange(boundEnd: latestSnapshotTimestamp) != nil else {
            return
        }

        var queryItems = selectionQueryItems(for: model.selection)
        let trimmedSearch = searchFieldInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        queryItems.append(.init(name: "search", value: trimmedSearch))

        let requestRange = requestedViewportRange()
        queryItems.append(URLQueryItem(name: "start", value: String(requestRange.lowerBound)))
        queryItems.append(URLQueryItem(name: "end", value: String(requestRange.upperBound)))

        if let column = model.sortColumn {
            queryItems.append(URLQueryItem(name: "sort", value: serverSortParameter(for: column)))
            queryItems.append(URLQueryItem(name: "direction", value: model.sortAscending ? "asc" : "desc"))
        }

        guard let apiEndpoint else { return }
        let url = apiEndpoint.appending(path: "history").appending(queryItems: queryItems)

        historicalRequestCounter += 1
        let requestID = historicalRequestCounter
        activeHistoricalRequestID = requestID

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        performSingleRequest(request) { [weak self] data, response, error in
            guard let self else { return }

            if error != nil {
                return
            }

            guard let data else {
                return
            }

            guard let (snapshotFrame, _) = parseFullViewportContents(data) else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeHistoricalRequestID == requestID else { return }
                guard self.model.isShowingHistoricalData else { return }

                CATransaction.begin()
                CATransaction.setDisableActions(true)

                processTable?.updateProcessTableRowsOnScroll(startIndex: snapshotFrame.windowStart,
                                                             entries: snapshotFrame.entries,
                                                             additionalEntries: snapshotFrame.additionalEntries)
                notifyAccessibilityTreeChanged()

                CATransaction.commit()
            }
        }
    }

    func onSelectionChanged() {
        if model.selectedProcess == nil {
            quitDialog?.dismiss()
            quitDialog = nil
        }
        updateCommandBarActionButtonsState()
    }

    private func detailURL(forPID pid: Int) -> URL? {
        return appletOuterURL?.appending(queryItems: [
            .init(name: "mode", value: "detail"),
            .init(name: "pid", value: String(pid))
        ])
    }

    private func cancelStream(triggerReconnect: Bool) {
        maintainStream = triggerReconnect
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        streamTask?.cancel()
        streamTask = nil
    }

    func handleStreamResponse(_ response: URLResponse, for task: URLSessionDataTask) -> URLSession.ResponseDisposition {
        guard isCurrentStreamTask(task) else { return .cancel }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            showStatus("Stream error: HTTP \(httpResponse.statusCode)")
            scheduleReconnect(with: nil)
            return .cancel
        }

        reconnectAttempts = 0
        showStatus(nil)
        return .allow
    }

    fileprivate func handleFullViewportContents(_ contents: FullViewportContents, for task: URLSessionDataTask) {
        guard isCurrentStreamTask(task) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
//
//        logRowEvent("stream frame parsed idx \(contents.snapshotIndex) entries \(contents.entries.count) windowStart \(contents.windowStart) total \(contents.windowTotal) additional \(contents.additionalEntries.count)")

        if contents.snapshotIndex != lastMetricsSnapshotIndex {

            currentSystemMetrics = contents.systemMetrics

            if let metrics = contents.systemMetrics {
                // TODO: Use a more sane approach to getting logical cpu count
                if metrics.logicalCpuCount > 0,
                   metrics.logicalCpuCount != model.logicalCpuCount {
                    model.logicalCpuCount = metrics.logicalCpuCount
                }

                if let cpu = metrics.cpu {
                    let sample = CPUSample(
                        timestamp: contents.snapshotTimestamp,
                        user: cpu.userPercent,
                        system: cpu.systemPercent,
                        idle: cpu.idlePercent
                    )
                    model.cpuHistory.append(sample)
                }

                let sanitizedProcess = metrics.processCount > 0 ? metrics.processCount : nil
                let sanitizedThread = metrics.threadCount > 0 ? metrics.threadCount : nil
                if sanitizedProcess == nil && sanitizedThread == nil {
                    return
                }
                countHistory.append(SystemCountSample(timestamp: contents.snapshotTimestamp,
                                                      processCount: metrics.processCount,
                                                      threadCount: metrics.threadCount))
                if trimHistory() {
                    if clampSelectionToBounds() {
                        cpuChart?.setSelection(selection: model.selection)
                    }
                }
            }

            refreshAggregatedSystemDisplay()
            lastMetricsSnapshotIndex = contents.snapshotIndex
        }
        if !model.isShowingHistoricalData {
            // This method ends the current non-animated transaction and starts a new animated one

            let isNewSnapshot = contents.snapshotIndex != currentSnapshotIndex || contents.windowTotal != model.displayedRowCount

            if isNewSnapshot {
                currentSnapshotIndex = contents.snapshotIndex
            }


            if isNewSnapshot {
                processTable?.updateProcessTableRows(startIndex: contents.windowStart,
                                                     totalCount: contents.windowTotal,
                                                     entries: contents.entries,
                                                     additionalEntries: contents.additionalEntries,
                                                     snapshotIndex: contents.snapshotIndex)
            } else {
                processTable?.updateProcessTableRowsOnScroll(startIndex: contents.windowStart,
                                                             entries: contents.entries,
                                                             additionalEntries: contents.additionalEntries)
            }
            notifyAccessibilityTreeChanged()
        }

        CATransaction.commit()
    }

    func handleStreamCompletion(_ error: Error?, for task: URLSessionTask) {
        guard isCurrentStreamTask(task) else { return }
        streamTask = nil

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
            guard let self else { return }
            self.startProcessStream()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

        let delayString = String(format: "%.0f", delay)
        if let error = error as NSError?, error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled {
            showStatus("Connection lost (\(error.localizedDescription)). Reconnecting in \(delayString)s…")
        } else {
            showStatus("Connection lost. Reconnecting in \(delayString)s…")
        }
    }

    private func layoutLayers() {
        guard let layers = layers else { return }
        let root = layers.rootLayer
        let status = layers.statusLayer

        root.frame = CGRect(origin: .zero, size: currentSize)

//        let header = layers.list.headerLayer
//        let rowsViewport = layers.list.rowsViewportLayer

        let availableHeight = root.bounds.height
        let availableWidth = root.bounds.width

        // TODO: hack, shouldn't save this here
        let rowHeight: CGFloat = 28
        let headerHeight: CGFloat = 28
        let minTableHeight = headerHeight + rowHeight * 3
        let maxMetricsHeight = max(availableHeight - minTableHeight, 0)
        var desiredMetricsHeight = min(systemSectionPreferredHeight,
                                       max(systemSectionMinimumHeight, availableHeight * 0.35))
        desiredMetricsHeight = min(desiredMetricsHeight, maxMetricsHeight)
        if maxMetricsHeight <= 0 {
            desiredMetricsHeight = 0
        }
        let metricsHeight = max(0, desiredMetricsHeight)
        let contentTopY = availableHeight
        let commandBarY = max(metricsHeight, contentTopY - commandBarTopInset - commandBarHeight)
        let tableTopY = max(metricsHeight, commandBarY - commandBarBottomSpacing)
        let tableHeight = max(tableTopY - metricsHeight, 0)

        layers.tableContainerLayer.frame = CGRect(x: 0,
                                                  y: metricsHeight,
                                                  width: availableWidth,
                                                  height: tableHeight)

        let metricsLayer = layers.system.containerLayer
        let divider = layers.system.machineDividerLayer

        let width = root.bounds.width
        metricsLayer.frame = CGRect(x: 0, y: 0, width: width, height: metricsHeight)
        metricsLayer.isHidden = metricsHeight <= 0
        divider.isHidden = metricsHeight <= 0
        layers.system.cpuStatsSectionLayer.isHidden = metricsHeight <= 0
        layers.system.cpuChartSectionLayer.isHidden = metricsHeight <= 0
        layers.system.countsSectionLayer.isHidden = metricsHeight <= 0

        if metricsHeight <= 0 {
            status.frame = .zero
            return
        }

        let dividerHeight = max(1.0 / max(root.contentsScale, 1), 0.5)
        divider.frame = CGRect(x: 0,
                               y: metricsHeight - dividerHeight,
                               width: width,
                               height: dividerHeight)

        let contentHeight = max(0, metricsHeight - dividerHeight)
        let padding = systemSectionContentPadding
        let columnSpacing = systemSectionColumnSpacing
        let availableSystemMetricsWidth = max(width - padding * 2, 0)

        var statsWidth = min(max(160, availableSystemMetricsWidth * 0.24), availableWidth)
        var countsWidth = min(max(160, availableSystemMetricsWidth * 0.24), max(availableSystemMetricsWidth - statsWidth - columnSpacing, 0))
        var chartWidth = max(availableSystemMetricsWidth - statsWidth - countsWidth - columnSpacing * 2, 0)

        if chartWidth < 180 && availableSystemMetricsWidth > 0 {
            let deficit = 180 - chartWidth
            let reducibleStats = max(statsWidth - 120, 0)
            let statsReduction = min(deficit / 2, reducibleStats)
            statsWidth -= statsReduction
            var remaining = max(deficit - statsReduction, 0)
            let reducibleCounts = max(countsWidth - 140, 0)
            let countsReduction = min(remaining, reducibleCounts)
            countsWidth -= countsReduction
            remaining = max(remaining - countsReduction, 0)
            chartWidth = max(availableSystemMetricsWidth - statsWidth - countsWidth - columnSpacing * 2, 0)
            if remaining > 0 && chartWidth > 0 {
                chartWidth = max(chartWidth - remaining, 0)
            }
        }

        chartWidth = max(chartWidth, 0)

        let sectionHeight = max(0, contentHeight - padding * 2)
        var currentX = padding

        let statsSection = layers.system.cpuStatsSectionLayer
        let statsHidden = statsWidth <= 0 || sectionHeight <= 0
        statsSection.isHidden = statsHidden
        statsSection.frame = CGRect(x: currentX,
                                    y: padding,
                                    width: max(0, statsWidth),
                                    height: sectionHeight)

        currentX += max(statsWidth, 0)
        if chartWidth > 0 {
            currentX += columnSpacing
        }

        let chartSection = layers.system.cpuChartSectionLayer
        let chartHidden = chartWidth <= 0 || sectionHeight <= 0
        chartSection.isHidden = chartHidden
        chartSection.frame = CGRect(x: currentX,
                                    y: padding,
                                    width: max(0, chartWidth),
                                    height: sectionHeight)

        if chartWidth > 0 {
            currentX += max(chartWidth, 0) + columnSpacing
        }

        let countsSection = layers.system.countsSectionLayer
        let countsHidden = countsWidth <= 0 || sectionHeight <= 0
        countsSection.isHidden = countsHidden
        countsSection.frame = CGRect(x: currentX,
                                     y: padding,
                                     width: max(0, countsWidth),
                                     height: sectionHeight)

        layoutCpuStatsSection(in: layers)
        layoutCpuChartSection(in: layers)
        layoutCountsSection(in: layers)

        let statusHeight: CGFloat = 18
        status.frame = CGRect(
            x: padding,
            y: padding / 2,
            width: max(0, width - padding * 2),
            height: statusHeight
        )

        layers.commandBarLayer.frame = CGRect(
            x: commandBarHorizontalInset,
            y: commandBarY,
            width: max(0, root.bounds.width - commandBarHorizontalInset * 2),
            height: commandBarHeight
        )

        layoutCommandBar()

        let tableBounds = layers.tableContainerLayer.bounds
        processTable?.layout(size: CGSize(width: tableBounds.width, height: tableBounds.height))

        quitDialog?.layout(in: root.bounds)
    }


    // MARK: Command bar and search field


    private struct CommandBarButton {
        let container: CALayer
        let backgroundLayer: CALayer
        let iconLayer: CALayer
        let textLayer: CATextLayer
        let symbolName: String
    }

    private struct CommandBarSearchField {
        let container: CALayer
        let backgroundLayer: CALayer
        let iconLayer: CALayer
        let clearButtonContainer: CALayer
        let clearButtonIconLayer: CALayer
        let placeholderLayer: CATextLayer
        let textLayer: CATextLayer
        let selectionLayer: CALayer
        let symbolName: String
        let clearSymbolName: String
    }

    private static let searchFieldID = UUID(uuid: (0x5B, 0x3A, 0x64, 0x42,
                                                  0xC6, 0x64,
                                                  0x4F, 0x4D,
                                                  0xA1, 0xA4,
                                                  0x0C, 0x3E, 0x40, 0xD5, 0xE7, 0x91))
    private let searchFieldInputController: SingleLineTextInputController<ProcessMonitorListContentController>
    private var lastSearchFilterText: String = ""
    private var restoreSearchFieldFocusOnWindowActivation = false
    private var commandBarActionButtonsEnabled = false

    private let commandBarHeight: CGFloat = 38
    private let commandBarButtonHeight: CGFloat = 36
    private let commandBarHorizontalInset: CGFloat = 16
    private let commandBarTopInset: CGFloat = 16
    private let commandBarBottomSpacing: CGFloat = 12
    private let commandBarItemSpacing: CGFloat = 12
    private let commandBarGroupSpacing: CGFloat = 16
    private let commandBarIconTextSpacing: CGFloat = 6
    private let commandBarButtonHorizontalPadding: CGFloat = 14
    private let commandBarDefaultIconSize = CGSize(width: 16, height: 16)
    private let searchFieldHeight: CGFloat = 36
    private let searchFieldMinWidth: CGFloat = 180
    private let searchFieldMaxWidth: CGFloat = 280
    private let searchFieldHorizontalPadding: CGFloat = 12
    private let searchFieldIconSpacing: CGFloat = 6
    private let searchFieldClearButtonSpacing: CGFloat = 6
    private let searchFieldCaretWidth: CGFloat = 1
    private let searchFieldClearButtonDefaultSize = CGSize(width: 14, height: 14)
    private let searchFieldClearSymbolName = "xmark.circle.fill"
    private let commandBarFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    private func commandBarBorderColor(separator: NSColor, isLightTheme: Bool) -> CGColor {
        separator.withAlphaComponent(isLightTheme ? 0.18 : 0.28).cgColor
    }

    private func commandBarCapsuleBackgroundColor() -> CGColor {
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
    }

    private func makeCommandBarButton(title: String, symbolName: String) -> CommandBarButton {
        let container = CALayer()
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

        let textLayer = makeTextLayer(font: commandBarFont, color: .black, alignment: .left)
        textLayer.truncationMode = .end
        textLayer.string = title
        container.addSublayer(textLayer)

        return CommandBarButton(container: container,
                                backgroundLayer: background,
                                iconLayer: iconLayer,
                                textLayer: textLayer,
                                symbolName: symbolName)
    }

    private func makeSearchField(symbolName: String, placeholder: String) -> CommandBarSearchField {
        let container = CALayer()
        container.backgroundColor = CGColor.clear

        let background = CALayer()
        background.cornerRadius = searchFieldHeight / 2
        background.masksToBounds = true
        background.backgroundColor = CGColor.clear
        background.borderWidth = 1
        background.borderColor = CGColor.clear
        container.addSublayer(background)

        let selectionLayer = CALayer()
        selectionLayer.backgroundColor = CGColor.clear
        selectionLayer.cornerRadius = 0
        selectionLayer.isHidden = true
        selectionLayer.masksToBounds = true
        background.addSublayer(selectionLayer)

        let iconLayer = CALayer()
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = 2
        container.addSublayer(iconLayer)

        let clearButtonContainer = CALayer()
        clearButtonContainer.backgroundColor = CGColor.clear
        clearButtonContainer.isHidden = true
        container.addSublayer(clearButtonContainer)

        let clearButtonIconLayer = CALayer()
        clearButtonIconLayer.contentsGravity = .resizeAspect
        clearButtonIconLayer.contentsScale = 2
        clearButtonIconLayer.isHidden = true
        clearButtonContainer.addSublayer(clearButtonIconLayer)

        let placeholderLayer = makeTextLayer(font: commandBarFont, color: .black, alignment: .left)
        placeholderLayer.truncationMode = .end
        placeholderLayer.string = placeholder
        container.addSublayer(placeholderLayer)

        let textLayer = makeTextLayer(font: commandBarFont, color: .black, alignment: .left)
        textLayer.truncationMode = .end
        textLayer.string = ""
        textLayer.isHidden = true
        container.addSublayer(textLayer)

        return CommandBarSearchField(container: container,
                                     backgroundLayer: background,
                                     iconLayer: iconLayer,
                                     clearButtonContainer: clearButtonContainer,
                                     clearButtonIconLayer: clearButtonIconLayer,
                                     placeholderLayer: placeholderLayer,
                                     textLayer: textLayer,
                                     selectionLayer: selectionLayer,
                                     symbolName: symbolName,
                                     clearSymbolName: searchFieldClearSymbolName)
    }

    private func refreshCommandBarIcons() {
        guard let layers = layers else { return }
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            let secondaryLabel = NSColor.secondaryLabelColor

            let stop = layers.stopButton
            requestSymbolImage(symbolName: stop.symbolName,
                               tint: label,
                               pointSize: 16,
                               weight: "semibold",
                               destinationLayer: stop.iconLayer)

            let inspect = layers.inspectButton
            requestSymbolImage(symbolName: inspect.symbolName,
                               tint: label,
                               pointSize: 16,
                               weight: "semibold",
                               destinationLayer: inspect.iconLayer)

            let search = layers.searchField
            requestSymbolImage(symbolName: search.symbolName,
                               tint: secondaryLabel,
                               pointSize: 14,
                               weight: "semibold",
                               destinationLayer: search.iconLayer)
            requestSymbolImage(symbolName: search.clearSymbolName,
                               tint: secondaryLabel,
                               pointSize: 14,
                               weight: "semibold",
                               destinationLayer: search.clearButtonIconLayer)
        }
    }

    private func updateCommandBarActionButtonsState(force: Bool = false) {
        guard let layers = layers else { return }
        let shouldEnable = model.selectedProcess != nil
        if force || shouldEnable != commandBarActionButtonsEnabled {
            commandBarActionButtonsEnabled = shouldEnable
        }

        let labelColor = NSColor.labelColor
        let backgroundOpacity: Float = shouldEnable ? 1.0 : 0.6
        let iconOpacity: Float = shouldEnable ? 1.0 : 0.4

        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            let textCgColor = (shouldEnable ? labelColor : labelColor.withAlphaComponent(0.5)).cgColor

            func applyButtonState(_ button: CommandBarButton) {
                button.backgroundLayer.opacity = backgroundOpacity
                button.iconLayer.opacity = iconOpacity
                button.textLayer.opacity = 1.0
                button.textLayer.foregroundColor = textCgColor
            }

            applyButtonState(layers.stopButton)
            applyButtonState(layers.inspectButton)
        }
    }

    private func requestSymbolImage(symbolName: String,
                                    tint: NSColor,
                                    pointSize: CGFloat,
                                    weight: String,
                                    destinationLayer: CALayer) {
        appConnection.getImage(systemSymbolName: symbolName,
                                      pointSize: pointSize,
                                      weight: weight,
                                      scale: 1.0,
                                      tintColor: tint) { [weak self, weak destinationLayer] data, width, height in
            Task { @MainActor [weak self, weak destinationLayer] in
                guard let self, let layer = destinationLayer else { return }
                guard let data = data,
                      let image = makeCGImageFromPNGData(data) else {
                    layer.contents = nil
                    layer.bounds = .zero
                    layer.isHidden = true
                    self.layoutCommandBar()
                    return
                }

                let contentsScale = max(layer.contentsScale, 2)
                layer.contentsScale = contentsScale
                let resolvedWidth = width > 0 ? CGFloat(width) : CGFloat(image.width) / contentsScale
                let resolvedHeight = height > 0 ? CGFloat(height) : CGFloat(image.height) / contentsScale
                layer.bounds = CGRect(origin: .zero, size: CGSize(width: resolvedWidth, height: resolvedHeight))
                layer.contents = image
                layer.isHidden = false
                self.layoutCommandBar()
            }
        }
    }

    private func layoutCommandBar() {
        guard let layers = layers else { return }
        let bar = layers.commandBarLayer
        let bounds = bar.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let availableWidth = bounds.width
        let buttonY = max((bounds.height - commandBarButtonHeight) / 2, 0)
        var currentX = commandBarHorizontalInset

        let stop = layers.stopButton
        let stopSize = preferredCommandBarButtonSize(stop)
        let stopMaxWidth = max(availableWidth - commandBarHorizontalInset - currentX, 0)
        let stopFrameWidth: CGFloat = stopMaxWidth >= commandBarButtonHeight ? min(stopSize.width, stopMaxWidth) : stopMaxWidth
        layoutCommandBarButton(stop,
                               frame: CGRect(x: currentX,
                                             y: buttonY,
                                             width: stopFrameWidth,
                                             height: commandBarButtonHeight))
        if !stop.container.isHidden {
            currentX += stop.container.bounds.width + commandBarItemSpacing
        }

        let inspect = layers.inspectButton
        let inspectSize = preferredCommandBarButtonSize(inspect)
        let inspectMaxWidth = max(availableWidth - commandBarHorizontalInset - currentX, 0)
        let inspectFrameWidth: CGFloat = inspectMaxWidth >= commandBarButtonHeight ? min(inspectSize.width, inspectMaxWidth) : inspectMaxWidth
        layoutCommandBarButton(inspect,
                               frame: CGRect(x: currentX,
                                             y: buttonY,
                                             width: inspectFrameWidth,
                                             height: commandBarButtonHeight))
        if !inspect.container.isHidden {
            currentX += inspect.container.bounds.width + commandBarGroupSpacing
        }

        let search = layers.searchField
        let remainingWidth = max(availableWidth - commandBarHorizontalInset - currentX, 0)
        var desiredWidth = min(searchFieldMaxWidth, remainingWidth)
        if remainingWidth >= searchFieldMinWidth {
            desiredWidth = max(searchFieldMinWidth, desiredWidth)
        }

        if desiredWidth <= 0 {
            search.container.isHidden = true
            search.container.frame = .zero
            search.backgroundLayer.frame = .zero
            search.iconLayer.frame = .zero
            search.placeholderLayer.frame = .zero
            search.textLayer.frame = .zero
            search.selectionLayer.frame = .zero
        } else {
            let searchWidth = desiredWidth
            let searchX = max(currentX, availableWidth - commandBarHorizontalInset - searchWidth)
            let frame = CGRect(x: searchX,
                               y: max((bounds.height - searchFieldHeight) / 2, 0),
                               width: searchWidth,
                               height: searchFieldHeight)
            layoutSearchField(search, frame: frame)
        }

        updateSearchFieldDisplay()
        updateSearchFieldFocusAppearance()
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

    private func layoutSearchField(_ field: CommandBarSearchField, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else {
            field.container.isHidden = true
            field.container.frame = .zero
            field.backgroundLayer.frame = .zero
            field.iconLayer.frame = .zero
            field.clearButtonContainer.frame = .zero
            field.placeholderLayer.frame = .zero
            field.textLayer.frame = .zero
            field.selectionLayer.frame = .zero
            return
        }
        field.container.isHidden = false
        field.container.frame = frame
        field.backgroundLayer.frame = CGRect(origin: .zero, size: frame.size)
        field.backgroundLayer.cornerRadius = frame.height / 2

        let iconHidden = field.iconLayer.isHidden || field.iconLayer.contents == nil
        let iconWidth = iconHidden ? 0 : max(field.iconLayer.bounds.width, commandBarDefaultIconSize.width)
        let iconHeight = iconHidden ? 0 : max(field.iconLayer.bounds.height, commandBarDefaultIconSize.height)
        let iconX = searchFieldHorizontalPadding
        let iconY = max((frame.height - iconHeight) / 2, 0)
        if iconWidth > 0 && iconHeight > 0 {
            field.iconLayer.frame = CGRect(x: iconX, y: iconY, width: iconWidth, height: iconHeight)
        } else {
            field.iconLayer.frame = CGRect(x: iconX, y: max((frame.height - commandBarDefaultIconSize.height) / 2, 0), width: 0, height: 0)
        }

        let clearVisible = !field.clearButtonContainer.isHidden
        var clearWidth: CGFloat = 0
        var clearHeight: CGFloat = 0
        if clearVisible {
            let iconBounds = field.clearButtonIconLayer.bounds
            clearWidth = iconBounds.width > 0 ? iconBounds.width : searchFieldClearButtonDefaultSize.width
            clearHeight = iconBounds.height > 0 ? iconBounds.height : searchFieldClearButtonDefaultSize.height
        }

        if clearVisible && clearWidth > 0 && clearHeight > 0 {
            let clearX = max(searchFieldHorizontalPadding,
                             frame.width - searchFieldHorizontalPadding - clearWidth)
            let clearY = max((frame.height - clearHeight) / 2, 0)
            field.clearButtonContainer.frame = CGRect(x: clearX, y: clearY, width: clearWidth, height: clearHeight)
            field.clearButtonIconLayer.frame = CGRect(origin: .zero, size: CGSize(width: clearWidth, height: clearHeight))
            field.clearButtonIconLayer.isHidden = false
        } else {
            field.clearButtonContainer.frame = .zero
            field.clearButtonIconLayer.frame = .zero
            field.clearButtonIconLayer.isHidden = true
        }

        let rightInset = searchFieldHorizontalPadding + (clearVisible && clearWidth > 0 ? (searchFieldClearButtonSpacing + clearWidth) : 0)
        let textStart = iconWidth > 0 ? iconX + iconWidth + searchFieldIconSpacing : iconX
        let textAvailableWidth = max(frame.width - textStart - rightInset, 0)
        let preferredSize = field.placeholderLayer.preferredFrameSize()
        let textHeight = min(preferredSize.height, frame.height)
        let textY = max((frame.height - textHeight) / 2, 0)
        field.placeholderLayer.frame = CGRect(x: textStart,
                                              y: textY,
                                              width: textAvailableWidth,
                                              height: textHeight)
        field.textLayer.frame = CGRect(x: textStart,
                                       y: textY,
                                       width: textAvailableWidth,
                                       height: textHeight)
        field.selectionLayer.frame = CGRect(x: textStart,
                                            y: textY,
                                            width: 0,
                                            height: textHeight)
        field.selectionLayer.cornerRadius = 0
    }

    private func updateSearchFieldDisplay() {
        guard let layers = layers else { return }

        let field = layers.searchField

        let text = searchFieldInputController.text
        let isFocused = searchFieldInputController.isFocused
        let selection = searchFieldInputController.selectionRange

        let showPlaceholder = text.isEmpty && !isFocused
        field.placeholderLayer.isHidden = !showPlaceholder
        field.textLayer.isHidden = text.isEmpty
        field.textLayer.string = text
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            field.textLayer.foregroundColor = NSColor.textColor.cgColor
        }
        field.clearButtonContainer.isHidden = text.isEmpty
        layoutSearchField(field, frame: field.container.frame)

        let textFrame = field.textLayer.frame
        let textBaseX = textFrame.minX
        let textBaseY = textFrame.minY
        let textHeight = textFrame.height
        let maxWidth = max(textFrame.width, 0)
        let backgroundWidth = field.backgroundLayer.bounds.width
        var cachedLine: CTLine?
        if !text.isEmpty && maxWidth > 0 {
            cachedLine = makeSearchFieldLine(for: text)
        }

        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            let selectedTextBackground = NSColor.selectedTextBackgroundColor
            let inactiveSelectionBase = NSColor.unemphasizedSelectedTextBackgroundColor
            let isLightTheme = NSColor.controlBackgroundColor.am_brightness > 0.6
            let selectionColor = (isFocused && model.isWindowActive ?
                                  selectedTextBackground.cgColor :
                                    inactiveSelectionBase.withAlphaComponent(isLightTheme ? 0.75 : 0.9).cgColor)

            if let range = selection, isFocused, let line = cachedLine {
                let offsets = selectionOffsets(line: line,
                                               text: text,
                                               range: range,
                                               maxWidth: maxWidth)
                let startX = textBaseX + offsets.start
                let endX = textBaseX + offsets.end
                let width = max(0, min(endX - startX, maxWidth - offsets.start))
                let availableWidth = max(0, backgroundWidth - startX)
                let clampedWidth = min(width, availableWidth)
                if clampedWidth > 0.5 {
                    field.selectionLayer.isHidden = false
                    field.selectionLayer.frame = CGRect(x: startX,
                                                        y: textBaseY,
                                                        width: clampedWidth,
                                                        height: textHeight)
                    field.selectionLayer.backgroundColor = selectionColor
                } else {
                    field.selectionLayer.isHidden = true
                    field.selectionLayer.frame = CGRect(x: startX,
                                                        y: textBaseY,
                                                        width: 0,
                                                        height: textHeight)
                    field.selectionLayer.backgroundColor = selectionColor
                }
            } else {
                field.selectionLayer.isHidden = true
                field.selectionLayer.frame = CGRect(x: field.textLayer.frame.minX,
                                                    y: field.textLayer.frame.minY,
                                                    width: 0,
                                                    height: field.textLayer.frame.height)
                field.selectionLayer.backgroundColor = selectionColor
            }
        }
        sendSearchFieldCursorUpdate(cachedLine: cachedLine)
    }

    private func updateSearchFieldFocusAppearance() {
        guard let layers = layers else { return }
        let field = layers.searchField
        let isFocused = searchFieldInputController.isFocused && model.isWindowActive

        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            let separator = NSColor.separatorColor
            let keyboardFocus = NSColor.keyboardFocusIndicatorColor
            let selectedTextBackground = NSColor.selectedTextBackgroundColor
            let inactiveSelectionBase = NSColor.unemphasizedSelectedTextBackgroundColor
            let isLightTheme = NSColor.controlBackgroundColor.am_brightness > 0.6

            field.backgroundLayer.borderColor = isFocused ?
            keyboardFocus.withAlphaComponent(isLightTheme ? 0.9 : 0.7).cgColor :
            commandBarBorderColor(separator: separator, isLightTheme: isLightTheme)
            field.backgroundLayer.borderWidth = isFocused ? 1.5 : 1
            field.selectionLayer.backgroundColor = isFocused ?
            selectedTextBackground.cgColor :
            inactiveSelectionBase.withAlphaComponent(isLightTheme ? 0.75 : 0.9).cgColor
        }
    }

    private func makeSearchFieldLine(for text: String) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.font: commandBarFont]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }


    private func offsetForSearchFieldCharacter(line: CTLine, text: String, index: Int, maxWidth: CGFloat) -> CGFloat {
        let utf16Index = utf16Offset(forCharacterIndex: index, in: text)
        var secondaryOffset: CGFloat = 0
        let primary = CTLineGetOffsetForStringIndex(line, utf16Index, &secondaryOffset)
        let offset = max(primary, secondaryOffset)
        if offset.isFinite {
            return min(max(offset, 0), maxWidth)
        }
        return 0
    }

    private func selectionOffsets(line: CTLine, text: String, range: Range<Int>, maxWidth: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let startOffset = offsetForSearchFieldCharacter(line: line, text: text, index: range.lowerBound, maxWidth: maxWidth)
        let endOffset = offsetForSearchFieldCharacter(line: line, text: text, index: range.upperBound, maxWidth: maxWidth)
        return (start: min(startOffset, maxWidth), end: min(max(endOffset, startOffset), maxWidth))
    }

    private func characterIndexForSearchField(xPosition: CGFloat) -> Int {
        guard let layers = layers else { return 0 }
        let field = layers.searchField
        let text = searchFieldInputController.text
        let textFrame = field.textLayer.frame
        let localX = max(0, min(xPosition - textFrame.minX, textFrame.width))
        guard !text.isEmpty, textFrame.width > 0 else { return 0 }
        let line = makeSearchFieldLine(for: text)
        let utf16Index = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        if utf16Index == kCFNotFound {
            return text.count
        }
        return characterIndex(forUTF16: utf16Index, in: text)
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

    private func updateInputMode() {
        appConnection.setInputMode(searchFieldInputController.isFocused ? .textInput : .rawKeys)
    }

    private func updateEditingCapabilities() {
        let outer = searchFieldInputController.currentEditingCapabilities()
        let capabilities = OuterframeContentEditingCapabilities(
            canCopy: outer.canCopy,
            canCut: outer.canCut,
            acceptablePasteboardTypeIdentifiers: outer.acceptablePasteboardTypeIdentifiers
        )
        appConnection.setPasteboardCapabilities(capabilities)
    }

    private func searchFieldCursorRect(_ field: CommandBarSearchField, cachedLine: CTLine?) -> CGRect {
        let textFrame = field.textLayer.frame
        let contentsScale = max(field.textLayer.contentsScale, 1)
        let cursorWidth = max(searchFieldCaretWidth, 1 / contentsScale)
        let maxWidth = max(textFrame.width, 0)
        let offset: CGFloat
        if let cachedLine, !searchFieldInputController.text.isEmpty && maxWidth > 0 {
            offset = offsetForSearchFieldCharacter(line: cachedLine,
                                                   text: searchFieldInputController.text,
                                                   index: searchFieldInputController.cursorPosition,
                                                   maxWidth: maxWidth)
        } else {
            offset = 0
        }

        let proposedX = min(max(textFrame.minX + offset, textFrame.minX), textFrame.minX + maxWidth)
        let maxCursorX = field.backgroundLayer.bounds.width - cursorWidth
        let limitedX = max(textFrame.minX, min(proposedX, maxCursorX))
        return CGRect(x: limitedX,
                      y: textFrame.minY,
                      width: cursorWidth,
                      height: textFrame.height)
    }

    private func sendSearchFieldCursorUpdate(cachedLine: CTLine? = nil) {
        guard let layers = layers else {
            appConnection.sendTextCursorUpdate(cursors: [])
            return
        }

        let field = layers.searchField
        let isFocused = searchFieldInputController.isFocused
        let hasSelection = searchFieldInputController.hasSelection

        if isFocused && !hasSelection {
            let cursorFrame = searchFieldCursorRect(field, cachedLine: cachedLine)
            let rootPosition = field.container.convert(cursorFrame.origin, to: layers.rootLayer)

            // Convert from CALayer's bottom-left coordinates to top-left coordinates
            // (OuterframeView expects y=0 at top)
            let rootHeight = layers.rootLayer.bounds.height
            let topLeftY = rootHeight - rootPosition.y - cursorFrame.height
            let cursor = OuterframeContentTextCursorSnapshot(fieldID: Self.searchFieldID,
                                                             rectX: Float32(rootPosition.x),
                                                             rectY: Float32(topLeftY),
                                                             rectWidth: Float32(cursorFrame.width),
                                                             rectHeight: Float32(cursorFrame.height),
                                                             visible: true)
            appConnection.sendTextCursorUpdate(cursors: [cursor])
        } else {
            appConnection.sendTextCursorUpdate(cursors: [])
        }
    }

    private func focusSearchField(selectAll: Bool = false) {
        searchFieldInputController.focus(selectAll: selectAll)
    }

    private func blurSearchField() {
        searchFieldInputController.blur()
    }

    private func clearSearchField() {
        let wasFocused = searchFieldInputController.isFocused
        guard !searchFieldInputController.text.isEmpty else {
            if !wasFocused {
                focusSearchField(selectAll: false)
            }
            return
        }
        searchFieldInputController.setText("")
        focusSearchField(selectAll: false)
    }

    private func handleCommandBarMouseDown(at point: CGPoint,
                                           modifierFlags: NSEvent.ModifierFlags,
                                           clickCount: Int) -> Bool {
        guard let layers = layers else { return false }
        let root = layers.rootLayer
        let bar = layers.commandBarLayer
        let localPoint = bar.convert(point, from: root)

        if bar.bounds.contains(localPoint) {
            let stop = layers.stopButton
            if !stop.container.isHidden,
               stop.container.frame.contains(localPoint) {
                if let selectedProcess = model.selectedProcess {
                    promptToStopProcess(selectedProcess)
                }
                return true
            }

            let inspect = layers.inspectButton
            if !inspect.container.isHidden,
               inspect.container.frame.contains(localPoint) {
                if let selectedProcess = model.selectedProcess {
                    launchProcessInspector(selectedProcess)
                }
                return true
            }

            let search = layers.searchField
            if search.container.frame.contains(localPoint) {
                let pointInSearch = search.container.convert(localPoint, from: bar)

                if !search.clearButtonContainer.isHidden,
                   search.clearButtonContainer.frame.contains(pointInSearch) {
                    clearSearchField()
                    return true
                }

                let wasFocused = searchFieldInputController.isFocused
                if !wasFocused {
                    focusSearchField(selectAll: clickCount >= 3)
                }

                let index = characterIndexForSearchField(xPosition: pointInSearch.x)
                switch clickCount {
                case 3...:
                    searchFieldInputController.selectAll()
                case 2:
                    searchFieldInputController.selectWord(at: index)
                default:
                    let modifySelection = modifierFlags.contains(.shift) && wasFocused
                    searchFieldInputController.setCursorPosition(index, modifySelection: modifySelection)
                }
                updateSearchFieldDisplay()
            } else {
                if searchFieldInputController.isFocused {
                    blurSearchField()
                }
                clearSelectedProcess()
            }
            return true
        } else {
            if searchFieldInputController.isFocused {
                blurSearchField()
            }
            return false
        }
    }

    private func handleCommandBarRightMouseDown(at point: CGPoint,
                                                modifierFlags: NSEvent.ModifierFlags,
                                                clickCount: Int) -> Bool {
        guard let layers = layers else { return false }
        let root = layers.rootLayer
        let bar = layers.commandBarLayer
        let localPoint = bar.convert(point, from: root)

        guard bar.bounds.contains(localPoint) else {
            return false
        }

        let search = layers.searchField
        guard search.container.frame.contains(localPoint) else {
            return true
        }

        let pointInSearch = search.container.convert(localPoint, from: bar)
        let wasFocused = searchFieldInputController.isFocused
        if !wasFocused {
            focusSearchField()
        }

        if !searchFieldInputController.hasSelection {
            let index = characterIndexForSearchField(xPosition: pointInSearch.x)
            searchFieldInputController.setCursorPosition(index, modifySelection: false)
        }

        updateSearchFieldDisplay()
        updateEditingCapabilities()

        let selectedText = searchFieldInputController.selectedTextContent() ?? ""
        let attributedText = NSAttributedString(string: selectedText,
                                                attributes: [.font: commandBarFont])
        appConnection.showContextMenu(for: attributedText, at: point)
        return true
    }

    private func clearSelectedProcess() {
        processTable?.clearSelection()
    }

    func promptToStopProcess(_ process: ProcessMonitorListModel.ProcessInfo) {
        blurSearchField()
        updateInputMode()

        guard let layers = layers else { return }

        quitDialog?.dismiss()
        quitDialog = ProcessQuitDialog(outerframeHost: outerframeHost,
                                       appearance: model.effectiveAppearance,
                                       hostLayer: layers.rootLayer,
                                       pid: process.pid,
                                       command: process.name) { [weak self] action in
            guard let self else { return }
            switch action {
            case .cancel:
                break
            case .quit(let force):
                self.sendTerminationRequest(pid: process.pid, command: process.name, force: force)
            }
            self.quitDialog = nil
        }
    }

    func launchProcessInspector(_ process: ProcessMonitorListModel.ProcessInfo) {

        blurSearchField()
        updateInputMode()

        let displayString = "PID \(process.pid)"
        let preferredSize = CGSize(width: 640, height: 730)
        guard let url = detailURL(forPID: process.pid) else { return }
        appConnection.openNewWindow(with: url,
                                    displayString: displayString,
                                    preferredSize: preferredSize)
    }

    private func sendTerminationRequest(pid: Int, command: String, force: Bool) {
        guard pid > 0, let apiEndpoint else { return }

        let actionPath = force ? "force-quit" : "quit"
        let requestURL = apiEndpoint
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

        func terminationDisplayName(pid: Int, command: String) -> String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "PID \(pid)"
            }
            return "\(trimmed) (\(pid))"
        }

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

        struct TerminationServerResponse: Decodable {
            let success: Bool
            let error: String?
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

    private func terminationErrorDescription(data: Data?, response: HTTPURLResponse) -> String {
        if let data,
           let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return body
        }
        return HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    }

    // MARK: System metrics

    private struct SystemMetricsLayers {
        let containerLayer: CALayer
        let machineDividerLayer: CALayer
        let cpuStatsSection: CPUStatsSection
        let cpuChartSectionLayer: CALayer
        let cpuChartHostLayer: CALayer
        let countsSectionLayer: CALayer
        let threadsValueLayer: CATextLayer
        let processesValueLayer: CATextLayer
        let threadsLabelLayer: CATextLayer
        let processesLabelLayer: CATextLayer

        @MainActor
        var cpuStatsSectionLayer: CALayer {
            cpuStatsSection.rootLayer
        }
    }

    typealias CPUSample = ProcessMonitorListModel.CPUSample

    private struct SystemCountSample {
        let timestamp: TimeInterval
        let processCount: Int?
        let threadCount: Int?
    }

    private var cpuUserColor: NSColor = .systemBlue
    private var cpuSystemColor: NSColor = .systemRed
    private var cpuIdleColor: NSColor = .labelColor
    private let cpuTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let systemSectionPreferredHeight: CGFloat = 150
    private let systemSectionMinimumHeight: CGFloat = 110
    private let systemSectionContentPadding: CGFloat = 16
    private let systemSectionColumnSpacing: CGFloat = 24
    private let cpuStatsRowSpacing: CGFloat = 8
    private let cpuStatsLabelFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let cpuStatsValueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let countsLabelFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private var currentSystemMetrics: SystemMetrics?

    private func layoutCpuStatsSection(in layers: Layers) {
        layers.system.cpuStatsSection.updateLayout()
    }

    private func layoutCountsSection(in layers: Layers) {
        let countsSection = layers.system.countsSectionLayer
        let threadsValue = layers.system.threadsValueLayer
        let processesValue = layers.system.processesValueLayer
        let threadsLabel = layers.system.threadsLabelLayer
        let processesLabel = layers.system.processesLabelLayer

        let width = countsSection.bounds.width
        let height = countsSection.bounds.height
        if width <= 0 || height <= 0 {
            return
        }

        let valueLineHeight = numericFont.ascender - numericFont.descender
        let labelLineHeight = countsLabelFont.ascender - countsLabelFont.descender
        let labelSpacing: CGFloat = 4
        let rowSpacing: CGFloat = 16

        var currentY: CGFloat = 0
        threadsValue.frame = CGRect(x: 0, y: currentY, width: width, height: valueLineHeight)
        currentY += valueLineHeight + labelSpacing
        threadsLabel.frame = CGRect(x: 0, y: currentY, width: width, height: labelLineHeight)
        currentY += labelLineHeight + rowSpacing

        processesValue.frame = CGRect(x: 0, y: currentY, width: width, height: valueLineHeight)
        currentY += valueLineHeight + labelSpacing
        processesLabel.frame = CGRect(x: 0, y: currentY, width: width, height: labelLineHeight)
    }

    private func refreshAggregatedSystemDisplay() {
        let timeWindow: ClosedRange<TimeInterval>?
        if let bounds = historyTimeBounds(),
           let range = model.selection.timeBasedRange(boundEnd: bounds.end) {
            timeWindow = range
        } else if let bounds = historyTimeBounds() {
            timeWindow = bounds.start...bounds.end
        } else {
            timeWindow = nil
        }

        let cpuStats: SystemMetrics.CPU?
        if model.cpuHistory.isEmpty {
            cpuStats = currentSystemMetrics?.cpu
        } else {
            var totalUser: Double = 0
            var totalSystem: Double = 0
            var totalIdle: Double = 0
            var count: Double = 0
            for sample in model.cpuHistory {
                if let timeWindow, sample.timestamp < timeWindow.lowerBound || sample.timestamp > timeWindow.upperBound {
                    continue
                }
                totalUser += sample.user
                totalSystem += sample.system
                totalIdle += sample.idle
                count += 1
            }
            if count > 0 {
                cpuStats = SystemMetrics.CPU(userPercent: totalUser / count,
                                             systemPercent: totalSystem / count,
                                             idlePercent: totalIdle / count)
            } else {
                cpuStats = currentSystemMetrics?.cpu
            }
        }

        guard let layers = layers else { return }
        let cpuValues = CPUStatsSection.Values(
            user: cpuStats?.userPercent,
            system: cpuStats?.systemPercent,
            idle: cpuStats?.idlePercent
        )
        layers.system.cpuStatsSection.updateValues(cpuValues,
                                                  logicalCpuCount: model.logicalCpuCount)

        let threadRange = countRange(for: \.threadCount, in: timeWindow)
            ?? valueRange(from: currentSystemMetrics?.threadCount)
        layers.system.threadsValueLayer.string = formattedValueRange(threadRange)
        layers.system.processesValueLayer.string = formattedProcessCount(metrics: currentSystemMetrics)
    }

    // MARK: CPU History chart

    private var currentHistoryCursor: PluginCursorType = .arrow

    private var countHistory: [SystemCountSample] = []

    private func layoutCpuChartSection(in layers: Layers) {
        let chartSection = layers.system.cpuChartSectionLayer
        let hostLayer = layers.system.cpuChartHostLayer

        let width = chartSection.bounds.width
        let height = chartSection.bounds.height
        if width <= 0 || height <= 0 {
            hostLayer.frame = .zero
            cpuChart?.layout(in: .zero)
            return
        }

        let inset: CGFloat = 0
        let hostFrame = chartSection.bounds.insetBy(dx: inset, dy: inset)
        hostLayer.frame = hostFrame
        cpuChart?.layout(in: hostLayer.bounds)
    }

    private func countRange(for keyPath: KeyPath<SystemCountSample, Int?>,
                            in range: ClosedRange<TimeInterval>?) -> ValueRange? {
        guard !countHistory.isEmpty else { return nil }
        var minValue: Int?
        var maxValue: Int?
        for sample in countHistory {
            if let range,
               (sample.timestamp < range.lowerBound || sample.timestamp > range.upperBound) {
                continue
            }
            guard let value = sample[keyPath: keyPath], value > 0 else { continue }
            if let currentMin = minValue {
                if value < currentMin {
                    minValue = value
                }
            } else {
                minValue = value
            }
            if let currentMax = maxValue {
                if value > currentMax {
                    maxValue = value
                }
            } else {
                maxValue = value
            }
        }
        if let minValue, let maxValue {
            return ValueRange(min: minValue, max: maxValue)
        }
        return nil
    }

    private func valueRange(from value: Int?) -> ValueRange? {
        guard let value, value > 0 else { return nil }
        return ValueRange(min: value, max: value)
    }

    private func historyTimeBounds() -> (start: TimeInterval, end: TimeInterval)? {
        guard let last = model.cpuHistory.last?.timestamp else {
            return nil
        }
        let duration = max(maxCpuHistoryDuration, 0.001)
        return (last - duration, last)
    }

    private func trimHistory() -> Bool {
        guard let lastTimestamp = model.cpuHistory.last?.timestamp else { return false }
        let cutoff = lastTimestamp - maxCpuHistoryDuration

        var trimmed = false

        if let keepIndex = model.cpuHistory.firstIndex(where: { $0.timestamp >= cutoff }) {
            if keepIndex > 0 {
                trimmed = true
                model.cpuHistory.removeFirst(keepIndex)
            }
        }

        if let keepIndex = countHistory.firstIndex(where: { $0.timestamp >= cutoff }),
           keepIndex > 0 {
            trimmed = true
            countHistory.removeFirst(keepIndex)
        }

        return trimmed
    }

    private func clampSelectionToBounds() -> Bool {
        if model.isShowingHistoricalData {
            return false
        }
        guard let bounds = historyTimeBounds() else { return false }

        var changed = false

        switch model.selection {
        case .range(let range):
            switch range {
            case .absolute(let actualRange):
                let lower = max(actualRange.lowerBound, bounds.start)
                var upper = min(actualRange.upperBound, bounds.end)
                if upper < lower {
                    upper = lower
                }
                if lower != actualRange.lowerBound || upper != actualRange.upperBound {
                    model.selection = .range(range: .absolute(range: lower...upper))
                    changed = true
                }
            case .moving:
                break
            }
        case .point(let time):
            switch time {
            case .absolute(let actualTime):
                let clamped = min(max(actualTime, bounds.start), bounds.end)
                if clamped != actualTime {
                    model.selection = .point(time: .absolute(time: clamped))
                    changed = true
                }
            case .now:
                break
            }
        case .none:
            break
        }

        return changed
    }

    // MARK: Status

    func showStatus(_ message: String?) {

        guard let layers else { return }
        if let message = message {
            layers.statusLayer.string = message
            layers.statusLayer.isHidden = false
        } else {
            layers.statusLayer.string = ""
            layers.statusLayer.isHidden = true
        }

        currentStatusText = message
    }
}



private struct SystemMetrics {
    struct CPU {
        let userPercent: Double
        let systemPercent: Double
        let idlePercent: Double
    }

    let cpu: CPU?
    let processCount: Int
    let visibleProcessCount: Int
    let threadCount: Int
    let logicalCpuCount: Int
}


struct ProcessEntry {
    let pid: Int
    let cpuPercent: Double
    let memoryKilobytes: Int
    let cpuTimeMilliseconds: Int
    let isKernelThread: Bool
    let user: String
    let command: String
    let previousIndex: Int?
}


private struct FullViewportContents {
    let snapshotIndex: UInt64
    let snapshotTimestamp: Double
    let entries: [ProcessEntry]
    let additionalEntries: [(Int, ProcessEntry)]
    let systemMetrics: SystemMetrics?
    let windowStart: Int
    let windowTotal: Int
}


private func parseFullViewportContents(_ data: Data) -> (FullViewportContents, Int)? {
    let messageHeaderSize = MemoryLayout<Double>.size * 3
        + MemoryLayout<UInt32>.size * 3
        + MemoryLayout<UInt64>.size
        + 8

    guard data.count >= messageHeaderSize else { return nil }
    let countOffset = MemoryLayout<Double>.size
    let windowStartOffset = countOffset + MemoryLayout<UInt32>.size
    let windowTotalOffset = windowStartOffset + MemoryLayout<UInt32>.size
    let snapshotOffset = windowTotalOffset + MemoryLayout<UInt32>.size
    let selectionStartOffset = snapshotOffset + MemoryLayout<UInt64>.size
    let selectionEndOffset = selectionStartOffset + MemoryLayout<Double>.size
    guard let snapshotTimestamp = readDoubleLE(from: data, offset: 0),
          let entryCountRaw = readUInt32LE(from: data, offset: countOffset),
          let windowStartRaw = readUInt32LE(from: data, offset: windowStartOffset),
          let windowTotalRaw = readUInt32LE(from: data, offset: windowTotalOffset),
          let snapshotIndex = readUInt64LE(from: data, offset: snapshotOffset),
          // selectionStartValue
          nil != readDoubleLE(from: data, offset: selectionStartOffset),
          // selectionEndValue
          nil != readDoubleLE(from: data, offset: selectionEndOffset) else {
        return nil
    }

    var offset = messageHeaderSize
    let entryCount = Int(entryCountRaw)
    var entries: [ProcessEntry] = []
    entries.reserveCapacity(entryCount)

    let entryFixedSize = MemoryLayout<UInt32>.size
        + MemoryLayout<Float>.size
        + MemoryLayout<UInt64>.size * 2
        + MemoryLayout<UInt32>.size * 2
        + MemoryLayout<Int32>.size
        + MemoryLayout<UInt8>.size

    for _ in 0..<entryCount {
        guard data.count >= offset + entryFixedSize,
              let pidValue = readUInt32LE(from: data, offset: offset),
              let cpuValue = readFloatLE(from: data, offset: offset + MemoryLayout<UInt32>.size) else {
            return nil
        }

        let memoryOffset = offset + MemoryLayout<UInt32>.size + MemoryLayout<Float>.size
        guard let memoryValue = readUInt64LE(from: data, offset: memoryOffset),
              let cpuTimeValue = readUInt64LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size),
              let userLength = readUInt32LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2),
              let commandLength = readUInt32LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size),
              let previousIndexRaw = readUInt32LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size * 2),
              let flags = readUInt8(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size * 2 + MemoryLayout<Int32>.size) else {
            return nil
        }

        let userLengthInt = Int(userLength)
        let commandLengthInt = Int(commandLength)
        let totalLength = entryFixedSize + userLengthInt + commandLengthInt
        guard data.count >= offset + totalLength else { return nil }

        let userStart = offset + entryFixedSize
        let commandStart = userStart + userLengthInt
        guard let user = stringFromData(data, offset: userStart, length: userLengthInt),
              let command = stringFromData(data, offset: commandStart, length: commandLengthInt) else {
            return nil
        }

        let previousIndexValue = Int32(bitPattern: previousIndexRaw)
        let previousIndex = previousIndexValue >= 0 ? Int(previousIndexValue) : nil

        let entry = ProcessEntry(pid: Int(pidValue),
                                 cpuPercent: Double(cpuValue),
                                 memoryKilobytes: Int(memoryValue),
                                 cpuTimeMilliseconds: Int(cpuTimeValue),
                                 isKernelThread: (flags & 0x1) != 0,
                                 user: user,
                                 command: command,
                                 previousIndex: previousIndex)
        entries.append(entry)
        offset += totalLength
    }

    let systemMetricsBlockSize = MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3 + MemoryLayout<UInt32>.size * 4

    guard data.count >= offset + systemMetricsBlockSize else { return nil }
    let metricsFlagOffset = offset
    let metricsAvailable = (readUInt8(from: data, offset: metricsFlagOffset) ?? 0) != 0
    let userValue = readFloatLE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size)
    let systemValue = readFloatLE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size)
    let idleValue = readFloatLE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 2)
    let processCountValue = readUInt32LE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3)
    let visibleProcessCountValue = readUInt32LE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3 + MemoryLayout<UInt32>.size)
    let threadCountValue = readUInt32LE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3 + MemoryLayout<UInt32>.size * 2)
    let logicalCpuCountValue = readUInt32LE(from: data, offset: metricsFlagOffset + MemoryLayout<UInt8>.size + MemoryLayout<Float>.size * 3 + MemoryLayout<UInt32>.size * 3)

    var systemMetrics: SystemMetrics?
    if metricsAvailable,
       let userValue,
       let systemValue,
       let idleValue,
       let processCountValue,
       let visibleProcessCountValue,
       let threadCountValue,
       let logicalCpuCountValue {
        let cpuMetrics = SystemMetrics.CPU(userPercent: Double(userValue),
                                           systemPercent: Double(systemValue),
                                           idlePercent: Double(idleValue))
        systemMetrics = SystemMetrics(cpu: cpuMetrics,
                                      processCount: Int(processCountValue),
                                      visibleProcessCount: Int(visibleProcessCountValue),
                                      threadCount: Int(threadCountValue),
                                      logicalCpuCount: Int(logicalCpuCountValue))
    }
    offset += systemMetricsBlockSize

    guard let additionalCountRaw = readUInt32LE(from: data, offset: offset) else { return nil }
    offset += MemoryLayout<UInt32>.size
    let additionalCount = Int(additionalCountRaw)
    var additionalEntries: [(Int, ProcessEntry)] = []
    additionalEntries.reserveCapacity(additionalCount)
    for _ in 0..<additionalCount {
        guard let currentIndexRaw = readUInt32LE(from: data, offset: offset) else { return nil }
        let currentIndex = Int(currentIndexRaw)
        let entryStart = offset + MemoryLayout<UInt32>.size
        guard data.count >= entryStart + entryFixedSize,
              let pidValue = readUInt32LE(from: data, offset: entryStart),
              let cpuValue = readFloatLE(from: data, offset: entryStart + MemoryLayout<UInt32>.size) else {
            return nil
        }

        let memoryOffset = entryStart + MemoryLayout<UInt32>.size + MemoryLayout<Float>.size
        guard let memoryValue = readUInt64LE(from: data, offset: memoryOffset),
              let cpuTimeValue = readUInt64LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size),
              let userLength = readUInt32LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2),
              let commandLength = readUInt32LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size),
              let previousIndexRaw = readUInt32LE(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size * 2),
              let flags = readUInt8(from: data, offset: memoryOffset + MemoryLayout<UInt64>.size * 2 + MemoryLayout<UInt32>.size * 2 + MemoryLayout<Int32>.size) else {
            return nil
        }

        let userLengthInt = Int(userLength)
        let commandLengthInt = Int(commandLength)
        let totalLength = entryFixedSize + userLengthInt + commandLengthInt
        guard data.count >= entryStart + totalLength else { return nil }

        let userStart = entryStart + entryFixedSize
        let commandStart = userStart + userLengthInt
        guard let user = stringFromData(data, offset: userStart, length: userLengthInt),
              let command = stringFromData(data, offset: commandStart, length: commandLengthInt) else {
            return nil
        }

        let previousIndexValue = Int32(bitPattern: previousIndexRaw)
        let previousIndex = previousIndexValue >= 0 ? Int(previousIndexValue) : nil

        let entry = ProcessEntry(pid: Int(pidValue),
                                 cpuPercent: Double(cpuValue),
                                 memoryKilobytes: Int(memoryValue),
                                 cpuTimeMilliseconds: Int(cpuTimeValue),
                                 isKernelThread: (flags & 0x1) != 0,
                                 user: user,
                                 command: command,
                                 previousIndex: previousIndex)
        additionalEntries.append((currentIndex, entry))
        offset = entryStart + totalLength
    }

    return (FullViewportContents(snapshotIndex: snapshotIndex, snapshotTimestamp: snapshotTimestamp, entries: entries, additionalEntries: additionalEntries, systemMetrics: systemMetrics, windowStart: Int(windowStartRaw), windowTotal: Int(windowTotalRaw)),
            offset)
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

private func formattedValueRange(_ range: ValueRange?) -> String {
    guard let range else { return "—" }
    if range.min == range.max {
        return formattedInteger(range.min)
    }
    return "\(formattedInteger(range.min)) – \(formattedInteger(range.max))"
}

private func formattedProcessCount(metrics: SystemMetrics?) -> String {
    guard let metrics else { return "—" }

    let visible = metrics.visibleProcessCount
    let total = metrics.processCount
    if visible == total {
        return formattedInteger(visible)
    }
    return "\(formattedInteger(visible)) of \(formattedInteger(total))"
}

private func boundingSize(for text: String, font: NSFont, width: CGFloat) -> CGSize {
    guard width.isFinite, width > 0 else { return .zero }
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let maxSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    let rect = attributed.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(rect.width), height: ceil(rect.height))
}

private func makeTextLayer(font: NSFont, color: NSColor, alignment: CATextLayerAlignmentMode) -> CATextLayer {
    let textLayer = CATextLayer()
    textLayer.font = font
    textLayer.fontSize = font.pointSize
    textLayer.foregroundColor = color.cgColor
    textLayer.alignmentMode = alignment
    textLayer.contentsScale = 2
    textLayer.truncationMode = .end
    return textLayer
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


private struct ValueRange: Equatable {
    let min: Int
    let max: Int
}

private final class ProcessStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: ProcessMonitorListContentController?
    private var streamBuffer = Data()

    init(owner: ProcessMonitorListContentController) {
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

        streamBuffer.append(data)

        while let (parsed, offset) = parseFullViewportContents(streamBuffer) {
            if streamBuffer.count >= offset {
                streamBuffer.removeSubrange(0..<offset)
            } else {
                streamBuffer.removeAll(keepingCapacity: true)
            }

            Task { @MainActor [weak owner] in
                guard let owner else { return }

                owner.handleFullViewportContents(parsed, for: dataTask)
            }
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
}
// MARK: - OuterframeHostDelegate

extension ProcessMonitorListContentController: OuterframeHostDelegate {
    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage) {
        switch message {
        case .initializeContent:
            // Already handled during start, ignore if received again
            break

        case .resizeContent(let width, let height):
            resize(width: Int(width), height: Int(height))

        case .mouseEvent(let kind, let x, let y, let modifierFlags, let clickCount):
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
            switch kind {
            case .mouseMoved:
                mouseMoved(to: point, modifierFlags: flags)
            case .mouseDown:
                mouseDown(at: point, modifierFlags: flags, clickCount: Int(clickCount))
            case .mouseUp:
                mouseUp(at: point, modifierFlags: flags)
            case .mouseDragged:
                mouseDragged(to: point, modifierFlags: flags)
            case .rightMouseDown:
                rightMouseDown(at: point, modifierFlags: flags, clickCount: Int(clickCount))
            case .rightMouseUp:
                break
            }

        case .scrollWheelEvent(let x, let y, let deltaX, let deltaY, let modifierFlags, let phase, let momentumPhase, let isMomentum, let isPrecise):
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            let delta = CGPoint(x: CGFloat(deltaX), y: CGFloat(deltaY))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
            scrollWheel(delta: delta,
                        at: point,
                        modifierFlags: flags,
                        phase: NSEvent.Phase(rawValue: UInt(phase)),
                        momentumPhase: NSEvent.Phase(rawValue: UInt(momentumPhase)),
                        isMomentum: isMomentum,
                        isPrecise: isPrecise)

        case .keyDown(let keyCode, let characters, let charactersIgnoringModifiers, let modifierFlags, let isRepeat):
            let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
            keyDown(keyCode: keyCode,
                    characters: characters,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    modifierFlags: flags,
                    isRepeat: isRepeat)

        case .keyUp:
            break

        case .textInput(let text, _, _, _):
            insertText(text)

        case .setMarkedText, .unmarkText:
            break

        case .systemAppearanceUpdate(let appearance):
            model.effectiveAppearance = appearance
            appearanceDidChange()

        case .viewFocusChanged(let isFocused):
            viewFocusChanged(isFocused)

        case .textCommand(let command):
            performTextCommand(command)

        case .magnification, .magnificationEnded, .quickLook:
            break

        case .textInputFocus:
            break

        case .setCursorPosition:
            break

        case .windowActiveUpdate(let isActive):
            setWindowActive(isActive)

        case .copySelectedPasteboardRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: pasteboardItemsForCopy())

        case .pasteboardContentDelivered(let items):
            handlePasteboardItemsForPaste(items)

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
