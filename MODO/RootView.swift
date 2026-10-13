import SwiftUI
import LocalAuthentication
import AppKit
import UniformTypeIdentifiers
import Combine

enum ModoLaunchStyle: Equatable {
    case full
    case condensed
    case none

    var duration: TimeInterval {
        switch self {
        case .full: 3.57
        case .condensed: 1.15
        case .none: 0
        }
    }

    static func resolveForProcess() -> ModoLaunchStyle {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let previous = defaults.double(forKey: "modo.lastColdLaunchEpoch")
        defaults.set(now, forKey: "modo.lastColdLaunchEpoch")
        if previous > 0, now - previous < 10 * 60 {
            return .condensed
        }
        return .full
    }
}

struct RootView: View {
    private static let processLaunchStyle = ModoLaunchStyle.resolveForProcess()

    @EnvironmentObject private var store: FramoStudioStore
    @AppStorage("studio.sidebar.collapsed") private var sidebarCollapsed = false
    @State private var isBooting = true
    @State private var launchStyle = RootView.processLaunchStyle
    @AppStorage("studio.onboarding.v20.completed") private var onboardingCompleted = false
    @State private var activeSheet: RootSheet?
    @State private var onboardingPresentedThisLaunch = false

    private enum RootSheet: String, Identifiable {
        case projectCreator
        case onboarding
        var id: String { rawValue }
    }

    private var onboardingSheetBinding: Binding<Bool> {
        Binding(
            get: { activeSheet == .onboarding },
            set: { isPresented in
                if !isPresented, activeSheet == .onboarding { activeSheet = nil }
            }
        )
    }

    var body: some View {
        StudioScaleContainer(scale: CGFloat(store.settings.effectiveScale)) {
            // Authenticated content never renders behind startup/login.
            // After unlock, the app shell enters with a soft scale + crossfade.
            ZStack {
                if store.profileGatePresented || isBooting {
                    StudioTheme.canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .transition(.opacity)
                } else {
                    appShell
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 1.012)),
                                removal: .opacity
                            )
                        )
                }
            }
            .animation(.easeInOut(duration: 0.46), value: store.profileGatePresented)
            .animation(.easeInOut(duration: 0.32), value: isBooting)
        }
        .environment(\.locale, Locale(identifier: store.settings.effectiveLanguage.localeIdentifier))
        .background(StudioTheme.sidebar)
        .foregroundStyle(StudioTheme.primary)
        .sheet(item: $activeSheet, onDismiss: sheetDidDismiss) { sheet in
            switch sheet {
            case .projectCreator:
                ProjectCreatorView().environmentObject(store)
            case .onboarding:
                FramoOnboardingViewV20(isPresented: onboardingSheetBinding)
                    .environmentObject(store)
            }
        }
        .alert("Workspace recovery", isPresented: Binding(
            get: { store.workspaceRecoveryNotice != nil },
            set: { if !$0 { store.workspaceRecoveryNotice = nil } }
        )) {
            Button("Reveal recovery files") {
                store.revealRecoveryFolder()
                store.workspaceRecoveryNotice = nil
            }
            Button("Dismiss", role: .cancel) { store.workspaceRecoveryNotice = nil }
        } message: {
            Text(store.workspaceRecoveryNotice ?? "")
        }
        .overlay {
            if isBooting && !store.profileGatePresented {
                BootSplashView(style: launchStyle)
                    .transition(.opacity)
            }
        }
        .overlay {
            if isBooting {
                ModoLaunchInputCatcher { finishBoot() }
                    .allowsHitTesting(false)
                    .zIndex(5000)
            }
        }
        .overlay {
            if store.showGlobalSearch && !isBooting && !store.profileGatePresented {
                GlobalCommandPalette()
                    .environmentObject(store)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(200)
            }
        }
        .overlay {
            if store.showTimeLauncher && !isBooting && !store.profileGatePresented {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { store.showTimeLauncher = false }
                    FramoTimeLauncher()
                        .environmentObject(store)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
                .zIndex(205)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = store.pluginNotice, !notice.isEmpty, !isBooting, !store.profileGatePresented {
                PluginNoticeToast(message: notice)
                    .environmentObject(store)
                    .padding(18)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(210)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isBooting && !store.profileGatePresented && onboardingCompleted {
                FramoFeatureCoachmark(descriptor: currentFeatureIntro)
                    .id(currentFeatureIntro.key)
                    .padding(.trailing, 22).padding(.bottom, 22)
                    .zIndex(180)
            }
        }
        .overlay {
            if store.showNotificationCenter && !isBooting && !store.profileGatePresented {
                GeometryReader { geometry in
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.025).contentShape(Rectangle())
                            .onTapGesture { store.showNotificationCenter = false }
                        FramoNotificationCenter()
                            .environmentObject(store)
                            .frame(width: min(370, max(260, geometry.size.width - 24)),
                                   height: min(560, max(220, geometry.size.height - 62)))
                            .padding(.top, 44).padding(.trailing, 12)
                    }
                }
                .zIndex(220)
            }
        }
        .overlay {
            if store.profileGatePresented {
                FramoProfileGateView(introStyle: isBooting ? launchStyle : .none)
                    .environmentObject(store)
                    .id("profile-gate-\(isBooting ? "boot" : "steady")")
                    .transition(
                        .asymmetric(
                            insertion: .opacity,
                            removal: .opacity.combined(with: .scale(scale: 0.992))
                        )
                    )
                    .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.46), value: store.profileGatePresented)
        .animation(.easeOut(duration: 0.12), value: store.showGlobalSearch)
        .onAppear {
            FramoFocusRuntime.shared.install(store: store)
            FramoAutoLockRuntime.shared.install(store: store)
            FramoNotchTimerController.shared.install(store: store)
        }
        .task {
            while !Task.isCancelled {
                store.refreshNotifications()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: store.settings.effectiveDockTimerBadgeEnabled) { _, _ in FramoFocusRuntime.shared.refreshPreferences() }
        .onChange(of: store.settings.effectiveNotchTimerEnabled) { _, _ in FramoNotchTimerController.shared.refreshPreferences() }
        .task(id: launchStyle) {
            guard launchStyle != .none else {
                finishBoot()
                return
            }
            try? await Task.sleep(for: .seconds(launchStyle.duration))
            guard !Task.isCancelled else { return }
            finishBoot()
        }
        .onChange(of: store.showProjectCreator) { _, shouldShow in
            guard shouldShow else {
                if activeSheet == .projectCreator { activeSheet = nil }
                return
            }
            if activeSheet == nil { activeSheet = .projectCreator }
        }
        .onChange(of: onboardingCompleted) { _, completed in
            if completed {
                if activeSheet == .onboarding { activeSheet = nil }
            } else {
                onboardingPresentedThisLaunch = false
                presentOnboardingIfNeeded()
            }
        }
        .onChange(of: store.profileGatePresented) { _, isLocked in
            if !isLocked { presentOnboardingIfNeeded() }
        }
    }

    private func finishBoot() {
        guard isBooting else { return }
        launchStyle = .none
        withAnimation(.easeOut(duration: 0.24)) {
            isBooting = false
        }
        presentOnboardingIfNeeded()
    }

    private func sheetDidDismiss() {
        if store.showProjectCreator { store.showProjectCreator = false }
    }

    private func presentOnboardingIfNeeded() {
        guard !isBooting,
              !onboardingCompleted,
              !onboardingPresentedThisLaunch,
              !store.profileGatePresented,
              activeSheet == nil else { return }
        onboardingPresentedThisLaunch = true
        activeSheet = .onboarding
    }

    private var currentFeatureIntro: FramoFeatureIntroDescriptor {
        if store.selectedSpaceID != nil { return .space }
        if store.selectedProjectID != nil { return .project }
        switch store.selection {
        case .home: return .home
        case .search: return .search
        case .customers, .sales, .finance: return .home
        case .projects: return .projects
        case .tasks: return .tasks
        case .calendar: return .calendar
        case .resources: return .resources
        case .places: return .places
        case .settings: return .settings
        }
    }

    private var appShell: some View {
        HStack(alignment: .top, spacing: 0) {
            StudioSidebar(collapsed: $sidebarCollapsed)
                .frame(width: sidebarCollapsed ? 62 : 244)
                .animation(.easeOut(duration: 0.12), value: sidebarCollapsed)

            ZStack {
                StudioTheme.sidebar
                VStack(spacing: 0) {
                    TopBar(sidebarCollapsed: $sidebarCollapsed)
                        .frame(height: 38)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(StudioTheme.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        if let spaceID = store.selectedSpaceID {
            FramoSpaceViewV13(spaceID: spaceID)
        } else if store.selection == .projects, let projectID = store.selectedProjectID {
            if let duoID = store.duoProjectID, duoID != projectID {
                HSplitView {
                    ProjectDetailView(projectID: projectID)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    ZStack(alignment: .topTrailing) {
                        ProjectDetailView(projectID: duoID)
                            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                        Button { store.closeDuo() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 26, height: 26)
                                .background(StudioTheme.elevated)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).studioPointerCursor().padding(8).help("Close Duo")
                    }
                }
            } else {
                ProjectDetailView(projectID: projectID)
            }
        } else {
            switch store.selection {
            case .home: HomeView()
            case .search: FramoSearchViewV13()
            case .customers: ModoCustomersView()
            case .sales: ModoSalesView()
            case .projects: FramoProjectsViewV13(favoritesOnly: false)
            case .tasks: FramoTasksViewV17()
            case .calendar: FramoCalendarViewV13()
            case .resources:
                if store.isFeatureAvailable(.resourceHub) { FramoResourcesViewV20() }
                else { FramoLockedFeatureView(feature: .resourceHub) }
            case .places:
                if store.isFeatureAvailable(.placesWorkspace) { FramoPlacesViewV20() }
                else { FramoLockedFeatureView(feature: .placesWorkspace) }
            case .finance: ModoFinanceView()
            case .settings: FramoSettingsView()
            }
        }
    }
}

private struct GlobalCommandPalette: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var query = ""
    @FocusState private var focused: Bool

    private enum ResultKind: String { case action = "Action", customer = "Customer", quote = "Quote", project = "Work", task = "Task", event = "Calendar", file = "File", space = "Space", place = "Place", person = "Person", gear = "Gear", page = "Page" }
    private struct Result: Identifiable {
        let id: String
        let kind: ResultKind
        let title: String
        let subtitle: String
        let symbol: String
        let action: () -> Void
    }

    private var results: [Result] {
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = rawQuery.lowercased()
        var items: [Result] = []

        func addAction(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, keywords: String, action: @escaping () -> Void) {
            if needle.isEmpty || keywords.localizedCaseInsensitiveContains(needle) || title.localizedCaseInsensitiveContains(needle) {
                items.append(Result(id: "action-\(id)", kind: .action, title: title, subtitle: subtitle, symbol: symbol, action: action))
            }
        }

        if store.isDestinationEnabled(.customers) {
            addAction("customer", "New customer", "Start a relationship record", "person.crop.circle.badge.plus", keywords: "new create customer client contact") {
                store.openDestination(.customers); close()
            }
        }
        if store.isDestinationEnabled(.sales) {
            addAction("quote", "New quote", "Create a quote draft · ⇧⌘Q", "doc.text", keywords: "new create quote proposal estimate") {
                _ = store.createQuote(customerID: store.business.organizations.first?.id)
                store.openDestination(.sales); close()
            }
        }
        if store.isDestinationEnabled(.projects) {
            addAction("project", "New work", "Create work · ⇧⌘N", "plus.square", keywords: "new create project work job") {
                store.requestProjectCreation(); close()
            }
            addAction("time", "Start time tracking", "Open the instant work timer · ⌥⌘F", "timer", keywords: "time timer track start") {
                store.showTimeLauncher = true; close()
            }
        }
        if store.isDestinationEnabled(.tasks) {
            addAction("task", "New task", "Create a task · ⇧⌘T", "checkmark.circle", keywords: "new create task") {
                store.quickAddTask(); store.openDestination(.tasks); close()
            }
        }
        addAction("backup", "Back up now", "Create a verified workspace snapshot", "externaldrive.badge.timemachine", keywords: "backup save snapshot protect workspace") { store.runBackupNow(); close() }
        addAction("health", "System Health", "Backups, sync, connectors and local data", "heart.text.square", keywords: "health diagnostics status backup sync storage") { store.requestedSettingsPane = "System Health"; store.openDestination(.settings); close() }
        if store.isDestinationEnabled(.projects), let projectID = store.selectedProjectID {
            addAction("project-milestone", "Add milestone", "Add a delivery point to the current work", "flag", keywords: "milestone delivery checkpoint project") {
                if let index = store.projects.firstIndex(where: { $0.id == projectID }) {
                    var milestones = store.projects[index].milestones ?? []
                    milestones.append(ModoMilestone(title: "New milestone", dueDate: store.projects[index].dueDate))
                    store.projects[index].milestones = milestones
                    store.recordBusinessActivity(kind: .created, summary: "Milestone created", recordType: "project", recordID: projectID)
                }
                close()
            }
        }
        addAction("sync", "Sync workspace", "CloudKit + Google change check", "arrow.triangle.2.circlepath", keywords: "sync cloud google refresh") {
            Task {
                await store.cloudSync.syncNow()
                await store.googleConnector.checkIncrementalChanges()
            }
            close()
        }
        addAction("connectors", "Open connectors", "Google, Frame.io, CloudKit and MCP", "point.3.connected.trianglepath.dotted", keywords: "connectors integrations store google frame cloud mcp") {
            store.requestedSettingsPane = "Store"
            store.openDestination(.settings)
            close()
        }
        addAction("share", "Share workspace", "Invite someone through iCloud", "person.badge.plus", keywords: "share invite collaborator cloud icloud") {
            store.requestedSettingsPane = "Store"
            store.openDestination(.settings)
            Task { await store.cloudSync.refreshSharingStatus() }
            close()
        }
        if store.isDestinationEnabled(.projects), store.googleConnector.isConnected {
            addAction("drive-changes", "Check Google Drive", "Look for Creative Brief changes", "externaldrive", keywords: "google drive docs changes brief refresh") {
                Task { await store.googleConnector.checkIncrementalChanges() }
                close()
            }
        }
        if store.isDestinationEnabled(.projects), store.frameIOConnector.isConnected {
            addAction("frame-refresh", "Refresh Frame.io", "Reload accessible workspaces and projects", "play.rectangle.on.rectangle", keywords: "frame frameio review projects refresh") {
                Task { await store.frameIOConnector.refreshCatalog() }
                close()
            }
        }

        if store.isDestinationEnabled(.customers), needle.hasPrefix("new customer ") {
            let name = String(rawQuery.dropFirst("new customer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                items.insert(Result(id: "action-customer-typed", kind: .action, title: "Create customer “\(name)”", subtitle: "Add to customer workspace", symbol: "person.crop.circle.badge.plus") {
                    _ = store.createCustomer(name: name); store.openDestination(.customers); close()
                }, at: 0)
            }
        } else if store.isDestinationEnabled(.sales), needle.hasPrefix("new quote ") {
            let customerName = String(rawQuery.dropFirst("new quote ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let customerID = store.business.organizations.first(where: { $0.name.localizedCaseInsensitiveContains(customerName) })?.id
            items.insert(Result(id: "action-quote-typed", kind: .action, title: customerID == nil ? "Create quote" : "Create quote for \(store.customerName(id: customerID))", subtitle: customerID == nil ? "Choose customer in Sales" : "Create immediately", symbol: "doc.text") {
                _ = store.createQuote(customerID: customerID); store.openDestination(.sales); close()
            }, at: 0)
        } else if store.isDestinationEnabled(.projects), needle.hasPrefix("new project ") {
            let title = String(rawQuery.dropFirst("new project ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                items.insert(Result(id: "action-project-typed", kind: .action, title: "Create project “\(title)”", subtitle: "Create immediately", symbol: "plus.square") {
                    store.createProject(title: title, client: ""); close()
                }, at: 0)
            }
        } else if store.isDestinationEnabled(.tasks), needle.hasPrefix("new task ") {
            let title = String(rawQuery.dropFirst("new task ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                items.insert(Result(id: "action-task-typed", kind: .action, title: "Create task “\(title)”", subtitle: "Add to workspace", symbol: "checkmark.circle") {
                    store.addTask(title: title, dueDate: nil, projectID: store.selectedProjectID); close()
                }, at: 0)
            }
        } else if store.isDestinationEnabled(.projects), needle.hasPrefix("time ") {
            let name = String(rawQuery.dropFirst("time ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let project = store.projects.first(where: { $0.title.localizedCaseInsensitiveContains(name) }) {
                items.insert(Result(id: "action-time-typed", kind: .action, title: "Start timer · \(project.title)", subtitle: project.client, symbol: "record.circle") {
                    store.startTimer(for: project.id); close()
                }, at: 0)
            }
        }
        for page in [SidebarDestination.home, .search, .customers, .sales, .projects, .tasks, .calendar, .resources, .places, .finance, .settings]
        where store.isDestinationEnabled(page) {
            if needle.isEmpty || page.displayName.lowercased().contains(needle) {
                items.append(Result(id: "page-\(page.rawValue)", kind: .page, title: page.displayName, subtitle: "Open page", symbol: page.fallback) {
                    store.openDestination(page); close()
                })
            }
        }
        if store.isDestinationEnabled(.customers) {
            for customer in store.business.organizations where needle.isEmpty || [customer.name, customer.email, customer.phone, customer.city, customer.vatNumber, customer.notes].joined(separator: " ").localizedCaseInsensitiveContains(needle) {
            items.append(Result(id: "customer-\(customer.id)", kind: .customer, title: customer.name, subtitle: customer.email.isEmpty ? customer.city : customer.email, symbol: "person.2") {
                store.openDestination(.customers); close()
            })
            }
        }
        if store.isDestinationEnabled(.sales) {
            for quote in store.business.quotes where needle.isEmpty || [quote.quoteNumber, quote.status.rawValue, store.customerName(id: quote.customerID)].joined(separator: " ").localizedCaseInsensitiveContains(needle) {
            items.append(Result(id: "quote-\(quote.id)", kind: .quote, title: quote.quoteNumber, subtitle: "\(store.customerName(id: quote.customerID)) · \(quote.total.formatted(.currency(code: quote.currency)))", symbol: "doc.text") {
                store.openDestination(.sales); close()
            })
            }
        }
        if store.isDestinationEnabled(.projects) {
            for project in store.projects where needle.isEmpty || projectSearchText(project).localizedCaseInsensitiveContains(needle) {
            items.append(Result(id: "project-\(project.id)", kind: .project, title: project.title, subtitle: [project.client, project.status.displayName(for: project.effectiveWorkType)].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "square.stack.3d.up") {
                store.openProject(project.id); close()
            })
            }
            for space in store.spaces where needle.isEmpty || [space.title, space.subtitle, space.notes].joined(separator: " ").localizedCaseInsensitiveContains(needle) {
            items.append(Result(id: "space-\(space.id)", kind: .space, title: space.title, subtitle: space.subtitle, symbol: "square.grid.2x2") {
                store.openSpace(space.id); close()
            })
            }
        }
        if store.isDestinationEnabled(.places) {
            for place in store.places where needle.isEmpty || [place.name, place.address, place.notes].joined(separator: " ").localizedCaseInsensitiveContains(needle) {
            items.append(Result(id: "place-\(place.id)", kind: .place, title: place.name, subtitle: place.address.isEmpty ? "Saved place" : place.address, symbol: "mappin.and.ellipse") {
                store.openDestination(.places); close()
            })
            }
        }
        if store.isDestinationEnabled(.tasks) {
            for task in store.tasks where needle.isEmpty || task.title.lowercased().contains(needle) {
            let project = task.projectID.flatMap { id in store.projects.first(where: { $0.id == id }) }
            items.append(Result(id: "task-\(task.id)", kind: .task, title: task.title, subtitle: project?.title ?? "Task", symbol: "checklist") {
                if let id = task.projectID { store.openProjectSection(id, section: .tasks) } else { store.openDestination(.tasks) }
                close()
            })
            }
        }
        if store.isDestinationEnabled(.calendar) {
            for event in store.calendarItems where needle.isEmpty || [event.title, event.location].joined(separator: " ").lowercased().contains(needle) {
            items.append(Result(id: "event-\(event.id)-\(event.date.timeIntervalSince1970)", kind: .event, title: event.title, subtitle: event.date.formatted(date: .abbreviated, time: .shortened), symbol: "calendar") {
                if let id = event.projectID { store.openProject(id) } else { store.openDestination(.calendar) }
                close()
            })
            }
        }
        if store.isDestinationEnabled(.resources) || store.isDestinationEnabled(.projects) {
            for project in store.projects {
                for member in project.crew where needle.isEmpty || [member.name, member.role, member.email, member.phone ?? "", member.handle ?? "", member.notes ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(needle) {
                items.append(Result(id: "crew-\(project.id)-\(member.id)", kind: .person, title: member.name, subtitle: [member.role, project.title].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "person.2") {
                    store.openDestination(.resources); close()
                })
            }
            for item in project.kit where needle.isEmpty || [item.name, item.category, item.serialNumber ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(needle) {
                items.append(Result(id: "gear-\(project.id)-\(item.id)", kind: .gear, title: item.name, subtitle: [item.category, project.title].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "camera") {
                    store.openDestination(.resources); close()
                })
            }
                for file in project.linkedFiles ?? [] where store.isDestinationEnabled(.projects) && (needle.isEmpty || [file.displayName, file.originalPath, file.volumeName, file.contentType].joined(separator: " ").localizedCaseInsensitiveContains(needle)) {
                    items.append(Result(id: "file-\(file.id)", kind: .file, title: file.displayName, subtitle: project.title + " · " + file.volumeName, symbol: "doc") {
                        store.openProjectSection(project.id, section: .files); close()
                    })
                }
            }
        }
        return Array(items.prefix(48))
    }

    private func projectSearchText(_ project: StudioProject) -> String {
        let core = [
            project.title, project.client, project.description, project.location,
            project.brief, project.script, project.deliverable, project.editingSoftware,
            project.aspectRatio, project.resolution, project.frameRate,
            project.kind?.rawValue ?? "", project.status.rawValue
        ]
        let shots = project.shots.flatMap { [$0.title, $0.description, $0.shotSize, $0.movement, $0.lens] }
        let storyboard = project.storyboard.flatMap { [$0.title, $0.notes] }
        let contacts = (project.clientContacts ?? []).flatMap { [$0.name, $0.company, $0.email, $0.phone] }
        return (core + shots + storyboard + contacts).joined(separator: " ")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.secondary)
                    TextField("Search MODO or type ‘new customer …’", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit { results.first?.action() }
                    Text("ESC").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
                }
                .padding(.horizontal, 16).frame(height: 50)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(results) { result in
                            Button { result.action() } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: result.symbol).frame(width: 20).foregroundStyle(StudioTheme.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(result.subtitle).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(result.kind.rawValue).font(.system(size: 8, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
                                }
                                .foregroundStyle(StudioTheme.primary)
                                .padding(.horizontal, 12).frame(height: 46)
                                .background(StudioTheme.soft.opacity(0.42))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                        if results.isEmpty {
                            Text(query.isEmpty ? "Search everything or run an action." : "No matching results")
                                .font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).padding(28)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 430)
            }
            .frame(width: 620)
            .background(StudioTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { close() }
    }

    private func close() { store.showGlobalSearch = false }
}

private struct PluginNoticeToast: View {
    @EnvironmentObject private var store: FramoStudioStore
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(StudioTheme.secondary)
            Text(message).font(.system(size: 10, weight: .medium)).lineLimit(3)
            Button { store.pluginNotice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).studioPointerCursor()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 420, alignment: .leading)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .task(id: message) {
            try? await Task.sleep(for: .seconds(4.5))
            if store.pluginNotice == message { store.pluginNotice = nil }
        }
    }
}




private struct BootSplashView: View {
    let style: ModoLaunchStyle

    @State private var cardVisible = false
    @State private var cardExpanded = false
    @State private var wordmarkVisible = false
    @State private var photoSettled = false
    @State private var materialVisible = true

    private var timingScale: Double {
        style == .condensed ? 0.34 : 1.0
    }

    var body: some View {
        GeometryReader { proxy in
            let cardSide = min(300, max(230, min(proxy.size.width, proxy.size.height) * 0.34))
            let width = cardExpanded ? proxy.size.width : cardSide
            let height = cardExpanded ? proxy.size.height : cardSide

            ZStack {
                StudioTheme.canvas
                    .opacity(materialVisible ? 0 : 1)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(materialVisible ? 1 : 0)
                    .ignoresSafeArea()

                Color.black
                    .opacity(materialVisible ? 0.08 : 0)
                    .ignoresSafeArea()

                ZStack {
                    Image("unsplashimagesplashscreen")
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(photoSettled ? 1.0 : 1.08)

                    Color.black.opacity(0.035)

                    Image("MODOLOGO")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: cardExpanded ? 340 : 170)
                        .opacity(wordmarkVisible ? 1 : 0)
                        .scaleEffect(wordmarkVisible ? 1 : 0.92)
                        .mask {
                            Rectangle()
                                .fill(.white)
                                .frame(width: 600, height: 280)
                                .rotationEffect(.degrees(-18))
                                .offset(
                                    x: wordmarkVisible ? 0 : 390,
                                    y: wordmarkVisible ? 0 : -190
                                )
                                .blur(radius: 10)
                        }
                }
                .frame(width: width, height: height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: cardExpanded ? 0 : 30,
                        style: .continuous
                    )
                )
                .shadow(
                    color: .black.opacity(cardExpanded ? 0 : 0.34),
                    radius: cardExpanded ? 0 : 34,
                    y: cardExpanded ? 0 : 18
                )
                .scaleEffect(cardVisible ? 1 : 0.86)
                .opacity(cardVisible ? 1 : 0)
                .animation(.spring(response: 0.81 * timingScale, dampingFraction: 0.86), value: cardVisible)
                .animation(.easeInOut(duration: 1.20 * timingScale), value: cardExpanded)
                .animation(.easeOut(duration: 1.61 * timingScale), value: photoSettled)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            if style == .none {
                cardVisible = true
                cardExpanded = true
                wordmarkVisible = true
                photoSettled = true
                materialVisible = false
                return
            }

            withAnimation(.spring(response: 0.81 * timingScale, dampingFraction: 0.86)) {
                cardVisible = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.98 * timingScale) {
                withAnimation(.easeInOut(duration: 1.20 * timingScale)) {
                    cardExpanded = true
                }
                withAnimation(.easeOut(duration: 1.61 * timingScale)) {
                    photoSettled = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15 * timingScale) {
                withAnimation(.easeOut(duration: 0.73 * timingScale)) {
                    wordmarkVisible = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.23 * timingScale) {
                withAnimation(.easeOut(duration: 0.70 * timingScale)) {
                    materialVisible = false
                }
            }
        }
        .transition(.opacity)
    }
}

private struct ModoLaunchInputCatcher: NSViewRepresentable {
    let onInput: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onInput = onInput
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onInput: () -> Void
        private var monitor: Any?

        init(onInput: @escaping () -> Void) {
            self.onInput = onInput
        }

        func install() {
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                DispatchQueue.main.async { self?.onInput() }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { uninstall() }
    }
}

private struct TopBar: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var sidebarCollapsed: Bool

    var body: some View {
        HStack(spacing: 4) {
            navigationButtons
            searchButton

            pinnedTabs
                .layoutPriority(10)

            timerBadge
            profileButton
            notificationButton
            addButton
            actionsMenu
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(StudioTheme.icon)
        .padding(.horizontal, 7)
    }

    private var navigationButtons: some View {
        HStack(spacing: 1) {
            Button { sidebarCollapsed.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(IconButtonStyle()).help("Toggle sidebar")
            Button { store.goBack() } label: { Image(systemName: "chevron.backward") }
                .buttonStyle(IconButtonStyle()).disabled(!store.canGoBack).help("Back")
            Button { store.goForward() } label: { Image(systemName: "chevron.forward") }
                .buttonStyle(IconButtonStyle()).disabled(!store.canGoForward).help("Forward")
        }
    }

    private var searchButton: some View {
        Button { store.showGlobalSearch = true } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).studioPointerCursor()
        .help("Search · ⌘K")
    }

    private var pinnedTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(store.pinnedPages.filter { store.isDestinationEnabled($0) }, id: \.self) { page in TopPageTab(page: page) }
                if store.isDestinationEnabled(.projects) {
                    ForEach(store.pinnedProjects) { project in TopProjectTab(project: project) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var notificationButton: some View {
        Button {
            store.refreshNotifications()
            store.showNotificationCenter.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: store.showNotificationCenter ? "bell.fill" : "bell")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                if store.unreadNotificationCount > 0 {
                    Circle().fill(Color(hex: "18A774")).frame(width: 5, height: 5)
                        .padding(.top, 4).padding(.trailing, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).studioPointerCursor()
        .help("Notifications")
        .accessibilityLabel("Notifications, \(store.unreadNotificationCount) unread")
    }

    private var addButton: some View {
        Menu {
            if store.isDestinationEnabled(.customers) {
                Button("Customer", systemImage: "person.crop.circle.badge.plus") { store.openDestination(.customers) }
            }
            if store.isDestinationEnabled(.sales) {
                Button("Opportunity", systemImage: "arrow.up.right") {
                    _ = store.createOpportunity(customerID: store.business.organizations.first?.id, title: "New opportunity")
                    store.openDestination(.sales)
                }
                Button("Quote", systemImage: "doc.text") {
                    _ = store.createQuote(customerID: store.business.organizations.first?.id)
                    store.openDestination(.sales)
                }
            }
            if store.isDestinationEnabled(.projects) || store.isDestinationEnabled(.tasks) { Divider() }
            if store.isDestinationEnabled(.projects) {
                Button("Work", systemImage: "plus.square") { store.requestProjectCreation() }
            }
            if store.isDestinationEnabled(.tasks) {
                Button("Task", systemImage: "checkmark.circle") { store.quickAddTask(); store.openDestination(.tasks) }
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .studioPointerCursor()
        .help("Create")
    }

    @ViewBuilder private var timerBadge: some View {
        if let projectID = store.activeTimerProjectID {
            Button { store.showTimeLauncher = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(StudioTheme.red).frame(width: 6, height: 6)
                    Text(store.projects.first(where: { $0.id == projectID })?.title ?? "Timer")
                        .lineLimit(1).frame(maxWidth: 110)
                    Image(systemName: "timer").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StudioTheme.primary)
                .padding(.horizontal, 9).frame(height: 27)
                .background(StudioTheme.elevated)
                .overlay(Capsule().stroke(StudioTheme.border))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).studioPointerCursor().help("Open Time Manager")
        }
    }

    private var profileDisplayName: String {
        let clean = store.settings.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = clean.split(separator: " ").first, !first.isEmpty { return String(first) }
        return store.activeProfileName
    }

    private var profileButton: some View {
        Menu {
            Text("Workspace owner · \(profileDisplayName)")
            Text(store.activeProfileName)
            Divider()
            Section("Workspaces") {
                ForEach(store.profiles) { profile in
                    Button {
                        if profile.id != store.activeProfileID { store.switchProfile(to: profile.id) }
                    } label: {
                        HStack {
                            Text(profile.name)
                            if profile.id == store.activeProfileID { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Divider()
            Button("Workspaces & Security…", systemImage: "lock.shield") {
                store.requestedSettingsPane = "Workspaces & Security"
                store.openDestination(.settings)
            }
            Button("Lock workspace", systemImage: "lock") {
                store.lockActiveProfile()
            }
        } label: {
            HStack(spacing: 5) {
                Text(profileDisplayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(StudioTheme.soft.opacity(0.64))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Workspace account")
    }

    private var actionsMenu: some View {
        Menu {
            if store.isDestinationEnabled(.projects) {
                Button("New work", systemImage: "plus") { store.requestProjectCreation() }
                Button("New space", systemImage: "square.grid.2x2") { store.createSpace() }
            }

            Menu("Open tab", systemImage: "plus.rectangle.on.rectangle") {
                ForEach(SidebarDestination.allCases.filter { $0 != .settings && store.isDestinationEnabled($0) }) { destination in
                    Button(destination.displayName) { store.pinPage(destination); store.openDestination(destination) }
                }
                if store.isDestinationEnabled(.projects), !store.projects.isEmpty {
                    Divider()
                    ForEach(store.projects) { project in
                        Button(project.title) { store.openProject(project.id) }
                    }
                }
            }

            if let selectedID = store.selectedProjectID {
                Menu("Split view", systemImage: "rectangle.split.2x1") {
                    ForEach(store.projects.filter { $0.id != selectedID }) { project in
                        Button(project.title) { store.openInDuo(project.id) }
                    }
                    if store.duoProjectID != nil {
                        Divider()
                        Button("Close split view") { store.closeDuo() }
                    }
                }

                let actions = store.pluginActions(target: .project)
                Menu("Plugins", systemImage: "puzzlepiece.extension") {
                    if actions.isEmpty { Button("Open plugin library") { store.openPluginSettings() } }
                    ForEach(actions) { registered in
                        Button(registered.action.label) { store.runPluginAction(registered, projectID: selectedID) }
                    }
                    if !actions.isEmpty { Divider(); Button("Plugin library…") { store.openPluginSettings() } }
                }
            } else {
                Button("Plugin library…", systemImage: "puzzlepiece.extension") { store.openPluginSettings() }
            }

            Divider()
            Button("Settings", systemImage: "gearshape") { store.openDestination(.settings) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 29, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .studioPointerCursor()
        .help("More")
    }
}

private struct TopPageTab: View {
    @EnvironmentObject private var store: FramoStudioStore
    let page: SidebarDestination
    @State private var hovered = false

    private var selected: Bool {
        store.selectedProjectID == nil && store.selectedSpaceID == nil && store.selection == page
    }

    var body: some View {
        HStack(spacing: 5) {
            Button { store.openDestination(page) } label: {
                HStack(spacing: 5) {
                    Image(systemName: page.fallback).font(.system(size: 9))
                    Text(page.displayName).lineLimit(1)
                }
                .padding(.leading, 7)
            }
            .buttonStyle(.plain).studioPointerCursor()
            if hovered {
                Button { store.unpinPage(page) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).studioPointerCursor().padding(.trailing, 6)
            } else {
                Color.clear.frame(width: 5)
            }
        }
        .frame(height: 26)
        .background(selected ? StudioTheme.selected : StudioTheme.soft)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? StudioTheme.border : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .contextMenu {
            newTabMenu
            Button("Pin tab", systemImage: "pin") { store.pinPage(page) }
            Divider()
            Button("Close tab", systemImage: "xmark") { store.unpinPage(page) }
        }
    }

    private var newTabMenu: some View {
        Menu("New tab", systemImage: "plus") {
            ForEach(SidebarDestination.allCases.filter { $0 != .settings && store.isDestinationEnabled($0) }) { destination in
                Button(destination.displayName) { store.pinPage(destination); store.openDestination(destination) }
            }
            Divider()
            ForEach(store.projects) { project in
                Button(project.title) { store.openProject(project.id) }
            }
        }
    }
}

private struct TopProjectTab: View {
    @EnvironmentObject private var store: FramoStudioStore
    let project: StudioProject
    @State private var hovered = false

    private var selected: Bool { store.selectedProjectID == project.id }
    private var isPinned: Bool { store.isProjectTabPinned(project.id) }

    var body: some View {
        HStack(spacing: 5) {
            Button { store.openProject(project.id) } label: {
                HStack(spacing: 5) {
                    if isPinned { Image(systemName: "pin.fill").font(.system(size: 7)) }
                    Capsule()
                        .fill(Color(hex: project.colorHex))
                        .frame(width: 3, height: 13)
                    Text(project.title).lineLimit(1).frame(maxWidth: 112)
                }
                .padding(.leading, 7)
            }
            .buttonStyle(.plain).studioPointerCursor()
            if hovered && !isPinned {
                Button { store.closeProjectTab(project.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).studioPointerCursor().padding(.trailing, 6)
            } else {
                Color.clear.frame(width: 5)
            }
        }
        .frame(height: 26)
        .background(selected ? StudioTheme.selected : StudioTheme.soft)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? StudioTheme.border : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .contextMenu {
            newTabMenu
            Button(isPinned ? "Unpin tab" : "Pin tab", systemImage: isPinned ? "pin.slash" : "pin") {
                store.setProjectTabPinned(project.id, pinned: !isPinned)
            }
            Button(store.isProjectPinnedToSidebar(project.id) ? "Remove from sidebar" : "Pin to sidebar", systemImage: "sidebar.left") {
                if store.isProjectPinnedToSidebar(project.id) { store.unpinProjectFromSidebar(project.id) }
                else { store.pinProjectToSidebar(project.id) }
            }
            Menu("Duo / Split View", systemImage: "rectangle.split.2x1") {
                ForEach(store.projects.filter { $0.id != project.id }) { other in
                    Button(other.title) {
                        store.openProject(project.id)
                        store.openInDuo(other.id)
                    }
                }
            }
            let pluginActions = store.pluginActions(target: .project)
            if !pluginActions.isEmpty {
                Divider()
                Menu("Plugins") {
                    ForEach(pluginActions) { registered in
                        Button(registered.action.label) { store.runPluginAction(registered, projectID: project.id) }
                    }
                }
            }
            Divider()
            Button("Close tab", systemImage: "xmark") { store.closeProjectTab(project.id) }
        }
    }

    private var newTabMenu: some View {
        Menu("New tab", systemImage: "plus") {
            ForEach(SidebarDestination.allCases.filter { $0 != .settings && store.isDestinationEnabled($0) }) { destination in
                Button(destination.displayName) { store.pinPage(destination); store.openDestination(destination) }
            }
            Divider()
            ForEach(store.projects.filter { $0.id != project.id }) { other in
                Button(other.title) { store.openProject(other.id) }
            }
        }
    }
}

private struct DuoProjectPicker: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var showing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Multitask").font(.system(size: 13, weight: .semibold))
            Text("Open another work item beside the current one.")
                .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.projects.filter { $0.id != store.selectedProjectID }) { project in
                        Button {
                            store.openInDuo(project.id)
                            showing = false
                        } label: {
                            HStack(spacing: 9) {
                                Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(project.client).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "rectangle.split.2x1").font(.system(size: 9))
                            }
                            .foregroundStyle(StudioTheme.primary)
                            .padding(.horizontal, 8)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    }
                }
            }
            .frame(maxHeight: 260)
            if store.duoProjectID != nil {
                Divider()
                Button("Close split view") {
                    store.closeDuo()
                    showing = false
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(StudioTheme.elevated)
    }
}

private struct PinPicker: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var showing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add tab").font(.system(size: 13, weight: .semibold))
            Text("Pin any workspace page or project to the top bar.")
                .font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
            Divider()
            Text("PAGES").pickerLabel()
            ForEach(SidebarDestination.allCases.filter { $0 != .settings && store.isDestinationEnabled($0) }) { page in
                pickerButton(icon: page.fallback, title: page.displayName) {
                    store.pinPage(page); store.openDestination(page); showing = false
                }
            }
            if store.isDestinationEnabled(.projects) {
                Divider()
                Text("WORK").pickerLabel()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.projects) { project in
                            Button {
                                store.openProject(project.id); showing = false
                            } label: {
                                HStack(spacing: 8) {
                                    Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 17)
                                    Text(project.title).lineLimit(1)
                                    Spacer()
                                    if store.settings.pinnedProjectIDs?.contains(project.id) == true { Image(systemName: "checkmark") }
                                }
                                .font(.system(size: 11))
                                .padding(.horizontal, 8).frame(height: 31)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                    }
                }
                .frame(height: min(CGFloat(store.projects.count) * 33, 210))
            }
        }
        .padding(14).frame(width: 300)
        .background(StudioTheme.elevated)
    }

    private func pickerButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { Image(systemName: icon).frame(width: 16); Text(title); Spacer(); Image(systemName: "plus") }
                .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 31).contentShape(Rectangle())
        }.buttonStyle(.plain).studioPointerCursor()
    }
}

private struct FramoFeatureIntroDescriptor: Hashable {
    let key: String
    let eyebrow: String
    let title: String
    let body: String
    let shortcut: String?

    static let home = Self(key: "home", eyebrow: "HOME", title: "Your business overview", body: "See active work, deadlines and what needs attention without opening every job.", shortcut: nil)
    static let search = Self(key: "search", eyebrow: "SEARCH", title: "Find anything quickly", body: "Search projects, tasks, people, spaces and events from one place.", shortcut: "⌘K")
    static let projects = Self(key: "projects", eyebrow: "WORK", title: "Every job, one system", body: "Open work to move from scope and planning to people, files, delivery and time logging.", shortcut: nil)
    static let tasks = Self(key: "tasks", eyebrow: "TASKS", title: "Keep the next action visible", body: "Create lightweight tasks, connect them to a project and keep work moving.", shortcut: nil)
    static let calendar = Self(key: "calendar", eyebrow: "CALENDAR", title: "Plan shoots and deadlines visually", body: "Use the week and month views to keep events, deadlines and production blocks together.", shortcut: nil)
    static let resources = Self(key: "resources", eyebrow: "CREW & DEVICES", title: "Add people and kit once", body: "Use Add to create a crew member or device and place it directly in the right work item.", shortcut: nil)
    static let places = Self(key: "places", eyebrow: "PLACES", title: "Your location library", body: "Search Apple Maps, save production locations, add photos and notes, and link each place back to projects.", shortcut: nil)
    static let settings = Self(key: "settings", eyebrow: "SETTINGS", title: "Make MODO yours", body: "Choose language and appearance, configure backups and sharing, or reset the workspace from Advanced.", shortcut: nil)
    static let project = Self(key: "project", eyebrow: "WORK", title: "Everything for one job", body: "Work pages adapt to the type of job. Keep only the planning, production and delivery tools you actually need.", shortcut: nil)
    static let space = Self(key: "space", eyebrow: "SPACE", title: "Group work without moving it", body: "Spaces collect related projects into a flexible overview. The project data stays connected wherever you view it.", shortcut: nil)
}

private struct FramoFeatureCoachmark: View {
    let descriptor: FramoFeatureIntroDescriptor
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(descriptor.eyebrow).font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(StudioTheme.tertiary)
                    }
                    Text(descriptor.title).font(.system(size: 14, weight: .semibold))
                    Text(descriptor.body).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let shortcut = descriptor.shortcut {
                            Text(shortcut).font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioTheme.tertiary)
                        }
                        Spacer()
                        Button("Skip") { dismiss() }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                        Button("Got it") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(14).frame(width: 320)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.border))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 7)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            isVisible = !UserDefaults.standard.bool(forKey: storageKey)
        }
        .animation(.easeOut(duration: 0.16), value: isVisible)
    }

    private var storageKey: String { "studio.feature-intro.\(descriptor.key).v1" }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: storageKey)
        isVisible = false
    }
}

private struct StudioSidebar: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        SidebarDestination.allCases.filter {
                            store.settings.effectiveVisibleDestinations.contains($0)
                        }
                    ) { SidebarRow(destination: $0, collapsed: collapsed) }

                    if !collapsed {
                        if !store.sidebarProjects.isEmpty {
                            Text("Pinned").sidebarSectionTitle()
                            ForEach(store.sidebarProjects) { project in
                                SidebarProjectRow(project: project)
                            }
                        }

                        if !store.projects.filter(\.favorite).isEmpty {
                            Text("Favorites").sidebarSectionTitle()
                            ForEach(store.projects.filter(\.favorite).prefix(4)) { project in
                                SidebarProjectRow(project: project)
                            }
                        }

                        HStack {
                            Text("Spaces")
                            Spacer()
                            Button { store.createSpace() } label: { Image(systemName: "plus") }
                                .buttonStyle(.plain).studioPointerCursor()
                        }
                        .sidebarSectionTitle()
                    } else {
                        Color.clear.frame(height: 8)
                    }

                    ForEach(store.spaces) { SpaceSidebarRow(space: $0, collapsed: collapsed) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)

            SidebarTransferPanel(collapsed: collapsed)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(StudioTheme.sidebar)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            StudioLogoMark(size: 29)

            if !collapsed {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.settings.studioName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    Text("Welcome, \(sidebarWelcomeName)")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button { store.requestProjectCreation() } label: {
                    AssetIcon(name: "icon-compose", fallback: "square.and.pencil", size: 13)
                }
                .buttonStyle(IconButtonStyle())
                .help("New work")
            }
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 12 : 13)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(StudioTheme.sidebar)
    }

    private var sidebarWelcomeName: String {
        let owner = store.settings.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty { return owner }

        let profile = store.activeProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? "there" : profile
    }
}

private struct SidebarProjectRow: View {
    @EnvironmentObject private var store: FramoStudioStore
    let project: StudioProject

    var body: some View {
        Button { store.openProject(project.id) } label: {
            HStack(spacing: 10) {
                Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 15)
                Text(project.title).lineLimit(1); Spacer()
            }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
            .padding(.horizontal, 17).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).studioPointerCursor()
        .contextMenu {
            Button("Open in Duo", systemImage: "rectangle.split.2x1") {
                if store.selectedProjectID == project.id {
                    if let other = store.projects.first(where: { $0.id != project.id }) { store.openInDuo(other.id) }
                } else if store.selectedProjectID != nil {
                    store.openInDuo(project.id)
                } else {
                    store.openProject(project.id)
                }
            }
            if store.isProjectPinnedToSidebar(project.id) {
                Button("Remove from sidebar", systemImage: "pin.slash") { store.unpinProjectFromSidebar(project.id) }
            } else {
                Button("Pin to sidebar", systemImage: "pin") { store.pinProjectToSidebar(project.id) }
            }
            let pluginActions = store.pluginActions(target: .project)
            if !pluginActions.isEmpty {
                Divider()
                Menu("Plugins") {
                    ForEach(pluginActions) { registered in
                        Button(registered.action.label) { store.runPluginAction(registered, projectID: project.id) }
                    }
                }
            }
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var store: FramoStudioStore
    let destination: SidebarDestination
    let collapsed: Bool
    @State private var showHoverStats = false

    private var selected: Bool {
        store.selection == destination && store.selectedProjectID == nil && store.selectedSpaceID == nil
    }

    var body: some View {
        Button { store.openDestination(destination) } label: {
            HStack(spacing: 10) {
                AssetIcon(name: destination.asset, fallback: destination.fallback, size: 16, color: selected ? StudioTheme.primary : StudioTheme.icon)
                if !collapsed { Text(destination.displayName); Spacer() }
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? StudioTheme.primary : StudioTheme.secondary)
            .padding(.horizontal, collapsed ? 0 : 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(selected ? StudioTheme.selected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).studioPointerCursor().padding(.horizontal, 9)
        .onHover { inside in
            guard collapsed else { showHoverStats = false; return }
            showHoverStats = inside
        }
        .popover(isPresented: Binding(
            get: { collapsed && showHoverStats },
            set: { if !$0 { showHoverStats = false } }
        ), arrowEdge: .leading) {
            SidebarHoverStatsCard(destination: destination)
                .environmentObject(store)
        }
        .help(collapsed ? "" : destination.displayName)
    }
}

private struct SpaceSidebarRow: View {
    @EnvironmentObject private var store: FramoStudioStore
    let space: StudioSpace
    let collapsed: Bool
    @State private var showHoverStats = false

    var body: some View {
        Button { store.openSpace(space.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: collapsed ? 16 : 14, weight: .medium)).foregroundStyle(StudioTheme.icon)
                    .frame(width: 31, height: 31)
                    .background(store.selectedSpaceID == space.id ? StudioTheme.selected : Color(hex: space.colorHex).opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                if !collapsed {
                    Text(space.title).lineLimit(1); Spacer()
                    Text("\(space.projectIDs.count)").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                }
            }
            .font(.system(size: 11, weight: store.selectedSpaceID == space.id ? .medium : .regular))
            .foregroundStyle(store.selectedSpaceID == space.id ? StudioTheme.primary : StudioTheme.secondary)
            .padding(.horizontal, collapsed ? 0 : 7).frame(maxWidth: .infinity, minHeight: 37)
        }
        .buttonStyle(.plain).studioPointerCursor().padding(.horizontal, 9).padding(.bottom, 2)
        .onHover { inside in
            guard collapsed else { showHoverStats = false; return }
            showHoverStats = inside
        }
        .popover(isPresented: Binding(
            get: { collapsed && showHoverStats },
            set: { if !$0 { showHoverStats = false } }
        ), arrowEdge: .leading) {
            SpaceHoverStatsCard(space: space).environmentObject(store)
        }
        .help(collapsed ? "" : space.title)
    }
}

private struct SidebarHoverStatsCard: View {
    @EnvironmentObject private var store: FramoStudioStore
    let destination: SidebarDestination

    private var rows: [(String, String)] {
        let openTasks = store.tasks.filter { !$0.isComplete }.count
        let activeProjects = store.projects.filter { $0.status != .delivered }.count
        let crewNames = Set(store.projects.flatMap { $0.crew.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } }.filter { !$0.isEmpty })
        let deviceCount = store.projects.flatMap(\.kit).reduce(0) { $0 + max(1, $1.quantity) }
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let upcoming = store.events.filter { $0.date >= .now && $0.date <= weekEnd }.count

        switch destination {
        case .home: return [("Active work", "\(activeProjects)"), ("Open tasks", "\(openTasks)")]
        case .search: return [("Customers", "\(store.business.organizations.count)"), ("Work", "\(store.projects.count)")]
        case .customers: return [("Customers", "\(store.business.organizations.count)"), ("Contacts", "\(store.business.people.count)")]
        case .sales: return [("Open", "\(store.business.opportunities.filter { ![.won, .lost].contains($0.stage) }.count)"), ("Quotes", "\(store.business.quotes.count)")]
        case .projects: return [("Total", "\(store.projects.count)"), ("Active", "\(activeProjects)")]
        case .tasks: return [("Open", "\(openTasks)"), ("Done", "\(store.tasks.filter(\.isComplete).count)")]
        case .calendar: return [("Next 7 days", "\(upcoming)"), ("All events", "\(store.events.count)")]
        case .resources: return [("Crew", "\(crewNames.count)"), ("Devices", "\(deviceCount)")]
        case .places: return [("Saved", "\(store.places.count)"), ("Photos", "\(store.places.reduce(0) { $0 + $1.photoPaths.count })")]
        case .finance: return [("Outstanding", store.outstandingInvoiceTotal.formatted(.currency(code: store.settings.currency))), ("Invoices", "\(store.invoices.count)")]
        case .settings: return [("Version", FramoStudioStore.appVersion), ("Build", FramoStudioStore.buildNumber)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AssetIcon(name: destination.asset, fallback: destination.fallback, size: 15, color: StudioTheme.primary)
                Text(destination.displayName).font(.system(size: 12, weight: .semibold))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                    Spacer()
                    Text(row.1).font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .padding(12).frame(width: 190)
        .background(StudioTheme.elevated)
    }
}

private struct SpaceHoverStatsCard: View {
    @EnvironmentObject private var store: FramoStudioStore
    let space: StudioSpace

    private var projects: [StudioProject] {
        store.projects.filter { space.projectIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 18, weight: .medium)).foregroundStyle(StudioTheme.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(space.title).font(.system(size: 12, weight: .semibold))
                    Text(space.subtitle).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
            }
            HStack {
                Text("Projects").foregroundStyle(StudioTheme.secondary)
                Spacer()
                Text("\(projects.count)").fontWeight(.semibold)
            }
            HStack {
                Text("Delivered").foregroundStyle(StudioTheme.secondary)
                Spacer()
                Text("\(projects.filter { $0.status == .delivered }.count)").fontWeight(.semibold)
            }
        }
        .font(.system(size: 9))
        .padding(12).frame(width: 200)
        .background(StudioTheme.elevated)
    }
}

private struct ProjectCreatorView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedWorkType: ModoWorkType?
    @State private var selectedKind: ProjectKind?
    @State private var title = ""
    @State private var client = ""
    @State private var bannerPath: String?
    @State private var bannerAssetName: String?
    @State private var hourlyRateText = ""
    @State private var fixedFeeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            creatorHeader

            Group {
                if selectedWorkType == nil {
                    workTypePicker
                } else if selectedWorkType == .creativeProduction && selectedKind == nil {
                    kindPicker
                } else {
                    projectSetup(selectedKind ?? fallbackKind)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))

            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(width: 720, height: 570)
        .background(StudioTheme.canvas)
        .animation(.easeInOut(duration: 0.20), value: selectedWorkType)
        .animation(.easeInOut(duration: 0.20), value: selectedKind)
    }

    private var fallbackKind: ProjectKind {
        switch selectedWorkType ?? .flexible {
        case .creativeProduction: return .personal
        case .event: return .event
        case .service: return .commercial
        case .consulting: return .commercial
        case .flexible: return .personal
        }
    }

    private var presetKinds: [ProjectKind] {
        ProjectKind.allCases.filter { $0 != .personal }
    }

    private var creatorHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 24, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
        }
    }

    private var headerTitle: String {
        guard let selectedWorkType else { return "What kind of work is this?" }
        if selectedWorkType == .creativeProduction && selectedKind == nil {
            return "Choose a creative preset"
        }
        return "New work"
    }

    private var headerSubtitle: String {
        guard let selectedWorkType else {
            return "MODO adapts the workspace so you only see tools that make sense for the job."
        }
        if selectedWorkType == .creativeProduction && selectedKind == nil {
            return "Start from a production preset or choose a flexible creative workspace."
        }
        return selectedWorkType.subtitle
    }

    private var workTypePicker: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(ModoWorkType.allCases) { type in
                Button {
                    selectedWorkType = type
                    selectedKind = type == .creativeProduction ? nil : fallbackKind(for: type)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: type.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(StudioTheme.icon)
                            .frame(width: 36, height: 36)
                            .background(StudioTheme.soft)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(type.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                            Text(type.subtitle)
                                .font(.system(size: 9.5))
                                .foregroundStyle(StudioTheme.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                    .background(StudioTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            }
        }
    }

    private func fallbackKind(for type: ModoWorkType) -> ProjectKind {
        switch type {
        case .creativeProduction: return .personal
        case .event: return .event
        case .service, .consulting: return .commercial
        case .flexible: return .personal
        }
    }

    private var kindPicker: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(presetKinds) { kind in
                presetKindButton(kind)
            }
            customKindButton
        }
    }

    private func presetKindButton(_ kind: ProjectKind) -> some View {
        Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(StudioTheme.icon)
                    .frame(width: 34, height: 34)
                    .background(StudioTheme.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                    Text(kind.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(StudioTheme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(StudioTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
    }

    private var customKindButton: some View {
        Button {
            selectedKind = .personal
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.icon)
                    .frame(width: 34, height: 34)
                    .background(StudioTheme.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Flexible creative")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start clean and decide which production pages you want later.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(StudioTheme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(StudioTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
    }

    private func projectSetup(_ kind: ProjectKind) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: (selectedWorkType ?? .flexible).icon)
                    Text((selectedWorkType ?? .flexible).rawValue)
                    Spacer()
                    Button("Change") {
                        selectedKind = nil
                        selectedWorkType = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.secondary)
                    .studioPointerCursor()
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(StudioTheme.tertiary)

                fieldLabel("WORK NAME")
                StudioDialogField {
                    TextField(workNamePlaceholder, text: $title)
                        .textFieldStyle(.plain)
                        .studioTextCursor()
                        .font(.system(size: 18, weight: .semibold))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(titleIsEmpty ? StudioTheme.red.opacity(0.48) : Color.clear, lineWidth: 1)
                )

                if titleIsEmpty {
                    Label("Give this work a name before creating it.", systemImage: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                }

                fieldLabel("CUSTOMER / LABEL")
                StudioDialogField {
                    TextField("Customer or personal label", text: $client)
                        .textFieldStyle(.plain)
                        .studioTextCursor()
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("HOURLY RATE")
                        StudioDialogField {
                            TextField("Default €\(Int(store.settings.defaultRate))/h", text: $hourlyRateText)
                                .textFieldStyle(.plain)
                                .studioTextCursor()
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("FIXED FEE / BUDGET")
                        StudioDialogField {
                            TextField("Optional", text: $fixedFeeText)
                                .textFieldStyle(.plain)
                                .studioTextCursor()
                        }
                    }
                }

                Spacer()

                HStack {
                    Button("Back") {
                        if selectedWorkType == .creativeProduction, selectedKind != nil {
                            selectedKind = nil
                        } else {
                            selectedKind = nil
                            selectedWorkType = nil
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Spacer()

                    Button("Create work") {
                        store.createProject(
                            title: title,
                            client: client,
                            kind: kind,
                            workType: selectedWorkType ?? .flexible,
                            symbol: nil,
                            bannerPath: bannerPath,
                            bannerAssetName: bannerAssetName,
                            hourlyRate: parsedMoney(hourlyRateText),
                            fixedFee: parsedMoney(fixedFeeText)
                        )
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(titleIsEmpty)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("COVER")
                ProjectBanner(
                    path: bannerPath,
                    assetName: bannerAssetName,
                    colorHex: "8A8A86",
                    height: 170,
                    fadeBottom: true
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(StudioTheme.border.opacity(0.65))
                )

                HStack(spacing: 8) {
                    Button("Choose image…") { chooseBanner() }
                        .buttonStyle(SecondaryButtonStyle())

                    if bannerPath != nil || bannerAssetName != nil {
                        Button("Use work color") {
                            bannerPath = nil
                            bannerAssetName = nil
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                Text("Leave the cover empty for a clean color treatment, or add an image that belongs to this work.")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 270)
        }
    }

    private var workNamePlaceholder: String {
        switch selectedWorkType ?? .flexible {
        case .creativeProduction: return "Name your production"
        case .service: return "Name the service job"
        case .consulting: return "Name the engagement"
        case .event: return "Name the event"
        case .flexible: return "Name this work"
        }
    }

    private func parsedMoney(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private var titleIsEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(StudioTheme.tertiary)
    }

    private func chooseBanner() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK,
           let url = panel.url,
           let managedPath = store.importManagedImageForWorkspace(from: url, category: "Project Banners") {
            bannerPath = managedPath
            bannerAssetName = nil
        }
    }
}

private struct SidebarTransferPanel: View {
    @EnvironmentObject private var store: FramoStudioStore
    let collapsed: Bool

    var body: some View {
        VStack(spacing: 7) {
            if collapsed {
                Button(action: openSharing) {
                    FramoMediaSVGReference(name: "sharepoint", tintHex: "A9A9A5")
                        .frame(width: 19, height: 19)
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
                .help("MODO Connect")
            } else {
                FramoReferenceSharingCard(
                    transfer: store.localTransfer,
                    onSharepoint: openSharing
                )
                .environmentObject(store)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func openSharing() {
        store.requestedSettingsPane = "Connect"
        store.openDestination(.settings)
    }
}

private extension View {
    func sidebarSectionTitle() -> some View {
        self.font(.system(size: 10, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
            .padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 5)
    }
}

private extension Text {
    func pickerLabel() -> some View {
        self.font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
    }
}

@MainActor
final class FramoFocusRuntime: ObservableObject {
    static let shared = FramoFocusRuntime()

    private weak var store: FramoStudioStore?
    private var timerCancellable: AnyCancellable?
    private var projectCancellable: AnyCancellable?
    private var tickTimer: Timer?

    private init() {}

    func install(store: FramoStudioStore) {
        guard self.store !== store else { refreshPreferences(); return }
        self.store = store
        timerCancellable = store.$activeTimerStartedAt.sink { [weak self] _ in
            Task { @MainActor in self?.refreshDockBadge() }
        }
        projectCancellable = store.$activeTimerProjectID.sink { [weak self] _ in
            Task { @MainActor in self?.refreshDockBadge() }
        }
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDockBadge() }
        }
        refreshPreferences()
    }

    func refreshPreferences() { refreshDockBadge() }

    private func refreshDockBadge() {
        guard let store, store.settings.effectiveDockTimerBadgeEnabled,
              store.activeTimerProjectID != nil else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        if store.activeTimerStartedAt == nil {
            NSApp.dockTile.badgeLabel = "Ⅱ"
            return
        }
        let seconds = max(0, Int(store.focusElapsedSeconds()))
        if seconds < 3600 { NSApp.dockTile.badgeLabel = "\(seconds / 60)m" }
        else { NSApp.dockTile.badgeLabel = String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60) }
    }
}

@MainActor
final class FramoAutoLockRuntime {
    static let shared = FramoAutoLockRuntime()

    private weak var store: FramoStudioStore?
    private var eventMonitor: Any?
    private var timer: Timer?
    private var lastActivity = Date()

    private init() {}

    func install(store: FramoStudioStore) {
        if self.store !== store {
            self.store = store
            lastActivity = .now
        }
        if eventMonitor == nil {
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged
            ]
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor in self?.recordActivity() }
                return event
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkLock() }
            }
        }
    }

    private func recordActivity() { lastActivity = .now }

    private func checkLock() {
        guard let store,
              !store.profileGatePresented,
              let profile = store.activeProfile,
              profile.isPasswordProtected else { return }
        let minutes = profile.effectiveAutoLockMinutes
        guard minutes > 0 else { return }
        if Date().timeIntervalSince(lastActivity) >= Double(minutes * 60) {
            store.lockActiveProfile()
            lastActivity = .now
        }
    }
}




struct FramoProfileGateView: View {
    @EnvironmentObject private var store: FramoStudioStore

    var introStyle: ModoLaunchStyle = .none

    @State private var selectedProfileID: UUID?
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showingCreator = false
    @State private var showingRecovery = false
    @State private var biometricAvailable = false
    @State private var biometricName = "Touch ID"

    // Intro states: one hero surface moves through all three shapes.
    @State private var introCardMode: Bool
    @State private var introBackdropVisible: Bool
    @State private var introCardVisible: Bool
    @State private var introExpanded: Bool
    @State private var wordmarkVisible: Bool
    @State private var photoSettled: Bool
    @State private var loginVisible: Bool

    @FocusState private var passwordFocused: Bool

    init(introStyle: ModoLaunchStyle = .none) {
        self.introStyle = introStyle
        let animateIntro = introStyle != .none
        _introCardMode = State(initialValue: animateIntro)
        _introBackdropVisible = State(initialValue: animateIntro)
        _introCardVisible = State(initialValue: !animateIntro)
        _introExpanded = State(initialValue: animateIntro)
        _wordmarkVisible = State(initialValue: !animateIntro)
        _photoSettled = State(initialValue: !animateIntro)
        _loginVisible = State(initialValue: !animateIntro)
    }

    private var timingScale: Double {
        introStyle == .condensed ? 0.34 : 1.0
    }

    private var selectedProfile: FramoWorkspaceProfile? {
        let id = selectedProfileID ?? store.activeProfileID
        return store.profiles.first(where: { $0.id == id })
    }

    var body: some View {
        GeometryReader { proxy in
            let cardSide = min(300, max(230, min(proxy.size.width, proxy.size.height) * 0.34))
            let heroHeight = min(270, max(205, proxy.size.height * 0.31))
            let finalVisualHeight = heroHeight + 36
            let loginTop = finalVisualHeight + 26

            let currentWidth: CGFloat = introCardMode
                ? cardSide
                : proxy.size.width

            let currentHeight: CGFloat = introCardMode
                ? cardSide
                : (introExpanded ? proxy.size.height : finalVisualHeight)

            let currentCenterY: CGFloat = introCardMode
                ? proxy.size.height * 0.50
                : (introExpanded ? proxy.size.height * 0.50 : finalVisualHeight * 0.50)

            ZStack {
                // For the first beat, MODO feels like a floating object over the
                // already-open app rather than a conventional opaque splash screen.
                StudioTheme.canvas
                    .opacity(introBackdropVisible ? 0 : 1)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(introBackdropVisible ? 1 : 0)
                    .ignoresSafeArea()

                Color.black
                    .opacity(introBackdropVisible ? 0.08 : 0)
                    .ignoresSafeArea()

                loginHero(
                    width: currentWidth,
                    height: currentHeight
                )
                .position(
                    x: proxy.size.width * 0.50,
                    y: currentCenterY
                )
                .scaleEffect(introCardVisible ? 1 : 0.86)
                .opacity(introCardVisible ? 1 : 0)
                .zIndex(2)

                loginContent
                    .frame(width: min(430, max(360, proxy.size.width - 64)))
                    .position(
                        x: proxy.size.width * 0.50,
                        y: loginTop + 170
                    )
                    .opacity(loginVisible ? 1 : 0)
                    .offset(y: loginVisible ? 0 : 8)
                    .allowsHitTesting(loginVisible)
                    .zIndex(3)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            selectedProfileID = store.activeProfileID ?? store.profiles.first?.id
            password = ""
            errorMessage = nil
            refreshBiometricAvailability()

            if introStyle != .none {
                runIntro()
            } else {
                introCardMode = false
                introBackdropVisible = false
                introCardVisible = true
                introExpanded = false
                wordmarkVisible = true
                photoSettled = true
                loginVisible = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    passwordFocused = selectedProfile?.isPasswordProtected == true
                }
            }
        }
        .sheet(isPresented: $showingCreator) {
            FramoProfileCreatorSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showingRecovery) {
            ModoRecoveryUnlockSheet(isPresented: $showingRecovery)
                .environmentObject(store)
        }
    }

    private func loginHero(
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            Image("unsplashimagesplashscreen")
                .resizable()
                .scaledToFill()
                .scaleEffect(photoSettled ? 1.0 : 1.085)

            Color.black.opacity(0.035)

            // The login gradient only appears once the floating square has become
            // the large hero. That keeps the opening object clean and graphic.
            VStack(spacing: 0) {
                Spacer()

                LinearGradient(
                    stops: [
                        .init(color: StudioTheme.canvas.opacity(0.0), location: 0.00),
                        .init(color: StudioTheme.canvas.opacity(0.05), location: 0.24),
                        .init(color: StudioTheme.canvas.opacity(0.22), location: 0.46),
                        .init(color: StudioTheme.canvas.opacity(0.58), location: 0.68),
                        .init(color: StudioTheme.canvas.opacity(0.94), location: 0.84),
                        .init(color: StudioTheme.canvas, location: 0.98),
                        .init(color: StudioTheme.canvas, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: introExpanded ? 190 : 128)
            }
            .opacity(introCardMode ? 0 : 1)
            .allowsHitTesting(false)

            Image("MODOLOGO")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(
                    width: introCardMode
                        ? 170
                        : (introExpanded ? 340 : 220)
                )
                .offset(y: (!introCardMode && !introExpanded) ? -10 : 0)
                .opacity(wordmarkVisible ? 1 : 0)
                .scaleEffect(wordmarkVisible ? 1 : 0.92)
                .mask {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 600, height: 280)
                        .rotationEffect(.degrees(-18))
                        .offset(
                            x: wordmarkVisible ? 0 : 390,
                            y: wordmarkVisible ? 0 : -190
                        )
                        .blur(radius: 10)
                }
        }
        .frame(width: width, height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: introCardMode ? 30 : 0,
                bottomLeadingRadius: introCardMode ? 30 : (introExpanded ? 0 : 20),
                bottomTrailingRadius: introCardMode ? 30 : (introExpanded ? 0 : 20),
                topTrailingRadius: introCardMode ? 30 : 0,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(introCardMode ? 0.34 : 0),
            radius: introCardMode ? 34 : 0,
            y: introCardMode ? 18 : 0
        )
        .ignoresSafeArea(edges: [.top, .horizontal])
        .animation(.spring(response: 0.81 * timingScale, dampingFraction: 0.86), value: introCardVisible)
        .animation(.easeInOut(duration: 1.20 * timingScale), value: introCardMode)
        .animation(.easeInOut(duration: 1.06 * timingScale), value: introExpanded)
        .animation(.easeOut(duration: 1.61 * timingScale), value: photoSettled)
    }

    private func runIntro() {
        introCardMode = true
        introBackdropVisible = true
        introCardVisible = false
        introExpanded = true
        wordmarkVisible = false
        photoSettled = false
        loginVisible = false

        withAnimation(.spring(response: 0.81 * timingScale, dampingFraction: 0.86)) {
            introCardVisible = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.98 * timingScale) {
            withAnimation(.easeInOut(duration: 1.20 * timingScale)) {
                introCardMode = false
            }
            withAnimation(.easeOut(duration: 1.61 * timingScale)) {
                photoSettled = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15 * timingScale) {
            withAnimation(.easeOut(duration: 0.73 * timingScale)) {
                wordmarkVisible = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.23 * timingScale) {
            withAnimation(.easeOut(duration: 0.70 * timingScale)) {
                introBackdropVisible = false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.18 * timingScale) {
            withAnimation(.easeInOut(duration: 1.06 * timingScale)) {
                introExpanded = false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.91 * timingScale) {
            withAnimation(.easeOut(duration: max(0.18, 0.42 * timingScale))) {
                loginVisible = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.22 * timingScale) {
            passwordFocused = selectedProfile?.isPasswordProtected == true
        }
    }

    @ViewBuilder
    private var loginContent: some View {
        if let profile = selectedProfile {
            VStack(spacing: 16) {
                profileDots
                    .padding(.bottom, 1)

                VStack(spacing: 5) {
                    Text("Welcome back")
                        .font(.system(size: 24, weight: .semibold))

                    Text(profile.name)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                        .animation(.easeOut(duration: 0.14), value: profile.id)
                }

                VStack(spacing: 11) {
                    if profile.isPasswordProtected {
                        SecureField("Workspace password", text: $password)
                            .textFieldStyle(.plain)
                            .studioTextCursor()
                            .focused($passwordFocused)
                            .padding(.horizontal, 13)
                            .frame(height: 44)
                            .background(StudioTheme.input)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .onSubmit { unlock(profile) }
                    }

                    Button {
                        unlock(profile)
                    } label: {
                        Text(profile.isPasswordProtected ? "Unlock MODO" : "Open MODO")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    if profile.isPasswordProtected && biometricAvailable {
                        Button {
                            unlockWithBiometrics(profile)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "touchid")
                                Text("Use \(biometricName)")
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    if profile.isPasswordProtected {
                        Button("Use recovery method") {
                            showingRecovery = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .studioPointerCursor()
                        .padding(.top, 1)
                    }

                    if let message = errorMessage ?? store.profileAccessError {
                        Text(message)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioTheme.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        showingCreator = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))

                            Text("New workspace")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(StudioTheme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(StudioTheme.soft.opacity(0.46))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()

                    Button("Open portable workspace") {
                        openPortableWorkspace()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(StudioTheme.tertiary)
                    .studioPointerCursor()
                }
                .padding(.top, 3)
            }
            .padding(.top, 0)
            .padding(.bottom, 42)
        }
    }

    private var profileDots: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.profiles) { profile in
                    let selected = profile.id == selectedProfileID

                    Button {
                        selectProfile(profile)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(selected ? StudioTheme.primary : StudioTheme.soft)
                                .frame(width: selected ? 31 : 28, height: selected ? 31 : 28)

                            Text(profileInitials(profile.name))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(selected ? StudioTheme.canvas : StudioTheme.secondary)
                        }
                        .overlay {
                            Circle()
                                .stroke(
                                    selected ? StudioTheme.primary.opacity(0.18) : StudioTheme.border.opacity(0.78),
                                    lineWidth: selected ? 3 : 1
                                )
                                .padding(selected ? -3 : 0)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                    .help(profile.name)
                    .accessibilityLabel(Text(profile.name))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(minWidth: 280, alignment: .center)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func profileInitials(_ name: String) -> String {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)

        let initials = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return initials.isEmpty ? "M" : initials
    }

    private func selectProfile(_ profile: FramoWorkspaceProfile) {
        errorMessage = nil
        store.profileAccessError = nil
        password = ""
        selectedProfileID = profile.id

        if store.activeProfileID != profile.id {
            store.switchProfile(to: profile.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            passwordFocused = profile.isPasswordProtected
        }
    }

    private func unlock(_ profile: FramoWorkspaceProfile) {
        if store.activeProfileID != profile.id {
            store.switchProfile(to: profile.id)
            guard store.activeProfileID == profile.id else {
                errorMessage = store.profileAccessError ?? "That workspace is unavailable."
                return
            }
        }

        if profile.isPasswordProtected {
            if store.unlockActiveProfile(password: password) {
                errorMessage = nil
                password = ""
            } else {
                errorMessage = "That password is incorrect."
            }
        } else {
            store.openActiveProfile()
        }
    }

    private func refreshBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        biometricAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometricName = context.biometryType == .touchID ? "Touch ID" : "biometrics"
    }

    private func unlockWithBiometrics(_ profile: FramoWorkspaceProfile) {
        if store.activeProfileID != profile.id {
            store.switchProfile(to: profile.id)
            guard store.activeProfileID == profile.id else {
                errorMessage = store.profileAccessError ?? "That workspace is unavailable."
                return
            }
        }

        let context = LAContext()
        context.localizedCancelTitle = "Use password"
        var evaluationError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evaluationError) else {
            errorMessage = "Biometric unlock is not available on this Mac."
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock \(profile.name) in MODO"
        ) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.errorMessage = nil
                    self.password = ""
                    self.store.unlockActiveProfileUsingDeviceAuthentication()
                } else if let error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openPortableWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open portable MODO workspace"
        panel.prompt = "Open Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK,
           let url = panel.url,
           let id = store.registerPortableProfile(at: url) {
            selectedProfileID = id
            password = ""
            errorMessage = nil
            store.profileAccessError = nil
        }
    }
}

private struct ModoRecoveryUnlockSheet: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var isPresented: Bool
    @State private var method: RecoveryMethod = .authenticator
    @State private var value = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private enum RecoveryMethod: String, CaseIterable, Identifiable {
        case authenticator = "Authenticator"
        case backupCode = "Backup code"
        var id: String { rawValue }
    }

    private var availableMethods: [RecoveryMethod] {
        var methods: [RecoveryMethod] = []
        if store.activeProfileHasAuthenticator { methods.append(.authenticator) }
        if store.activeProfileHasRecoveryCodes { methods.append(.backupCode) }
        return methods
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recover access")
                        .font(.system(size: 18, weight: .semibold))
                    Text(store.activeProfileName)
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.tertiary)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
            }

            if availableMethods.isEmpty {
                Text("No recovery method was set up for this workspace.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Recovery codes or Authenticator must be configured beforehand in Settings → Workspaces & Security.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(StudioTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: $method) {
                    ForEach(availableMethods) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField(
                    method == .authenticator ? "6-digit code" : "XXXX-XXXX",
                    text: $value
                )
                .textFieldStyle(.plain)
                .studioTextCursor()
                .focused($fieldFocused)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { unlock() }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.red)
                }

                Button("Unlock") {
                    unlock()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 390)
        .background(StudioTheme.canvas)
        .onAppear {
            if !availableMethods.contains(method), let first = availableMethods.first {
                method = first
            }
            fieldFocused = !availableMethods.isEmpty
        }
        .onChange(of: method) { _, _ in
            value = ""
            errorMessage = nil
            fieldFocused = true
        }
    }

    private func unlock() {
        let success: Bool
        switch method {
        case .authenticator:
            success = store.unlockActiveProfile(authenticatorCode: value)
        case .backupCode:
            success = store.unlockActiveProfile(recoveryCode: value)
        }

        if success {
            value = ""
            errorMessage = nil
            isPresented = false
        } else {
            errorMessage = method == .authenticator
                ? "That Authenticator code is not valid."
                : "That backup code is not valid or has already been used."
        }
    }
}

struct ModoRecoveryKitSheet: View {
    let kit: ModoRecoveryKit
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save your recovery access")
                    .font(.system(size: 20, weight: .semibold))
                Text("Keep these somewhere safe before closing this window.")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("AUTHENTICATOR")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)

                Text("Add a new account in your authenticator app and enter this setup key.")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.secondary)

                HStack(spacing: 8) {
                    Text(kit.authenticatorSecret)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)

                    Spacer()

                    Button("Copy key") {
                        copy(kit.authenticatorSecret)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Copy link") {
                        copy(kit.authenticatorURL)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(10)
                .background(StudioTheme.soft.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BACKUP CODES")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StudioTheme.tertiary)
                    Spacer()
                    Button("Copy all") {
                        copy(kit.backupCodes.joined(separator: "\n"))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(kit.backupCodes, id: \.self) { code in
                        Text(code)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(StudioTheme.soft.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Text("Each backup code works once. Authenticator recovery is tied to this Mac's Keychain.")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
            }

            HStack {
                Spacer()
                Button("Done") {
                    onDone?()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(StudioTheme.canvas)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct FramoProfileCreatorSheet: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var storage: FramoProfileStorageKind = .local
    @State private var portableFolder: URL?
    @State private var errorMessage: String?
    @State private var recoveryKit: ModoRecoveryKit?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New workspace")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Create an isolated MODO workspace on this Mac or on a removable drive.")
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.tertiary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(height: 36)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Storage").font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                HStack(spacing: 5) {
                    ForEach(FramoProfileStorageKind.allCases) { item in
                        Button {
                            storage = item
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: item == .portable ? "externaldrive" : "internaldrive")
                                Text(item.rawValue)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(storage == item ? StudioTheme.primary : StudioTheme.secondary)
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(storage == item ? StudioTheme.selected : StudioTheme.soft.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    }
                }
                if storage == .portable {
                    Button {
                        choosePortableFolder()
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(portableFolder?.path ?? "Choose an empty folder or external drive…")
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Workspace password").font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain).padding(.horizontal, 11).frame(height: 36)
                    .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                SecureField("Confirm password", text: $confirmPassword)
                    .textFieldStyle(.plain).padding(.horizontal, 11).frame(height: 36)
                    .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("Required for new workspaces. On supported Macs you can unlock with Touch ID after setup. This app lock does not encrypt the workspace folder itself.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }

            if let errorMessage {
                Text(errorMessage).font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.red)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Create workspace") { createWorkspace() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(StudioTheme.canvas)
        .sheet(item: $recoveryKit) { kit in
            ModoRecoveryKitSheet(kit: kit) {
                recoveryKit = nil
                dismiss()
            }
        }
    }

    private func choosePortableFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose portable workspace folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { portableFolder = panel.url }
    }

    private func createWorkspace() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { errorMessage = "Give the workspace a name."; return }
        guard password.count >= 6 else { errorMessage = "Use a workspace password of at least 6 characters."; return }
        guard password == confirmPassword else { errorMessage = "The passwords do not match."; return }

        let id: UUID?
        switch storage {
        case .local:
            id = store.createLocalProfile(name: clean, password: password)
        case .portable:
            guard let portableFolder else { errorMessage = "Choose a folder for the portable workspace."; return }
            id = store.createPortableProfile(name: clean, password: password, at: portableFolder)
        }
        guard id != nil else {
            errorMessage = store.pluginNotice ?? "MODO couldn't create the workspace."
            return
        }
        _ = store.unlockActiveProfile(password: password)
        if let kit = store.regenerateActiveProfileRecoveryKit() {
            recoveryKit = kit
        } else {
            dismiss()
        }
    }
}

struct FramoFloatingSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}

struct FramoFloatingButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(width: 30, height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (selected ? 0.08 : 0)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FramoTimeLauncher: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var query = ""
    @State private var appeared = false
    @FocusState private var searchFocused: Bool

    private var filteredProjects: [StudioProject] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(store.projects.prefix(7)) }
        return Array(store.projects.filter {
            $0.title.localizedCaseInsensitiveContains(needle) ||
            $0.client.localizedCaseInsensitiveContains(needle)
        }.prefix(8))
    }

    private var activeProject: StudioProject? {
        guard let id = store.activeTimerProjectID else { return nil }
        return store.projects.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let activeProject {
                activeTimer(activeProject)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            searchField
                .padding(.top, activeProject == nil ? 2 : 12)

            projectList

            footer
        }
        .frame(width: 354)
        .background(.regularMaterial)
        .background(StudioTheme.canvas.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.26), radius: 30, y: 14)
        .scaleEffect(appeared ? 1 : 0.965)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .animation(.spring(response: 0.30, dampingFraction: 0.86), value: appeared)
        .animation(.easeInOut(duration: 0.18), value: store.activeTimerProjectID)
        .onAppear {
            searchFocused = true
            withAnimation { appeared = true }
        }
        .onExitCommand {
            withAnimation(.easeIn(duration: 0.12)) { appeared = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                store.showTimeLauncher = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StudioLogoMark(size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("MODO Time")
                    .font(.system(size: 13, weight: .semibold))
                Text(activeProject == nil ? "Start tracking in seconds" : "Tracking now")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            Spacer()
            Text("⌥⌘F")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.tertiary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(StudioTheme.soft.opacity(0.62), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Button {
                withAnimation(.easeIn(duration: 0.12)) { appeared = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                    store.showTimeLauncher = false
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private func activeTimer(_ project: StudioProject) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(hex: project.colorHex).opacity(0.22))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(store.activeTimerStartedAt == nil ? StudioTheme.tertiary : Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(store.activeTimerStartedAt == nil ? 1 : pulseScale(for: context.date))
                        .opacity(store.activeTimerStartedAt == nil ? 0.55 : pulseOpacity(for: context.date))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(duration(store.focusElapsedSeconds(now: context.date)))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioTheme.primary)
                        .contentTransition(.numericText())
                }

                Spacer()

                Button {
                    if store.activeTimerStartedAt == nil { store.startTimer(for: project.id) }
                    else { store.pauseTimer() }
                } label: {
                    Image(systemName: store.activeTimerStartedAt == nil ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())

                Button {
                    withAnimation(.easeOut(duration: 0.16)) { store.stopTimer() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
            }
            .padding(11)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.055), lineWidth: 0.6)
            }
            .padding(.horizontal, 12)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioTheme.tertiary)
            TextField("Find work", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .focused($searchFocused)
                .studioTextCursor()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(StudioTheme.input.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredProjects) { project in
                    ModoTimeProjectRow(
                        project: project,
                        isActive: store.activeTimerProjectID == project.id
                    ) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            store.startTimer(for: project.id)
                        }
                        closeAfterSelection()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 236)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Create & track") {
                    let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.createProject(title: title, client: "")
                    if let id = store.selectedProjectID { store.startTimer(for: id) }
                    closeAfterSelection()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            Button {
                store.showTimeLauncher = false
                store.requestProjectCreation()
            } label: {
                Label("New work", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func closeAfterSelection() {
        withAnimation(.easeIn(duration: 0.11)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            store.showTimeLauncher = false
        }
    }

    private func pulseScale(for date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8)
        return phase < 0.45 ? 1.18 : 1
    }

    private func pulseOpacity(for date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8)
        return phase < 0.45 ? 1 : 0.62
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ModoTimeProjectRow: View {
    let project: StudioProject
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color(hex: project.colorHex))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    if !project.client.isEmpty {
                        Text(project.client)
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioTheme.secondary)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioTheme.tertiary)
                        .opacity(hovering ? 1 : 0.55)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .background((isActive ? StudioTheme.selected : StudioTheme.soft).opacity(isActive ? 0.78 : (hovering ? 0.52 : 0)))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.004 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .studioPointerCursor()
    }
}

private struct FramoNotificationCenter: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var unreadOnly = false
    private var ink: Color { StudioTheme.primary }
    private var muted: Color { StudioTheme.tertiary }

    private var items: [FramoNotificationItem] {
        let all = store.visibleNotifications
        return unreadOnly ? all.filter { !$0.isRead } : all
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty { emptyState }
                    ForEach(items) { item in
                        FramoNotificationRow(item: item,
                            onOpen: { store.openNotification(item) },
                            onAction: { store.openNotification(item, completeTask: item.kind == .task) },
                            onDismiss: { store.dismissNotification(item.id) })
                    }
                }
                .padding(.top, 4).padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
        .background(StudioTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .foregroundStyle(ink)
        .onExitCommand { store.showNotificationCenter = false }
    }

    private var header: some View {
        HStack {
            Text("Notifications").font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                store.showNotificationCenter = false
                store.requestedSettingsPane = "Notifications"
                store.openDestination(.settings)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(muted).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).help("Notification settings")
            .accessibilityLabel("Notification settings")
        }
        .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 13)
    }

    private var tabs: some View {
        HStack(alignment: .top, spacing: 20) {
            tab("All", unread: false)
            tab("Unread", unread: true)
            Spacer(minLength: 6)
            Button("Mark all as read") { store.markAllNotificationsRead() }
                .font(.system(size: 10)).foregroundStyle(muted)
                .buttonStyle(.plain).padding(.top, 2)
                .disabled(store.unreadNotificationCount == 0)
        }
        .padding(.horizontal, 18)
    }

    private func tab(_ title: String, unread: Bool) -> some View {
        Button { unreadOnly = unread } label: {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(unreadOnly == unread ? ink : muted)
                    if unread && store.unreadNotificationCount > 0 {
                        Text(String(store.unreadNotificationCount))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                            .background(StudioTheme.soft, in: Capsule())
                    }
                }
                .frame(height: 20)
                Rectangle().fill(unreadOnly == unread ? ink : Color.clear)
                    .frame(width: 20, height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + " notifications")
        .accessibilityAddTraits(unreadOnly == unread ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell").font(.system(size: 24, weight: .light)).foregroundStyle(muted)
            Text(unreadOnly ? "You’re all caught up" : "No notifications yet")
                .font(.system(size: 14, weight: .medium))
            Text(unreadOnly ? "There are no unread notifications." : "Task reminders, upcoming shoots and app messages appear here.")
                .font(.system(size: 12)).foregroundStyle(muted)
                .multilineTextAlignment(.center).frame(maxWidth: 270)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 58)
    }
}

private struct FramoNotificationRow: View {
    let item: FramoNotificationItem
    let onOpen: () -> Void
    let onAction: () -> Void
    let onDismiss: () -> Void
    private var ink: Color { StudioTheme.primary }
    private var muted: Color { StudioTheme.tertiary }

    private var symbol: String {
        switch item.kind {
        case .task: item.detail == "Overdue" ? "exclamationmark.triangle.fill" : "checklist"
        case .event: "calendar"
        case .information: "checkmark"
        }
    }

    private var actionTitle: String? {
        switch item.kind {
        case .task: "Mark complete"
        case .event: "View schedule"
        case .information: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                title
                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 9)).foregroundStyle(muted).padding(.top, 3)
                if let detail = item.detail, !detail.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "clock").font(.system(size: 9))
                        Text(detail).font(.system(size: 10))
                    }
                    .foregroundStyle(muted).padding(.top, 10)
                }
                HStack(spacing: 8) {
                    if let actionTitle {
                        Button(actionTitle, action: onAction)
                            .buttonStyle(FramoNotificationActionStyle(primary: item.kind == .task))
                    }
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(FramoNotificationActionStyle())
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    @ViewBuilder private var title: some View {
        if item.kind == .information {
            Text(item.title).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        } else {
            Button(action: onOpen) {
                Text(item.title).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                    .lineSpacing(3).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain).help("View details")
        }
    }

    private var icon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.kind == .task && item.detail != "Overdue" ? StudioTheme.green : StudioTheme.secondary)
                .frame(width: 30, height: 30)
                .background(StudioTheme.soft, in: RoundedRectangle(cornerRadius: 8))
            if !item.isRead {
                Circle().fill(Color(hex: "18A774")).frame(width: 7, height: 7).offset(x: 2, y: -2)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FramoNotificationActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(primary ? StudioTheme.onPrimary : StudioTheme.primary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(primary ? StudioTheme.primary : StudioTheme.soft,
                in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

