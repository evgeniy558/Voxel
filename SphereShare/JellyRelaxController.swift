//
// JellyRelaxController.swift
// Контроллер расслабления желе при остановке пальца.
//

import SwiftUI

final class JellyRelaxController: ObservableObject {
    private var workItem: DispatchWorkItem?

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    func scheduleRelax(delay: Double, perform: @escaping () -> Void) {
        workItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.workItem = nil
            DispatchQueue.main.async { perform() }
        }
        workItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
