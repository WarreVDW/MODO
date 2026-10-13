import SwiftUI
import AppKit
import UniformTypeIdentifiers



// MARK: - Project Symbol Picker

private struct StudioEmoji: View {
    let symbol: String
    var size: CGFloat = 24

    var body: some View {
        Group {
            if !symbol.isEmpty,
               NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(StudioTheme.icon)
            } else {
                Text(symbol.isEmpty ? "🎬" : symbol)
                    .font(.system(size: size))
            }
        }
        .accessibilityLabel(Text(symbol.isEmpty ? "Project symbol" : symbol))
    }
}

private struct EmojiPicker: View {
    @Binding var selection: String

    private let symbols: [String] = [
        "film",
        "video",
        "camera",
        "photo",
        "play.rectangle",
        "rectangle.stack",
        "rectangle.portrait",
        "sparkles",
        "music.note",
        "waveform",
        "mic",
        "headphones",
        "calendar",
        "clock",
        "location",
        "mappin",
        "person.2",
        "briefcase",
        "square.grid.2x2",
        "square.stack.3d.up",
        "folder",
        "doc",
        "checkmark.circle",
        "star",
        "bolt",
        "flame",
        "heart",
        "globe",
        "airplane",
        "car"
    ]

    private let columns = Array(
        repeating: GridItem(.fixed(36), spacing: 6),
        count: 6
    )

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        selection = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(
                                selection == symbol
                                    ? StudioTheme.primary
                                    : StudioTheme.secondary
                            )
                            .frame(width: 36, height: 36)
                            .background(
                                selection == symbol
                                    ? StudioTheme.selected
                                    : Color.clear
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 8,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                }
            }
            .padding(10)
        }
        .frame(width: 270, height: 220)
    }
}

private extension ProjectStatus {
    var displayName: String { rawValue }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var store: FramoStudioStore
    let projectID: UUID
    @State private var draft: StudioProject?
    @State private var showDeleteConfirmation = false
    @State private var projectSaveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let project = Binding($draft) {
                VStack(spacing: 0) {
                    ProjectHeader(project: project)
                    ProjectTabBar(project: project, section: sectionBinding, showDeleteConfirmation: $showDeleteConfirmation)
                    sectionContent(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onChange(of: project.wrappedValue) { _, value in
                    queueProjectSave(value)
                }
            } else {
                EmptyState(icon: "folder.badge.questionmark", title: "Project not found", message: "This project may have been removed.")
            }
        }
        .onAppear { loadProject(projectID) }
        .onDisappear { flushProjectSave() }
        .onChange(of: projectID) { _, id in loadProject(id) }
        .onChange(of: store.projects.first(where: { $0.id == projectID })?.enabledSections) { _, sections in
            if draft?.enabledSections != sections { draft?.enabledSections = sections }
        }
        .onChange(of: store.projects.first(where: { $0.id == projectID })?.linkedFiles) { _, files in
            if draft?.linkedFiles != files { draft?.linkedFiles = files }
        }
        .onChange(of: store.projectRefreshToken) { _, _ in
            projectSaveTask?.cancel()
            loadProject(projectID)
        }
        .confirmationDialog("Delete this project?", isPresented: $showDeleteConfirmation) {
            Button("Delete project", role: .destructive) {
                store.deleteProject(projectID)
                store.openDestination(.projects)
            }
        } message: {
            Text("This removes the project from the local workspace.")
        }
    }

    private func queueProjectSave(_ value: StudioProject) {
        projectSaveTask?.cancel()
        projectSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            store.updateProject(value)
        }
    }

    private func flushProjectSave() {
        projectSaveTask?.cancel()
        if let draft { store.updateProject(draft) }
    }

    private func loadProject(_ id: UUID) {
        draft = store.projects.first(where: { $0.id == id })
        if let draft {
            let selected = store.selectedSection(for: id)
            let sectionAvailable = draft.effectiveSections.contains(selected) &&
                (selected != .tasks || store.isDestinationEnabled(.tasks))
            if !sectionAvailable { store.setSelectedSection(.overview, for: id) }
        }
    }

    private var sectionBinding: Binding<ProjectSection> {
        Binding(
            get: { store.selectedSection(for: projectID) },
            set: { store.setSelectedSection($0, for: projectID) }
        )
    }

    @ViewBuilder private func sectionContent(_ project: Binding<StudioProject>) -> some View {
        switch store.selectedSection(for: projectID) {
        case .overview: ProjectOverview(project: project)
        case .tasks:
            if store.settings.isDestinationEnabled(.tasks) {
                ProjectTasksView(projectID: project.wrappedValue.id)
            } else {
                EmptyState(icon: "checklist", title: "Tasks are hidden", message: "Enable Tasks in Settings → Workspace to use task planning here.")
            }
        case .brief:
            LongformEditor(
                title: "Creative brief",
                subtitle: "Build the objective, audience and creative direction in one editable document.",
                text: project.brief,
                richData: project.briefRTF
            )
        case .script:
            LongformEditor(
                title: "Script",
                subtitle: "Write dialogue, interview structure, VO and scene notes without leaving MODO.",
                text: project.script,
                richData: project.scriptRTF,
                monospaced: true
            )
        case .storyboard: StoryboardView(project: project)
        case .shots: ShotListView(project: project)
        case .schedule: ProjectScheduleView(project: project)
        case .crew: PeopleView(project: project)
        case .kit: KitView(project: project)
        case .files: FilesView(project: project, syncthing: store.syncthing)
        case .delivery: DeliveryView(project: project)
        case .time: TimeLogView(project: project)
        }
    }
}

private enum ProjectNavGroup: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tasks = "Tasks"
    case writing = "Writing"
    case visuals = "Visuals"
    case production = "Production"
    case delivery = "Delivery"

    var id: String { rawValue }

    var sections: [ProjectSection] {
        switch self {
        case .overview: [.overview]
        case .tasks: [.tasks]
        case .writing: [.brief, .script]
        case .visuals: [.storyboard, .shots]
        case .production: [.schedule, .crew, .kit, .files]
        case .delivery: [.delivery, .time]
        }
    }
}

private struct ProjectTabBar: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject
    @Binding var section: ProjectSection
    @Binding var showDeleteConfirmation: Bool
    @State private var hoveredGroup: ProjectNavGroup?
    @State private var hoveringGroupMenu: ProjectNavGroup?
    @State private var showingStatusOptions = false
    @State private var showingCompactSections = false
    @State private var hoverCloseGeneration = 0

    private var visibleSections: [ProjectSection] {
        project.effectiveSections.filter { section in
            section != .tasks || store.settings.isDestinationEnabled(.tasks)
        }
    }

    private var availableGroups: [ProjectNavGroup] {
        ProjectNavGroup.allCases.filter { group in
            group.sections.contains { visibleSections.contains($0) }
        }
    }


    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 1120 {
                compactBar
            } else {
                regularBar
            }
        }
        .frame(height: 52)
        .background(StudioTheme.canvas)
        .zIndex(200)
    }

    private var regularBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(availableGroups) { group in
                    navigationControl(group)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)

            actionCluster(compact: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Button {
                showingCompactSections.toggle()
            } label: {
                Text(section.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(StudioTheme.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(StudioTheme.soft)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .studioPointerCursor()
            .fixedSize()
            .gesture(sectionSwipeGesture)
            .onHover { inside in
                if inside {
                    hoverCloseGeneration += 1
                    showingCompactSections = true
                } else {
                    scheduleCompactHoverClose()
                }
            }
            .overlay(alignment: .topLeading) {
                if showingCompactSections {
                    compactSectionMenu
                        .offset(y: -CGFloat(project.effectiveSections.count * 30 + 18))
                        .onHover { inside in
                            if inside {
                                hoverCloseGeneration += 1
                                showingCompactSections = true
                            } else {
                                scheduleCompactHoverClose()
                            }
                        }
                }
            }
            .zIndex(showingCompactSections ? 60 : 0)

            Spacer(minLength: 2)
            actionCluster(compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var compactSectionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleSections) { item in
                Button {
                    section = item
                    showingCompactSections = false
                } label: {
                    HStack(spacing: 8) {
                        Text(sectionDisplayName(item))
                            .font(.system(size: 11, weight: section == item ? .semibold : .medium))
                        Spacer(minLength: 10)
                        if section == item {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(minWidth: 170, alignment: .leading)
                    .background(section == item ? StudioTheme.selected.opacity(0.65) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            }
        }
        .padding(6)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func scheduleCompactHoverClose() {
        hoverCloseGeneration += 1
        let generation = hoverCloseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
            guard generation == hoverCloseGeneration else { return }
            showingCompactSections = false
        }
    }

    @ViewBuilder
    private func navigationControl(_ group: ProjectNavGroup) -> some View {
        let enabled = group.sections.filter { visibleSections.contains($0) }
        let active = group.sections.contains(section)
        let hasSubmenu = enabled.count > 1
        let menuVisible = hasSubmenu && (hoveredGroup == group || hoveringGroupMenu == group)

        Button {
            selectPrimarySection(for: group)
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(group.rawValue)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? StudioTheme.primary : StudioTheme.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Capsule()
                    .fill(active ? StudioTheme.primary : Color.clear)
                    .frame(width: active ? 22 : 0, height: 2)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
        .onHover { inside in
            guard hasSubmenu else { return }
            if inside {
                hoverCloseGeneration += 1
                hoveredGroup = group
            } else {
                scheduleGroupHoverClose(group)
            }
        }
        .overlay(alignment: .bottom) {
            if menuVisible {
                hoverMenu(for: group, enabled: enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .offset(y: -44)
                    .onHover { inside in
                        if inside {
                            hoverCloseGeneration += 1
                            hoveringGroupMenu = group
                            hoveredGroup = group
                        } else {
                            hoveringGroupMenu = nil
                            scheduleGroupHoverClose(group)
                        }
                    }
                    .zIndex(500)
            }
        }
        .zIndex(menuVisible ? 500 : 0)
    }

    private func hoverMenu(for group: ProjectNavGroup, enabled: [ProjectSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(enabled) { item in
                Button {
                    section = item
                    hoveredGroup = nil
                    hoveringGroupMenu = nil
                } label: {
                    HStack(spacing: 8) {
                        Text(sectionDisplayName(item))
                            .font(.system(size: 11, weight: section == item ? .semibold : .medium))
                        Spacer(minLength: 10)
                        if section == item {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(minWidth: 142, alignment: .leading)
                    .background(section == item ? StudioTheme.selected.opacity(0.65) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            }
        }
        .padding(6)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func scheduleGroupHoverClose(_ group: ProjectNavGroup) {
        hoverCloseGeneration += 1
        let generation = hoverCloseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
            guard generation == hoverCloseGeneration else { return }
            if hoveringGroupMenu != group && hoveredGroup == group {
                hoveredGroup = nil
            }
        }
    }

    private func navLabel(_ title: String, active: Bool, showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
            if showsChevron { AssetIcon(name: "updown", fallback: "chevron.up.chevron.down", size: 9, color: active ? StudioTheme.primary : StudioTheme.secondary) }
        }
        .font(.system(size: 11, weight: active ? .semibold : .medium))
        .foregroundStyle(active ? StudioTheme.primary : StudioTheme.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private var sectionSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) > 20 else { return }
                let sections = project.effectiveSections
                guard let current = sections.firstIndex(of: section) else { return }
                if horizontal < 0, current < sections.index(before: sections.endIndex) {
                    section = sections[sections.index(after: current)]
                } else if horizontal > 0, current > sections.startIndex {
                    section = sections[sections.index(before: current)]
                }
            }
    }

    private func actionCluster(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            statusPicker(width: compact ? 110 : 210)
            Button {
                section = .files
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 34, height: 32)
                    .background(section == .files ? StudioTheme.selected : StudioTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).studioPointerCursor().help("Project files")
            timerButton(showLabel: !compact)
            Rectangle().fill(StudioTheme.border).frame(width: 1, height: compact ? 26 : 34)
            settingsMenu
        }
        .padding(.horizontal, compact ? 8 : 12)
        .frame(height: compact ? 40 : 48)
        .background(RoundedRectangle(cornerRadius: compact ? 12 : 14).fill(StudioTheme.soft))
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14).stroke(StudioTheme.border, lineWidth: 1))
        .fixedSize()
    }

    private func statusPicker(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text(project.status.displayName(for: project.effectiveWorkType))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(StudioTheme.primary)
        .padding(.horizontal, width > 150 ? 16 : 11)
        .frame(width: width, height: width > 150 ? 36 : 30)
        .background(StudioTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: width > 150 ? 11 : 10))
        .onHover { inside in
            if inside {
                hoverCloseGeneration += 1
                showingStatusOptions = true
            } else {
                scheduleStatusHoverClose()
            }
        }
        .overlay(alignment: .topLeading) {
            if showingStatusOptions {
                statusHoverMenu(width: width)
                    .offset(y: -CGFloat(ProjectStatus.allCases.count * 30 + 18))
                    .onHover { inside in
                        if inside {
                            hoverCloseGeneration += 1
                            showingStatusOptions = true
                        } else {
                            scheduleStatusHoverClose()
                        }
                    }
            }
        }
        .zIndex(showingStatusOptions ? 50 : 0)
    }

    private func statusHoverMenu(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ProjectStatus.allCases, id: \.self) { item in
                Button {
                    project.status = item
                    showingStatusOptions = false
                } label: {
                    HStack(spacing: 8) {
                        Text(item.displayName(for: project.effectiveWorkType))
                            .font(.system(size: 11, weight: project.status == item ? .semibold : .medium))
                        Spacer(minLength: 10)
                        if project.status == item {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(minWidth: max(width, 160), alignment: .leading)
                    .background(project.status == item ? StudioTheme.selected.opacity(0.65) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            }
        }
        .padding(6)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func scheduleStatusHoverClose() {
        hoverCloseGeneration += 1
        let generation = hoverCloseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
            guard generation == hoverCloseGeneration else { return }
            showingStatusOptions = false
        }
    }

    private func timerButton(showLabel: Bool) -> some View {
        let timerRunning = store.activeTimerProjectID != nil
        let thisProjectRunning = store.activeTimerProjectID == project.id
        return Button {
            if timerRunning { store.stopTimer() }
            else { store.startTimer(for: project.id) }
        } label: {
            Group {
                if showLabel {
                    HStack(spacing: 6) {
                        if timerRunning { Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold)) }
                        Text(timerRunning ? (thisProjectRunning ? "Stop timer" : "Stop active timer") : "Start timer")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(minWidth: 150)
                } else {
                    Image(systemName: timerRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 22)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .help(timerRunning ? "Stop the active timer" : "Start timer for this project")
    }

    private var settingsMenu: some View {
        Menu {
            Section("Layout") {
                ForEach(ProjectSection.allCases) { item in
                    if item == .overview {
                        Button { } label: { Label("Overview", systemImage: "checkmark") }.disabled(true)
                    } else if item == .tasks && !store.isDestinationEnabled(.tasks) {
                        EmptyView()
                    } else {
                        Button { toggle(item) } label: {
                            if project.effectiveSections.contains(item) { Label(sectionDisplayName(item), systemImage: "checkmark") }
                            else { Text(sectionDisplayName(item)) }
                        }
                    }
                }
            }
            Divider()
            Button(store.isProjectPinnedToSidebar(project.id) ? "Remove from sidebar" : "Pin project to sidebar") {
                if store.isProjectPinnedToSidebar(project.id) { store.unpinProjectFromSidebar(project.id) }
                else { store.pinProjectToSidebar(project.id) }
            }
            Menu("Open Duo with…") {
                ForEach(store.projects.filter { $0.id != project.id }) { other in
                    Button(other.title) { store.openInDuo(other.id) }
                }
            }
            if !store.localTransfer.connectedPeers.isEmpty {
                Menu("Send workspace to…") {
                    ForEach(store.localTransfer.connectedPeers, id: \.self) { peer in
                        Button(peer.displayName) { store.sendWorkspace(to: peer) }
                    }
                }
            }
            let pluginActions = store.pluginActions(target: .project)
            if !pluginActions.isEmpty {
                Menu("Plugins") {
                    ForEach(pluginActions) { registered in
                        Button(registered.action.label) { store.runPluginAction(registered, projectID: project.id) }
                    }
                }
            }
            Divider()
            Button("Project settings") { store.openDestination(.settings) }
            Button("Delete project", role: .destructive) { showDeleteConfirmation = true }
        } label: {
            AssetIcon(name: "arrange", fallback: "slider.horizontal.3", size: 18, color: StudioTheme.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .studioPointerCursor()
        .frame(width: 36)
        .help("Project layout and actions")
    }

    private func sectionDisplayName(_ item: ProjectSection) -> String {
        switch project.effectiveWorkType {
        case .creativeProduction:
            return item.displayName

        case .service:
            switch item {
            case .overview: return "Overview"
            case .tasks: return "Tasks"
            case .brief: return "Scope"
            case .script: return "Notes"
            case .storyboard: return "Plan"
            case .shots: return "Checklist"
            case .schedule: return "Appointments"
            case .crew: return "People"
            case .kit: return "Materials"
            case .files: return "Files"
            case .delivery: return "Handover"
            case .time: return "Time"
            }

        case .consulting:
            switch item {
            case .overview: return "Overview"
            case .tasks: return "Tasks"
            case .brief: return "Scope"
            case .script: return "Notes"
            case .storyboard: return "Plan"
            case .shots: return "Checklist"
            case .schedule: return "Meetings"
            case .crew: return "People"
            case .kit: return "Resources"
            case .files: return "Files"
            case .delivery: return "Deliverables"
            case .time: return "Time"
            }

        case .event:
            switch item {
            case .overview: return "Overview"
            case .tasks: return "Tasks"
            case .brief: return "Event brief"
            case .script: return "Notes"
            case .storyboard: return "Plan"
            case .shots: return "Checklist"
            case .schedule: return "Run of show"
            case .crew: return "People"
            case .kit: return "Equipment"
            case .files: return "Files"
            case .delivery: return "Follow-up"
            case .time: return "Time"
            }

        case .flexible:
            switch item {
            case .overview: return "Overview"
            case .tasks: return "Tasks"
            case .brief: return "Notes"
            case .script: return "Writing"
            case .storyboard: return "Plan"
            case .shots: return "Checklist"
            case .schedule: return "Schedule"
            case .crew: return "People"
            case .kit: return "Resources"
            case .files: return "Files"
            case .delivery: return "Deliverables"
            case .time: return "Time"
            }
        }
    }

    private func selectPrimarySection(for group: ProjectNavGroup) {
        let enabled = group.sections.filter { visibleSections.contains($0) }
        if enabled.contains(section) { return }
        section = enabled.first ?? .overview
    }

    private func toggle(_ item: ProjectSection) {
        let enabled = project.effectiveSections.contains(item)
        store.setProjectSectionEnabled(projectID: project.id, section: item, enabled: !enabled)
        if let updated = store.projects.first(where: { $0.id == project.id }) { project.enabledSections = updated.enabledSections }
        if enabled && section == item { section = .overview }
    }
}

private struct ProjectHeader: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject
    @State private var showingEmojiPicker = false
    @State private var showingCoverControls = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                ProjectBanner(
                    path: project.bannerPath,
                    assetName: project.bannerAssetName ?? StudioBannerDefaults.assetName(for: project.id),
                    colorHex: project.colorHex,
                    height: project.effectiveBannerHeight,
                    focusY: project.effectiveBannerFocusY,
                    fadeBottom: true
                )
                Button { showingCoverControls.toggle() } label: {
                    Label("Cover", systemImage: "photo")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.58)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).studioPointerCursor().padding(12)
                .popover(isPresented: $showingCoverControls) { BannerControls(project: $project) }
            }

            HStack(spacing: 13) {
                Button { showingEmojiPicker.toggle() } label: {
                    StudioEmoji(symbol: project.coverSymbol, size: 28)
                        .frame(width: 50, height: 50)
                        .background(StudioTheme.elevated)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).studioPointerCursor()
                .popover(isPresented: $showingEmojiPicker) { EmojiPicker(selection: $project.coverSymbol) }

                VStack(alignment: .leading, spacing: 3) {
                    TextField("Work title", text: $project.title)
                        .textFieldStyle(.plain)
                        .studioTextCursor()
                        .font(.system(size: 18, weight: .semibold))
                        .studioEditableLine()

                    HStack(spacing: 7) {
                        TextField("Customer", text: $project.client)
                            .textFieldStyle(.plain)
                            .studioTextCursor()
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.secondary)
                            .studioEditableLine()

                        Text("·")
                            .foregroundStyle(StudioTheme.tertiary)

                        Menu {
                            ForEach(ModoWorkType.allCases) { type in
                                Button {
                                    changeWorkType(type)
                                } label: {
                                    Label(type.rawValue, systemImage: type.icon)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: project.effectiveWorkType.icon)
                                Text(project.effectiveWorkType.rawValue)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .semibold))
                            }
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)

                Spacer()
                if hasFrameLink {
                    Button { openURL(project.frameIOURL ?? project.clientShareURL ?? "") } label: {
                        Label("Frame.io", systemImage: "play.rectangle.on.rectangle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button { project.favorite.toggle() } label: { Image(systemName: project.favorite ? "star.fill" : "star") }
                    .buttonStyle(IconButtonStyle()).help("Favorite")
            }
            .padding(.horizontal, 22).frame(height: 70)
        }
    }



    private func changeWorkType(_ type: ModoWorkType) {
        guard type != project.effectiveWorkType else { return }
        project.workType = type
        project.enabledSections = type.defaultSections
        if type != .creativeProduction {
            project.editingSoftware = ""
            project.aspectRatio = ""
            project.resolution = ""
            project.frameRate = ""
        }
        store.setSelectedSection(.overview, for: project.id)
    }
    private var hasFrameLink: Bool {
        !(project.frameIOURL ?? "").isEmpty || !(project.clientShareURL ?? "").isEmpty
    }

    private func openURL(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let normalized = text.contains("://") ? text : "https://\(text)"
        if let url = URL(string: normalized) { NSWorkspace.shared.open(url) }
    }
}

private struct BannerControls: View {
    @Binding var project: StudioProject
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Cover").font(.system(size: 13, weight: .semibold))
            Text("PRESETS").sectionMicroLabel()
            HStack(spacing: 6) {
                ForEach(["banner", "banner1", "banner3"], id: \.self) { name in
                    Button {
                        project.bannerPath = nil
                        project.bannerAssetName = name
                    } label: {
                        ProjectBanner(path: nil, assetName: name, colorHex: project.colorHex, height: 54)
                            .frame(width: 84).clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(project.bannerAssetName == name ? StudioTheme.primary : StudioTheme.border))
                    }.buttonStyle(.plain).studioPointerCursor()
                }
            }
            Button("Choose image…") { chooseBanner() }.buttonStyle(SecondaryButtonStyle())
            Divider()
            Text("SIZE").sectionMicroLabel()
            Slider(value: Binding(get: { project.bannerHeight ?? 170 }, set: { project.bannerHeight = $0 }), in: 120...300, step: 5)
            Text("FOCUS").sectionMicroLabel()
            Slider(value: Binding(get: { project.bannerFocusY ?? 0.5 }, set: { project.bannerFocusY = $0 }), in: 0...1)
            HStack {
                Button("Reset") { project.bannerHeight = 170; project.bannerFocusY = 0.5 }.buttonStyle(.plain).studioPointerCursor()
                Spacer(); Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14).frame(width: 300)
        .background(StudioTheme.elevated)
    }

    private func chooseBanner() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            project.bannerPath = panel.url?.path
            project.bannerAssetName = nil
        }
    }
}

private struct ProjectOverview: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject
    @State private var isEditing = false

    private struct ProgressStage: Identifiable {
        let id: String
        let title: String
        let detail: String
        let value: Double
        let section: ProjectSection
    }

    private let editColumns = [GridItem(.flexible()), GridItem(.flexible())]

    private var workType: ModoWorkType { project.effectiveWorkType }
    private var isCreative: Bool { workType == .creativeProduction }
    private var tasksEnabled: Bool { store.settings.isDestinationEnabled(.tasks) }

    private var projectTasks: [StudioTask] {
        guard tasksEnabled else { return [] }
        return store.tasks.filter { $0.projectID == project.id }
    }

    private var openProjectTasks: [StudioTask] {
        projectTasks
            .filter { !$0.isComplete }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var needsSetup: Bool {
        project.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        project.description == "Add a concise project description."
    }

    private var setupFields: [String] {
        if isCreative {
            return [project.description, project.location, project.deliverable, project.editingSoftware]
        }
        return [project.description, project.location, project.deliverable, project.nextAction ?? ""]
    }

    private var stages: [ProgressStage] {
        let configured = setupFields.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0 != "Add a concise project description."
        }.count
        let setupProgress = Double(configured) / Double(max(1, setupFields.count))

        var result: [ProgressStage] = [
            ProgressStage(
                id: "setup",
                title: "Setup",
                detail: configured == setupFields.count ? "Work ready" : "\(configured)/\(setupFields.count) details",
                value: setupProgress,
                section: .overview
            )
        ]

        if tasksEnabled {
            let taskProgress = projectTasks.isEmpty ? 0 : Double(projectTasks.filter(\.isComplete).count) / Double(projectTasks.count)
            result.append(
                ProgressStage(
                    id: "tasks",
                    title: "Tasks",
                    detail: projectTasks.isEmpty ? "No tasks yet" : "\(projectTasks.filter(\.isComplete).count)/\(projectTasks.count) done",
                    value: taskProgress,
                    section: .tasks
                )
            )
        }

        if isCreative {
            let shotProgress = project.shots.isEmpty ? 0 : Double(project.shots.filter(\.completed).count) / Double(project.shots.count)
            let kitProgress = project.kit.isEmpty ? 0 : Double(project.kit.filter(\.packed).count) / Double(project.kit.count)
            let productionInputs = [
                project.shots.isEmpty ? nil : shotProgress,
                project.kit.isEmpty ? nil : kitProgress
            ].compactMap { $0 }
            let productionProgress = productionInputs.isEmpty ? 0 : productionInputs.reduce(0, +) / Double(productionInputs.count)

            result.append(
                ProgressStage(
                    id: "production",
                    title: "Production",
                    detail: productionDetail,
                    value: productionProgress,
                    section: project.effectiveSections.contains(.shots) ? .shots : .schedule
                )
            )
        } else {
            let hasBrief = !project.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasNextAction = !(project.nextAction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let planningProgress = [hasBrief, hasNextAction].filter { $0 }.count
            result.append(
                ProgressStage(
                    id: "planning",
                    title: workType == .event ? "Planning" : "Scope",
                    detail: planningProgress == 2 ? "Ready to move" : "\(planningProgress)/2 essentials",
                    value: Double(planningProgress) / 2.0,
                    section: project.effectiveSections.contains(.brief) ? .brief : .overview
                )
            )
        }

        let hasDeliveryLink = !(project.frameIOURL ?? "").isEmpty || !(project.clientShareURL ?? "").isEmpty
        let delivered = project.status == .delivered
        let deliveryProgress: Double = delivered ? 1 : (hasDeliveryLink ? 0.7 : (!project.deliverable.isEmpty ? 0.35 : 0))
        if project.effectiveSections.contains(.delivery) {
            result.append(
                ProgressStage(
                    id: "delivery",
                    title: "Delivery",
                    detail: delivered ? "Delivered" : (hasDeliveryLink ? "Review ready" : "Not ready"),
                    value: deliveryProgress,
                    section: .delivery
                )
            )
        }

        return result
    }

    private var overallProgress: Double {
        let values = stages.map(\.value)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private var productionDetail: String {
        let shots = project.shots.isEmpty ? "No shots" : "\(project.shots.filter(\.completed).count)/\(project.shots.count) shots"
        let kit = project.kit.isEmpty ? "No kit" : "\(project.kit.filter(\.packed).count)/\(project.kit.count) packed"
        return shots + " · " + kit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overview")
                            .font(.system(size: 25, weight: .semibold))
                        HStack(spacing: 5) {
                            Image(systemName: workType.icon)
                            Text(workType.rawValue)
                            Text("·")
                            Text("\(Int((overallProgress * 100).rounded()))% ready")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                    }

                    Spacer()

                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation(.easeOut(duration: 0.12)) { isEditing.toggle() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if isEditing {
                    editView
                } else {
                    summaryView
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 28)
        }
        .onAppear {
            if needsSetup { isEditing = true }
        }
    }

    private var editView: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                StudioCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(aboutLabel).sectionMicroLabel()
                        TextField(aboutPlaceholder, text: $project.description, axis: .vertical)
                            .textFieldStyle(.plain)
                            .studioTextCursor()
                            .font(.system(size: 12))
                            .lineLimit(4...10)
                            .padding(11)
                            .background(StudioTheme.input)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .padding(15)
                }

                StudioCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(isCreative ? "PRODUCTION" : "WORK").sectionMicroLabel()

                        if isCreative {
                            editableRow("Editing software", text: $project.editingSoftware)
                        } else {
                            editableOptionalRow("Next action", text: Binding(
                                get: { project.nextAction ?? "" },
                                set: { project.nextAction = $0 }
                            ))
                        }

                        editableRow("Deliverable", text: $project.deliverable)
                        editableRow("Work color", text: $project.colorHex)
                    }
                    .padding(15)
                }
            }
            .frame(maxWidth: 360)

            StudioCard {
                LazyVGrid(columns: editColumns, spacing: 10) {
                    EditableDateCard(label: "START", icon: "calendar", value: $project.startDate)
                    EditableDateCard(label: "DEADLINE", icon: "flag", value: $project.dueDate)
                    EditableTextCard(label: "LOCATION", icon: "mappin", placeholder: "Add location", value: $project.location)

                    if isCreative {
                        EditableTextCard(label: "FORMAT", icon: "rectangle", placeholder: "16:9", value: $project.aspectRatio)
                        EditableTextCard(label: "RESOLUTION", icon: "4k.tv", placeholder: "4K UHD", value: $project.resolution)
                        EditableTextCard(label: "FRAME RATE", icon: "gauge", placeholder: "25 fps", value: $project.frameRate)
                    } else {
                        infoCard(label: "TYPE", icon: workType.icon, value: workType.rawValue)
                        infoCard(label: "CUSTOMER", icon: "person.crop.circle", value: project.client.isEmpty ? "Not linked" : project.client)
                        infoCard(label: "STATUS", icon: "circle.dotted", value: project.status.displayName(for: project.effectiveWorkType))
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                workStateCard
                    .frame(maxWidth: .infinity)
                nextDeadlineCard
                    .frame(width: 300)
            }

            HStack(alignment: .top, spacing: 14) {
                nextUpCard
                    .frame(maxWidth: .infinity)
                workDetailsCard
                    .frame(maxWidth: .infinity)
            }

            if !project.description.isEmpty && project.description != "Add a concise project description." {
                StudioCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ABOUT").sectionMicroLabel()
                        Text(project.description)
                            .font(.system(size: 12))
                            .foregroundStyle(StudioTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var workStateCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WORK STATE").sectionMicroLabel()
                        Text(project.status.displayName(for: project.effectiveWorkType))
                            .font(.system(size: 21, weight: .semibold))
                    }
                    Spacer()
                    Button("Change") { isEditing = true }
                        .buttonStyle(SecondaryButtonStyle())
                }

                projectPipelineStepper

                HStack(spacing: 8) {
                    readinessPill("Setup", ready: stages.first(where: { $0.id == "setup" })?.value == 1)

                    if tasksEnabled {
                        readinessPill("Tasks", ready: openProjectTasks.isEmpty && !projectTasks.isEmpty)
                    }

                    if isCreative {
                        readinessPill("Shots", ready: !project.shots.isEmpty && project.shots.allSatisfy(\.completed))
                        readinessPill("Kit", ready: !project.kit.isEmpty && project.kit.allSatisfy(\.packed))
                    } else {
                        readinessPill("Scope", ready: !project.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if project.effectiveSections.contains(.delivery) {
                        readinessPill(
                            "Delivery",
                            ready: project.status == .delivered ||
                            !(project.frameIOURL ?? "").isEmpty ||
                            !(project.clientShareURL ?? "").isEmpty
                        )
                    }
                }
            }
            .padding(15)
        }
    }

    private func readinessPill(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(ready ? StudioTheme.green : StudioTheme.tertiary)
            Text(title)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(StudioTheme.soft)
        .clipShape(Capsule())
    }

    private var projectPipelineStepper: some View {
        HStack(spacing: 0) {
            ForEach(Array(ProjectStatus.allCases.enumerated()), id: \.element) { index, status in
                Button {
                    project.status = status
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            if index > 0 {
                                Rectangle()
                                    .fill(index <= currentStatusIndex ? Color(hex: project.colorHex) : StudioTheme.border)
                                    .frame(height: 2)
                            }

                            Circle()
                                .fill(index <= currentStatusIndex ? Color(hex: project.colorHex) : StudioTheme.soft)
                                .overlay(
                                    Circle()
                                        .stroke(index <= currentStatusIndex ? Color(hex: project.colorHex) : StudioTheme.border, lineWidth: 1)
                                )
                                .frame(width: 12, height: 12)

                            if index < ProjectStatus.allCases.count - 1 {
                                Rectangle()
                                    .fill(index < currentStatusIndex ? Color(hex: project.colorHex) : StudioTheme.border)
                                    .frame(height: 2)
                            }
                        }

                        Text(status.displayName(for: project.effectiveWorkType))
                            .font(.system(size: 8, weight: status == project.status ? .semibold : .medium))
                            .foregroundStyle(status == project.status ? StudioTheme.primary : StudioTheme.tertiary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private var currentStatusIndex: Int {
        ProjectStatus.allCases.firstIndex(of: project.status) ?? 0
    }

    private var nextDeadlineCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("DEADLINE").sectionMicroLabel()
                    Spacer()
                    Text(durationLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                }

                DatePicker(
                    "",
                    selection: $project.dueDate,
                    in: project.startDate...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .controlSize(.regular)

                HStack(spacing: 7) {
                    Button("Tomorrow") {
                        project.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("+1 week") {
                        project.dueDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("START").sectionMicroLabel()
                        DatePicker("", selection: $project.startDate, displayedComponents: .date)
                            .labelsHidden()
                            .controlSize(.small)
                    }

                    Spacer()

                    if let nextTask = openProjectTasks.first {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("NEXT TASK").sectionMicroLabel()
                            Text(nextTask.title)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                        }
                    } else if let nextAction = project.nextAction, !nextAction.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("NEXT ACTION").sectionMicroLabel()
                            Text(nextAction)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nextUpCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXT UP").sectionMicroLabel()

                        if tasksEnabled {
                            Text(openProjectTasks.isEmpty ? "Nothing blocking this work" : "\(openProjectTasks.count) open task\(openProjectTasks.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .medium))
                        } else {
                            Text(project.nextAction?.isEmpty == false ? project.nextAction! : "Add a next action")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }

                    Spacer()

                    if tasksEnabled {
                        Button("Open tasks") { store.setSelectedSection(.tasks, for: project.id) }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Edit") { isEditing = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(14)

                if tasksEnabled {
                    if openProjectTasks.isEmpty {
                        Text("Nothing urgent right now.")
                            .font(.system(size: 10))
                            .foregroundStyle(StudioTheme.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(openProjectTasks.prefix(5)) { task in
                                HStack(spacing: 10) {
                                    Circle()
                                        .stroke(StudioTheme.border, lineWidth: 1.2)
                                        .frame(width: 14, height: 14)
                                    Text(task.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    if let due = task.dueDate {
                                        Text(due.shortStudioDate)
                                            .font(.system(size: 8))
                                            .foregroundStyle(StudioTheme.tertiary)
                                    }
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 38)
                                .background(StudioTheme.soft)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                } else {
                    Text("Tasks are hidden for this workspace. Use the work's next action to keep momentum without adding another module.")
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    private var workDetailsCard: some View {
        StudioCard {
            VStack(spacing: 0) {
                HStack {
                    Text(isCreative ? "PRODUCTION DETAILS" : "WORK DETAILS").sectionMicroLabel()
                    Spacer()
                    Button("Edit") { isEditing = true }
                        .buttonStyle(.plain)
                        .studioPointerCursor()
                        .font(.system(size: 9, weight: .medium))
                }
                .padding(14)

                Divider()
                summaryLine("Type", value: workType.rawValue)
                Divider()
                summaryLine("Location", value: fallback(project.location))

                if isCreative {
                    Divider()
                    summaryLine("Format", value: "\(fallback(project.aspectRatio)) · \(fallback(project.resolution))")
                    Divider()
                    summaryLine("Frame rate", value: fallback(project.frameRate))
                    Divider()
                    summaryLine("Editing", value: fallback(project.editingSoftware))
                } else if let nextAction = project.nextAction {
                    Divider()
                    summaryLine("Next action", value: fallback(nextAction))
                }

                Divider()
                summaryLine("Delivery", value: fallback(project.deliverable))
                Divider()
                summaryLine(
                    "People",
                    value: "\((project.clientContacts ?? []).count) customer · \(project.crew.count) team"
                )
            }
        }
    }

    private var aboutLabel: String {
        switch workType {
        case .creativeProduction: "ABOUT THE PRODUCTION"
        case .service: "ABOUT THE SERVICE"
        case .consulting: "ABOUT THE ENGAGEMENT"
        case .event: "ABOUT THE EVENT"
        case .flexible: "ABOUT THE WORK"
        }
    }

    private var aboutPlaceholder: String {
        switch workType {
        case .creativeProduction: "Describe what you are making"
        case .service: "Describe the scope, outcome and constraints"
        case .consulting: "Describe the objective, scope and expected outcome"
        case .event: "Describe the event, audience and plan"
        case .flexible: "Describe what this work needs to achieve"
        }
    }

    private var durationLabel: String {
        let days = max(1, Calendar.current.dateComponents([.day], from: project.startDate, to: project.dueDate).day ?? 1)
        return "\(days)d"
    }

    private func fallback(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not set" : value
    }

    private func summaryLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(StudioTheme.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 14)
        .frame(minHeight: 39)
    }

    private func editableRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(StudioTheme.secondary)
                .frame(width: 112, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .studioTextCursor()
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .frame(height: 29)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .font(.system(size: 10))
    }

    private func editableOptionalRow(_ title: String, text: Binding<String>) -> some View {
        editableRow(title, text: text)
    }

    @ViewBuilder
    private func infoCard(label: String, icon: String, value: String) -> some View {
        StudioCard {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(StudioTheme.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).sectionMicroLabel()
                    Text(value)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(12)
        }
    }
}

private struct EditableTextCard: View {
    let label: String
    let icon: String
    let placeholder: String
    @Binding var value: String

    var body: some View {
        StudioCard {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(StudioTheme.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).sectionMicroLabel()
                    TextField(placeholder, text: $value).textFieldStyle(.plain).studioTextCursor().font(.system(size: 11, weight: .medium))
                }
                Spacer()
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 66)
        }
    }
}

private struct EditableDateCard: View {
    let label: String
    let icon: String
    @Binding var value: Date

    var body: some View {
        StudioCard {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(StudioTheme.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).sectionMicroLabel()
                    DatePicker("", selection: $value, displayedComponents: .date)
                        .labelsHidden().controlSize(.small)
                }
                Spacer()
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 66)
        }
    }
}

private struct ProjectTasksView: View {
    @EnvironmentObject private var store: FramoStudioStore
    let projectID: UUID
    @State private var filter: TaskFilter = .open
    @State private var quickTitle = ""
    @State private var search = ""

    private enum TaskFilter: String, CaseIterable, Identifiable {
        case open = "Open"
        case today = "Today"
        case upcoming = "Upcoming"
        case completed = "Completed"
        var id: String { rawValue }
    }

    private var project: StudioProject? { store.projects.first(where: { $0.id == projectID }) }
    private var projectTasks: [StudioTask] { store.tasks.filter { $0.projectID == projectID } }
    private var visibleTasks: [StudioTask] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projectTasks.filter { task in
            let filterMatches: Bool
            switch filter {
            case .open: filterMatches = !task.isComplete
            case .today: filterMatches = !task.isComplete && (task.dueDate.map(Calendar.current.isDateInToday) ?? false)
            case .upcoming:
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
                filterMatches = !task.isComplete && ((task.dueDate ?? .distantPast) >= tomorrow)
            case .completed: filterMatches = task.isComplete
            }
            return filterMatches && (needle.isEmpty || task.title.lowercased().contains(needle))
        }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
        }
    }

    private var openCount: Int { projectTasks.filter { !$0.isComplete }.count }
    private var overdueCount: Int { projectTasks.filter { !$0.isComplete && (($0.dueDate ?? .distantFuture) < Calendar.current.startOfDay(for: .now)) }.count }
    private var completedCount: Int { projectTasks.filter(\.isComplete).count }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    metrics
                    quickAdd
                    toolbar
                    if visibleTasks.isEmpty {
                        StudioCard {
                            VStack(spacing: 6) {
                                Text(filter == .completed ? "Nothing completed yet" : "No tasks here")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Add a task, change the filter, or give an existing task a deadline.")
                                    .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                            }
                            .padding(32).frame(maxWidth: .infinity)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: proxy.size.width > 900 ? 330 : 280), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(visibleTasks) { task in
                                if let binding = taskBinding(task.id) { ProjectTaskCard(task: binding) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 24)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tasks").font(.system(size: 25, weight: .semibold))
                Text(project?.title ?? "Project").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Button("Add task") { focusNewTask() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            taskMetric("Open", value: openCount, accent: StudioTheme.primary)
            taskMetric("Overdue", value: overdueCount, accent: overdueCount > 0 ? StudioTheme.red : StudioTheme.tertiary)
            taskMetric("Done", value: completedCount, accent: StudioTheme.green)
            Spacer(minLength: 0)
        }
    }

    private func taskMetric(_ title: String, value: Int, accent: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text("\(value)").font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
        }
        .padding(.horizontal, 11).frame(height: 34)
        .background(StudioTheme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var quickAdd: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus.circle").foregroundStyle(StudioTheme.secondary)
            TextField("What needs to happen?", text: $quickTitle)
                .textFieldStyle(.plain).studioTextCursor()
                .onSubmit { createQuickTask() }
            Button("Add") { createQuickTask() }.buttonStyle(SecondaryButtonStyle()).disabled(quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) { ForEach(TaskFilter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.tertiary)
                TextField("Search tasks", text: $search).textFieldStyle(.plain).studioTextCursor()
            }
            .padding(.horizontal, 10).frame(height: 31)
            .background(StudioTheme.soft).clipShape(RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
    }

    private func focusNewTask() { quickTitle = "New task"; createQuickTask() }
    private func createQuickTask() {
        let title = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.tasks.insert(StudioTask(title: title, dueDate: nil, isComplete: false, projectID: projectID, priority: 1), at: 0)
        quickTitle = ""
        filter = .open
    }
    private func taskBinding(_ id: UUID) -> Binding<StudioTask>? {
        guard let index = store.tasks.firstIndex(where: { $0.id == id }) else { return nil }
        return $store.tasks[index]
    }
}

private struct ProjectTaskCard: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var task: StudioTask
    @State private var showingDate = false

    private var dueLabel: String {
        guard let due = task.dueDate else { return "No deadline" }
        if Calendar.current.isDateInToday(due) { return "Today · " + due.formatted(date: .omitted, time: .shortened) }
        return due.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 10) {
                    Button { task.isComplete.toggle() } label: {
                        Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16)).foregroundStyle(task.isComplete ? StudioTheme.green : StudioTheme.secondary)
                    }.buttonStyle(.plain)
                    TextField("Task", text: $task.title)
                        .textFieldStyle(.plain).studioTextCursor()
                        .font(.system(size: 12, weight: .semibold))
                        .strikethrough(task.isComplete)
                    Spacer()
                    Menu {
                        ForEach(1...3, id: \.self) { value in Button("Priority \(value)") { task.priority = value } }
                        Divider()
                        let actions = store.pluginActions(target: .task)
                        ForEach(actions) { action in Button(action.action.label) { store.runPluginAction(action, projectID: task.projectID, taskID: task.id) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                }
                HStack(spacing: 8) {
                    Button { showingDate.toggle() } label: {
                        HStack(spacing: 5) { Image(systemName: "calendar"); Text(dueLabel) }
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(task.dueDate.map { $0 < .now && !task.isComplete } == true ? StudioTheme.red : StudioTheme.secondary)
                    }
                    .buttonStyle(.plain).studioPointerCursor()
                    .popover(isPresented: $showingDate) {
                        VStack(alignment: .leading, spacing: 10) {
                            DatePicker("Due", selection: Binding(get: { task.dueDate ?? .now }, set: { task.dueDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                            HStack { Button("Tomorrow") { task.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) }; Button("Clear") { task.dueDate = nil; showingDate = false } }
                        }.padding(14).frame(width: 300)
                    }
                    Spacer()
                    HStack(spacing: 3) { ForEach(1...3, id: \.self) { value in Circle().fill(value <= task.priority ? StudioTheme.primary : StudioTheme.border).frame(width: 5, height: 5) } }
                }
            }
            .padding(13)
        }
    }
}

private struct LongformEditor: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    @Binding var richData: Data?
    var monospaced = false
    @State private var action: RichEditorAction?
    @State private var pageLayout: DocumentPageLayout = .single
    @State private var textSelection = RichTextSelection.empty

    private var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
    private var characterCount: Int { text.count }
    private var pageCount: Int { max(1, Int(ceil(Double(max(1, characterCount)) / 2800.0))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 25, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Picker("", selection: $pageLayout) {
                        ForEach(DocumentPageLayout.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 155)
                }
            }

            RichEditorToolbar(action: $action, monospaced: monospaced)

            HStack(alignment: .top, spacing: 14) {
                documentPage(editable: true)
                if pageLayout == .twoPage {
                    DocumentContinuationPreview(text: text, monospaced: monospaced)
                        .frame(maxWidth: .infinity, minHeight: 620)
                }
            }

            HStack(spacing: 14) {
                Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                Text("\(wordCount) words")
                Text("\(characterCount) characters")
                Spacer()
                Text("RTF document")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(StudioTheme.tertiary)
        }
        .padding(.horizontal, 22).padding(.vertical, 28)
    }

    private func documentPage(editable: Bool) -> some View {
        RichTextEditor(text: $text, rtfData: $richData, selection: $textSelection, monospaced: monospaced, action: action)
            .frame(maxWidth: .infinity, minHeight: 620)
            .background(StudioTheme.canvas)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }


}

private enum DocumentPageLayout: String, CaseIterable, Identifiable {
    case single = "1 page"
    case twoPage = "2 pages"
    var id: String { rawValue }
}

private struct DocumentContinuationPreview: View {
    let text: String
    let monospaced: Bool

    private var continuation: String {
        let chars = Array(text)
        let start = min(chars.count, 2800)
        return String(chars[start...])
    }

    var body: some View {
        ScrollView {
            Text(continuation.isEmpty ? "Page 2 will appear here as the document grows." : continuation)
                .font(monospaced ? .system(size: 14, design: .monospaced) : .system(size: 14))
                .foregroundStyle(continuation.isEmpty ? StudioTheme.tertiary : StudioTheme.primary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
        }
        .background(StudioTheme.canvas)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

private struct RichTextSelection: Equatable {
    var text: String
    var range: NSRange
    static let empty = RichTextSelection(text: "", range: NSRange(location: 0, length: 0))
}

private enum RichEditorCommand: Equatable {
    case bold, italic, underline, bullet, heading, body
    case font(String)
    case size(CGFloat)
    case image(URL)
    case replaceSelection(String, NSRange)
}

private struct RichEditorAction: Equatable {
    let id = UUID()
    let command: RichEditorCommand
    static func == (lhs: RichEditorAction, rhs: RichEditorAction) -> Bool { lhs.id == rhs.id }
}

private struct RichEditorToolbar: View {
    @Binding var action: RichEditorAction?
    let monospaced: Bool

    var body: some View {
        HStack(spacing: 2) {
            formatButton("bold", help: "Bold", command: .bold)
            formatButton("italic", help: "Italic", command: .italic)
            formatButton("underline", help: "Underline", command: .underline)
            Divider().frame(height: 18).padding(.horizontal, 4)
            formatButton("textformat.size.larger", help: "Heading", command: .heading)
            formatButton("textformat", help: "Body text", command: .body)
            formatButton("list.bullet", help: "Bullet", command: .bullet)
            Button { chooseImage() } label: { Image(systemName: "photo").frame(width: 28, height: 27) }
                .buttonStyle(.plain).studioPointerCursor().help("Insert image")
            Divider().frame(height: 18).padding(.horizontal, 4)
            Menu {
                ForEach(["Helvetica Neue", "Avenir Next", "Arial", "Georgia", "Times New Roman", "Iowan Old Style", "Baskerville", "Courier New", "Menlo"], id: \.self) { font in
                    Button(font) { send(.font(font)) }
                }
            } label: {
                HStack(spacing: 5) { Text(monospaced ? "Script font" : "Font"); Image(systemName: "chevron.down") }
                    .font(.system(size: 10)).padding(.horizontal, 8).frame(height: 28)
                    .background(StudioTheme.soft).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton).studioPointerCursor().fixedSize()
            Menu {
                ForEach([11, 12, 14, 16, 18, 24, 32], id: \.self) { value in Button("\(value) pt") { send(.size(CGFloat(value))) } }
            } label: {
                Text("Size").font(.system(size: 10)).padding(.horizontal, 8).frame(height: 28)
                    .background(StudioTheme.soft).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton).studioPointerCursor().fixedSize()
            Spacer()
            Text("Rich text").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
        }
        .padding(4)
        .background(StudioTheme.soft)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatButton(_ icon: String, help: String, command: RichEditorCommand) -> some View {
        Button { send(command) } label: { Image(systemName: icon).frame(width: 28, height: 27) }
            .buttonStyle(.plain).studioPointerCursor().help(help)
    }

    private func send(_ command: RichEditorCommand) { action = RichEditorAction(command: command) }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { send(.image(url)) }
    }
}

private struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    @Binding var selection: RichTextSelection
    let monospaced: Bool
    let action: RichEditorAction?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let editor = NSTextView()
        editor.delegate = context.coordinator
        editor.isRichText = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = NSSize(width: 22, height: 20)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false

        if let rtfData, let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            editor.textStorage?.setAttributedString(attributed)
        } else {
            let font = baseFont(monospaced: monospaced, size: 14)
            editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.string != text, editor.window?.firstResponder !== editor {
            context.coordinator.isApplyingExternalUpdate = true
            editor.string = text
            editor.font = baseFont(monospaced: monospaced, size: 14)
            context.coordinator.isApplyingExternalUpdate = false
        }
        if let action, context.coordinator.lastActionID != action.id {
            context.coordinator.lastActionID = action.id
            context.coordinator.apply(action.command, to: editor)
        }
    }

    private func baseFont(monospaced: Bool, size: CGFloat) -> NSFont {
        monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastActionID: UUID?
        var isApplyingExternalUpdate = false
        private var syncGeneration = 0
        init(parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate,
                  let editor = notification.object as? NSTextView else { return }
            scheduleSync(editor)
            publishSelection(editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            publishSelection(editor)
        }

        private func publishSelection(_ editor: NSTextView) {
            let rawRange = editor.selectedRange()
            let full = editor.string as NSString
            let valid = NSIntersectionRange(rawRange, NSRange(location: 0, length: full.length))
            let selected = valid.length > 0 ? full.substring(with: valid) : ""
            let snapshot = RichTextSelection(text: selected, range: valid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.selection != snapshot { self.parent.selection = snapshot }
            }
        }

        func apply(_ command: RichEditorCommand, to editor: NSTextView) {
            editor.window?.makeFirstResponder(editor)
            switch command {
            case .bold: applyTrait(.boldFontMask, editor: editor)
            case .italic: applyTrait(.italicFontMask, editor: editor)
            case .underline: applyAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, editor: editor)
            case .bullet: editor.insertText("• ", replacementRange: editor.selectedRange())
            case .heading: applyFontSize(22, weight: .semibold, editor: editor)
            case .body: applyFontSize(14, weight: .regular, editor: editor)
            case .font(let name): applyFontName(name, editor: editor)
            case .size(let size): applyFontSize(size, weight: nil, editor: editor)
            case .image(let url): insertImage(url, editor: editor)
            case .replaceSelection(let replacement, let range): replaceSelection(replacement, range: range, editor: editor)
            }
            scheduleSync(editor)
        }

        private func selectedOrTypingFont(_ editor: NSTextView) -> NSFont {
            let range = editor.selectedRange()
            if range.location < editor.textStorage?.length ?? 0,
               let font = editor.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont { return font }
            return editor.font ?? NSFont.systemFont(ofSize: 14)
        }

        private func applyTrait(_ trait: NSFontTraitMask, editor: NSTextView) {
            let manager = NSFontManager.shared
            let font = manager.convert(selectedOrTypingFont(editor), toHaveTrait: trait)
            applyAttribute(.font, value: font, editor: editor)
        }

        private func applyFontName(_ name: String, editor: NSTextView) {
            let current = selectedOrTypingFont(editor)
            let font = NSFont(name: name, size: current.pointSize) ?? current
            applyAttribute(.font, value: font, editor: editor)
        }

        private func applyFontSize(_ size: CGFloat, weight: NSFont.Weight?, editor: NSTextView) {
            let current = selectedOrTypingFont(editor)
            let font: NSFont
            if let weight { font = NSFont.systemFont(ofSize: size, weight: weight) }
            else { font = NSFont(name: current.fontName, size: size) ?? NSFont.systemFont(ofSize: size) }
            applyAttribute(.font, value: font, editor: editor)
        }

        private func insertImage(_ url: URL, editor: NSTextView) {
            guard let image = NSImage(contentsOf: url) else { return }
            let attachment = NSTextAttachment()
            let maxWidth: CGFloat = 520
            if image.size.width > maxWidth, image.size.width > 0 {
                let ratio = maxWidth / image.size.width
                let resized = NSImage(size: NSSize(width: maxWidth, height: image.size.height * ratio))
                resized.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: resized.size), from: .zero, operation: .copy, fraction: 1)
                resized.unlockFocus()
                attachment.image = resized
            } else {
                attachment.image = image
            }
            let attributed = NSAttributedString(attachment: attachment)
            let range = editor.selectedRange()
            editor.textStorage?.replaceCharacters(in: range, with: attributed)
            editor.setSelectedRange(NSRange(location: range.location + 1, length: 0))
        }

        private func replaceSelection(_ replacement: String, range: NSRange, editor: NSTextView) {
            guard let storage = editor.textStorage else { return }
            let valid = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            guard valid.location != NSNotFound, valid.length > 0 else { return }
            var attributes = editor.typingAttributes
            if valid.location < storage.length {
                attributes = storage.attributes(at: valid.location, effectiveRange: nil)
            }
            let attributed = NSAttributedString(string: replacement, attributes: attributes)
            storage.replaceCharacters(in: valid, with: attributed)
            let location = valid.location + (replacement as NSString).length
            editor.setSelectedRange(NSRange(location: location, length: 0))
            publishSelection(editor)
        }

        private func applyAttribute(_ key: NSAttributedString.Key, value: Any, editor: NSTextView) {
            let range = editor.selectedRange()
            if range.length > 0 {
                editor.textStorage?.addAttribute(key, value: value, range: range)
            } else {
                var attrs = editor.typingAttributes
                attrs[key] = value
                editor.typingAttributes = attrs
            }
        }

        private func scheduleSync(_ editor: NSTextView) {
            syncGeneration += 1
            let generation = syncGeneration
            let plainText = editor.string
            let richData: Data?
            if let storage = editor.textStorage {
                richData = try? storage.data(
                    from: NSRange(location: 0, length: storage.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                )
            } else {
                richData = nil
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.syncGeneration else { return }
                self.parent.text = plainText
                self.parent.rtfData = richData
            }
        }
    }
}

private struct StoryboardView: View {
    @Binding var project: StudioProject
    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storyboard").font(.system(size: 25, weight: .semibold))
                    Text("Every editable field is explicitly labelled; add a reference frame when you have one.").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button("Add frame") { project.storyboard.append(StoryboardCard(shotNumber: project.storyboard.count + 1, title: "", notes: "")) }.buttonStyle(PrimaryButtonStyle())
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach($project.storyboard) { $card in StoryboardCardEditor(card: $card) }
                }.padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 28)
    }
}

private struct StoryboardCardEditor: View {
    @Binding var card: StoryboardCard

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 0) {
                referenceImage
                VStack(alignment: .leading, spacing: 9) {
                    Text("SHOT \(card.shotNumber)").sectionMicroLabel()
                    labelledField("FRAME TITLE", placeholder: "Type a frame title", text: $card.title)
                    labelledField("VISUAL / ACTION NOTES", placeholder: "Describe what we should see", text: $card.notes, axis: .vertical)
                }.padding(12)
            }
        }
    }

    @ViewBuilder private var referenceImage: some View {
        ZStack {
            if let path = card.assetPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                StudioTheme.soft
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 22, weight: .light))
                    Text("Add reference frame").font(.system(size: 10, weight: .medium))
                }.foregroundStyle(StudioTheme.tertiary)
            }
            Button("Choose image") { chooseImage() }
                .buttonStyle(SecondaryButtonStyle()).opacity(card.assetPath == nil ? 1 : 0.9)
        }
        .frame(height: 132).clipped()
    }

    private func labelledField(_ label: String, placeholder: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).sectionMicroLabel()
            TextField(placeholder, text: text, axis: axis)
                .textFieldStyle(.plain).studioTextCursor().font(.system(size: 11))
                .padding(8).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { card.assetPath = panel.url?.path }
    }
}

private struct ShotListView: View {
    @Binding var project: StudioProject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shot list").font(.system(size: 25, weight: .semibold))
                    Text("Clear input cells make it obvious what can be edited.").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button("Add shot") { addShot() }.buttonStyle(PrimaryButtonStyle())
            }
            StudioCard {
                VStack(spacing: 0) {
                    shotHeader
                    Divider()
                    ForEach($project.shots) { $shot in
                        ShotEditorRow(shot: $shot)
                        Divider().padding(.leading, 45)
                    }
                    if project.shots.isEmpty { Text("No shots yet.").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary).padding(28) }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 28)
    }

    private var shotHeader: some View {
        HStack {
            Text("#").frame(width: 26)
            Text("SHOT / DESCRIPTION").frame(maxWidth: .infinity, alignment: .leading)
            Text("SIZE").frame(width: 88, alignment: .leading)
            Text("MOVEMENT").frame(width: 105, alignment: .leading)
            Text("LENS").frame(width: 72, alignment: .leading)
            Text("DONE").frame(width: 42)
        }
        .font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
        .padding(.horizontal, 11).frame(height: 34)
    }

    private func addShot() {
        project.shots.append(Shot(number: project.shots.count + 1, title: "", description: "", shotSize: "Medium", movement: "Static", lens: "35mm", frameRate: project.frameRate, duration: "5 sec", completed: false))
    }
}

private struct ShotEditorRow: View {
    @Binding var shot: Shot

    var body: some View {
        HStack(spacing: 8) {
            Text("\(shot.number)").frame(width: 26).foregroundStyle(StudioTheme.secondary)
            VStack(spacing: 5) {
                input("Shot title", text: $shot.title)
                input("What happens in this shot?", text: $shot.description, small: true)
            }
            .frame(maxWidth: .infinity)
            input("Size", text: $shot.shotSize).frame(width: 88)
            input("Movement", text: $shot.movement).frame(width: 105)
            input("Lens", text: $shot.lens).frame(width: 72)
            Toggle("", isOn: $shot.completed).labelsHidden().toggleStyle(.checkbox).frame(width: 42)
        }
        .font(.system(size: 10)).padding(.horizontal, 11).frame(height: 66)
    }

    private func input(_ placeholder: String, text: Binding<String>, small: Bool = false) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).studioTextCursor()
            .font(.system(size: small ? 9 : 10, weight: small ? .regular : .medium))
            .foregroundStyle(small ? StudioTheme.secondary : StudioTheme.primary)
            .padding(.horizontal, 7).frame(height: small ? 24 : 27)
            .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct ProjectScheduleView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject

    private var related: [StudioEvent] {
        store.calendarItems.filter { $0.projectID == project.id }.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Schedule").font(.system(size: 25, weight: .semibold))
                Spacer()
                Button("Add event") { store.addEvent(projectID: project.id, on: project.startDate) }.buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 12) {
                DatePicker("Start", selection: $project.startDate, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Deadline", selection: $project.dueDate, displayedComponents: [.date, .hourAndMinute])
            }.font(.system(size: 10))
            StudioCard {
                VStack(spacing: 0) {
                    ForEach(related) { event in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(hex: event.colorHex)).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).fontWeight(.medium)
                                Text(event.location).foregroundStyle(StudioTheme.secondary)
                            }
                            Spacer()
                            Text(event.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(StudioTheme.secondary)
                        }
                        .font(.system(size: 10)).padding(12)
                        Divider().padding(.leading, 30)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 28)
    }
}

private struct PeopleView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject

    private var crewLibrary: [CrewMember] {
        var seen = Set<String>()
        return store.projects
            .flatMap(\.crew)
            .filter { member in
                let email = member.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let key = !email.isEmpty ? "email:\(email)" : "name:\(name)"
                guard !name.isEmpty || !email.isEmpty else { return false }
                return seen.insert(key).inserted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("People").font(.system(size: 25, weight: .semibold))
                        Text("Clients and workers attached to this production.").font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                }
                clientsCard
                crewCard
            }
            .padding(.horizontal, 22).padding(.vertical, 28)
        }
    }

    private var clientsCard: some View {
        StudioCard {
            VStack(spacing: 0) {
                HStack { Text("CLIENTS").sectionMicroLabel(); Spacer(); Button("Add client") { addClient() }.buttonStyle(SecondaryButtonStyle()) }
                    .padding(12)
                Divider()
                ForEach(Array((project.clientContacts ?? []).enumerated()), id: \.element.id) { index, _ in
                    clientRow(index)
                    Divider().padding(.leading, 12)
                }
                if (project.clientContacts ?? []).isEmpty {
                    Text("Add the people who approve, review or receive the work.").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).padding(20)
                }
            }
        }
    }

    private var crewCard: some View {
        StudioCard {
            VStack(spacing: 0) {
                HStack {
                    Text("WORKERS / CREW").sectionMicroLabel()
                    Spacer()
                    Menu("From library") {
                        ForEach(crewLibrary.filter { libraryMember in
                            !project.crew.contains(where: { existing in
                                if !libraryMember.email.isEmpty && !existing.email.isEmpty {
                                    return existing.email.caseInsensitiveCompare(libraryMember.email) == .orderedSame
                                }
                                return existing.name.caseInsensitiveCompare(libraryMember.name) == .orderedSame
                            })
                        }) { member in
                            Button("\(member.name) · \(member.role)") {
                                var copy = member
                                copy.id = UUID()
                                project.crew.append(copy)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().studioPointerCursor()
                    Button("Add person") { addCrew() }.buttonStyle(SecondaryButtonStyle())
                }
                    .padding(12)
                Divider()
                ForEach($project.crew) { $member in
                    HStack(spacing: 10) {
                        InitialAvatar(initials: member.initials, size: 32)
                        cleanField("Name", text: $member.name)
                        cleanField("Role", text: $member.role).frame(width: 160)
                        cleanField("Email", text: $member.email).frame(width: 205)
                    }
                    .padding(11)
                    Divider().padding(.leading, 52)
                }
            }
        }
    }

    private func clientRow(_ index: Int) -> some View {
        HStack(spacing: 9) {
            cleanField("Name", text: clientBinding(index, \.name))
            cleanField("Company", text: clientBinding(index, \.company)).frame(width: 150)
            cleanField("Email", text: clientBinding(index, \.email)).frame(width: 200)
            cleanField("Phone", text: clientBinding(index, \.phone)).frame(width: 120)
        }
        .padding(11)
    }

    private func clientBinding(_ index: Int, _ keyPath: WritableKeyPath<ClientContact, String>) -> Binding<String> {
        Binding(
            get: { (project.clientContacts ?? [])[index][keyPath: keyPath] },
            set: { value in
                var clients = project.clientContacts ?? []
                guard clients.indices.contains(index) else { return }
                clients[index][keyPath: keyPath] = value
                project.clientContacts = clients
            }
        )
    }

    private func cleanField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).studioTextCursor().font(.system(size: 10))
            .padding(.horizontal, 8).frame(height: 29).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func addClient() {
        var clients = project.clientContacts ?? []
        clients.append(ClientContact(name: "", company: project.client, email: "", phone: ""))
        project.clientContacts = clients
    }

    private func addCrew() {
        project.crew.append(CrewMember(name: "", role: "", email: "", initials: "--"))
    }
}

private struct KitView: View {
    @Binding var project: StudioProject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kit list").font(.system(size: 25, weight: .semibold))
                    Text("\(project.kit.filter(\.packed).count) of \(project.kit.count) packed").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button("Add item") { project.kit.append(KitItem(name: "", category: "Other", packed: false, quantity: 1)) }.buttonStyle(PrimaryButtonStyle())
            }
            StudioCard {
                VStack(spacing: 0) {
                    ForEach($project.kit) { $item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $item.packed).labelsHidden().toggleStyle(.checkbox)
                            TextField("Item", text: $item.name).textFieldStyle(.plain).studioTextCursor().fontWeight(.medium).studioEditableLine()
                            Spacer()
                            TextField("Category", text: $item.category).textFieldStyle(.plain).studioTextCursor().foregroundStyle(StudioTheme.secondary).studioEditableLine().frame(width: 145)
                            Stepper("\(item.quantity)", value: $item.quantity, in: 1...20).frame(width: 78)
                        }
                        .font(.system(size: 10)).padding(.horizontal, 13).frame(height: 44)
                        Divider().padding(.leading, 42)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 28)
    }
}

private struct FilesView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject
    @ObservedObject private var syncthing: FramoV5SyncthingService
    @State private var source: FileSource = .all
    @State private var selectedFileID: UUID?
    @State private var filterText = ""
    @State private var showInspector = false

    init(project: Binding<StudioProject>, syncthing: FramoV5SyncthingService) {
        _project = project
        _syncthing = ObservedObject(wrappedValue: syncthing)
    }

    private var experimentalRemoteEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "MODOEnableExperimentalRemoteConnect") as? Bool) == true
    }

    private enum FileSource: Hashable, Identifiable {
        case all, offline, remoteHost, frameIO
        case volume(String), folder(String), nearby(String), syncthing(String)

        var id: String {
            switch self {
            case .all: "all"
            case .offline: "offline"
            case .remoteHost: "remote"
            case .frameIO: "frameio"
            case .volume(let v): "volume-\(v)"
            case .folder(let v): "folder-\(v)"
            case .nearby(let v): "nearby-\(v)"
            case .syncthing(let v): "syncthing-\(v)"
            }
        }

        var title: String {
            switch self {
            case .all: "All files"
            case .offline: "Offline"
            case .remoteHost: "Remote MODO"
            case .frameIO: "Frame.io"
            case .volume(let value), .folder(let value), .nearby(let value), .syncthing(let value): value
            }
        }
    }

    private var linkedFiles: [LinkedProjectFile] { project.linkedFiles ?? [] }
    private var volumes: [String] { Array(Set(linkedFiles.map(\.volumeName).filter { !$0.isEmpty })).sorted() }
    private var folders: [String] { Array(Set(linkedFiles.map { URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent().lastPathComponent }.filter { !$0.isEmpty })).sorted() }

    private var localFilteredFiles: [LinkedProjectFile] {
        let base: [LinkedProjectFile]
        switch source {
        case .all: base = linkedFiles
        case .offline: base = linkedFiles.filter { !store.linkedFileIsAvailable($0) }
        case .volume(let value): base = linkedFiles.filter { $0.volumeName == value }
        case .folder(let value): base = linkedFiles.filter { URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent().lastPathComponent == value }
        default: base = []
        }
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty ? base : base.filter { [$0.displayName, $0.volumeName, $0.originalPath].joined(separator: " ").lowercased().contains(needle) }
    }

    private var selectedFile: LinkedProjectFile? {
        localFilteredFiles.first(where: { $0.id == selectedFileID }) ?? localFilteredFiles.first
    }

    var body: some View {
        VStack(spacing: 12) {
            fileToolbar

            HStack(spacing: 12) {
                fileSidebar
                    .frame(width: 218)
                    .background(StudioTheme.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.border.opacity(0.85)))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                sourceContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioTheme.elevated)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.border.opacity(0.85)))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if showInspector {
                    inspector
                        .frame(width: 258)
                        .background(StudioTheme.elevated)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.border.opacity(0.85)))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(18)
        .background(StudioTheme.canvas)
        .task {
            store.configureFramoV5SyncthingService()
            if store.isPluginEnabled("org.framo.syncthing") { await syncthing.refresh() }
            if selectedFileID == nil { selectedFileID = localFilteredFiles.first?.id }
        }
        .onChange(of: source) { _, _ in selectedFileID = localFilteredFiles.first?.id }
        .onChange(of: localFilteredFiles.map(\.id)) { _, ids in
            if let selectedFileID, ids.contains(selectedFileID) { return }
            self.selectedFileID = ids.first
        }
    }

    private var fileToolbar: some View {
        HStack(spacing: 9) {
            Text("Files").font(.system(size: 18, weight: .semibold))
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            Text(source.title).font(.system(size: 10, weight: .medium)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                TextField("Search", text: $filterText).textFieldStyle(.plain).studioTextCursor().font(.system(size: 10))
            }
            .padding(.horizontal, 9).frame(width: 190, height: 30)
            .background(StudioTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button("Link files…") { store.linkFiles(to: project.id) }.buttonStyle(PrimaryButtonStyle())
            Button { withAnimation(.easeOut(duration: 0.14)) { showInspector.toggle() } } label: {
                Image(systemName: "info.circle")
                    .frame(width: 30, height: 30)
                    .background(showInspector ? StudioTheme.selected : StudioTheme.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).studioPointerCursor().help("Toggle file details")
            Menu {
                Button("Sharing settings") { store.requestedSettingsPane = "Sharing"; store.openDestination(.settings) }
                Button("Refresh Syncthing") { store.refreshProjectSyncthing(project.id) }
                if experimentalRemoteEnabled, store.remoteAccess.manifest != nil { Button("Refresh remote host") { store.connectRemoteHost() } }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .background(StudioTheme.soft).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().studioPointerCursor()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.border.opacity(0.85)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fileSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                sidebarSection("LIBRARY")
                sourceRow(.all, symbol: "tray.full", count: linkedFiles.count)
                if linkedFiles.contains(where: { !store.linkedFileIsAvailable($0) }) {
                    sourceRow(.offline, symbol: "externaldrive.badge.xmark", count: linkedFiles.filter { !store.linkedFileIsAvailable($0) }.count)
                }

                if !volumes.isEmpty {
                    sidebarSection("LOCATIONS")
                    ForEach(volumes, id: \.self) { volume in
                        sourceRow(.volume(volume), symbol: "externaldrive", count: linkedFiles.filter { $0.volumeName == volume }.count)
                    }
                }

                if !folders.isEmpty {
                    sidebarSection("PROJECT FOLDERS")
                    ForEach(folders, id: \.self) { folder in
                        sourceRow(.folder(folder), symbol: "folder", count: linkedFiles.filter { URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent().lastPathComponent == folder }.count)
                    }
                }

                sidebarSection("CONNECTED")
                ForEach(store.localTransfer.connectedPeers, id: \.displayName) { peer in
                    sourceRow(.nearby(peer.displayName), symbol: "laptopcomputer.and.iphone", status: "Nearby")
                }
                if experimentalRemoteEnabled, store.remoteAccess.manifest != nil {
                    sourceRow(.remoteHost, symbol: "network", status: "Browse")
                }
                if store.isPluginEnabled("org.framo.syncthing") {
                    ForEach(syncthing.devices) { device in
                        sourceRow(.syncthing(device.name), symbol: "arrow.triangle.2.circlepath", status: device.connected ? "Online" : "Offline")
                    }
                }

                sidebarSection("REVIEW")
                sourceRow(.frameIO, symbol: "play.rectangle", status: project.frameIOURL == nil ? "Not linked" : "Ready")

                if store.localTransfer.connectedPeers.isEmpty &&
                    (!experimentalRemoteEnabled || store.remoteAccess.manifest == nil) &&
                    syncthing.devices.isEmpty {
                    Button("Connect devices…") {
                        store.requestedSettingsPane = "Connect"
                        store.openDestination(.settings)
                    }
                        .buttonStyle(.plain).studioPointerCursor()
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sidebarSection(_ title: String) -> some View {
        Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 4)
    }

    private func sourceRow(_ item: FileSource, symbol: String, count: Int? = nil, status: String? = nil) -> some View {
        Button { source = item } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 15)
                Text(item.title).lineLimit(1)
                Spacer()
                if let count { Text("\(count)").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary) }
                if let status { Text(status).font(.system(size: 7, weight: .medium)).foregroundStyle(StudioTheme.tertiary) }
            }
            .font(.system(size: 10, weight: source == item ? .semibold : .regular))
            .foregroundStyle(source == item ? StudioTheme.primary : StudioTheme.secondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(source == item ? StudioTheme.selected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 7)
        }
        .buttonStyle(.plain).studioPointerCursor()
    }

    @ViewBuilder private var sourceContent: some View {
        switch source {
        case .remoteHost: remoteBrowser
        case .nearby(let peer): nearbyBrowser(peer)
        case .syncthing(let device): syncthingBrowser(device)
        case .frameIO: frameIOBrowser
        default: localBrowser
        }
    }

    private var localBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if source == .all && (!folders.isEmpty || !volumes.isEmpty) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Folders").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text("\(volumes.count + folders.count)").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
                        }
                        structureShelf
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Files").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("\(localFilteredFiles.count) linked").font(.system(size: 8, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
                    }
                    fileTable
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var structureShelf: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(volumes, id: \.self) { volume in
                structureCard(.volume(volume), symbol: "externaldrive.fill", count: linkedFiles.filter { $0.volumeName == volume }.count)
            }
            ForEach(folders, id: \.self) { folder in
                structureCard(.folder(folder), symbol: "folder.fill", count: linkedFiles.filter { URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent().lastPathComponent == folder }.count)
            }
        }
    }

    private func structureCard(_ item: FileSource, symbol: String, count: Int) -> some View {
        Button { source = item } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(StudioTheme.soft).frame(width: 48, height: 48)
                    Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(StudioTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Text("\(count) file\(count == 1 ? "" : "s")").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(10).frame(maxWidth: .infinity, minHeight: 68)
            .background(StudioTheme.elevated)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.border.opacity(0.8)))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).studioPointerCursor()
    }

    private var fileTable: some View {
        VStack(spacing: 5) {
            if localFilteredFiles.isEmpty {
                Button { store.linkFiles(to: project.id) } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 23)).foregroundStyle(StudioTheme.tertiary)
                        Text("Link files or folders to this project").font(.system(size: 10, weight: .semibold))
                        Text("MODO keeps references to your original media.").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(StudioTheme.soft.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).studioPointerCursor()
            } else {
                ForEach(localFilteredFiles) { file in localFileRow(file) }
            }
        }
    }

    private func localFileRow(_ file: LinkedProjectFile) -> some View {
        let online = store.linkedFileIsAvailable(file)
        return Button { selectedFileID = file.id } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(online ? StudioTheme.soft : StudioTheme.red.opacity(0.1))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: fileIcon(file)).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Text(URL(fileURLWithPath: file.originalPath).deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 8)).foregroundStyle(online ? StudioTheme.tertiary : StudioTheme.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(file.volumeName).font(.system(size: 8)).foregroundStyle(StudioTheme.secondary).frame(width: 130, alignment: .leading).lineLimit(1)
                Text(file.sizeLabel).font(.system(size: 8)).foregroundStyle(StudioTheme.secondary).frame(width: 90, alignment: .trailing)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 8).frame(height: 50)
            .background(selectedFileID == file.id ? StudioTheme.selected : StudioTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).studioPointerCursor()
        .contextMenu { fileContextMenu(file) }
    }

    @ViewBuilder private func fileContextMenu(_ file: LinkedProjectFile) -> some View {
        Button("Open") { store.openLinkedFile(file) }.disabled(!store.linkedFileIsAvailable(file))
        Button("Reveal in Finder") { store.revealLinkedFile(file) }.disabled(!store.linkedFileIsAvailable(file))
        let pluginActions = store.pluginActions(target: .linkedFile, fileExtension: URL(fileURLWithPath: file.displayName).pathExtension)
        if !pluginActions.isEmpty {
            Divider()
            Menu("Plugins") {
                ForEach(pluginActions) { registered in Button(registered.action.label) { store.runPluginAction(registered, projectID: project.id, linkedFileID: file.id) } }
            }
        }
        Divider()
        Button("Remove link", role: .destructive) { store.removeLinkedFile(file.id, from: project.id) }
    }

    private func fileIcon(_ file: LinkedProjectFile) -> String {
        let ext = URL(fileURLWithPath: file.displayName).pathExtension.lowercased()
        if ["mov","mp4","mxf","mkv"].contains(ext) { return "film" }
        if ["wav","mp3","aif","aiff"].contains(ext) { return "waveform" }
        if ["jpg","jpeg","png","tif","tiff","heic"].contains(ext) { return "photo" }
        if ["pdf"].contains(ext) { return "doc.richtext" }
        return "doc"
    }

    private func nearbyBrowser(_ peer: String) -> some View {
        let target = store.localTransfer.connectedPeers.first(where: { $0.displayName == peer })
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer).font(.system(size: 18, weight: .semibold))
                        Text("Nearby MODO device").font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Button("Sharing settings") { store.requestedSettingsPane = "Sharing"; store.openDestination(.settings) }.buttonStyle(SecondaryButtonStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Send project files").font(.system(size: 12, weight: .semibold))
                    if linkedFiles.isEmpty {
                        Text("Link files to this project first.").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    } else {
                        ForEach(linkedFiles) { file in
                            HStack(spacing: 9) {
                                Image(systemName: fileIcon(file)).frame(width: 20).foregroundStyle(StudioTheme.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.displayName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    Text(file.sizeLabel).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                                }
                                Spacer()
                                Button("Send") {
                                    if let target { store.sendLinkedFile(file, to: target) }
                                }
                                .buttonStyle(SecondaryButtonStyle()).disabled(target == nil || !store.linkedFileIsAvailable(file))
                            }
                            .padding(10).background(StudioTheme.elevated).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Browse files on another Mac").font(.system(size: 11, weight: .semibold))
                    Text("Enable MODO Host on that device, then it appears as Remote MODO in this sidebar. Remote files can be downloaded and linked directly to this work.")
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).background(StudioTheme.soft.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .padding(20)
        }
    }

    private func syncthingBrowser(_ device: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device).font(.system(size: 18, weight: .semibold))
                    Text(syncthing.status).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button("Refresh") { store.refreshProjectSyncthing(project.id) }.buttonStyle(SecondaryButtonStyle())
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project sync root").font(.system(size: 11, weight: .semibold))
                    Text(project.syncthingFolderPath ?? "Not configured").font(.system(size: 9, design: .monospaced)).foregroundStyle(StudioTheme.tertiary)
                    HStack {
                        Button(project.syncthingFolderPath == nil ? "Choose folder…" : "Change folder…") { store.chooseSyncthingRoot(for: project.id) }.buttonStyle(SecondaryButtonStyle())
                        Button(project.syncthingFolderID == nil ? "Start sync" : "Update sync") { store.configureProjectSyncthing(project.id) }.buttonStyle(PrimaryButtonStyle()).disabled(project.syncthingFolderPath == nil)
                    }
                }.padding(16)
            }
            Spacer()
        }
        .padding(20)
    }

    private var remoteBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.remoteAccess.manifest?.workspaceName ?? "Remote MODO").font(.system(size: 14, weight: .semibold))
                    Text(store.remoteAccess.status).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }
                Spacer()
                Button("Refresh") { store.connectRemoteHost() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 16).frame(height: 52)
            Divider()
            if let manifest = store.remoteAccess.manifest {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(manifest.items) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.kind == .workspace ? "shippingbox" : "doc").frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    Text([item.projectTitle, item.volumeName, item.sizeLabel].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                }
                                Spacer()
                                if item.kind == .linkedFile {
                                    Button("Download & link") { store.downloadRemoteItemAndLink(item, to: project.id) }.buttonStyle(PrimaryButtonStyle())
                                } else {
                                    Button("Download") { store.downloadRemoteItem(item) }.buttonStyle(SecondaryButtonStyle())
                                }
                            }
                            .padding(10).background(StudioTheme.elevated).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(10)
                }
            } else {
                connectionEmptyState(title: "No remote host", symbol: "network.slash", body: "Connect to a MODO Host in Connect settings, then browse and link its files here.") {
                    store.requestedSettingsPane = "Sharing"; store.openDestination(.settings)
                }
            }
        }
    }

    private var frameIOBrowser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Frame.io").font(.system(size: 18, weight: .semibold))
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    fileLinkRow("Project / review", text: optionalBinding(\.frameIOURL), value: project.frameIOURL)
                    fileLinkRow("Client share", text: optionalBinding(\.clientShareURL), value: project.clientShareURL)
                }.padding(16)
            }
            Spacer()
        }.padding(20)
    }

    private func fileLinkRow(_ label: String, text: Binding<String>, value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).frame(width: 110, alignment: .leading)
            TextField("Paste link", text: text).textFieldStyle(.plain).studioEditableSurface().studioTextCursor()
            Button { copy(value ?? "") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(IconButtonStyle())
            Button { open(value ?? "") } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(IconButtonStyle())
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Inspector").font(.system(size: 11, weight: .semibold)); Spacer() }
                .padding(.horizontal, 14).frame(height: 44)
            Divider()
            if let file = selectedFile, isLocalSource {
                ScrollView { fileInspector(file).padding(14) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: inspectorSymbol).font(.system(size: 24)).foregroundStyle(StudioTheme.tertiary)
                    Text(source.title).font(.system(size: 12, weight: .semibold))
                    Text(inspectorMessage).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(StudioTheme.soft.opacity(0.35))
    }

    private var isLocalSource: Bool {
        switch source { case .all, .offline, .volume(_), .folder(_): true; default: false }
    }
    private var inspectorSymbol: String {
        switch source { case .remoteHost: "network"; case .nearby(_): "laptopcomputer.and.iphone"; case .syncthing(_): "arrow.triangle.2.circlepath"; case .frameIO: "play.rectangle"; default: "doc" }
    }
    private var inspectorMessage: String {
        switch source {
        case .remoteHost: "Browse another MODO workspace and download files directly into this work."
        case .nearby(_): "Nearby transfer is direct peer-to-peer. MODO Host adds browseable remote files."
        case .syncthing(_): "Syncthing keeps the selected project folder replicated between devices."
        case .frameIO: "Keep review and client delivery links with the project."
        default: "Select a file to inspect it."
        }
    }

    private func fileInspector(_ file: LinkedProjectFile) -> some View {
        let online = store.linkedFileIsAvailable(file)
        return VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 12).fill(online ? StudioTheme.elevated : StudioTheme.red.opacity(0.08))
                .frame(height: 104)
                .overlay(Image(systemName: fileIcon(file)).font(.system(size: 30)).foregroundStyle(StudioTheme.secondary))
            inspectorValue("Name", file.displayName)
            inspectorValue("Drive", file.volumeName)
            inspectorValue("Folder", URL(fileURLWithPath: file.originalPath).deletingLastPathComponent().lastPathComponent)
            inspectorValue("Size", file.sizeLabel)
            inspectorValue("Status", online ? "Online" : "Drive offline")
            HStack {
                Button("Open") { store.openLinkedFile(file) }.buttonStyle(PrimaryButtonStyle()).disabled(!online)
                Button("Reveal") { store.revealLinkedFile(file) }.buttonStyle(SecondaryButtonStyle()).disabled(!online)
            }
            Menu("Plugins") {
                let actions = store.pluginActions(target: .linkedFile, fileExtension: URL(fileURLWithPath: file.displayName).pathExtension)
                if actions.isEmpty { Button("No file plugins installed") { }.disabled(true) }
                ForEach(actions) { registered in Button(registered.action.label) { store.runPluginAction(registered, projectID: project.id, linkedFileID: file.id) } }
            }
            .menuStyle(.borderlessButton).buttonStyle(SecondaryButtonStyle())
        }
    }

    private func inspectorValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            Text(value).font(.system(size: 10)).textSelection(.enabled)
        }
    }

    private func connectionEmptyState(title: String, symbol: String, body: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(StudioTheme.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(body).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Open Sharing") { action() }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<StudioProject, String?>) -> Binding<String> {
        Binding(get: { project[keyPath: keyPath] ?? "" }, set: { project[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func open(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { return }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"; if let url = URL(string: normalized) { NSWorkspace.shared.open(url) }
    }
}

private struct DeliveryView: View {
    @Binding var project: StudioProject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delivery").font(.system(size: 25, weight: .semibold))
            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    deliveryField("Deliverables", text: $project.deliverable)

                    if project.effectiveWorkType == .creativeProduction {
                        deliveryField("Aspect ratio", text: $project.aspectRatio)
                        deliveryField("Resolution", text: $project.resolution)
                        deliveryField("Editing software", text: $project.editingSoftware)
                    } else {
                        HStack {
                            Text("Work type")
                                .foregroundStyle(StudioTheme.secondary)
                                .frame(width: 145, alignment: .leading)
                            Text(project.effectiveWorkType.rawValue)
                                .fontWeight(.medium)
                        }
                        .font(.system(size: 10))
                    }

                    Divider()
                    HStack {
                        Image(systemName: "link").foregroundStyle(StudioTheme.secondary)
                        Text("Client share").foregroundStyle(StudioTheme.secondary).frame(width: 120, alignment: .leading)
                        TextField("Frame.io share or delivery URL", text: Binding(get: { project.clientShareURL ?? "" }, set: { project.clientShareURL = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.plain).studioTextCursor().fontWeight(.medium)
                    }.font(.system(size: 10))
                }
                .padding(16)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.vertical, 28)
    }

    private func deliveryField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).foregroundStyle(StudioTheme.secondary).frame(width: 145, alignment: .leading)
            TextField(label, text: text).textFieldStyle(.plain).studioTextCursor().fontWeight(.medium)
        }.font(.system(size: 10))
    }
}

private struct TimeLogView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var project: StudioProject
    @State private var hourlyRateText = ""
    @State private var fixedFeeText = ""

    private var total: TimeInterval { store.loggedSeconds(for: project, includingActive: true) }
    private var totalLabel: String { duration(total) }
    private var rate: Double { store.effectiveHourlyRate(for: project) }
    private var value: Double { store.trackedValue(for: project) }
    private var balance: Double? { store.fixedFeeBalance(for: project) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Time").font(.system(size: 25, weight: .semibold))
                        Text("Track focused work without keeping MODO in front.")
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Button(store.activeTimerProjectID == project.id ? "Stop" : "Start timer") {
                        store.activeTimerProjectID == project.id ? store.stopTimer() : store.startTimer(for: project.id)
                    }.buttonStyle(PrimaryButtonStyle())
                }

                HStack(spacing: 10) {
                    metric("Tracked", value: totalLabel)
                    metric("Value", value: value.formatted(.currency(code: store.settings.currency)))
                    metric("Rate", value: rate.formatted(.currency(code: store.settings.currency)) + "/h")
                    if let balance {
                        metric(balance >= 0 ? "Budget left" : "Over budget", value: abs(balance).formatted(.currency(code: store.settings.currency)), warning: balance < 0)
                    }
                }

                StudioCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Project pricing").font(.system(size: 11, weight: .semibold))
                        HStack(spacing: 12) {
                            pricingField("Hourly rate", text: $hourlyRateText, placeholder: "Default \(Int(store.settings.defaultRate))")
                            pricingField("Fixed fee / budget", text: $fixedFeeText, placeholder: "Optional")
                            Button("Save") { savePricing() }.buttonStyle(SecondaryButtonStyle())
                        }
                        Text("With a fixed fee, MODO shows how much of the work budget is left. Without one, it simply shows the value of tracked billable time.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    .padding(14)
                }

                StudioCard {
                    VStack(spacing: 0) {
                        ForEach(project.timeEntries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: "clock").foregroundStyle(StudioTheme.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).fontWeight(.medium)
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(StudioTheme.secondary)
                                }
                                Spacer()
                                Text(duration(entry.seconds)).fontWeight(.medium)
                                Text(entry.billable ? "Billable" : "Non-billable")
                                    .foregroundStyle(StudioTheme.secondary).frame(width: 80, alignment: .trailing)
                            }
                            .font(.system(size: 10)).padding(13)
                            .contextMenu {
                                Button("Delete entry", role: .destructive) {
                                    project.timeEntries.removeAll { $0.id == entry.id }
                                }
                            }
                            Divider().padding(.leading, 40)
                        }
                        if project.timeEntries.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "timer").foregroundStyle(StudioTheme.tertiary)
                                Text("No time logged yet").font(.system(size: 10, weight: .medium))
                                Text("Press ⌘F anywhere on your Mac and choose this project.")
                                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                            }
                            .padding(28).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 28)
        }
        .onAppear { loadPricing() }
        .onChange(of: project.id) { _, _ in loadPricing() }
    }

    private func metric(_ title: String, value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 7, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(warning ? StudioTheme.red : StudioTheme.primary)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(StudioTheme.elevated)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pricingField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 7, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).studioTextCursor()
                .padding(.horizontal, 9).frame(height: 32)
                .background(StudioTheme.input)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPricing() {
        hourlyRateText = project.hourlyRate.map { String(format: "%.2f", $0) } ?? ""
        fixedFeeText = project.fixedFee.map { String(format: "%.2f", $0) } ?? ""
    }

    private func savePricing() {
        project.hourlyRate = parseMoney(hourlyRateText)
        project.fixedFee = parseMoney(fixedFeeText)
        store.updateProject(project)
    }

    private func parseMoney(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        return String(format: "%dm", total / 60)
    }
}

private extension Text {
    func sectionMicroLabel() -> some View {
        self.font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
    }
}

private extension Binding {
    init?(_ base: Binding<Value?>) {
        guard let value = base.wrappedValue else { return nil }
        self.init(get: { base.wrappedValue ?? value }, set: { base.wrappedValue = $0 })
    }
}
