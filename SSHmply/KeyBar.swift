import UIKit
import Combine

/// Scroll view that lets a drag that starts on a button scroll the bar (buttons are UIControls,
/// which by default swallow the gesture).
private final class KeyScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// Termius-style key row shown above the software keyboard (and only while the keyboard is up).
/// Glass buttons on iOS 26, tinted capsules before that. Horizontally scrollable.
final class KeyBarView: UIInputView {
    private static let barHeight: CGFloat = 48
    private static let buttonHeight: CGFloat = 36
    private static let spacing: CGFloat = 6
    private static let edge: CGFloat = 8

    private weak var session: TerminalSession?
    private let scroll = KeyScrollView()
    private var buttons: [UIButton] = []
    private var fixedWidths: [ObjectIdentifier: CGFloat] = [:]
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
    private var repeatTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    @MainActor
    init(session: TerminalSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.barHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        scroll.canCancelContentTouches = true
        scroll.clipsToBounds = true
        addSubview(scroll)

        build()
        session.$ctrlActive.receive(on: DispatchQueue.main).sink { [weak self] on in self?.ctrlButton?.isSelected = on }.store(in: &cancellables)
        session.$altActive.receive(on: DispatchQueue.main).sink { [weak self] on in self?.altButton?.isSelected = on }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    deinit { repeatTimer?.invalidate() }

    // MARK: Layout (manual frames: deterministic inside the keyboard's input view)

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let y = (bounds.height - Self.buttonHeight) / 2
        var x = Self.edge
        for button in buttons {
            let natural = button.intrinsicContentSize.width
            let width = fixedWidths[ObjectIdentifier(button)] ?? max(40, natural)
            button.frame = CGRect(x: x, y: y, width: width, height: Self.buttonHeight)
            x += width + Self.spacing
        }
        scroll.contentSize = CGSize(width: x - Self.spacing + Self.edge, height: bounds.height)
    }

    // MARK: Buttons

    private func build() {
        // Hide keyboard · Esc · Tab · Ctrl · Alt · arrows · symbols · navigation · snippets · paste
        add(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.session?.hideKeyboard() }
        add(title: "esc") { [weak self] in self?.session?.sendKey(.escape) }
        add(title: "tab") { [weak self] in self?.session?.sendKey(.tab) }
        ctrlButton = add(title: "ctrl", toggle: true) { [weak self] in self?.session?.toggleCtrl() }
        altButton = add(title: "alt", toggle: true) { [weak self] in self?.session?.toggleAlt() }
        add(symbol: "arrow.left", repeating: true) { [weak self] in self?.session?.sendKey(.left) }
        add(symbol: "arrow.down", repeating: true) { [weak self] in self?.session?.sendKey(.down) }
        add(symbol: "arrow.up", repeating: true) { [weak self] in self?.session?.sendKey(.up) }
        add(symbol: "arrow.right", repeating: true) { [weak self] in self?.session?.sendKey(.right) }
        for sym in ["|", "/", "~", "-", "_", ".", ":", "$", "&", "*", "\\", "'", "\""] {
            add(title: sym, width: 40) { [weak self] in self?.session?.sendTyped(sym) }
        }
        add(title: "home") { [weak self] in self?.session?.sendKey(.home) }
        add(title: "end") { [weak self] in self?.session?.sendKey(.end) }
        add(title: "pg↑", repeating: true) { [weak self] in self?.session?.sendKey(.pageUp) }
        add(title: "pg↓", repeating: true) { [weak self] in self?.session?.sendKey(.pageDown) }
        add(symbol: "chevron.left.forwardslash.chevron.right") { [weak self] in self?.session?.onShowSnippets?() }
        add(symbol: "doc.on.clipboard") { [weak self] in self?.session?.pasteFromClipboard() }
    }

    @discardableResult
    private func add(title: String? = nil, symbol: String? = nil, width: CGFloat? = nil, toggle: Bool = false,
                     repeating: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = makeButton(title: title, symbol: symbol, toggle: toggle)
        if let width { fixedWidths[ObjectIdentifier(button)] = width }

        if repeating {
            button.addAction(UIAction { [weak self] _ in self?.startRepeat(action) }, for: .touchDown)
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
            }
        } else {
            button.addAction(UIAction { [weak self] _ in
                self?.haptic.impactOccurred()
                action()
            }, for: .touchUpInside)
        }
        buttons.append(button)
        scroll.addSubview(button)
        return button
    }

    private func makeButton(title: String?, symbol: String?, toggle: Bool) -> UIButton {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .gray()
        }
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        if let title {
            var text = AttributedString(title)
            text.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
            config.attributedTitle = text
        }
        if let symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        }
        let button = UIButton(configuration: config)
        if toggle {
            button.configurationUpdateHandler = { btn in
                var c = btn.configuration
                c?.baseForegroundColor = btn.isSelected ? .systemBlue : .label
                if #unavailable(iOS 26.0) {
                    c?.baseBackgroundColor = btn.isSelected ? UIColor.systemBlue.withAlphaComponent(0.25) : nil
                }
                btn.configuration = c
            }
        }
        return button
    }

    // MARK: Key repeat (arrows, page up/down)

    private func startRepeat(_ fire: @escaping () -> Void) {
        haptic.impactOccurred()
        fire()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in fire() }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
