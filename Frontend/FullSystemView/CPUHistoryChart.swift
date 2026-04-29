import AppKit
import CoreText
import QuartzCore

@MainActor
final class CPUHistoryChart {
    enum TimePoint: Equatable {
        case now
        case absolute(time: TimeInterval)
    }

    enum TimeRange: Equatable {
        case absolute(range: ClosedRange<TimeInterval>)
        case moving(ago: TimeInterval)
    }

    enum Selection: Equatable {
        case range(range: TimeRange)
        case point(time: TimePoint)
        case none

        var duration: TimeInterval {
            switch self {
            case .range(let range):
                switch range {
                case .absolute(let range):
                    return range.upperBound - range.lowerBound
                case .moving(let ago):
                    return ago
                }
            case .point:
                return 1
            case .none:
                return 0
            }
        }

        var historical: Bool {
            switch self {
            case .range(let range):
                switch range {
                case .absolute:
                    true
                case .moving:
                    false
                }
            case .point(let time):
                switch time {
                case .now:
                    false
                case .absolute:
                    true
                }
            case .none:
                false
            }
        }

        func timeBasedRange(boundEnd: TimeInterval) -> ClosedRange<TimeInterval>? {
            switch self {
            case .range(let range):
                switch range {
                case .absolute(let actualRange):
                    return actualRange
                case .moving(let ago):
                    return (boundEnd - ago)...boundEnd
                }

            case .point(let time):
                switch time {
                case .now:
                    return (boundEnd - 1)...boundEnd
                case .absolute(let actualTime):
                    return (actualTime - 1)...actualTime
                }
            case .none:
                return nil
            }
        }
    }

    private let appConnection: OuterframeHost
    private let model: ProcessMonitorListModel

    let rootLayer: CALayer

    private let chartContainerLayer = CALayer()
    private let systemAreaLayer = CAShapeLayer()
    private let userAreaLayer = CAShapeLayer()
    private let baselineLayer = CALayer()
    private let selectionDimmingLayer = CALayer()
    private let selectionDimLeftLayer = CALayer()
    private let selectionDimRightLayer = CALayer()
    private let selectionOverlayLayer = CALayer()
    private let selectionFillLayer = CALayer()
    private let selectionLeftHandleLayer = CALayer()
    private let selectionRightHandleLayer = CALayer()
//    private let selectionPointLayer = CALayer()
    private let selectionTooltipLayer = CALayer()
    private let selectionTooltipTextLayer: CATextLayer
    private let hoverOverlayLayer = CALayer()
    private let hoverLineLayer = CAShapeLayer()
    private let hoverValueBackgroundLayer = CAShapeLayer()
    private let hoverValueContainerLayer = CALayer()
    private var hoverMaxLabelWidth = CGFloat(0)
    private let tickContainerLayer = CALayer()
    private var verticalTickLineLayers: [CALayer] = []
    private var verticalTickTextLayers: [CATextLayer] = []
    private var verticalTickCoverLayers: [CALayer] = []
    private var horizontalTickLineLayers: [CALayer] = []
    private var horizontalTickTextLayers: [CATextLayer] = []

    let boundsDuration: TimeInterval = 180

    private var hoverFraction: CGFloat?
    private var selectionDragState: SelectionDragState = .none
    private var hoveredSelectionHandle: SelectionHandle? {
        didSet {
            if hoveredSelectionHandle != nil && oldValue == nil {
                appConnection.performHapticFeedback(.alignment)
            }
        }
    }
    private var selectionTooltipMode: SelectionTooltipMode = .hidden
    private var maxDisplayPercent: Double = 100
    private var currentlyDisplayedMaxDisplayPercent: Double = 0
    private var currentlyDisplayedChartFrame: CGRect = .zero
    private var tickTargets: [ChartTickTarget] = []
    private var hoverRows: [HoverRowLayers] = []
    private var hoverDigitAtlas: DigitAtlas?
    private var hoverLabelImages: (user: HoverLabelImage, system: HoverLabelImage)? = nil
    private var hoverSymbolImages: (dot: HoverLabelImage, percent: HoverLabelImage)? = nil
    private var cachedMaxHoverDigits: Int?
    private var cachedMaxHoverDigitsLogicalCpuCount: Int?
    private var digitsBuffer = Data(count: 32)
    private var hoverLinePathHeight: CGFloat = 0
    private var hoverLinePathCached: Bool = false
    private var currentCursor: PluginCursorType?
    private var hoverBackgroundSize: CGSize = .zero
    private var prevSelectionOverlayFrame: CGRect = .zero

    weak var mainController: ProcessMonitorListContentController?

    private var currentAppearance: NSAppearance {
        model.effectiveAppearance
    }

    private let userColor: NSColor
    private let systemColor: NSColor

    private let tickLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let hoverValueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let selectionTooltipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private let verticalLabelHeight: CGFloat = 18
    private let rightLabelWidth: CGFloat = 70
    private let selectionPointWidth: CGFloat = 2
    private let selectionEdgeTolerance: TimeInterval = 0.5
    private let selectionHandleWidth: CGFloat = 2
    private let selectionHandleHitSlop: CGFloat = 8
    private let selectionPointDisplayThreshold: TimeInterval = 0.75
    private let minimumSelectionDuration: TimeInterval = 0.5
    private let pointSelectionMinimumDuration: TimeInterval = 0.5
    private let hoverValuePadding: CGFloat = 6
    private let hoverDigitSpacing: CGFloat = 1
    private let hoverSymbolSpacing: CGFloat = 1
    private let verticalLabelSpacing: CGFloat = 4

    init(appConnection: OuterframeHost, model: ProcessMonitorListModel, hostLayer: CALayer, userColor: NSColor, systemColor: NSColor,
         mainController: ProcessMonitorListContentController) {
        self.appConnection = appConnection
        self.model = model
        self.userColor = userColor
        self.systemColor = systemColor
        self.mainController = mainController

        rootLayer = CALayer()
        rootLayer.backgroundColor = CGColor.clear
        rootLayer.isGeometryFlipped = true
        hostLayer.addSublayer(rootLayer)

        chartContainerLayer.masksToBounds = true
        chartContainerLayer.cornerRadius = 6
        chartContainerLayer.backgroundColor = CGColor.clear
        rootLayer.addSublayer(chartContainerLayer)

        systemAreaLayer.fillColor = CGColor.clear
        systemAreaLayer.strokeColor = nil
        systemAreaLayer.lineJoin = .round
        systemAreaLayer.lineCap = .round
        chartContainerLayer.addSublayer(systemAreaLayer)

        userAreaLayer.fillColor = CGColor.clear
        userAreaLayer.strokeColor = nil
        userAreaLayer.lineJoin = .round
        userAreaLayer.lineCap = .round
        chartContainerLayer.addSublayer(userAreaLayer)

        baselineLayer.backgroundColor = CGColor.clear
        chartContainerLayer.addSublayer(baselineLayer)

        selectionDimmingLayer.backgroundColor = CGColor.clear
        selectionDimmingLayer.isHidden = true
        chartContainerLayer.addSublayer(selectionDimmingLayer)
        selectionDimmingLayer.addSublayer(selectionDimLeftLayer)
        selectionDimmingLayer.addSublayer(selectionDimRightLayer)

        selectionOverlayLayer.isHidden = true
        selectionOverlayLayer.masksToBounds = false
        chartContainerLayer.addSublayer(selectionOverlayLayer)

        selectionFillLayer.backgroundColor = CGColor.clear
        selectionFillLayer.zPosition = 0
        selectionOverlayLayer.addSublayer(selectionFillLayer)

        selectionLeftHandleLayer.zPosition = 1
        selectionOverlayLayer.addSublayer(selectionLeftHandleLayer)

        selectionRightHandleLayer.zPosition = 1
        selectionOverlayLayer.addSublayer(selectionRightHandleLayer)

//        selectionPointLayer.isHidden = true
//        chartContainerLayer.addSublayer(selectionPointLayer)

        selectionTooltipLayer.isHidden = true
        selectionTooltipLayer.masksToBounds = true
        selectionTooltipLayer.cornerRadius = 6

        func makeTextLayer(font: NSFont, alignment: CATextLayerAlignmentMode) -> CATextLayer {
            let textLayer = CATextLayer()
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            textLayer.alignmentMode = alignment
            textLayer.contentsScale = 2
            textLayer.truncationMode = .end
            return textLayer
        }

        selectionTooltipTextLayer = makeTextLayer(font: selectionTooltipFont, alignment: .center)
        selectionTooltipLayer.addSublayer(selectionTooltipTextLayer)

        hoverOverlayLayer.masksToBounds = false
        hoverOverlayLayer.isGeometryFlipped = false
        hoverOverlayLayer.zPosition = 1
        rootLayer.addSublayer(hoverOverlayLayer)

        hoverLineLayer.strokeColor = CGColor.clear
        hoverLineLayer.lineWidth = 1
        hoverLineLayer.lineDashPattern = [4, 3]
        hoverLineLayer.isHidden = true
        hoverOverlayLayer.addSublayer(hoverLineLayer)

        hoverValueBackgroundLayer.isHidden = true
        hoverValueBackgroundLayer.lineWidth = 1
        hoverValueBackgroundLayer.masksToBounds = false
        hoverValueBackgroundLayer.zPosition = 0
        hoverOverlayLayer.addSublayer(hoverValueBackgroundLayer)

        hoverValueContainerLayer.isHidden = true
        hoverValueContainerLayer.masksToBounds = false
        hoverValueContainerLayer.zPosition = 1
        hoverOverlayLayer.addSublayer(hoverValueContainerLayer)

        tickContainerLayer.zPosition = 0
        rootLayer.addSublayer(tickContainerLayer)

        for _ in 0..<8 {
            let line = CALayer()
            line.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            line.isHidden = true
            tickContainerLayer.addSublayer(line)
            verticalTickLineLayers.append(line)

            let label = makeTextLayer(font: tickLabelFont, alignment: .center)
            label.truncationMode = .none
            label.isHidden = true
            tickContainerLayer.addSublayer(label)
            verticalTickTextLayers.append(label)

            let cover = CALayer()
            cover.backgroundColor = NSColor.clear.cgColor
            cover.isHidden = true
            tickContainerLayer.addSublayer(cover)
            verticalTickCoverLayers.append(cover)
        }

        for _ in 0..<3 {
            let line = CALayer()
            line.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
            line.isHidden = true
            tickContainerLayer.addSublayer(line)
            horizontalTickLineLayers.append(line)

            let label = makeTextLayer(font: tickLabelFont, alignment: .right)
            label.isHidden = true
            tickContainerLayer.addSublayer(label)
            horizontalTickTextLayers.append(label)
        }

        selectionTooltipLayer.zPosition = tickContainerLayer.zPosition + 1
        rootLayer.addSublayer(selectionTooltipLayer)

        model.addCPUHistoryObserver { [weak self] _, _ in
            self?.updateChart()
        }

        currentAppearance.performAsCurrentDrawingAppearance {
            updateAppearance()
        }
    }

    // Public API
    func setSamples(_ newSamples: [ProcessMonitorListModel.CPUSample], logicalCpuCount: Int) {
        model.cpuHistory = newSamples
        if logicalCpuCount > 0 {
            model.logicalCpuCount = logicalCpuCount
        }
    }

    func setSelection(selection: Selection) {
        model.selection = selection
        updateSelectionOverlay()
    }

    func layout(in frame: CGRect) {
        rootLayer.frame = frame
        let chartFrame = CGRect(
            x: 0,
            y: 0,
            width: max(0, frame.width - rightLabelWidth),
            height: max(0, frame.height - verticalLabelHeight - verticalLabelSpacing)
        )
        chartContainerLayer.frame = chartFrame
        tickContainerLayer.frame = rootLayer.bounds

        let baselineHeight = max(1.0 / max(chartContainerLayer.contentsScale, 1), 0.5)
        baselineLayer.frame = CGRect(x: 0,
                                     y: max(chartFrame.height - baselineHeight, 0),
                                     width: chartFrame.width,
                                     height: baselineHeight)
        updateChart()
    }

    func updateAppearance() {
        // Colors are driven by the caller's current NSAppearance context
        chartContainerLayer.backgroundColor = NSColor.clear.cgColor
        baselineLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        systemAreaLayer.fillColor = systemColor.withAlphaComponent(0.7).cgColor
        userAreaLayer.fillColor = userColor.cgColor

        func brightness(color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3.0
        }

        let controlBackground = NSColor.controlBackgroundColor
        let isLightTheme = brightness(color: controlBackground) > 0.6
        let outsideColor = isLightTheme ? NSColor.black.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.18)
        selectionDimmingLayer.backgroundColor = NSColor.clear.cgColor
        selectionDimLeftLayer.backgroundColor = outsideColor.cgColor
        selectionDimRightLayer.backgroundColor = outsideColor.cgColor

        let labelColor = NSColor.labelColor
        let handleColor = labelColor
        selectionOverlayLayer.backgroundColor = NSColor.clear.cgColor
        selectionFillLayer.backgroundColor = NSColor.clear.cgColor
        selectionLeftHandleLayer.backgroundColor = handleColor.cgColor
        selectionRightHandleLayer.backgroundColor = handleColor.cgColor
//        selectionPointLayer.backgroundColor = handleColor.cgColor
        selectionTooltipLayer.backgroundColor = labelColor.withAlphaComponent(isLightTheme ? 0.9 : 0.8).cgColor
        selectionTooltipTextLayer.foregroundColor = NSColor.textBackgroundColor.cgColor

        hoverLineLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        hoverValueBackgroundLayer.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        hoverValueBackgroundLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        updateChart()

        let separator = NSColor.separatorColor
        for line in verticalTickLineLayers {
            line.backgroundColor = separator.withAlphaComponent(0.35).cgColor
        }
        for label in verticalTickTextLayers {
            label.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
        for cover in verticalTickCoverLayers {
            cover.backgroundColor = NSColor.clear.cgColor
        }
        for line in horizontalTickLineLayers {
            line.backgroundColor = separator.withAlphaComponent(0.25).cgColor
        }
        for label in horizontalTickTextLayers {
            label.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }

        hoverDigitAtlas = nil
        hoverLabelImages = nil
        hoverSymbolImages = nil
        hoverRows.removeAll()
        hoverValueContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        hoverLinePathHeight = 0
        hoverLinePathCached = false
        hoverBackgroundSize = .zero
    }

    // Click events (clicks on ticks or beginning a drag from some point) *should* animate.
    func handleMouseDown(at point: CGPoint) -> Bool {
        if let handle = selectionHandle(at: point), let range = currentSelectionRange() {
            let fixedPoint = switch handle {
            case .start:
                range.upper
            case .end:
                range.lower
            }

            hideHoverIndicator()
            selectionDragState = .inprogress(fixedPoint: fixedPoint)
            return true
        }

        if let tickTime = tickSelectionTime(at: point) {
            hoverFraction = nil

            model.selection = Selection.range(range: .moving(ago: currentBounds().end - tickTime))

            if let mainController {
                mainController.stateUpdateOnSelectionChange()

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                mainController.immediateUpdatesOnSelectionChange(isInTransaction: true)
                CATransaction.commit()


                CATransaction.begin()
                updateSelectionOverlay()
                mainController.animatedUpdatesOnSelectionChange(isInTransaction: true)
                CATransaction.commit()
            }

            return true
        }

        let pointInChart = chartContainerLayer.convert(point, from: rootLayer)

        if chartContainerLayer.bounds.contains(pointInChart) {
            selectionDragState = .inprogress(fixedPoint: timeForChartPoint(x: pointInChart.x))
            model.selection = Selection.point(time: timeForChartPoint(x: pointInChart.x))

            if let mainController {

                mainController.stateUpdateOnSelectionChange()

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                mainController.immediateUpdatesOnSelectionChange(isInTransaction: true)
                hideHoverIndicator()
                CATransaction.commit()

                CATransaction.begin()
                mainController.animatedUpdatesOnSelectionChange(isInTransaction: true)
                updateSelectionOverlay()
                CATransaction.commit()
            }

            return true
        }

        return false
    }

    func handleMouseDragged(at point: CGPoint) -> Bool {
        // Drag events *shouldn't* animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }

        guard let mainController else { return false }

        switch selectionDragState {
        case .inprogress(let fixedPoint):

            hideHoverIndicator()

            let bounds = currentBounds()
            let pointInChart = chartContainerLayer.convert(point, from: rootLayer)
            let otherPoint = timeForChartPoint(x: pointInChart.x)

            var newSelection: Selection = model.selection

            let tooltipData: (duration: TimeInterval, anchorX: CGFloat)?
            switch (fixedPoint, otherPoint) {
            case (.now, .now):
                newSelection = .point(time: .now)
                tooltipData = nil
            case (.now, .absolute(let otherTime)):
                let duration = bounds.end - otherTime
                newSelection = .range(range: .moving(ago: duration))
                tooltipData = (duration, min(max(pointInChart.x, 0), chartContainerLayer.bounds.width))

            case (.absolute(let otherTime), .now):
                let duration = bounds.end - otherTime
                newSelection = .range(range: .moving(ago: bounds.end - otherTime))
                tooltipData = (duration, min(max(pointInChart.x, 0), chartContainerLayer.bounds.width))
            case (.absolute(let fixedTime), .absolute(let otherTime)):
                let lower = min(fixedTime, otherTime)
                let upper = max(fixedTime, otherTime)
                newSelection = .range(range: .absolute(range: lower...upper))
                tooltipData = (upper - lower, min(max(pointInChart.x, 0), chartContainerLayer.bounds.width))
            }


            model.selection = newSelection
            mainController.stateUpdateOnSelectionChange()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateSelectionOverlay()
            if let tooltipData {
                showDurationTooltip(duration: tooltipData.duration, anchorX: tooltipData.anchorX)
            }
            mainController.immediateUpdatesOnSelectionChange(isInTransaction: true)
            CATransaction.commit()

            mainController.animatedUpdatesOnSelectionChange(isInTransaction: false)

            return true
        case .none:
            break
        }

        if tickSelectionTime(at: point) != nil {
            hideHoverIndicator()
            setCursorIfNeeded(.pointingHand)
            return true
        }

        let pointInGraph = chartContainerLayer.convert(point, from: rootLayer)
        if chartContainerLayer.bounds.contains(pointInGraph) {
            hoverFraction = pointInGraph.x / max(chartContainerLayer.bounds.width, 1)
            refreshHoverIndicator()
            return true
        }

        hideHoverIndicator()
        setCursorIfNeeded(.arrow)
        return false
    }

    func handleMouseUp(at point: CGPoint) -> Bool {
        let wasDragging: Bool
        switch selectionDragState {
        case .inprogress:
            wasDragging = true
            selectionDragState = .none
        case .none:
            wasDragging = false
        }
        defer {
            if wasDragging || selectionTooltipMode == .dragging {
                hideSelectionTooltip()
            }
        }
        if let handle = selectionHandle(at: point) {
            hoveredSelectionHandle = handle
            return true
        }
        if tickSelectionTime(at: point) != nil {
            return true
        }
        if chartContainerLayer.bounds.contains(chartContainerLayer.convert(point, from: rootLayer)) {
            return true
        }
        if wasDragging {
            return true
        }
        return false
    }

    func handleMouseMoved(at point: CGPoint) -> Bool {
        if case .none = selectionDragState {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer {
                CATransaction.commit()
            }
            let handle = selectionHandle(at: point)
            hoveredSelectionHandle = handle
            if handle != nil {
                setCursorIfNeeded(.resizeLeftRight)
            }
            if tickSelectionTime(at: point) != nil {
                hideHoverIndicator()
                setCursorIfNeeded(.pointingHand)
                return true
            }

            if handle == nil {
                setCursorIfNeeded(.arrow)
            }

            let pointInGraph = chartContainerLayer.convert(point, from: rootLayer)
            if chartContainerLayer.bounds.contains(pointInGraph) {
                hoverFraction = pointInGraph.x / max(chartContainerLayer.bounds.width, 1)
                refreshHoverIndicator()
                return true
            } else {
                hideHoverIndicator()
                return handle != nil
            }
        }
        return false
    }

    private func selectionHandle(at rootPoint: CGPoint) -> SelectionHandle? {
        guard !selectionOverlayLayer.isHidden else { return nil }
        let pointInOverlay = selectionOverlayLayer.convert(rootPoint, from: rootLayer)
        let leftFrame = selectionLeftHandleLayer.frame.insetBy(dx: -selectionHandleHitSlop, dy: -selectionHandleHitSlop)
        if leftFrame.contains(pointInOverlay) {
            return .start
        }
        let rightFrame = selectionRightHandleLayer.frame.insetBy(dx: -selectionHandleHitSlop, dy: -selectionHandleHitSlop)
        if rightFrame.contains(pointInOverlay) {
            return .end
        }
        return nil
    }

    private func setCursorIfNeeded(_ cursor: PluginCursorType) {
        guard currentCursor != cursor else { return }
        currentCursor = cursor
        appConnection.setCursor(cursor)
    }

    // MARK: - Internal chart state
    private enum SelectionDragState {
        case none
        case inprogress(fixedPoint: TimePoint)
    }

    private enum SelectionHandle: Equatable {
        case start
        case end
    }

    private enum SelectionTooltipMode: Equatable {
        case hidden
        case dragging
        case hovering(SelectionHandle)
    }

    private struct HoverRowLayers {
        let labelLayer: CALayer
        var digitLayers: [CALayer]
        let dotLayer: CALayer
        let percentLayer: CALayer
    }

    private struct DigitAtlas {
        let image: CGImage
        let glyphSize: CGSize
        let scale: CGFloat
        private static let asciiZero = Character("0").asciiValue ?? 48
        private static let asciiNine = Character("9").asciiValue ?? 57

        func rect(for character: Character) -> CGRect? {
            guard let asciiValue = character.asciiValue,
                  asciiValue >= Self.asciiZero,
                  asciiValue <= Self.asciiNine else {
                return nil
            }
            let index = Int(asciiValue - Self.asciiZero)
            let digitCount = Int(Self.asciiNine - Self.asciiZero) + 1
            let atlasWidth = glyphSize.width * CGFloat(digitCount)
            guard atlasWidth > 0 else { return nil }
            let x = glyphSize.width * CGFloat(index) / atlasWidth
            let width = glyphSize.width / atlasWidth
            return CGRect(x: x, y: 0, width: width, height: 1)
        }
    }

    private struct HoverLabelImage {
        let image: CGImage
        let size: CGSize
        let scale: CGFloat
    }

    private struct ChartTickTarget {
        let frameInRoot: CGRect
        let timeAgo: TimeInterval
    }

    private func currentBounds() -> (start: TimeInterval, end: TimeInterval) {
        let last = model.cpuHistory.last?.timestamp ?? CACurrentMediaTime()
        return (last - boundsDuration, last)
    }

    private func quantizedTime(_ time: TimeInterval) -> TimeInterval {
        return (time * 100).rounded(.toNearestOrAwayFromZero) / 100.0
    }

    private func timeForChartPoint(x: CGFloat) -> TimePoint {
        let bounds = currentBounds()
        let width = max(chartContainerLayer.bounds.width, 1)
        let normalized = min(max(Double(x / width), 0), 1)

        let t = bounds.start + (bounds.end - bounds.start) * normalized

        if Swift.abs(t - bounds.end) <= selectionEdgeTolerance {
            return .now
        } else {
            return .absolute(time: quantizedTime(t))
        }
    }

    private func updateChart() {
        let width = chartContainerLayer.bounds.width
        let height = chartContainerLayer.bounds.height

        let bounds = currentBounds()
        let visibleSamples = model.cpuHistory.drop(while: { $0.timestamp < bounds.start })

        let maxCombined = visibleSamples.compactMap { $0.combined }.max() ?? 100.0
        let coreScale = max(Double(model.logicalCpuCount), 1.0) * 100.0
        let dataScale = ceil(max(maxCombined, 100.0) / 100.0) * 100.0
        let chartScale = max(coreScale, dataScale)
        maxDisplayPercent = chartScale

        let bottom = height
        let yForPercent: (Double) -> CGFloat = { value in
            let clamped = min(max(value, 0), chartScale)
            let normalized = CGFloat(clamped / chartScale)
            return bottom - normalized * height
        }

        let windowDuration = max(bounds.end - bounds.start, 0.001)
        let xPositionForSample: (ProcessMonitorListModel.CPUSample) -> CGFloat = { sample in
            let clampedTime = min(max(sample.timestamp, bounds.start), bounds.end)
            let relative = (clampedTime - bounds.start) / windowDuration
            let normalized = min(max(relative, 0), 1)
            return CGFloat(normalized) * width
        }

        let baselineHeight = max(1.0 / max(chartContainerLayer.contentsScale, 1), 0.5)
        baselineLayer.frame = CGRect(x: 0,
                                     y: max(height - baselineHeight, 0),
                                     width: width,
                                     height: baselineHeight)
        baselineLayer.isHidden = false

        var samplePositions: [CGFloat] = []
        samplePositions.reserveCapacity(visibleSamples.count)
        for sample in visibleSamples {
            samplePositions.append(xPositionForSample(sample))
        }
        var boundaries: [CGFloat] = Array(repeating: 0, count: visibleSamples.count + 1)
        if visibleSamples.count == 1 {
            boundaries[0] = 0
            boundaries[1] = width
        } else if visibleSamples.count > 1 {
            boundaries[0] = max(0, samplePositions[0] - (samplePositions[1] - samplePositions[0]) / 2)
            for i in 0..<(visibleSamples.count - 1) {
                boundaries[i + 1] = (samplePositions[i] + samplePositions[i + 1]) * 0.5
            }
            boundaries[boundaries.count - 1] = min(width, samplePositions.last! + (samplePositions.last! - samplePositions[visibleSamples.count - 2]) / 2)
        } else {
            boundaries[0] = 0
            boundaries[boundaries.count - 1] = width
        }

        let whitespaceFraction: CGFloat = 0.08
        let systemAreaPath = CGMutablePath()
        let userAreaPath = CGMutablePath()
        for (index, sample) in visibleSamples.enumerated() {
            let leftBoundary = max(0, min(boundaries[index], width))
            let rightBoundary = max(leftBoundary, min(boundaries[index + 1], width))
            if rightBoundary <= leftBoundary {
                continue
            }
            var barWidth = rightBoundary - leftBoundary
            let spacing = barWidth * whitespaceFraction
            barWidth = max(barWidth - spacing, 1)
            let left = leftBoundary + spacing / 2

            let systemTop = yForPercent(sample.system)
            let combinedTop = yForPercent(sample.combined)

            let systemRect = CGRect(x: left,
                                    y: min(systemTop, bottom),
                                    width: barWidth,
                                    height: max(0, bottom - systemTop))
            systemAreaPath.addRect(systemRect)

            let userHeight = max(0, systemTop - combinedTop)
            if userHeight > 0 {
                let userRect = CGRect(x: left,
                                      y: min(combinedTop, systemTop),
                                      width: barWidth,
                                      height: userHeight)
                userAreaPath.addRect(userRect)
            }
        }

        systemAreaLayer.path = systemAreaPath
        userAreaLayer.path = userAreaPath
        updateTicks(bounds: bounds, chartScale: chartScale, chartFrame: chartContainerLayer.frame)
        updateSelectionOverlay()
        refreshHoverIndicator()
    }

    private func updateTicks(bounds: (start: TimeInterval, end: TimeInterval), chartScale: Double, chartFrame: CGRect) {
        if currentlyDisplayedMaxDisplayPercent == maxDisplayPercent,
           currentlyDisplayedChartFrame == chartFrame { return }

        tickContainerLayer.frame = rootLayer.bounds

        let duration = bounds.end - bounds.start
        let baseStep: TimeInterval = 30
        let minTickSpacing: CGFloat = 50
        let desiredTickCount: Int
        if chartContainerLayer.bounds.width > 0 {
            desiredTickCount = max(1, Int(chartContainerLayer.bounds.width / minTickSpacing))
        } else {
            desiredTickCount = 1
        }
        let idealStep = duration / Double(max(desiredTickCount, 1))
        var step = max(baseStep, ceil(idealStep / baseStep) * baseStep)
        if step.isNaN || step.isInfinite {
            step = baseStep
        }
        if step > duration && duration > 0 {
            step = duration
        }

        var current = bounds.end
        var tickIndex = 0
        tickTargets.removeAll(keepingCapacity: true)
        while current >= bounds.start && tickIndex < verticalTickLineLayers.count {
            let xInChart = xPosition(for: current,
                                     firstTimestamp: bounds.start,
                                     lastTimestamp: bounds.end,
                                     width: chartFrame.width)
            let x = chartFrame.minX + xInChart
            let line = verticalTickLineLayers[tickIndex]
            let label = verticalTickTextLayers[tickIndex]
            let cover = verticalTickCoverLayers[tickIndex]
            line.isHidden = false
            label.isHidden = false
            cover.isHidden = false

            line.frame = CGRect(x: x, y: chartFrame.minY, width: 1, height: chartFrame.height)
            label.string = formatTimeTickLabel(forOffset: bounds.end - current)
            let size = label.preferredFrameSize()
            label.frame = CGRect(x: x - size.width / 2,
                                 y: chartFrame.maxY + verticalLabelSpacing,
                                 width: size.width,
                                 height: verticalLabelHeight)
            let paddedLabel = label.frame.insetBy(dx: -6, dy: -2)
            cover.frame = paddedLabel
            let labelRectInRoot = rootLayer.convert(paddedLabel, from: tickContainerLayer)
            tickTargets.append(ChartTickTarget(frameInRoot: labelRectInRoot, timeAgo: bounds.end - current))

            current -= step
            tickIndex += 1
        }

        for i in tickIndex..<verticalTickLineLayers.count {
            verticalTickLineLayers[i].isHidden = true
            verticalTickTextLayers[i].isHidden = true
            verticalTickCoverLayers[i].isHidden = true
        }

        // Horizontal ticks - compute whole-number core ticks
        let tickValues = computeCoreTicks(chartScale: chartScale)
        for i in 0..<horizontalTickLineLayers.count {
            let line = horizontalTickLineLayers[i]
            let label = horizontalTickTextLayers[i]
            if i < tickValues.count {
                let value = tickValues[i]
                let y = chartFrame.minY + yPosition(forPercent: value, chartHeight: chartFrame.height)
                line.isHidden = false
                label.isHidden = false
                line.frame = CGRect(x: chartFrame.minX, y: y, width: chartFrame.width, height: 1)
                label.string = formatCoreTickLabel(forPercent: value)
                let size = label.preferredFrameSize()
                let labelX = chartFrame.maxX + 6
                label.frame = CGRect(x: labelX,
                                     y: y - size.height / 2,
                                     width: size.width,
                                     height: size.height)
            } else {
                line.isHidden = true
                label.isHidden = true
            }
        }

        currentlyDisplayedMaxDisplayPercent = maxDisplayPercent
        currentlyDisplayedChartFrame = chartFrame
    }

    private func hideTicks() {
        for line in verticalTickLineLayers { line.isHidden = true }
        for text in verticalTickTextLayers { text.isHidden = true }
        for cover in verticalTickCoverLayers { cover.isHidden = true }
        for line in horizontalTickLineLayers { line.isHidden = true }
        for text in horizontalTickTextLayers { text.isHidden = true }
        tickTargets.removeAll(keepingCapacity: true)
    }

    private func formatTimeTickLabel(forOffset offset: TimeInterval) -> String {
        if offset < 1 { return "Now" }
        let totalSeconds = max(Int(round(offset)), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "-%d:%02d", minutes, seconds)
    }

    private func formatCoreTickLabel(forPercent percent: Double) -> String {
        let cores = max(percent / 100.0, 0)
        let rounded = Int(round(cores))
        let suffix = rounded == 1 ? "core" : "cores"
        return "\(rounded) \(suffix)"
    }

    private func computeCoreTicks(chartScale: Double) -> [Double] {
        let coreCount = Int(round(chartScale / 100.0))
        if coreCount <= 0 { return [] }

        // For 1-3 cores, show a tick for each core
        if coreCount <= 3 {
            return (1...coreCount).map { Double($0) * 100.0 }
        }

        // For 4+ cores, find a step that gives 2-3 evenly spaced whole-number ticks
        let step: Int
        if coreCount % 3 == 0 {
            step = coreCount / 3  // Divisible by 3: show 3 ticks
        } else if coreCount % 2 == 0 {
            step = coreCount / 2  // Divisible by 2: show 2 ticks
        } else {
            // Odd number not divisible by 3: use ceiling division for ~2 ticks
            step = (coreCount + 2) / 3
        }

        var ticks: [Double] = []
        var current = step
        while current < coreCount && ticks.count < 2 {
            ticks.append(Double(current) * 100.0)
            current += step
        }
        // Always include the maximum
        ticks.append(Double(coreCount) * 100.0)

        return ticks
    }

    private func yPosition(forPercent percent: Double, chartHeight: CGFloat) -> CGFloat {
        guard chartHeight > 0 else { return 0 }
        let scale = max(maxDisplayPercent, 1)
        let clamped = min(max(percent, 0), scale)
        let normalized = CGFloat(clamped / scale)
        return chartHeight - normalized * chartHeight
    }

    private func xPosition(for time: TimeInterval,
                           firstTimestamp: TimeInterval,
                           lastTimestamp: TimeInterval,
                           width: CGFloat) -> CGFloat {
        guard lastTimestamp > firstTimestamp, width > 0 else { return 0 }
        let clamped = min(max(time, firstTimestamp), lastTimestamp)
        let relative = (clamped - firstTimestamp) / (lastTimestamp - firstTimestamp)
        return CGFloat(relative) * width
    }

    private func tickSelectionTime(at rootPoint: CGPoint) -> TimeInterval? {
        let pointInTicks = tickContainerLayer.convert(rootPoint, from: rootLayer)
        let boundsEnd = currentBounds().end
        for (index, target) in tickTargets.enumerated() {
            guard index < verticalTickTextLayers.count else { continue }
            let label = verticalTickTextLayers[index]
            if label.isHidden { continue }
            let padded = label.frame.insetBy(dx: -6, dy: -2)
            if padded.contains(pointInTicks) {
                return boundsEnd - target.timeAgo
            }
        }
        return nil
    }

    private func updateSelectionOverlay() {
        guard chartContainerLayer.bounds.width > 0 else { return }

        let bounds = currentBounds()
        let width = chartContainerLayer.bounds.width
        let height = chartContainerLayer.bounds.height

        let start: Double
        let end: Double
        switch model.selection {
        case .range(let range):
            selectionOverlayLayer.isHidden = false
            selectionDimmingLayer.isHidden = false
            switch range {
            case .absolute(let timeRange):
                let clampedLower = min(max(timeRange.lowerBound, bounds.start), bounds.end)
                let clampedUpper = min(max(timeRange.upperBound, bounds.start), bounds.end)
                start = ((clampedLower - bounds.start) / boundsDuration) * width
                end = ((clampedUpper - bounds.start) / boundsDuration) * width
            case .moving(let ago):
                let clampedAgo = min(max(ago, 0), boundsDuration)
                start = width * ((boundsDuration - clampedAgo) / boundsDuration)
                end = width
            }

        case .point(let time):
            selectionOverlayLayer.isHidden = false
            selectionDimmingLayer.isHidden = false

            let desiredPointWidth = max(width / CGFloat(boundsDuration), selectionHandleWidth * 2)

            switch time {
            case .now:
                let clampedWidth = min(desiredPointWidth, width)
                start = max(width - clampedWidth, 0)
                end = width
            case .absolute(let timestamp):
                let midpoint = ((timestamp - bounds.start) / boundsDuration) * width
                let halfWidth = min(desiredPointWidth, width) / 2
                start = midpoint - halfWidth
                end = midpoint + halfWidth
            }
        case .none:
            selectionOverlayLayer.isHidden = true
            selectionDimmingLayer.isHidden = true
            start = 0
            end = 0
        }

        let overlayFrame = CGRect(x: start, y: 0, width: Swift.abs(end - start), height: height)

        if overlayFrame == prevSelectionOverlayFrame {
            return
        }
        prevSelectionOverlayFrame = overlayFrame

        selectionOverlayLayer.frame = overlayFrame
        selectionFillLayer.frame = selectionOverlayLayer.bounds
        let handleOffset = selectionHandleWidth * 0.5
        selectionLeftHandleLayer.frame = CGRect(x: -handleOffset,
                                                y: 0,
                                                width: selectionHandleWidth,
                                                height: height)
        selectionRightHandleLayer.frame = CGRect(x: overlayFrame.width - handleOffset,
                                                 y: 0,
                                                 width: selectionHandleWidth,
                                                 height: height)
        selectionOverlayLayer.isHidden = false

        selectionDimmingLayer.frame = chartContainerLayer.bounds
        let lower = min(start, end)
        let upper = max(start, end)
        selectionDimLeftLayer.frame = CGRect(x: 0,
                                             y: 0,
                                             width: max(0, lower),
                                             height: height)
        selectionDimRightLayer.frame = CGRect(x: upper,
                                              y: 0,
                                              width: max(0, width - upper),
                                              height: height)
    }

    private func currentSelectionRange() -> (lower: TimePoint, upper: TimePoint)? {
        let bounds = currentBounds()
        switch model.selection {
        case .range(let range):
            switch range {
            case .absolute(let actualRange):
                return (.absolute(time: actualRange.lowerBound), .absolute(time: actualRange.upperBound))
            case .moving(let ago):
                return (.absolute(time: bounds.end - ago), .now)
            }

        case .point(let time):
            switch time {
            case .now:
                return (.absolute(time: bounds.end - 1), .now)
            case .absolute(let actualTime):
                return (.absolute(time: actualTime - 1), .absolute(time: actualTime))
            }
        case .none:
            return nil
        }
    }

    private func refreshHoverIndicator() {
        guard let fraction = hoverFraction else {
            hideHoverIndicator()
            return
        }

        let width = chartContainerLayer.bounds.width
        let height = chartContainerLayer.bounds.height
        let x = max(min(CGFloat(fraction) * width, width), 0)

        hoverLineLayer.isHidden = false
        if hoverLinePathHeight != height || !hoverLinePathCached {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: height))
            hoverLineLayer.path = path
            hoverLinePathHeight = height
            hoverLinePathCached = true
        }
        hoverLineLayer.position = CGPoint(x: x, y: 0)

        if let sample = closestSample(to: timeForChartPoint(x: x)) {
            updateHoverValue(for: sample, anchorX: x, chartWidth: width, chartHeight: height)
        } else {
            hoverValueBackgroundLayer.isHidden = true
            hoverValueContainerLayer.isHidden = true
        }
    }

    private func updateHoverValue(for sample: ProcessMonitorListModel.CPUSample, anchorX: CGFloat, chartWidth: CGFloat, chartHeight: CGFloat) {

        let atlas: DigitAtlas
        let hoverLabelImages: (user: HoverLabelImage, system: HoverLabelImage)
        let hoverSymbolImages: (dot: HoverLabelImage, percent: HoverLabelImage)
        if let hoverDigitAtlas,
           let hli = self.hoverLabelImages,
           let hsi = self.hoverSymbolImages {
            atlas = hoverDigitAtlas
            hoverLabelImages = hli
            hoverSymbolImages = hsi
        } else {
            var atlas2: DigitAtlas? = nil
            var hli: (user: HoverLabelImage, system: HoverLabelImage)? = nil
            var hsi: (dot: HoverLabelImage, percent: HoverLabelImage)? = nil

            currentAppearance.performAsCurrentDrawingAppearance {
                atlas2 = buildHoverDigitAtlas()
                hli = buildHoverLabelImages()
                hsi = buildHoverSymbolImages()
            }

            guard let atlas2,
                  let hli,
                  let hsi else { return }

            atlas = atlas2
            self.hoverDigitAtlas = atlas2
            hoverLabelImages = hli
            self.hoverLabelImages = hli
            hoverSymbolImages = hsi
            self.hoverSymbolImages = hsi

            hoverRows.removeAll()
            hoverValueContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        }

        let maxDigits: Int
        if let cachedMaxHoverDigits,
           cachedMaxHoverDigitsLogicalCpuCount == model.logicalCpuCount {
            maxDigits = cachedMaxHoverDigits
        } else {
            let maxValue = Double(model.logicalCpuCount) * 100.0
            let formatted = String(format: "%.1f", maxValue)
            maxDigits = formatted.count
            cachedMaxHoverDigits = maxDigits
            cachedMaxHoverDigitsLogicalCpuCount = model.logicalCpuCount
        }

        let labelSpacing: CGFloat = 6
        let digitWidth = atlas.glyphSize.width
        let digitHeight = atlas.glyphSize.height
        let digitAdvance = digitWidth + hoverDigitSpacing
        let rowSpacing: CGFloat = 4
        let padding: CGFloat = hoverValuePadding
        let dotSize = hoverSymbolImages.dot.size
        let percentSize = hoverSymbolImages.percent.size

        let dotSpacing: CGFloat = hoverDigitSpacing
        let contentDigitsWidth = CGFloat(maxDigits - 1) * digitAdvance

        let rowHeight = max(digitHeight,
                            dotSize.height,
                            percentSize.height)
        let contentHeight = rowHeight * 2 + rowSpacing

        let integerDigits = maxDigits - 1
        let needsRebuild = hoverRows.count != 2 || hoverRows.first?.digitLayers.count != integerDigits
        if needsRebuild {
            hoverRows.removeAll()
            hoverValueContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

            var labelLayers: [CALayer] = []
            var maxLabelWidth = CGFloat(0)

            let labelImages: [HoverLabelImage] = [hoverLabelImages.user, hoverLabelImages.system]
            for (imageIndex, image) in labelImages.enumerated() {
                let rowY = CGFloat(imageIndex) * (rowHeight + rowSpacing)

                let labelLayer = CALayer()
                labelLayer.contentsScale = image.scale
                labelLayer.contents = image.image
                let imageSize = image.size
                labelLayer.frame = CGRect(x: 0,
                                          y: rowY + (rowHeight - imageSize.height) / 2,
                                          width: imageSize.width,
                                          height: imageSize.height)
                maxLabelWidth = max(maxLabelWidth, imageSize.width)
                labelLayer.isHidden = false
                hoverValueContainerLayer.addSublayer(labelLayer)
                labelLayers.append(labelLayer)
            }

            let contentWidth = maxLabelWidth + labelSpacing + contentDigitsWidth + dotSpacing + dotSize.width + hoverSymbolSpacing + percentSize.width
            let bubbleSize = CGSize(width: contentWidth + padding * 2, height: contentHeight + padding * 2)
            hoverValueBackgroundLayer.bounds = CGRect(origin: .zero, size: bubbleSize)
            hoverValueBackgroundLayer.anchorPoint = CGPoint(x: 0, y: 0)

            for imageIndex in labelImages.indices {

                let rowY = CGFloat(imageIndex) * (rowHeight + rowSpacing)
                let digitsY = rowY + (rowHeight - digitHeight) / 2
                let startX = contentWidth - (contentDigitsWidth + dotSpacing + dotSize.width + hoverSymbolSpacing + percentSize.width)

                var digits: [CALayer] = []
                for iDigit in 0..<integerDigits {
                    let digitLayer = CALayer()
                    digitLayer.contentsScale = atlas.scale
                    digitLayer.contentsGravity = .resizeAspect
                    digitLayer.isHidden = true
                    digitLayer.contents = atlas.image
                    var x = startX + digitAdvance*CGFloat(iDigit)
                    if iDigit == integerDigits - 1 {
                        x += dotSize.width + dotSpacing
                    }
                    digitLayer.frame = CGRect(x: x,
                                         y: digitsY,
                                         width: digitWidth,
                                         height: digitHeight)
                    hoverValueContainerLayer.addSublayer(digitLayer)
                    digits.append(digitLayer)
                }

                let dotLayer = CALayer()
                dotLayer.contentsScale = hoverSymbolImages.dot.scale
                dotLayer.contents = hoverSymbolImages.dot.image
                dotLayer.frame = CGRect(x: startX + CGFloat(integerDigits - 1) * digitAdvance,
                                        y: rowY + (rowHeight - dotSize.height) / 2,
                                        width: dotSize.width,
                                        height: dotSize.height)
                hoverValueContainerLayer.addSublayer(dotLayer)

                let percentLayer = CALayer()
                percentLayer.contentsScale = hoverSymbolImages.percent.scale
                percentLayer.contents = hoverSymbolImages.percent.image
                percentLayer.frame = CGRect(x: contentWidth - percentSize.width,
                                            y: rowY + (rowHeight - percentSize.height) / 2,
                                            width: percentSize.width,
                                            height: percentSize.height)
                hoverValueContainerLayer.addSublayer(percentLayer)

                hoverRows.append(HoverRowLayers(labelLayer: labelLayers[imageIndex], digitLayers: digits, dotLayer: dotLayer, percentLayer: percentLayer))
            }

            self.hoverMaxLabelWidth = maxLabelWidth
        }

        let contentWidth = hoverMaxLabelWidth + labelSpacing + contentDigitsWidth + dotSpacing + dotSize.width + hoverSymbolSpacing + percentSize.width
        let bubbleSize = CGSize(width: contentWidth + padding * 2, height: contentHeight + padding * 2)

        var bubbleX = anchorX + 10
        if bubbleX + bubbleSize.width > chartWidth {
            bubbleX = anchorX - bubbleSize.width - 10
        }
        bubbleX = max(0, min(bubbleX, max(0, chartWidth - bubbleSize.width)))
        let bubbleY = max(0, min(chartHeight - bubbleSize.height, chartHeight * 0.2))

        hoverValueBackgroundLayer.isHidden = false
        hoverValueBackgroundLayer.position = CGPoint(x: bubbleX, y: bubbleY)
        if bubbleSize != hoverBackgroundSize {
            hoverValueBackgroundLayer.path = CGPath(roundedRect: CGRect(origin: .zero, size: bubbleSize), cornerWidth: 6, cornerHeight: 6, transform: nil)
            hoverBackgroundSize = bubbleSize
        }

        let contentOrigin = CGPoint(x: bubbleX + padding, y: bubbleY + padding)
        hoverValueContainerLayer.isHidden = false
        hoverValueContainerLayer.frame = CGRect(origin: contentOrigin, size: CGSize(width: contentWidth, height: contentHeight))


        func applyDigits(index: Int, value: Double) {
            guard index < hoverRows.count else { return }
            let row = hoverRows[index]
            let label = row.labelLayer
            label.isHidden = false

            let length = digitsBuffer.withUnsafeMutableBytes { rawBuffer in
                guard let buffer = rawBuffer.bindMemory(to: CChar.self).baseAddress,
                      rawBuffer.count > 0 else {
                    return 0
                }

                return Int(formatNumberWithFractionDigitsFast(value, 1, buffer, rawBuffer.count))
            }

            let digitCount = max(length - 1, 2)
            let integerDigits = max(digitCount - 1, 1)
            let digits = row.digitLayers
            let startX = contentWidth - (contentDigitsWidth + dotSpacing + dotSize.width + hoverSymbolSpacing + percentSize.width)
            let total = digits.count
            var fractionalStartX: CGFloat?
            var x = startX
            for i in 0..<total {
                let targetIndex = digitCount - total + i
                let layer = digits[i]
                if targetIndex >= 0, targetIndex < digitCount {
                    if targetIndex >= integerDigits && fractionalStartX == nil {
                        x += dotSize.width + dotSpacing
                        fractionalStartX = x
                    }
                    let decimalIndex = max(length - 2, 0)
                    let bufferIndex = targetIndex >= decimalIndex ? targetIndex + 1 : targetIndex
                    if bufferIndex >= 0, bufferIndex < length {
                        let byte = digitsBuffer[bufferIndex]
                        if byte >= 48, byte <= 57,
                           let rect = atlas.rect(for: Character(UnicodeScalar(byte))) {
                            layer.isHidden = false
                            layer.contentsRect = rect
                        }
                        x += digitAdvance
                        continue
                    }
                }
                layer.isHidden = true
                x += digitAdvance
            }
        }

        applyDigits(index: 0, value: sample.user)
        applyDigits(index: 1, value: sample.system)
    }

    private func buildHoverDigitAtlas() -> DigitAtlas? {
        let characters: [Character] = Array("0123456789")
        let resolvedColor = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: hoverValueFont,
            .foregroundColor: resolvedColor
        ]

        var maxWidth: CGFloat = 0
        var maxAscent: CGFloat = 0
        var maxDescent: CGFloat = 0
        var lines: [Character: CTLine] = [:]

        for character in characters {
            let attributed = NSAttributedString(string: String(character), attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            maxWidth = max(maxWidth, width)
            maxAscent = max(maxAscent, ascent)
            maxDescent = max(maxDescent, descent)
            lines[character] = line
        }

        let glyphWidth = max(ceil(maxWidth), 1)
        let glyphHeight = max(ceil(maxAscent + maxDescent), 1)
        let glyphSize = CGSize(width: glyphWidth, height: glyphHeight)
        let atlasSize = CGSize(width: glyphWidth * CGFloat(characters.count), height: glyphHeight)
        let baseScale = max(hoverOverlayLayer.contentsScale, 1)
        let scale = max(baseScale, 2)
        let pixelWidth = Int(round(atlasSize.width * scale))
        let pixelHeight = Int(round(atlasSize.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for (index, character) in characters.enumerated() {
            guard let line = lines[character] else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let x = CGFloat(index) * glyphSize.width
            let xOffset = (glyphSize.width - width) / 2
            let baselineY = maxDescent
            context.textPosition = CGPoint(x: x + xOffset, y: baselineY)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { return nil }
        return DigitAtlas(image: image, glyphSize: glyphSize, scale: scale)
    }

    private func buildHoverLabelImages() -> (user: HoverLabelImage, system: HoverLabelImage)? {
        let resolvedColor = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? NSColor.labelColor
        if let user = makeHoverLabelImage(text: "User", color: resolvedColor),
           let system = makeHoverLabelImage(text: "System", color: resolvedColor) {
            return (user: user, system: system)
        } else {
            return nil
        }
    }

    private func buildHoverSymbolImages() -> (dot: HoverLabelImage, percent: HoverLabelImage)? {
        let resolvedColor = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? NSColor.labelColor
        if let dot = makeHoverLabelImage(text: ".", color: resolvedColor),
           let percent = makeHoverLabelImage(text: "%", color: resolvedColor) {
            return (dot: dot, percent: percent)
        } else {
            return nil
        }
    }

    private func makeHoverLabelImage(text: String, color: NSColor) -> HoverLabelImage? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: hoverValueFont,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let size = CGSize(width: max(ceil(width), 1), height: max(ceil(ascent + descent), 1))
        let baseScale = max(hoverOverlayLayer.contentsScale, 1)
        let scale = max(baseScale, 2)
        let pixelWidth = Int(round(size.width * scale))
        let pixelHeight = Int(round(size.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return HoverLabelImage(image: image, size: size, scale: scale)
    }

    private func hideHoverIndicator() {
        hoverFraction = nil
        hoverLineLayer.isHidden = true
        hoverValueBackgroundLayer.isHidden = true
        hoverValueContainerLayer.isHidden = true
    }

    private func closestSample(to targetTime: TimePoint) -> ProcessMonitorListModel.CPUSample? {
        guard !model.cpuHistory.isEmpty else { return nil }

        let bounds = currentBounds()
        let targetTimestamp = switch targetTime {
        case .now:
            bounds.end
        case .absolute(let time):
            time
        }

        // Ignore if target is outside available samples.
        guard let first = model.cpuHistory.first else { return nil }
        guard targetTimestamp >= first.timestamp, targetTimestamp <= bounds.end else { return nil }

        var best: ProcessMonitorListModel.CPUSample?
        var bestDelta = TimeInterval.greatestFiniteMagnitude
        for sample in model.cpuHistory {
            let delta = Swift.abs(sample.timestamp - targetTimestamp)
            if delta < bestDelta {
                best = sample
                bestDelta = delta
            }
        }
        return best
    }

    private func showDurationTooltip(duration: TimeInterval, anchorX: CGFloat) {
        let text = formatDuration(duration)
        selectionTooltipTextLayer.string = text
        let size = selectionTooltipTextLayer.preferredFrameSize()
        let padding: CGFloat = 6
        let tooltipSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        // Center within the selected range if possible.
        let selectionMidX = selectionOverlayLayer.frame.midX
        let x = max(0, min(selectionMidX - tooltipSize.width / 2, max(0, chartContainerLayer.bounds.width - tooltipSize.width)))
        let y = min(chartContainerLayer.bounds.height - tooltipSize.height - 4, chartContainerLayer.bounds.height * 0.6)
        let localFrame = CGRect(origin: CGPoint(x: x, y: y), size: tooltipSize)
        selectionTooltipLayer.frame = chartContainerLayer.convert(localFrame, to: rootLayer)
        selectionTooltipTextLayer.frame = CGRect(x: padding, y: padding, width: size.width, height: size.height)
        selectionTooltipLayer.isHidden = false
        selectionTooltipMode = .dragging
    }

    private func hideSelectionTooltip() {
        selectionTooltipLayer.isHidden = true
        selectionTooltipMode = .hidden
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        if value < 1 { return String(format: "%.2fs", value) }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return String(format: "%ds", seconds)
    }
}
