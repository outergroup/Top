import CoreText
import QuartzCore
import AppKit.NSAppearance

// You create a ProcessTable

// Methods that this exposes:
// - init(appConnection:model:tableContainer:position:mainController:)
// - cleanup
// - layout(size:)
// - updateSelectionAppearance()
// - appearanceDidChange()
// - updateProcessTableRows(startIndex:totalCount:entries:additionalEntries:snapshotIndex:)
// - scrollWheel(delta:at:hasPreciseScrollingDeltas:rootLayer:)
// - mouseDown(at:modifierFlags:clickCount:rootLayer:)
// - mouseDragged(at:modifierFlags:rootLayer:)
// - mouseUp(at:modifierFlags:rootLayer:)
// - onResize
// - keyDown

// It calls:
// - ProcessMonitorListContentController.announceViewportToServer(immediate:force:)
// - ProcessMonitorListContentController.launchProcessInspector(process:)
// - ProcessMonitorListContentController.promptToStopProcess(process:)
// - ProcessMonitorListContentController.onSelectionChanged

private let digitSpriteMapLength: Int8 = 10
private let decimalSpriteMapLength: Int8 = 1
private let colonSpriteMapLength: Int8 = 1
private let memoryUnitSpriteMapLength: Int8 = 1
private let blank: Int8 = -1

private let digitAtlasLength: Int8 = digitSpriteMapLength * 3
private let decimalAtlasLength: Int8 = decimalSpriteMapLength * 3
private let colonAtlasLength: Int8 = colonSpriteMapLength * 3
private let memoryUnitAtlasLength: Int8 = memoryUnitSpriteMapLength * 3

private let digitAtlasCharacterWidth: CGFloat = 1.0 / CGFloat(digitAtlasLength)
private let decimalAtlasCharacterWidth: CGFloat = 1.0 / CGFloat(decimalAtlasLength)
private let colonAtlasCharacterWidth: CGFloat = 1.0 / CGFloat(colonAtlasLength)
private let memoryUnitWidth: CGFloat = 1.0 / CGFloat(memoryUnitAtlasLength)


// DEVELOPMENT PHASE 1: Write the ideal "generated" code directly. This is error-prone, but the point is to first find the ideal "generated" code, then figure out how to express a program that generates that code,
private let cpuUtilizationBegin: Int = 0
private let cpuUtilizationLength: Int = 6
private let cpuUtilizationEnd: Int = cpuUtilizationBegin + cpuUtilizationLength
private let cpuUtilizationDecimalOffset = cpuUtilizationEnd
private let cpuUtilizationDecimalLength = 1
private let cpuTimeBegin: Int = cpuUtilizationDecimalOffset + cpuUtilizationDecimalLength
private let cpuTimeLength: Int = 11
private let cpuTimeEnd: Int = cpuTimeBegin + cpuTimeLength
private let cpuTimeDecimalOffset = cpuTimeEnd
private let cpuTimeDecimalLength = 1
private let cpuTimeHourColonOffset = cpuTimeDecimalOffset + cpuTimeDecimalLength
private let cpuTimeHourColonLength = 1
private let cpuTimeMinuteColonOffset = cpuTimeHourColonOffset + cpuTimeMinuteColonLength
private let cpuTimeMinuteColonLength = 1
private let memoryDigitsBegin: Int = cpuTimeMinuteColonOffset + cpuTimeMinuteColonLength
private let memoryDigitsLength: Int = 5
private let memoryDigitsEnd: Int = memoryDigitsBegin + memoryDigitsLength
private let memoryUnitsOffset: Int = memoryDigitsEnd
private let memoryUnitsLength: Int = 1
private let memoryDecimalOffset = memoryUnitsOffset + memoryUnitsLength
private let memoryDecimalLength = 1
private let pidBegin: Int = memoryDecimalOffset + memoryDecimalLength
private let pidLength: Int = 6
private let pidEnd: Int = pidBegin + pidLength
private let rowVisualBlockSize: Int = pidEnd

private let spriteMapLengths: [Int8] = (
    Array(repeating: digitSpriteMapLength, count: cpuUtilizationLength)
    + Array(repeating: decimalSpriteMapLength, count: cpuUtilizationDecimalLength)
    + Array(repeating: digitSpriteMapLength, count: cpuTimeLength)
    + Array(repeating: decimalSpriteMapLength, count: cpuTimeDecimalLength)
    + Array(repeating: colonSpriteMapLength, count: cpuTimeHourColonLength)
    + Array(repeating: colonSpriteMapLength, count: cpuTimeMinuteColonLength)
    + Array(repeating: digitSpriteMapLength, count: memoryDigitsLength)
    + Array(repeating: memoryUnitSpriteMapLength, count: memoryUnitsLength)
    + Array(repeating: decimalSpriteMapLength, count: memoryDecimalLength)
    + Array(repeating: digitSpriteMapLength, count: pidLength)
)

private let spriteWidths: [CGFloat] = (
    Array(repeating: digitAtlasCharacterWidth, count: cpuUtilizationLength)
    + Array(repeating: decimalAtlasCharacterWidth, count: cpuUtilizationDecimalLength)
    + Array(repeating: digitAtlasCharacterWidth, count: cpuTimeLength)
    + Array(repeating: decimalAtlasCharacterWidth, count: cpuTimeDecimalLength)
    + Array(repeating: colonAtlasCharacterWidth, count: cpuTimeHourColonLength)
    + Array(repeating: colonAtlasCharacterWidth, count: cpuTimeMinuteColonLength)
    + Array(repeating: digitAtlasCharacterWidth, count: memoryDigitsLength)
    + Array(repeating: memoryUnitWidth, count: memoryUnitsLength)
    + Array(repeating: decimalAtlasCharacterWidth, count: memoryDecimalLength)
    + Array(repeating: digitAtlasCharacterWidth, count: pidLength)
)


@MainActor
final class ProcessTable {

    private struct ListLayers {
        let headerLayer: CALayer
        let headerBorderLayer: CALayer
        let headerTextLayers: [CATextLayer]
        let headerSortIndicatorLayers: [CALayer]
        let headerSeparators: [CALayer]
        let rowsViewportLayer: CALayer
        let rowsContentLayer: CALayer
        let rowStripeContainer: CALayer
        var rowStripeLayers: [CALayer]
    }

    private struct RowData {
        var process: ProcessEntry
        var layerIndex: Int
    }

    private struct Column {
        let title: String
        let weight: CGFloat
        let alignment: CATextLayerAlignmentMode
        let sortKey: ProcessMonitorListModel.SortColumn
    }

    private enum MemoryUnit {
        case kb
        case mb
        case gb
    }

    // Indexes serve as multipliers for moving between pages in sprite atlasas
    private enum RowSelectionState: Int8 {
        case notSelected = 0
        case selectedInKeyWindow = 1
        case selectedInNonKeyWindow = 2
    }

    private struct ProcessRowVisual {
        let container: CALayer
        let background: CALayer

        let commandTextLayer: CATextLayer
        var commandText: String
        let userTextLayer: CATextLayer
        var userText: String

        let cpuPercentContainer: CALayer
        let cpuTimeContainer: CALayer

        let memoryContainer: CALayer
        let memoryTextLayer: CATextLayer

        let pidContainer: CALayer
    }

    private let appConnection: OuterframeHost
    private let model: ProcessMonitorListModel
    private let position: CGPoint
    weak var mainController: ProcessMonitorListContentController?

    private let rowsScrollbarController: ScrollbarController<ProcessTable>

    private var listLayers: ListLayers

    private let columns: [Column] = [
        Column(title: "Command", weight: 0.34, alignment: .left, sortKey: .command),
        Column(title: "User", weight: 0.16, alignment: .left, sortKey: .user),
        Column(title: "% CPU", weight: 0.14, alignment: .right, sortKey: .cpu),
        Column(title: "CPU Time", weight: 0.16, alignment: .right, sortKey: .cpuTime),
        Column(title: "Memory", weight: 0.14, alignment: .right, sortKey: .memory),
        Column(title: "PID", weight: 0.06, alignment: .right, sortKey: .pid)
    ]

    private let bodyTextColor: NSColor = .labelColor
    private let activeSelectionBackgroundColor = NSColor.controlAccentColor
    private let inactiveSelectionBackgroundColor = NSColor.unemphasizedSelectedTextBackgroundColor
    private let activeSelectionTextColor: NSColor = .white
    private let inactiveSelectionTextColor: NSColor = .labelColor
    private let rowHeight: CGFloat = 28
    private let headerHeight: CGFloat = 28
    private let tableHorizontalInset: CGFloat = 0
    private let tableTopInset: CGFloat = 0
    private let tableBottomInset: CGFloat = 0
    private let rowsOverscan: CGFloat = 120
    nonisolated static let rowContentHorizontalInset: CGFloat = 16
    private let rowBackgroundVerticalInset: CGFloat = 0
    private let rowBackgroundCornerRadius: CGFloat = 6
    nonisolated static let cellContentHorizontalInset: CGFloat = 8
    private let headerFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let headerFontHighlighted = NSFont.systemFont(ofSize: 13, weight: .semibold)

    private let numericFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let commandFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let rowAnimationLoggingEnabled = false

    private var rowVisuals: [ProcessRowVisual] = []
    private var rowVisualIsFree: [Bool] = []
    private var freeVisuals: [Int] = []

    var columnWidths: [CGFloat] = []
    var columnOffsets: [CGFloat] = []

    private var currentScrollOffset: CGFloat = 0
    private var streamEntries: [(rowStart: Int, entries: [RowData])] = []
    private var additionalStreamEntries: [(Int, RowData)] = []

    private var spriteMapPositions: [Int8] = []
    private var newSpriteMapPositions: [Int8] = []
    private var spriteMapLayers: [CALayer] = []

    private var memoryUnits: [MemoryUnit] = []
    private var newMemoryUnits: [MemoryUnit] = []
    private var kernelMemoryFlags: [Bool] = []
    private var newKernelMemoryFlags: [Bool] = []

    private var selectionState: [RowSelectionState] = []
    private var newSelectionState: [RowSelectionState] = []

    private var chevronUpImage: CGImage?
    private var chevronDownImage: CGImage?

    init(appConnection: OuterframeHost, model: ProcessMonitorListModel, tableContainer: CALayer, position: CGPoint, mainController: ProcessMonitorListContentController) {
        self.appConnection = appConnection
        self.model = model
        self.mainController = mainController
        self.position = position


        //
        // TABLE LAYERS + BUTTONS
        //


        let header = CALayer()
        header.backgroundColor = CGColor.clear
        tableContainer.addSublayer(header)

        let headerBorder = CALayer()
        headerBorder.backgroundColor = CGColor.clear
        tableContainer.addSublayer(headerBorder)

        let headerTextLayers: [CATextLayer] = columns.map { column in
            let textLayer = CATextLayer()
            textLayer.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            textLayer.fontSize = 13
            textLayer.foregroundColor = CGColor.black
            textLayer.alignmentMode = column.alignment
            textLayer.contentsScale = 2
            textLayer.truncationMode = .end

            textLayer.string = column.title
            header.addSublayer(textLayer)
            return textLayer
        }

        var headerSeparators: [CALayer] = []
        for _ in 0..<max(columns.count - 1, 0) {
            let separator = CALayer()
            separator.backgroundColor = CGColor.clear
            header.addSublayer(separator)
            headerSeparators.append(separator)
        }

        let headerSortIndicatorLayers: [CALayer] = columns.map { _ in
            let indicatorLayer = CALayer()
            indicatorLayer.contentsScale = 2
            indicatorLayer.contentsGravity = .resizeAspect
            indicatorLayer.isHidden = true
            header.addSublayer(indicatorLayer)
            return indicatorLayer
        }

        let rowsViewport = CALayer()
        rowsViewport.masksToBounds = true
        rowsViewport.isGeometryFlipped = true
        tableContainer.addSublayer(rowsViewport)

        let rowsContent = CALayer()
        rowsContent.anchorPoint = .zero
        rowsViewport.addSublayer(rowsContent)

        let rowStripeContainer = CALayer()
        rowStripeContainer.anchorPoint = .zero
        rowsContent.addSublayer(rowStripeContainer)

        self.listLayers = ListLayers(headerLayer: header, headerBorderLayer: headerBorder, headerTextLayers: headerTextLayers, headerSortIndicatorLayers: headerSortIndicatorLayers, headerSeparators: headerSeparators, rowsViewportLayer: rowsViewport, rowsContentLayer: rowsContent, rowStripeContainer: rowStripeContainer, rowStripeLayers: [])

        rowsScrollbarController = ScrollbarController(
            appConnection: appConnection,
            viewportLayer: rowsViewport,
            appearance: model.effectiveAppearance,
            width: 8,
            inset: 4
        )
        rowsScrollbarController.delegate = self

        updateHeaderLabels()
        rowsScrollbarController.updateLayout(metrics: rowsScrollbarMetrics())

        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            initializeDigitsSpriteMap()
            applyColorsToLayers()
        }

        requestSortIndicatorImages()
    }

    private func requestSortIndicatorImages() {
        let tintColor = NSColor.secondaryLabelColor
        appConnection.getImage(
            systemSymbolName: "chevron.up",
            pointSize: 10,
            weight: .semibold,
            scale: 1.0
        ) { [weak self] data, width, height, bytesPerRow in
            Task { @MainActor in
                guard let self, let data else { return }
                guard let image = makeCGImageFromAlphaMaskData(data,
                                                               width: width,
                                                               height: height,
                                                               bytesPerRow: bytesPerRow,
                                                               tintColor: tintColor,
                                                               appearance: self.model.effectiveAppearance) else { return }
                self.chevronUpImage = image
                self.updateHeaderLabels()
            }
        }

        appConnection.getImage(
            systemSymbolName: "chevron.down",
            pointSize: 10,
            weight: .semibold,
            scale: 1.0
        ) { [weak self] data, width, height, bytesPerRow in
            Task { @MainActor in
                guard let self, let data else { return }
                guard let image = makeCGImageFromAlphaMaskData(data,
                                                               width: width,
                                                               height: height,
                                                               bytesPerRow: bytesPerRow,
                                                               tintColor: tintColor,
                                                               appearance: self.model.effectiveAppearance) else { return }
                self.chevronDownImage = image
                self.updateHeaderLabels()
            }
        }
    }

    func cleanup() {
        rowsScrollbarController.cleanup()
    }

    func layout(size: CGSize) {
        let x = position.x + tableHorizontalInset

        listLayers.headerLayer.frame = CGRect(
            x: x,
            y: yFromTop(tableTopInset + position.y, height: headerHeight, containerHeight: size.height),
            width: size.width,
            height: headerHeight
        )

        let scale = max(listLayers.headerLayer.contentsScale, 1)
        let borderHeight = max(1.0 / scale, 0.5)
        let borderY = listLayers.headerLayer.frame.minY - borderHeight
        listLayers.headerBorderLayer.frame = CGRect(x: x,
                                                    y: borderY,
                                                    width: listLayers.headerLayer.bounds.width,
                                                    height: borderHeight)

        let rowsHeight = max(0, size.height - position.y - headerHeight)
        listLayers.rowsViewportLayer.frame = CGRect(
            x: x,
            y: yFromTop(tableTopInset + position.y + headerHeight, height: rowsHeight, containerHeight: size.height),
            width: size.width,
            height: rowsHeight
        )

        let contentHeight = max(listLayers.rowsContentLayer.bounds.height, CGFloat(model.displayedRowCount) * rowHeight)
        listLayers.rowsContentLayer.bounds = CGRect(x: 0,
                                                    y: 0,
                                                    width: listLayers.rowsViewportLayer.bounds.width,
                                                    height: contentHeight)

        let contentWidth = max(0, size.width - Self.rowContentHorizontalInset * 2)
        var currentX: CGFloat = 0
        var separatorPositions: [CGFloat] = []

        var widths: [CGFloat] = []
        var offsets: [CGFloat] = []
        for index in columns.indices {
            offsets.append(currentX)
            let columnWidth = widthForColumn(at: index, totalWidth: contentWidth, currentX: currentX)
            widths.append(columnWidth)
            currentX += columnWidth
            if index < columns.count - 1 {
                separatorPositions.append(Self.rowContentHorizontalInset + currentX)
            }
        }

        self.columnWidths = widths
        self.columnOffsets = offsets

        layoutHeaderColumns()

        let separatorHeight: CGFloat = 14
        let separatorYOffset = (headerHeight - separatorHeight) / 2
        for (index, separator) in listLayers.headerSeparators.enumerated() {
            let position = separatorPositions[index]
            separator.frame = CGRect(x: position,
                                     y: separatorYOffset,
                                     width: 1 / listLayers.headerLayer.contentsScale,
                                     height: separatorHeight)
        }

        let viewportWidth = listLayers.rowsViewportLayer.bounds.width
        let num_stripes = Int(ceil(size.height / rowHeight)) + 2
        if listLayers.rowStripeLayers.count < num_stripes {
            let (rowEvenColor, rowOddColor) = alternatingRowColors()

            for stripeIndex in listLayers.rowStripeLayers.count..<num_stripes {
                let stripe = CALayer()
                let originY = CGFloat(stripeIndex) * rowHeight
                stripe.frame = CGRect(x: 0, y: originY, width: viewportWidth, height: rowHeight)
                stripe.backgroundColor = (stripeIndex % 2 == 0) ? rowEvenColor : rowOddColor
                listLayers.rowStripeContainer.addSublayer(stripe)
                listLayers.rowStripeLayers.append(stripe)
            }
        } else if listLayers.rowStripeLayers.count > num_stripes {
            for stripeIndex in num_stripes..<listLayers.rowStripeLayers.count {

                listLayers.rowStripeLayers[stripeIndex].removeFromSuperlayer()
            }
            listLayers.rowStripeLayers.removeLast(listLayers.rowStripeLayers.count - num_stripes)
        }

        for (stripeIndex, stripe) in listLayers.rowStripeLayers.enumerated() {
            stripe.frame = CGRect(x: 0,
                                  y: CGFloat(stripeIndex) * rowHeight,
                                  width: viewportWidth,
                                  height: rowHeight)
        }

        // Apply the changes to every row visual, even the current "free" ones, rather than enumerating the ones currently being used from streamEntries. This lets us trust that free visuals are already properly laid out.
        for layerIndex in rowVisuals.indices {
            layoutVisual(layerIndex: layerIndex, widths: widths, offsets: offsets, rowHeight: rowHeight)
        }
    }

    func updateSelectionAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            for (_, entries) in streamEntries {
                for entry in entries {
                    newSelectionState[entry.layerIndex] = if entry.process.pid == model.selectedProcess?.pid {
                        if model.isWindowActive && model.isTableFirstResponder {
                            .selectedInKeyWindow
                        } else {
                            .selectedInNonKeyWindow
                        }
                    } else {
                        .notSelected
                    }

                    updateCommandTextColor(layerIndex: entry.layerIndex,
                                           selectionState: newSelectionState[entry.layerIndex])
                    updateUserTextColor(layerIndex: entry.layerIndex,
                                        selectionState: newSelectionState[entry.layerIndex])
                }
            }
        }

        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            commitSelectionState()
        }
        CATransaction.commit()
    }

    private func applyColorsToLayers() {
        listLayers.headerLayer.backgroundColor = CGColor.clear

        let isLightTheme = NSColor.controlBackgroundColor.am_brightness > 0.6
        listLayers.headerBorderLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(isLightTheme ? 0.35 : 0.6).cgColor

        let label = NSColor.labelColor.cgColor
        for header in listLayers.headerTextLayers {
            header.foregroundColor = label
        }
        for separatorLayer in listLayers.headerSeparators {
            separatorLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(isLightTheme ? 0.35 : 0.45).cgColor
        }

        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            for layerIndex in rowVisuals.indices {
                updateCommandTextColor(layerIndex: layerIndex,
                                       selectionState: selectionState[layerIndex])
                updateUserTextColor(layerIndex: layerIndex,
                                    selectionState: selectionState[layerIndex])
                updateMemoryTextColor(layerIndex: layerIndex,
                                      selectionState: selectionState[layerIndex])
            }
        }

        let (rowEvenColor, rowOddColor) = alternatingRowColors()
        for (index, stripe) in listLayers.rowStripeLayers.enumerated() {
            let rowIndex = model.visibleRowRange.lowerBound + index
            stripe.isHidden = false
            stripe.backgroundColor = (rowIndex % 2 == 0) ? rowEvenColor : rowOddColor
        }

        rowsScrollbarController.updateAppearance(model.effectiveAppearance)
    }

    func appearanceDidChange() {
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            initializeDigitsSpriteMap()
        }

        requestSortIndicatorImages()

        for layerIndex in rowVisuals.indices {
            let base = layerIndex * rowVisualBlockSize

            for offset in cpuUtilizationBegin..<cpuUtilizationEnd {
                spriteMapLayers[base + offset].contents = digitsSpriteMap
            }

            spriteMapLayers[base + cpuUtilizationDecimalOffset].contents = decimalSeparatorImage

            for offset in cpuTimeBegin..<cpuTimeEnd {
                spriteMapLayers[base + offset].contents = digitsSpriteMap
            }

            for offset in memoryDigitsBegin..<memoryDigitsEnd {
                spriteMapLayers[base + offset].contents = digitsSpriteMap
            }

            spriteMapLayers[base + cpuTimeDecimalOffset].contents = decimalSeparatorImage
            spriteMapLayers[base + cpuTimeHourColonOffset].contents = colonImage
            spriteMapLayers[base + cpuTimeMinuteColonOffset].contents = colonImage

            spriteMapLayers[base + memoryUnitsOffset].contents = switch memoryUnits[layerIndex] {
            case .kb:
                kbImage
            case .mb:
                mbImage
            case .gb:
                gbImage
            }

            spriteMapLayers[base + memoryDecimalOffset].contents = decimalSeparatorImage

            for offset in pidBegin..<pidEnd {
                spriteMapLayers[base + offset].contents = digitsSpriteMap
            }
        }

        applyColorsToLayers()
    }

    private func mapEntriesToSpritePositions(entries: [ProcessEntry],
                                             additionalEntries: [(Int, ProcessEntry)] = []) -> (positions: [Int8], memoryUnits: [MemoryUnit], kernelMemoryFlags: [Bool], selectionState: [RowSelectionState]) {
        let numEntries = entries.count + additionalEntries.count
        var positions: [Int8] = .init(repeating: -1, count: rowVisualBlockSize * numEntries)
        var unsortedMemoryUnits: [MemoryUnit] = .init()
        unsortedMemoryUnits.reserveCapacity(numEntries)
        var unsortedKernelMemoryFlags: [Bool] = .init()
        unsortedKernelMemoryFlags.reserveCapacity(numEntries)
        var unsortedSelectionState: [RowSelectionState] = .init()
        unsortedSelectionState.reserveCapacity(numEntries)

        func processEntry(_ index: Int, _ entry: ProcessEntry) {
            let selectionState: RowSelectionState = if model.selectedProcess?.pid == entry.pid {
                if model.isWindowActive && model.isTableFirstResponder {
                    .selectedInKeyWindow
                } else {
                    .selectedInNonKeyWindow
                }
            } else {
                .notSelected
            }
            unsortedSelectionState.append(selectionState)

            let atlasNumber = selectionState.rawValue

            let entryBase = index * rowVisualBlockSize
            let digitAtlasOffset = atlasNumber * digitSpriteMapLength

            do {
                let digits = Int(round(entry.cpuPercent * 10))
                let d0 = Int8((digits / 100_000) % 10) + digitAtlasOffset
                let d1 = Int8((digits /  10_000) % 10) + digitAtlasOffset
                let d2 = Int8((digits /   1_000) % 10) + digitAtlasOffset
                let d3 = Int8((digits /     100) % 10) + digitAtlasOffset
                let d4 = Int8((digits /      10) % 10) + digitAtlasOffset
                let d5 = Int8( digits            % 10) + digitAtlasOffset

                // TODO: create a set of functions for different numbers of digits, and then use them according to a switch / if else. That way, I can rely on the branch predictor to correctly choose the function.

                // TODO: confirm that this uses csel / cmov in assembly. Then add a code comment indicating this.
                // TODO: check in the assembly whether this performs a bounds check on every single `rowVisuals` lookup.

                let base = entryBase + cpuUtilizationBegin
                positions[base + 0] = digits >= 100_000 ? d0 : blank
                positions[base + 1] = digits >=  10_000 ? d1 : blank
                positions[base + 2] = digits >=   1_000 ? d2 : blank
                positions[base + 3] = digits >=     100 ? d3 : blank
                // Always show at least two digits (e.g. "0.0")
                positions[base + 4] = d4
                positions[base + 5] = d5

                positions[entryBase + cpuUtilizationDecimalOffset] = atlasNumber * decimalSpriteMapLength
            }

            do {
                let totalSeconds = entry.cpuTimeMilliseconds / 1000
                let milliseconds = entry.cpuTimeMilliseconds % 1000
                let seconds = totalSeconds % 60
                let totalMinutes = totalSeconds / 60
                let minutes = totalMinutes % 60
                let hours = totalSeconds / 3600

                let h0 = Int8((hours /      1000) % 10) + digitAtlasOffset
                let h1 = Int8((hours /       100) % 10) + digitAtlasOffset
                let h2 = Int8((hours /        10) % 10) + digitAtlasOffset
                let h3 = Int8( hours              % 10) + digitAtlasOffset
                let m0 = Int8((minutes /      10) % 10) + digitAtlasOffset
                let m1 = Int8( minutes            % 10) + digitAtlasOffset
                let s0 = Int8((seconds /      10) % 10) + digitAtlasOffset
                let s1 = Int8( seconds            % 10) + digitAtlasOffset
                let ms0 = Int8((milliseconds /     100) % 10) + digitAtlasOffset
                let ms1 = Int8((milliseconds /     10)  % 10) + digitAtlasOffset
                let ms2 = Int8( milliseconds            % 10) + digitAtlasOffset

                let base = entryBase + cpuTimeBegin
                positions[base + 0] = hours >=      1000 ? h0 : blank
                positions[base + 1] = hours >=       100 ? h1 : blank
                positions[base + 2] = hours >=        10 ? h2 : blank
                positions[base + 3] = hours >=         1 ? h3 : blank
                positions[base + 4] = totalMinutes >= 10 ? m0 : blank
                positions[base + 5] = m1
                positions[base + 6] = s0
                positions[base + 7] = s1
                positions[base + 8] = ms0
                positions[base + 9] = ms1
                positions[base + 10] = ms2

                positions[entryBase + cpuTimeDecimalOffset] = atlasNumber * decimalSpriteMapLength
                positions[entryBase + cpuTimeHourColonOffset] = hours >= 1 ? atlasNumber * colonSpriteMapLength : blank
                positions[entryBase + cpuTimeMinuteColonOffset] = atlasNumber * colonSpriteMapLength
            }

            do {
                positions[entryBase + memoryUnitsOffset] = atlasNumber * memoryUnitSpriteMapLength
                positions[entryBase + memoryDecimalOffset] = atlasNumber * decimalSpriteMapLength
                unsortedKernelMemoryFlags.append(entry.isKernelThread)

                if entry.memoryKilobytes < 1024 {
                    // Units: KB, no decimal place
                    let kb = entry.memoryKilobytes

                    let d0 = Int8((kb /   1_000) % 10) + digitAtlasOffset
                    let d1 = Int8((kb /     100) % 10) + digitAtlasOffset
                    let d2 = Int8((kb /      10) % 10) + digitAtlasOffset
                    let d3 = Int8( kb            % 10) + digitAtlasOffset

                    let base = entryBase + memoryDigitsBegin
                    positions[base + 0] = blank
                    positions[base + 1] = kb >=   1_000 ? d0 : blank
                    positions[base + 2] = kb >=     100 ? d1 : blank
                    positions[base + 3] = kb >=      10 ? d2 : blank
                    positions[base + 4] = d3

                    unsortedMemoryUnits.append(.kb)
                } else if entry.memoryKilobytes < 1024 * 1024 - 512 {
                    let shift = 10
                    unsortedMemoryUnits.append(.mb)

                    var fullUnits = entry.memoryKilobytes >> shift
                    let unitSize = 0x1 << shift
                    let remainder = entry.memoryKilobytes & (unitSize - 1)

                    // TODO: use look up tables or bit magic for these?
                    var tenths = Int(round((Float(remainder) / Float(unitSize)) * 10))

                    fullUnits += (tenths == 10) ? 1 : 0
                    tenths %= 10

                    let f0 = Int8((fullUnits /  1000) % 10) + digitAtlasOffset
                    let f1 = Int8((fullUnits /   100) % 10) + digitAtlasOffset
                    let f2 = Int8((fullUnits /    10) % 10) + digitAtlasOffset
                    let f3 = Int8( fullUnits          % 10) + digitAtlasOffset
                    let d0 = Int8(tenths) + digitAtlasOffset

                    let base = entryBase + memoryDigitsBegin
                    positions[base + 0] = fullUnits >= 1000 ? f0 : blank
                    positions[base + 1] = fullUnits >=  100 ? f1 : blank
                    positions[base + 2] = fullUnits >=   10 ? f2 : blank
                    positions[base + 3] = f3
                    positions[base + 4] = d0
                } else {
                    let shift = 20
                    unsortedMemoryUnits.append(.gb)

                    var fullUnits = entry.memoryKilobytes >> shift
                    let unitSize = 0x1 << shift
                    let remainder = entry.memoryKilobytes & (unitSize - 1)

                    // TODO: use look up tables or bit magic for these?
                    var hundredths = Int(round((Float(remainder) / Float(unitSize)) * 100))

                    fullUnits += (hundredths == 100) ? 1 : 0
                    hundredths %= 100

                    let f0 = Int8((fullUnits /   100) % 10) + digitAtlasOffset
                    let f1 = Int8((fullUnits /    10) % 10) + digitAtlasOffset
                    let f2 = Int8( fullUnits          % 10) + digitAtlasOffset
                    let d0 = Int8((hundredths /   10) % 10) + digitAtlasOffset
                    let d1 = Int8( hundredths         % 10) + digitAtlasOffset


                    let base = entryBase + memoryDigitsBegin
                    positions[base + 0] = fullUnits >= 100 ? f0 : blank
                    positions[base + 1] = fullUnits >=  10 ? f1 : blank
                    positions[base + 2] = f2
                    positions[base + 3] = d0
                    positions[base + 4] = d1
                }
            }

            do {
                let digits = entry.pid
                let d0 = Int8((digits / 100_000) % 10) + digitAtlasOffset
                let d1 = Int8((digits /  10_000) % 10) + digitAtlasOffset
                let d2 = Int8((digits /   1_000) % 10) + digitAtlasOffset
                let d3 = Int8((digits /     100) % 10) + digitAtlasOffset
                let d4 = Int8((digits /      10) % 10) + digitAtlasOffset
                let d5 = Int8( digits            % 10) + digitAtlasOffset

                let base = entryBase + pidBegin
                positions[base + 0] = digits >= 100_000 ? d0 : blank
                positions[base + 1] = digits >=  10_000 ? d1 : blank
                positions[base + 2] = digits >=   1_000 ? d2 : blank
                positions[base + 3] = digits >=     100 ? d3 : blank
                positions[base + 4] = digits >=      10 ? d4 : blank
                positions[base + 5] = d5
            }
        }

        for (i, entry) in entries.enumerated() {
            processEntry(i, entry)
        }

        for (i, (_, entry)) in additionalEntries.enumerated() {
            processEntry(entries.count + i, entry)
        }

        return (positions, unsortedMemoryUnits, unsortedKernelMemoryFlags, unsortedSelectionState)
    }

    func updateProcessTableRows(startIndex: Int,
                                totalCount: Int,
                                entries: [ProcessEntry],
                                additionalEntries: [(Int, ProcessEntry)] = [],
                                snapshotIndex: UInt64) {
//        print("updateProcessTableRows(startIndex=\(startIndex), numberOfEntries=\(entries.count)")

        let (positions, unsortedMemoryUnits, unsortedKernelMemoryFlags, unsortedSelectionState) = mapEntriesToSpritePositions(entries: entries, additionalEntries: additionalEntries)

        func copyToNewSpriteMapPositions(_ entryIndex: Int, _ layerIndex: Int) {
            let fromBegin = entryIndex * rowVisualBlockSize
            let fromEnd = (entryIndex + 1) * rowVisualBlockSize
            let toBegin = layerIndex * rowVisualBlockSize
            let toEnd = (layerIndex + 1) * rowVisualBlockSize
            newSpriteMapPositions[toBegin..<toEnd] = positions[fromBegin..<fromEnd]
            newMemoryUnits[layerIndex] = unsortedMemoryUnits[entryIndex]
            newKernelMemoryFlags[layerIndex] = unsortedKernelMemoryFlags[entryIndex]
            newSelectionState[layerIndex] = unsortedSelectionState[entryIndex]
        }

        if totalCount != model.displayedRowCount {
            model.displayedRowCount = totalCount

            let contentHeight = CGFloat(totalCount) * rowHeight
            listLayers.rowsContentLayer.bounds = CGRect(x: 0, y: 0, width: listLayers.rowsViewportLayer.bounds.width, height: contentHeight)
        }

        reconcileRowsScrollOffset(announceViewport: true)

        enum QueuedAnimation {
            case implicitSetFrame(layerIndex: Int, position: CGPoint)
            case explicitSetFrame(layerIndex: Int, startY: CGFloat, position: CGPoint)
        }

        var queuedAnimations: [QueuedAnimation] = []

        var used = Array(repeating: false,
                         // Give it extra space in case we grow the list of row visuals
                         count: rowVisuals.count + entries.count)

//        let iterationLabel = "Iteration 0x" + String(snapshotIndex, radix: 16)
//        print(iterationLabel)
//        mainController?.showStatus(iterationLabel)

        let prevStreamEntries = streamEntries
        streamEntries = [(startIndex, entries.enumerated().map { (i_relative, process) in
            let globalIndex = startIndex + i_relative
            let newPosition = CGPoint(x: 0, y: CGFloat(globalIndex) * rowHeight)

//            print("Process: \(process.command)")

            @MainActor
            func getEntry() -> RowData {

                if let previousIndex = process.previousIndex {
//                    print("Has previous index: \(previousIndex)")
                    for (prevEntriesRowStart, prevEntries) in prevStreamEntries {
                        let i_prev_relative = previousIndex - prevEntriesRowStart
                        if (0..<prevEntries.count).contains(i_prev_relative) {
                            let layerIndex = prevEntries[i_prev_relative].layerIndex
//                            print("found layer: \(layerIndex)")

                            if globalIndex != previousIndex {
                                queuedAnimations.append(.implicitSetFrame(layerIndex: layerIndex, position: newPosition))
                            }

                            return RowData(process: process, layerIndex: layerIndex)
                        }
                    }

//                    print("Did not find layer")
                    let layerIndex = createRowVisual()
                    let startY = CGFloat(previousIndex) * rowHeight
                    queuedAnimations.append(.explicitSetFrame(layerIndex: layerIndex, startY: startY, position: newPosition))

                    rowVisuals[layerIndex].container.position = newPosition

                    return RowData(process: process, layerIndex: layerIndex)
                } else {
//                    print("Doesn't have previous index")
                    let layerIndex = createRowVisual()
                    rowVisuals[layerIndex].container.position = newPosition
                    return RowData(process: process, layerIndex: layerIndex)
                }
            }

            let entry = getEntry()
            used[entry.layerIndex] = true
            applyEntryContent(entry: entry)
            copyToNewSpriteMapPositions(i_relative, entry.layerIndex)
            return entry
        })]

        var toRemove: [Int] = []

        additionalStreamEntries = additionalEntries.enumerated().compactMap { (additionalEntryIndex, arg1) in

            let (globalIndex, process) = arg1
            guard let previousIndex = process.previousIndex else {
                // This shouldn't happen, the only reason to include an additional entry is because it's animating across the viewport, i.e. it has a previous index.
                print("Received unexpected entry outside the viewport without a previous index")
                return nil
            }

            @MainActor
            func getEntry() -> RowData {

                let newPosition = CGPoint(x: 0, y: CGFloat(globalIndex) * rowHeight)

                for (prevEntriesRowStart, prevEntries) in prevStreamEntries {
                    if (prevEntriesRowStart..<prevEntriesRowStart+prevEntries.count).contains(previousIndex) {
                        let layerIndex = prevEntries[previousIndex - prevEntriesRowStart].layerIndex
                        queuedAnimations.append(.implicitSetFrame(layerIndex: layerIndex, position: newPosition))
                        toRemove.append(layerIndex)
                        return RowData(process: process, layerIndex: layerIndex)
                    }
                }

                let layerIndex = createRowVisual()
                let startY = CGFloat(previousIndex) * rowHeight
                queuedAnimations.append(.explicitSetFrame(layerIndex: layerIndex, startY: startY, position: newPosition))

                toRemove.append(layerIndex)
                return RowData(process: process, layerIndex: layerIndex)
            }

            let entry = getEntry()
            used[entry.layerIndex] = true
            applyEntryContent(entry: entry)
            copyToNewSpriteMapPositions(entries.count + additionalEntryIndex, entry.layerIndex)
            return (globalIndex, entry)
        }


        commitSpritePositions()

        for layerIndex in rowVisuals.indices {
            if !rowVisualIsFree[layerIndex],
               !used[layerIndex] {
                rowVisuals[layerIndex].container.removeFromSuperlayer()
                rowVisualIsFree[layerIndex] = true
                freeVisuals.append(layerIndex)
            }
        }

        CATransaction.commit()
        CATransaction.begin()

        for queuedAnimation in queuedAnimations {
            switch queuedAnimation {
            case .implicitSetFrame(let layerIndex, let position):
                rowVisuals[layerIndex].container.position = position
            case .explicitSetFrame(let layerIndex, let startY, let position):
                let animation = CABasicAnimation(keyPath: "position.y")
                animation.fromValue = startY
                animation.toValue = position.y
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let layer = rowVisuals[layerIndex].container
                layer.add(animation, forKey: "positionYMove")
                layer.position = position
            }
        }

        CATransaction.setCompletionBlock {
            for layerIndex in toRemove {
                if !self.rowVisualIsFree[layerIndex] {
                    self.rowVisuals[layerIndex].container.removeFromSuperlayer()
                    self.rowVisualIsFree[layerIndex] = true
                    self.freeVisuals.append(layerIndex)
                }
            }
        }
    }

    func updateProcessTableRowsOnScroll(startIndex: Int,
                                        entries: [ProcessEntry],
                                        additionalEntries: [(Int, ProcessEntry)] = []) {
//        print("updateProcessTableRowsOnScroll(startIndex=\(startIndex), numberOfEntries=\(entries.count)")

        let (positions, unsortedMemoryUnits, unsortedKernelMemoryFlags, unsortedSelectionState) = mapEntriesToSpritePositions(entries: entries, additionalEntries: additionalEntries)

        func copyToNewSpriteMapPositions(_ entryIndex: Int, _ layerIndex: Int) {
            let fromBegin = entryIndex * rowVisualBlockSize
            let fromEnd = (entryIndex + 1) * rowVisualBlockSize
            let toBegin = layerIndex * rowVisualBlockSize
            let toEnd = (layerIndex + 1) * rowVisualBlockSize
            newSpriteMapPositions[toBegin..<toEnd] = positions[fromBegin..<fromEnd]
            newMemoryUnits[layerIndex] = unsortedMemoryUnits[entryIndex]
            newKernelMemoryFlags[layerIndex] = unsortedKernelMemoryFlags[entryIndex]
            newSelectionState[layerIndex] = unsortedSelectionState[entryIndex]
        }

        // Pragmatic choice: don't worry about trying to capture animations while scrolling.
        // We could choose to be perfectionists; imagine if there were a user setting to slow down animations, and the user could quickly scroll around while it's animating, and we'd want them to see animations everywhere, not just in the initial viewport.
        // But it's not worth designing for that, in part because it will likely create a bunch of nearly-dead code that might accumulate bugs.

        // find a contiguous range that that this can be inserted/appended to
        var done = false
        for (i_contiguous, (currEntriesStartIndex, currEntries)) in streamEntries.enumerated() {
            let currEntriesEnd = currEntriesStartIndex + currEntries.count
            let newEntriesEnd = startIndex + entries.count

            let contiguousPotential = (currEntriesStartIndex - 1)...(currEntriesStartIndex + currEntries.count)
            if contiguousPotential.overlaps(startIndex..<startIndex + entries.count) {

                let currRange = currEntriesStartIndex..<currEntriesEnd
                let newEntriesRange = startIndex..<newEntriesEnd

                let newRange = min(currEntriesStartIndex, startIndex) ..< max(currEntriesEnd, newEntriesEnd)

                var newEntries: [RowData] = []
                newEntries.reserveCapacity(newRange.count)

                if currEntriesStartIndex < startIndex {
                    // start with old ones, until you get to start of new ones
                    for i in currRange.lowerBound..<newEntriesRange.lowerBound {
                        let relative_i = i - currRange.lowerBound
                        newEntries.append(currEntries[relative_i])
                    }
                }

                // start with new ones
                for i in newEntriesRange {
                    let relative_i = i - newEntriesRange.lowerBound

                    // Overwriting is not expected, but we're robust to it if the backend chooses to do it
                    let layerIndex: Int
                    if currRange.contains(i) {
                        layerIndex = currEntries[i - currRange.lowerBound].layerIndex
                    } else {
                        layerIndex = createRowVisual()
                    }

                    rowVisuals[layerIndex].container.position = CGPoint(x: 0, y: CGFloat(i) * rowHeight)
                    let entry = RowData(process: entries[relative_i], layerIndex: layerIndex)
                    applyEntryContent(entry: entry)
                    copyToNewSpriteMapPositions(relative_i, layerIndex)
                    newEntries.append(entry)
                }

                // then continue with previous (if applicable)
                if newEntriesRange.upperBound < currRange.upperBound {
                    for i in newEntriesRange.upperBound ..< currRange.upperBound {
                        let relative_i = i - currRange.lowerBound
                        newEntries.append(currEntries[relative_i])
                    }
                }

                streamEntries[i_contiguous] = (newRange.lowerBound, newEntries)
                done = true

                break
            }
        }

        // else create a new range
        if !done {
            streamEntries.append((startIndex, entries.enumerated().map { (i, process) in
                let layerIndex = createRowVisual()
                rowVisuals[layerIndex].container.position = CGPoint(x: 0, y: CGFloat(startIndex + i) * rowHeight)
                let entry = RowData(process: process, layerIndex: layerIndex)
                applyEntryContent(entry: entry)
                copyToNewSpriteMapPositions(i, layerIndex)
                return entry
            }))
        }

        if additionalEntries.count > 0 {
            print("Skipping additional entries on scroll; we don't animate rows that appear due to scrolling")
        }

        commitSpritePositions()
    }

    private func rowsScrollbarMetrics() -> ScrollbarController<ProcessTable>.Metrics {
        let viewport = listLayers.rowsViewportLayer
        let contentHeight = CGFloat(model.displayedRowCount) * rowHeight
        return ScrollbarController.Metrics(viewportSize: viewport.bounds.size,
                                           contentHeight: contentHeight,
                                           scrollOffset: currentScrollOffset)
    }

    private func maxRowsScrollOffset() -> CGFloat {
        let viewport = listLayers.rowsViewportLayer
        let contentHeight = CGFloat(model.displayedRowCount) * rowHeight
        return max(contentHeight - viewport.bounds.height, 0)
    }

    private func reconcileRowsScrollOffset(announceViewport: Bool) {
        let viewport = listLayers.rowsViewportLayer
        guard viewport.bounds.height > 0 else {
            currentScrollOffset = max(0, currentScrollOffset)
            return
        }

        let contentHeight = CGFloat(model.displayedRowCount) * rowHeight
        currentScrollOffset = clampScrollOffset(currentScrollOffset,
                                                contentHeight: contentHeight,
                                                viewportHeight: viewport.bounds.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var position = listLayers.rowsContentLayer.position
        position.y = -currentScrollOffset
        listLayers.rowsContentLayer.position = position

        let increment = 2 * rowHeight
        let stripeY = floor(currentScrollOffset / increment) * increment
        if listLayers.rowStripeContainer.position.y != stripeY {
            listLayers.rowStripeContainer.position = CGPoint(x: 0, y: stripeY)
        }

        rowsScrollbarController.updateLayout(metrics: rowsScrollbarMetrics())
        CATransaction.commit()

        let newRange = visibleRowRangeForCurrentViewport()
        if newRange != model.visibleRowRange {
            model.visibleRowRange = newRange
            if announceViewport {
                mainController?.announceViewportToServer(immediate: true)
            }
        }
    }

    private func setRowsScrollOffset(_ value: CGFloat) {
        let viewport = listLayers.rowsViewportLayer
        guard viewport.bounds.height > 0 else {
            currentScrollOffset = max(0, value)
            return
        }

        let contentHeight = CGFloat(model.displayedRowCount) * rowHeight
        let clamped = clampScrollOffset(value,
                                        contentHeight: contentHeight,
                                        viewportHeight: viewport.bounds.height)
        if abs(clamped - currentScrollOffset) < 0.0001 {
            currentScrollOffset = clamped
            reconcileRowsScrollOffset(announceViewport: false)
            return
        }

        currentScrollOffset = clamped

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var position = listLayers.rowsContentLayer.position
        position.y = -currentScrollOffset
        listLayers.rowsContentLayer.position = position

        let increment = 2 * rowHeight
        let new_y = floor(currentScrollOffset / increment) * increment
        if listLayers.rowStripeContainer.position.y != new_y {
            listLayers.rowStripeContainer.position = CGPoint(x: 0, y: new_y)
        }

        rowsScrollbarController.updateLayout(metrics: rowsScrollbarMetrics())
        CATransaction.commit()

        let newRange = visibleRowRangeForCurrentViewport()
        if newRange != model.visibleRowRange {
            model.visibleRowRange = newRange
            mainController?.announceViewportToServer(immediate: true)
        }
    }

    @discardableResult
    private func scrollRows(byAdjustedDeltaY deltaY: CGFloat) -> Bool {
        let maxOffset = maxRowsScrollOffset()
        if maxOffset <= 0.0001 { return false }
        let proposed = max(min(currentScrollOffset - deltaY, maxOffset), 0)
        if abs(proposed - currentScrollOffset) < 0.0001 { return false }
        setRowsScrollOffset(proposed)
        return true
    }

    func scrollWheel(delta: CGPoint,
                     at point: CGPoint,
                     hasPreciseScrollingDeltas: Bool,
                     rootLayer: CALayer) -> Bool {

        let pointInViewport = listLayers.rowsViewportLayer.convert(point, from: rootLayer)
        guard listLayers.rowsViewportLayer.bounds.contains(pointInViewport) else { return false }

        let multiplier: CGFloat = hasPreciseScrollingDeltas ? 1.0 : rowHeight
        let adjustedDeltaY = delta.y * multiplier
        if adjustedDeltaY != 0 {
            rowsScrollbarController.cancelAnimation()
            _ = scrollRows(byAdjustedDeltaY: adjustedDeltaY)
        }
        return true
    }

    private func entry(atGlobalIndex index: Int) -> RowData? {
        for (rowStart, entries) in streamEntries {
            let local = index - rowStart
            guard local >= 0, local < entries.count else { continue }
            return entries[local]
        }

        return nil
    }

    /// Returns loaded process entries for accessibility, limited to visible range.
    /// Each tuple contains (globalRowIndex, processEntry, frameInTable).
    /// The frame is relative to the table container, accounting for scroll position.
    func loadedEntriesForAccessibility() -> [(index: Int, process: ProcessEntry, frame: CGRect)] {
        var result: [(index: Int, process: ProcessEntry, frame: CGRect)] = []
        let tableWidth = listLayers.rowsViewportLayer.bounds.width
        let headerHeight = listLayers.headerLayer.bounds.height
        let tableHeight = listLayers.rowsViewportLayer.bounds.height + headerHeight

        for (rowStart, entries) in streamEntries {
            for (localIndex, rowData) in entries.enumerated() {
                let globalIndex = rowStart + localIndex
                // Only include rows in the visible range
                if model.visibleRowRange.contains(globalIndex) {
                    // Calculate frame in CALayer coordinates (y=0 at bottom of table)
                    let contentY = CGFloat(globalIndex) * rowHeight
                    let rowTopFromTableTop = contentY - currentScrollOffset + headerHeight
                    let rowY = tableHeight - rowTopFromTableTop - rowHeight
                    let frame = CGRect(x: 0, y: rowY, width: tableWidth, height: rowHeight)
                    result.append((globalIndex, rowData.process, frame))
                }
            }
        }
        return result.sorted { $0.index < $1.index }
    }

    func columnLayoutForAccessibility() -> [(width: CGFloat, offset: CGFloat)] {
        let inset = Self.rowContentHorizontalInset
        return zip(columnWidths, columnOffsets).map { (width: $0, offset: $1 + inset) }
    }

    func headerForAccessibility() -> (frame: CGRect, columns: [(title: String, isSorted: Bool, frame: CGRect)]) {
        let tableHeight = listLayers.rowsViewportLayer.bounds.height + headerHeight
        // Header frame in CALayer coordinates (y=0 at bottom of table)
        // Header is at top, so y = tableHeight - headerHeight
        let headerY = tableHeight - headerHeight
        let headerFrame = CGRect(x: 0, y: headerY, width: listLayers.headerLayer.bounds.width, height: headerHeight)

        let inset = Self.rowContentHorizontalInset
        let columnInfo: [(title: String, isSorted: Bool, frame: CGRect)] = columns.enumerated().map { (index, column) in
            let isSorted = (model.sortColumn == column.sortKey)
            let columnX = (index < columnOffsets.count ? columnOffsets[index] : 0) + inset
            let columnWidth = index < columnWidths.count ? columnWidths[index] : 0
            let columnFrame = CGRect(x: columnX, y: headerY, width: columnWidth, height: headerHeight)
            return (title(for: column), isSorted, columnFrame)
        }

        return (headerFrame, columnInfo)
    }

    func mouseDown(at rootPoint: CGPoint, modifierFlags: NSEvent.ModifierFlags, clickCount: Int, rootLayer: CALayer) -> Bool {
        if rowsScrollbarController.handleMouseDown(at: rootLayer.convert(rootPoint, to: listLayers.rowsViewportLayer)) == true {
            return true
        }

        let pointInHeader = listLayers.headerLayer.convert(rootPoint, from: rootLayer)
        if listLayers.headerLayer.bounds.contains(pointInHeader) {
            let contentWidth = listLayers.headerLayer.bounds.width - Self.rowContentHorizontalInset * 2
            guard contentWidth > 0 else { return false }
            let adjustedX = pointInHeader.x - Self.rowContentHorizontalInset
            guard adjustedX >= 0 && adjustedX <= contentWidth else { return false }
            guard let columnIndex = columnIndex(forX: adjustedX, totalWidth: contentWidth) else {
                return false
            }
            handleSortSelection(for: columnIndex)
            return true
        }

        if let rowIndex = rowIndex(atRootPoint: rootPoint, rootLayer: rootLayer) {
            selectRow(at: rowIndex)
            if clickCount >= 2,
               let selectedProcess = model.selectedProcess {
                mainController?.launchProcessInspector(selectedProcess)
            }
            return true
        }


        // TODO: merge this logic with the above, we're doing redundant things between here and rowIndex(atRootPoint:...).
        let pointInTable = listLayers.rowsViewportLayer.convert(rootPoint, from: rootLayer)
        if listLayers.rowsViewportLayer.bounds.contains(pointInTable) {
            clearSelection()
        }

        return false
    }

    func mouseDragged(at rootPoint: CGPoint, modifierFlags: NSEvent.ModifierFlags, rootLayer: CALayer) -> Bool {
        rowsScrollbarController.handleMouseDragged(to: rootLayer.convert(rootPoint, to: listLayers.rowsViewportLayer))
    }

    func mouseUp(at rootPoint: CGPoint, modifierFlags: NSEvent.ModifierFlags, rootLayer: CALayer) -> Bool {
        rowsScrollbarController.handleMouseUp(at: rootLayer.convert(rootPoint, to: listLayers.rowsViewportLayer))
    }

    func onResize() {
        reconcileRowsScrollOffset(announceViewport: false)
    }

    func onSearchFilterChanged() {
        streamEntries.removeAll(keepingCapacity: false)
        additionalStreamEntries.removeAll(keepingCapacity: false)
    }

    func selectionModeDidChange() {
        updateHeaderLabels()
    }

    private func updateHeaderLabels() {
        let headerTextLayers = listLayers.headerTextLayers
        let sortIndicatorLayers = listLayers.headerSortIndicatorLayers
        guard headerTextLayers.count == columns.count,
              sortIndicatorLayers.count == columns.count else { return }

        for (index, layer) in headerTextLayers.enumerated() {
            let title = title(for: columns[index])
            let isSorted = model.sortColumn == columns[index].sortKey

            layer.string = title
            let font = isSorted ? headerFontHighlighted : headerFont
            layer.font = font
            layer.fontSize = font.pointSize

            let indicatorLayer = sortIndicatorLayers[index]
            if isSorted {
                indicatorLayer.isHidden = false
                indicatorLayer.contents = model.sortAscending ? chevronUpImage : chevronDownImage
            } else {
                indicatorLayer.isHidden = true
                indicatorLayer.contents = nil
            }
        }

        layoutHeaderColumns()
    }

    private func layoutHeaderColumns() {
        guard columnWidths.count == columns.count else { return }

        let chevronSize: CGFloat = 10
        let chevronSpacing: CGFloat = 3

        for (index, columnLabelLayer) in listLayers.headerTextLayers.enumerated() {
            let columnWidth = columnWidths[index]
            let currentX = columnOffsets[index]
            let inset = min(Self.cellContentHorizontalInset, columnWidth / 2)
            let isSorted = model.sortColumn == columns[index].sortKey
            let currentFont = isSorted ? headerFontHighlighted : headerFont
            let lineHeight = currentFont.ascender - currentFont.descender
            let yOffset: CGFloat = 6
            let chevronSpace = isSorted ? (chevronSize + chevronSpacing) : 0
            columnLabelLayer.frame = CGRect(x: Self.rowContentHorizontalInset + currentX + inset,
                                            y: yOffset,
                                            width: max(0, columnWidth - inset * 2 - chevronSpace),
                                            height: lineHeight)

            let indicatorLayer = listLayers.headerSortIndicatorLayers[index]
            let indicatorY = yOffset + (lineHeight - chevronSize) / 2
            let indicatorX = columnLabelLayer.frame.maxX + chevronSpacing
            indicatorLayer.frame = CGRect(x: indicatorX, y: indicatorY, width: chevronSize, height: chevronSize)
        }
    }

    private func visibleRowRangeForCurrentViewport(overscan: CGFloat? = nil) -> Range<Int> {
        let viewportLayer = listLayers.rowsViewportLayer
        let contentLayer = listLayers.rowsContentLayer
        let contentHeight = contentLayer.bounds.height > 0 ? contentLayer.bounds.height : CGFloat(model.displayedRowCount) * rowHeight
        guard viewportLayer.bounds.height > 0,
              contentHeight > 0,
              model.displayedRowCount > 0 else {
            return 0..<0
        }

        let appliedOverscan = max(overscan ?? rowsOverscan, 0)
        let visibleRect = viewportLayer.convert(viewportLayer.bounds, to: contentLayer)
        if visibleRect.height <= 0 {
            return 0..<0
        }

        let minY = max(visibleRect.minY - appliedOverscan, 0)
        let maxY = min(visibleRect.maxY + appliedOverscan, contentHeight)
        if maxY < minY {
            return 0..<0
        }

        let lower = max(Int(floor(minY / rowHeight)), 0)
        let upper = min(Int(ceil(maxY / rowHeight)), model.displayedRowCount)
        if upper < lower {
            return 0..<0
        }
        return lower..<upper
    }

    private func applyEntryContent(entry: RowData) {
        newSelectionState[entry.layerIndex] = if model.selectedProcess?.pid == entry.process.pid {
            if model.isWindowActive && model.isTableFirstResponder {
                RowSelectionState.selectedInKeyWindow
            } else {
                RowSelectionState.selectedInNonKeyWindow
            }
        } else {
            .notSelected
        }

        if rowVisuals[entry.layerIndex].commandText != entry.process.command {
            rowVisuals[entry.layerIndex].commandText = entry.process.command
            rowVisuals[entry.layerIndex].commandTextLayer.string = entry.process.command
        }

        if rowVisuals[entry.layerIndex].userText != entry.process.user {
            rowVisuals[entry.layerIndex].userText = entry.process.user
            rowVisuals[entry.layerIndex].userTextLayer.string = entry.process.user
        }
    }

    private func commitSpritePositions() {
        for layerIndex in rowVisuals.indices {
            if selectionState[layerIndex] != newSelectionState[layerIndex] {
                model.effectiveAppearance.performAsCurrentDrawingAppearance {
                    rowVisuals[layerIndex].background.backgroundColor = switch newSelectionState[layerIndex] {
                    case .notSelected:
                        CGColor.clear
                    case .selectedInKeyWindow:
                        activeSelectionBackgroundColor.cgColor
                    case .selectedInNonKeyWindow:
                        inactiveSelectionBackgroundColor.cgColor
                    }

                    updateCommandTextColor(layerIndex: layerIndex,
                                           selectionState: newSelectionState[layerIndex])
                    updateUserTextColor(layerIndex: layerIndex,
                                        selectionState: newSelectionState[layerIndex])
                    updateMemoryTextColor(layerIndex: layerIndex,
                                          selectionState: newSelectionState[layerIndex])
                }

                selectionState[layerIndex] = newSelectionState[layerIndex]
            }

            if memoryUnits[layerIndex] != newMemoryUnits[layerIndex] ||
                kernelMemoryFlags[layerIndex] != newKernelMemoryFlags[layerIndex] {
                // Re-layout this visual's memory container, using the new memory type

                memoryUnits[layerIndex] = newMemoryUnits[layerIndex]
                kernelMemoryFlags[layerIndex] = newKernelMemoryFlags[layerIndex]
                // TODO: it's gross that I have to look up this frame
                layoutMemoryCell(layerIndex: layerIndex, memoryFrame: rowVisuals[layerIndex].memoryContainer.frame)
            }

            let base = layerIndex * rowVisualBlockSize

            // Naive looping implementation
            // TODO: replace with a vectorized comparison of arrays, followed by a "number of trailing zeros" loop on bitvectors
            for offset in 0..<rowVisualBlockSize {
                let i = base + offset
                let spritePosition = newSpriteMapPositions[i]
                if spritePosition != spriteMapPositions[i] {
                    let spriteWidth = spriteWidths[offset]
                    spriteMapLayers[i].contentsRect = CGRect(x: CGFloat(spritePosition) * spriteWidth, y: 0, width: spriteWidth, height: 1)
                }
            }
        }

        spriteMapPositions = newSpriteMapPositions
    }

    private func logRowEvent(_ message: String) {
        guard rowAnimationLoggingEnabled else { return }
        print("[Rows] \(message)")
    }

    private func logViewportEvent(_ message: String) {
        print("[Viewport] \(message)")
    }

    private func alternatingRowColors() -> (even: CGColor, odd: CGColor) {
        var evenColor: CGColor = NSColor.controlBackgroundColor.cgColor
        var oddColor: CGColor = evenColor
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            let alternating = NSColor.alternatingContentBackgroundColors
            evenColor = NSColor.clear.cgColor
            if alternating.count >= 2 {
                oddColor = alternating[1].cgColor
            } else if let first = alternating.first {
                oddColor = first.cgColor
            } else {
                let background = NSColor.controlBackgroundColor
                oddColor = (background.blended(withFraction: 0.08, of: NSColor.labelColor)
                              ?? background).cgColor
            }
        }

        return (even: evenColor, odd: oddColor)
    }

    private func selectRow(at index: Int, ensureVisible: Bool = false) {
        guard index >= 0 else { return }
        if model.displayedRowCount > 0 && index >= model.displayedRowCount {
            return
        }
        if ensureVisible {
            ensureSelectedRowVisible(at: index)
        }


        guard let entry = entry(atGlobalIndex: index) else { return }

        updateSelection(.init(pid: entry.process.pid, name: entry.process.command))
    }

    func clearSelection() {
        updateSelection(nil)
    }

    private func commitSelectionState() {
        for layerIndex in rowVisuals.indices {
            let prevAtlasNumber = selectionState[layerIndex].rawValue
            let atlasNumber = newSelectionState[layerIndex].rawValue

            let delta = atlasNumber - prevAtlasNumber

            if delta != 0 {
                rowVisuals[layerIndex].background.backgroundColor = switch newSelectionState[layerIndex] {
                case .notSelected:
                    CGColor.clear
                case .selectedInKeyWindow:
                    activeSelectionBackgroundColor.cgColor
                case .selectedInNonKeyWindow:
                    inactiveSelectionBackgroundColor.cgColor
                }

                let base = layerIndex * rowVisualBlockSize

                for offset in 0..<rowVisualBlockSize {
                    let i = base + offset
                    let atlasDelta = delta * spriteMapLengths[offset]
                    let curr = newSpriteMapPositions[i]
                    let new = curr != blank ? Int8(curr + atlasDelta) : blank
                    newSpriteMapPositions[i] = new
                    if new != blank {
                        let spriteWidth = spriteWidths[offset]
                        spriteMapLayers[i].contentsRect = CGRect(x: CGFloat(new) * spriteWidth, y: 0, width: spriteWidth, height: 1)
                    }
                }

                selectionState[layerIndex] = newSelectionState[layerIndex]
            }
        }
    }

    private func updateSelection(_ processInfo: ProcessMonitorListModel.ProcessInfo?) {
        if model.selectedProcess?.pid == processInfo?.pid { return }
        model.selectedProcess = processInfo

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            for (_, entries) in streamEntries {
                for entry in entries {
                    newSelectionState[entry.layerIndex] = if entry.process.pid == model.selectedProcess?.pid {
                        if model.isWindowActive && model.isTableFirstResponder {
                            .selectedInKeyWindow
                        } else {
                            .selectedInNonKeyWindow
                        }
                    } else {
                        .notSelected
                    }

                    updateCommandTextColor(layerIndex: entry.layerIndex,
                                           selectionState: newSelectionState[entry.layerIndex])
                    updateUserTextColor(layerIndex: entry.layerIndex,
                                        selectionState: newSelectionState[entry.layerIndex])
                    updateMemoryTextColor(layerIndex: entry.layerIndex,
                                          selectionState: newSelectionState[entry.layerIndex])
                }
            }

            commitSelectionState()
        }
        CATransaction.commit()
        mainController?.onSelectionChanged()
    }

    func keyDown(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, modifierFlags: NSEvent.ModifierFlags, isARepeat: Bool) -> Bool {

        switch keyCode {
        case 125: // Down arrow
            moveSelection(by: 1)
            return true
        case 126: // Up arrow
            moveSelection(by: -1)
            return true
        case 51, 117: // Delete, Forward Delete
            if let selectedProcess = model.selectedProcess {
                mainController?.promptToStopProcess(selectedProcess)
                return true
            }
        default:
            break
        }

        return false
    }

    private func moveSelection(by delta: Int) {
        guard delta != 0 else { return }
        guard model.displayedRowCount > 0 else {
            clearSelection()
            return
        }

        var currentIndex: Int? = nil
        if let selectedProcess = model.selectedProcess {
            for (rowStart, entries) in streamEntries {
                for (offset, entry) in entries.enumerated() {
                    if entry.process.pid == selectedProcess.pid {
                        currentIndex = rowStart + offset
                    }
                }
            }
        }

        let targetIndex = if let currentIndex {
            min(max(currentIndex + delta, 0), model.displayedRowCount - 1)
        } else {
            0
        }

        selectRow(at: targetIndex, ensureVisible: true)
    }

    private func ensureSelectedRowVisible(at index: Int) {
        let viewportLayer = listLayers.rowsViewportLayer
        let viewportHeight = viewportLayer.bounds.height
        guard viewportHeight > 0 else { return }

        let contentHeight = CGFloat(model.displayedRowCount) * rowHeight
        let rowTop = CGFloat(index) * rowHeight
        let rowBottom = rowTop + rowHeight

        var targetOffset = currentScrollOffset
        if rowTop < currentScrollOffset {
            targetOffset = rowTop
        } else if rowBottom > currentScrollOffset + viewportHeight {
            targetOffset = rowBottom - viewportHeight
        }

        let clampedOffset = clampScrollOffset(targetOffset, contentHeight: contentHeight, viewportHeight: viewportHeight)
        if abs(clampedOffset - currentScrollOffset) < 0.5 {
            return
        }

        rowsScrollbarController.cancelAnimation()
        setRowsScrollOffset(clampedOffset)
    }

    private func rowIndex(atRootPoint point: CGPoint, rootLayer: CALayer) -> Int? {
        let rowsViewport = listLayers.rowsViewportLayer
        let rowsContent = listLayers.rowsContentLayer

        let pointInViewport = rowsViewport.convert(point, from: rootLayer)
        guard rowsViewport.bounds.contains(pointInViewport) else { return nil }

        let pointInContent = rowsContent.convert(point, from: rootLayer)
        if pointInContent.x < 0 || pointInContent.x > rowsContent.bounds.width {
            return nil
        }
        if pointInContent.y < 0 {
            return nil
        }

        let index = Int(pointInContent.y / rowHeight)
        guard index >= 0, (model.displayedRowCount <= 0 || index < model.displayedRowCount) else { return nil }
        return index
    }

    private var digitsSpriteMap: CGImage?
    private var digitSize: CGSize = .zero

    private var decimalSeparatorImage: CGImage?
    private var decimalSeparatorSize: CGSize = .zero

    private var colonImage: CGImage?
    private var colonSize: CGSize = .zero

    private var kbImage: CGImage?
    private var kbSize: CGSize = .zero
    private var kbRightInset: CGFloat = 0

    private var mbImage: CGImage?
    private var mbSize: CGSize = .zero
    private var mbRightInset: CGFloat = 0

    private var gbImage: CGImage?
    private var gbSize: CGSize = .zero
    private var gbRightInset: CGFloat = 0

    private var kernelTextSize: CGSize = .zero
    private var kernelTextRightInset: CGFloat = 0
    private var memoryUnitRightInset: CGFloat = 0

    private var spaceSize: CGSize = .zero

    private func initializeSymbolImages() {
        func textRightInset(_ text: String, font: NSFont) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
            let advanceWidth = attributed.size().width
            return max(advanceWidth - bounds.maxX, 0)
        }

        do {
            let (image, atlasSize) = getSpriteMap(atlasText: Locale.current.decimalSeparator!)

            decimalSeparatorImage = image
            decimalSeparatorSize = CGSize(width: atlasSize.width / 3, height: atlasSize.height)
        }


        do {
            let (image, atlasSize) = getSpriteMap(atlasText: ":")

            colonImage = image
            colonSize = CGSize(width: atlasSize.width / 3, height: atlasSize.height)
        }

        do {
            // TODO: change this to actually use "KB" etc.
            let (image, atlasSize) = getSpriteMap(atlasText: "KB")

            kbImage = image
            kbSize = CGSize(width: atlasSize.width / 3, height: atlasSize.height)
            kbRightInset = textRightInset("KB", font: numericFont)
        }

        do {
            // TODO: change this to actually use "MB" and a space
            let (image, atlasSize) = getSpriteMap(atlasText: "MB")

            mbImage = image
            mbSize = CGSize(width: atlasSize.width / 3, height: atlasSize.height)
            mbRightInset = textRightInset("MB", font: numericFont)
        }

        do {
            // TODO: change this to actually use "GB" and a space
            let (image, atlasSize) = getSpriteMap(atlasText: "GB")

            gbImage = image
            gbSize = CGSize(width: atlasSize.width / 3, height: atlasSize.height)
            gbRightInset = textRightInset("GB", font: numericFont)
        }

        do {
            spaceSize = NSAttributedString(string: " ", attributes: [
                .font: numericFont,
                .foregroundColor: NSColor.textColor
            ]).size()
        }

        do {
            kernelTextSize = NSAttributedString(string: "kernel", attributes: [
                .font: commandFont,
                .foregroundColor: NSColor.textColor
            ]).size()
            kernelTextRightInset = textRightInset("kernel", font: commandFont)
        }

        memoryUnitRightInset = max(kbRightInset, max(mbRightInset, gbRightInset))
    }

    private func alignedMemoryUnitX(frameWidth: CGFloat,
                                    unitWidth: CGFloat,
                                    unitRightInset: CGFloat) -> CGFloat {
        frameWidth - unitWidth + unitRightInset - memoryUnitRightInset
    }

//    func writeCGImageToDesktop(_ image: CGImage, name: String = "debug") {
//        let url = FileManager.default.homeDirectoryForCurrentUser
//            .appendingPathComponent("transient")
//            .appendingPathComponent("\(name).png")
//
//        guard let dest = CGImageDestinationCreateWithURL(
//            url as CFURL,
//            UTType.png.identifier as CFString,
//            1,
//            nil
//        ) else { return }
//
//        CGImageDestinationAddImage(dest, image, nil)
//        CGImageDestinationFinalize(dest)
//    }

    private func getSpriteMap(atlasText: String) -> (CGImage, CGSize) {
        let scale = CGFloat(2)

        // TODO: reconsider this theme logic
        let isLightTheme = NSColor.controlBackgroundColor.am_brightness > 0.6

        let selectedColor = isLightTheme ? NSColor.white : NSColor.textColor
        let unemphasizedSelectedColor = NSColor.textColor

        let glyphSize = NSAttributedString(string: String(atlasText.prefix(1)), attributes: [
            .font: numericFont,
            .foregroundColor: NSColor.textColor
        ]).size()

        let atlasSize = CGSize(width: glyphSize.width * CGFloat(atlasText.count) * 3,
                               height: glyphSize.height)

        let pixelWidth = Int(round(atlasSize.width * scale))
        let pixelHeight = Int(round(atlasSize.height * scale))


        let context = CGContext(data: nil,
                                width: pixelWidth,
                                height: pixelHeight,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        context.scaleBy(x: scale, y: scale)

        func applyText(color: CGColor) {
            for character in atlasText {

                let layer = CATextLayer()
                layer.contentsScale = scale
                layer.font = numericFont
                layer.fontSize = numericFont.pointSize
                layer.foregroundColor = color
                layer.string = String(character)
                layer.alignmentMode = .left
                layer.frame = CGRect(origin: .zero,
                                     size: glyphSize)
                layer.render(in: context)

                context.translateBy(x: glyphSize.width, y: 0)

            }

        }

        applyText(color: NSColor.textColor.cgColor)
        applyText(color: selectedColor.cgColor)
        applyText(color: unemphasizedSelectedColor.cgColor)

        let image = context.makeImage()!
        return (image, atlasSize)
    }

    private func initializeDigitsSpriteMap() {
        // TODO: put this somewhere more principled
        initializeSymbolImages()

        let (image, atlasSize) = getSpriteMap(atlasText: "0123456789")

        digitsSpriteMap = image

        digitSize = CGSize(width: atlasSize.width / CGFloat(digitAtlasLength), height: atlasSize.height)
    }

    private func createRowVisual() -> Int {
        if let index = freeVisuals.popLast() {
            rowVisualIsFree[index] = false
            listLayers.rowsContentLayer.addSublayer(rowVisuals[index].container)
            return index
        }

        let container = CALayer()
        container.anchorPoint = .zero

        listLayers.rowsContentLayer.addSublayer(container)

        let viewportWidth = listLayers.rowsViewportLayer.bounds.width

        let background = CALayer()
        background.cornerRadius = rowBackgroundCornerRadius
        background.masksToBounds = true
        background.backgroundColor = NSColor.clear.cgColor
        background.frame = CGRect(origin: .zero, size: CGSize(width: viewportWidth, height: rowHeight)).insetBy(dx: Self.rowContentHorizontalInset, dy: rowBackgroundVerticalInset)
        container.addSublayer(background)

        let commandTextLayer = CATextLayer()
        let textContentsScale: CGFloat = 2
        commandTextLayer.contentsScale = textContentsScale
        commandTextLayer.font = commandFont
        commandTextLayer.fontSize = commandFont.pointSize
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            commandTextLayer.foregroundColor = bodyTextColor.cgColor
        }
        commandTextLayer.alignmentMode = .left
        commandTextLayer.truncationMode = .end
        commandTextLayer.isWrapped = false
        commandTextLayer.anchorPoint = CGPoint(x: 0, y: 0)
        commandTextLayer.string = ""
        container.addSublayer(commandTextLayer)

        let userTextLayer = CATextLayer()
        userTextLayer.contentsScale = textContentsScale
        userTextLayer.font = commandFont
        userTextLayer.fontSize = commandFont.pointSize
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            userTextLayer.foregroundColor = bodyTextColor.cgColor
        }
        userTextLayer.alignmentMode = .left
        userTextLayer.truncationMode = .end
        userTextLayer.isWrapped = false
        userTextLayer.anchorPoint = CGPoint(x: 0, y: 0)
        userTextLayer.string = ""
        container.addSublayer(userTextLayer)

        let memoryTextLayer = CATextLayer()
        memoryTextLayer.contentsScale = textContentsScale
        memoryTextLayer.font = commandFont
        memoryTextLayer.fontSize = commandFont.pointSize
        model.effectiveAppearance.performAsCurrentDrawingAppearance {
            memoryTextLayer.foregroundColor = bodyTextColor.cgColor
        }
        memoryTextLayer.alignmentMode = .right
        memoryTextLayer.truncationMode = .start
        memoryTextLayer.isWrapped = false
        memoryTextLayer.anchorPoint = CGPoint(x: 0, y: 0)
        memoryTextLayer.string = "kernel"
        memoryTextLayer.isHidden = true
        container.addSublayer(memoryTextLayer)

        let newArraySize = spriteMapLayers.count + rowVisualBlockSize
        spriteMapLayers.reserveCapacity(newArraySize)
        spriteMapPositions.reserveCapacity(newArraySize)
        newSpriteMapPositions.reserveCapacity(newArraySize)

        func addLayer(_ childContainer: CALayer, _ width: CGFloat, _ image: CGImage?) {
            let spriteMapLayer = CALayer()
            spriteMapLayer.contents = image
            spriteMapLayer.contentsRect = CGRect(x: -1, y: 0, width: width, height: 1)
            spriteMapLayer.contentsScale = 2
            childContainer.addSublayer(spriteMapLayer)
            spriteMapLayers.append(spriteMapLayer)
        }

        let cpuPercentContainer = CALayer()
        container.addSublayer(cpuPercentContainer)
        for _ in cpuUtilizationBegin..<cpuUtilizationEnd {
            addLayer(cpuPercentContainer, digitAtlasCharacterWidth, digitsSpriteMap)
        }
        addLayer(cpuPercentContainer, decimalAtlasCharacterWidth, decimalSeparatorImage)

        let cpuTimeContainer = CALayer()
        container.addSublayer(cpuTimeContainer)
        for _ in cpuTimeBegin..<cpuTimeEnd {
            addLayer(cpuTimeContainer, digitAtlasCharacterWidth, digitsSpriteMap)
        }
        addLayer(cpuTimeContainer, decimalAtlasCharacterWidth, decimalSeparatorImage)
        addLayer(cpuTimeContainer, colonAtlasCharacterWidth, colonImage)
        addLayer(cpuTimeContainer, colonAtlasCharacterWidth, colonImage)

        let memoryContainer = CALayer()
        container.addSublayer(memoryContainer)
        for _ in memoryDigitsBegin..<memoryDigitsEnd {
            addLayer(memoryContainer, digitAtlasCharacterWidth, digitsSpriteMap)
        }
        // wait for layout to actually set the image (use nil for now)
        // TODO: don't use this helper, then
        addLayer(memoryContainer, memoryUnitWidth, nil)
        addLayer(memoryContainer, decimalAtlasCharacterWidth, decimalSeparatorImage)

        let pidContainer = CALayer()
        container.addSublayer(pidContainer)
        for _ in pidBegin..<pidEnd {
            addLayer(pidContainer, digitAtlasCharacterWidth, digitsSpriteMap)
        }

        assert(pidEnd == rowVisualBlockSize)

        for _ in 0..<rowVisualBlockSize {
            spriteMapPositions.append(blank)
            newSpriteMapPositions.append(blank)
        }

        // Start with most common case: MB
        memoryUnits.append(.mb)
        newMemoryUnits.append(.mb)
        kernelMemoryFlags.append(false)
        newKernelMemoryFlags.append(false)

        // Most common case
        selectionState.append(.notSelected)
        newSelectionState.append(.notSelected)

        let visual = ProcessRowVisual(container: container,
                                      background: background,
                                      commandTextLayer: commandTextLayer,
                                      commandText: "",
                                      userTextLayer: userTextLayer,
                                      userText: "",
                                      cpuPercentContainer: cpuPercentContainer,
                                      cpuTimeContainer: cpuTimeContainer,
                                      memoryContainer: memoryContainer,
                                      memoryTextLayer: memoryTextLayer,
                                      pidContainer: pidContainer)


        let index = rowVisuals.count
        rowVisuals.append(visual)
        rowVisualIsFree.append(false)
        layoutVisual(layerIndex: index, widths: columnWidths, offsets: columnOffsets, rowHeight: rowHeight)
        return index
    }

    func rowColumnFrame(columnIndex: Int, widths: [CGFloat], offsets: [CGFloat], rowHeight: CGFloat) -> CGRect {
        let columnWidth = widths[columnIndex]
        let inset = min(ProcessTable.cellContentHorizontalInset, columnWidth / 2)
        return CGRect(x: ProcessTable.rowContentHorizontalInset + offsets[columnIndex] + inset,
                      y: 0,
                      width: max(0, columnWidth - inset * 2),
                      height: rowHeight)
    }

    private func commandTextFrame(for columnFrame: CGRect) -> CGRect {
        let lineHeight = commandFont.ascender - commandFont.descender
        let yOffset = max((columnFrame.height - lineHeight) / 2, 0)
        return CGRect(x: columnFrame.minX,
                      y: columnFrame.minY + yOffset,
                      width: columnFrame.width,
                      height: lineHeight)
    }

    private func updateCommandTextColor(layerIndex: Int,
                                        selectionState: RowSelectionState) {
        let color = switch selectionState {
        case .notSelected:
            bodyTextColor.cgColor
        case .selectedInKeyWindow:
            activeSelectionTextColor.cgColor
        case .selectedInNonKeyWindow:
            inactiveSelectionTextColor.cgColor
        }
        rowVisuals[layerIndex].commandTextLayer.foregroundColor = color
    }

    private func updateUserTextColor(layerIndex: Int,
                                     selectionState: RowSelectionState) {
        let color = switch selectionState {
        case .notSelected:
            bodyTextColor.cgColor
        case .selectedInKeyWindow:
            activeSelectionTextColor.cgColor
        case .selectedInNonKeyWindow:
            inactiveSelectionTextColor.cgColor
        }
        rowVisuals[layerIndex].userTextLayer.foregroundColor = color
    }

    private func updateMemoryTextColor(layerIndex: Int,
                                       selectionState: RowSelectionState) {
        let color = switch selectionState {
        case .notSelected:
            bodyTextColor.cgColor
        case .selectedInKeyWindow:
            activeSelectionTextColor.cgColor
        case .selectedInNonKeyWindow:
            inactiveSelectionTextColor.cgColor
        }
        rowVisuals[layerIndex].memoryTextLayer.foregroundColor = color
    }

    private func setMemorySpritesHidden(layerIndex: Int, hidden: Bool) {
        let base = layerIndex * rowVisualBlockSize
        for offset in memoryDigitsBegin...memoryDecimalOffset {
            spriteMapLayers[base + offset].isHidden = hidden
        }
    }

    // TODO prune input args
    private func layoutMemoryCell(layerIndex: Int, memoryFrame: CGRect) {
        let base = layerIndex * rowVisualBlockSize
        let memoryTextLayer = rowVisuals[layerIndex].memoryTextLayer

        if kernelMemoryFlags[layerIndex] {
            setMemorySpritesHidden(layerIndex: layerIndex, hidden: true)
            memoryTextLayer.isHidden = false
            let width = min(kernelTextSize.width, memoryFrame.width)
            let lineHeight = commandFont.ascender - commandFont.descender
            let yOffset = max((memoryFrame.height - lineHeight) / 2, 0)
            memoryTextLayer.frame = CGRect(x: memoryFrame.minX + max(memoryFrame.width - width + kernelTextRightInset - memoryUnitRightInset, 0),
                                           y: memoryFrame.minY + yOffset,
                                           width: width,
                                           height: lineHeight)
            return
        }

        setMemorySpritesHidden(layerIndex: layerIndex, hidden: false)
        memoryTextLayer.isHidden = true
        memoryTextLayer.frame = .zero

        switch memoryUnits[layerIndex] {
        case .kb:
            // TODO: set the unit string. use a stored CGImage? But I do still need to change this quickly when e.g. active state changes
            let memoryUnitSize = kbSize

            // No decimal
            let totalWidth: CGFloat = CGFloat(memoryDigitsLength) * digitSize.width + memoryUnitSize.width + spaceSize.width

            let startX = memoryFrame.width - totalWidth

            let y = max((memoryFrame.height - digitSize.height) / 2, 0)

            let digitsBase = base + memoryDigitsBegin

            for iDigit in 0..<memoryDigitsLength {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            // Unit
            do {
                let i = base + memoryUnitsOffset
                spriteMapLayers[i].frame =
                CGRect(origin: CGPoint(x: alignedMemoryUnitX(frameWidth: memoryFrame.width,
                                                             unitWidth: memoryUnitSize.width,
                                                             unitRightInset: kbRightInset),
                                       // TODO: remove digitSize
                                       y: max((memoryFrame.height - digitSize.height) / 2, 0)),
                       size: memoryUnitSize)
                spriteMapLayers[i].contents = kbImage
            }

            do {
                let i = base + memoryDecimalOffset
                spriteMapLayers[i].frame = .zero
            }

        case .mb:
            // Decimal with one digit after the decimal
            let memoryUnitSize = mbSize
            let totalWidth: CGFloat = CGFloat(memoryDigitsLength) * digitSize.width + decimalSeparatorSize.width + memoryUnitSize.width + spaceSize.width

            let startX = memoryFrame.width - totalWidth
            let y = max((memoryFrame.height - decimalSeparatorSize.height) / 2, 0)

            let digitsBase = base + memoryDigitsBegin

            // Digits before decimal
            for iDigit in 0..<(memoryDigitsLength - 1) {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }
            // Digit after decimal
            do {
                let iDigit = memoryDigitsLength - 1
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: memoryFrame.width - digitSize.width - memoryUnitSize.width - spaceSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            // Decimal
            do {
                let i = base + memoryDecimalOffset
                spriteMapLayers[i].frame =
                CGRect(origin: CGPoint(x: memoryFrame.width - digitSize.width - decimalSeparatorSize.width - memoryUnitSize.width - spaceSize.width,
                                       y: max((memoryFrame.height - digitSize.height) / 2, 0)),
                       size: decimalSeparatorSize)
            }

            // Unit
            do {
                let i = base + memoryUnitsOffset
                spriteMapLayers[i].frame =
                CGRect(origin: CGPoint(x: alignedMemoryUnitX(frameWidth: memoryFrame.width,
                                                             unitWidth: memoryUnitSize.width,
                                                             unitRightInset: mbRightInset),
                                       // TODO: remove digitSize
                                       y: max((memoryFrame.height - digitSize.height) / 2, 0)),
                       size: memoryUnitSize)
                spriteMapLayers[i].contents = mbImage
            }
        case .gb:
            // Decimal point, followed by two digits
            let memoryUnitSize = gbSize
            let totalWidth: CGFloat = CGFloat(memoryDigitsLength) * digitSize.width + decimalSeparatorSize.width + memoryUnitSize.width + spaceSize.width

            let startX = memoryFrame.width - totalWidth
            let y = max((memoryFrame.height - decimalSeparatorSize.height) / 2, 0)

            let digitsBase = base + memoryDigitsBegin

            // Digits before decimal
            for iDigit in 0..<(memoryDigitsLength - 2) {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }
            // Digits after decimal
            for iDigit in (memoryDigitsLength - 2)..<memoryDigitsLength {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width + decimalSeparatorSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            // Decimal
            do {
                let i = base + memoryDecimalOffset
                spriteMapLayers[i].frame =
                CGRect(origin: CGPoint(x: memoryFrame.width - (2 * digitSize.width) - decimalSeparatorSize.width - memoryUnitSize.width - spaceSize.width,
                                       y: max((memoryFrame.height - digitSize.height) / 2, 0)),
                       size: decimalSeparatorSize)
            }

            // Unit
            do {
                let i = base + memoryUnitsOffset
                spriteMapLayers[i].frame =
                CGRect(origin: CGPoint(x: alignedMemoryUnitX(frameWidth: memoryFrame.width,
                                                             unitWidth: memoryUnitSize.width,
                                                             unitRightInset: gbRightInset),
                                       // TODO: remove digitSize
                                       y: max((memoryFrame.height - digitSize.height) / 2, 0)),
                       size: memoryUnitSize)
                spriteMapLayers[i].contents = gbImage
            }
        }
    }

    private func layoutVisual(layerIndex: Int, widths: [CGFloat], offsets: [CGFloat], rowHeight: CGFloat) {
        rowVisuals[layerIndex].background.frame = CGRect(origin: .zero,
                                                         size: CGSize(width: listLayers.rowsViewportLayer.bounds.width,
                                                                      height: rowHeight))
            .insetBy(dx: Self.rowContentHorizontalInset, dy: rowBackgroundVerticalInset)

        let commandFrame = rowColumnFrame(columnIndex: 0, widths: widths, offsets: offsets, rowHeight: rowHeight)
        rowVisuals[layerIndex].commandTextLayer.frame = commandTextFrame(for: commandFrame)

        let userFrame = rowColumnFrame(columnIndex: 1, widths: widths, offsets: offsets, rowHeight: rowHeight)
        rowVisuals[layerIndex].userTextLayer.frame = commandTextFrame(for: userFrame)

        let base = layerIndex * rowVisualBlockSize

        //
        // % CPU
        //
        do {
            let cpuPercentFrame = rowColumnFrame(columnIndex: 2, widths: widths, offsets: offsets, rowHeight: rowHeight)
            rowVisuals[layerIndex].cpuPercentContainer.frame = cpuPercentFrame

            let numDigits = cpuUtilizationLength
            let totalWidth: CGFloat = CGFloat(numDigits) * digitSize.width + decimalSeparatorSize.width

            let startX = cpuPercentFrame.width - totalWidth
            let y = max((cpuPercentFrame.height - decimalSeparatorSize.height) / 2, 0)

            let digitsBase = base + cpuUtilizationBegin

            // Digits before decimal
            for iDigit in 0..<(numDigits - 1) {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }
            // Digit after decimal
            do {
                let iDigit = numDigits - 1
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: cpuPercentFrame.width - digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            // Decimal
            do {
                let i = base + cpuUtilizationDecimalOffset
                spriteMapLayers[i].frame =
                CGRect(origin: CGPoint(x: cpuPercentFrame.width - digitSize.width - decimalSeparatorSize.width,
                                       y: max((cpuPercentFrame.height - digitSize.height) / 2, 0)),
                       size: decimalSeparatorSize)
            }
        }

        //
        // CPU time
        //

        do {
            let cpuTimeFrame = rowColumnFrame(columnIndex: 3, widths: widths, offsets: offsets, rowHeight: rowHeight)
            rowVisuals[layerIndex].cpuTimeContainer.frame = cpuTimeFrame

            let numDigits = cpuTimeLength

            let totalWidth: CGFloat = CGFloat(numDigits) * digitSize.width + 2 * colonSize.width + decimalSeparatorSize.width

            let startX = cpuTimeFrame.width - totalWidth
            let y = max((cpuTimeFrame.height - colonSize.height) / 2, 0)

            let digitsBase = base + cpuTimeBegin

            // Digits before first colon
            for iDigit in 0..<4 {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }


            for iDigit in 4..<6 {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width + colonSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            for iDigit in 6..<8 {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width + 2 * colonSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            for iDigit in 8..<11 {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width + 2 * colonSize.width + decimalSeparatorSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }

            // Decimal
            do {
                let i = base + cpuTimeDecimalOffset
                spriteMapLayers[i].frame = CGRect(
                    origin: CGPoint(x: cpuTimeFrame.width - (3 * digitSize.width) - decimalSeparatorSize.width,
                                    y: max((cpuTimeFrame.height - digitSize.height) / 2, 0)),
                    size: colonSize)
            }

            // Hour colon
            do {
                let i = base + cpuTimeHourColonOffset
                spriteMapLayers[i].frame = CGRect(
                    origin: CGPoint(x: startX + (4 * digitSize.width),
                                    y: max((cpuTimeFrame.height - digitSize.height) / 2, 0)),
                    size: colonSize)
            }

            // Minute Colon
            do {
                let i = base + cpuTimeMinuteColonOffset
                spriteMapLayers[i].frame = CGRect(
                    origin: CGPoint(x: cpuTimeFrame.width - decimalSeparatorSize.width - (5 * digitSize.width) - colonSize.width,
                                    y: max((cpuTimeFrame.height - digitSize.height) / 2, 0)),
                    size: colonSize)
            }
        }

        //
        // MEMORY
        //
        do {
            let memoryFrame = rowColumnFrame(columnIndex: 4, widths: widths, offsets: offsets, rowHeight: rowHeight)
            rowVisuals[layerIndex].memoryContainer.frame = memoryFrame

            layoutMemoryCell(layerIndex: layerIndex, memoryFrame: memoryFrame)
        }

        //
        // PID
        //
        do {
            let pidFrame = rowColumnFrame(columnIndex: 5, widths: widths, offsets: offsets, rowHeight: rowHeight)
            rowVisuals[layerIndex].pidContainer.frame = pidFrame

            let totalWidth: CGFloat = CGFloat(pidLength) * digitSize.width

            let startX = pidFrame.width - totalWidth
            let y = max((pidFrame.height - digitSize.height) / 2, 0)

            let digitsBase = base + pidBegin

            for iDigit in 0..<pidLength {
                let i = digitsBase + iDigit
                spriteMapLayers[i].frame = CGRect(origin: CGPoint(x: startX + CGFloat(iDigit) * digitSize.width,
                                                                  y: y),
                                                  size: digitSize)
            }
        }
    }

    private func columnIndex(forX x: CGFloat, totalWidth: CGFloat) -> Int? {
        var currentX: CGFloat = 0
        for index in 0..<columns.count {
            let columnWidth = widthForColumn(at: index, totalWidth: totalWidth, currentX: currentX)
            let nextX = currentX + columnWidth
            if x >= currentX && x <= nextX {
                return index
            }
            currentX = nextX
        }
        return nil
    }

    private func handleSortSelection(for columnIndex: Int) {
        guard columnIndex >= 0 && columnIndex < columns.count else { return }
        let selectedColumn = columns[columnIndex].sortKey
        if let current = model.sortColumn,
            current == selectedColumn {
            model.sortAscending.toggle()
        } else {
            model.sortColumn = selectedColumn
            model.sortAscending = defaultSortAscending(for: selectedColumn)
        }
        streamEntries.removeAll(keepingCapacity: false)
        model.displayedRowCount = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateHeaderLabels()
        CATransaction.commit()
        mainController?.announceViewportToServer(immediate: true, force: true)
    }

    private func defaultSortAscending(for column: ProcessMonitorListModel.SortColumn) -> Bool {
        switch column {
        case .pid, .command, .user:
            return true
        case .cpu, .cpuTime, .memory:
            return false
        }
    }

    private func clampScrollOffset(_ offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return max(0, offset) }
        let maxOffset = max(contentHeight - viewportHeight, 0)
        if maxOffset <= 0 {
            return 0
        }
        return min(max(offset, 0), maxOffset)
    }

    private func yFromTop(_ top: CGFloat, height: CGFloat, containerHeight: CGFloat) -> CGFloat {
        guard containerHeight.isFinite else { return 0 }
        let available = max(containerHeight - height, 0)
        let origin = containerHeight - top - height
        if available <= 0 {
            return 0
        }
        return min(max(origin, 0), available)
    }

    private func text(for column: ProcessMonitorListModel.SortColumn, entry: ProcessEntry) -> String {
        switch column {
        case .command:
            return entry.command
        case .user:
            return entry.user
        default:
            return ""
        }
    }

    private func title(for column: Column) -> String {
        if column.sortKey == .cpuTime {
            return model.selection.historical ? column.title : "Total CPU Time"
        }
        return column.title
    }

    private func widthForColumn(at index: Int, totalWidth: CGFloat, currentX: CGFloat) -> CGFloat {
        if index == columns.count - 1 {
            return max(0, totalWidth - currentX)
        }
        return max(0, totalWidth * columns[index].weight)
    }
}

private func makeCGImageFromAlphaMaskData(_ data: Data,
                                          width: UInt32,
                                          height: UInt32,
                                          bytesPerRow: UInt32,
                                          tintColor: NSColor,
                                          appearance: NSAppearance) -> CGImage? {
    let pixelWidth = Int(width)
    let pixelHeight = Int(height)
    let maskBytesPerRow = Int(bytesPerRow)
    guard pixelWidth > 0, pixelHeight > 0, maskBytesPerRow >= pixelWidth else { return nil }
    guard data.count >= maskBytesPerRow * pixelHeight else { return nil }

    var resolvedColor: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        resolvedColor = tintColor.usingColorSpace(.sRGB)
    }
    guard let color = resolvedColor else { return nil }

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 1
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    var rgbaData = Data(count: pixelWidth * pixelHeight * 4)
    data.withUnsafeBytes { maskBytes in
        rgbaData.withUnsafeMutableBytes { rgbaBytes in
            guard let maskBaseAddress = maskBytes.baseAddress,
                  let rgbaBaseAddress = rgbaBytes.baseAddress else {
                return
            }
            let mask = maskBaseAddress.assumingMemoryBound(to: UInt8.self)
            let rgba = rgbaBaseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<pixelHeight {
                for x in 0..<pixelWidth {
                    let coverage = CGFloat(mask[y * maskBytesPerRow + x]) / 255
                    let outputAlpha = coverage * alpha
                    let offset = (y * pixelWidth + x) * 4
                    rgba[offset] = UInt8((red * outputAlpha * 255).rounded())
                    rgba[offset + 1] = UInt8((green * outputAlpha * 255).rounded())
                    rgba[offset + 2] = UInt8((blue * outputAlpha * 255).rounded())
                    rgba[offset + 3] = UInt8((outputAlpha * 255).rounded())
                }
            }
        }
    }

    guard let provider = CGDataProvider(data: rgbaData as CFData) else { return nil }
    return CGImage(width: pixelWidth,
                   height: pixelHeight,
                   bitsPerComponent: 8,
                   bitsPerPixel: 32,
                   bytesPerRow: pixelWidth * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: true,
                   intent: .defaultIntent)
}

extension ProcessTable: ScrollbarControllerDelegate {
    func scrollbarDidChangeScrollOffset(_ offset: CGFloat) {
        setRowsScrollOffset(offset)
    }
}

private extension NSColor {
    var am_brightness: CGFloat {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3.0
    }
}
