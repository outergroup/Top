import AppKit
import QuartzCore

private let alertButtonHeight: CGFloat = 28
private let alertButtonSpacing: CGFloat = 12
private let alertButtonHorizontalPadding: CGFloat = 18
private let alertPanelHorizontalPadding: CGFloat = 24
private let alertPanelVerticalPadding: CGFloat = 24

@MainActor
final class ProcessQuitDialog {
    enum Action {
        case cancel
        case quit(force: Bool)
    }

    private struct QuitAlertButton {
        let container: CALayer
        let backgroundLayer: CALayer
        let textLayer: CATextLayer
        let action: Action
    }

    private weak var hostLayer: CALayer?
    private let overlayLayer: CALayer
    private let panelLayer: CALayer
    private let titleLayer: CATextLayer
    private let messageLayer: CATextLayer
    private let cancelButton: QuitAlertButton
    private let forceQuitButton: QuitAlertButton
    private let quitButton: QuitAlertButton
    private let outerframeHost: OuterframeHost
    private let appearance: NSAppearance
    private let onAction: (Action) -> Void
    private let pid: Int
    private let command: String
    private var pressedButton: QuitAlertButton?
    private var activeButton: QuitAlertButton?

    private let alertMessageFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    init(outerframeHost: OuterframeHost,
         appearance: NSAppearance,
         hostLayer: CALayer,
         pid: Int,
         command: String,
         onAction: @escaping (Action) -> Void) {
        self.outerframeHost = outerframeHost
        self.appearance = appearance
        self.hostLayer = hostLayer
        self.pid = pid
        self.command = command
        self.onAction = onAction

        overlayLayer = CALayer()
        overlayLayer.frame = hostLayer.bounds
        overlayLayer.opacity = 1.0
        overlayLayer.isHidden = false
        overlayLayer.zPosition = 2000
        hostLayer.addSublayer(overlayLayer)

        let panel = CALayer()
        panel.isGeometryFlipped = true
        panel.cornerRadius = 12
        panel.masksToBounds = false
        panel.borderWidth = 1
        panel.shadowOpacity = 0.18
        panel.shadowRadius = 16
        panel.shadowOffset = CGSize(width: 0, height: 2)
        overlayLayer.addSublayer(panel)
        panelLayer = panel

        func makeTextLayer(font: NSFont, alignment: CATextLayerAlignmentMode) -> CATextLayer {
            let textLayer = CATextLayer()
            textLayer.font = font
            textLayer.fontSize = font.pointSize
            textLayer.alignmentMode = alignment
            textLayer.contentsScale = 2
            return textLayer
        }

        titleLayer = makeTextLayer(font: NSFont.systemFont(ofSize: 17, weight: .semibold), alignment: .left)
        titleLayer.truncationMode = .end
        panel.addSublayer(titleLayer)

        messageLayer = makeTextLayer(font: alertMessageFont, alignment: .left)
        messageLayer.isWrapped = true
        messageLayer.truncationMode = .none
        panel.addSublayer(messageLayer)

        let buttonFont = NSFont.systemFont(ofSize: 13, weight: .regular)

        func makeButton(title: String, action: Action) -> QuitAlertButton {
            let container = CALayer()
            panel.addSublayer(container)

            let background = CALayer()
            background.cornerRadius = alertButtonHeight / 2
            background.masksToBounds = true
            background.borderWidth = 1
            container.addSublayer(background)

            let textLayer = makeTextLayer(font: buttonFont, alignment: .center)
            textLayer.truncationMode = .end
            textLayer.string = title
            container.addSublayer(textLayer)

            return QuitAlertButton(container: container,
                                   backgroundLayer: background,
                                   textLayer: textLayer,
                                   action: action)
        }

        cancelButton = makeButton(title: "Cancel", action: .cancel)
        forceQuitButton = makeButton(title: "Force Quit", action: .quit(force: true))
        quitButton = makeButton(title: "Quit", action: .quit(force: false))

        titleLayer.string = "Are you sure you want to quit this process?"
        messageLayer.string = "Do you really want to quit \"\(command)\"?"

        let hostBounds = hostLayer.bounds
        layout(in: hostBounds)

        appearance.performAsCurrentDrawingAppearance {
            updateAppearance()
        }
    }

    func dismiss() {
        overlayLayer.opacity = 0
        overlayLayer.isHidden = true
        overlayLayer.removeFromSuperlayer()
        hostLayer = nil
        pressedButton = nil
        activeButton = nil
    }

    func layout(in bounds: CGRect) {
        guard overlayLayer.superlayer != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        overlayLayer.frame = bounds

        guard !overlayLayer.isHidden else {
            CATransaction.commit()
            return
        }

        func metrics(for button: QuitAlertButton) -> (size: CGSize, width: CGFloat) {
            let textSize = button.textLayer.preferredFrameSize()
            let width = max(textSize.width + alertButtonHorizontalPadding * 2, 96)
            return (textSize, width)
        }

        let cancelMetrics = metrics(for: cancelButton)
        let forceQuitMetrics = metrics(for: forceQuitButton)
        let quitMetrics = metrics(for: quitButton)

        let totalButtonsWidth = cancelMetrics.width + forceQuitMetrics.width + quitMetrics.width
        let totalSpacing = alertButtonSpacing * 2
        let minimumPanelWidth = totalButtonsWidth + totalSpacing + alertPanelHorizontalPadding * 2
        let widthCap: CGFloat = 520
        let availableWidth = max(bounds.width - 40, minimumPanelWidth)
        let panelWidth = max(min(max(availableWidth, minimumPanelWidth), widthCap), minimumPanelWidth)
        let contentWidth = max(0, panelWidth - alertPanelHorizontalPadding * 2)

        let titleSize = titleLayer.preferredFrameSize()
        let messageString: String
        if let string = messageLayer.string as? String {
            messageString = string
        } else if let attributed = messageLayer.string as? NSAttributedString {
            messageString = attributed.string
        } else {
            messageString = ""
        }

        let boundingRect = NSAttributedString(string: messageString,
                                              attributes: [.font: alertMessageFont])
            .boundingRect(with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        let messageSize = CGSize(width: ceil(boundingRect.width), height: ceil(boundingRect.height))

        let titleMessageSpacing: CGFloat = 8
        let buttonsTopSpacing: CGFloat = 20
        let buttonsY = alertPanelVerticalPadding + titleSize.height + titleMessageSpacing + messageSize.height + buttonsTopSpacing

        var currentX = panelWidth - alertPanelHorizontalPadding
        let quitFrame = CGRect(x: (currentX - quitMetrics.width),
                               y: buttonsY,
                               width: quitMetrics.width,
                               height: alertButtonHeight)
        currentX -= quitMetrics.width + alertButtonSpacing

        let forceQuitFrame = CGRect(x: (currentX - forceQuitMetrics.width),
                                    y: buttonsY,
                                    width: forceQuitMetrics.width,
                                    height: alertButtonHeight)
        currentX -= forceQuitMetrics.width + alertButtonSpacing

        let cancelFrame = CGRect(x: (currentX - cancelMetrics.width),
                                 y: buttonsY,
                                 width: cancelMetrics.width,
                                 height: alertButtonHeight)

        let panelHeight = buttonsY + alertButtonHeight + alertPanelVerticalPadding
        let panelSize = CGSize(width: panelWidth, height: panelHeight)
        let panelOrigin = CGPoint(x: max((bounds.width - panelSize.width) / 2, 0),
                                  y: max((bounds.height - panelSize.height) / 2, 0))
        panelLayer.frame = CGRect(origin: panelOrigin, size: panelSize)

        titleLayer.frame = CGRect(x: alertPanelHorizontalPadding,
                                  y: alertPanelVerticalPadding,
                                  width: contentWidth,
                                  height: titleSize.height)

        messageLayer.frame = CGRect(x: alertPanelHorizontalPadding,
                                    y: alertPanelVerticalPadding + titleSize.height + titleMessageSpacing,
                                    width: contentWidth,
                                    height: messageSize.height)

        func applyLayout(_ button: QuitAlertButton, frame: CGRect, textSize: CGSize) {
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

        applyLayout(cancelButton, frame: cancelFrame, textSize: cancelMetrics.size)
        applyLayout(forceQuitButton, frame: forceQuitFrame, textSize: forceQuitMetrics.size)
        applyLayout(quitButton, frame: quitFrame, textSize: quitMetrics.size)

        CATransaction.commit()
    }

    func updateAppearance() {
        overlayLayer.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.25).cgColor
        panelLayer.backgroundColor = NSColor.white.cgColor
        panelLayer.borderColor = NSColor(calibratedWhite: 0.0, alpha: 0.2).cgColor
        panelLayer.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.5).cgColor
        let label = NSColor.labelColor.cgColor
        titleLayer.foregroundColor = label
        messageLayer.foregroundColor = label

        let accent = NSColor.controlAccentColor
        let pressedAccent = accent.shadow(withLevel: 0.15) ?? accent
        let secondaryBackground = NSColor.controlBackgroundColor
        let pressedSecondary = secondaryBackground.shadow(withLevel: 0.15) ?? secondaryBackground
        let secondaryBorder = NSColor(calibratedWhite: 0.0, alpha: 0.15)

        func styleSecondaryButton(_ button: QuitAlertButton, isPressed: Bool) {
            let fill = isPressed ? pressedSecondary : secondaryBackground
            button.backgroundLayer.backgroundColor = fill.cgColor
            button.backgroundLayer.borderColor = secondaryBorder.cgColor
            button.backgroundLayer.borderWidth = 1
            button.textLayer.foregroundColor = NSColor.labelColor.cgColor
        }

        func stylePrimaryButton(_ button: QuitAlertButton, isPressed: Bool) {
            let fill = isPressed ? pressedAccent : accent
            button.backgroundLayer.backgroundColor = fill.cgColor
            button.backgroundLayer.borderColor = fill.cgColor
            button.backgroundLayer.borderWidth = 0
            button.textLayer.foregroundColor = NSColor.white.cgColor
        }

        styleSecondaryButton(cancelButton, isPressed: pressedButton?.container === cancelButton.container)
        styleSecondaryButton(forceQuitButton, isPressed: pressedButton?.container === forceQuitButton.container)
        stylePrimaryButton(quitButton, isPressed: pressedButton?.container === quitButton.container)
    }

    func handleMouseDown(at point: CGPoint) -> Bool {
        guard let host = hostLayer,
              overlayLayer.superlayer === host,
              !overlayLayer.isHidden else { return false }

        let pointInOverlay = overlayLayer.convert(point, from: host)
        if !overlayLayer.bounds.contains(pointInOverlay) {
            return false
        }

        pressedButton = nil
        activeButton = nil
        let buttonsToCheck: [QuitAlertButton] = [cancelButton, forceQuitButton, quitButton]
        for button in buttonsToCheck {
            let localPoint = button.container.convert(point, from: host)
            if button.container.bounds.contains(localPoint) {
                pressedButton = button
                activeButton = button
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                updateAppearance()
                CATransaction.commit()
                return true
            }
        }

        // Capture events for the entire overlay
        return true
    }

    func handleMouseUp(at point: CGPoint) -> Bool {
        guard let host = hostLayer,
              overlayLayer.superlayer === host,
              !overlayLayer.isHidden else { return false }

        let target = activeButton
        activeButton = nil
        pressedButton = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateAppearance()
        CATransaction.commit()

        guard let target else {
            let pointInOverlay = overlayLayer.convert(point, from: host)
            return overlayLayer.bounds.contains(pointInOverlay)
        }

        let pointInButton = target.container.convert(point, from: host)
        if target.container.bounds.contains(pointInButton) {
            dismiss()
            onAction(target.action)
        }
        return true
    }

    func handleMouseDragged(at point: CGPoint) -> Bool {
        guard let host = hostLayer,
              overlayLayer.superlayer === host,
              !overlayLayer.isHidden else { return false }

        if let activeButton {
            let localPoint = activeButton.container.convert(point, from: host)
            if activeButton.container.bounds.contains(localPoint) {
                if pressedButton?.container !== activeButton.container {
                    pressedButton = activeButton
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    updateAppearance()
                    CATransaction.commit()
                }
            } else if pressedButton != nil {
                pressedButton = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                updateAppearance()
                CATransaction.commit()
            }
            return true
        } else {
            // Still modal while showing
            return overlayLayer.bounds.contains(overlayLayer.convert(point, from: host))
        }
    }
}
