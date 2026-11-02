import UIKit
import Combine

/// Termius-style key row shown above the software keyboard (and only while the keyboard is up).
/// Glass buttons on iOS 26, tinted capsules before that.
final class KeyBarView: UIInputView {
    private weak var session: TerminalSession?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
    private var repeatTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    @MainActor
    init(session: TerminalSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        session.$ctrlActive.receive(on: DispatchQueue.main).sink { [weak self] on in self?.ctrlButton?.isSelected = on }.store(in: &cancellables)
        session.$altActive.receive(on: DispatchQueue.main).sink { [weak self] on in self?.altButton?.isSelected = on }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
    }

    deinit { repeatTimer?.invalidate() }

    // MARK: Layout

    private func build() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

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
            add(title: sym, width: 38) { [weak self] in self?.session?.sendTyped(sym) }
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
        if let width { button.widthAnchor.constraint(equalToConstant: width).isActive = true }

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
        stack.addArrangedSubview(button)
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
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
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
