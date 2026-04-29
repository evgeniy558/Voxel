//
//  AppAccentColorPicker.swift
//

import SwiftUI
import UIKit

/// Контейнер с child VC: в SwiftUI `.sheet` у одиночного `UIColorPickerViewController` часто нулевой layout — сетка цветов не нажимается.
final class SphereUIColorPickerContainerViewController: UIViewController {
    let picker: UIColorPickerViewController

    init(picker: UIColorPickerViewController) {
        self.picker = picker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(picker)
        view.addSubview(picker.view)
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.view.topAnchor.constraint(equalTo: view.topAnchor),
            picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        picker.didMove(toParent: self)
    }
}

struct AppAccentUIColorPickerSheet: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedUIColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, selectedUIColor: $selectedUIColor)
    }

    func makeUIViewController(context: Context) -> SphereUIColorPickerContainerViewController {
        let picker = UIColorPickerViewController()
        picker.delegate = context.coordinator
        picker.selectedColor = selectedUIColor
        picker.supportsAlpha = false
        return SphereUIColorPickerContainerViewController(picker: picker)
    }

    func updateUIViewController(_ uiViewController: SphereUIColorPickerContainerViewController, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.selectedUIColor = $selectedUIColor
        // Не перезаписываем picker.selectedColor здесь — иначе сбрасывается выбор при каждом refresh SwiftUI.
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var isPresented: Binding<Bool>
        var selectedUIColor: Binding<UIColor>

        init(isPresented: Binding<Bool>, selectedUIColor: Binding<UIColor>) {
            self.isPresented = isPresented
            self.selectedUIColor = selectedUIColor
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            let c = viewController.selectedColor
            DispatchQueue.main.async { [weak self] in
                self?.selectedUIColor.wrappedValue = c
            }
        }

        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            let c = viewController.selectedColor
            DispatchQueue.main.async { [weak self] in
                self?.selectedUIColor.wrappedValue = c
            }
        }
    }
}
