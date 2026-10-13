import WebKit
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MapKit
import CoreLocation
import Contacts
@preconcurrency import MultipeerConnectivity

struct FramoPageHeaderV13: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 29, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

struct FramoSearchViewV13: View {
    @EnvironmentObject private var store: FramoStudioStore

    private var query: String { store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var projects: [StudioProject] {
        guard store.isDestinationEnabled(.projects) else { return [] }
        guard !query.isEmpty else { return Array(store.projects.prefix(8)) }
        return store.projects.filter(matchesProject)
    }

    private var customers: [ModoOrganization] {
        guard store.isDestinationEnabled(.customers) else { return [] }
        guard !query.isEmpty else { return Array(store.business.organizations.prefix(8)) }
        return store.business.organizations.filter { matchesAny([$0.name, $0.email, $0.phone, $0.city, $0.vatNumber, $0.notes]) }
    }

    private var quotes: [ModoQuote] {
        guard store.isDestinationEnabled(.sales) else { return [] }
        guard !query.isEmpty else { return Array(store.business.quotes.prefix(8)) }
        return store.business.quotes.filter { quote in
            matchesAny([quote.quoteNumber, quote.status.rawValue, store.customerName(id: quote.customerID)]) ||
            quote.lines.contains { matchesAny([$0.name, $0.description]) }
        }
    }

    private var tasks: [StudioTask] {
        guard store.isDestinationEnabled(.tasks) else { return [] }
        guard !query.isEmpty else { return Array(store.tasks.filter { !$0.isComplete }.prefix(8)) }
        return store.tasks.filter { matchesAny([$0.title]) }
    }

    private var spaces: [StudioSpace] {
        guard store.isDestinationEnabled(.projects) else { return [] }
        guard !query.isEmpty else { return Array(store.spaces.prefix(6)) }
        return store.spaces.filter { matchesAny([$0.title, $0.subtitle, $0.notes]) }
    }

    private var events: [StudioEvent] {
        guard store.isDestinationEnabled(.calendar) else { return [] }
        guard !query.isEmpty else { return Array(store.calendarItems.filter { $0.date >= .now }.prefix(8)) }
        return store.calendarItems.filter { matchesAny([$0.title, $0.location]) }
    }

    private var relatedSearches: [String] {
        guard !query.isEmpty else { return [] }
        var values: [String] = []
        if store.isDestinationEnabled(.projects) {
            values.append(contentsOf: store.projects.filter(matchesProject).flatMap { [$0.client, $0.status.displayName(for: $0.effectiveWorkType), $0.location] })
        }
        if store.isDestinationEnabled(.customers) {
            values.append(contentsOf: store.business.organizations.filter { matchesAny([$0.name, $0.email, $0.city]) }.map(\.name))
        }
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(query) != .orderedSame }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(5).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                searchField
                if !relatedSearches.isEmpty { relatedSearchStrip }
                resultGrid
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 46)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Search").font(.system(size: 26, weight: .semibold))
                Text(query.isEmpty ? "Find anything in your workspace." : "\(totalMatches) results for “\(query)”")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Button("Quick search · ⌘K") { store.showGlobalSearch = true }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var totalMatches: Int { projects.count + customers.count + quotes.count + tasks.count + spaces.count + events.count }

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StudioTheme.secondary)
            TextField("Customers, quotes, work, tasks, files, places…", text: $store.searchText)
                .textFieldStyle(.plain)
                .studioTextCursor()
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.tertiary)
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 42)
        .background(StudioTheme.soft.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var relatedSearchStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Related")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiary)
                ForEach(relatedSearches, id: \.self) { suggestion in
                    Button(suggestion) { store.searchText = suggestion }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var resultGrid: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 860 {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 28) {
                        if store.isDestinationEnabled(.customers) {
                            searchSection("Customers", count: customers.count) {
                                ForEach(customers) { customer in customerResult(customer) }
                            }
                        }
                        if store.isDestinationEnabled(.projects) {
                            searchSection("Work", count: projects.count) {
                                ForEach(projects) { project in projectResult(project) }
                            }
                            searchSection("Spaces", count: spaces.count) {
                                ForEach(spaces) { space in spaceResult(space) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 28) {
                        if store.isDestinationEnabled(.sales) {
                            searchSection("Quotes", count: quotes.count) {
                                ForEach(quotes) { quote in quoteResult(quote) }
                            }
                        }
                        if store.isDestinationEnabled(.tasks) {
                            searchSection("Tasks", count: tasks.count) {
                                ForEach(tasks) { task in TaskRow(task: task) }
                            }
                        }
                        if store.isDestinationEnabled(.calendar) {
                            searchSection("Calendar", count: events.count) {
                                ForEach(events) { event in eventResult(event) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    if store.isDestinationEnabled(.customers) { searchSection("Customers", count: customers.count) { ForEach(customers) { customer in customerResult(customer) } } }
                    if store.isDestinationEnabled(.sales) { searchSection("Quotes", count: quotes.count) { ForEach(quotes) { quote in quoteResult(quote) } } }
                    if store.isDestinationEnabled(.projects) {
                        searchSection("Work", count: projects.count) { ForEach(projects) { project in projectResult(project) } }
                        searchSection("Spaces", count: spaces.count) { ForEach(spaces) { space in spaceResult(space) } }
                    }
                    if store.isDestinationEnabled(.tasks) { searchSection("Tasks", count: tasks.count) { ForEach(tasks) { task in TaskRow(task: task) } } }
                    if store.isDestinationEnabled(.calendar) { searchSection("Calendar", count: events.count) { ForEach(events) { event in eventResult(event) } } }
                }
            }
        }
        .frame(minHeight: 500)
    }

    private func searchSection<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
            }
            if count == 0 {
                Text(query.isEmpty ? "Nothing here yet" : "No matching \(title.lowercased())")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .padding(.horizontal, 2)
            } else {
                LazyVStack(spacing: 6) { content() }
            }
        }
    }

    private func customerResult(_ customer: ModoOrganization) -> some View {
        Button { store.openDestination(.customers) } label: {
            HStack(spacing: 10) {
                Circle().fill(StudioTheme.soft).frame(width: 30, height: 30).overlay(Text(customer.name.prefix(1).uppercased()).font(.system(size: 10, weight: .semibold)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(customer.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(customer.email.isEmpty ? customer.city : customer.email).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
                Spacer()
                Text("Customer").font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
            }
            .foregroundStyle(StudioTheme.primary).padding(.horizontal, 11).frame(height: 46).background(StudioTheme.soft.opacity(0.50)).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).studioPointerCursor()
    }

    private func quoteResult(_ quote: ModoQuote) -> some View {
        Button { store.openDestination(.sales) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(StudioTheme.tertiary).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quote.quoteNumber).font(.system(size: 11, weight: .semibold))
                    Text(store.customerName(id: quote.customerID)).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
                Spacer()
                Text(quote.total, format: .currency(code: quote.currency)).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(StudioTheme.primary).padding(.horizontal, 11).frame(height: 46).background(StudioTheme.soft.opacity(0.50)).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).studioPointerCursor()
    }

    private func projectResult(_ project: StudioProject) -> some View {
        Button { store.openProject(project.id) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: project.colorHex))
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text([project.client, project.location].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
                Spacer()
                Text(project.status.displayName(for: project.effectiveWorkType))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 11)
            .frame(height: 46)
            .background(StudioTheme.soft.opacity(0.50))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
    }

    private func spaceResult(_ space: StudioSpace) -> some View {
        Button { store.openSpace(space.id) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: space.colorHex))
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.title).font(.system(size: 11, weight: .semibold))
                    Text(space.subtitle).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 11)
            .frame(height: 46)
            .background(StudioTheme.soft.opacity(0.50))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
    }

    private func eventResult(_ event: StudioEvent) -> some View {
        Button {
            if let projectID = event.projectID { store.openProject(projectID) }
            else { store.openDestination(.calendar) }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: event.colorHex)).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                }
                Spacer()
            }
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 11)
            .frame(height: 46)
            .background(StudioTheme.soft.opacity(0.50))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
    }

    private func matchesProject(_ project: StudioProject) -> Bool {
        if matchesAny([
            project.title, project.client, project.description, project.location, project.brief, project.script,
            project.deliverable, project.editingSoftware, project.aspectRatio, project.resolution, project.frameRate,
            project.kind?.rawValue ?? "", project.status.rawValue, project.frameIOURL ?? "", project.clientShareURL ?? ""
        ]) { return true }
        if project.shots.contains(where: matchesShot) { return true }
        if project.crew.contains(where: matchesCrewMember) { return true }
        if (project.clientContacts ?? []).contains(where: matchesClientContact) { return true }
        if project.kit.contains(where: matchesKitItem) { return true }
        if project.storyboard.contains(where: matchesStoryboardCard) { return true }
        if (project.linkedFiles ?? []).contains(where: { matchesAny([$0.displayName, $0.originalPath, $0.volumeName, $0.contentType]) }) { return true }
        return false
    }

    private func matchesShot(_ shot: Shot) -> Bool { matchesAny([shot.title, shot.description, shot.shotSize, shot.movement, shot.lens, shot.frameRate, shot.duration]) }
    private func matchesCrewMember(_ member: CrewMember) -> Bool { matchesAny([member.name, member.role, member.email]) }
    private func matchesClientContact(_ contact: ClientContact) -> Bool { matchesAny([contact.name, contact.company, contact.email, contact.phone]) }
    private func matchesKitItem(_ item: KitItem) -> Bool { matchesAny([item.name, item.category]) }
    private func matchesStoryboardCard(_ card: StoryboardCard) -> Bool { matchesAny([card.title, card.notes]) }
    private func matchesAny(_ values: [String]) -> Bool { values.contains { $0.localizedCaseInsensitiveContains(query) } }
}
struct FramoProjectsViewV13: View {
    @EnvironmentObject private var store: FramoStudioStore
    let favoritesOnly: Bool
    @State private var statusFilter: ProjectStatus?
    @State private var layout: ProjectLayout = .grid
    @State private var workTypeFilter: ModoWorkType?

    private enum ProjectLayout: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case pipeline = "Pipeline"
        var id: String { rawValue }
        var symbol: String { self == .grid ? "square.grid.2x2" : "rectangle.3.group" }
    }

    private var visible: [StudioProject] {
        store.projects.filter { project in
            (!favoritesOnly || project.favorite) &&
            (statusFilter == nil || project.status == statusFilter) &&
            (workTypeFilter == nil || project.effectiveWorkType == workTypeFilter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectsHeader
            if layout == .grid { filters }

            Group {
                if layout == .grid { gridView } else { pipelineView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
    }

    private var projectsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(favoritesOnly ? "Favorites" : "All work").font(.system(size: 25, weight: .semibold))
                Text("From accepted scope to delivery.").font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            layoutControl
            Button { store.requestProjectCreation() } label: {
                Label("New work", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var layoutControl: some View {
        HStack(spacing: 3) {
            ForEach(ProjectLayout.allCases) { item in
                Button { layout = item } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 9))
                        Text(item.rawValue)
                    }
                    .font(.system(size: 10, weight: layout == item ? .semibold : .medium))
                    .foregroundStyle(layout == item ? StudioTheme.primary : StudioTheme.secondary)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(layout == item ? StudioTheme.selected : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).studioPointerCursor()
            }
        }
        .padding(2)
        .frame(height: 34)
        .background(StudioTheme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterButton("All", status: nil)
                ForEach(ProjectStatus.allCases, id: \.self) { status in
                    filterButton(status.rawValue, status: status)
                }

                Divider().frame(height: 18)

                workTypeButton("All types", type: nil)
                ForEach(ModoWorkType.allCases) { type in
                    workTypeButton(type.rawValue, type: type)
                }
            }
        }
    }

    private var gridView: some View {
        GeometryReader { proxy in
            let minimum: CGFloat = proxy.size.width > 1200 ? 240 : 210
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: 340), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(visible) { project in
                        LargeProjectCard(project: project)
                            .onTapGesture { store.openProject(project.id) }
                            .studioPointerCursor()
                    }
                }
                .padding(.bottom, 28)
            }
        }
    }

    private var pipelineView: some View {
        GeometryReader { proxy in
            let gaps: CGFloat = 8 * CGFloat(max(ProjectStatus.allCases.count - 1, 0))
            let fit = max(68, (proxy.size.width - gaps) / CGFloat(max(ProjectStatus.allCases.count, 1)))
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(ProjectStatus.allCases, id: \.self) { status in
                        pipelineColumn(status, width: fit)
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .padding(.bottom, 18)
            }
        }
    }

    private func pipelineColumn(_ status: ProjectStatus, width: CGFloat) -> some View {
        let projects = store.projects.filter {
            (!favoritesOnly || $0.favorite) &&
            $0.status == status &&
            (workTypeFilter == nil || $0.effectiveWorkType == workTypeFilter)
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.displayName(for: workTypeFilter))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer()
                Text("\(projects.count)").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 3).frame(height: 28)

            ForEach(projects) { project in
                Button { store.openProject(project.id) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(project.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(2)
                        Text(project.client)
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.secondary)
                            .lineLimit(1)
                        Text(project.dueDate.shortStudioDate)
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.elevated.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(hex: project.colorHex).opacity(0.16), lineWidth: 0.65)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).studioPointerCursor()
                .draggable("project:\(project.id.uuidString)")
            }

            if projects.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    Text("Drop work here").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(StudioTheme.soft.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 12)
        }
        .padding(9)
        .frame(width: width)
        .frame(minHeight: 520, alignment: .top)
        .background(StudioTheme.soft.opacity(0.44))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first else { return false }
            let token = raw.hasPrefix("project:") ? String(raw.dropFirst(8)) : raw
            guard let id = UUID(uuidString: token) else { return false }
            moveProject(id, to: status)
            return true
        }
    }

    private func moveProject(_ id: UUID, to status: ProjectStatus) {
        guard var project = store.projects.first(where: { $0.id == id }) else { return }
        project.status = status
        store.updateProject(project)
    }

    private func filterButton(_ title: String, status: ProjectStatus?) -> some View {
        Button(title) { statusFilter = status }
            .buttonStyle(.plain).studioPointerCursor()
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(statusFilter == status ? StudioTheme.primary : StudioTheme.secondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(statusFilter == status ? StudioTheme.selected : StudioTheme.soft)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func workTypeButton(_ title: String, type: ModoWorkType?) -> some View {
        Button(title) { workTypeFilter = type }
            .buttonStyle(.plain)
            .studioPointerCursor()
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(workTypeFilter == type ? StudioTheme.primary : StudioTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(workTypeFilter == type ? StudioTheme.selected : StudioTheme.soft.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LargeProjectCard: View {
    @EnvironmentObject private var store: FramoStudioStore
    let project: StudioProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectBanner(path: project.bannerPath, assetName: project.bannerAssetName, colorHex: project.colorHex, height: 105, focusY: project.effectiveBannerFocusY)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusPill(status: project.status)
                    HStack(spacing: 4) {
                        Image(systemName: project.effectiveWorkType.icon)
                        Text(project.effectiveWorkType.rawValue)
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(StudioTheme.tertiary)
                    Spacer()
                    Text(project.dueDate.shortStudioDate)
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.secondary)
                }
                Text(project.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(project.client).font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
            }
            .padding(14)
            .background(StudioTheme.soft.opacity(0.97))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 22, style: .continuous))
            .padding(.horizontal, 7)
            .padding(.top, -15)
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
        .background(StudioTheme.soft.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color(hex: project.colorHex).opacity(0.17), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
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


struct FramoTasksViewV17: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var taskDraft: TaskDraft?
    @State private var quickTaskText = ""
    @State private var showCompletedArchive = false
    @FocusState private var quickTaskFocused: Bool

    private struct TaskDraft: Identifiable {
        let id = UUID()
        var taskID: UUID?
        var title: String
        var dueDate: Date?
        var projectID: UUID?
        var priority: Int
        var heading: String
    }

    private var openTasks: [StudioTask] { store.tasks.filter { !$0.isComplete } }

    private var overdueTasks: [StudioTask] {
        openTasks
            .filter { task in
                guard let due = task.dueDate else { return false }
                return due < Calendar.current.startOfDay(for: .now)
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var todayTasks: [StudioTask] {
        openTasks
            .filter { $0.dueDate.map(Calendar.current.isDateInToday) ?? false }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var upcomingTasks: [StudioTask] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return openTasks
            .filter { ($0.dueDate ?? .distantPast) >= tomorrow }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var undatedTasks: [StudioTask] {
        openTasks.filter { $0.dueDate == nil }
    }

    private var allCompletedTasks: [StudioTask] {
        store.tasks.filter(\.isComplete)
    }

    private var completedTasks: [StudioTask] {
        Array(allCompletedTasks.prefix(16))
    }

    private var archivedCompletedTasks: [StudioTask] {
        Array(allCompletedTasks.dropFirst(16))
    }

    private var equalLaneHeight: CGFloat {
        let maximum = [overdueTasks.count, todayTasks.count, upcomingTasks.count, undatedTasks.count].max() ?? 0
        return min(max(270, CGFloat(maximum) * 66 + 88), 470)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    quickAdd
                    planner(width: proxy.size.width - 36)
                    completedSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .sheet(item: $taskDraft) { draft in
            TaskEditor(draft: draft)
                .environmentObject(store)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                quickTaskFocused = false
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tasks")
                    .font(.system(size: 25, weight: .semibold))
                Text("\(openTasks.count) open · \(overdueTasks.count) overdue · \(todayTasks.count) today")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Button("Add task") {
                beginTask(heading: "New task", dueDate: nil)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StudioTheme.tertiary)
            TextField("Add task…", text: $quickTaskText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($quickTaskFocused)
                .onSubmit { runQuickTask() }
                .studioTextCursor()
            if !quickTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") { runQuickTask() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .studioPointerCursor()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(StudioTheme.input.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func planner(width: CGFloat) -> some View {
        if width >= 1120 {
            HStack(alignment: .top, spacing: 10) {
                lane("Overdue", tasks: overdueTasks, accent: StudioTheme.red, dueDate: overdueDefaultDate)
                lane("Today", tasks: todayTasks, accent: StudioTheme.green, dueDate: todayDefaultDate)
                lane("Upcoming", tasks: upcomingTasks, accent: StudioTheme.primary, dueDate: upcomingDefaultDate)
                lane("No date", tasks: undatedTasks, accent: StudioTheme.tertiary, dueDate: nil)
            }
        } else if width >= 650 {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    lane("Overdue", tasks: overdueTasks, accent: StudioTheme.red, dueDate: overdueDefaultDate)
                    lane("Today", tasks: todayTasks, accent: StudioTheme.green, dueDate: todayDefaultDate)
                }
                HStack(alignment: .top, spacing: 10) {
                    lane("Upcoming", tasks: upcomingTasks, accent: StudioTheme.primary, dueDate: upcomingDefaultDate)
                    lane("No date", tasks: undatedTasks, accent: StudioTheme.tertiary, dueDate: nil)
                }
            }
        } else {
            VStack(spacing: 10) {
                lane("Overdue", tasks: overdueTasks, accent: StudioTheme.red, dueDate: overdueDefaultDate)
                lane("Today", tasks: todayTasks, accent: StudioTheme.green, dueDate: todayDefaultDate)
                lane("Upcoming", tasks: upcomingTasks, accent: StudioTheme.primary, dueDate: upcomingDefaultDate)
                lane("No date", tasks: undatedTasks, accent: StudioTheme.tertiary, dueDate: nil)
            }
        }
    }

    private var overdueDefaultDate: Date? {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: yesterday)
    }

    private var todayDefaultDate: Date? {
        Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now)
    }

    private var upcomingDefaultDate: Date? {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        return Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: tomorrow)
    }

    private func lane(_ title: String, tasks: [StudioTask], accent: Color, dueDate: Date?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                beginTask(heading: "Add to \(title)", dueDate: dueDate)
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(tasks.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StudioTheme.tertiary)
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .studioPointerCursor()

            if tasks.isEmpty {
                Button {
                    beginTask(heading: "Add to \(title)", dueDate: dueDate)
                } label: {
                    Text("Add a task")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(tasks) { task in taskRow(task) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: equalLaneHeight, alignment: .topLeading)
        .background(StudioTheme.soft.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .dropDestination(for: String.self) { values, _ in
            guard let raw = values.first else { return false }
            let token = raw.hasPrefix("task:") ? String(raw.dropFirst(5)) : raw
            guard let id = UUID(uuidString: token) else { return false }
            moveTask(id, to: title, dueDate: dueDate)
            return true
        } isTargeted: { _ in }
    }

    private func taskRow(_ task: StudioTask) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                toggleTask(task.id)
            } label: {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(task.isComplete ? StudioTheme.green : StudioTheme.secondary)
            }
            .buttonStyle(.plain)
            .studioPointerCursor()

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 10, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    if let project = project(for: task) {
                        Circle().fill(Color(hex: project.colorHex)).frame(width: 5, height: 5)
                        Text(project.title).lineLimit(1)
                    }
                    if let due = task.dueDate {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("No date")
                    }
                }
                .font(.system(size: 8))
                .foregroundStyle(StudioTheme.tertiary)
            }

            Spacer(minLength: 4)

            if task.priority >= 2 {
                Image(systemName: task.priority >= 3 ? "exclamationmark.2" : "exclamationmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(task.priority >= 3 ? StudioTheme.red : StudioTheme.secondary)
            }
        }
        .foregroundStyle(StudioTheme.primary)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(StudioTheme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { editTask(task) }
        .studioPointerCursor()
        .draggable("task:\(task.id.uuidString)") {
            Text(task.title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(StudioTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            Button(task.isComplete ? "Reopen" : "Complete") { toggleTask(task.id) }
            Button("Due today") { setTaskDue(task.id, date: todayDefaultDate) }
            Button("Due tomorrow") { setTaskDue(task.id, date: upcomingDefaultDate) }
            Button("Remove due date") { setTaskDue(task.id, date: nil) }
            if let projectID = task.projectID {
                Divider()
                Button("Open work") { store.openProjectSection(projectID, section: .tasks) }
            }
            let actions = store.pluginActions(target: .task)
            if !actions.isEmpty {
                Divider()
                Menu("Plugins") {
                    ForEach(actions) { action in
                        Button(action.action.label) {
                            store.runPluginAction(action, projectID: task.projectID, taskID: task.id)
                        }
                    }
                }
            }
        }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(StudioTheme.green.opacity(0.75)).frame(width: 7, height: 7)
                Text("Completed").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(completedTasks.count)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)
            }

            if completedTasks.isEmpty {
                Text("Completed tasks will collect here.")
                    .font(.system(size: 9))
                    .foregroundStyle(StudioTheme.tertiary)
                    .padding(.vertical, 18)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], spacing: 8) {
                    ForEach(completedTasks) { task in
                        taskRow(task)
                    }
                }
            }

            if !archivedCompletedTasks.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showCompletedArchive.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: showCompletedArchive ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("Archive")
                        Text("\(archivedCompletedTasks.count)")
                            .foregroundStyle(StudioTheme.tertiary)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondary)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .studioPointerCursor()

                if showCompletedArchive {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], spacing: 8) {
                        ForEach(archivedCompletedTasks) { task in taskRow(task) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.top, 4)
    }

    private func project(for task: StudioTask) -> StudioProject? {
        guard let id = task.projectID else { return nil }
        return store.projects.first(where: { $0.id == id })
    }

    private func beginTask(heading: String, dueDate: Date?) {
        taskDraft = TaskDraft(
            taskID: nil,
            title: "",
            dueDate: dueDate,
            projectID: store.selectedProjectID,
            priority: 1,
            heading: heading
        )
    }

    private func editTask(_ task: StudioTask) {
        taskDraft = TaskDraft(
            taskID: task.id,
            title: task.title,
            dueDate: task.dueDate,
            projectID: task.projectID,
            priority: task.priority,
            heading: "Edit task"
        )
    }

    private func toggleTask(_ id: UUID) {
        guard let index = store.tasks.firstIndex(where: { $0.id == id }) else { return }
        store.tasks[index].isComplete.toggle()
    }

    private func setTaskDue(_ id: UUID, date: Date?) {
        guard let index = store.tasks.firstIndex(where: { $0.id == id }) else { return }
        store.tasks[index].dueDate = date
    }

    private func runQuickTask() {
        let text = quickTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addTask(title: text, dueDate: nil, projectID: nil)
        quickTaskText = ""
        quickTaskFocused = true
    }

    private func moveTask(_ id: UUID, to lane: String, dueDate: Date?) {
        guard let index = store.tasks.firstIndex(where: { $0.id == id }) else { return }
        store.tasks[index].isComplete = false
        switch lane {
        case "No date":
            store.tasks[index].dueDate = nil
        case "Overdue":
            store.tasks[index].dueDate = overdueDefaultDate
        case "Today":
            store.tasks[index].dueDate = todayDefaultDate
        case "Upcoming":
            store.tasks[index].dueDate = upcomingDefaultDate
        default:
            store.tasks[index].dueDate = dueDate
        }
    }

    private struct TaskEditor: View {
        @EnvironmentObject private var store: FramoStudioStore
        @Environment(\.dismiss) private var dismiss
        let draft: TaskDraft

        @State private var title: String
        @State private var projectID: UUID?
        @State private var hasDueDate: Bool
        @State private var dueDate: Date
        @State private var priority: Int

        init(draft: TaskDraft) {
            self.draft = draft
            _title = State(initialValue: draft.title)
            _projectID = State(initialValue: draft.projectID)
            _hasDueDate = State(initialValue: draft.dueDate != nil)
            _dueDate = State(initialValue: draft.dueDate ?? .now)
            _priority = State(initialValue: draft.priority)
        }

        private var projectName: String {
            guard let projectID, let project = store.projects.first(where: { $0.id == projectID }) else { return "No project" }
            return project.title
        }

        private var priorityName: String {
            switch priority {
            case 3: return "Urgent"
            case 2: return "High"
            default: return "Normal"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.heading)
                            .font(.system(size: 20, weight: .semibold))
                        Text("Keep the task lightweight; details can stay with the project.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                }

                VStack(alignment: .leading, spacing: 7) {
                    dialogLabel("TASK")
                    StudioDialogField {
                        TextField("What needs to happen?", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .studioTextCursor()
                    }
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        dialogLabel("PROJECT")
                        Menu {
                            Button("No project") { projectID = nil }
                            ForEach(store.projects) { project in
                                Button(project.title) { projectID = project.id }
                            }
                        } label: {
                            menuField(projectName)
                        }
                        .menuStyle(.borderlessButton)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        dialogLabel("PRIORITY")
                        Menu {
                            Button("Normal") { priority = 1 }
                            Button("High") { priority = 2 }
                            Button("Urgent") { priority = 3 }
                        } label: {
                            menuField(priorityName)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Set a due date", isOn: $hasDueDate)
                        .font(.system(size: 11, weight: .medium))
                        .toggleStyle(.switch)
                    if hasDueDate {
                        StudioDialogSurface {
                            HStack {
                                Text("Due")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(StudioTheme.secondary)
                                Spacer()
                                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                            }
                        }
                    }
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button(draft.taskID == nil ? "Add task" : "Save") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
            .frame(width: 470)
            .background(StudioTheme.canvas)
        }

        private func dialogLabel(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(StudioTheme.tertiary)
        }

        private func menuField(_ title: String) -> some View {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(StudioTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        private func save() {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }

            if let id = draft.taskID,
               let index = store.tasks.firstIndex(where: { $0.id == id }) {
                store.tasks[index].title = clean
                store.tasks[index].projectID = projectID
                store.tasks[index].priority = priority
                store.tasks[index].dueDate = hasDueDate ? dueDate : nil
            } else {
                store.addTask(title: clean, dueDate: hasDueDate ? dueDate : nil, projectID: projectID)
                if let index = store.tasks.firstIndex(where: { $0.title == clean && $0.projectID == projectID }) {
                    store.tasks[index].priority = priority
                }
            }
            dismiss()
        }
    }
}


struct FramoCalendarViewV13: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var selectedDate = Date.now
    @State private var displayMode: CalendarDisplayMode = .week
    @State private var planningDraft: PlanningDraft?
    @State private var taskDraft: TaskComposerDraft?
    @State private var showCalendarSidebar = false
    @State private var sidebarHint = false
    @AppStorage("studio.sidebar.collapsed") private var appSidebarCollapsed = false
    @AppStorage("studio.calendar.sidebar-hint-shown") private var sidebarHintShown = false

    private enum CalendarDisplayMode: String, CaseIterable, Identifiable, Hashable {
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }
    }

    private struct PlanningDraft: Identifiable {
        let id = UUID()
        var start: Date
        var end: Date
    }

    private struct TaskComposerDraft: Identifiable {
        let id = UUID()
        var title: String = ""
        var dueDate: Date?
        var projectID: UUID?
        var heading: String
    }

    private var calendar: Calendar { Calendar.current }
    private var week: [Date] {
        let weekday = calendar.component(.weekday, from: selectedDate)
        let offset = -((weekday + 5) % 7)
        let monday = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: selectedDate)) ?? selectedDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                calendarHeader
                switch displayMode {
                case .week:
                    HStack(alignment: .top, spacing: 0) {
                        weekPanel
                        if showCalendarSidebar {
                            calendarSidebar
                        }
                    }
                case .month:
                    HStack(alignment: .top, spacing: 0) {
                        largeMonthPanel
                        if showCalendarSidebar {
                            calendarSidebar
                        }
                    }
                }
            }

            if sidebarHint {
                Text("Week view adapts automatically when a sidebar is open")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.primary)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(StudioTheme.elevated)
                    .overlay(Capsule().stroke(StudioTheme.border))
                    .clipShape(Capsule())
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $planningDraft) { draft in
            PlanningComposer(draft: draft, selectedDate: $selectedDate).environmentObject(store)
        }
        .sheet(item: $taskDraft) { draft in
            CalendarTaskComposer(draft: draft).environmentObject(store)
        }
        .sheet(item: $store.inspectedCalendarItem) { item in
            CalendarEventInspector(item: item).environmentObject(store)
        }
        .onAppear {
            // Preserve the user's global sidebar choice. The week grid now adapts
            // to the available width instead of switching to a different layout.
        }
    }

    private var calendarHeader: some View {
        HStack(spacing: 14) {
            Text(selectedDate.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 24, weight: .semibold))
                .frame(minWidth: 190, alignment: .leading)

            Spacer(minLength: 20)

            HStack(spacing: 6) {
                Button { beginPlanning(on: selectedDate) } label: {
                    Text("Plan")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 58, height: 28)
                        .background(StudioTheme.soft.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).studioPointerCursor()

                ForEach(CalendarDisplayMode.allCases) { mode in
                    Button { displayMode = mode } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 10, weight: displayMode == mode ? .semibold : .medium))
                            .foregroundStyle(displayMode == mode ? StudioTheme.primary : StudioTheme.secondary)
                            .frame(width: 58, height: 28)
                            .background(displayMode == mode ? StudioTheme.selected : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).studioPointerCursor()
                }

                Button("Today") { selectedDate = .now }
                    .buttonStyle(.plain).studioPointerCursor()
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 58, height: 28)
                    .background(StudioTheme.soft.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button { moveCalendar(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).studioPointerCursor()
                Button { moveCalendar(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).studioPointerCursor()

                calendarIntegrationMenu

                Button {
                    withAnimation(.easeOut(duration: 0.14)) { showCalendarSidebar.toggle() }
                    if showCalendarSidebar && displayMode == .week {
                        withAnimation(.easeOut(duration: 0.15)) { sidebarHint = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            withAnimation(.easeOut(duration: 0.15)) { sidebarHint = false }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sidebar.right")
                        Text("Sidebar")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(showCalendarSidebar ? StudioTheme.selected : StudioTheme.soft.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).studioPointerCursor().help("Show the mini calendar and selected-day agenda")
            }
            .fixedSize()
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
    }

    private var calendarIntegrationMenu: some View {
        Menu {
            Button("Connect Apple Calendar") { store.connectAppleCalendar() }
            Button("Sync MODO plans to Apple Calendar") { store.pushFramoPlansToAppleCalendar() }
            Button("Import upcoming Apple Calendar events") { store.importAppleCalendar() }
            Divider()
            Button("Open Calendar.app") {
                if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Text(store.calendarIntegrationStatus)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.plus")
                Text("Apple")
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(StudioTheme.soft.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .studioPointerCursor()
        .fixedSize()
        .help("Connect, import or sync with Apple Calendar")
    }

    private var weekPanel: some View {
        HourlyWeekGrid(
            days: week,
            selectedDate: $selectedDate,
            onPlanAt: { beginPlanning(at: $0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendarSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonthGrid(selectedDate: $selectedDate)
            selectedDayAgenda
            HStack {
                Text("WORK").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
                Spacer()
                Text(selectedDate.formatted(.dateTime.month(.abbreviated))).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
            }
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(store.projects.sorted { $0.dueDate < $1.dueDate }) { project in
                        CalendarProjectRow(project: project)
                    }
                }
            }
        }
        .padding(14).frame(width: 272)
    }

    private var selectedDayAgenda: some View {
        let items = store.calendarItems.filter { calendarItem($0, occursOn: selectedDate) }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(items.count) planned item\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }
                Spacer()
                Button { beginPlanning(on: selectedDate) } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle()).help("Plan something")
            }
            if items.isEmpty {
                Text("Nothing planned").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    .padding(.vertical, 7)
            } else {
                ForEach(items.prefix(5)) { item in CalendarItemRow(item: item, compact: true) }
                if items.count > 5 {
                    Text("+\(items.count - 5) more").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }
            }
        }
    }

    private func calendarItem(_ item: StudioEvent, occursOn day: Date) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        let start = calendar.startOfDay(for: item.date)
        let end = calendar.startOfDay(for: item.endDate)
        return dayStart >= start && dayStart <= end
    }

    private var largeMonthPanel: some View {
        LargeMonthGrid(selectedDate: $selectedDate) { start, end in
            selectedDate = start
            planningDraft = PlanningDraft(start: start, end: end)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func beginPlanning(on day: Date) {
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        planningDraft = PlanningDraft(start: start, end: start.addingTimeInterval(3600))
    }

    private func beginPlanning(at start: Date) {
        selectedDate = start
        planningDraft = PlanningDraft(start: start, end: start.addingTimeInterval(3600))
    }

    private func moveCalendar(_ amount: Int) {
        let component: Calendar.Component = displayMode == .month ? .month : .day
        let value = displayMode == .month ? amount : amount * 7
        selectedDate = calendar.date(byAdding: component, value: value, to: selectedDate) ?? selectedDate
    }

    private struct HourlyWeekGrid: View {
        @EnvironmentObject private var store: FramoStudioStore
        let days: [Date]
        @Binding var selectedDate: Date
        let onPlanAt: (Date) -> Void

        private let startHour = 7
        private let endHour = 23
        private let rowHeight: CGFloat = 58
        private let timeWidth: CGFloat = 54

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: timeWidth, height: 54)
                    ForEach(days, id: \.self) { day in
                        Button {
                            selectedDate = day
                        } label: {
                            VStack(spacing: 3) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(StudioTheme.tertiary)
                                Text(day.formatted(.dateTime.day()))
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Calendar.current.isDateInToday(day) ? StudioTheme.selected.opacity(0.62) : .clear)
                        }
                        .buttonStyle(.plain)
                        .studioPointerCursor()
                    }
                }

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(startHour..<endHour, id: \.self) { hour in
                                Text(String(format: "%02d:00", hour))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(StudioTheme.tertiary)
                                    .frame(width: timeWidth - 9, height: rowHeight, alignment: .topTrailing)
                                    .padding(.top, -4)
                            }
                        }
                        .frame(width: timeWidth)

                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            DayTimelineColumn(
                                day: day,
                                startHour: startHour,
                                endHour: endHour,
                                rowHeight: rowHeight,
                                selectedDate: $selectedDate,
                                onPlanAt: onPlanAt
                            )
                            if index < days.count - 1 {
                                Rectangle().fill(StudioTheme.border.opacity(0.28)).frame(width: 1)
                            }
                        }
                    }
                }
            }
            .background(StudioTheme.canvas)
        }

        private struct DayTimelineColumn: View {
            @EnvironmentObject private var store: FramoStudioStore
            let day: Date
            let startHour: Int
            let endHour: Int
            let rowHeight: CGFloat
            @Binding var selectedDate: Date
            let onPlanAt: (Date) -> Void

            private var calendar: Calendar { Calendar.current }

            private var items: [StudioEvent] {
                let dayStart = calendar.startOfDay(for: day)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
                return store.calendarItems
                    .filter { $0.date < dayEnd && $0.endDate > dayStart }
                    .sorted { $0.date < $1.date }
            }

            private var displayStart: Date {
                calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
            }

            private var displayEnd: Date {
                calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) ?? day.addingTimeInterval(16 * 3600)
            }

            var body: some View {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(startHour..<endHour, id: \.self) { hour in
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: rowHeight)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(StudioTheme.border.opacity(0.24)).frame(height: 1)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedDate = day
                                    let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
                                    onPlanAt(date)
                                }
                                .dropDestination(for: String.self) { values, _ in
                                    guard let payload = values.first else { return false }
                                    selectedDate = day
                                    let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
                                    return store.schedulePayload(payload, at: date)
                                } isTargeted: { _ in }
                                .studioPointerCursor()
                        }
                    }

                    GeometryReader { proxy in
                        ForEach(placements) { placement in
                            let laneGap: CGFloat = 5
                            let horizontalInset: CGFloat = 6
                            let usableWidth = max(40, proxy.size.width - horizontalInset * 2)
                            let width = max(34, (usableWidth - CGFloat(max(0, placement.laneCount - 1)) * laneGap) / CGFloat(placement.laneCount))
                            let x = horizontalInset + CGFloat(placement.lane) * (width + laneGap)

                            Button {
                                selectedDate = placement.item.date
                                store.inspectCalendarItem(placement.item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(placement.item.title)
                                        .font(.system(size: 9, weight: .semibold))
                                        .lineLimit(2)
                                    if placement.height > 38 {
                                        Text(placement.item.date.formatted(date: .omitted, time: .shortened))
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(StudioTheme.secondary)
                                    }
                                }
                                .foregroundStyle(StudioTheme.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Color(hex: placement.item.colorHex).opacity(0.16))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(hex: placement.item.colorHex))
                                        .frame(width: 3)
                                        .padding(.vertical, 5)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .studioPointerCursor()
                            .frame(width: width, height: placement.height)
                            .offset(x: x, y: placement.offset)
                        }
                    }

                    if calendar.isDateInToday(day), let currentY {
                        HStack(spacing: 3) {
                            Circle().fill(StudioTheme.red).frame(width: 5, height: 5)
                            Rectangle().fill(StudioTheme.red.opacity(0.72)).frame(height: 1)
                        }
                        .offset(x: -2, y: currentY)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: contentHeight)
                .background(calendar.isDate(day, inSameDayAs: selectedDate) ? StudioTheme.selected.opacity(0.16) : .clear)
            }

            private struct EventPlacement: Identifiable {
                let item: StudioEvent
                let offset: CGFloat
                let height: CGFloat
                let lane: Int
                let laneCount: Int
                var id: UUID { item.id }
            }

            /// Events keep their true time position. Collisions are resolved horizontally
            /// like a desktop calendar instead of pushing cards down into unrelated hours.
            private var placements: [EventPlacement] {
                struct Temp {
                    let item: StudioEvent
                    let offset: CGFloat
                    let height: CGFloat
                    let lane: Int
                    var bottom: CGFloat { offset + height }
                }

                var active: [(bottom: CGFloat, lane: Int)] = []
                var temp: [Temp] = []

                for item in items {
                    guard let geometry = eventGeometry(item) else { continue }
                    let height = max(18, geometry.height)
                    active.removeAll { $0.bottom <= geometry.offset + 1 }
                    let occupied = Set(active.map { $0.lane })
                    var lane = 0
                    while occupied.contains(lane) { lane += 1 }
                    active.append((geometry.offset + height, lane))
                    temp.append(Temp(item: item, offset: geometry.offset, height: height, lane: lane))
                }

                return temp.map { current in
                    let overlapping = temp.filter { other in
                        other.offset < current.bottom && other.bottom > current.offset
                    }
                    let laneCount = max(1, (overlapping.map(\.lane).max() ?? 0) + 1)
                    return EventPlacement(
                        item: current.item,
                        offset: current.offset,
                        height: current.height,
                        lane: current.lane,
                        laneCount: laneCount
                    )
                }
            }

            private var contentHeight: CGFloat {
                CGFloat(endHour - startHour) * rowHeight
            }

            private var currentY: CGFloat? {
                let now = Date.now
                guard now >= displayStart && now <= displayEnd else { return nil }
                return CGFloat(now.timeIntervalSince(displayStart) / 3600) * rowHeight
            }

            private func eventGeometry(_ item: StudioEvent) -> (offset: CGFloat, height: CGFloat)? {
                let start = max(item.date, displayStart)
                let end = min(item.endDate, displayEnd)
                guard end > start else { return nil }
                let offset = CGFloat(start.timeIntervalSince(displayStart) / 3600) * rowHeight
                let rawHeight = CGFloat(end.timeIntervalSince(start) / 3600) * rowHeight
                // Leave a visible breathing gap between back-to-back events. The
                // top remains pinned to the real start time; only the card body
                // is shortened so adjacent appointments never visually fuse.
                return (offset, max(18, rawHeight - 5))
            }
        }
    }

    private struct StackedWeekList: View {
        @EnvironmentObject private var store: FramoStudioStore
        let days: [Date]
        @Binding var selectedDate: Date
        let onPlan: (Date) -> Void

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(days, id: \.self) { day in
                        dayCard(day)
                    }
                }
                .padding(14)
            }
        }

        @ViewBuilder
        private func dayCard(_ day: Date) -> some View {
            let items = events(on: day)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 12, weight: .semibold))
                        Text(day.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.system(size: 9))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    if Calendar.current.isDateInToday(day) {
                        Text("TODAY")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                    Button {
                        selectedDate = day
                        onPlan(day)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(StudioTheme.soft)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                }

                if items.isEmpty {
                    Button {
                        selectedDate = day
                        onPlan(day)
                    } label: {
                        HStack {
                            Text("No plans")
                            Spacer()
                            Text("Add something")
                            Image(systemName: "plus")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 42)
                        .background(StudioTheme.soft.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                } else {
                    ForEach(items) { item in
                        CalendarItemRow(item: item, compact: false)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(Calendar.current.isDate(day, inSameDayAs: selectedDate) ? StudioTheme.selected.opacity(0.30) : StudioTheme.elevated)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Calendar.current.isDate(day, inSameDayAs: selectedDate) ? StudioTheme.primary.opacity(0.25) : StudioTheme.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { selectedDate = day }
                .dropDestination(for: String.self) { values, _ in
                    guard let payload = values.first else { return false }
                    selectedDate = day
                    let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
                    return store.schedulePayload(payload, at: start)
                } isTargeted: { _ in }
        }

        private func events(on day: Date) -> [StudioEvent] {
            let cal = Calendar.current
            let current = cal.startOfDay(for: day)
            return store.calendarItems
                .filter { current >= cal.startOfDay(for: $0.date) && current <= cal.startOfDay(for: $0.endDate) }
                .sorted { $0.date < $1.date }
        }
    }

    private struct WeekColumn: View {
        @EnvironmentObject private var store: FramoStudioStore
        let day: Date
        let onPlan: () -> Void

        private var items: [StudioEvent] {
            let cal = Calendar.current
            let current = cal.startOfDay(for: day)
            return store.calendarItems.filter { current >= cal.startOfDay(for: $0.date) && current <= cal.startOfDay(for: $0.endDate) }
        }

        var body: some View {
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
                    Text(day.formatted(.dateTime.day())).font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Calendar.current.isDateInToday(day) ? StudioTheme.selected.opacity(0.65) : .clear)

                Divider()

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items) { item in CalendarItemRow(item: item, compact: true) }
                        Button(action: onPlan) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                Text(items.isEmpty ? "Plan" : "Add")
                            }
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(StudioTheme.soft.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    }
                    .padding(8)
                }
            }
            .background(StudioTheme.canvas)
            .contentShape(Rectangle())
            .contextMenu { Button("Plan event") { onPlan() } }
        }
    }

    private struct WeekdayRow: View {
        @EnvironmentObject private var store: FramoStudioStore
        let day: Date
        let onPlan: () -> Void

        private var items: [StudioEvent] {
            let cal = Calendar.current
            let current = cal.startOfDay(for: day)
            return store.calendarItems.filter { current >= cal.startOfDay(for: $0.date) && current <= cal.startOfDay(for: $0.endDate) }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 13) {
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.secondary)
                    Text(day.formatted(.dateTime.day())).font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 44)

                VStack(spacing: 6) {
                    if items.isEmpty {
                        Button(action: onPlan) {
                            HStack {
                                Text("Nothing planned").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                            }
                            .padding(10)
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    } else {
                        ForEach(items.prefix(6)) { item in CalendarItemRow(item: item) }
                        if items.count > 6 { Text("+\(items.count - 6) more").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(11)
            .background(Calendar.current.isDateInToday(day) ? StudioTheme.soft : StudioTheme.elevated)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contextMenu { Button("Plan event") { onPlan() } }
        }
    }

    private struct WeekendCard: View {
        @EnvironmentObject private var store: FramoStudioStore
        let day: Date
        let onPlan: () -> Void
        private var items: [StudioEvent] {
            let cal = Calendar.current
            let current = cal.startOfDay(for: day)
            return store.calendarItems.filter { current >= cal.startOfDay(for: $0.date) && current <= cal.startOfDay(for: $0.endDate) }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(day.formatted(.dateTime.weekday(.wide))).font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text(day.formatted(.dateTime.day())).font(.system(size: 13, weight: .bold))
                }
                ForEach(items.prefix(2)) { CalendarItemRow(item: $0, compact: true) }
                if items.isEmpty {
                    Button("Plan something") { onPlan() }
                        .buttonStyle(.plain).studioPointerCursor()
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
            .background(StudioTheme.soft)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contextMenu { Button("Plan event") { onPlan() } }
        }
    }

    private struct CalendarItemRow: View {
        @EnvironmentObject private var store: FramoStudioStore
        let item: StudioEvent
        var compact = false

        var body: some View {
            Button {
                store.inspectCalendarItem(item)
            } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: item.colorHex)).frame(width: 4, height: compact ? 23 : 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: compact ? 9 : 10, weight: .medium)).lineLimit(1)
                        Text(meta).font(.system(size: 8)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 7).frame(height: compact ? 32 : 38)
                .background(Color(hex: item.colorHex).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).studioPointerCursor()
        }

        private var meta: String {
            if item.location == "Task due" || item.location == "Project starts" || item.location == "Project deadline" { return item.location }
            return item.date.formatted(date: .omitted, time: .shortened) + (item.location.isEmpty ? "" : " · " + item.location)
        }
    }

    private struct MonthGrid: View {
        @EnvironmentObject private var store: FramoStudioStore
        @Binding var selectedDate: Date
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

        private var days: [Date] {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month], from: selectedDate)
            let first = cal.date(from: comps) ?? selectedDate
            let weekday = cal.component(.weekday, from: first)
            let offset = -((weekday + 5) % 7)
            let start = cal.date(byAdding: .day, value: offset, to: first) ?? first
            return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }

        var body: some View {
            VStack(spacing: 5) {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(["M","T","W","T","F","S","S"].enumerated()), id: \.offset) { _, label in
                        Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(StudioTheme.tertiary).frame(height: 16)
                    }
                    ForEach(days, id: \.self) { day in dayCell(day) }
                }
            }
        }

        private func dayCell(_ day: Date) -> some View {
            let cal = Calendar.current
            let currentMonth = cal.component(.month, from: day) == cal.component(.month, from: selectedDate)
            let colors = store.calendarItems.filter { item in
                let current = cal.startOfDay(for: day)
                return current >= cal.startOfDay(for: item.date) && current <= cal.startOfDay(for: item.endDate)
            }.prefix(3).map(\.colorHex)
            return Button { selectedDate = day } label: {
                VStack(spacing: 3) {
                    Text(day.formatted(.dateTime.day())).font(.system(size: 9, weight: cal.isDate(day, inSameDayAs: selectedDate) ? .bold : .regular))
                    HStack(spacing: 2) { ForEach(Array(colors.enumerated()), id: \.offset) { _, color in Circle().fill(Color(hex: color)).frame(width: 3, height: 3) } }
                }
                .foregroundStyle(currentMonth ? StudioTheme.primary : StudioTheme.tertiary)
                .frame(maxWidth: .infinity).frame(height: 31)
                .background(cal.isDate(day, inSameDayAs: selectedDate) ? StudioTheme.selected : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).studioPointerCursor()
            .contextMenu {
                Button("Plan on this day") { selectedDate = day }
            }
        }
    }

    private struct LargeMonthGrid: View {
        @EnvironmentObject private var store: FramoStudioStore
        @Binding var selectedDate: Date
        let onCreateRange: (Date, Date) -> Void
        @State private var dragStartIndex: Int?
        @State private var dragCurrentIndex: Int?

        private let spacing: CGFloat = 8
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

        private var days: [Date] {
            let cal = Calendar.current
            let components = cal.dateComponents([.year, .month], from: selectedDate)
            let first = cal.date(from: components) ?? selectedDate
            let weekday = cal.component(.weekday, from: first)
            let offset = -((weekday + 5) % 7)
            let start = cal.date(byAdding: .day, value: offset, to: first) ?? first
            return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }

        private var dragRange: ClosedRange<Int>? {
            guard let start = dragStartIndex, let current = dragCurrentIndex else { return nil }
            return min(start, current)...max(start, current)
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 8) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(StudioTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7)
                        }
                    }

                    GeometryReader { proxy in
                        LazyVGrid(columns: columns, spacing: spacing) {
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                dayCell(day, index: index)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(monthDragGesture(size: proxy.size))
                    }
                    .frame(minHeight: 736)
                }
                .padding(.bottom, 12)
            }
        }

        private func monthDragGesture(size: CGSize) -> some Gesture {
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    guard let index = dayIndex(at: value.location, size: size) else { return }
                    if dragStartIndex == nil { dragStartIndex = index }
                    dragCurrentIndex = index
                    selectedDate = days[index]
                }
                .onEnded { value in
                    defer { dragStartIndex = nil; dragCurrentIndex = nil }
                    guard let startIndex = dragStartIndex,
                          let endIndex = dayIndex(at: value.location, size: size) ?? dragCurrentIndex else { return }
                    let lower = min(startIndex, endIndex)
                    let upper = max(startIndex, endIndex)
                    let cal = Calendar.current
                    let startDay = days[lower]
                    let endDay = days[upper]
                    let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: startDay) ?? startDay
                    let endHour = lower == upper ? 10 : 17
                    let end = cal.date(bySettingHour: endHour, minute: 0, second: 0, of: endDay) ?? endDay.addingTimeInterval(3600)
                    onCreateRange(start, end)
                }
        }

        private func dayIndex(at point: CGPoint, size: CGSize) -> Int? {
            let cellWidth = max(1, (size.width - spacing * 6) / 7)
            let cellHeight = max(1, (size.height - spacing * 5) / 6)
            let col = Int(point.x / (cellWidth + spacing))
            let row = Int(point.y / (cellHeight + spacing))
            guard col >= 0, col < 7, row >= 0, row < 6 else { return nil }
            let index = row * 7 + col
            return days.indices.contains(index) ? index : nil
        }

        private func dayCell(_ day: Date, index: Int) -> some View {
            let cal = Calendar.current
            let inMonth = cal.component(.month, from: day) == cal.component(.month, from: selectedDate)
            let selected = cal.isDate(day, inSameDayAs: selectedDate)
            let items = store.calendarItems.filter { item in
                let current = cal.startOfDay(for: day)
                return current >= cal.startOfDay(for: item.date) && current <= cal.startOfDay(for: item.endDate)
            }
            let inDrag = dragRange?.contains(index) == true

            return VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 12, weight: selected || inDrag ? .bold : .semibold))
                    Spacer()
                    if cal.isDateInToday(day) {
                        Text("TODAY").font(.system(size: 7, weight: .bold)).foregroundStyle(StudioTheme.secondary)
                    }
                }

                ForEach(items.prefix(3)) { item in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: item.colorHex)).frame(width: 3, height: 17)
                        Text(item.title).font(.system(size: 8, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(Color(hex: item.colorHex).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                if items.count > 3 {
                    Text("+\(items.count - 3) more")
                        .font(.system(size: 7, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(inMonth ? StudioTheme.primary : StudioTheme.tertiary)
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 116, alignment: .topLeading)
            .background(inDrag ? StudioTheme.selected : (selected ? StudioTheme.selected.opacity(0.7) : StudioTheme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(inDrag ? StudioTheme.primary.opacity(0.45) : (selected ? StudioTheme.primary.opacity(0.32) : StudioTheme.border)))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .onTapGesture { selectedDate = day }
            .studioPointerCursor()
        }
    }

    private struct CalendarTaskComposer: View {
        @EnvironmentObject private var store: FramoStudioStore
        @Environment(\.dismiss) private var dismiss
        let draft: TaskComposerDraft
        @State private var title: String
        @State private var projectID: UUID?
        @State private var hasDueDate: Bool
        @State private var dueDate: Date

        init(draft: TaskComposerDraft) {
            self.draft = draft
            _title = State(initialValue: draft.title)
            _projectID = State(initialValue: draft.projectID)
            _hasDueDate = State(initialValue: draft.dueDate != nil)
            _dueDate = State(initialValue: draft.dueDate ?? Date.now)
        }

        private var selectedProjectName: String {
            guard let projectID, let project = store.projects.first(where: { $0.id == projectID }) else { return "No project" }
            return project.title
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top) {
                    Text(draft.heading).font(.system(size: 19, weight: .semibold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                }

                StudioDialogField {
                    TextField("What needs to happen?", text: $title)
                        .textFieldStyle(.plain)
                        .studioTextCursor()
                        .font(.system(size: 13, weight: .medium))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("PROJECT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StudioTheme.tertiary)
                    Menu {
                        Button("No project") { projectID = nil }
                        ForEach(store.projects) { project in
                            Button(project.title) { projectID = project.id }
                        }
                    } label: {
                        HStack {
                            Text(selectedProjectName).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(StudioTheme.tertiary)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 40)
                        .background(StudioTheme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                }

                Toggle("Set a due date", isOn: $hasDueDate)
                    .font(.system(size: 11, weight: .medium))
                    .toggleStyle(.switch)

                if hasDueDate {
                    StudioDialogSurface {
                        HStack {
                            Text("Due")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StudioTheme.secondary)
                            Spacer()
                            DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                        }
                    }
                }

                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Add task") {
                        store.addTask(title: title, dueDate: hasDueDate ? dueDate : nil, projectID: projectID)
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
            .frame(width: 430)
            .background(StudioTheme.canvas)
        }
    }

    private struct PlanningComposer: View {
        @EnvironmentObject private var store: FramoStudioStore
        @Environment(\.dismiss) private var dismiss
        let draft: PlanningDraft
        @Binding var selectedDate: Date
        @State private var title = ""
        @State private var location = ""
        @State private var projectID: UUID?
        @State private var start: Date
        @State private var end: Date
        @State private var colorHex: String? = nil

        private let palette = ["6F7D8C", "4F7CAC", "2F9E77", "D08C60", "B06A7A", "8068B0", "9B7B47"]

        init(draft: PlanningDraft, selectedDate: Binding<Date>) {
            self.draft = draft
            _selectedDate = selectedDate
            _start = State(initialValue: draft.start)
            _end = State(initialValue: draft.end)
        }

        private var selectedProjectName: String {
            guard let projectID, let project = store.projects.first(where: { $0.id == projectID }) else { return "No project" }
            return project.title
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plan something")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Add a shoot, edit session, meeting or deadline.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                }

                TextField("Event, shoot, edit session…", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .studioTextCursor()
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 12) {
                    dateField("Start", selection: $start)
                    dateField("End", selection: $end, range: start...)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("PROJECT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StudioTheme.tertiary)
                    Menu {
                        Button("No project") { projectID = nil }
                        ForEach(store.projects) { project in
                            Button(project.title) {
                                projectID = project.id
                                colorHex = project.colorHex
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedProjectName)
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(StudioTheme.tertiary)
                        }
                        .foregroundStyle(StudioTheme.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(StudioTheme.soft.opacity(0.74))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                HStack(spacing: 9) {
                    Text("COLOR")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StudioTheme.tertiary)
                        .frame(width: 48, alignment: .leading)
                    Button { colorHex = nil } label: {
                        Text("Auto")
                            .font(.system(size: 8, weight: colorHex == nil ? .semibold : .medium))
                            .foregroundStyle(colorHex == nil ? StudioTheme.primary : StudioTheme.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(colorHex == nil ? StudioTheme.selected : StudioTheme.soft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                    ForEach(palette, id: \.self) { hex in
                        Button { colorHex = hex } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 19, height: 19)
                                .overlay {
                                    if colorHex == hex {
                                        Circle().stroke(StudioTheme.primary.opacity(0.85), lineWidth: 2).padding(-3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .studioPointerCursor()
                    }
                    Spacer()
                }

                TextField("Location (optional)", text: $location)
                    .textFieldStyle(.plain)
                    .studioTextCursor()
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(StudioTheme.input.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Add to calendar") {
                        store.createEvent(title: title, start: start, end: end, projectID: projectID, location: location, colorHex: colorHex)
                        selectedDate = start
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(StudioTheme.canvas)
        }

        private func dateField(_ label: String, selection: Binding<Date>, range: PartialRangeFrom<Date>? = nil) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)
                Group {
                    if let range {
                        DatePicker("", selection: selection, in: range, displayedComponents: [.date, .hourAndMinute])
                    } else {
                        DatePicker("", selection: selection, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct CalendarEventInspector: View {
        @EnvironmentObject private var store: FramoStudioStore
        @Environment(\.dismiss) private var dismiss
        let item: StudioEvent
        private let palette = ["547AA5", "4B8C75", "A36E57", "7A68A6", "A47C43", "9A6275", "5E858C"]

        private var project: StudioProject? {
            item.projectID.flatMap { id in store.projects.first(where: { $0.id == id }) }
        }

        private var isStoredEvent: Bool {
            store.events.contains(where: { $0.id == item.id })
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(hex: item.colorHex))
                        .frame(width: 5, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(kindLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                }

                VStack(alignment: .leading, spacing: 10) {
                    detailRow("Start", value: item.date.formatted(date: .abbreviated, time: .shortened))
                    detailRow("End", value: item.endDate.formatted(date: .abbreviated, time: .shortened))
                    if !item.location.isEmpty { detailRow("Location", value: item.location) }
                    if let project { detailRow("Project", value: project.title) }
                }
                .padding(13)
                .background(StudioTheme.soft.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 9) {
                    Text(isStoredEvent ? "COLOR" : (project == nil ? "COLOR" : "PROJECT COLOR"))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StudioTheme.tertiary)
                    HStack(spacing: 9) {
                        ForEach(palette, id: \.self) { hex in
                            Button {
                                store.setCalendarItemColor(item, colorHex: hex)
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 21, height: 21)
                                    .overlay {
                                        if (store.inspectedCalendarItem?.colorHex ?? item.colorHex) == hex {
                                            Circle().stroke(StudioTheme.primary.opacity(0.82), lineWidth: 2).padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .studioPointerCursor()
                        }
                    }
                    if !isStoredEvent, project != nil {
                        Text("This item inherits its project color, so changing it keeps the calendar consistent.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                }

                HStack {
                    if let project {
                        Button("Open work") {
                            dismiss()
                            store.openProject(project.id)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else if item.location == "Task due" {
                        Button("Open tasks") {
                            dismiss()
                            store.openDestination(.tasks)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(20)
            .frame(width: 420)
            .background(StudioTheme.canvas)
        }

        private var kindLabel: String {
            if item.location == "Task due" { return "Task deadline" }
            if item.location == "Project starts" { return "Project start" }
            if item.location == "Project deadline" { return "Project deadline" }
            return "Calendar event"
        }

        private func detailRow(_ label: String, value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.tertiary)
                    .frame(width: 56, alignment: .leading)
                Text(value)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    private struct CalendarProjectRow: View {
        @EnvironmentObject private var store: FramoStudioStore
        let project: StudioProject

        var body: some View {
            Button { store.openProject(project.id) } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: project.colorHex)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                        Text(project.status.rawValue).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Text(project.dueDate.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 8, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                }
                .foregroundStyle(StudioTheme.primary)
                .padding(.horizontal, 9).frame(height: 42)
                .background(StudioTheme.soft.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain).studioPointerCursor()
        }
    }

}

struct FramoSpaceViewV13: View {
    @EnvironmentObject private var store: FramoStudioStore
    let spaceID: UUID
    @State private var tab = "Work"
    @State private var coverHovered = false
    @State private var showingCoverControls = false

    private var spaceBinding: Binding<StudioSpace>? {
        guard let index = store.spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
        return $store.spaces[index]
    }

    var body: some View {
        if let space = spaceBinding {
            ScrollView {
                VStack(spacing: 0) {
                    spaceBanner(space)
                    VStack(alignment: .leading, spacing: 20) {
                        spaceHeader(space)
                        spaceTabs(space)
                        Divider()
                        content(space)
                    }
                    .padding(.horizontal, 34).padding(.bottom, 50)
                }
            }
        } else {
            EmptyState(icon: "square.stack.3d.up.slash", title: "Space not found", message: "This space may have been removed.")
        }
    }

    private func spaceBanner(_ space: Binding<StudioSpace>) -> some View {
        ZStack(alignment: .bottomTrailing) {
            ProjectBanner(path: space.wrappedValue.bannerPath, assetName: space.wrappedValue.bannerAssetName, colorHex: space.wrappedValue.colorHex, height: space.wrappedValue.effectiveBannerHeight, focusY: space.wrappedValue.effectiveBannerFocusY, fadeBottom: true)
                .onHover { coverHovered = $0 }
            if coverHovered {
                Button { showingCoverControls.toggle() } label: {
                    Label("Change cover", systemImage: "photo").font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 6).background(.black.opacity(0.58)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).studioPointerCursor().padding(16)
                .popover(isPresented: $showingCoverControls) { SpaceCoverControls(space: space) }
            }
        }
    }

    private func spaceHeader(_ space: Binding<StudioSpace>) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: space.wrappedValue.emoji.isEmpty ? "square.stack.3d.up" : space.wrappedValue.emoji)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(StudioTheme.icon)
                .frame(width: 48, height: 48)
                .background(StudioTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Space name", text: space.title)
                    .textFieldStyle(.plain).studioTextCursor()
                    .font(.system(size: 29, weight: .bold))
                TextField("What belongs in this space?", text: space.subtitle)
                    .textFieldStyle(.plain).studioTextCursor()
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func spaceTabs(_ space: Binding<StudioSpace>) -> some View {
        HStack(spacing: 18) {
            ForEach(["Work", "Pipeline", "Notes"], id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 7) {
                        Text(item)
                            .font(.system(size: 11, weight: tab == item ? .semibold : .medium))
                            .foregroundStyle(tab == item ? StudioTheme.primary : StudioTheme.secondary)
                        Capsule()
                            .fill(tab == item ? StudioTheme.primary : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).studioPointerCursor()
            }
            Spacer()
            Menu("Add existing") {
                ForEach(store.projects.filter { !space.wrappedValue.projectIDs.contains($0.id) }) { project in
                    Button(project.title) { space.wrappedValue.projectIDs.append(project.id) }
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).studioPointerCursor()
            Button("New work") { store.requestProjectCreation() }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(height: 38)
    }

    @ViewBuilder private func content(_ space: Binding<StudioSpace>) -> some View {
        switch tab {
        case "Pipeline": spacePipeline(space.wrappedValue)
        case "Notes":
            TextEditor(text: space.notes).font(.system(size: 12)).scrollContentBackground(.hidden)
                .padding(14).frame(minHeight: 260).background(StudioTheme.elevated)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.border)).clipShape(RoundedRectangle(cornerRadius: 9))
        default: spaceProjects(space.wrappedValue)
        }
    }

    private func spaceProjects(_ space: StudioSpace) -> some View {
        let projects = store.projects.filter { space.projectIDs.contains($0.id) }
        return VStack(spacing: 0) {
            HStack { Text("STATUS").frame(width: 120, alignment: .leading); Text("PROJECT").frame(maxWidth: .infinity, alignment: .leading); Text("CLIENT").frame(width: 170, alignment: .leading); Text("DUE").frame(width: 80, alignment: .leading) }
                .font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary).padding(.horizontal, 12).frame(height: 36)
            Divider()
            ForEach(projects) { project in
                Button { store.openProject(project.id) } label: {
                    HStack(spacing: 11) {
                        StatusPill(status: project.status).frame(width: 120, alignment: .leading)
                        HStack(spacing: 8) { Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 18); Text(project.title).fontWeight(.semibold).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(project.client).frame(width: 170, alignment: .leading).foregroundStyle(StudioTheme.secondary)
                        Text(project.dueDate.shortStudioDate).frame(width: 80, alignment: .leading).foregroundStyle(StudioTheme.secondary)
                    }
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.primary).padding(.horizontal, 12).frame(height: 49).contentShape(Rectangle())
                }.buttonStyle(.plain).studioPointerCursor()
                Divider().padding(.leading, 12)
            }
            if projects.isEmpty { Text("No projects in this space yet.").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).padding(36) }
        }
        .background(StudioTheme.elevated).overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.border)).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func spacePipeline(_ space: StudioSpace) -> some View {
        let projects = store.projects.filter { space.projectIDs.contains($0.id) }
        let statuses = ProjectStatus.allCases
        return GeometryReader { proxy in
            let available = max(0, proxy.size.width - CGFloat(max(0, statuses.count - 1)) * 10)
            let columnWidth = max(210, available / CGFloat(max(1, statuses.count)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(statuses, id: \.self) { status in
                        pipelineColumn(status, projects: projects)
                            .frame(width: columnWidth)
                    }
                }
                .frame(minWidth: proxy.size.width, alignment: .leading)
                .padding(.bottom, 8)
            }
        }
        .frame(minHeight: 520)
    }

    private func pipelineColumn(_ status: ProjectStatus, projects: [StudioProject]) -> some View {
        let items = projects.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.rawValue).font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("\(items.count)").font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 2)

            ForEach(items) { project in
                Button { store.openProject(project.id) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 22)
                            Text(project.title).font(.system(size: 10, weight: .semibold)).lineLimit(2)
                        }
                        HStack {
                            Text(project.client).font(.system(size: 8)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                            Spacer()
                            Text(project.dueDate.shortStudioDate).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                        }
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.elevated)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).studioPointerCursor()
                .draggable("project:\(project.id.uuidString)")
            }
            Spacer(minLength: 12)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 500, alignment: .top)
        .background(StudioTheme.soft)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border.opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { values, _ in
            guard let raw = values.first else { return false }
            let token = raw.hasPrefix("project:") ? String(raw.dropFirst(8)) : raw
            guard let id = UUID(uuidString: token) else { return false }
            store.setProjectStatus(id, status: status)
            return true
        }
    }
}

private struct SpaceCoverControls: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var space: StudioSpace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Space cover").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(["banner", "banner1", "banner3"], id: \.self) { name in
                    Button { space.bannerPath = nil; space.bannerAssetName = name } label: {
                        ProjectBanner(path: nil, assetName: name, colorHex: space.colorHex, height: 50)
                            .frame(width: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).studioPointerCursor()
                }
            }
            Button("Choose image…") { chooseBanner() }.buttonStyle(SecondaryButtonStyle())
            Text("SIZE").framoSettingsMicroLabelV13(); Slider(value: Binding(get: { space.bannerHeight ?? 210 }, set: { space.bannerHeight = $0 }), in: 140...320, step: 5)
            Text("FOCUS").framoSettingsMicroLabelV13(); Slider(value: Binding(get: { space.bannerFocusY ?? 0.5 }, set: { space.bannerFocusY = $0 }), in: 0...1)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(14).frame(width: 290).background(StudioTheme.elevated)
    }

    private func chooseBanner() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let managedPath = store.importManagedImageForWorkspace(from: url, category: "Space Banners") {
            space.bannerPath = managedPath
            space.bannerAssetName = nil
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case language = "Language & Region"
    case appearance = "Appearance"
    case brand = "Brand"
    case notifications = "Notifications"
    case profiles = "Workspaces & Security"
    case workflow = "Workflow"
    case data = "Workspace"
    case health = "System Health"
    case plugins = "Extensions"
    case transfer = "Connect"
    case integrations = "Store"
    case updates = "Version"
    case advanced = "Advanced"
    case legal = "Privacy & Legal"
    case about = "About"

    var id: String { rawValue }
}

private enum FramoLegalDocument: String, Identifiable {
    case terms = "Terms of Use"
    case privacy = "Privacy Policy"
    case licenses = "Open-source & third-party notices"
    case data = "Data & permissions"

    var id: String { rawValue }
    var title: String { rawValue }

    var intro: String {
        switch self {
        case .terms: "Rules for using MODO and its production-workspace features."
        case .privacy: "How MODO handles workspace data, files, networking and optional integrations."
        case .licenses: "Notes for Apple frameworks, plug-ins and other third-party components used by a MODO build."
        case .data: "A plain-language overview of where MODO data lives and what optional permissions can do."
        }
    }

    var sections: [(String, String)] {
        switch self {
        case .terms:
            return [
                ("Using MODO", "You may use MODO to plan, manage and deliver production work. You are responsible for the projects, media, client information and other material you add to the app, and for making sure you have permission to use or share that material."),
                ("Backups and availability", "MODO is designed around a local workspace. Keep appropriate backups of important production data and linked media. Features that depend on a network, another device, a plug-in or a third-party service may be unavailable when those dependencies are unavailable."),
                ("Sharing and integrations", "When you enable MODO Connect, plug-ins or integrations, you choose what information leaves the local workspace. Nearby Connect is device-to-device. Remote Connect can route through the Tor network when you enable it."),
                ("Software changes", "MODO can add, change or retire features between releases. Features can require a minimum MODO version and remain locked until the application is updated."),
                ("Responsibility", "Use MODO in a way that complies with applicable law, contracts and client obligations. Do not use the software to access systems or data you are not authorized to access.")
            ]
        case .privacy:
            return [
                ("Local workspace", "MODO stores its core workspace database on your Mac. Linked production media can remain in the locations you choose instead of being copied into a central MODO cloud by default."),
                ("Network activity", "MODO can use the network when you explicitly enable features such as Nearby Connect, Remote Connect over Tor, plug-ins, integrations or software-update checks. Remote Connect launches the Tor executable you selected or the one bundled with MODO."),
                ("Third parties", "A plug-in or integration can transmit data to its own service when you enable and use it. Review that provider's policy before connecting client or confidential production data."),
                ("Deletion", "Reset and erase controls in Settings remove the local workspace data managed by MODO. They do not automatically delete external backups, files on other drives, copies already shared with another device or data held by a third-party service."),
                ("Diagnostics", "This build exposes version, build, database and update-status information in Settings. Add any analytics, crash-reporting or telemetry disclosures here if those services are added to a distributed build.")
            ]
        case .licenses:
            return [
                ("Apple frameworks", "MODO uses macOS system frameworks such as SwiftUI, AppKit, MapKit, EventKit, Network and related Apple APIs. Their use is governed by Apple's platform and developer terms."),
                ("Plug-ins", "Installed MODO plug-ins and adapters can have separate licenses. Their name, version, author and permissions are visible in Settings → Plugins."),
                ("Open-source notices", "If you add an open-source package, keep its required copyright and license notice with the distributed app and list it here or in an accompanying notices file."),
                ("Bundled resources", "Icons, templates, images, fonts and other bundled resources should only be distributed when you have the necessary rights or license to do so.")
            ]
        case .data:
            return [
                ("Workspace database", "Work, tasks, calendar items, spaces, saved places and MODO preferences are encoded in the local workspace database shown in Settings → Project & Data."),
                ("Files", "MODO can reference media and documents at paths you choose. Removing a reference from MODO does not necessarily delete the original file from disk."),
                ("Permissions", "macOS can ask for access when MODO uses protected capabilities such as calendars, selected folders or local-network features. You can review system permissions in macOS Settings."),
                ("Export and sharing", "Anything you export or share leaves the local workspace under the destination and access rules you choose. Check client confidentiality requirements before sharing."),
                ("Erase", "Settings → Advanced contains reset and erase actions. Use a backup first when the workspace contains production data you cannot recreate.")
            ]
        }
    }
}

struct FramoLockedFeatureView: View {
    @EnvironmentObject private var store: FramoStudioStore
    let feature: FramoFeature

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(StudioTheme.elevated)
                    .frame(width: 62, height: 62)
                Image(systemName: "lock.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Text(feature.title).font(.system(size: 24, weight: .semibold))
            Text("Requires MODO \(feature.minimumVersion) or newer")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioTheme.secondary)
            Text(feature.summary)
                .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Open Updates") {
                store.requestedSettingsPane = "Updates"
                store.openDestination(.settings)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.canvas)
    }
}

struct FramoSettingsView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var category: SettingsCategory = .general
    @State private var interfaceScaleDraft: Double = 1.0
    @State private var showingOnboarding = false
    @State private var confirmFullReset = false
    @State private var confirmFactoryReset = false
    @State private var legalDocument: FramoLegalDocument?
    @State private var deleteRequest: DeleteRequest?
    @State private var showingProfileCreator = false
    @State private var profileNameDraft = ""
    @State private var profilePasswordDraft = ""
    @State private var profilePasswordConfirm = ""
    @State private var recoveryKit: ModoRecoveryKit?
    @State private var integrationRefreshToken = 0
    @State private var cloudShareEmail = ""
    @State private var cloudShareReadOnly = false
    @State private var showPlannedConnectors = false

    private struct DeleteRequest: Identifiable {
        let id = UUID()
        let kind: String
        let targetID: UUID
        let title: String
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(category.rawValue).font(.system(size: 24, weight: .semibold))
                    settingsPane
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 34).padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(StudioTheme.canvas)
        .onAppear {
            interfaceScaleDraft = store.settings.effectiveScale
            profileNameDraft = store.activeProfileName
            applyRequestedPane(store.requestedSettingsPane)
        }
        .onChange(of: store.requestedSettingsPane) { _, value in applyRequestedPane(value) }
        .onChange(of: store.activeProfileID) { _, _ in
            profileNameDraft = store.activeProfileName
            profilePasswordDraft = ""
            profilePasswordConfirm = ""
        }
        .onReceive(store.googleConnector.objectWillChange) { _ in integrationRefreshToken &+= 1 }
        .onReceive(store.frameIOConnector.objectWillChange) { _ in integrationRefreshToken &+= 1 }
        .onReceive(store.cloudSync.objectWillChange) { _ in integrationRefreshToken &+= 1 }
        .onReceive(store.mcpServer.objectWillChange) { _ in integrationRefreshToken &+= 1 }
        .onReceive(store.peppolConnector.objectWillChange) { _ in integrationRefreshToken &+= 1 }
        .sheet(isPresented: $showingOnboarding) {
            FramoOnboardingViewV20(isPresented: $showingOnboarding).environmentObject(store)
        }
        .sheet(isPresented: $showingProfileCreator) {
            FramoProfileCreatorSheet().environmentObject(store)
        }
        .sheet(item: $recoveryKit) { kit in
            ModoRecoveryKitSheet(kit: kit) {
                recoveryKit = nil
            }
        }
        .sheet(item: $legalDocument) { document in
            FramoLegalDocumentView(document: document)
        }
        .alert("Reset workspace & redo onboarding?", isPresented: $confirmFullReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset workspace", role: .destructive) {
                store.resetWorkspaceToOnboarding()
            }
        } message: {
            Text("This clears this workspace's business data, settings, brand assets, connectors and managed media, then starts onboarding again. The workspace container, password/recovery access and external backups are kept.")
        }
        .alert("Factory reset MODO?", isPresented: $confirmFactoryReset) {
            Button("Cancel", role: .cancel) { }
            Button("Factory reset", role: .destructive) {
                store.factoryResetMODO()
            }
        } message: {
            Text("This removes MODO's local workspaces, local credentials, recovery setup, cached connector access and app preferences from this Mac. External portable workspaces and external backups are not deleted. This cannot be undone.")
        }
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text("Remove \(request.title)?"),
                message: Text(request.kind == "project" ? "This also removes its MODO tasks and calendar items. Linked files on disk are not deleted." : "This removes the saved place from MODO."),
                primaryButton: .destructive(Text("Remove")) {
                    if request.kind == "project" { store.deleteProject(request.targetID) }
                    else { store.deletePlace(request.targetID) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func applyRequestedPane(_ value: String?) {
        guard let value else { return }
        switch value {
        case "Project & Data", "Data", "Workspace": category = .data
        case "System Health", "Health", "Diagnostics": category = .health
        case "Notifications", "Notification settings": category = .notifications
        case "Brand", "Brand assets", "Identity": category = .brand
        case "Workspaces & Security", "Profiles & Security", "Profiles", "Security", "Workspaces": category = .profiles
        case "Plugins", "Extensions": category = .plugins
        case "Store", "Connectors", "Integrations": category = .integrations
        case "Sharing", "MODO Connect", "Connect": category = .transfer
        case "Updates", "Changelog", "Version": category = .updates
        case "Privacy & Legal", "Legal", "Privacy": category = .legal
        case "Advanced": category = .advanced
        default: break
        }
        store.requestedSettingsPane = nil
    }

    private var visibleCategories: [SettingsCategory] { [.general, .appearance, .brand, .profiles, .notifications, .data, .health, .transfer, .integrations, .plugins, .updates, .about] }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                Text("MODO preferences")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 13).padding(.top, 16).padding(.bottom, 10)

            ForEach(visibleCategories) { item in
                Button { category = item } label: {
                    HStack(spacing: 9) {
                        Text(item.rawValue)
                        Spacer()
                    }
                    .font(.system(size: 12, weight: category == item ? .medium : .regular))
                    .foregroundStyle(category == item ? StudioTheme.primary : StudioTheme.secondary)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(category == item ? StudioTheme.soft.opacity(0.94) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain).studioPointerCursor()
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("MODO \(FramoStudioStore.appVersion)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
                Text("Build \(FramoStudioStore.buildNumber)")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 11).padding(.bottom, 12)
        }
        .padding(.horizontal, 7)
        .frame(width: 190)
        .background(StudioTheme.canvas)
    }

    @ViewBuilder private var settingsPane: some View {
        switch category {
        case .general: generalPane
        case .language: languagePane
        case .appearance: appearancePane
        case .brand: brandPane
        case .profiles: profilesPane
        case .notifications: notificationPane
        case .workflow: workflowPane
        case .data: dataManagerPane
        case .health: systemHealthPane
        case .plugins: PluginSettingsPane(manager: store.pluginManager, syncthing: store.syncthing).environmentObject(store)
        case .transfer:
            TransferSettingsPane(service: store.localTransfer, host: store.hostSharing, remote: store.remoteAccess, tor: store.torConnect).environmentObject(store)
        case .integrations: integrationsPane
        case .updates: updatesPane
        case .advanced: advancedPane
        case .legal: legalPane
        case .about: aboutPane
        }
    }

    private var systemHealthPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("Workspace") {
                healthRow("Workspace", value: store.activeProfileName, state: .good)
                healthRow("Database", value: ByteCountFormatter.string(fromByteCount: store.databaseByteSize, countStyle: .file), state: .good)
                healthRow("Last save", value: "Local workspace active", state: .good)
                healthRow("Backup", value: store.backupStatus, state: store.settings.lastBackupDate == nil ? .warning : .good)
                HStack(spacing: 8) {
                    Button("Back up now") { store.runBackupNow() }.buttonStyle(SecondaryButtonStyle())
                    Button("Reveal workspace") { store.revealActiveProfileFolder() }.buttonStyle(SecondaryButtonStyle())
                    Button("Reveal database") { store.revealDatabase() }.buttonStyle(SecondaryButtonStyle())
                }
            }

            settingsGroup("Connections") {
                healthRow("CloudKit", value: store.cloudSync.accountStatus, state: store.cloudSync.accountStatus.localizedCaseInsensitiveContains("available") || store.cloudSync.accountStatus.localizedCaseInsensitiveContains("signed") ? .good : .neutral)
                healthRow("Google Drive + Docs", value: store.googleConnector.isConnected ? (store.googleConnector.accountEmail.isEmpty ? "Connected" : store.googleConnector.accountEmail) : "Not connected", state: store.googleConnector.isConnected ? .good : .neutral)
                healthRow("Frame.io", value: store.frameIOConnector.isConnected ? (store.frameIOConnector.accountName.isEmpty ? "Connected" : store.frameIOConnector.accountName) : "Not connected", state: store.frameIOConnector.isConnected ? .good : .neutral)
                healthRow("Peppol", value: store.peppolConnector.state.label, state: .neutral)
                healthRow("MCP", value: store.mcpServer.state.label, state: store.settings.effectiveMCPEnabled ? .good : .neutral)
                HStack(spacing: 8) {
                    Button("Sync now") { Task { await store.cloudSync.syncNow(); await store.googleConnector.checkIncrementalChanges() } }.buttonStyle(PrimaryButtonStyle())
                    Button("Open connectors") { category = .integrations }.buttonStyle(SecondaryButtonStyle())
                }
            }

            settingsGroup("Data ownership") {
                healthRow("Work", value: "\(store.projects.count)", state: .good)
                healthRow("Customers", value: "\(store.business.organizations.count)", state: .good)
                healthRow("Tasks", value: "\(store.tasks.count)", state: .good)
                healthRow("Invoices", value: "\(store.invoices.count)", state: .good)
                healthRow("Linked media", value: ByteCountFormatter.string(fromByteCount: store.linkedMediaBytes, countStyle: .file), state: .neutral)
                Text("MODO keeps the core workspace local. Connectors are optional and should never be the only copy of business data.")
                    .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum HealthState: Equatable { case good, warning, neutral }

    private func healthRow(_ title: String, value: String, state: HealthState) -> some View {
        HStack(spacing: 10) {
            Circle().fill(state == .good ? StudioTheme.green : state == .warning ? StudioTheme.red : StudioTheme.tertiary).frame(width: 7, height: 7)
            Text(title).font(.system(size: 10, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
        }
        .frame(minHeight: 28)
    }

    private var categorySubtitle: String { "" }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Studio") {
                settingField("Your name", text: $store.settings.ownerName)
                Spacer().frame(height: 2)
                settingField("Studio name", text: $store.settings.studioName)
                Spacer().frame(height: 2)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MODO mode")
                        Text(store.settings.effectiveWorkspaceMode.subtitle).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { store.settings.effectiveWorkspaceMode },
                        set: { store.setWorkspaceMode($0) }
                    )) {
                        ForEach(ModoWorkspaceMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Spacer().frame(height: 2)
                HStack {
                    Text("Default hourly rate")
                    Spacer()
                    TextField("65", value: $store.settings.defaultRate, format: .number)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 9).frame(width: 88, height: 30)
                        .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(store.settings.currency).foregroundStyle(StudioTheme.secondary)
                }
            }

            settingsGroup("Modules") {
                let configurable = SidebarDestination.allCases.filter {
                    ![SidebarDestination.home, .search, .settings].contains($0)
                }

                ForEach(configurable) { destination in
                    HStack(spacing: 10) {
                        Image(systemName: destination.fallback)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StudioTheme.secondary)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.displayName)
                                .font(.system(size: 10, weight: .medium))
                            Text(settingsModuleDescription(destination))
                                .font(.system(size: 8))
                                .foregroundStyle(StudioTheme.tertiary)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { store.settings.effectiveEnabledDestinations.contains(destination) },
                            set: { store.setEnabledDestination(destination, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .frame(minHeight: 34)
                }

                Text("Your selected MODO mode can temporarily focus this set further. Turning a module off hides its UI, commands, Today cards, notifications and MCP exposure without deleting its stored data.")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsGroup("Quick time tracking") {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Time manager").fontWeight(.medium)
                        Text("Use ⌥⌘F to start, switch, pause or stop tracking from one compact launcher.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Open") { store.showTimeLauncher = true }.buttonStyle(SecondaryButtonStyle())
                }
                Toggle("Show MODO Time around the MacBook notch", isOn: Binding(
                    get: { store.settings.effectiveNotchTimerEnabled },
                    set: { store.settings.notchTimerEnabled = $0; FramoNotchTimerController.shared.refreshPreferences() }
                ))
                .font(.system(size: 10))
                Text("Hover the camera housing to open the compact project picker. Macs without a display notch use a normal menu-bar item instead.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                Toggle("Show elapsed time on the Dock icon", isOn: Binding(
                    get: { store.settings.effectiveDockTimerBadgeEnabled },
                    set: { store.settings.dockTimerBadgeEnabled = $0 }
                ))
                .font(.system(size: 10))
            }

            settingsGroup("Workspace") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New work")
                        Text("Choose a work type, then MODO reveals only the depth that job needs.").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Create") { store.requestProjectCreation() }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer().frame(height: 2)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Feature introductions")
                        Text("Show the small, skippable guide cards again on every page.").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Reset tips") { store.resetFeatureIntroductions() }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer().frame(height: 2)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Onboarding")
                        Text("Replay the first-run overview.").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Redo onboarding") { store.resetOnboarding(); showingOnboarding = true }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }


    private var brandPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("Brand identity") {
                HStack(alignment: .top, spacing: 14) {
                    brandPrimarySlot(
                        title: "Primary logo",
                        subtitle: "Used on quotes, invoices, exports and client-facing documents.",
                        asset: store.primaryBrandLogo,
                        kind: .logo
                    )

                    brandPrimarySlot(
                        title: "App / brand icon",
                        subtitle: "Compact mark for avatars, favicons and small placements.",
                        asset: store.primaryBrandIcon,
                        kind: .icon
                    )
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PRIMARY COLOR")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(StudioTheme.tertiary)
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hex: store.settings.effectiveBrandPrimaryHex))
                                .frame(width: 30, height: 30)
                            TextField(
                                "#111111",
                                text: Binding(
                                    get: { store.settings.brandPrimaryHex ?? "111111" },
                                    set: { store.settings.brandPrimaryHex = normalizedBrandHex($0) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .studioTextCursor()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                        .background(StudioTheme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("SECONDARY COLOR")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(StudioTheme.tertiary)
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hex: store.settings.effectiveBrandSecondaryHex))
                                .frame(width: 30, height: 30)
                            TextField(
                                "#E9E9E6",
                                text: Binding(
                                    get: { store.settings.brandSecondaryHex ?? "E9E9E6" },
                                    set: { store.settings.brandSecondaryHex = normalizedBrandHex($0) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .studioTextCursor()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 38)
                        .background(StudioTheme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }

            settingsGroup("Asset library") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.brandAssets.count) asset\(store.brandAssets.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                        Text("MODO copies brand assets into Managed Media so they remain available if the original file moves.")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }

                    Spacer()

                    Menu {
                        Button("Logo…", systemImage: "rectangle.3.group") { chooseBrandAsset(.logo) }
                        Button("Icon…", systemImage: "app") { chooseBrandAsset(.icon) }
                        Button("Brand mark…", systemImage: "seal") { chooseBrandAsset(.mark) }
                        Button("Image…", systemImage: "photo") { chooseBrandAsset(.image) }
                    } label: {
                        Label("Add asset", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)

                    Button("Reveal files") {
                        store.revealManagedMedia()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if store.brandAssets.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                        Text("No brand assets yet")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Add logos, icons, marks and reusable brand imagery.")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 10)], spacing: 10) {
                        ForEach(store.brandAssets) { asset in
                            brandAssetCard(asset)
                        }
                    }
                }
            }
        }
    }

    private func brandPrimarySlot(
        title: String,
        subtitle: String,
        asset: ModoBrandAsset?,
        kind: ModoBrandAssetKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))

            Button {
                chooseBrandAsset(kind, makePrimary: true)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(StudioTheme.soft.opacity(0.60))

                    if let asset,
                       let image = NSImage(contentsOfFile: asset.path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 18, weight: .medium))
                            Text("Choose \(kind.rawValue.lowercased())")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(StudioTheme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(StudioTheme.border.opacity(0.72), lineWidth: 0.7)
                }
            }
            .buttonStyle(.plain)
            .studioPointerCursor()

            Text(subtitle)
                .font(.system(size: 8))
                .foregroundStyle(StudioTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func brandAssetCard(_ asset: ModoBrandAsset) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(StudioTheme.soft.opacity(0.62))

                if let image = NSImage(contentsOfFile: asset.path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    Image(systemName: asset.kind.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                }
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name)
                        .font(.system(size: 9.5, weight: .semibold))
                        .lineLimit(1)
                    Text(asset.kind.rawValue)
                        .font(.system(size: 8))
                        .foregroundStyle(StudioTheme.tertiary)
                }

                Spacer()

                Menu {
                    if asset.kind == .logo {
                        Button("Use as primary logo") { store.setPrimaryBrandLogo(asset.id) }
                    }
                    if asset.kind == .icon {
                        Button("Use as primary icon") { store.setPrimaryBrandIcon(asset.id) }
                    }
                    Divider()
                    Button("Remove", role: .destructive) { store.removeBrandAsset(asset.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .padding(10)
        .background(StudioTheme.elevated.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func chooseBrandAsset(_ kind: ModoBrandAssetKind, makePrimary: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.title = "Add \(kind.rawValue.lowercased())"
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = store.addBrandAsset(from: url, kind: kind, makePrimary: makePrimary)
    }

    private func normalizedBrandHex(_ value: String) -> String {
        String(value.uppercased().filter { $0.isHexDigit }.prefix(6))
    }

    private var profilesPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Current workspace") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.activeProfileName).font(.system(size: 11, weight: .semibold))
                        Text(store.activeProfile?.storageKind.rawValue ?? "Workspace")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Reveal folder") { store.revealActiveProfileFolder() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                HStack(spacing: 8) {
                    TextField("Workspace name", text: $profileNameDraft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(StudioTheme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button("Rename") { store.renameActiveProfile(profileNameDraft) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileNameDraft == store.activeProfileName)
                }
                if let path = store.activeProfile?.externalPath, store.activeProfile?.storageKind == .portable {
                    Text(path).font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
            }

            settingsGroup("App lock") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.activeProfile?.isPasswordProtected == true ? "Password protected" : "No workspace password")
                            .font(.system(size: 10, weight: .medium))
                        Text("Locks access inside MODO. For encrypted files at rest, use FileVault or an encrypted removable volume.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    if store.activeProfile?.isPasswordProtected == true {
                        Button("Lock now") { store.lockActiveProfile() }.buttonStyle(SecondaryButtonStyle())
                    }
                }

                SecureField(store.activeProfile?.isPasswordProtected == true ? "New password" : "Password", text: $profilePasswordDraft)
                    .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34)
                    .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                SecureField("Confirm password", text: $profilePasswordConfirm)
                    .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34)
                    .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    if store.activeProfile?.isPasswordProtected == true {
                        Button("Remove password") {
                            store.setActiveProfilePassword("")
                            profilePasswordDraft = ""
                            profilePasswordConfirm = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                    Button(store.activeProfile?.isPasswordProtected == true ? "Change password" : "Set password") {
                        guard profilePasswordDraft == profilePasswordConfirm else { return }
                        let changed = store.setActiveProfilePassword(profilePasswordDraft)
                        profilePasswordDraft = ""
                        profilePasswordConfirm = ""
                        if changed,
                           !store.activeProfileHasRecoveryCodes,
                           !store.activeProfileHasAuthenticator {
                            recoveryKit = store.regenerateActiveProfileRecoveryKit()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(profilePasswordDraft.isEmpty || profilePasswordDraft != profilePasswordConfirm)
                }

                if store.activeProfile?.isPasswordProtected == true {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic lock")
                            Text("Locks MODO after inactivity.").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.activeProfile?.effectiveAutoLockMinutes ?? 15 },
                            set: { store.setActiveProfileAutoLock(minutes: $0) }
                        )) {
                            Text("Never").tag(0)
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                        }
                        .labelsHidden().frame(width: 150)
                    }


                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recovery access")
                                .font(.system(size: 10, weight: .medium))

                            let configured = store.activeProfileHasRecoveryCodes || store.activeProfileHasAuthenticator
                            Text(configured
                                 ? "Authenticator and one-time backup codes can unlock this workspace if the password or Touch ID is unavailable."
                                 : "Set up an Authenticator key and one-time backup codes before you need them.")
                                .font(.system(size: 8))
                                .foregroundStyle(StudioTheme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        HStack(spacing: 7) {
                            if store.activeProfileHasRecoveryCodes || store.activeProfileHasAuthenticator {
                                Button("Remove") {
                                    store.disableActiveProfileRecovery()
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }

                            Button(
                                store.activeProfileHasRecoveryCodes || store.activeProfileHasAuthenticator
                                    ? "Regenerate…"
                                    : "Set up…"
                            ) {
                                recoveryKit = store.regenerateActiveProfileRecoveryKit()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }

            settingsGroup("Workspaces") {
                ForEach(store.profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.storageKind == .portable ? "externaldrive" : "internaldrive")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.system(size: 10, weight: .medium))
                            HStack(spacing: 5) {
                                Text(profile.storageKind.rawValue)
                                if profile.isPasswordProtected { Text("· Locked") }
                            }
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                        }
                        Spacer()
                        if profile.id == store.activeProfileID {
                            Text("Current").font(.system(size: 8, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
                        } else {
                            Button("Switch") { store.switchProfile(to: profile.id) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .frame(minHeight: 40)
                }

                HStack(spacing: 8) {
                    Button("New workspace…") { showingProfileCreator = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Open portable…") { openPortableProfileFromSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func openPortableProfileFromSettings() {
        let panel = NSOpenPanel()
        panel.title = "Open portable MODO workspace"
        panel.prompt = "Open Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = store.registerPortableProfile(at: url)
        }
    }

    private var notificationPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("In-app notifications") {
                Toggle("Task reminders", isOn: $store.notificationState.tasksEnabled)
                    .font(.system(size: 10))
                Toggle("Upcoming shoots & events", isOn: $store.notificationState.eventsEnabled)
                    .font(.system(size: 10))
                Toggle("App messages", isOn: $store.notificationState.messagesEnabled)
                    .font(.system(size: 10))
                Text("MODO keeps notification state inside the active workspace. These controls apply to the notification center in the app.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("Notification center") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Unread items").fontWeight(.medium)
                        Text("\(store.unreadNotificationCount) currently unread")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Mark all read") { store.markAllNotificationsRead() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(store.unreadNotificationCount == 0)
                }
            }
        }
        .onDisappear { store.refreshNotifications() }
    }

    private var languagePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Interface language") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Formatting locale")
                        Text("Controls date, number and regional formatting. Interface copy remains English until full localization ships.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { store.settings.effectiveLanguage },
                        set: { store.settings.language = $0 }
                    )) {
                        ForEach(FramoLanguage.allCases) { language in
                            Text("\(language.rawValue)  ·  \(language.shortCode)").tag(language)
                        }
                    }
                    .labelsHidden().frame(width: 220)
                }
            }

            settingsGroup("Region") {
                HStack {
                    Text("Currency")
                    Spacer()
                    TextField("EUR", text: $store.settings.currency)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 9).frame(width: 100, height: 30)
                        .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                HStack {
                    Text("Locale")
                    Spacer()
                    Text(store.settings.effectiveLanguage.localeIdentifier)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
                }
            }

            settingsGroup("Apply") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart MODO")
                        Text("Useful after changing bundled plug-ins or other runtime resources.").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Restart") { store.restartApplication() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Theme") {
                HStack {
                    Text("Mode")
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Button { store.settings.appearance = appearance } label: {
                                Text(appearance.rawValue)
                                    .font(.system(size: 9, weight: store.settings.appearance == appearance ? .semibold : .medium))
                                    .foregroundStyle(store.settings.appearance == appearance ? StudioTheme.primary : StudioTheme.secondary)
                                    .padding(.horizontal, 11)
                                    .frame(height: 29)
                                    .background(store.settings.appearance == appearance ? StudioTheme.selected : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                    }
                    .padding(2)
                    .background(StudioTheme.input.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Spacer().frame(height: 2)
                HStack {
                    Text("Palette")
                    Spacer()
                    Picker("", selection: Binding(get: { store.settings.effectivePalette }, set: { store.settings.palette = $0 })) {
                        ForEach(InterfacePalette.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                Toggle("Higher contrast", isOn: Binding(get: { store.settings.effectiveHighContrast }, set: { store.settings.highContrast = $0 }))
                HStack {
                    Text("Project symbols")
                    Spacer()
                    Text("Monochrome")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                }
            }

            settingsGroup("Interface") {
                HStack {
                    Text("Scale")
                    Spacer()
                    Slider(
                        value: $interfaceScaleDraft,
                        in: 0.85...1.20,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing {
                                store.settings.interfaceScale = interfaceScaleDraft
                            }
                        }
                    )
                    .frame(width: 220)
                    Text("\(Int(interfaceScaleDraft * 100))%")
                        .foregroundStyle(StudioTheme.secondary).frame(width: 42, alignment: .trailing)
                    Button("Reset") {
                        interfaceScaleDraft = 1.0
                        store.settings.interfaceScale = 1.0
                    }
                    .buttonStyle(.plain).studioPointerCursor()
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
                }
                HStack {
                    Text("Accent")
                    Spacer()
                    TextField("6B6B68", text: Binding(get: { store.settings.effectiveAccentHex }, set: { store.settings.accentHex = $0.replacingOccurrences(of: "#", with: "") }))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 9).frame(width: 110, height: 30)
                        .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var workflowPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Project pages") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], alignment: .leading, spacing: 7) {
                    ForEach(ProjectSection.allCases) { page in
                        Toggle(page.rawValue, isOn: sectionBinding(page)).disabled(page == .overview)
                    }
                }
            }

        }
    }

    private var integrationsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("Peppol e-invoicing") {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(StudioTheme.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Peppol — free-first").font(.system(size: 11, weight: .semibold))
                        Text(store.peppolConnector.state.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(store.peppolConnector.isConfigured ? StudioTheme.green : StudioTheme.secondary)
                    }
                    Spacer()
                    Button("Open Finance") { store.openDestination(.finance) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Text("Recipient lookup and Peppol BIS export are free and work without an account. Optional live sending uses Peppyrus; MODO adds no fees and always shows the provider limits before you connect.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("Google Drive + Docs") {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                            .frame(width: 28, height: 28)
                            .background(StudioTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Google Drive + Docs").font(.system(size: 11, weight: .semibold))
                            Text(store.googleConnector.state.label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(store.googleConnector.isConnected ? StudioTheme.green : StudioTheme.secondary)
                        }
                        Spacer()
                        if store.googleConnector.isConnected {
                            Button("Disconnect") { store.googleConnector.disconnect() }
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button("Connect Google") { store.googleConnector.connect() }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    Text("Creates project folders and Google Docs briefs, includes an in-app Drive browser, and watches linked documents for remote changes without copying credentials into the workspace database.")
                        .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }

                if store.googleConnector.isConnected {
                    HStack(spacing: 8) {
                        Button("Check Drive changes") { Task { await store.googleConnector.checkIncrementalChanges() } }
                            .buttonStyle(SecondaryButtonStyle())
                        if !store.googleConnector.remoteChangeProjectIDs.isEmpty {
                            Button("Pull \(store.googleConnector.remoteChangeProjectIDs.count) update\(store.googleConnector.remoteChangeProjectIDs.count == 1 ? "" : "s")") {
                                Task { await store.googleConnector.syncChangedBriefs() }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        Spacer()
                        if let checked = store.googleConnector.lastIncrementalCheck {
                            Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                        }
                    }
                }

                if store.googleConnector.effectiveClientID == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OAuth desktop client ID").font(.system(size: 9, weight: .medium))
                        HStack(spacing: 8) {
                            TextField("123456789-…apps.googleusercontent.com", text: Binding(
                                get: { store.settings.googleOAuthClientID ?? "" },
                                set: { store.settings.googleOAuthClientID = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(StudioTheme.input)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Button("Google Cloud Console") {
                                if let url = URL(string: "https://console.cloud.google.com/apis/credentials") { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Text("Create an OAuth client of type Desktop app and enable Google Drive API + Google Docs API. The client ID is public configuration; tokens are stored in macOS Keychain.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                }
            }

            settingsGroup("Cloud workspace") {
                HStack(spacing: 12) {
                    Image(systemName: "icloud")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(StudioTheme.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CloudKit entity sync").font(.system(size: 11, weight: .semibold))
                        Text(store.cloudSync.state.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.settings.effectiveCloudSyncEnabled },
                        set: { store.cloudSync.setEnabled($0) }
                    ))
                    .labelsHidden()
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.cloudSync.sharingStatus)
                            .font(.system(size: 9, weight: .semibold))
                        Text(store.settings.hasSharedCloudWorkspace
                             ? "This workspace syncs from another iCloud user's shared MODO workspace."
                             : "Sync across your Macs or invite another iCloud user into this workspace.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Toggle("Auto sync", isOn: Binding(
                        get: { store.settings.effectiveCloudAutoSyncEnabled },
                        set: { store.settings.cloudAutoSyncEnabled = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    Button("Sync now") { Task { await store.cloudSync.syncNow() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!store.settings.effectiveCloudSyncEnabled)
                }

                if store.settings.hasSharedCloudWorkspace {
                    HStack(spacing: 8) {
                        if let url = store.cloudSync.shareURL ?? store.settings.cloudShareURL.flatMap(URL.init(string:)) {
                            Text(url.absoluteString)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(StudioTheme.tertiary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Disconnect shared workspace") { Task { await store.cloudSync.leaveSharedWorkspace() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("Invite iCloud email", text: $cloudShareEmail)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(StudioTheme.input)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Picker("Access", selection: $cloudShareReadOnly) {
                            Text("Editor").tag(false)
                            Text("Viewer").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 92)

                        Button("Invite") {
                            let email = cloudShareEmail
                            Task {
                                do {
                                    let url = try await store.cloudSync.invite(email: email, readOnly: cloudShareReadOnly)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    cloudShareEmail = ""
                                    store.pluginNotice = "Invite created and share link copied"
                                } catch { store.pluginNotice = error.localizedDescription }
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(cloudShareEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Copy share link") { Task { await store.cloudSync.copyShareLink() } }
                            .buttonStyle(SecondaryButtonStyle())
                        if store.cloudSync.shareParticipantCount > 1 {
                            Button("Stop sharing") { Task { await store.cloudSync.stopSharingOwnedWorkspace() } }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                Text("Sharing is workspace-level in this build: invite someone as an Editor or Viewer. Project-specific roles, mentions and approval permissions are not implied. Local media stays local unless you explicitly link or transfer it.")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("MCP automation") {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(StudioTheme.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model Context Protocol")
                            .font(.system(size: 11, weight: .semibold))
                        Text(store.mcpServer.state.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { store.settings.effectiveMCPEnabled },
                        set: { enabled in
                            store.settings.mcpEnabled = enabled
                            if enabled { store.mcpServer.start() }
                            else { store.mcpServer.stop() }
                        }
                    ))
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    Text(store.mcpServer.endpointURL)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondary)
                        .textSelection(.enabled)

                    Spacer()

                    Text("Port")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)

                    TextField("7346", value: Binding(
                        get: { store.settings.effectiveMCPPort },
                        set: {
                            store.settings.mcpPort = $0
                            if store.settings.effectiveMCPEnabled { store.mcpServer.restart() }
                        }
                    ), format: .number)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(width: 70, height: 30)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button("Copy MCP config") { store.mcpServer.copyConfigToPasteboard() }
                        .buttonStyle(SecondaryButtonStyle())

                    Button("Rotate token") { store.mcpServer.rotateAccessToken() }
                        .buttonStyle(SecondaryButtonStyle())
                }

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write access")
                            .font(.system(size: 9, weight: .semibold))
                        Text(store.settings.effectiveMCPAllowWrites
                             ? "External MCP clients can use the exposed safe mutation tools for enabled modules."
                             : "Read-only. External clients can inspect enabled workspace data but cannot change it.")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }

                    Spacer()

                    Toggle("Allow writes", isOn: Binding(
                        get: { store.settings.effectiveMCPAllowWrites },
                        set: { enabled in
                            store.settings.mcpAllowWrites = enabled
                            if store.settings.effectiveMCPEnabled { store.mcpServer.restart() }
                        }
                    ))
                    .font(.system(size: 9))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(10)
                .background(StudioTheme.soft.opacity(0.36))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text("Loopback-only and bearer-token protected. MODO exposes only modules enabled for this workspace. Consequential finance actions such as issuing invoices or recording payments stay outside the MCP write surface.")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("Built in") {
                HStack(spacing: 12) {
                    Image(systemName: "calendar").frame(width: 22).foregroundStyle(StudioTheme.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Calendar").fontWeight(.medium)
                        Text("Integrated through EventKit. No MODO backend is required.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Open Calendar") {
                        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            settingsGroup("Frame.io") {
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .frame(width: 28, height: 28)
                        .background(StudioTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frame.io V4").font(.system(size: 11, weight: .semibold))
                        Text(store.frameIOConnector.state.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(store.frameIOConnector.isConnected ? StudioTheme.green : StudioTheme.secondary)
                    }
                    Spacer()
                    if store.frameIOConnector.isConnected {
                        Button("Refresh") { Task { await store.frameIOConnector.refreshCatalog() } }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Disconnect") { store.frameIOConnector.disconnect() }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Connect Frame.io") { store.frameIOConnector.connect() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                Text("Link MODO projects directly to Frame.io workspaces/projects for review and delivery. Tokens stay in Keychain; project IDs stay in the workspace for portable linking.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)

                if store.frameIOConnector.effectiveClientID == nil {
                    HStack(spacing: 8) {
                        TextField("Adobe OAuth Native App client ID", text: Binding(
                            get: { store.settings.frameIOOAuthClientID ?? "" },
                            set: { store.settings.frameIOOAuthClientID = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(StudioTheme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button("Adobe Developer Console") {
                            if let url = URL(string: "https://developer.adobe.com/console") { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                } else if store.frameIOConnector.isConnected {
                    Text("\(store.frameIOConnector.projects.count) Frame.io project\(store.frameIOConnector.projects.count == 1 ? "" : "s") available")
                        .font(.system(size: 8, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                }
            }

            DisclosureGroup(isExpanded: $showPlannedConnectors) {
                settingsGroup("Coming later") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 9)], spacing: 9) {
                        plannedConnector("Notion", detail: "Project hubs and business databases.", icon: "square.text.square")
                        plannedConnector("Dropbox", detail: "Project folders and delivery assets.", icon: "shippingbox")
                        plannedConnector("OneDrive", detail: "Microsoft 365 project files.", icon: "cloud")
                        plannedConnector("Slack", detail: "Review and delivery notifications.", icon: "message")
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Coming later")
                        .font(.system(size: 9, weight: .semibold))
                    Spacer()
                    Text("Hidden from normal workflow")
                        .font(.system(size: 8))
                        .foregroundStyle(StudioTheme.tertiary)
                }
            }
            .tint(StudioTheme.tertiary)
        }
    }

    private func plannedConnector(_ name: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(StudioTheme.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 10, weight: .semibold))
                Text(detail).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }
            Spacer()
            Text("COMING LATER").font(.system(size: 7.5, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
        }
        .padding(10)
        .background(StudioTheme.elevated.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var dataManagerPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("Workspace") {
                HStack(spacing: 24) {
                    dataMetric("Work", value: "\(store.projects.count)")
                    dataMetric("Places", value: "\(store.places.count)")
                    dataMetric("Database", value: ByteCountFormatter.string(fromByteCount: store.databaseByteSize, countStyle: .file))
                    Spacer()
                    Button("Reveal database") { store.revealDatabase() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Managed media") { store.revealManagedMedia() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Clean unused") {
                        store.cleanupOrphanedManagedMedia()
                        store.pluginNotice = "Unused managed media cleaned"
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Text("MODO stores workspace data here and keeps selected banners/reference images in Managed Media. Large production media stays linked in its original location.")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("Work") {
                if store.projects.isEmpty {
                    Text("No work yet.").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                } else {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        HStack(spacing: 10) {
                            Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                Text(project.client.isEmpty ? project.status.displayName(for: project.effectiveWorkType) : "\(project.client) · \(project.status.displayName(for: project.effectiveWorkType))")
                                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Button("Open") { store.openProject(project.id) }
                                .buttonStyle(.plain).font(.system(size: 9, weight: .medium)).studioPointerCursor()
                            Button(role: .destructive) {
                                deleteRequest = DeleteRequest(kind: "project", targetID: project.id, title: project.title)
                            } label: {
                                Image(systemName: "trash").frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain).studioPointerCursor().help("Remove project")
                        }
                        .frame(height: 42)
                        if index < store.projects.count - 1 { Spacer().frame(height: 2) }
                    }
                }
            }

            settingsGroup("Saved places") {
                if store.places.isEmpty {
                    Text("No saved places yet.").font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                } else {
                    ForEach(Array(store.places.enumerated()), id: \.element.id) { index, place in
                        HStack(spacing: 10) {
                            Image(systemName: "mappin")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 26, height: 26)
                                .background(StudioTheme.soft)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name.isEmpty ? "Untitled place" : place.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                Text(place.address.isEmpty ? "No address" : place.address)
                                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(place.photoPaths.count) photo\(place.photoPaths.count == 1 ? "" : "s")")
                                .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                            Button(role: .destructive) {
                                deleteRequest = DeleteRequest(kind: "place", targetID: place.id, title: place.name.isEmpty ? "place" : place.name)
                            } label: {
                                Image(systemName: "trash").frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain).studioPointerCursor().help("Remove saved place")
                        }
                        .frame(height: 42)
                        if index < store.places.count - 1 { Spacer().frame(height: 2) }
                    }
                }
            }

            settingsGroup("Reset") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset workspace & redo onboarding")
                            .font(.system(size: 10, weight: .medium))
                        Text("Clear this workspace's business data, settings, brand assets, connectors and managed media. Keep the workspace container, app lock/recovery access and external backups.")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Reset…", role: .destructive) { confirmFullReset = true }
                        .buttonStyle(SecondaryButtonStyle())
                }

                Spacer().frame(height: 2)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Factory reset MODO")
                            .font(.system(size: 10, weight: .medium))
                        Text("Remove all local MODO workspaces, app-scoped credentials, recovery setup and preferences from this Mac. Portable workspaces and external backups are not deleted.")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Factory reset…", role: .destructive) { confirmFactoryReset = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func dataMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 17, weight: .semibold))
            Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
        }
    }


    private var updatesPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup("Version") {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(StudioTheme.selected)
                            .frame(width: 44, height: 44)
                        Text("F")
                            .font(.system(size: 18, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MODO \(FramoStudioStore.appVersion)").font(.system(size: 13, weight: .semibold))
                        Text("Build \(FramoStudioStore.buildNumber)").font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                }
                Text("Updates are not managed inside MODO. This page only shows the installed version and release notes.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("Changelog") {
                ForEach(FramoReleaseCatalog.releases) { release in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("MODO \(release.version)").font(.system(size: 12, weight: .semibold))
                            Text("Build \(release.build)").font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioTheme.tertiary)
                            Spacer()
                            Text(release.date).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                        }
                        Text(release.title).font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                        ForEach(release.highlights, id: \.self) { item in
                            HStack(alignment: .top, spacing: 7) {
                                Text("•").foregroundStyle(StudioTheme.tertiary)
                                Text(item).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    if release.id != FramoReleaseCatalog.releases.last?.id { Spacer().frame(height: 2) }
                }
            }
        }
    }


    private var legalPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Privacy & Legal") {
                legalRow(.terms, symbol: "doc.text")
                Spacer().frame(height: 2)
                legalRow(.privacy, symbol: "hand.raised")
                Spacer().frame(height: 2)
                legalRow(.data, symbol: "externaldrive")
                Spacer().frame(height: 2)
                legalRow(.licenses, symbol: "curlybraces.square")
            }

            settingsGroup("Release transparency") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Installed software")
                        Text("Terms, privacy behavior and feature availability can change between releases, so the changelog stays tied to the installed version.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Open changelog") { category = .updates }.buttonStyle(SecondaryButtonStyle())
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(FramoStudioStore.appVersion).foregroundStyle(StudioTheme.secondary)
                }
                HStack {
                    Text("Build")
                    Spacer()
                    Text(FramoStudioStore.buildNumber).foregroundStyle(StudioTheme.secondary)
                }
            }
        }
    }

    private func legalRow(_ document: FramoLegalDocument, symbol: String) -> some View {
        Button { legalDocument = document } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 19).foregroundStyle(StudioTheme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title).foregroundStyle(StudioTheme.primary)
                    Text(document.intro).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).studioPointerCursor()
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Automatic backup") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(store.settings.autoBackupEnabled == true && store.settings.backupFolderBookmark != nil ? StudioTheme.green : StudioTheme.tertiary)
                                .frame(width: 8, height: 8)
                            Text(store.backupStatus).font(.system(size: 11, weight: .medium))
                        }
                        if let path = store.settings.backupFolderPath {
                            Text(path).font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.settings.autoBackupEnabled ?? false },
                        set: { enabled in
                            store.settings.autoBackupEnabled = enabled
                            if enabled { store.runBackupNow() }
                        }
                    ))
                    .labelsHidden()
                }

                Spacer().frame(height: 2)

                HStack {
                    Text("Every")
                    Picker("", selection: Binding(
                        get: { store.settings.effectiveAutoBackupIntervalMinutes },
                        set: { store.updateBackupSchedule(minutes: $0) }
                    )) {
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }
                    .labelsHidden().frame(width: 110)
                    Spacer()
                    Text("Keep")
                    Stepper(
                        "\(store.settings.effectiveAutoBackupKeepCount)",
                        value: Binding(
                            get: { store.settings.effectiveAutoBackupKeepCount },
                            set: { store.settings.autoBackupKeepCount = $0 }
                        ),
                        in: 3...60
                    )
                    .frame(width: 110)
                }

                HStack {
                    Button(store.settings.backupFolderPath == nil ? "Choose folder…" : "Change folder…") { chooseBackupFolder() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Back up now") { store.runBackupNow() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(store.settings.backupFolderBookmark == nil)
                    Spacer()
                    if let date = store.settings.lastBackupDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                }
            }

            settingsGroup("Local database") {
                Text(store.databaseURL.path)
                    .font(.system(size: 9, design: .monospaced)).textSelection(.enabled).foregroundStyle(StudioTheme.tertiary)
            }

            settingsGroup("Reset & recovery") {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Redo onboarding for this workspace").fontWeight(.medium)
                        Text("Keeps your workspace access and external backups, while clearing the workspace data and configuration.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Reset workspace…", role: .destructive) { confirmFullReset = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer().frame(height: 2)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Factory reset this Mac").fontWeight(.medium)
                        Text("Removes all local MODO workspaces, credentials and preferences. External portable workspaces and backups stay untouched.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Factory reset…", role: .destructive) { confirmFactoryReset = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("MODO") {
                HStack(spacing: 14) {
                    StudioLogoMark(size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MODO").font(.system(size: 17, weight: .semibold))
                        Text(store.versionLabel).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                        Text("Your business. Your way. Work, customers, planning, people, files and delivery in one local-first workspace.")
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Button("Version") { category = .updates }.buttonStyle(SecondaryButtonStyle())
                        Button("Restart MODO") { store.restartApplication() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }

            settingsGroup("Open source") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Built in the open").font(.system(size: 11, weight: .semibold))
                        Text("MODO is designed as an open-source business workspace. Its connector layer, data formats and application source are built to be auditable, extensible and portable.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                }
            }

            settingsGroup("Build") {
                HStack { Text("Version"); Spacer(); Text(FramoStudioStore.appVersion).foregroundStyle(StudioTheme.secondary) }
                HStack { Text("Build"); Spacer(); Text(FramoStudioStore.buildNumber).foregroundStyle(StudioTheme.secondary) }
                HStack { Text("Database"); Spacer(); Text(store.databaseURL.lastPathComponent).foregroundStyle(StudioTheme.secondary) }
            }

            settingsGroup("Documents") {
                HStack(spacing: 8) {
                    Button("Terms of Use") { legalDocument = .terms }.buttonStyle(SecondaryButtonStyle())
                    Button("Privacy Policy") { legalDocument = .privacy }.buttonStyle(SecondaryButtonStyle())
                    Button("Licenses") { legalDocument = .licenses }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioTheme.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 12) { content() }
                .font(.system(size: 11))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.soft.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .studioTextCursor()
                .padding(.horizontal, 10)
                .frame(width: 250, height: 32)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func settingsModuleDescription(_ destination: SidebarDestination) -> String {
        switch destination {
        case .customers: "Organizations and contacts"
        case .sales: "Opportunities and quotes"
        case .projects: "Jobs, production and delivery"
        case .tasks: "Workspace and work-linked tasks"
        case .calendar: "Plans, deadlines and events"
        case .resources: "People, devices and reusable kit"
        case .places: "Locations and references"
        case .finance: "Invoices and payments"
        default: destination.displayName
        }
    }

    private func sectionBinding(_ section: ProjectSection) -> Binding<Bool> {
        Binding(
            get: { store.settings.effectiveDefaultSections.contains(section) },
            set: { enabled in
                var sections = store.settings.effectiveDefaultSections
                if enabled && !sections.contains(section) { sections.append(section) }
                if !enabled && section != .overview { sections.removeAll { $0 == section } }
                store.settings.defaultProjectSections = sections
            }
        )
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { try? store.setBackupFolder(url) }
    }
}


private struct FramoLegalDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    let document: FramoLegalDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title).font(.system(size: 18, weight: .semibold))
                    Text(document.intro).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(document.sections.indices, id: \.self) { index in
                        let section = document.sections[index]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.0).font(.system(size: 12, weight: .semibold))
                            Text(section.1).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    Spacer().frame(height: 2)
                    Text("Applies to MODO \(FramoStudioStore.appVersion) · Build \(FramoStudioStore.buildNumber)")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioTheme.tertiary)
                }
                .padding(22)
            }
        }
        .frame(width: 640, height: 590)
        .background(StudioTheme.canvas)
    }
}

private struct PluginSettingsPane: View {
    @EnvironmentObject private var store: FramoStudioStore
    @ObservedObject private var manager: FramoV5PluginManager
    @ObservedObject private var syncthing: FramoV5SyncthingService
    @State private var filter: PluginFilter = .discover
    @State private var category: PluginCategory = .all
    @State private var pluginSearch = ""
    @State private var apiKey = ""
    @State private var showExternalPlugins = false

    private enum PluginFilter: String, CaseIterable, Identifiable {
        case discover = "Discover"
        case installed = "Installed"
        var id: String { rawValue }
    }

    private enum PluginCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case sync = "Sync & storage"
        case media = "Media"
        case editorial = "Editorial"
        case production = "Production"
        case communication = "Communication"
        case utilities = "Utilities"
        var id: String { rawValue }
    }

    init(manager: FramoV5PluginManager, syncthing: FramoV5SyncthingService) {
        _manager = ObservedObject(wrappedValue: manager)
        _syncthing = ObservedObject(wrappedValue: syncthing)
    }

    private var visiblePlugins: [FramoPluginManifest] {
        var source: [FramoPluginManifest]
        switch filter {
        case .discover: source = manager.catalog
        case .installed: source = manager.catalog.filter { store.isPluginInstalled($0.id) }
        }
        if filter == .discover && !showExternalPlugins {
            source = source.filter { plugin in
                maturity(plugin) == .releaseReady && manager.isRuntimeReady(plugin.id)
            }
        }
        let categorized = category == .all ? source : source.filter { pluginCategory($0) == category }
        let needle = pluginSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return categorized }
        return categorized.filter { [ $0.name, $0.summary, $0.author ].joined(separator: " ").lowercased().contains(needle) }
    }

    private func pluginCategory(_ plugin: FramoPluginManifest) -> PluginCategory {
        let id = plugin.id.lowercased()
        if ["syncthing", "rclone", "restic", "s3", "webdav", "sftp", "webtorrent", "rsync"].contains(where: id.contains) { return .sync }
        if ["ffmpeg", "mediainfo", "exiftool", "imagemagick"].contains(where: id.contains) { return .media }
        if ["otio", "frameio"].contains(where: id.contains) { return .editorial }
        if ["kitsu", "git", "taskkit", "calendar-kit"].contains(where: id.contains) { return .production }
        if ["discord", "slack"].contains(where: id.contains) { return .communication }
        if ["checksum", "archive", "native-export", "finder", "quicklook", "spotlight"].contains(where: id.contains) { return .utilities }
        return .production
    }


    private enum ExtensionMaturity {
        case releaseReady
        case experimental
        case planned

        var label: String {
            switch self {
            case .releaseReady: "Available"
            case .experimental: "Experimental"
            case .planned: "Coming later"
            }
        }
    }

    private func maturity(_ plugin: FramoPluginManifest) -> ExtensionMaturity {
        guard manager.canInstall(plugin.id) else { return .planned }

        let experimentalIDs = [
            "org.framo.syncthing",
            "org.framo.ffmpeg",
            "org.framo.mediainfo",
            "org.framo.exiftool",
            "org.framo.imagemagick",
            "org.framo.git",
            "org.framo.otio",
            "org.framo.rclone",
            "org.framo.restic",
            "org.framo.webtorrent"
        ]

        if experimentalIDs.contains(plugin.id) { return .experimental }
        return .releaseReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(PluginFilter.allCases) { item in
                            Button {
                                filter = item
                            } label: {
                                Text(item.rawValue)
                                    .font(.system(size: 10, weight: filter == item ? .semibold : .medium))
                                    .foregroundStyle(filter == item ? StudioTheme.primary : StudioTheme.secondary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(filter == item ? StudioTheme.selected : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .studioPointerCursor()
                        }
                    }
                    .padding(2)
                    .background(StudioTheme.soft.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Menu {
                        ForEach(PluginCategory.allCases) { item in
                            Button {
                                category = item
                            } label: {
                                if category == item { Label(item.rawValue, systemImage: "checkmark") }
                                else { Text(item.rawValue) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(category.rawValue)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(StudioTheme.soft.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Spacer(minLength: 12)

                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                        TextField("Search extensions", text: $pluginSearch)
                            .textFieldStyle(.plain)
                            .studioTextCursor()
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 220, height: 30)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button("Install local…") { store.installExternalPluginPackage() }
                        .buttonStyle(SecondaryButtonStyle())
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only release-ready extensions are shown by default.")
                            .font(.system(size: 9, weight: .medium))
                        Text("MODO never installs command-line tools or Homebrew behind your back.")
                            .font(.system(size: 8))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Toggle("Show experimental & planned", isOn: $showExternalPlugins)
                        .font(.system(size: 9))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 2)
            }

            ForEach(visiblePlugins) { plugin in
                pluginCard(plugin)
                if plugin.id == "org.framo.syncthing", store.isPluginInstalled(plugin.id) {
                    syncthingConfiguration
                }
            }

            if filter == .installed && visiblePlugins.isEmpty {
                StudioCard {
                    VStack(spacing: 5) {
                        Text("No plugins installed").font(.system(size: 12, weight: .semibold))
                        Text("Switch to Discover and enable only the tools your workflow actually needs.")
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                    }
                    .padding(24).frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            apiKey = FramoV5Keychain.readSyncthingAPIKey() ?? ""
            store.configureFramoV5SyncthingService()
            if store.isPluginEnabled("org.framo.syncthing") { Task { await syncthing.refresh() } }
        }
    }

    private func pluginCard(_ plugin: FramoPluginManifest) -> some View {
        let installed = store.isPluginInstalled(plugin.id)
        let enabled = store.isPluginEnabled(plugin.id)
        let canInstall = manager.canInstall(plugin.id)
        let ready = plugin.id == "org.framo.syncthing" ? syncthing.isReachable : manager.isRuntimeReady(plugin.id)
        let runtime = manager.runtimeStatus(for: plugin.id)

        return StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(plugin.name).font(.system(size: 13, weight: .semibold))
                            Circle()
                                .fill(installed && ready ? StudioTheme.green : StudioTheme.tertiary)
                                .frame(width: 7, height: 7)

                            Text(installed ? (ready ? "Ready" : "Needs setup") : maturity(plugin).label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(
                                    maturity(plugin) == .experimental
                                    ? Color(hex: "C59155")
                                    : StudioTheme.tertiary
                                )
                        }
                        Text(plugin.summary).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                    }
                    Spacer()
                    if installed {
                        if !ready && plugin.id != "org.framo.syncthing" {
                            Button("Locate tool…") {
                                store.pluginNotice = manager.chooseRuntime(for: plugin.id)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Toggle("", isOn: Binding(get: { enabled && ready }, set: { store.setPluginEnabled(plugin.id, enabled: $0 && ready) }))
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(!ready)
                        Button("Remove") { store.uninstallPlugin(plugin.id) }.buttonStyle(SecondaryButtonStyle())
                    } else if canInstall && ready {
                        Button("Add") { store.installPlugin(plugin.id) }.buttonStyle(PrimaryButtonStyle())
                    } else if canInstall {
                        Text(maturity(plugin) == .experimental ? "Experimental · setup required" : "Extra software required")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                    } else {
                        Text("Coming later")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                }

                HStack(spacing: 5) {
                    Text(plugin.license).font(.system(size: 8, weight: .medium)).foregroundStyle(StudioTheme.tertiary)
                    if installed && !plugin.actions.isEmpty {
                        Text("·").foregroundStyle(StudioTheme.tertiary)
                        Text(ready ? "Ready for MODO menus" : "Finish setup to use in MODO")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    if let source = plugin.sourceURL, let url = URL(string: source) {
                        Button("Source") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain).studioPointerCursor()
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
                    }
                }
            }
            .padding(14)
        }
    }

    private var syncthingConfiguration: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SYNCTHING").framoSettingsMicroLabelV13()
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Syncthing connection").font(.system(size: 11, weight: .semibold))
                            Text(syncthing.status).font(.system(size: 9)).foregroundStyle(syncthing.isReachable ? StudioTheme.green : StudioTheme.secondary)
                        }
                        Spacer()
                        Button("Refresh") { store.configureFramoV5SyncthingService(); Task { await syncthing.refresh() } }.buttonStyle(SecondaryButtonStyle())
                        if syncthing.isReachable { Button("Dashboard") { syncthing.openDashboard() }.buttonStyle(SecondaryButtonStyle()) }
                    }

                    Divider()
                    HStack {
                        Text("Mode")
                        Spacer()
                        Picker("", selection: Binding(get: { store.settings.effectiveSyncthingMode }, set: { store.settings.syncthingMode = $0 })) {
                            ForEach(SyncthingMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 185)
                    }

                    HStack {
                        Text("Local API")
                        Spacer()
                        TextField("http://127.0.0.1:8384", text: Binding(get: { store.settings.effectiveSyncthingBaseURL }, set: { store.setSyncthingBaseURL($0) }))
                            .textFieldStyle(.roundedBorder).frame(width: 260).studioTextCursor()
                    }
                    HStack {
                        Text("API key")
                        Spacer()
                        SecureField("Syncthing API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder).frame(width: 260).studioTextCursor()
                            .onSubmit { store.setSyncthingAPIKey(apiKey); Task { await syncthing.refresh() } }
                        Button("Save") { store.setSyncthingAPIKey(apiKey); Task { await syncthing.refresh() } }.buttonStyle(SecondaryButtonStyle())
                    }
                    Text("The API key is stored in macOS Keychain, not inside the MODO workspace file.")
                        .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)

                    if store.settings.effectiveSyncthingMode == .managed {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Managed executable")
                                Text(store.settings.syncthingExecutablePath ?? store.detectedSyncthingExecutable()?.path ?? "Not found")
                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                            }
                            Spacer()
                            if store.detectedSyncthingExecutable() == nil && store.settings.syncthingExecutablePath == nil {
                                Button("Install Syncthing") {
                                    store.pluginNotice = "Installing Syncthing…"
                                    manager.installRuntime(for: "org.framo.syncthing") { message in store.pluginNotice = message }
                                }.buttonStyle(PrimaryButtonStyle())
                            }
                            Button("Choose…") { store.chooseSyncthingExecutable() }.buttonStyle(SecondaryButtonStyle())
                            if syncthing.managedRunning {
                                Button("Stop") { store.stopManagedSyncthing() }.buttonStyle(SecondaryButtonStyle())
                            } else {
                                Button("Start") { store.startManagedSyncthing() }.buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        Toggle("Start managed Syncthing with MODO", isOn: Binding(get: { store.settings.effectiveSyncthingAutoStart }, set: { store.settings.syncthingAutoStart = $0 }))
                    }

                    if !syncthing.devices.isEmpty {
                        Divider()
                        Text("DEVICES").framoSettingsMicroLabelV13()
                        ForEach(syncthing.devices) { device in
                            HStack {
                                Circle().fill(device.connected ? StudioTheme.green : StudioTheme.tertiary).frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name).font(.system(size: 10, weight: .medium))
                                    Text(String(device.deviceID.prefix(20)) + "…").font(.system(size: 8, design: .monospaced)).foregroundStyle(StudioTheme.tertiary)
                                }
                                Spacer()
                                Text(device.connected ? "Online" : (device.paused ? "Paused" : "Offline")).font(.system(size: 8)).foregroundStyle(StudioTheme.secondary)
                            }
                        }
                    }
                }
                .font(.system(size: 10)).padding(14)
            }
        }
    }
}

private struct TransferSettingsPane: View {
    @EnvironmentObject private var store: FramoStudioStore
    @ObservedObject private var transfer: FramoV5LocalTransferService
    @ObservedObject private var host: FramoV5HostService
    @ObservedObject private var remote: FramoV5RemoteAccessService
    @ObservedObject private var tor: FramoTorConnectService
    @State private var operationError: String?
    @State private var connectInviteDraft = ""
    @State private var showDeveloperDetails = false
    @State private var confirmRemotePull = false

    init(service: FramoV5LocalTransferService, host: FramoV5HostService, remote: FramoV5RemoteAccessService, tor: FramoTorConnectService) {
        _transfer = ObservedObject(wrappedValue: service)
        _host = ObservedObject(wrappedValue: host)
        _remote = ObservedObject(wrappedValue: remote)
        _tor = ObservedObject(wrappedValue: tor)
    }

    private var experimentalRemoteEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "MODOEnableExperimentalRemoteConnect") as? Bool) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MODO Connect")
                    .font(.system(size: 17, weight: .semibold))
                Text("Connect two Macs nearby. Remote Connect stays hidden in release builds until its bundled secure transport is ready.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.secondary)
            }

            nearbyCard

            if experimentalRemoteEnabled {
                remoteCard
            } else {
                StudioCard {
                    HStack(spacing: 12) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Remote Connect")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Experimental and hidden in this release build. Nearby Connect remains available without weakening the macOS sandbox.")
                                .font(.system(size: 8.5))
                                .foregroundStyle(StudioTheme.tertiary)
                        }
                        Spacer()
                        Text("COMING LATER")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    .padding(14)
                }
            }

            if experimentalRemoteEnabled {
                DisclosureGroup(isExpanded: $showDeveloperDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    developerStatusRow("Host", value: host.status)
                    developerStatusRow("Remote client", value: remote.status)
                    developerStatusRow("Tor", value: tor.status)
                    HStack(spacing: 8) {
                        Button("Choose Tor executable…") { store.chooseTorExecutable() }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Stop Remote") { store.setFramoConnectRemoteEnabled(false) }
                            .buttonStyle(SecondaryButtonStyle())
                        Spacer()
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Developer details")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.tertiary)
            }
                .tint(StudioTheme.tertiary)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .alert("Workspace", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .alert("Pull the remote workspace?", isPresented: $confirmRemotePull) {
            Button("Cancel", role: .cancel) { }
            Button("Pull workspace") { store.pullRemoteWorkspace() }
        } message: {
            Text("Work, tasks, calendar items, spaces and places on this Mac will be replaced by the connected Mac's current snapshot. Your MODO settings stay on this Mac.")
        }
    }

    private var nearbyCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    connectIcon("wifi")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nearby")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Both Macs are on the same Wi-Fi or local network.")
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.settings.effectiveLocalTransferEnabled },
                        set: { store.setLocalTransferEnabled($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }

                if !store.settings.effectiveLocalTransferEnabled {
                    Text("Turn Nearby on, then open MODO on the other Mac. It should appear automatically.")
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                } else if transfer.peers.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Looking for another Mac running MODO…")
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                    }
                } else {
                    ForEach(transfer.peers, id: \.self) { peer in
                        nearbyPeerRow(peer)
                    }
                }

                if let received = transfer.lastReceivedURL {
                    Divider()
                    receivedFile(received)
                }
            }
            .padding(14)
        }
    }

    private var remoteCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 11) {
                    connectIcon("network")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Connect Macs on different networks through Tor. No MODO cloud account required.")
                            .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    if store.settings.effectiveFramoConnectRemoteEnabled {
                        Button("Turn off") { store.setFramoConnectRemoteEnabled(false) }
                            .buttonStyle(.plain).font(.system(size: 9, weight: .medium)).studioPointerCursor()
                    }
                }

                Divider()
                remoteSetupContent
            }
            .padding(14)
        }
    }

    @ViewBuilder private var remoteSetupContent: some View {
        if !store.settings.effectiveFramoConnectRemoteEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remote has one job: create a secure address for this Mac and let another MODO Mac connect to it.")
                    .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                Button("Set up Remote") { store.setFramoConnectRemoteEnabled(true) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else if store.detectedTorExecutable() == nil {
            setupStep(
                number: "1",
                title: "Install Tor once",
                body: "MODO needs the free Tor command-line app to create the private remote connection. Install it in Terminal, then come back here.") {
                    HStack(spacing: 8) {
                        Button("Copy: brew install tor") { store.copyTorInstallCommand() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("I already have Tor…") { store.chooseTorExecutable() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
        } else if store.framoConnectTorNeedsSandboxFix {
            setupStep(
                number: "1",
                title: "Allow this Xcode build to run Tor",
                body: "Tor is installed, but this development build is inside the macOS App Sandbox. That is why Start returns ‘Permission denied’. For local testing, disable App Sandbox for the MODO target. For a release build, Tor should be bundled inside MODO instead.") {
                    HStack(spacing: 8) {
                        Button("Copy Xcode steps") { store.copyTorDevelopmentFix() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Choose another Tor…") { store.chooseTorExecutable() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
        } else if !tor.isRunning {
            setupStep(
                number: "2",
                title: "Start Remote",
                body: "Tor is ready. Start Remote and MODO will create this Mac's private Connect address.") {
                    Button("Start Remote") { store.startFramoConnectRemote() }
                        .buttonStyle(PrimaryButtonStyle())
                }
        } else if tor.onionAddress == nil {
            setupStep(
                number: "2",
                title: "Starting Remote…",
                body: tor.status) {
                    ProgressView(value: max(0, min(1, tor.bootstrapProgress)))
                        .controlSize(.small)
                        .frame(maxWidth: 280)
                }
        } else {
            remoteReadyContent
        }
    }

    private var remoteReadyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(StudioTheme.green).frame(width: 7, height: 7)
                Text("Remote is ready")
                    .font(.system(size: 10, weight: .semibold))
                Text("This Mac can now make or accept a MODO Connect connection.")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }

            HStack(alignment: .top, spacing: 10) {
                simpleConnectBox(
                    title: "Share this Mac",
                    body: "Copy one invite and send it privately to the other Mac."
                ) {
                    Button("Copy invite") { store.copyFramoConnectInvite() }
                        .buttonStyle(PrimaryButtonStyle())
                }

                simpleConnectBox(
                    title: "Connect to a Mac",
                    body: "Paste the invite you received from the other Mac."
                ) {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("Paste invite", text: $connectInviteDraft)
                            .textFieldStyle(.roundedBorder)
                            .studioTextCursor()
                            .onSubmit { connectInvite() }
                        HStack(spacing: 7) {
                            Button("Paste") {
                                if let value = NSPasteboard.general.string(forType: .string) { connectInviteDraft = value }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Button("Connect") { connectInvite() }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(connectInviteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            if let manifest = remote.manifest {
                Divider()
                HStack(spacing: 10) {
                    connectIcon("laptopcomputer")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manifest.workspaceName).font(.system(size: 10, weight: .semibold))
                        Text("Connected remotely").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Pull workspace…") { confirmRemotePull = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else if !remote.status.isEmpty && remote.status != "Idle" {
                Text(remote.status)
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }
        }
    }

    private func setupStep<Actions: View>(number: String, title: String, body: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 26)
                .background(StudioTheme.selected)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Text(body).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
    }

    private func simpleConnectBox<Actions: View>(title: String, body: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .semibold))
            Text(body).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StudioTheme.soft.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func connectIcon(_ symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(StudioTheme.soft)
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(StudioTheme.secondary)
        }
        .frame(width: 36, height: 36)
    }

    private func nearbyPeerRow(_ peer: MCPeerID) -> some View {
        let connected = transfer.connectedPeers.contains(peer)
        return HStack(spacing: 9) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 11))
                .frame(width: 30, height: 30)
                .background(StudioTheme.soft)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName.replacingOccurrences(of: "MODO · ", with: ""))
                    .font(.system(size: 10, weight: .medium))
                Text(connected ? "Connected" : "Found nearby")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }
            Spacer()
            if connected {
                Menu("Send") {
                    Button("Workspace") { store.sendWorkspace(to: peer) }
                    Button("File…") { transfer.chooseAndSendFile(to: peer) }
                }
                .menuStyle(.borderlessButton).frame(width: 70)
            } else {
                Button("Connect") { transfer.connect(to: peer) }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func receivedFile(_ url: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 9, weight: .medium))
                Text("Received from another Mac").font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }
            Spacer()
            if url.pathExtension.lowercased() == "framo" {
                Button("Import") { try? store.importFramo(from: url) }.buttonStyle(PrimaryButtonStyle())
            }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func developerStatusRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 9, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
        }
    }

    private func connectInvite() {
        let value = connectInviteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.connectFramoInvite(value)
    }
}

extension Text {
    func framoSettingsMicroLabelV13() -> some View {
        self.font(.system(size: 9, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
    }
}

// MARK: - V0.20 connected production pages

struct FramoResourcesViewV20: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var tab = "Crew"
    @State private var filter = ""
    @State private var addKind: FramoResourceAddKind?
    @State private var assignmentPerson: PersonRecord?
    @State private var showingContactsImport = false

    private struct PersonRecord: Identifiable {
        let key: String
        var member: CrewMember
        var projectIDs: [UUID]
        var id: String { key }
    }

    private struct GearRecord: Identifiable {
        let projectID: UUID
        let projectTitle: String
        let item: KitItem
        var id: String { "\(projectID.uuidString)-\(item.id.uuidString)" }
    }

    private var people: [PersonRecord] {
        var grouped: [String: PersonRecord] = [:]
        for project in store.projects {
            for member in project.crew {
                let email = member.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let name = member.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let key = email.isEmpty ? "name:\(name)" : "email:\(email)"
                if var existing = grouped[key] {
                    if !existing.projectIDs.contains(project.id) { existing.projectIDs.append(project.id) }
                    if existing.member.photoPath == nil, member.photoPath != nil { existing.member.photoPath = member.photoPath }
                    grouped[key] = existing
                } else {
                    grouped[key] = PersonRecord(key: key, member: member, projectIDs: [project.id])
                }
            }
        }
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return grouped.values
            .filter { q.isEmpty || [$0.member.name, $0.member.role, $0.member.email].joined(separator: " ").lowercased().contains(q) }
            .sorted { $0.member.name.localizedCaseInsensitiveCompare($1.member.name) == .orderedAscending }
    }

    private var gear: [GearRecord] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.projects.flatMap { project in
            project.kit.map { GearRecord(projectID: project.id, projectTitle: project.title, item: $0) }
        }
        .filter { q.isEmpty || [$0.item.name, $0.item.category, $0.projectTitle].joined(separator: " ").lowercased().contains(q) }
        .sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crew & devices").font(.system(size: 24, weight: .semibold))
                    Text("People and gear, with their project assignments visible at a glance.")
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                TextField("Search", text: $filter)
                    .textFieldStyle(.plain).studioTextCursor()
                    .padding(.horizontal, 10).frame(width: 210, height: 30)
                    .background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 7))
                Menu {
                    Button("Crew member", systemImage: "person.badge.plus") { addKind = .crew }
                    Button("Import from Apple Contacts…", systemImage: "person.crop.circle.badge.plus") { showingContactsImport = true }
                    Divider()
                    Button("Device", systemImage: "camera") { addKind = .device }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)

            HStack {
                FramoFlatTabsV20(items: ["Crew", "Devices"], selection: $tab)
                Spacer()
                Text(tab == "Crew" ? "\(people.count) people" : "\(gear.count) items")
                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 24).padding(.bottom, 10)

            ScrollView {
                if tab == "Crew" { peopleList }
                else { gearList }
            }
        }
        .sheet(item: $addKind) { kind in
            FramoQuickResourceAddSheet(kind: kind).environmentObject(store)
        }
        .sheet(item: $assignmentPerson) { person in
            crewAssignmentSheet(person)
        }
        .sheet(isPresented: $showingContactsImport) {
            FramoContactsImportSheet().environmentObject(store)
        }
    }

    private var peopleList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 12)], spacing: 12) {
            if people.isEmpty {
                emptyState("No crew yet", "Add a person and choose the first project they work on.")
            }

            ForEach(people) { record in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Button { choosePersonPhoto(record) } label: {
                            FramoLocalPhotoV20(path: record.member.photoPath, fallback: record.member.initials, width: 52, height: 52, fit: false)
                        }
                        .buttonStyle(.plain).studioPointerCursor().help("Change photo")

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.member.name.isEmpty ? "Unnamed person" : record.member.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(record.member.role.isEmpty ? "Crew" : record.member.role)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(StudioTheme.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    projectAssignmentSummary(record)

                    HStack(spacing: 8) {
                        if !record.member.email.isEmpty {
                            Button { store.openMail(to: record.member.email, subject: "MODO") } label: {
                                Label("Email", systemImage: "envelope")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Spacer()
                        Button("Work") { assignmentPerson = record }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .background(StudioTheme.soft.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { assignmentPerson = record }
                .contextMenu {
                    Button("Manage projects…") { assignmentPerson = record }
                    Button("Change photo…") { choosePersonPhoto(record) }
                    Divider()
                    Button("Remove from all projects", role: .destructive) { store.removeCrewMemberEverywhere(record.member) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 1180, alignment: .leading)
    }

    private func projectAssignmentSummary(_ record: PersonRecord) -> some View {
        HStack(spacing: 5) {
            let assigned = store.projects.filter { record.projectIDs.contains($0.id) }
            ForEach(assigned.prefix(2)) { project in
                Text(project.title)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(StudioTheme.soft)
                    .clipShape(Capsule())
            }
            if assigned.count > 2 {
                Text("+\(assigned.count - 2)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiary)
            }
        }
    }

    private var gearList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)], spacing: 12) {
            if gear.isEmpty {
                emptyState("No devices yet", "Add cameras, lenses, audio or other production gear.")
            }

            ForEach(gear) { record in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Button { chooseGearPhoto(record) } label: {
                            FramoLocalPhotoV20(path: record.item.photoPath, fallback: "", width: 72, height: 62, fit: false)
                                .overlay {
                                    if record.item.photoPath == nil {
                                        Image(systemName: "camera")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(StudioTheme.secondary)
                                    }
                                }
                        }
                        .buttonStyle(.plain).studioPointerCursor().help("Change device photo")

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.item.name.isEmpty ? "Unnamed device" : record.item.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(2)
                            Text("\(record.item.category) · ×\(record.item.quantity)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(StudioTheme.secondary)
                            Text(record.projectTitle)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(StudioTheme.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Menu {
                            Button("Available") { setLoan(record, crewID: nil) }
                            Divider()
                            ForEach(allCrewForProject(record.projectID)) { member in
                                Button(member.name.isEmpty ? "Unnamed crew" : member.name) { setLoan(record, crewID: member.id) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(loanLabel(record)).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                            }
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(StudioTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        Spacer()
                        Button("Open") { store.openProjectSection(record.projectID, section: .kit) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .background(StudioTheme.soft.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contextMenu {
                    Button("Change photo…") { chooseGearPhoto(record) }
                    Button("Open work") { store.openProjectSection(record.projectID, section: .kit) }
                    Divider()
                    Button("Remove device", role: .destructive) { store.removeKitItem(projectID: record.projectID, itemID: record.item.id) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 1180, alignment: .leading)
    }

    private func crewAssignmentSheet(_ record: PersonRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                FramoLocalPhotoV20(path: record.member.photoPath, fallback: record.member.initials, width: 44, height: 44, fit: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.member.name).font(.system(size: 16, weight: .semibold))
                    Text("Choose the projects this person works on.")
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button { assignmentPerson = nil } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.projects) { project in
                        let assigned = store.isCrewMember(record.member, assignedTo: project.id)
                        Button {
                            if assigned { store.removeCrewMember(record.member, fromProject: project.id) }
                            else { store.assignCrewMember(record.member, toProject: project.id) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: assigned ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    Text(project.client).font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .frame(height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    }
                }
            }

            HStack {
                Button("Remove from all", role: .destructive) {
                    store.removeCrewMemberEverywhere(record.member)
                    assignmentPerson = nil
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Done") { assignmentPerson = nil }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20).frame(width: 460, height: 520)
        .background(StudioTheme.canvas)
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(subtitle).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func allCrewForProject(_ projectID: UUID) -> [CrewMember] {
        store.projects.first(where: { $0.id == projectID })?.crew ?? []
    }

    private func loanLabel(_ record: GearRecord) -> String {
        guard let id = record.item.lentToCrewID,
              let member = allCrewForProject(record.projectID).first(where: { $0.id == id }) else { return "Available" }
        return "With \(member.name)"
    }

    private func setLoan(_ record: GearRecord, crewID: UUID?) {
        var item = record.item
        item.lentToCrewID = crewID
        item.dueBack = crewID == nil ? nil : item.dueBack
        store.updateKitItem(projectID: record.projectID, item: item)
    }

    private func choosePersonPhoto(_ record: PersonRecord) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let projectID = record.projectIDs.first else { return }
        guard let member = store.projects.first(where: { $0.id == projectID })?.crew.first(where: {
            let emailA = $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let emailB = record.member.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return (!emailA.isEmpty && emailA == emailB) || (emailA.isEmpty && emailB.isEmpty && $0.name.caseInsensitiveCompare(record.member.name) == .orderedSame)
        }) else { return }
        store.setCrewPhoto(projectID: projectID, memberID: member.id, sourceURL: url)
    }

    private func chooseGearPhoto(_ record: GearRecord) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setDevicePhoto(projectID: record.projectID, itemID: record.item.id, sourceURL: url)
    }
}


private enum FramoResourceAddKind: String, Identifiable {
    case crew = "Crew member"
    case device = "Device"
    var id: String { rawValue }
}

private struct FramoQuickResourceAddSheet: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss
    let kind: FramoResourceAddKind
    @State private var projectID: UUID?
    @State private var name = ""
    @State private var secondary = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var serial = ""
    @State private var quantity = 1
    @State private var photoURL: URL?

    private var selectedProjectTitle: String {
        guard let projectID, let project = store.projects.first(where: { $0.id == projectID }) else { return "Choose project" }
        return project.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add \(kind.rawValue.lowercased())")
                        .font(.system(size: 22, weight: .semibold))
                    Text(kind == .crew ? "Add someone to a production crew." : "Add a device to a production kit.")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }

            HStack(alignment: .center, spacing: 14) {
                Button { choosePhoto() } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(StudioTheme.soft.opacity(0.78))
                        if let photoURL, let image = NSImage(contentsOf: photoURL) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: kind == .crew ? "person.crop.circle" : "camera")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(StudioTheme.secondary)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(StudioTheme.border.opacity(0.48), lineWidth: 0.7)
                    }
                }
                .buttonStyle(.plain)
                .studioPointerCursor()

                VStack(alignment: .leading, spacing: 7) {
                    Button(photoURL == nil ? "Add photo" : "Change photo") { choosePhoto() }
                        .buttonStyle(SecondaryButtonStyle())
                    if photoURL != nil {
                        Button("Remove photo") { photoURL = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioTheme.secondary)
                            .studioPointerCursor()
                    }
                }
                Spacer()
            }

            StudioDialogField("Project") {
                Menu {
                    ForEach(store.projects) { project in
                        Button(project.title) { projectID = project.id }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedProjectTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(projectID == nil ? StudioTheme.tertiary : StudioTheme.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
            }

            StudioDialogField("Name") {
                TextField(kind == .crew ? "Name" : "Device name", text: $name)
                    .textFieldStyle(.plain)
                    .studioTextCursor()
            }

            StudioDialogField(kind == .crew ? "Role" : "Category") {
                TextField(kind == .crew ? "Director, producer, sound…" : "Camera, lens, audio…", text: $secondary)
                    .textFieldStyle(.plain)
                    .studioTextCursor()
            }

            if kind == .crew {
                HStack(spacing: 10) {
                    StudioDialogField("Email") {
                        TextField("name@example.com", text: $email).textFieldStyle(.plain).studioTextCursor()
                    }
                    StudioDialogField("Phone") {
                        TextField("Optional", text: $phone).textFieldStyle(.plain).studioTextCursor()
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    StudioDialogField("Serial number") {
                        TextField("Optional", text: $serial).textFieldStyle(.plain).studioTextCursor()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("QUANTITY").font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.tertiary)
                        Stepper("×\(quantity)", value: $quantity, in: 1...99)
                            .frame(width: 110, height: 38)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Add") { save() }.buttonStyle(PrimaryButtonStyle())
                    .disabled(projectID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 540)
        .background(StudioTheme.canvas)
        .onAppear { projectID = store.selectedProjectID ?? store.projects.first?.id }
    }

    private func save() {
        guard let projectID else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecondary = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .crew {
            if let id = store.addCrewMember(to: projectID, name: cleanName, role: cleanSecondary.isEmpty ? "Crew" : cleanSecondary, email: email, phone: phone),
               let photoURL {
                store.setCrewPhoto(projectID: projectID, memberID: id, sourceURL: photoURL)
            }
        } else {
            if let id = store.addDevice(to: projectID, name: cleanName, category: cleanSecondary.isEmpty ? "Device" : cleanSecondary, quantity: quantity, serialNumber: serial),
               let photoURL {
                store.setDevicePhoto(projectID: projectID, itemID: id, sourceURL: photoURL)
            }
        }
        dismiss()
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        photoURL = panel.url
    }
}

private struct FramoContactsImportSheet: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [ContactCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var projectID: UUID?
    @State private var query = ""
    @State private var loading = true
    @State private var status = "Requesting access to Apple Contacts…"

    private struct ContactCandidate: Identifiable, Hashable {
        let id: String
        let name: String
        let email: String
        let phone: String
    }

    private var filtered: [ContactCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return contacts }
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(needle) ||
            $0.email.localizedCaseInsensitiveContains(needle) ||
            $0.phone.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import contacts")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Choose people from Apple Contacts and add them to a project crew.")
                        .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }

            HStack(spacing: 10) {
                Picker("Project", selection: $projectID) {
                    Text("Choose project").tag(Optional<UUID>.none)
                    ForEach(store.projects) { project in
                        Text(project.title).tag(Optional(project.id))
                    }
                }
                .labelsHidden()
                .frame(width: 240)

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
                    TextField("Search contacts", text: $query)
                        .textFieldStyle(.plain)
                        .studioTextCursor()
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Group {
                if loading {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if contacts.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 20)).foregroundStyle(StudioTheme.tertiary)
                        Text(status).font(.system(size: 10, weight: .medium))
                        Text("You can change Contacts access in macOS System Settings → Privacy & Security → Contacts.")
                            .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filtered) { contact in
                                Button {
                                    if selectedIDs.contains(contact.id) { selectedIDs.remove(contact.id) }
                                    else { selectedIDs.insert(contact.id) }
                                } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: selectedIDs.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(selectedIDs.contains(contact.id) ? StudioTheme.primary : StudioTheme.tertiary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(contact.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                            Text([contact.email, contact.phone].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 44)
                                    .background(selectedIDs.contains(contact.id) ? StudioTheme.selected : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .studioPointerCursor()
                            }
                        }
                    }
                }
            }
            .frame(height: 340)

            HStack {
                Text(selectedIDs.isEmpty ? "No contacts selected" : "\(selectedIDs.count) selected")
                    .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Import") { importSelected() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(projectID == nil || selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 590, height: 510)
        .background(StudioTheme.canvas)
        .onAppear {
            projectID = store.selectedProjectID ?? store.projects.first?.id
            Task { await loadContacts() }
        }
    }

    @MainActor
    private func loadContacts() async {
        loading = true
        let contactStore = CNContactStore()
        do {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                contactStore.requestAccess(for: .contacts) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else {
                loading = false
                status = "Contacts access was not granted."
                return
            }

            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var found: [ContactCandidate] = []
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let personalName = [contact.givenName, contact.familyName]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: " ")
                let name = personalName.isEmpty ? contact.organizationName : personalName
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                found.append(ContactCandidate(
                    id: contact.identifier,
                    name: name,
                    email: contact.emailAddresses.first?.value as String? ?? "",
                    phone: contact.phoneNumbers.first?.value.stringValue ?? ""
                ))
            }
            contacts = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            status = contacts.isEmpty ? "No contacts were found." : ""
        } catch {
            status = "MODO couldn't read Apple Contacts."
        }
        loading = false
    }

    private func importSelected() {
        guard let projectID else { return }
        let existing = store.projects.first(where: { $0.id == projectID })?.crew ?? []
        for contact in contacts where selectedIDs.contains(contact.id) {
            let duplicate = existing.contains { member in
                let memberEmail = member.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let contactEmail = contact.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !memberEmail.isEmpty, !contactEmail.isEmpty { return memberEmail == contactEmail }
                return member.name.caseInsensitiveCompare(contact.name) == .orderedSame
            }
            if !duplicate {
                _ = store.addCrewMember(to: projectID, name: contact.name, role: "Crew", email: contact.email, phone: contact.phone)
            }
        }
        dismiss()
    }
}

private enum FramoMapStyleV21: String, CaseIterable, Identifiable {
    case muted = "Clean"
    case standard = "Standard"
    case hybrid = "Satellite"

    var id: String { rawValue }
    var mapType: MKMapType {
        switch self {
        case .muted: .mutedStandard
        case .standard: .standard
        case .hybrid: .hybrid
        }
    }
    var icon: String {
        switch self {
        case .muted: "map"
        case .standard: "map.fill"
        case .hybrid: "globe.europe.africa.fill"
        }
    }
}

private struct FramoPlaceSearchResult: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var category: String = ""
}

struct FramoPlacesViewV20: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var selectedPlaceID: UUID?
    @State private var showsSavedPanel = false
    @State private var placeSearch = ""
    @State private var searchResults: [FramoPlaceSearchResult] = []
    @State private var hasSearched = false
    @State private var rightCollapsed = true
    @State private var mapStyle: FramoMapStyleV21 = .muted
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50.8503, longitude: 4.3517),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
    )
    @State private var locating = false
    @State private var mapSearching = false
    @FocusState private var searchFocused: Bool

    private var selectedPlace: StudioPlace? {
        guard let selectedPlaceID else { return nil }
        return store.places.first(where: { $0.id == selectedPlaceID })
    }

    private var selectedBinding: Binding<StudioPlace>? {
        guard let id = selectedPlaceID, let index = store.places.firstIndex(where: { $0.id == id }) else { return nil }
        return $store.places[index]
    }

    private var filteredPlaces: [StudioPlace] {
        let query = placeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.places }
        return store.places.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.address.localizedCaseInsensitiveContains(query) ||
            $0.notes.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchQuery: String { placeSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            FramoSeamlessPlacesMap(
                places: store.places,
                region: $region,
                selectedID: $selectedPlaceID,
                mapType: mapStyle.mapType,
                onSelect: {
                    rightCollapsed = false
                    showsSavedPanel = false
                    searchResults = []
                    searchFocused = false
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .overlay(alignment: .topLeading) {
            if hasSearched && !searchQuery.isEmpty {
                searchResultsPanel
                    .padding(.top, 66)
                    .padding(.leading, 16)
            } else if showsSavedPanel {
                savedPlacesPanel
                    .padding(.top, 66)
                    .padding(.leading, 16)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !rightCollapsed, selectedPlace != nil {
                inspector
                    .frame(width: 324)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .framoLiquidGlass(radius: 18)
                    .padding(16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            mapZoomControls
                .padding(.bottom, 16)
                .padding(.trailing, (!rightCollapsed && selectedPlace != nil) ? 356 : 16)
                .animation(.easeOut(duration: 0.16), value: rightCollapsed)
        }
        .background(StudioTheme.canvas)
        .onAppear { fitAllPlaces() }
        .onChange(of: placeSearch) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults = []
                hasSearched = false
            }
        }
    }

    // Search and map actions are separate functional groups, with no enclosing input tray.
    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            mapSearchField
            mapActions
            Spacer(minLength: 0)
        }
    }

    private var mapSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search places or addresses", text: $placeSearch)
                .font(.system(size: 12)).textFieldStyle(.plain)
                .studioTextCursor().focused($searchFocused)
                .onSubmit { searchPlaces() }
                .onExitCommand { clearMapSearch() }
                .accessibilityLabel("Search places or addresses")
            if mapSearching { ProgressView().controlSize(.mini) }
            if !placeSearch.isEmpty {
                Button(action: clearMapSearch) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
                    .help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 150, idealWidth: 280, maxWidth: 280)
        .frame(height: 38)
        .modifier(FramoFloatingSurface(radius: 12))
    }

    private var mapActions: some View {
        HStack(spacing: 2) {
            Button {
                showsSavedPanel.toggle()
                hasSearched = false
                searchResults = []
                searchFocused = false
            } label: { Image(systemName: showsSavedPanel ? "bookmark.fill" : "bookmark") }
            .buttonStyle(FramoFloatingButtonStyle(selected: showsSavedPanel))
            .help("Saved places").accessibilityLabel("Saved places")

            Menu {
                ForEach(FramoMapStyleV21.allCases) { style in
                    Button { mapStyle = style } label: {
                        if mapStyle == style { Label(style.rawValue, systemImage: "checkmark") }
                        else { Text(style.rawValue) }
                    }
                }
                Divider()
                Button("Fit saved places") { fitAllPlaces() }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Map style").accessibilityLabel("Map style")

            Button { fitAllPlaces() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(FramoFloatingButtonStyle())
                .help("Fit saved places").accessibilityLabel("Fit saved places")

            Button { addPlaceAtCenter() } label: { Image(systemName: "plus") }
                .buttonStyle(FramoFloatingButtonStyle())
                .help("Add place at map center").accessibilityLabel("Add place at map center")
        }
        .padding(4)
        .modifier(FramoFloatingSurface(radius: 12))
    }

    private var mapZoomControls: some View {
        VStack(spacing: 2) {
            Button { zoomMap(by: 0.68) } label: { Image(systemName: "plus") }
                .buttonStyle(FramoFloatingButtonStyle())
                .help("Zoom in")
            Button { zoomMap(by: 1.46) } label: { Image(systemName: "minus") }
                .buttonStyle(FramoFloatingButtonStyle())
                .help("Zoom out")
        }
        .padding(4)
        .modifier(FramoFloatingSurface(radius: 12))
    }

    private func zoomMap(by factor: Double) {
        var next = region
        next.span.latitudeDelta = min(max(next.span.latitudeDelta * factor, 0.0005), 180)
        next.span.longitudeDelta = min(max(next.span.longitudeDelta * factor, 0.0005), 180)
        withAnimation(.easeOut(duration: 0.18)) { region = next }
    }

    private func clearMapSearch() {
        placeSearch = ""
        searchResults = []
        hasSearched = false
    }

    private var savedPlacesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(store.places.count)")
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 38)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if filteredPlaces.isEmpty {
                        Text("No saved places")
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    ForEach(filteredPlaces) { place in
                        Button { open(place) } label: {
                            HStack(spacing: 8) {
                                FramoLocalPhotoV20(path: place.photoPaths.first, fallback: "", width: 36, height: 36, fit: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name.isEmpty ? "Untitled place" : place.name)
                                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(place.address.isEmpty ? "No address" : place.address)
                                        .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 48)
                            .background(selectedPlaceID == place.id ? StudioTheme.selected : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                        .contextMenu {
                            Button("Open") { open(place) }
                            Button("Add photos…") { addPhoto(to: place.id) }
                            Divider()
                            Button("Remove", role: .destructive) { store.deletePlace(place.id) }
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 280, height: 300)
        .modifier(FramoFloatingSurface(radius: 14))
    }

    private var searchResultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Results")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if mapSearching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).frame(height: 38)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if !mapSearching && searchResults.isEmpty {
                        Text("No places found")
                            .font(.system(size: 11)).foregroundStyle(StudioTheme.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(searchResults) { result in
                        HStack(spacing: 8) {
                            Image(systemName: "mappin")
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background(StudioTheme.soft)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(result.subtitle.isEmpty ? "Location" : result.subtitle)
                                    .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Button { saveSearchResult(result) } label: { Image(systemName: "plus") }
                                .buttonStyle(FramoFloatingButtonStyle())
                                .help("Save this place").accessibilityLabel("Save " + result.title)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                        .onTapGesture { preview(result) }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 280, height: min(350, max(100, CGFloat(searchResults.count) * 50 + 42)))
        .modifier(FramoFloatingSurface(radius: 14))
    }

    @ViewBuilder private var inspector: some View {
        if let place = selectedBinding {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Place name", text: place.name)
                                .textFieldStyle(.plain).studioTextCursor()
                                .font(.system(size: 16, weight: .semibold))
                            TextField("Address", text: place.address, axis: .vertical)
                                .textFieldStyle(.plain).studioTextCursor()
                                .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                        }
                        Spacer()
                        Button { rightCollapsed = true; selectedPlaceID = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(IconButtonStyle())
                    }

                    if let first = place.wrappedValue.photoPaths.first {
                        FramoLocalPhotoV20(path: first, fallback: "", width: 298, height: 142, fit: false)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }

                    HStack(spacing: 6) {
                        Button("Add photos…") { addPhoto(to: place.wrappedValue.id) }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Center") { center(on: place.wrappedValue) }
                            .buttonStyle(SecondaryButtonStyle())
                        Menu {
                            Button("Open in Maps") { openInMaps(place.wrappedValue) }
                            Button("Find this address") { locateSelectedPlace() }
                            Button("Copy coordinates") { copyCoordinates(place.wrappedValue) }
                            Spacer().frame(height: 2)
                            Button("Remove place", role: .destructive) { deleteSelectedPlace() }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }

                    if !place.wrappedValue.photoPaths.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(place.wrappedValue.photoPaths.prefix(4).enumerated()), id: \.offset) { _, path in
                                ZStack(alignment: .topTrailing) {
                                    FramoLocalPhotoV20(path: path, fallback: "", width: 58, height: 44, fit: false)
                                    Button {
                                        store.removePhoto(fromPlace: place.wrappedValue.id, path: path)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 3, y: -3)
                                }
                            }
                            if place.wrappedValue.photoPaths.count > 4 {
                                Text("+\(place.wrappedValue.photoPaths.count - 4)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(StudioTheme.tertiary)
                            }
                            Spacer()
                        }
                    }

                    Spacer().frame(height: 2)
                    HStack {
                        Text("Work").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(place.wrappedValue.projectIDs.count) linked")
                            .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
                    }
                    VStack(spacing: 3) {
                        ForEach(store.projects) { project in
                            Button {
                                let linked = place.wrappedValue.projectIDs.contains(project.id)
                                store.setPlaceLinked(place.wrappedValue.id, to: project.id, linked: !linked)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: place.wrappedValue.projectIDs.contains(project.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 10))
                                    Capsule().fill(Color(hex: project.colorHex)).frame(width: 3, height: 17)
                                    Text(project.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                                    Spacer()
                                }
                                .frame(height: 28)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                    }

                    Spacer().frame(height: 2)
                    Text("Notes").font(.system(size: 12, weight: .semibold))
                    TextEditor(text: place.notes)
                        .font(.system(size: 11))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                        .padding(7)
                        .background(StudioTheme.input)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .padding(13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func open(_ place: StudioPlace) {
        selectedPlaceID = place.id
        rightCollapsed = false
        showsSavedPanel = false
        hasSearched = false
        searchResults = []
        center(on: place)
    }

    private func preview(_ result: FramoPlaceSearchResult) {
        withAnimation(.easeOut(duration: 0.18)) {
            region.center = CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude)
            region.span = MKCoordinateSpan(latitudeDelta: 0.045, longitudeDelta: 0.045)
        }
    }

    private func fitAllPlaces() {
        let coordinates = store.places.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            .filter { CLLocationCoordinate2DIsValid($0) }
        guard let first = coordinates.first else { return }
        let minLat = coordinates.map(\.latitude).min() ?? first.latitude
        let maxLat = coordinates.map(\.latitude).max() ?? first.latitude
        let minLon = coordinates.map(\.longitude).min() ?? first.longitude
        let maxLon = coordinates.map(\.longitude).max() ?? first.longitude
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(170, max(0.025, (maxLat - minLat) * 1.35)),
                                   longitudeDelta: min(350, max(0.025, (maxLon - minLon) * 1.35)))
        )
    }

    private func addPlaceAtCenter() {
        let id = store.createPlace(latitude: region.center.latitude, longitude: region.center.longitude)
        selectedPlaceID = id
        rightCollapsed = false
        showsSavedPanel = false
    }

    private func saveSearchResult(_ result: FramoPlaceSearchResult) {
        if let existing = store.places.first(where: {
            abs($0.latitude - result.latitude) < 0.0001 && abs($0.longitude - result.longitude) < 0.0001
        }) {
            open(existing)
            return
        }
        let id = store.createPlace(name: result.title, address: result.subtitle, latitude: result.latitude, longitude: result.longitude)
        selectedPlaceID = id
        rightCollapsed = false
        hasSearched = false
        searchResults = []
        placeSearch = ""
        if let place = store.places.first(where: { $0.id == id }) { center(on: place) }
    }

    private func deleteSelectedPlace() {
        guard let selectedPlaceID else { return }
        store.deletePlace(selectedPlaceID)
        self.selectedPlaceID = nil
        rightCollapsed = true
    }

    private func center(on place: StudioPlace) {
        withAnimation(.easeOut(duration: 0.18)) {
            region.center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            region.span = MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
        }
    }

    private func addPhoto(to placeID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addPhoto(toPlace: placeID, sourceURL: url) }
    }

    private func locateSelectedPlace() {
        guard let place = selectedPlace, !place.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        locating = true
        let query = place.address
        Task { @MainActor in
            defer { locating = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard let coordinate = response.mapItems.first?.placemark.coordinate,
                      let index = store.places.firstIndex(where: { $0.id == place.id }) else { return }
                store.places[index].latitude = coordinate.latitude
                store.places[index].longitude = coordinate.longitude
                center(on: store.places[index])
            } catch {
                store.pluginNotice = "Couldn't find that address"
            }
        }
    }

    private func searchPlaces() {
        let query = searchQuery
        guard !query.isEmpty else { return }
        hasSearched = true
        showsSavedPanel = false
        mapSearching = true
        let searchRegion = region
        Task { @MainActor in
            defer { mapSearching = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = searchRegion
            do {
                let response = try await MKLocalSearch(request: request).start()
                var seen = Set<String>()
                let results = response.mapItems.prefix(8).compactMap { item -> FramoPlaceSearchResult? in
                    let coordinate = item.placemark.coordinate
                    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                    let title = item.name ?? item.placemark.name ?? query
                    let subtitle = item.placemark.title ?? [item.placemark.locality, item.placemark.administrativeArea]
                        .compactMap { $0 }.joined(separator: ", ")
                    let key = "\(title.lowercased())|\(String(format: "%.4f", coordinate.latitude))|\(String(format: "%.4f", coordinate.longitude))"
                    guard seen.insert(key).inserted else { return nil }
                    let category = item.pointOfInterestCategory?.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? ""
                    return FramoPlaceSearchResult(title: title, subtitle: subtitle, latitude: coordinate.latitude, longitude: coordinate.longitude, category: category)
                }
                searchResults = results
                if let first = results.first { preview(first) }
            } catch {
                store.pluginNotice = "Couldn't search Apple Maps"
                searchResults = []
            }
        }
    }

    private func copyCoordinates(_ place: StudioPlace) {
        let text = String(format: "%.6f, %.6f", place.latitude, place.longitude)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.pluginNotice = "Coordinates copied"
    }

    private func openInMaps(_ place: StudioPlace) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)))
        mapItem.name = place.name
        mapItem.openInMaps()
    }
}


struct FramoOnboardingViewV20: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Binding var isPresented: Bool

    @State private var step = 0
    @State private var securityPassword = ""
    @State private var securityConfirm = ""
    @State private var securityError: String?
    @State private var onboardingRecoveryKit: ModoRecoveryKit?

    private struct StepInfo {
        let eyebrow: String
        let title: String
        let subtitle: String
        let symbol: String
    }

    private let steps: [StepInfo] = [
        StepInfo(
            eyebrow: "WELCOME",
            title: "Build MODO around your business.",
            subtitle: "A clean first setup: your workspace, the tools you actually need, your brand and your preferred way of working.",
            symbol: "sparkles"
        ),
        StepInfo(
            eyebrow: "SECURITY",
            title: "Protect the workspace.",
            subtitle: "Set the app lock now, then save recovery access so a lost password or unavailable fingerprint never locks you out.",
            symbol: "lock"
        ),
        StepInfo(
            eyebrow: "BUSINESS",
            title: "Give MODO the basics.",
            subtitle: "These details become the default context for money, dates, documents and customer-facing work.",
            symbol: "building.2"
        ),
        StepInfo(
            eyebrow: "TOOLS",
            title: "Choose what you need.",
            subtitle: "Keep MODO calm. Select the areas that belong in your workspace now; you can change this later.",
            symbol: "square.grid.2x2"
        ),
        StepInfo(
            eyebrow: "BRAND",
            title: "Bring your identity in.",
            subtitle: "Add your logo, icon and brand colors once. MODO keeps them in the workspace and applies them to quotes, invoices and client-facing exports.",
            symbol: "paintbrush"
        ),
        StepInfo(
            eyebrow: "MODE",
            title: "Choose your default view.",
            subtitle: "Modes trim the interface for different kinds of days without moving or deleting any data.",
            symbol: "slider.horizontal.3"
        ),
        StepInfo(
            eyebrow: "READY",
            title: "This is your MODO.",
            subtitle: "The workspace is ready. You can refine modules, brand assets and security later in Settings.",
            symbol: "checkmark"
        )
    ]

    var body: some View {
        HStack(spacing: 0) {
            onboardingRail
                .frame(width: 235)

            Divider()
                .opacity(0.55)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(steps[step].eyebrow)
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(StudioTheme.tertiary)

                    Spacer()

                    Text("\(step + 1) / \(steps.count)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioTheme.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(steps[step].title)
                        .font(.system(size: 29, weight: .semibold))
                        .tracking(-0.5)
                    Text(steps[step].subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .padding(.top, 18)

                Group {
                    switch step {
                    case 0: welcomeSetup
                    case 1: securitySetup
                    case 2: businessSetup
                    case 3: moduleSetup
                    case 4: brandSetup
                    case 5: modeSetup
                    default: readySetup
                    }
                }
                .padding(.top, 22)

                Spacer(minLength: 18)

                HStack {
                    if step > 0 {
                        Button("Back") {
                            withAnimation(.easeOut(duration: 0.18)) { step -= 1 }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Spacer()

                    if step > 0 && step < steps.count - 1 && step != 1 {
                        Button("Skip") {
                            withAnimation(.easeOut(duration: 0.18)) { step += 1 }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                        .studioPointerCursor()
                    }

                    Button(step == steps.count - 1 ? "Enter MODO" : "Continue") {
                        continueTour()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 610)
        .background(StudioTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.72), lineWidth: 0.7)
        }
        .sheet(item: $onboardingRecoveryKit) { kit in
            ModoRecoveryKitSheet(kit: kit) {
                onboardingRecoveryKit = nil
                withAnimation(.easeOut(duration: 0.20)) {
                    step += 1
                }
            }
        }
    }

    private var onboardingRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StudioLogoMark(size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MODO")
                        .font(.system(size: 13, weight: .bold))
                    Text("SETUP")
                        .font(.system(size: 7.5, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(StudioTheme.tertiary)
                }
            }
            .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(index == step ? StudioTheme.primary : StudioTheme.soft)
                                .frame(width: 24, height: 24)

                            if index < step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(index == step ? StudioTheme.canvas : StudioTheme.secondary)
                            } else {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(index == step ? StudioTheme.canvas : StudioTheme.tertiary)
                            }
                        }

                        Text(item.eyebrow.capitalized)
                            .font(.system(size: 9.5, weight: index == step ? .semibold : .medium))
                            .foregroundStyle(index == step ? StudioTheme.primary : StudioTheme.tertiary)

                        Spacer()
                    }
                    .frame(height: 34)
                }
            }

            Spacer()

            Text("You can redo this setup from Settings → Workspace.")
                .font(.system(size: 8))
                .foregroundStyle(StudioTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .background(StudioTheme.soft.opacity(0.18))
    }

    private var welcomeSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                Image("unsplashimagesplashscreen")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 210)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Image("MODOLOGO")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150)
                    .padding(18)
            }
            .frame(maxWidth: 560)
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 8) {
                onboardingFeature("person.2", "Customers")
                onboardingFeature("square.stack.3d.up", "Work")
                onboardingFeature("eurosign.circle", "Money")
                onboardingFeature("checklist", "Tasks")
            }

            Button("Start with MODO defaults") {
                store.initializeProductionWorkspace()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func onboardingFeature(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(StudioTheme.secondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(StudioTheme.soft.opacity(0.68))
        .clipShape(Capsule())
    }

    @ViewBuilder private var securitySetup: some View {
        if store.activeProfile?.isPasswordProtected == true {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StudioTheme.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workspace protection is already active")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Touch ID and recovery can be managed later in Workspaces & Security.")
                            .font(.system(size: 8.5))
                            .foregroundStyle(StudioTheme.tertiary)
                    }
                }
                .padding(12)
                .background(StudioTheme.soft.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .frame(maxWidth: 560)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                SecureField("Workspace password", text: $securityPassword)
                    .textFieldStyle(.plain)
                    .studioTextCursor()
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit { continueTour() }

                SecureField("Confirm password", text: $securityConfirm)
                    .textFieldStyle(.plain)
                    .studioTextCursor()
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit { continueTour() }

                if let securityError {
                    Text(securityError)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.red)
                } else {
                    Text("At least 6 characters. MODO will immediately create Authenticator recovery and one-time backup codes after this step.")
                        .font(.system(size: 8.5))
                        .foregroundStyle(StudioTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 520)
        }
    }

    private var businessSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            onboardingField(
                "Business / studio name",
                text: Binding(
                    get: { store.settings.studioName },
                    set: { store.settings.studioName = $0 }
                )
            )

            HStack(spacing: 9) {
                onboardingField(
                    "City",
                    text: Binding(
                        get: { store.settings.businessCity ?? "" },
                        set: { store.settings.businessCity = $0 }
                    )
                )
                onboardingField(
                    "Country",
                    text: Binding(
                        get: { store.settings.businessCountryCode ?? "BE" },
                        set: { store.settings.businessCountryCode = $0.uppercased() }
                    )
                )
            }

            HStack(spacing: 9) {
                onboardingField(
                    "Currency",
                    text: Binding(
                        get: { store.settings.currency },
                        set: { store.settings.currency = $0.uppercased() }
                    )
                )
                onboardingField(
                    "Time zone",
                    text: Binding(
                        get: { store.settings.timeZoneIdentifier ?? TimeZone.current.identifier },
                        set: { store.settings.timeZoneIdentifier = $0 }
                    )
                )
            }

            Menu {
                ForEach(
                    ["Service business", "Studio / agency", "Consulting", "Field service", "Repair / maintenance", "Other"],
                    id: \.self
                ) { type in
                    Button(type) { store.settings.businessType = type }
                }
            } label: {
                HStack {
                    Text(store.settings.effectiveBusinessType)
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioTheme.tertiary)
                }
                .foregroundStyle(StudioTheme.primary)
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(maxWidth: 560)
    }

    private func onboardingField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .studioTextCursor()
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(StudioTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var moduleSetup: some View {
        let configurable = SidebarDestination.allCases.filter {
            ![SidebarDestination.home, .search, .settings].contains($0)
        }

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 9),
                GridItem(.flexible(), spacing: 9)
            ],
            spacing: 9
        ) {
            ForEach(configurable) { destination in
                let enabled = store.settings.effectiveEnabledDestinations.contains(destination)

                Button {
                    store.setEnabledDestination(destination, enabled: !enabled)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: destination.fallback)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(StudioTheme.soft.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.displayName)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(moduleDescription(destination))
                                .font(.system(size: 8))
                                .foregroundStyle(StudioTheme.tertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(enabled ? StudioTheme.primary : StudioTheme.tertiary)
                    }
                    .foregroundStyle(StudioTheme.primary)
                    .padding(10)
                    .frame(height: 52)
                    .background(enabled ? StudioTheme.selected : StudioTheme.soft.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .studioPointerCursor()
            }
        }
        .frame(maxWidth: 570)
    }

    private func moduleDescription(_ destination: SidebarDestination) -> String {
        switch destination {
        case .customers: "CRM & contacts"
        case .sales: "Leads, opportunities & quotes"
        case .projects: "Work"
        case .tasks: "Tasks & follow-up"
        case .calendar: "Dates & planning"
        case .resources: "People & gear"
        case .places: "Locations & references"
        case .finance: "Invoices & payments"
        default: destination.displayName
        }
    }

    private var brandSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                onboardingBrandSlot(
                    title: "Logo",
                    asset: store.primaryBrandLogo,
                    kind: .logo
                )
                onboardingBrandSlot(
                    title: "Icon",
                    asset: store.primaryBrandIcon,
                    kind: .icon
                )
            }

            HStack(spacing: 9) {
                onboardingColorField(
                    "Primary",
                    value: Binding(
                        get: { store.settings.brandPrimaryHex ?? "111111" },
                        set: { store.settings.brandPrimaryHex = normalizedHex($0) }
                    )
                )
                onboardingColorField(
                    "Secondary",
                    value: Binding(
                        get: { store.settings.brandSecondaryHex ?? "E9E9E6" },
                        set: { store.settings.brandSecondaryHex = normalizedHex($0) }
                    )
                )
            }

            Text("Quotes, invoices and client-facing exports use this identity. Add more logos, marks and imagery any time in Settings → Brand.")
                .font(.system(size: 8.5))
                .foregroundStyle(StudioTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560)
    }

    private func onboardingBrandSlot(
        title: String,
        asset: ModoBrandAsset?,
        kind: ModoBrandAssetKind
    ) -> some View {
        Button {
            chooseOnboardingBrandAsset(kind)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)

                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(StudioTheme.soft.opacity(0.58))

                    if let asset,
                       let image = NSImage(contentsOfFile: asset.path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 17, weight: .medium))
                            Text("Choose \(title.lowercased())")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(StudioTheme.tertiary)
                    }
                }
                .frame(height: 118)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(StudioTheme.border.opacity(0.68), lineWidth: 0.7)
                }
            }
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
        .frame(maxWidth: .infinity)
    }

    private func onboardingColorField(_ title: String, value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: value.wrappedValue))
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)
                TextField("HEX", text: value)
                    .textFieldStyle(.plain)
                    .studioTextCursor()
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(StudioTheme.input)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func chooseOnboardingBrandAsset(_ kind: ModoBrandAssetKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.title = "Choose \(kind.rawValue.lowercased())"
        panel.prompt = "Use"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = store.addBrandAsset(from: url, kind: kind, makePrimary: true)
    }

    private func normalizedHex(_ value: String) -> String {
        String(value.uppercased().filter { $0.isHexDigit }.prefix(6))
    }

    private var modeSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 9)], spacing: 9) {
                ForEach(ModoWorkspaceMode.allCases) { mode in
                    let selected = store.settings.effectiveWorkspaceMode == mode

                    Button {
                        store.setWorkspaceMode(mode)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(mode.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                            }

                            Text(mode.subtitle)
                                .font(.system(size: 8))
                                .foregroundStyle(StudioTheme.secondary)
                                .lineLimit(2)
                        }
                        .foregroundStyle(StudioTheme.primary)
                        .padding(11)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                        .background(selected ? StudioTheme.selected : StudioTheme.soft.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                }
            }

            Text("Modes focus the modules you selected on the previous step; they never delete or rewrite your data. Switch modes any time in Settings.")
                .font(.system(size: 8.5))
                .foregroundStyle(StudioTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 570)
    }

    private var readySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(StudioTheme.primary)
                        .frame(width: 42, height: 42)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(StudioTheme.canvas)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Workspace ready")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(store.settings.effectiveEnabledDestinations.count - 3) selected module\(store.settings.effectiveEnabledDestinations.count - 3 == 1 ? "" : "s") · \(store.brandAssets.count) brand asset\(store.brandAssets.count == 1 ? "" : "s")")
                        .font(.system(size: 8.5))
                        .foregroundStyle(StudioTheme.tertiary)
                }
            }

            Text("Nothing is locked in. Settings → Brand manages identity, and your module selection can be changed whenever your workflow changes.")
                .font(.system(size: 9))
                .foregroundStyle(StudioTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(StudioTheme.soft.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func continueTour() {
        if step == 1 && store.activeProfile?.isPasswordProtected != true {
            guard securityPassword.count >= 6 else {
                securityError = "Use at least 6 characters."
                return
            }

            guard securityPassword == securityConfirm else {
                securityError = "The passwords do not match."
                return
            }

            guard store.setActiveProfilePassword(securityPassword) else {
                securityError = "MODO could not save the workspace password."
                return
            }

            securityPassword = ""
            securityConfirm = ""
            securityError = nil

            if let kit = store.regenerateActiveProfileRecoveryKit() {
                onboardingRecoveryKit = kit
                return
            }
        }

        if step == steps.count - 1 {
            store.markOnboardingComplete()
            isPresented = false
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                step += 1
            }
        }
    }
}

private struct FramoFlatTabsV20: View {
    let items: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    Text(item)
                        .font(.system(size: 10, weight: selection == item ? .semibold : .medium))
                        .foregroundStyle(selection == item ? StudioTheme.primary : StudioTheme.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(selection == item ? StudioTheme.elevated : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).studioPointerCursor()
            }
        }
        .padding(3)
        .background(StudioTheme.soft.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct FramoLocalPhotoV20: View {
    let path: String?
    let fallback: String
    let width: CGFloat
    let height: CGFloat
    let fit: Bool

    var body: some View {
        ZStack {
            StudioTheme.soft
            if let path, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Text(fallback.isEmpty ? "—" : fallback)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioTheme.border))
    }
}

// MARK: - Compact sidebar workspace controls

struct FramoReferenceSharingCard: View {
    @EnvironmentObject private var store: FramoStudioStore
    @ObservedObject var transfer: FramoV5LocalTransferService
    let onSharepoint: () -> Void
    @State private var operationError: String?

    private var backupLabel: String {
        store.settings.autoBackupEnabled == true ? "Automatic backups on" : "Automatic backups off"
    }

    private var intervalLabel: String {
        let minutes = store.settings.effectiveAutoBackupIntervalMinutes
        if minutes > 0 && minutes <= 60 && 60 % minutes == 0 { return "\(60 / minutes)/hr" }
        if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60)hr" }
        return "\(minutes)min"
    }

    private var statusLabel: String {
        if transfer.isTransferring { return transfer.transferDirection }
        guard let date = store.settings.lastBackupDate else { return "Not backed up yet" }
        return "Backed up \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var progress: Double {
        let raw = transfer.isTransferring ? transfer.transferProgress : (store.settings.lastBackupDate == nil ? 0.0 : 1.0)
        return raw.isFinite ? min(max(raw, 0), 1) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggleBackup) {
                HStack(spacing: 6) {
                    Text(backupLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                    Spacer(minLength: 4)
                    Text(intervalLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StudioTheme.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle automatic backups")

            Button(action: backupNow) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(StudioTheme.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workspace")
                            .font(.system(size: 15, weight: .semibold))
                        Text(statusLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioTheme.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioTheme.primary)
                .padding(.horizontal, 11)
                .frame(height: 50)
                .background(StudioTheme.selected.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .studioPointerCursor()
            .help("Back up workspace now")

            HStack(spacing: 6) {
                compactAction("link", "Connect", action: onSharepoint)
                compactAction("square.and.arrow.down", "Import", action: importWorkspace)
                compactAction("square.and.arrow.up", "Export", action: exportWorkspace)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(StudioTheme.primary)
                .controlSize(.mini)
                .accessibilityLabel("Workspace transfer progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
        }
        .padding(11)
        .background(StudioTheme.soft.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .alert("Workspace", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) { Button("OK", role: .cancel) { operationError = nil } }
        message: { Text(operationError ?? "") }
    }

    private func compactAction(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(StudioTheme.secondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(StudioTheme.elevated.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .studioPointerCursor()
        .disabled(transfer.isTransferring)
    }

    private func chooseBackupFolderIfNeeded() -> Bool {
        if store.settings.backupFolderBookmark != nil { return true }
        let panel = NSOpenPanel()
        panel.title = "Choose workspace backup folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try store.setBackupFolder(url); return true }
        catch { operationError = error.localizedDescription; return false }
    }

    private func toggleBackup() {
        if store.settings.autoBackupEnabled == true { store.settings.autoBackupEnabled = false }
        else if chooseBackupFolderIfNeeded() {
            store.settings.autoBackupEnabled = true
            store.runBackupNow()
        }
    }

    private func backupNow() {
        if chooseBackupFolderIfNeeded() { store.runBackupNow() }
    }

    private func exportWorkspace() {
        if let url = store.exportFramo() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func importWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "framo") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importFramo(from: url) }
        catch { operationError = error.localizedDescription }
    }
}

// Uses the actual bundled SVG, including Media folder references and flattened
// Copy Bundle Resources. Asset-catalog entries are also supported, without SF fallbacks.
struct FramoMediaSVGReference: View {
    let name: String
    let tintHex: String

    var body: some View {
        Group {
            if let image = FramoReferenceSVGResources.image(named: name) {
                Image(nsImage: image).renderingMode(.template).resizable()
                    .scaledToFit().foregroundStyle(Color(hex: tintHex))
            } else if let data = FramoReferenceSVGResources.svgData[name] {
                FramoReferenceSVGWebView(data: data, tintHex: tintHex)
            } else {
                FramoResourceFallbackIcon(name: name, tintHex: tintHex)
                    .onAppear {
                        NSLog("Media/%@.svg was not found in the app bundle; showing the built-in outline until the resource is available.", name)
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum FramoReferenceSVGResources {
    private static func assetNames(_ name: String) -> [String] {
        [name, name + ".svg", "Media/" + name, "Media/" + name + ".svg",
         "media/" + name, "media/" + name + ".svg", "icon-" + name]
    }

    static func image(named name: String) -> NSImage? {
        for candidate in assetNames(name) {
            if let image = NSImage(named: NSImage.Name(candidate)) { return image }
        }
        if let data = svgData[name], let image = NSImage(data: data) { return image }
        return nil
    }

    static let svgData: [String: Data] = {
        let names = ["disk", "download", "upload", "sharepoint"]
        var result: [String: Data] = [:]
        for name in names {
            for candidate in assetNames(name) {
                if let asset = NSDataAsset(name: candidate),
                   String(data: asset.data, encoding: .utf8)?.contains("<svg") == true {
                    result[name] = asset.data
                    break
                }
            }
            if result[name] != nil { continue }
            for folder in ["Media", "media", "Resources/Media", ""] {
                if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: folder.isEmpty ? nil : folder),
                   let data = try? Data(contentsOf: url) { result[name] = data; break }
            }
        }
        if result.count < names.count, let root = Bundle.main.resourceURL,
           let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in files where url.pathExtension.lowercased() == "svg" {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if names.contains(name), result[name] == nil, let data = try? Data(contentsOf: url) { result[name] = data }
            }
        }
        return result
    }()
}

private struct FramoReferenceSVGWebView: NSViewRepresentable {
    let data: Data
    let tintHex: String

    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let encoded = data.base64EncodedString()
        let tint = tintHex.filter { $0.isHexDigit }
        let key = tint + encoded
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        // Local SVG only. No JavaScript, remote images, scripts, or network requests.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;pointer-events:none}
        div{width:100%;height:100%;background:#\(tint);-webkit-mask:url('data:image/svg+xml;base64,\(encoded)') center/contain no-repeat;}</style>
        </head><body><div></div></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Native map with clustered pins and no permanent photo labels
private struct FramoSeamlessPlacesMap: NSViewRepresentable {
    let places: [StudioPlace]
    @Binding var region: MKCoordinateRegion
    @Binding var selectedID: UUID?
    let mapType: MKMapType
    let onSelect: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = mapType
        map.pointOfInterestFilter = .excludingAll
        map.showsBuildings = false
        map.showsTraffic = false
        map.showsScale = false
        map.showsCompass = true
        map.showsZoomControls = false
        map.isPitchEnabled = false
        map.setRegion(region, animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if map.mapType != mapType { map.mapType = mapType }
        let validPlaces = places.filter {
            CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        let validIDs = Set(validPlaces.map(\.id))
        let removed = coordinator.pins.keys.filter { !validIDs.contains($0) }
        for id in removed {
            if let annotation = coordinator.pins.removeValue(forKey: id) { map.removeAnnotation(annotation) }
        }
        for place in validPlaces {
            let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            if let pin = coordinator.pins[place.id] {
                if pin.coordinate.latitude != coordinate.latitude || pin.coordinate.longitude != coordinate.longitude {
                    pin.coordinate = coordinate
                }
                if pin.title != place.name { pin.title = place.name }
                if pin.photoPath != place.photoPaths.first {
                    pin.photoPath = place.photoPaths.first
                    (map.view(for: pin) as? PhotoPinView)?.configure(photoPath: pin.photoPath, selected: selectedID == place.id)
                }
            } else {
                let pin = PlacePin(id: place.id, name: place.name, coordinate: coordinate, photoPath: place.photoPaths.first)
                coordinator.pins[place.id] = pin
                map.addAnnotation(pin)
            }
        }
        if !Coordinator.matches(map.region, region) {
            coordinator.applyingRegion = true
            map.setRegion(region, animated: false)
            coordinator.applyingRegion = false
        }
        if let selectedID, let pin = coordinator.pins[selectedID] {
            if !(map.selectedAnnotations.contains { ($0 as? PlacePin)?.id == selectedID }) {
                map.selectAnnotation(pin, animated: false)
            }
        } else {
            for annotation in map.selectedAnnotations { map.deselectAnnotation(annotation, animated: false) }
        }
    }

    final class PlacePin: NSObject, MKAnnotation {
        let id: UUID
        @objc dynamic var title: String?
        @objc dynamic var coordinate: CLLocationCoordinate2D
        var photoPath: String?
        init(id: UUID, name: String, coordinate: CLLocationCoordinate2D, photoPath: String?) {
            self.id = id
            self.title = name
            self.coordinate = coordinate
            self.photoPath = photoPath
            super.init()
        }
    }

    final class PhotoPinView: MKAnnotationView {
        private let imageView = NSImageView(frame: .zero)
        private let fallback = NSImageView(frame: .zero)

        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            wantsLayer = true
            frame = NSRect(x: 0, y: 0, width: 46, height: 46)
            centerOffset = NSPoint(x: 0, y: -22)
            layer?.cornerRadius = 11
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.windowBackgroundColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.masksToBounds = false

            imageView.imageScaling = .scaleAxesIndependently
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 9
            imageView.layer?.masksToBounds = true
            addSubview(imageView)

            fallback.imageScaling = .scaleProportionallyUpOrDown
            fallback.contentTintColor = .secondaryLabelColor
            addSubview(fallback)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            imageView.frame = bounds.insetBy(dx: 3, dy: 3)
            fallback.frame = bounds.insetBy(dx: 12, dy: 12)
        }

        func configure(photoPath: String?, selected: Bool) {
            if let photoPath, let image = NSImage(contentsOfFile: photoPath) {
                imageView.image = image
                imageView.isHidden = false
                fallback.isHidden = true
            } else {
                imageView.image = nil
                imageView.isHidden = true
                fallback.isHidden = false
                fallback.image = NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: "Saved place")
            }
            layer?.borderWidth = selected ? 3 : 2
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = selected ? 0.22 : 0.12
            layer?.shadowRadius = selected ? 6 : 3
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FramoSeamlessPlacesMap
        var pins: [UUID: PlacePin] = [:]
        var applyingRegion = false
        init(_ parent: FramoSeamlessPlacesMap) { self.parent = parent }

        static func matches(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.000001 &&
            abs(lhs.center.longitude - rhs.center.longitude) < 0.000001 &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.000001 &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.000001
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !applyingRegion else { return }
            let latest = mapView.region
            guard !Self.matches(parent.region, latest) else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.region = latest }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let identifier = "framo-cluster"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = cluster
                view.canShowCallout = false
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.markerTintColor = .darkGray
                view.glyphTintColor = .white
                view.glyphText = "\(cluster.memberAnnotations.count)"
                view.clusteringIdentifier = nil
                view.displayPriority = .defaultHigh
                return view
            }

            guard let pin = annotation as? PlacePin else { return nil }
            let identifier = "framo-photo-place"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PhotoPinView)
                ?? PhotoPinView(annotation: pin, reuseIdentifier: identifier)
            view.annotation = pin
            view.canShowCallout = false
            view.clusteringIdentifier = "framo-saved-places"
            view.displayPriority = parent.selectedID == pin.id ? .required : .defaultHigh
            view.configure(photoPath: pin.photoPath, selected: parent.selectedID == pin.id)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                return
            }
            guard let pin = view.annotation as? PlacePin else { return }
            view.displayPriority = .required
            (view as? PhotoPinView)?.configure(photoPath: pin.photoPath, selected: true)
            if parent.selectedID != pin.id {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.selectedID = pin.id
                    self?.parent.onSelect()
                }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if let pin = view.annotation as? PlacePin {
                view.displayPriority = .defaultHigh
                (view as? PhotoPinView)?.configure(photoPath: pin.photoPath, selected: false)
            }
        }
    }
}

// Used only when the actual SVG cannot be found in the installed app bundle.
// Never substitutes a system symbol for an existing Media resource.
private struct FramoResourceFallbackIcon: View {
    let name: String
    let tintHex: String

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                             tx: (size.width - 24 * scale) / 2,
                                             ty: (size.height - 24 * scale) / 2)
            context.stroke(outline.applying(transform), with: .color(Color(hex: tintHex)),
                           style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
        }
    }

    private var outline: Path {
        var p = Path()
        switch name {
        case "upload", "download":
            let tip: CGFloat = name == "upload" ? 5 : 19
            let shoulder: CGFloat = name == "upload" ? 11 : 13
            let tail: CGFloat = name == "upload" ? 19 : 5
            p.move(to: CGPoint(x: 12, y: tail)); p.addLine(to: CGPoint(x: 12, y: tip))
            p.move(to: CGPoint(x: 6, y: shoulder)); p.addLine(to: CGPoint(x: 12, y: tip))
            p.addLine(to: CGPoint(x: 18, y: shoulder))
        case "sharepoint":
            p.addRoundedRect(in: CGRect(x: 1, y: 2, width: 14, height: 11), cornerSize: CGSize(width: 3, height: 3))
            p.addRoundedRect(in: CGRect(x: 9, y: 11, width: 14, height: 11), cornerSize: CGSize(width: 3, height: 3))
            p.addEllipse(in: CGRect(x: 5, y: 6, width: 3, height: 3))
            p.addEllipse(in: CGRect(x: 16, y: 15, width: 3, height: 3))
            p.move(to: CGPoint(x: 8, y: 7.5)); p.addLine(to: CGPoint(x: 12, y: 7.5))
            p.move(to: CGPoint(x: 12, y: 16.5)); p.addLine(to: CGPoint(x: 16, y: 16.5))
        default:
            p.move(to: CGPoint(x: 2, y: 13))
            p.addLine(to: CGPoint(x: 6, y: 6))
            p.addQuadCurve(to: CGPoint(x: 8, y: 5), control: CGPoint(x: 6.5, y: 5))
            p.addLine(to: CGPoint(x: 16, y: 5))
            p.addQuadCurve(to: CGPoint(x: 18, y: 6), control: CGPoint(x: 17.5, y: 5))
            p.addLine(to: CGPoint(x: 22, y: 13))
            p.addRoundedRect(in: CGRect(x: 1, y: 12, width: 22, height: 8), cornerSize: CGSize(width: 4, height: 4))
            p.addEllipse(in: CGRect(x: 17.3, y: 15.3, width: 1.4, height: 1.4))
        }
        return p
    }
}

// MARK: - MODO Finance + Peppol

struct ModoFinanceView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var editor: InvoiceSelection?
    @State private var showPeppolSetup = false

    private struct InvoiceSelection: Identifiable { let id: UUID }

    private var sentValue: Double {
        store.invoices.filter { $0.status == .sent || $0.status == .paid }.reduce(0) { $0 + $1.total }
    }

    private var openValue: Double {
        store.invoices.filter { $0.status != .paid }.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summary
                peppolStatus
                invoiceList
            }
            .frame(maxWidth: 1180)
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 46)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $editor) { selection in
            ModoInvoiceEditor(invoiceID: selection.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $showPeppolSetup) {
            ModoPeppolSetupView()
                .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Money")
                    .font(.system(size: 30, weight: .semibold))
                Text("Invoices, payments and cash visibility without pretending to be full accounting.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Button("Peppol setup") { showPeppolSetup = true }
                .buttonStyle(SecondaryButtonStyle())
            Button("New invoice") {
                let id = store.createInvoice(projectID: store.selectedProjectID)
                editor = InvoiceSelection(id: id)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            financeMetric("Invoices", "\(store.invoices.count)", "all documents")
            financeMetric("Outstanding", money(store.outstandingInvoiceTotal), "still to be collected")
            financeMetric("Paid", money(store.business.payments.reduce(0) { $0 + $1.amount }), "recorded payments")
            financeMetric("Drafts", "\(store.invoices.filter { $0.status == .draft || $0.status == .ready }.count)", "still being prepared")
        }
    }

    private func financeMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
            Text(value).font(.system(size: 24, weight: .semibold))
            Text(detail).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(StudioTheme.soft.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var peppolStatus: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Peppol")
                    .font(.system(size: 12, weight: .semibold))
                Text(store.peppolConnector.isConfigured ? store.peppolConnector.state.label : "Lookup and UBL export are ready. Connect the optional free-tier transport only when you want one-click sending.")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Text(store.peppolConnector.isConfigured ? "Transport: Peppyrus" : "No paid transport required")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(StudioTheme.tertiary)
            Button(store.peppolConnector.isConfigured ? "Manage" : "Connect") { showPeppolSetup = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(15)
        .background(StudioTheme.soft.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var invoiceList: some View {
        if store.invoices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No invoices yet").font(.system(size: 17, weight: .semibold))
                Text("Create an invoice from here and link it to a project when useful.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                Button("Create first invoice") {
                    let id = store.createInvoice(projectID: store.selectedProjectID)
                    editor = InvoiceSelection(id: id)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 5)
            }
            .padding(.vertical, 28)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Invoices")
                    .font(.system(size: 16, weight: .semibold))
                ForEach(store.invoices.sorted { $0.issueDate > $1.issueDate }) { invoice in
                    Button { editor = InvoiceSelection(id: invoice.id) } label: {
                        HStack(spacing: 14) {
                            Capsule()
                                .fill(statusColor(invoice.status))
                                .frame(width: 3, height: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(invoice.invoiceNumber).font(.system(size: 12, weight: .semibold))
                                Text(invoice.customerName.isEmpty ? "No customer yet" : invoice.customerName)
                                    .font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                            }
                            Spacer()
                            Text(invoice.status.rawValue)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(StudioTheme.secondary)
                            Text(money(invoice.total))
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 110, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 58)
                        .background(StudioTheme.soft.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .studioPointerCursor()
                }
            }
        }
    }

    private func statusColor(_ status: ModoInvoiceStatus) -> Color {
        switch status {
        case .draft: StudioTheme.tertiary
        case .ready: Color(hex: "C59155")
        case .sending: Color(hex: "5578C5")
        case .issued: Color(hex: "5578C5")
        case .sent: Color(hex: "8664B8")
        case .partlyPaid: Color(hex: "C59155")
        case .paid: StudioTheme.green
        case .overdue: StudioTheme.red
        case .voided, .credited: StudioTheme.tertiary
        case .failed: StudioTheme.red
        }
    }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = store.settings.currency
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(store.settings.currency)"
    }
}

private struct ModoPeppolSetupView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var senderParticipantID = ""
    @State private var vat = ""
    @State private var iban = ""
    @State private var street = ""
    @State private var zip = ""
    @State private var city = ""
    @State private var country = "BE"
    @State private var useTestEnvironment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Peppol")
                        .font(.system(size: 24, weight: .semibold))
                    Text("MODO's invoice creation, directory lookup and Peppol BIS export are free. Live transport is optional.")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("FREE IN MODO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)
                HStack(spacing: 14) {
                    freeFeature("Peppol BIS 3.0 UBL")
                    freeFeature("Public recipient lookup")
                    freeFeature("Unlimited local invoices")
                }
            }
            .padding(14)
            .background(StudioTheme.soft.opacity(0.44))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("BUSINESS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)

                setupField("Sender Peppol ID", text: $senderParticipantID)
                Text("Belgium: use 0208 followed by your 10-digit KBO number, for example 0208:0123456789.")
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)

                HStack(spacing: 8) {
                    setupField("VAT number", text: $vat)
                    setupField("IBAN", text: $iban)
                }
                setupField("Street", text: $street)
                HStack(spacing: 8) {
                    setupField("ZIP", text: $zip)
                    setupField("City", text: $city)
                    setupField("Country", text: $country, width: 88)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Optional one-click sending")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Peppyrus is a certified Access Point with a published free plan. MODO does not add a surcharge.")
                            .font(.system(size: 9))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Toggle("Test", isOn: $useTestEnvironment)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SecureField(store.peppolConnector.apiKey.isEmpty ? "Peppyrus API key (optional)" : "API key saved in Keychain", text: $apiKey)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(StudioTheme.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(store.peppolConnector.providerFreeTierLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(StudioTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(StudioTheme.soft.opacity(0.30))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            if case .error(let message) = store.peppolConnector.state {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.red)
            } else {
                Text(store.peppolConnector.state.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTheme.secondary)
            }

            HStack {
                if store.peppolConnector.isConfigured {
                    Button("Disconnect transport", role: .destructive) {
                        store.peppolConnector.disconnect()
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Test") {
                        Task { await store.peppolConnector.testConnection() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Save") {
                    store.peppolConnector.configure(
                        apiKey: apiKey,
                        senderParticipantID: senderParticipantID,
                        iban: iban,
                        businessVAT: vat,
                        street: street,
                        zip: zip,
                        city: city,
                        countryCode: country,
                        useTestEnvironment: useTestEnvironment
                    )
                    if store.peppolConnector.isConfigured {
                        Task { await store.peppolConnector.testConnection() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 590)
        .background(StudioTheme.canvas)
        .onAppear {
            senderParticipantID = store.settings.peppolSenderParticipantID ?? ""
            vat = store.settings.peppolBusinessVAT ?? ""
            iban = store.settings.peppolBusinessIBAN ?? ""
            street = store.settings.peppolBusinessStreet ?? ""
            zip = store.settings.peppolBusinessZip ?? ""
            city = store.settings.peppolBusinessCity ?? ""
            country = store.settings.peppolBusinessCountryCode ?? "BE"
            useTestEnvironment = store.settings.peppolUseTestEnvironment ?? false
        }
    }

    @ViewBuilder private func freeFeature(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StudioTheme.green)
            Text(title)
                .font(.system(size: 9, weight: .medium))
        }
    }

    private func setupField(_ placeholder: String, text: Binding<String>, width: CGFloat? = nil) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .studioTextCursor()
            .padding(.horizontal, 12)
            .frame(width: width, height: 38)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(StudioTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ModoInvoiceEditor: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss
    let invoiceID: UUID
    @State private var draft: ModoInvoice?
    @State private var recipientMessage: String?
    @State private var paymentAmount: Double = 0
    @State private var paymentReference = ""

    var body: some View {
        Group {
            if let invoice = Binding($draft) {
                VStack(alignment: .leading, spacing: 0) {
                    editorHeader(invoice)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Group {
                                basics(invoice)
                                customer(invoice)
                                lines(invoice)
                                notes(invoice)
                            }
                            .disabled(!isCommerciallyEditable(invoice.wrappedValue))
                            .opacity(isCommerciallyEditable(invoice.wrappedValue) ? 1 : 0.72)
                            if !isCommerciallyEditable(invoice.wrappedValue) {
                                HStack(spacing: 8) {
                                    Image(systemName: "lock.fill")
                                    Text("Issued invoice content is locked. Payment and delivery status can still be updated.")
                                }
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(StudioTheme.secondary)
                            }
                            transmission(invoice)
                        }
                        .padding(28)
                    }
                }
                .onChange(of: invoice.wrappedValue) { _, value in store.updateInvoice(value) }
            } else {
                ProgressView().frame(width: 760, height: 500)
            }
        }
        .frame(width: 820)
        .frame(minHeight: 620)
        .onAppear { draft = store.invoices.first(where: { $0.id == invoiceID }) }
    }

    private func isCommerciallyEditable(_ invoice: ModoInvoice) -> Bool {
        invoice.issuedAt == nil && invoice.issuedSnapshot == nil && [.draft, .ready, .failed].contains(invoice.status)
    }

    private func editorHeader(_ invoice: Binding<ModoInvoice>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Invoice \(invoice.wrappedValue.invoiceNumber)").font(.system(size: 22, weight: .semibold))
                Text(invoice.wrappedValue.status.rawValue).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            if [.sent, .partlyPaid, .paid].contains(invoice.wrappedValue.status) {
                Button("Refresh evidence") {
                    Task { await store.peppolConnector.refreshEvidence(invoiceID: invoiceID) }
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button("Export PDF") {
                store.updateInvoice(invoice.wrappedValue)
                store.exportInvoicePDF(invoiceID)
            }
            .buttonStyle(SecondaryButtonStyle())

            Button("Done") {
                store.updateInvoice(invoice.wrappedValue)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .frame(height: 78)
        .background(StudioTheme.soft.opacity(0.34))
    }

    private func basics(_ invoice: Binding<ModoInvoice>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Invoice")
            HStack(spacing: 10) {
                field("Number", text: invoice.invoiceNumber)
                DatePicker("Issue", selection: invoice.issueDate, displayedComponents: .date)
                    .datePickerStyle(.field)
                DatePicker("Due", selection: invoice.dueDate, displayedComponents: .date)
                    .datePickerStyle(.field)
            }
            Picker("Project", selection: invoice.projectID) {
                Text("No project").tag(Optional<UUID>.none)
                ForEach(store.projects) { project in Text(project.title).tag(Optional(project.id)) }
            }
            .pickerStyle(.menu)
        }
    }

    private func customer(_ invoice: Binding<ModoInvoice>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Customer & Peppol")
            Picker("Customer record", selection: invoice.customerID) {
                Text("No linked customer").tag(Optional<UUID>.none)
                ForEach(store.business.organizations) { customer in
                    Text(customer.name).tag(Optional(customer.id))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: invoice.wrappedValue.customerID) { _, customerID in
                guard let customerID, let customer = store.customer(id: customerID) else { return }
                invoice.wrappedValue.customerName = customer.name
                invoice.wrappedValue.customerEmail = customer.email
                invoice.wrappedValue.customerStreet = customer.street
                invoice.wrappedValue.customerZip = customer.postalCode
                invoice.wrappedValue.customerCity = customer.city
                invoice.wrappedValue.customerCountryCode = customer.countryCode
                invoice.wrappedValue.customerPeppolID = customer.peppolID
            }
            HStack(spacing: 10) {
                field("Customer name", text: invoice.customerName)
                field("Email", text: invoice.customerEmail)
            }
            HStack(spacing: 10) {
                field("Street", text: invoice.customerStreet)
                field("ZIP", text: invoice.customerZip, width: 110)
                field("City", text: invoice.customerCity)
                field("Country", text: invoice.customerCountryCode, width: 90)
            }
            HStack(spacing: 10) {
                field("Scheme", text: invoice.customerPeppolScheme, width: 120)
                field("Peppol ID", text: invoice.customerPeppolID)
                Button("Check recipient") {
                    Task {
                        let ok = await store.peppolConnector.discoverReceiver(scheme: invoice.wrappedValue.customerPeppolScheme, identifier: invoice.wrappedValue.customerPeppolID)
                        recipientMessage = ok ? "Available on Peppol" : store.peppolConnector.state.label
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if let recipientMessage { Text(recipientMessage).font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary) }
            Text("Belgian companies normally use BE:EN / Peppol scheme 0208 with the 10-digit KBO enterprise number.")
                .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
        }
    }

    private func lines(_ invoice: Binding<ModoInvoice>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Lines")
                Spacer()
                Button("Add line") { invoice.wrappedValue.lines.append(ModoInvoiceLine()) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            ForEach(invoice.lines) { $line in
                HStack(spacing: 8) {
                    field("Description", text: $line.name)
                    numberField("Qty", value: $line.quantity, width: 75)
                    numberField("Unit price", value: $line.unitPrice, width: 100)
                    numberField("VAT %", value: $line.vatRate, width: 82)
                    Text(money(line.total))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 95, alignment: .trailing)
                    Button { invoice.wrappedValue.lines.removeAll { $0.id == line.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                }
            }
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Subtotal  \(money(invoice.wrappedValue.subtotal))").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                    Text("VAT  \(money(invoice.wrappedValue.vatTotal))").font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                    Text("Total  \(money(invoice.wrappedValue.total))").font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    private func notes(_ invoice: Binding<ModoInvoice>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Notes")
            TextField("Optional invoice note", text: invoice.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .frame(minHeight: 70, alignment: .topLeading)
                .background(StudioTheme.input)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func transmission(_ invoice: Binding<ModoInvoice>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Structured invoice")
                        .font(.system(size: 11, weight: .semibold))
                    Text(invoice.wrappedValue.lastTransmissionMessage ?? "Export a Peppol BIS XML for free, or use the optional connected Access Point for one-click delivery.")
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
                if invoice.wrappedValue.status == .draft || invoice.wrappedValue.status == .ready {
                    Button("Issue invoice") {
                        store.updateInvoice(invoice.wrappedValue)
                        store.issueInvoice(invoiceID)
                        draft = store.invoices.first(where: { $0.id == invoiceID })
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            HStack(spacing: 8) {
                Button("Export UBL") {
                    store.updateInvoice(invoice.wrappedValue)
                    store.peppolConnector.exportUBL(invoiceID: invoiceID)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!invoice.wrappedValue.canSendViaPeppol)

                Spacer()

                if store.peppolConnector.isConfigured {
                    Button("Send via Peppol") {
                        store.updateInvoice(invoice.wrappedValue)
                        Task {
                            await store.peppolConnector.send(invoiceID: invoiceID)
                            draft = store.invoices.first(where: { $0.id == invoiceID })
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!invoice.wrappedValue.canSendViaPeppol)
                } else {
                    Text("One-click delivery is optional")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTheme.tertiary)
                }
            }

            if invoice.wrappedValue.status != .draft && invoice.wrappedValue.status != .voided && invoice.wrappedValue.status != .credited && invoice.wrappedValue.status != .paid {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Record payment").font(.system(size: 10, weight: .semibold))
                    HStack(spacing: 8) {
                        TextField("Amount", value: $paymentAmount, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.plain).padding(.horizontal, 10).frame(width: 120, height: 34).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 8))
                        TextField("Reference", text: $paymentReference)
                            .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 34).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Add") {
                            store.recordPayment(invoiceID: invoiceID, amount: paymentAmount, reference: paymentReference)
                            paymentAmount = 0
                            paymentReference = ""
                            draft = store.invoices.first(where: { $0.id == invoiceID })
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(paymentAmount <= 0)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(StudioTheme.soft.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }

    private func field(_ placeholder: String, text: Binding<String>, width: CGFloat? = nil) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .frame(width: width, height: 38)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(StudioTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func numberField(_ placeholder: String, value: Binding<Double>, width: CGFloat) -> some View {
        TextField(placeholder, value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.plain)
            .padding(.horizontal, 9)
            .frame(width: width, height: 38)
            .background(StudioTheme.input)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = store.settings.currency
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(store.settings.currency)"
    }
}
