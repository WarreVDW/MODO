import SwiftUI
import AppKit
import Combine
import QuartzCore

@MainActor
final class FramoNotchTimerController {
    static let shared = FramoNotchTimerController()

    private weak var store: FramoStudioStore?
    private var leftPanel: NSPanel?
    private var rightPanel: NSPanel?
    private var expandedPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tick: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func install(store: FramoStudioStore) {
        if self.store !== store {
            self.store = store
            cancellables.removeAll()

            store.$activeTimerProjectID
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
            store.$activeTimerStartedAt
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
            store.$profileGatePresented
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }

        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                Task { @MainActor in self?.mouseMoved() }
            }
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                Task { @MainActor in self?.mouseMoved() }
                return event
            }
        }

        if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStatusItem() }
            }
        }

        refresh()
    }

    func refreshPreferences() {
        refresh()
    }

    func showExpanded() {
        guard let store,
              !store.profileGatePresented,
              store.settings.effectiveNotchTimerEnabled else { return }

        hideWorkItem?.cancel()
        ensureExpandedPanel(store: store)
        positionExpandedPanel()

        if let expandedPanel {
            present(expandedPanel, duration: 0.18)
        }
    }

    func hideExpanded(after delay: TimeInterval = 0.24) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.expandedPanel else { return }
            self.dismiss(panel, duration: 0.14)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refresh() {
        guard let store else { return }

        if store.profileGatePresented || !store.settings.effectiveNotchTimerEnabled {
            hideEverything()
            return
        }

        let screen = targetScreen()

        if hasNotch(screen) {
            removeStatusItem()

            if store.activeTimerProjectID != nil {
                ensureCompactPanels(store: store)
                positionCompactPanels(on: screen)
                if let leftPanel { present(leftPanel, duration: 0.16) }
                if let rightPanel { present(rightPanel, duration: 0.16) }
            } else {
                if let leftPanel { dismiss(leftPanel, duration: 0.12) }
                if let rightPanel { dismiss(rightPanel, duration: 0.12) }
            }
        } else {
            if let leftPanel { dismiss(leftPanel, duration: 0.10) }
            if let rightPanel { dismiss(rightPanel, duration: 0.10) }
            ensureStatusItem(store: store)
            refreshStatusItem()
        }
    }

    private func mouseMoved() {
        guard let store,
              !store.profileGatePresented,
              store.settings.effectiveNotchTimerEnabled else { return }

        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? targetScreen()
        guard hasNotch(screen) else { return }

        let hoverRect = virtualNotchHoverRect(on: screen).insetBy(dx: -22, dy: -10)
        let expandedContains = expandedPanel?.frame.insetBy(dx: -10, dy: -10).contains(point) == true

        if hoverRect.contains(point) || expandedContains {
            showExpanded()
        } else if expandedPanel?.isVisible == true {
            hideExpanded()
        }
    }

    private func ensureCompactPanels(store: FramoStudioStore) {
        if leftPanel == nil {
            let panel = makePanel(width: 92, height: 28, acceptsMouse: false)
            panel.contentView = NSHostingView(
                rootView: ModoNotchElapsedView()
                    .environmentObject(store)
            )
            leftPanel = panel
        }

        if rightPanel == nil {
            let panel = makePanel(width: 34, height: 28, acceptsMouse: false)
            panel.contentView = NSHostingView(
                rootView: ModoNotchRecordView()
                    .environmentObject(store)
            )
            rightPanel = panel
        }
    }

    private func ensureExpandedPanel(store: FramoStudioStore) {
        guard expandedPanel == nil else { return }

        let panel = makePanel(width: 336, height: 146, acceptsMouse: true)
        panel.contentView = NSHostingView(
            rootView: ModoNotchExpandedView(onDismiss: { [weak self] in
                guard let self, let panel = self.expandedPanel else { return }
                self.dismiss(panel, duration: 0.12)
            })
            .environmentObject(store)
        )
        expandedPanel = panel
    }

    private func makePanel(width: CGFloat, height: CGFloat, acceptsMouse: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !acceptsMouse
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        return panel
    }

    private func positionCompactPanels(on screen: NSScreen) {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return }

        if let leftPanel {
            let size = leftPanel.frame.size
            let x = max(leftArea.minX + 6, leftArea.maxX - size.width - 5)
            let y = leftArea.midY - size.height / 2
            leftPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        if let rightPanel {
            let size = rightPanel.frame.size
            let x = min(rightArea.maxX - size.width - 6, rightArea.minX + 5)
            let y = rightArea.midY - size.height / 2
            rightPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func positionExpandedPanel() {
        guard let panel = expandedPanel else { return }
        let screen = targetScreen()
        let x = screen.frame.midX - panel.frame.width / 2
        let y = screen.visibleFrame.maxY - panel.frame.height + 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func virtualNotchHoverRect(on screen: NSScreen) -> NSRect {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NSRect(
                x: left.maxX,
                y: min(left.minY, right.minY),
                width: max(1, right.minX - left.maxX),
                height: max(left.height, right.height)
            )
        }
        return NSRect(x: screen.frame.midX - 76, y: screen.frame.maxY - 28, width: 152, height: 28)
    }

    private func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 &&
        screen.auxiliaryTopLeftArea != nil &&
        screen.auxiliaryTopRightArea != nil
    }

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        ?? NSScreen.main
        ?? NSScreen.screens[0]
    }

    private func ensureStatusItem(store: FramoStudioStore) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        showExpanded()
    }

    private func refreshStatusItem() {
        guard let store, let button = statusItem?.button else { return }

        if store.activeTimerProjectID != nil {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "MODO timer")
            button.imagePosition = .imageLeading
            button.title = compactDuration(store.focusElapsedSeconds())
        } else {
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "MODO Time")
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func present(_ panel: NSPanel, duration: TimeInterval) {
        guard !panel.isVisible || panel.alphaValue < 0.99 else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss(_ panel: NSPanel, duration: TimeInterval) {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 0
        })
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func hideEverything() {
        if let leftPanel { dismiss(leftPanel, duration: 0.08) }
        if let rightPanel { dismiss(rightPanel, duration: 0.08) }
        if let expandedPanel { dismiss(expandedPanel, duration: 0.08) }
        removeStatusItem()
    }
}

private struct ModoNotchElapsedView: View {
    @EnvironmentObject private var store: FramoStudioStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(duration(store.focusElapsedSeconds(now: context.date)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.94))
                .clipShape(Capsule())
        }
        .padding(1)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ModoNotchRecordView: View {
    @EnvironmentObject private var store: FramoStudioStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8)
            let pulse = phase < 0.52

            Circle()
                .fill(store.activeTimerStartedAt == nil ? Color.white.opacity(0.46) : Color.red)
                .frame(width: 7, height: 7)
                .scaleEffect(store.activeTimerStartedAt == nil ? 1 : (pulse ? 1.24 : 1))
                .opacity(store.activeTimerStartedAt == nil ? 0.55 : (pulse ? 1 : 0.48))
                .animation(.easeInOut(duration: 0.24), value: pulse)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.94))
                .clipShape(Capsule())
        }
        .padding(1)
    }
}

private struct ModoNotchExpandedView: View {
    @EnvironmentObject private var store: FramoStudioStore
    let onDismiss: () -> Void

    @State private var selectedProjectID: UUID?
    @State private var appeared = false

    private var activeProject: StudioProject? {
        guard let id = store.activeTimerProjectID else { return nil }
        return store.projects.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                StudioLogoMark(size: 18)

                if let activeProject {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activeProject.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(duration(store.focusElapsedSeconds(now: context.date)))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                } else {
                    Text("MODO Time")
                        .font(.system(size: 11, weight: .semibold))
                }

                Spacer()

                if store.activeTimerProjectID != nil {
                    Button {
                        if store.activeTimerStartedAt == nil, let id = store.activeTimerProjectID {
                            store.startTimer(for: id)
                        } else {
                            store.pauseTimer()
                        }
                    } label: {
                        Image(systemName: store.activeTimerStartedAt == nil ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(IconButtonStyle())

                    Button {
                        store.stopTimer()
                        onDismiss()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                }
            }

            HStack(spacing: 8) {
                Picker(
                    "",
                    selection: Binding(
                        get: { selectedProjectID ?? store.activeTimerProjectID },
                        set: { selectedProjectID = $0 }
                    )
                ) {
                    Text("Choose project").tag(Optional<UUID>.none)
                    ForEach(store.projects) { project in
                        Text(project.title).tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if store.activeTimerProjectID == nil {
                    Button("Start") {
                        if let id = selectedProjectID {
                            store.startTimer(for: id)
                            onDismiss()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selectedProjectID == nil)
                } else {
                    Button("Open") {
                        store.showTimeLauncher = true
                        NSApp.activate(ignoringOtherApps: true)
                        onDismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(12)
        .frame(width: 336, height: 146)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.26), radius: 24, y: 10)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -6)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: appeared)
        .onAppear {
            selectedProjectID = store.activeTimerProjectID ?? store.projects.first?.id
            withAnimation { appeared = true }
        }
        .onChange(of: selectedProjectID) { _, id in
            guard let id,
                  store.activeTimerProjectID != nil,
                  id != store.activeTimerProjectID else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                store.startTimer(for: id)
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
