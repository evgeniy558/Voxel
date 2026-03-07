import UIKit

private final class ItemContainerView: UIView {
    weak var iconView: UIView?
    weak var titleLabel: UILabel?
    var iconScale: CGFloat = 1
    var iconBaseSize: CGFloat = 28

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let base = iconBaseSize
        let iw = base * iconScale
        let ih = base * iconScale
        let iconCenterY: CGFloat = 4 + base / 2
        iconView?.frame = CGRect(x: (w - iw) / 2, y: iconCenterY - ih / 2, width: iw, height: ih)
        if let label = titleLabel {
            label.bounds = CGRect(x: 0, y: 0, width: w, height: 18)
            label.center = CGPoint(x: w / 2, y: 4 + base + 4 + 9)
            label.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            label.transform = CGAffineTransform(scaleX: iconScale, y: iconScale)
        }
    }
}

/// Порт таббара из Telegram-iOS для iOS 18 и ниже: та же структура (LiquidLens), серые иконки снаружи, капля с блюром, внутри капли — акцентные иконки.
public final class TelegramTabBarView: UIView {

    public struct Item: Equatable {
        let id: Int
        let title: String
        let imageName: String

        public init(id: Int, title: String, imageName: String) {
            self.id = id
            self.title = title
            self.imageName = imageName
        }
    }

    private let innerInset: CGFloat = 4
    private let dropletInset: CGFloat = 2
    private let showTabNames: Bool = true
    private let wideTabBar: Bool = false

    private var items: [Item] = []
    private var selectedId: Int = 0
    private var accentColor: UIColor = .systemPurple
    private var isDark: Bool = false

    public var onSelect: ((Int) -> Void)?

    private let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let contentView = UIView()
    private let selectedContentView = UIView()
    private let selectedContentMaskView = UIView()
    private let blurLensView: UIVisualEffectView
    private var itemViews: [Int: UIView] = [:]
    private var selectedItemViews: [Int: UIView] = [:]
    private let tabSelectionRecognizer: TabSelectionRecognizer

    private var selectionGestureState: (startX: CGFloat, currentX: CGFloat, itemId: Int)?
    private var overrideSelectedId: Int?
    private var lastLensX: CGFloat = -1
    private var lastEffectiveSelectedId: Int?
    private var wasPressedOrDragging: Bool = false

    public override init(frame: CGRect) {
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        blurLensView = UIVisualEffectView(effect: blurEffect)
        tabSelectionRecognizer = TabSelectionRecognizer(target: nil, action: nil)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        blurLensView = UIVisualEffectView(effect: blurEffect)
        tabSelectionRecognizer = TabSelectionRecognizer(target: nil, action: nil)
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.clipsToBounds = true
        addSubview(backgroundView)

        contentView.isUserInteractionEnabled = false
        addSubview(contentView)

        blurLensView.clipsToBounds = true
        addSubview(blurLensView)

        selectedContentView.isUserInteractionEnabled = false
        addSubview(selectedContentView)
        selectedContentMaskView.backgroundColor = .black
        selectedContentView.mask = selectedContentMaskView

        tabSelectionRecognizer.addTarget(self, action: #selector(onTabSelectionGesture(_:)))
        addGestureRecognizer(tabSelectionRecognizer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        addGestureRecognizer(tap)
    }

    public func configure(items: [Item], selectedId: Int, accentColor: UIColor, isDark: Bool) {
        self.items = items
        self.selectedId = selectedId
        self.overrideSelectedId = nil
        self.accentColor = accentColor
        self.isDark = isDark
        setNeedsLayout()
        layoutIfNeeded()
    }

    public func setSelectedId(_ id: Int) {
        guard selectedId != id else { return }
        selectedId = id
        overrideSelectedId = nil
        setNeedsLayout()
        layoutIfNeeded()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height

        let widthReducer: CGFloat = items.count == 2 ? 1.5 : (items.count == 1 ? 1.75 : (items.count == 3 ? 1.25 : 1.0))
        var availableWidth = min(500, w) / widthReducer
        if !wideTabBar {
            availableWidth -= 48 + innerInset * 2
        }
        let barHeight: CGFloat = (showTabNames ? 56 : 40) + innerInset * 2
        let itemHeight: CGFloat = showTabNames ? 56 : 40
        let availableItemsWidth = availableWidth - innerInset * 2
        let itemWidth = floor(availableItemsWidth / CGFloat(max(1, items.count)))
        let contentWidth = innerInset * 2 + CGFloat(items.count) * itemWidth
        let tabsWidth = min(availableWidth, contentWidth)
        let tabsHeight = barHeight
        let barOriginX = (w - tabsWidth) / 2

        backgroundView.frame = CGRect(x: barOriginX, y: 0, width: tabsWidth, height: tabsHeight)
        backgroundView.layer.cornerRadius = tabsHeight / 2

        contentView.frame = CGRect(x: barOriginX, y: 0, width: tabsWidth, height: tabsHeight)
        selectedContentView.frame = CGRect(x: barOriginX, y: 0, width: tabsWidth, height: tabsHeight)

        let effectiveSelectedId: Int
        let lensX: CGFloat
        let lensW = itemWidth + innerInset * 2

        if let state = selectionGestureState {
            effectiveSelectedId = state.itemId
            lensX = max(0, min(tabsWidth - lensW, state.currentX))
        } else {
            effectiveSelectedId = overrideSelectedId ?? selectedId
            let idx = items.firstIndex(where: { $0.id == effectiveSelectedId }) ?? 0
            lensX = CGFloat(idx) * itemWidth
        }

        let lensH = tabsHeight - dropletInset * 2
        let lensWInset = max(0, lensW - dropletInset * 2)
        let lensXInset = lensX + dropletInset
        let lensYInset = dropletInset
        let lensFrame = CGRect(x: lensXInset, y: lensYInset, width: lensWInset, height: lensH)
        let isDragging = selectionGestureState != nil
        let maskFrame = CGRect(x: round(lensXInset), y: round(lensYInset), width: round(lensWInset), height: round(lensH))

        let r = min(maskFrame.width, maskFrame.height) / 2
        blurLensView.transform = .identity
        selectedContentMaskView.transform = .identity

        if isDragging {
            blurLensView.frame = CGRect(x: barOriginX + lensFrame.minX, y: lensFrame.minY, width: lensFrame.width, height: lensFrame.height)
            blurLensView.layer.cornerRadius = r
            blurLensView.layer.cornerCurve = .continuous
            selectedContentMaskView.frame = maskFrame
            selectedContentMaskView.layer.cornerRadius = r
            selectedContentMaskView.layer.cornerCurve = .continuous
            lastLensX = lensX
            lastEffectiveSelectedId = effectiveSelectedId
        } else {
            let targetBlurFrame = CGRect(x: barOriginX + lensFrame.minX, y: lensFrame.minY, width: lensFrame.width, height: lensFrame.height)
            let tabChanged = lastEffectiveSelectedId != nil && lastEffectiveSelectedId != effectiveSelectedId
            let lensChanged = lastLensX >= 0 && (tabChanged || abs(lastLensX - lensX) > 0.5)
            if lensChanged {
                UIView.animate(withDuration: 0.52, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.28) {
                    self.blurLensView.frame = targetBlurFrame
                    self.selectedContentMaskView.frame = maskFrame
                }
            } else {
                blurLensView.frame = targetBlurFrame
                selectedContentMaskView.frame = maskFrame
            }
            blurLensView.layer.cornerRadius = r
            blurLensView.layer.cornerCurve = .continuous
            selectedContentMaskView.layer.cornerRadius = r
            selectedContentMaskView.layer.cornerCurve = .continuous
            lastLensX = lensX
            lastEffectiveSelectedId = effectiveSelectedId
        }

        for (index, item) in items.enumerated() {
            let itemFrame = CGRect(
                x: innerInset + CGFloat(index) * itemWidth,
                y: floor((tabsHeight - itemHeight) / 2),
                width: itemWidth,
                height: itemHeight
            )

            let grayView: UIView
            if let existing = itemViews[item.id] {
                grayView = existing
            } else {
                grayView = makeItemView(title: item.title, imageName: item.imageName, isAccent: false, iconScale: 1)
                contentView.addSubview(grayView)
                itemViews[item.id] = grayView
            }
            grayView.frame = itemFrame
            if let c = grayView as? ItemContainerView {
                (c.iconView as? UIImageView)?.tintColor = UIColor.label.withAlphaComponent(0.65)
                c.titleLabel?.textColor = UIColor.label.withAlphaComponent(0.65)
            }

            let accentView: UIView
            if let existing = selectedItemViews[item.id] {
                accentView = existing
            } else {
                accentView = makeItemView(title: item.title, imageName: item.imageName, isAccent: true, iconScale: 1)
                selectedContentView.addSubview(accentView)
                selectedItemViews[item.id] = accentView
            }
            accentView.frame = itemFrame
            accentView.transform = .identity
            if let c = accentView as? ItemContainerView {
                (c.iconView as? UIImageView)?.tintColor = accentColor
                c.titleLabel?.textColor = accentColor
                let targetScale: CGFloat = isDragging ? 1.15 : 1
                let scaleChanged = abs(c.iconScale - targetScale) > 0.01
                if scaleChanged {
                    let duration: TimeInterval = targetScale > 1 ? 0.26 : 0.2
                    let damping: CGFloat = targetScale > 1 ? 0.72 : 0.82
                    UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: damping, initialSpringVelocity: 0.35) {
                        c.iconScale = targetScale
                        c.setNeedsLayout()
                        c.layoutIfNeeded()
                    }
                } else if isDragging {
                    c.iconScale = 1.15
                    c.setNeedsLayout()
                    c.layoutIfNeeded()
                }
            }
        }
        wasPressedOrDragging = isDragging
    }

    private func makeItemView(title: String, imageName: String, isAccent: Bool, iconScale: CGFloat = 1) -> UIView {
        let container = ItemContainerView()
        container.iconScale = iconScale
        container.iconBaseSize = 28
        let pointSize: CGFloat = 24 * iconScale
        let imageView: UIImageView
        if let customImage = UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate) {
            imageView = UIImageView(image: customImage)
        } else {
            let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            imageView = UIImageView(image: UIImage(systemName: imageName, withConfiguration: config))
        }
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = isAccent ? accentColor : UIColor.label.withAlphaComponent(0.65)
        container.addSubview(imageView)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = isAccent ? accentColor : UIColor.label.withAlphaComponent(0.65)
        label.textAlignment = .center
        container.addSubview(label)

        container.iconView = imageView
        container.titleLabel = label
        return container
    }

    private func lensXForItem(id: Int) -> CGFloat {
        let w = bounds.width
        let widthReducer: CGFloat = items.count == 2 ? 1.5 : (items.count == 1 ? 1.75 : (items.count == 3 ? 1.25 : 1.0))
        var availableWidth = min(500, w) / widthReducer
        if !wideTabBar { availableWidth -= 48 + innerInset * 2 }
        let availableItemsWidth = availableWidth - innerInset * 2
        let itemWidth = floor(availableItemsWidth / CGFloat(max(1, items.count)))
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return 0 }
        return CGFloat(idx) * itemWidth
    }

    private func item(at point: CGPoint) -> Int? {
        let pContent = contentView.convert(point, from: self)
        var closest: (id: Int, dist: CGFloat)?
        for (id, view) in itemViews {
            let f = view.frame
            if f.contains(pContent) {
                return id
            }
            let dist = abs(pContent.x - f.midX)
            if closest == nil || dist < closest!.dist {
                closest = (id, dist)
            }
        }
        return closest?.id
    }

    /// Вкладка под центром капли по lensX — чтобы масштаб иконки совпадал с каплей при драге.
    private func itemIdForLensX(_ lensX: CGFloat) -> Int? {
        let w = bounds.width
        let widthReducer: CGFloat = items.count == 2 ? 1.5 : (items.count == 1 ? 1.75 : (items.count == 3 ? 1.25 : 1.0))
        var availableWidth = min(500, w) / widthReducer
        if !wideTabBar { availableWidth -= 48 + innerInset * 2 }
        let availableItemsWidth = availableWidth - innerInset * 2
        let itemWidth = floor(availableItemsWidth / CGFloat(max(1, items.count)))
        let lensW = itemWidth + innerInset * 2
        let centerX = lensX + lensW / 2
        let idx = max(0, min(items.count - 1, Int(centerX / itemWidth)))
        return items[idx].id
    }

    @objc private func onTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let p = recognizer.location(in: self)
        guard let id = item(at: p), id != selectedId else { return }
        onSelect?(id)
    }

    @objc private func onTabSelectionGesture(_ recognizer: TabSelectionRecognizer) {
        switch recognizer.state {
        case .began:
            let loc = recognizer.location(in: self)
            if let id = item(at: loc) {
                let startX = lensXForItem(id: id)
                selectionGestureState = (startX, startX, id)
                setNeedsLayout()
                layoutIfNeeded()
            }
        case .changed:
            if var state = selectionGestureState {
                let trans = recognizer.translation(in: self)
                state.currentX = state.startX + trans.x
                let idByTouch = item(at: recognizer.location(in: self))
                let idByLens = itemIdForLensX(state.currentX)
                state.itemId = idByTouch ?? idByLens ?? state.itemId
                selectionGestureState = state
                setNeedsLayout()
                layoutIfNeeded()
            }
        case .ended, .cancelled:
            if let state = selectionGestureState {
                selectionGestureState = nil
                if recognizer.state == .ended {
                    overrideSelectedId = state.itemId
                    onSelect?(state.itemId)
                }
                setNeedsLayout()
                layoutIfNeeded()
            }
        default:
            break
        }
    }
}
