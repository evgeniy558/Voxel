//
//  SphereApp.swift
//  Sphere
//
//  Created by Evgeniy on 01.03.2026.
//

import SwiftUI
import AVFoundation
import UIKit

@main
struct SphereApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupAudioSession()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                setupAudioSession()
            }
        }
    }
}
