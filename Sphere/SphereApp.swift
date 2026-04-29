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
    @State private var showMainApp: Bool = false

    init() {
        setupAudioSession()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        if let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupId) {
            let inbox = c.appendingPathComponent("ShareInbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        if !UserDefaults.standard.bool(forKey: "sphereAccentMigrated_d9fcff") {
            let d = UserDefaults.standard
            if !d.bool(forKey: "sphereUseCustomAccent") {
                d.set(217.0 / 255.0, forKey: "sphereAccentR")
                d.set(252.0 / 255.0, forKey: "sphereAccentG")
                d.set(1.0, forKey: "sphereAccentB")
            }
            d.set(true, forKey: "sphereAccentMigrated_d9fcff")
        }
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMainApp {
                    ContentView()
                } else {
                    SplashScreenView {
                        showMainApp = true
                    }
                }
            }
            .task { SphereBackendAuth.shared.start() }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                setupAudioSession()
            }
        }
    }
}

