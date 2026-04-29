import AppKit
import CoreText
import QuartzCore

@MainActor
final class CPUStatsSection {
    enum StatKind {
        case idle
        case user
        case system
    }

    struct Values {
        let user: Double?
        let system: Double?
        let idle: Double?
    }

    let rootLayer: CALayer

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

    private struct TextImage {
        let image: CGImage
        let size: CGSize
        let scale: CGFloat
    }

    private struct SymbolImages {
        let dot: TextImage
        let percent: TextImage
        let placeholder: TextImage
    }

    private struct RowResources {
        let atlas: DigitAtlas
        let symbols: SymbolImages
        let label: TextImage
    }

    private struct Resources {
        let title: TextImage
        let idle: RowResources
        let user: RowResources
        let system: RowResources
    }

    private struct RowLayers {
        let labelLayer: CALayer
        var digitLayers: [CALayer]
        let dotLayer: CALayer
        let percentLayer: CALayer
        let placeholderLayer: CALayer
    }

    private struct ValueColors {
        var idle: NSColor
        var user: NSColor
        var system: NSColor
    }

    private struct DigitAtlasCache {
        var idle: DigitAtlas?
        var user: DigitAtlas?
        var system: DigitAtlas?
    }

    private struct LabelImageCache {
        var idle: TextImage?
        var user: TextImage?
        var system: TextImage?
    }

    private struct SymbolImageCache {
        var idle: SymbolImages?
        var user: SymbolImages?
        var system: SymbolImages?
    }

    private let appConnection: OuterframeHost
    private let model: ProcessMonitorListModel
    private weak var mainController: ProcessMonitorListContentController?

    private var currentAppearance: NSAppearance {
        model.effectiveAppearance
    }

    private let titleFont: NSFont
    private let labelFont: NSFont
    private let valueFont: NSFont
    private let rowSpacing: CGFloat
    private let labelSpacing: CGFloat = 6
    private let digitSpacing: CGFloat = 0
    private let symbolSpacing: CGFloat = 1
    private let titleSpacing: CGFloat

    private let contentLayer = CALayer()
    private let titleLayer = CALayer()
    private let rowsLayer = CALayer()

    private var titleColor: NSColor
    private var labelColor: NSColor
    private var valueColors: ValueColors

    private var digitAtlases = DigitAtlasCache()
    private var labelImages = LabelImageCache()
    private var symbolImages = SymbolImageCache()
    private var titleImage: TextImage?
    private var currentResources: Resources?
    private var idleRow: RowLayers?
    private var userRow: RowLayers?
    private var systemRow: RowLayers?
    private var currentValues = Values(user: nil, system: nil, idle: nil)
    private var currentLogicalCpuCount: Int = 1
    private var cachedMaxDigits: Int?
    private var cachedLogicalCpuCount: Int?
    private var needsLayerRebuild = true
    private var currentIntegerDigits: Int = 0
    private var currentDigitAdvance: CGFloat = 0
    private var currentDotSize: CGSize = .zero
    private var currentValueWidth: CGFloat = 0
    private var currentContentWidth: CGFloat = 0
    private var builtIntegerDigits: Int = 0

    init(appConnection: OuterframeHost,
         model: ProcessMonitorListModel,
         mainController: ProcessMonitorListContentController,
         hostLayer: CALayer,
         titleFont: NSFont,
         labelFont: NSFont,
         valueFont: NSFont,
         rowSpacing: CGFloat) {
        self.appConnection = appConnection
        self.model = model
        self.mainController = mainController
        self.titleFont = titleFont
        self.labelFont = labelFont
        self.valueFont = valueFont
        self.rowSpacing = rowSpacing
        self.titleSpacing = rowSpacing

        let defaultColor = NSColor.labelColor
        self.titleColor = defaultColor
        self.labelColor = defaultColor
        self.valueColors = ValueColors(idle: defaultColor,
                                       user: defaultColor,
                                       system: defaultColor)

        rootLayer = CALayer()
        rootLayer.backgroundColor = CGColor.clear
        rootLayer.isGeometryFlipped = true
        rootLayer.contentsScale = max(hostLayer.contentsScale, 1)
        hostLayer.addSublayer(rootLayer)

        contentLayer.backgroundColor = CGColor.clear
        contentLayer.contentsScale = rootLayer.contentsScale
        rootLayer.addSublayer(contentLayer)

        titleLayer.contentsGravity = .resizeAspect
        contentLayer.addSublayer(titleLayer)

        rowsLayer.backgroundColor = CGColor.clear
        rowsLayer.contentsScale = rootLayer.contentsScale
        contentLayer.addSublayer(rowsLayer)
    }

    func setColors(title: NSColor, label: NSColor, user: NSColor, system: NSColor, idle: NSColor) {
        titleColor = title
        labelColor = label
        valueColors = ValueColors(idle: idle,
                                  user: user,
                                  system: system)
        digitAtlases = DigitAtlasCache()
        labelImages = LabelImageCache()
        symbolImages = SymbolImageCache()
        currentResources = nil
        idleRow = nil
        userRow = nil
        systemRow = nil
        titleImage = nil
        needsLayerRebuild = true
        render()
    }

    func updateValues(_ values: Values, logicalCpuCount: Int) {
        currentValues = values
        currentLogicalCpuCount = max(logicalCpuCount, 1)
        render()
    }

    func updateLayout() {
        render()
    }

    struct AccessibilityRowInfo {
        let labelText: String
        let labelFrame: CGRect
        let valueFrame: CGRect
        let currentValue: Double?
    }

    struct AccessibilityInfo {
        let titleFrame: CGRect
        let idleRow: AccessibilityRowInfo
        let userRow: AccessibilityRowInfo
        let systemRow: AccessibilityRowInfo
    }

    func accessibilityInfo() -> AccessibilityInfo? {
        guard let idleRow = idleRow,
              let userRow = userRow,
              let systemRow = systemRow else {
            return nil
        }

        func rowInfo(row: RowLayers, label: String, value: Double?) -> AccessibilityRowInfo {
            let labelFrame = rootLayer.convert(row.labelLayer.frame, from: rowsLayer)
            let valueStartX = row.digitLayers.first?.frame.minX ?? row.placeholderLayer.frame.minX
            let valueEndX = row.percentLayer.frame.maxX
            let valueY = row.digitLayers.first?.frame.minY ?? row.placeholderLayer.frame.minY
            let valueHeight = row.digitLayers.first?.frame.height ?? row.placeholderLayer.frame.height
            let valueFrameInRows = CGRect(x: valueStartX, y: valueY, width: valueEndX - valueStartX, height: valueHeight)
            let valueFrame = rootLayer.convert(valueFrameInRows, from: rowsLayer)
            return AccessibilityRowInfo(labelText: label, labelFrame: labelFrame, valueFrame: valueFrame, currentValue: value)
        }

        let titleFrameInContent = titleLayer.frame
        let titleFrame = rootLayer.convert(titleFrameInContent, from: contentLayer)

        return AccessibilityInfo(
            titleFrame: titleFrame,
            idleRow: rowInfo(row: idleRow, label: "Idle", value: currentValues.idle),
            userRow: rowInfo(row: userRow, label: "User", value: currentValues.user),
            systemRow: rowInfo(row: systemRow, label: "System", value: currentValues.system)
        )
    }

    private func render() {
        let bounds = rootLayer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        currentAppearance.performAsCurrentDrawingAppearance {
            self.renderContents(in: bounds)
        }
    }

    private func buildResources() -> Resources? {
        guard let title = buildTitleImage(),
              let idle = buildRowResources(for: .idle),
              let user = buildRowResources(for: .user),
              let system = buildRowResources(for: .system) else {
            return nil
        }
        return Resources(title: title, idle: idle, user: user, system: system)
    }

    private func buildRowResources(for kind: StatKind) -> RowResources? {
        guard let atlas = digitAtlas(for: kind),
              let symbols = buildSymbolImages(for: kind),
              let label = buildLabelImage(for: kind) else {
            return nil
        }
        return RowResources(atlas: atlas, symbols: symbols, label: label)
    }

    private func renderContents(in bounds: CGRect) {
        contentLayer.frame = bounds
        currentResources = nil

        let maxDigits = computeMaxDigits(logicalCpuCount: currentLogicalCpuCount)
        if cachedMaxDigits != maxDigits {
            cachedMaxDigits = maxDigits
            needsLayerRebuild = true
        }

        guard let resources = buildResources() else { return }
        currentResources = resources
        let titleImage = resources.title

        let digitWidth = max(resources.idle.atlas.glyphSize.width,
                             resources.user.atlas.glyphSize.width,
                             resources.system.atlas.glyphSize.width)
        let digitHeight = max(resources.idle.atlas.glyphSize.height,
                              resources.user.atlas.glyphSize.height,
                              resources.system.atlas.glyphSize.height)
        let digitAdvance = digitWidth + digitSpacing

        let dotSize = maxSize(resources.idle.symbols.dot.size,
                              resources.user.symbols.dot.size,
                              resources.system.symbols.dot.size)
        let percentSize = maxSize(resources.idle.symbols.percent.size,
                                  resources.user.symbols.percent.size,
                                  resources.system.symbols.percent.size)
        let placeholderSize = maxSize(resources.idle.symbols.placeholder.size,
                                      resources.user.symbols.placeholder.size,
                                      resources.system.symbols.placeholder.size)

        let integerDigits = max(maxDigits - 1, 1)
        let contentDigitsWidth = CGFloat(integerDigits) * digitAdvance
        let valueWidth = contentDigitsWidth + digitSpacing + dotSize.width + symbolSpacing + percentSize.width
        let labelMaxWidth = max(resources.idle.label.size.width,
                                resources.user.label.size.width,
                                resources.system.label.size.width)
        let availableLabelWidth = max(bounds.width - valueWidth - labelSpacing, 0)
        let labelWidth = min(labelMaxWidth, availableLabelWidth)
        let contentWidth = labelWidth + labelSpacing + valueWidth
        let rowHeight = max(digitHeight, dotSize.height, percentSize.height, placeholderSize.height)
        let titleHeight = titleImage.size.height

        titleLayer.isHidden = false
        titleLayer.contents = titleImage.image
        titleLayer.contentsScale = titleImage.scale
        titleLayer.frame = CGRect(x: 0,
                                  y: 0,
                                  width: titleImage.size.width,
                                  height: titleImage.size.height)

        let startY = titleHeight + titleSpacing
        let rowsWidth = max(contentWidth, bounds.width)
        rowsLayer.frame = CGRect(x: 0,
                                 y: startY,
                                 width: rowsWidth,
                                 height: max(0, bounds.height - startY))

        let rowsIncomplete = idleRow == nil || userRow == nil || systemRow == nil
        if needsLayerRebuild || rowsIncomplete || builtIntegerDigits != integerDigits {
            rebuildRows(integerDigits: integerDigits, resources: resources)
        }

        currentIntegerDigits = integerDigits
        currentDigitAdvance = digitAdvance
        currentDotSize = dotSize
        currentValueWidth = valueWidth
        currentContentWidth = contentWidth

        layoutRows(rowHeight: rowHeight,
                   digitSize: CGSize(width: digitWidth, height: digitHeight),
                   labelWidth: labelWidth,
                   contentWidth: contentWidth,
                   startY: 0,
                   dotSize: dotSize,
                   percentSize: percentSize,
                   placeholderSize: placeholderSize,
                   idle: resources.idle,
                   user: resources.user,
                   system: resources.system)

        needsLayerRebuild = false
        updateRowValues()
    }

    private func rebuildRows(integerDigits: Int, resources: Resources) {
        idleRow = nil
        userRow = nil
        systemRow = nil
        rowsLayer.sublayers?.forEach { sublayer in
            sublayer.removeFromSuperlayer()
        }

        func makeRow(_ rowResources: RowResources) -> RowLayers {
            let labelLayer = CALayer()
            labelLayer.contentsGravity = .resizeAspect
            labelLayer.contentsScale = rowsLayer.contentsScale
            rowsLayer.addSublayer(labelLayer)

            var digitLayers: [CALayer] = []
            digitLayers.reserveCapacity(integerDigits)
            for _ in 0..<integerDigits {
                let digitLayer = CALayer()
                digitLayer.contentsGravity = .resizeAspect
                digitLayer.contentsScale = rowResources.atlas.scale
                digitLayer.isHidden = true
                digitLayer.contents = rowResources.atlas.image
                rowsLayer.addSublayer(digitLayer)
                digitLayers.append(digitLayer)
            }

            let dotLayer = CALayer()
            dotLayer.contents = rowResources.symbols.dot.image
            dotLayer.contentsScale = rowResources.symbols.dot.scale
            rowsLayer.addSublayer(dotLayer)

            let percentLayer = CALayer()
            percentLayer.contents = rowResources.symbols.percent.image
            percentLayer.contentsScale = rowResources.symbols.percent.scale
            rowsLayer.addSublayer(percentLayer)

            let placeholderLayer = CALayer()
            placeholderLayer.contents = rowResources.symbols.placeholder.image
            placeholderLayer.contentsScale = rowResources.symbols.placeholder.scale
            rowsLayer.addSublayer(placeholderLayer)

            return RowLayers(labelLayer: labelLayer,
                             digitLayers: digitLayers,
                             dotLayer: dotLayer,
                             percentLayer: percentLayer,
                             placeholderLayer: placeholderLayer)
        }

        idleRow = makeRow(resources.idle)
        userRow = makeRow(resources.user)
        systemRow = makeRow(resources.system)
        builtIntegerDigits = integerDigits
    }

    private func layoutRows(rowHeight: CGFloat,
                            digitSize: CGSize,
                            labelWidth: CGFloat,
                            contentWidth: CGFloat,
                            startY: CGFloat,
                            dotSize: CGSize,
                            percentSize: CGSize,
                            placeholderSize: CGSize,
                            idle: RowResources,
                            user: RowResources,
                            system: RowResources) {
        guard let idleRow = idleRow,
              let userRow = userRow,
              let systemRow = systemRow else { return }

        let digitWidth = digitSize.width
        let digitHeight = digitSize.height
        let digitAdvance = currentDigitAdvance
        let integerDigits = currentIntegerDigits
        let startX = contentWidth - currentValueWidth

        func layoutRow(_ row: RowLayers, _ rowResources: RowResources, _ rowIndex: Int) {
            let rowY = startY + CGFloat(rowIndex) * (rowHeight + self.rowSpacing)
            row.labelLayer.isHidden = false
            row.labelLayer.contents = rowResources.label.image
            row.labelLayer.contentsScale = rowResources.label.scale
            row.labelLayer.frame = CGRect(x: 0,
                                          y: rowY + (rowHeight - rowResources.label.size.height) / 2,
                                          width: min(rowResources.label.size.width, labelWidth),
                                          height: rowResources.label.size.height)

            let digitsY = rowY + (rowHeight - digitHeight) / 2
            for digitIndex in 0..<row.digitLayers.count {
                let digitLayer = row.digitLayers[digitIndex]
                var x = startX + digitAdvance * CGFloat(digitIndex)
                if digitIndex == integerDigits - 1 {
                    x += dotSize.width + self.digitSpacing
                }
                digitLayer.frame = CGRect(x: x,
                                          y: digitsY,
                                          width: digitWidth,
                                          height: digitHeight)
            }

            row.dotLayer.frame = CGRect(x: startX + CGFloat(integerDigits - 1) * digitAdvance,
                                        y: rowY + (rowHeight - dotSize.height) / 2,
                                        width: dotSize.width,
                                        height: dotSize.height)

            row.percentLayer.frame = CGRect(x: contentWidth - percentSize.width,
                                            y: rowY + (rowHeight - percentSize.height) / 2,
                                            width: percentSize.width,
                                            height: percentSize.height)

            row.placeholderLayer.frame = CGRect(x: startX,
                                                y: rowY + (rowHeight - placeholderSize.height) / 2,
                                                width: placeholderSize.width,
                                                height: placeholderSize.height)
        }

        layoutRow(idleRow, idle, 0)
        layoutRow(userRow, user, 1)
        layoutRow(systemRow, system, 2)
    }

    private func updateRowValues() {
        guard let resources = currentResources,
              let idleRow = idleRow,
              let userRow = userRow,
              let systemRow = systemRow else { return }
        let dotSize = currentDotSize
        let digitAdvance = currentDigitAdvance
        let contentWidth = currentContentWidth
        let valueWidth = currentValueWidth
        let startX = contentWidth - valueWidth

        func updateRow(_ row: RowLayers, _ rowResources: RowResources, _ value: Double?) {
            if let value {
                row.placeholderLayer.isHidden = true
                row.dotLayer.isHidden = false
                row.percentLayer.isHidden = false

                var digitsBuffer = [CChar](repeating: 0, count: 32)
                var length = Int(formatNumberWithFractionDigitsFast(value, 1, &digitsBuffer, digitsBuffer.count))
                if length <= 0 {
                    let clamped = max(value, 0)
                    let formatted = String(format: "%.1f", clamped)
                    let utf8 = formatted.utf8
                    length = min(utf8.count, digitsBuffer.count - 1)
                    var idx = 0
                    for byte in utf8.prefix(length) {
                        digitsBuffer[idx] = CChar(bitPattern: byte)
                        idx += 1
                    }
                    digitsBuffer[min(idx, digitsBuffer.count - 1)] = 0
                }

                let digitCount = max(length - 1, 2)
                let targetIntegerDigits = max(digitCount - 1, 1)
                let total = row.digitLayers.count
                var x = startX
                var fractionalStartX: CGFloat?
                for i in 0..<total {
                    let targetIndex = digitCount - total + i
                    let layer = row.digitLayers[i]
                    if targetIndex >= 0, targetIndex < digitCount {
                        if targetIndex >= targetIntegerDigits && fractionalStartX == nil {
                            x += dotSize.width + self.digitSpacing
                            fractionalStartX = x
                        }
                        let decimalIndex = max(length - 2, 0)
                        let bufferIndex = targetIndex >= decimalIndex ? targetIndex + 1 : targetIndex
                        if bufferIndex >= 0, bufferIndex < length {
                            let byte = digitsBuffer[bufferIndex]
                            if byte >= 48, byte <= 57,
                               let rect = rowResources.atlas.rect(for: Character(UnicodeScalar(UInt8(bitPattern: byte)))) {
                                layer.isHidden = false
                                layer.contentsRect = rect
                            } else {
                                layer.isHidden = true
                            }
                            x += digitAdvance
                            continue
                        }
                    }
                    layer.isHidden = true
                    x += digitAdvance
                }
            } else {
                row.placeholderLayer.isHidden = false
                row.dotLayer.isHidden = true
                row.percentLayer.isHidden = true
                for layer in row.digitLayers {
                    layer.isHidden = true
                }
                row.placeholderLayer.contents = rowResources.symbols.placeholder.image
                row.placeholderLayer.contentsScale = rowResources.symbols.placeholder.scale
            }
        }

        updateRow(idleRow, resources.idle, currentValues.idle)
        updateRow(userRow, resources.user, currentValues.user)
        updateRow(systemRow, resources.system, currentValues.system)
    }

    private func computeMaxDigits(logicalCpuCount: Int) -> Int {
        if let cachedMaxDigits,
           let cachedLogicalCpuCount,
           cachedLogicalCpuCount == logicalCpuCount {
            return cachedMaxDigits
        }
        let maxValue = Double(max(logicalCpuCount, 1)) * 100.0
        let formatted = String(format: "%.1f", maxValue)
        let digitCount = formatted.count
        cachedMaxDigits = digitCount
        cachedLogicalCpuCount = logicalCpuCount
        return digitCount
    }

    private func digitAtlas(for kind: StatKind) -> DigitAtlas? {
        switch kind {
        case .idle:
            if let atlas = digitAtlases.idle {
                return atlas
            }
            guard let atlas = buildDigitAtlas(for: valueColors.idle) else { return nil }
            digitAtlases.idle = atlas
            return atlas
        case .user:
            if let atlas = digitAtlases.user {
                return atlas
            }
            guard let atlas = buildDigitAtlas(for: valueColors.user) else { return nil }
            digitAtlases.user = atlas
            return atlas
        case .system:
            if let atlas = digitAtlases.system {
                return atlas
            }
            guard let atlas = buildDigitAtlas(for: valueColors.system) else { return nil }
            digitAtlases.system = atlas
            return atlas
        }
    }

    private func buildLabelImage(for kind: StatKind) -> TextImage? {
        let text: String
        switch kind {
        case .idle:
            text = "Idle:"
        case .user:
            text = "User:"
        case .system:
            text = "System:"
        }
        switch kind {
        case .idle:
            if let image = labelImages.idle {
                return image
            }
            guard let image = makeTextImage(text: text, font: labelFont, color: labelColor) else { return nil }
            labelImages.idle = image
            return image
        case .user:
            if let image = labelImages.user {
                return image
            }
            guard let image = makeTextImage(text: text, font: labelFont, color: labelColor) else { return nil }
            labelImages.user = image
            return image
        case .system:
            if let image = labelImages.system {
                return image
            }
            guard let image = makeTextImage(text: text, font: labelFont, color: labelColor) else { return nil }
            labelImages.system = image
            return image
        }
    }

    private func buildSymbolImages(for kind: StatKind) -> SymbolImages? {
        switch kind {
        case .idle:
            if let symbols = symbolImages.idle {
                return symbols
            }
            guard let dot = makeTextImage(text: ".", font: valueFont, color: valueColors.idle),
                  let percent = makeTextImage(text: "%", font: valueFont, color: valueColors.idle),
                  let placeholder = makeTextImage(text: "—", font: valueFont, color: valueColors.idle) else {
                return nil
            }
            let symbols = SymbolImages(dot: dot, percent: percent, placeholder: placeholder)
            symbolImages.idle = symbols
            return symbols
        case .user:
            if let symbols = symbolImages.user {
                return symbols
            }
            guard let dot = makeTextImage(text: ".", font: valueFont, color: valueColors.user),
                  let percent = makeTextImage(text: "%", font: valueFont, color: valueColors.user),
                  let placeholder = makeTextImage(text: "—", font: valueFont, color: valueColors.user) else {
                return nil
            }
            let symbols = SymbolImages(dot: dot, percent: percent, placeholder: placeholder)
            symbolImages.user = symbols
            return symbols
        case .system:
            if let symbols = symbolImages.system {
                return symbols
            }
            guard let dot = makeTextImage(text: ".", font: valueFont, color: valueColors.system),
                  let percent = makeTextImage(text: "%", font: valueFont, color: valueColors.system),
                  let placeholder = makeTextImage(text: "—", font: valueFont, color: valueColors.system) else {
                return nil
            }
            let symbols = SymbolImages(dot: dot, percent: percent, placeholder: placeholder)
            symbolImages.system = symbols
            return symbols
        }
    }

    private func buildTitleImage() -> TextImage? {
        if let titleImage {
            return titleImage
        }
        let image = makeTextImage(text: "CPU Usage", font: titleFont, color: titleColor)
        titleImage = image
        return image
    }

    private func buildDigitAtlas(for color: NSColor) -> DigitAtlas? {
        let characters: [Character] = Array("0123456789")
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        let attributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
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
        let baseScale = max(rootLayer.contentsScale, 1)
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

    private func makeTextImage(text: String, font: NSFont, color: NSColor) -> TextImage? {
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: resolvedColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let size = CGSize(width: max(ceil(width), 1), height: max(ceil(ascent + descent), 1))
        let baseScale = max(rootLayer.contentsScale, 1)
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
        return TextImage(image: image, size: size, scale: scale)
    }

    private func maxSize(_ a: CGSize, _ b: CGSize, _ c: CGSize) -> CGSize {
        CGSize(width: max(a.width, b.width, c.width),
               height: max(a.height, b.height, c.height))
    }
}
