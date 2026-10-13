import SwiftUI
import AppKit
import CloudKit

@main
struct ModoApp: App {
    @NSApplicationDelegateAdaptor(ModoAppDelegate.self) private var appDelegate
    @StateObject private var store = FramoStudioStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .onAppear { applyNativeAppearance(store.settings.appearance) }
                .onChange(of: store.settings.appearance) { _, appearance in
                    applyNativeAppearance(appearance)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Search MODO") { store.showGlobalSearch = true }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Divider()
                Button("New project") { store.requestProjectCreation() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.profileGatePresented)
                Button("New quote") {
                    _ = store.createQuote(customerID: store.business.organizations.first?.id)
                    store.openDestination(.sales)
                }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                    .disabled(store.profileGatePresented)
                Button("New task") { store.quickAddTask() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(store.profileGatePresented)
            }

            CommandMenu("Time") {
                Button("Open Time Manager") { store.showTimeLauncher = true }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(store.profileGatePresented)
                if store.activeTimerProjectID != nil {
                    Divider()
                    Button(store.activeTimerStartedAt == nil ? "Resume Timer" : "Pause Timer") {
                        if let id = store.activeTimerProjectID {
                            if store.activeTimerStartedAt == nil { store.startTimer(for: id) }
                            else { store.pauseTimer() }
                        }
                    }
                    .disabled(store.profileGatePresented)
                    Button("Stop Timer") { store.stopTimer() }
                        .disabled(store.profileGatePresented)
                }
            }

            CommandMenu("Navigate") {
                Button("Today") { store.openDestination(.home) }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Button("Customers") { store.openDestination(.customers) }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Button("Sales") { store.openDestination(.sales) }
                    .keyboardShortcut("3", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Button("Work") { store.openDestination(.projects) }
                    .keyboardShortcut("4", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Button("Tasks") { store.openDestination(.tasks) }
                    .keyboardShortcut("5", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Button("Calendar") { store.openDestination(.calendar) }
                    .keyboardShortcut("6", modifiers: [.command])
                    .disabled(store.profileGatePresented)
                Button("Money") { store.openDestination(.finance) }
                    .keyboardShortcut("7", modifiers: [.command])
                    .disabled(store.profileGatePresented)
            }
        }

        Settings {
            ZStack {
                FramoSettingsView()
                    .environmentObject(store)
                if store.profileGatePresented {
                    FramoProfileGateView()
                        .environmentObject(store)
                        .zIndex(1000)
                }
            }
            .preferredColorScheme(store.settings.appearance.colorScheme)
            .frame(minWidth: 900, idealWidth: 1180, minHeight: 640, idealHeight: 760)
        }
    }

    private func applyNativeAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

}


@MainActor
enum ModoCloudShareBridge {
    static var handler: ((CKShare.Metadata) -> Void)?

    static func deliver(_ metadata: CKShare.Metadata) {
        handler?(metadata)
    }
}

final class ModoAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        ModoCloudShareBridge.deliver(metadata)
    }
}
