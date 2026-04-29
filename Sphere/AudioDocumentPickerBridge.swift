//
//  AudioDocumentPickerBridge.swift
//  UIDocumentPicker с asCopy — обход проблемы SwiftUI fileImporter на iOS 26 (выбор в «Файлах» не срабатывает).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AudioDocumentPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPickedURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if isPresented, context.coordinator.presentedPicker == nil {
            context.coordinator.present(from: uiViewController)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: AudioDocumentPickerPresenter
        weak var presentedPicker: UIDocumentPickerViewController?

        init(parent: AudioDocumentPickerPresenter) {
            self.parent = parent
        }

        func present(from host: UIViewController) {
            let types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .formSheet
            presentedPicker = picker
            host.present(picker, animated: true)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            controller.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.presentedPicker = nil
                self.parent.isPresented = false
                if let url = urls.first {
                    self.parent.onPickedURL(url)
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: true) { [weak self] in
                self?.presentedPicker = nil
                self?.parent.isPresented = false
            }
        }
    }
}

/// На iOS 26+ импорт аудио через `UIDocumentPicker` (см. `AudioDocumentPickerPresenter`); на более ранних — стандартный `fileImporter`.
struct SphereLegacyAudioFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    var onPickedURLs: ([URL]) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    onPickedURLs(urls)
                case .failure:
                    break
                }
            }
        }
    }
}
