import Foundation
import UIKit

/// Скопировано из Telegram-iOS: TabSelectionRecognizer — жесты перетаскивания капли таббара.
public final class TabSelectionRecognizer: UIGestureRecognizer {
    private var initialLocation: CGPoint?
    private var currentLocation: CGPoint?

    public override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    public override func reset() {
        super.reset()
        initialLocation = nil
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let event else { return }
        super.touchesBegan(touches, with: event)
        if initialLocation == nil {
            initialLocation = touches.first?.location(in: view)
        }
        currentLocation = initialLocation
        state = .began
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let event else { return }
        super.touchesEnded(touches, with: event)
        state = .ended
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let event else { return }
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let event else { return }
        super.touchesMoved(touches, with: event)
        currentLocation = touches.first?.location(in: view)
        state = .changed
    }

    public func translation(in view: UIView?) -> CGPoint {
        let targetView = view ?? self.view
        guard let initial = initialLocation, let current = currentLocation, let target = targetView else {
            return .zero
        }
        let initialInTarget = self.view?.convert(initial, to: target) ?? initial
        let currentInTarget = self.view?.convert(current, to: target) ?? current
        return CGPoint(x: currentInTarget.x - initialInTarget.x, y: currentInTarget.y - initialInTarget.y)
    }
}
