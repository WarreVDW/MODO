import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var showingTaskComposer = false

    private var openTasks: [StudioTask] {
        store.tasks.filter { !$0.isComplete }
    }

    private var upcomingEvents: [StudioEvent] {
        store.calendarItems
            .filter { $0.date >= Calendar.current.startOfDay(for: .now) }
            .sorted { $0.date < $1.date }
    }

    private var activeProjects: [StudioProject] {
        store.projects.filter { $0.status != .delivered }
    }

    private var overdueCount: Int {
        let today = Calendar.current.startOfDay(for: .now)
        return openTasks.filter { ($0.dueDate ?? .distantFuture) < today }.count
    }

    private var todayTaskCount: Int {
        openTasks.filter { $0.dueDate.map(Calendar.current.isDateInToday) ?? false }.count
    }

    private var eventsThisWeek: Int {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        return upcomingEvents.filter { $0.date <= end }.count
    }

    private var deliveredCount: Int {
        store.projects.filter { $0.status == .delivered }.count
    }

    private var openOpportunities: [ModoOpportunity] {
        store.business.opportunities.filter { ![.won, .lost].contains($0.stage) }
    }

    private var openQuotes: [ModoQuote] {
        store.business.quotes.filter { [.draft, .sent].contains($0.status) }
    }

    private var overdueInvoices: [ModoInvoice] {
        store.invoices.filter { invoice in
            ![.paid, .voided, .credited].contains(invoice.status) && invoice.dueDate < Calendar.current.startOfDay(for: .now)
        }
    }

    private var mode: ModoWorkspaceMode { store.settings.effectiveWorkspaceMode }

    private func enabled(_ destination: SidebarDestination) -> Bool {
        store.isDestinationEnabled(destination)
    }

    private struct FocusItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let value: String
        let destination: SidebarDestination
        let projectID: UUID?
        let warning: Bool
    }

    private var focusItems: [FocusItem] {
        var items: [FocusItem] = []

        if enabled(.tasks), let task = openTasks
            .filter({ ($0.dueDate ?? .distantFuture) <= Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now })
            .sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) })
            .first {
            let overdue = (task.dueDate ?? .distantFuture) < Calendar.current.startOfDay(for: .now)
            items.append(FocusItem(
                id: "task-\(task.id)",
                title: overdue ? "Overdue task" : "Task to finish",
                detail: task.title,
                value: task.dueDate?.shortStudioDate ?? "Today",
                destination: .tasks,
                projectID: task.projectID,
                warning: overdue
            ))
        }

        if enabled(.calendar), let event = upcomingEvents.first {
            items.append(FocusItem(
                id: "event-\(event.id)",
                title: "Next on your calendar",
                detail: event.title,
                value: event.date.formatted(date: .omitted, time: .shortened),
                destination: .calendar,
                projectID: event.projectID,
                warning: false
            ))
        }

        if enabled(.sales), let opportunity = store.opportunitiesNeedingFollowUp.first {
            items.append(FocusItem(
                id: "sales-\(opportunity.id)",
                title: "Follow up",
                detail: opportunity.nextAction.isEmpty ? opportunity.title : opportunity.nextAction,
                value: "Sales",
                destination: .sales,
                projectID: nil,
                warning: true
            ))
        }

        if enabled(.finance), let invoice = overdueInvoices.sorted(by: { $0.dueDate < $1.dueDate }).first {
            items.append(FocusItem(
                id: "invoice-\(invoice.id)",
                title: "Payment overdue",
                detail: invoice.customerName.isEmpty ? invoice.invoiceNumber : invoice.customerName,
                value: invoice.total.formatted(.currency(code: invoice.currency)),
                destination: .finance,
                projectID: invoice.projectID,
                warning: true
            ))
        }

        if enabled(.projects), let project = activeProjects.sorted(by: { $0.dueDate < $1.dueDate }).first {
            items.append(FocusItem(
                id: "project-\(project.id)",
                title: "Closest work deadline",
                detail: project.title,
                value: project.dueDate.shortStudioDate,
                destination: .projects,
                projectID: project.id,
                warning: project.dueDate < Calendar.current.startOfDay(for: .now)
            ))
        }

        return Array(items.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                if mode == .focus {
                    focusSection
                } else {
                    overview

                    if mode == .business || mode == .finance {
                        if enabled(.sales) || enabled(.finance) { businessFlow }
                    }

                    if enabled(.projects) && mode != .finance { continueSection }

                    if mode == .production || mode == .studio {
                        if enabled(.projects) { productionReadiness }
                        if enabled(.calendar) || enabled(.tasks) { workSection }
                        if enabled(.projects) { projectPulse }
                    } else if mode == .business {
                        if enabled(.tasks) || enabled(.calendar) { workSection }
                    } else if mode == .finance {
                        if enabled(.finance) || enabled(.sales) { financeAttention }
                    }

                    if mode == .studio && (enabled(.sales) || enabled(.finance)) {
                        businessFlow
                    }

                    if mode != .finance { activitySection }
                }
            }
            .frame(maxWidth: 1240)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 52)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Today")
                    .font(.system(size: 30, weight: .semibold))
                Text(greeting)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Search") { store.showGlobalSearch = true }
                    .buttonStyle(SecondaryButtonStyle())
                Menu("New") {
                    if enabled(.customers) {
                        Button("Customer") { store.openDestination(.customers) }
                    }
                    if enabled(.sales) {
                        Button("Opportunity") {
                            _ = store.createOpportunity(customerID: store.business.organizations.first?.id, title: "New opportunity")
                            store.openDestination(.sales)
                        }
                        Button("Quote") {
                            _ = store.createQuote(customerID: store.business.organizations.first?.id)
                            store.openDestination(.sales)
                        }
                    }
                    if enabled(.projects) || enabled(.tasks) { Divider() }
                    if enabled(.projects) {
                        Button("Work") { store.requestProjectCreation() }
                    }
                    if enabled(.tasks) {
                        Button("Task") { store.quickAddTask() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(mode == .finance ? "Money at a glance" : "Overview", detail: todayLine)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                if mode == .finance, enabled(.finance) {
                    metricButton(destination: .finance) {
                        HomeMetricTile(
                            title: "Outstanding",
                            value: store.outstandingInvoiceTotal.formatted(.currency(code: store.settings.currency)),
                            detail: overdueInvoices.isEmpty ? "No overdue invoices" : "\(overdueInvoices.count) overdue",
                            prominence: .small,
                            warning: !overdueInvoices.isEmpty
                        )
                    }
                }

                if enabled(.projects) {
                    metricButton(destination: .projects) {
                        HomeMetricTile(title: "Active work", value: "\(activeProjects.count)", detail: nextProjectDetail, prominence: .small)
                    }
                }

                if enabled(.sales) {
                    metricButton(destination: .sales) {
                        HomeMetricTile(title: "Open quotes", value: "\(openQuotes.count)", detail: store.openQuoteTotal.formatted(.currency(code: store.settings.currency)), prominence: .small)
                    }
                }

                if enabled(.customers) {
                    metricButton(destination: .customers) {
                        HomeMetricTile(title: "Customers", value: "\(store.business.organizations.count)", detail: "\(openOpportunities.count) open opportunities", prominence: .small)
                    }
                }

                if enabled(.tasks) {
                    metricButton(destination: .tasks) {
                        HomeMetricTile(title: "Open tasks", value: "\(openTasks.count)", detail: "\(todayTaskCount) due today", prominence: .small, warning: overdueCount > 0)
                    }
                }

                if enabled(.calendar) {
                    metricButton(destination: .calendar) {
                        HomeMetricTile(title: "Next 7 days", value: "\(eventsThisWeek)", detail: upcomingEvents.first?.title ?? "Nothing scheduled", prominence: .small)
                    }
                }

                if mode != .finance, enabled(.finance) {
                    metricButton(destination: .finance) {
                        HomeMetricTile(
                            title: "Outstanding",
                            value: store.outstandingInvoiceTotal.formatted(.currency(code: store.settings.currency)),
                            detail: overdueInvoices.isEmpty ? "No overdue invoices" : "\(overdueInvoices.count) overdue",
                            prominence: .small,
                            warning: !overdueInvoices.isEmpty
                        )
                    }
                }
            }
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("What needs you now", detail: "Focus mode keeps Today to three things")

            if focusItems.isEmpty {
                HomeEmptyState(title: "Nothing urgent", detail: "You are clear for now.")
                    .frame(height: 140)
            } else {
                VStack(spacing: 8) {
                    ForEach(focusItems) { item in
                        Button {
                            if let projectID = item.projectID, item.destination == .projects {
                                store.openProject(projectID)
                            } else {
                                store.openDestination(item.destination)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(StudioTheme.secondary)
                                    Text(item.detail)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(StudioTheme.primary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(item.value)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(item.warning ? StudioTheme.red : StudioTheme.secondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(StudioTheme.soft.opacity(0.58))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .studioPointerCursor()
                    }
                }
            }
        }
    }

    private var financeAttention: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Cash attention", detail: "Only commercial follow-up, not accounting")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                if enabled(.finance) {
                    attentionCard(
                        title: "Overdue invoices",
                        value: "\(overdueInvoices.count)",
                        detail: overdueInvoices.isEmpty ? "Nothing overdue" : "Follow up on payment",
                        destination: .finance,
                        warning: !overdueInvoices.isEmpty
                    )
                }
                if enabled(.sales) {
                    attentionCard(
                        title: "Quotes waiting",
                        value: "\(openQuotes.filter { $0.status == .sent }.count)",
                        detail: "Keep proposals moving",
                        destination: .sales,
                        warning: false
                    )
                }
            }
        }
    }

    private var businessFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Needs attention", detail: "Follow-up across the modules you enabled")
                Spacer()
                if enabled(.sales) {
                    Button("Open sales") { store.openDestination(.sales) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .studioPointerCursor()
                } else if enabled(.finance) {
                    Button("Open money") { store.openDestination(.finance) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .studioPointerCursor()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                if enabled(.sales) {
                    attentionCard(
                        title: "Customer follow-up",
                        value: "\(store.opportunitiesNeedingFollowUp.count)",
                        detail: store.opportunitiesNeedingFollowUp.first?.nextAction.isEmpty == false ? (store.opportunitiesNeedingFollowUp.first?.nextAction ?? "") : "Nothing due today",
                        destination: .sales,
                        warning: !store.opportunitiesNeedingFollowUp.isEmpty
                    )
                    attentionCard(
                        title: "Quotes waiting",
                        value: "\(openQuotes.filter { $0.status == .sent }.count)",
                        detail: openQuotes.filter { $0.status == .sent }.isEmpty ? "No proposals waiting" : "Follow up before they go cold",
                        destination: .sales,
                        warning: false
                    )
                }

                if enabled(.finance) {
                    attentionCard(
                        title: "Overdue invoices",
                        value: "\(overdueInvoices.count)",
                        detail: overdueInvoices.isEmpty ? "Cash is up to date" : "Needs payment follow-up",
                        destination: .finance,
                        warning: !overdueInvoices.isEmpty
                    )
                }
            }
        }
    }


    private var productionReadiness: some View {
        let candidates = activeProjects
            .filter { [.creativeProduction, .event].contains($0.effectiveWorkType) }
            .sorted { $0.dueDate < $1.dueDate }
        let warnings = candidates.compactMap { project -> (StudioProject, String)? in
            if project.effectiveWorkType == .creativeProduction {
                if project.shots.isEmpty { return (project, "Shot list is still empty") }
                if project.crew.isEmpty { return (project, "No people assigned yet") }
                if project.kit.isEmpty { return (project, "No kit prepared yet") }
            } else if project.effectiveWorkType == .event {
                if project.crew.isEmpty { return (project, "No people assigned yet") }
            }
            return nil
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Production readiness", detail: warnings.isEmpty ? "Upcoming work is prepared" : "Missing setup before the next deadline")
                Spacer()
                if let first = warnings.first {
                    Button("Open work") { store.openProject(first.0.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .studioPointerCursor()
                }
            }

            if warnings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StudioTheme.green)
                    Text(candidates.isEmpty ? "No production work needs setup right now." : "No obvious production setup gaps in your closest active work.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(StudioTheme.soft.opacity(0.42))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                    ForEach(Array(warnings.prefix(4).enumerated()), id: \.element.0.id) { _, item in
                        Button { store.openProject(item.0.id) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(StudioTheme.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.0.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text(item.1).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                }
                                Spacer()
                                Text(item.0.dueDate.shortStudioDate)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(StudioTheme.secondary)
                            }
                            .foregroundStyle(StudioTheme.primary)
                            .padding(.horizontal, 13)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(StudioTheme.soft.opacity(0.56))
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .studioPointerCursor()
                    }
                }
            }
        }
    }

    private func attentionCard(title: String, value: String, detail: String, destination: SidebarDestination, warning: Bool) -> some View {
        Button { store.openDestination(destination) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
                    Text(detail).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                Spacer()
                Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(warning ? StudioTheme.red : StudioTheme.primary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(StudioTheme.soft.opacity(0.60))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).studioPointerCursor()
    }

    private func metricButton<Content: View>(destination: SidebarDestination, @ViewBuilder content: () -> Content) -> some View {
        Button { store.openDestination(destination) } label: { content() }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .studioPointerCursor()
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Continue", detail: "Recent work")
                Spacer()
                Button("View all") { store.openDestination(.projects) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
                    .studioPointerCursor()
            }

            if store.projects.isEmpty {
                HomeEmptyState(title: "No work yet", detail: "Create your first job and it will stay close here.")
                    .frame(height: 130)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.projects.prefix(10)) { project in
                            ProjectCard(project: project)
                                .frame(width: 278)
                                .onTapGesture { store.openProject(project.id) }
                                .studioPointerCursor()
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private var workSection: some View {
        if enabled(.calendar) && enabled(.tasks) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    upcomingColumn.frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                    tasksColumn.frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 26) {
                    upcomingColumn
                    tasksColumn
                }
            }
        } else if enabled(.calendar) {
            upcomingColumn
        } else if enabled(.tasks) {
            tasksColumn
        }
    }

    private var upcomingColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Upcoming", detail: "Calendar")
                Spacer()
                Button("Open calendar") { store.openDestination(.calendar) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
                    .studioPointerCursor()
            }

            VStack(spacing: 6) {
                ForEach(upcomingEvents.prefix(6)) { event in
                    EventRow(event: event)
                }
                if upcomingEvents.isEmpty {
                    HomeEmptyState(title: "Nothing scheduled", detail: "Your next plan will appear here.")
                }
            }
        }
    }

    private var tasksColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Tasks", detail: "What needs attention")
                Spacer()
                Button("Add task") { showingTaskComposer.toggle() }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $showingTaskComposer, arrowEdge: .top) {
                        QuickTaskComposer(showing: $showingTaskComposer)
                            .environmentObject(store)
                    }
            }

            VStack(spacing: 6) {
                ForEach(openTasks.prefix(7)) { task in
                    TaskRow(task: task)
                }
                if openTasks.isEmpty {
                    HomeEmptyState(title: "Everything is cleared", detail: "New work will appear here.")
                }
            }
        }
    }

    private var projectPulse: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Work pulse", detail: "Closest deadlines")
                Spacer()
                quickActions
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                ForEach(activeProjects.sorted { $0.dueDate < $1.dueDate }.prefix(6)) { project in
                    Button { store.openProject(project.id) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(project.status.displayName(for: project.effectiveWorkType))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(StudioTheme.secondary)
                                Spacer()
                                Text(project.dueDate.shortStudioDate)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text(project.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                            Text(project.client)
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 3)
                            ProgressView(value: projectProgress(project))
                                .tint(Color(hex: project.colorHex))
                                .controlSize(.mini)
                        }
                        .foregroundStyle(StudioTheme.primary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: 124, alignment: .topLeading)
                        .background(StudioTheme.soft.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Activity", detail: "What changed recently")
            VStack(spacing: 4) {
                ForEach(visibleActivity.sorted { $0.date > $1.date }.prefix(8)) { entry in
                    HStack(spacing: 10) {
                        Circle().fill(StudioTheme.tertiary).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Text("\(entry.actor) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                        }
                        Spacer()
                        Text(entry.source.rawValue).font(.system(size: 8, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
                    }
                    .padding(.horizontal, 10).frame(height: 42)
                }
                if visibleActivity.isEmpty {
                    HomeEmptyState(title: "No activity yet", detail: "Changes from your enabled modules will appear here.")
                }
            }
        }
    }

    private var visibleActivity: [ModoActivityEntry] {
        store.business.activities.filter { entry in
            switch entry.recordType.lowercased() {
            case "customer", "person": return enabled(.customers)
            case "opportunity", "quote": return enabled(.sales)
            case "invoice", "payment": return enabled(.finance)
            case "project", "work", "file", "time": return enabled(.projects)
            case "task": return enabled(.tasks)
            case "event", "calendar": return enabled(.calendar)
            case "place", "location": return enabled(.places)
            case "crew", "resource", "device": return enabled(.resources)
            default: return true
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            if enabled(.customers) { Button("Customer") { store.openDestination(.customers) } }
            if enabled(.sales) { Button("Quote") { store.openDestination(.sales) } }
            if enabled(.calendar) { Button("Plan") { store.openDestination(.calendar) } }
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part: String
        switch hour {
        case 0..<5: part = "Good night"
        case 5..<12: part = "Good morning"
        case 12..<18: part = "Good afternoon"
        default: part = "Good evening"
        }
        let firstName = store.settings.ownerName.split(separator: " ").first.map(String.init) ?? store.settings.ownerName
        return firstName.isEmpty ? part : "\(part), \(firstName)"
    }

    private var todayLine: String {
        Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private var nextProjectDetail: String {
        guard let project = activeProjects.min(by: { $0.dueDate < $1.dueDate }) else { return "No active deadlines" }
        return "Next · \(project.title) · \(project.dueDate.shortStudioDate)"
    }

    private func projectProgress(_ project: StudioProject) -> Double {
        let items = store.tasks.filter { $0.projectID == project.id }
        guard !items.isEmpty else { return 0 }
        return Double(items.filter(\.isComplete).count) / Double(items.count)
    }
}

private struct HomeMetricTile: View {
    enum Prominence { case large, small }
    let title: String
    let value: String
    let detail: String
    let prominence: Prominence
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominence == .large ? 12 : 6) {
            Text(title)
                .font(.system(size: prominence == .large ? 12 : 10, weight: .medium))
                .foregroundStyle(StudioTheme.secondary)
            Text(value)
                .font(.system(size: prominence == .large ? 36 : 23, weight: .semibold, design: .rounded))
                .foregroundStyle(warning ? StudioTheme.red : StudioTheme.primary)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioTheme.tertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(prominence == .large ? 18 : 14)
        .frame(maxWidth: .infinity, minHeight: prominence == .large ? 156 : 72, alignment: .topLeading)
        .background(StudioTheme.soft.opacity(prominence == .large ? 0.85 : 0.60))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HomeEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(14)
        .background(StudioTheme.soft.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ProjectCard: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var hovering = false
    let project: StudioProject

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ProjectBanner(
                path: project.bannerPath,
                assetName: project.bannerAssetName,
                colorHex: project.colorHex,
                height: 206,
                focusY: project.effectiveBannerFocusY
            )
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.30),
                        .init(color: Color.black.opacity(0.16), location: 0.54),
                        .init(color: Color.black.opacity(0.78), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text(project.status.displayName(for: project.effectiveWorkType))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(.black.opacity(0.30), in: Capsule())

                    Spacer()

                    Text(project.dueDate.shortStudioDate)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(.black.opacity(0.24), in: Capsule())
                }

                Spacer(minLength: 32)

                Text(project.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !project.client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(project.client)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .padding(.top, 4)
                }
            }
            .padding(14)
        }
        .frame(height: 206)
        .background(StudioTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(hovering ? 0.15 : 0.07), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(hovering ? 0.22 : 0.12), radius: hovering ? 18 : 10, y: hovering ? 8 : 4)
        .scaleEffect(hovering ? 1.012 : 1)
        .offset(y: hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open work") { store.openProject(project.id) }
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

private struct QuickTaskComposer: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var showing: Bool
    @State private var title = ""
    @State private var projectID: UUID?
    @State private var hasDueDate = true
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New task").font(.system(size: 16, weight: .semibold))

            TextField("What needs to happen?", text: $title)
                .textFieldStyle(.plain)
                .studioTextCursor()
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 9))

            HStack {
                Text("Work").foregroundStyle(StudioTheme.secondary)
                Spacer()
                Picker("", selection: $projectID) {
                    Text("No work").tag(UUID?.none)
                    ForEach(store.projects) { project in
                        Text(project.title).tag(Optional(project.id))
                    }
                }
                .labelsHidden().frame(width: 190)
            }
            .font(.system(size: 11))

            Toggle("Due date", isOn: $hasDueDate)
                .font(.system(size: 11))
            if hasDueDate {
                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }

            HStack {
                Button("Cancel") { showing = false }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Add task") {
                    store.addTask(title: title, dueDate: hasDueDate ? dueDate : nil, projectID: projectID)
                    showing = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(StudioTheme.elevated)
    }
}

private struct EventRow: View {
    @EnvironmentObject private var store: FramoStudioStore
    let event: StudioEvent

    private var project: StudioProject? {
        event.projectID.flatMap { id in store.projects.first(where: { $0.id == id }) }
    }

    var body: some View {
        Button {
            if let id = event.projectID { store.openProject(id) }
            else { store.openDestination(.calendar) }
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: event.colorHex))
                    .frame(width: 4, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(eventSubtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 55)
            .background(StudioTheme.soft.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
    }

    private var eventSubtitle: String {
        var parts: [String] = [event.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))]
        if let project { parts.append(project.title) }
        else if !event.location.isEmpty { parts.append(event.location) }
        return parts.joined(separator: " · ")
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: FramoStudioStore
    let task: StudioTask
    @State private var showingDuePicker = false

    private var project: StudioProject? {
        task.projectID.flatMap { id in store.projects.first(where: { $0.id == id }) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { store.toggleTask(task.id) } label: {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(task.isComplete ? StudioTheme.green : StudioTheme.secondary)
            }
            .buttonStyle(.plain).studioPointerCursor()

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 11, weight: .medium))
                    .strikethrough(task.isComplete)
                    .foregroundStyle(task.isComplete ? StudioTheme.tertiary : StudioTheme.primary)
                    .lineLimit(1)
                if let project {
                    Text(project.title)
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()

            Button { showingDuePicker.toggle() } label: {
                Text(task.dueDate?.shortStudioDate ?? "No date")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(task.dueDate == nil ? StudioTheme.tertiary : StudioTheme.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(StudioTheme.selected.opacity(0.7))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain).studioPointerCursor()
            .popover(isPresented: $showingDuePicker) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Task due date").font(.system(size: 12, weight: .semibold))
                    DatePicker("", selection: Binding(get: { task.dueDate ?? .now }, set: { store.setTaskDueDate(task.id, date: $0) }), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    HStack {
                        Button("Remove") { store.setTaskDueDate(task.id, date: nil); showingDuePicker = false }
                        Spacer()
                        Button("Done") { showingDuePicker = false }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(14).frame(width: 250)
                .background(StudioTheme.elevated)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(StudioTheme.soft.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .contextMenu {
            let pluginActions = store.pluginActions(target: .task)
            if pluginActions.isEmpty {
                Button("No task plugins installed") { }.disabled(true)
            } else {
                ForEach(pluginActions) { registered in
                    Button(registered.action.label) { store.runPluginAction(registered, projectID: task.projectID, taskID: task.id) }
                }
            }
        }
    }
}
