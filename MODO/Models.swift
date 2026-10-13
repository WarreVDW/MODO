import Foundation
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable, Codable, Hashable {
    case home = "Home"
    case search = "Search"
    case customers = "Customers"
    case sales = "Sales"
    case projects = "Projects"
    case tasks = "Tasks"
    case calendar = "Calendar"
    case resources = "Crew & gear"
    case places = "Places"
    case finance = "Finance"
    case settings = "Settings"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .home: "Today"
        case .projects: "Work"
        case .finance: "Money"
        case .resources: "Crew & devices"
        default: rawValue
        }
    }
    var asset: String {
        switch self {
        case .home: "icon-home"
        case .search: "icon-search"
        case .customers: "person.2.crop.square.stack"
        case .sales: "chart.line.uptrend.xyaxis"
        case .projects: "icon-all-projects"
        case .tasks: "Tasks"
        case .calendar: "icon-calendar"
        case .resources: "icon-crew"
        case .places: "location.svg"
        case .finance: "eurosign.circle"
        case .settings: "icon-settings"
        }
    }
    var fallback: String {
        switch self {
        case .home: "rectangle.split.2x1"
        case .search: "magnifyingglass"
        case .customers: "person.2"
        case .sales: "chart.line.uptrend.xyaxis"
        case .projects: "square.stack.3d.up"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .resources: "person.2"
        case .places: "mappin.and.ellipse"
        case .finance: "eurosign.circle"
        case .settings: "gearshape"
        }
    }
}

enum ModoWorkspaceMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case studio = "Studio"
    case production = "Production"
    case business = "Business"
    case finance = "Finance"
    case focus = "Focus"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .studio: "Everything, including production tools"
        case .production: "Customers, work, planning, crew and places"
        case .business: "Customers, sales, work and money"
        case .finance: "Customers, quotes, invoices and payments"
        case .focus: "Only what needs attention now"
        }
    }

    var visibleDestinations: Set<SidebarDestination> {
        switch self {
        case .studio:
            return Set(SidebarDestination.allCases)
        case .production:
            return [.home, .search, .customers, .projects, .tasks, .calendar, .resources, .places, .settings]
        case .business:
            return [.home, .search, .customers, .sales, .projects, .tasks, .calendar, .finance, .settings]
        case .finance:
            return [.home, .search, .customers, .sales, .finance, .settings]
        case .focus:
            return [.home, .customers, .projects, .tasks, .calendar, .settings]
        }
    }
}

enum ProjectStatus: String, Codable, CaseIterable, Hashable {
    case lead = "Lead"
    case preproduction = "Pre-production"
    case production = "Production"
    case postproduction = "Post-production"
    case review = "Review"
    case delivered = "Delivered"

    func displayName(for workType: ModoWorkType? = nil) -> String {
        switch workType {
        case .creativeProduction:
            return rawValue
        case .service:
            return switch self {
            case .lead: "Lead"
            case .preproduction: "Planned"
            case .production: "In progress"
            case .postproduction: "Finishing"
            case .review: "Review"
            case .delivered: "Delivered"
            }
        case .consulting:
            return switch self {
            case .lead: "Lead"
            case .preproduction: "Scoping"
            case .production: "Active"
            case .postproduction: "Wrap-up"
            case .review: "Review"
            case .delivered: "Delivered"
            }
        case .event:
            return switch self {
            case .lead: "Lead"
            case .preproduction: "Planning"
            case .production: "Event"
            case .postproduction: "Follow-up"
            case .review: "Review"
            case .delivered: "Delivered"
            }
        case .flexible:
            return switch self {
            case .lead: "Lead"
            case .preproduction: "Planned"
            case .production: "Active"
            case .postproduction: "Finishing"
            case .review: "Review"
            case .delivered: "Delivered"
            }
        case .none:
            return switch self {
            case .lead: "Lead"
            case .preproduction: "Planning"
            case .production: "In progress"
            case .postproduction: "Finishing"
            case .review: "Review"
            case .delivered: "Delivered"
            }
        }
    }

    var color: Color {
        switch self {
        case .lead: .gray
        case .preproduction: Color(hex: "C59155")
        case .production: Color(hex: "5578C5")
        case .postproduction: Color(hex: "8664B8")
        case .review: Color(hex: "D17662")
        case .delivered: Color(hex: "55A782")
        }
    }
}

enum ProjectKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case commercial = "Commercial"
    case documentary = "Documentary"
    case event = "Event film"
    case social = "Social content"
    case music = "Music video"
    case photography = "Photography"
    case personal = "Personal"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .commercial: "film"
        case .documentary: "video"
        case .event: "calendar"
        case .social: "rectangle.portrait.on.rectangle.portrait"
        case .music: "music.note"
        case .photography: "camera"
        case .personal: "square.grid.2x2"
        }
    }

    var subtitle: String {
        switch self {
        case .commercial: "Brief, production and client delivery"
        case .documentary: "Research, story and field production"
        case .event: "Run of show, crew and fast delivery"
        case .social: "Campaign batches and platform versions"
        case .music: "Treatment, storyboard and performance"
        case .photography: "Shot list, selects and hand-off"
        case .personal: "A flexible blank production space"
        }
    }
}

enum ModoWorkType: String, Codable, CaseIterable, Identifiable, Hashable {
    case creativeProduction = "Creative production"
    case service = "Service project"
    case consulting = "Consulting"
    case event = "Event"
    case flexible = "Flexible"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .creativeProduction: "camera.viewfinder"
        case .service: "wrench.and.screwdriver"
        case .consulting: "person.text.rectangle"
        case .event: "calendar.badge.clock"
        case .flexible: "square.grid.2x2"
        }
    }

    var subtitle: String {
        switch self {
        case .creativeProduction: "Brief, production, media and delivery"
        case .service: "Scope, tasks, appointments, files and time"
        case .consulting: "Notes, deliverables, meetings and time"
        case .event: "Schedule, people, locations and checklists"
        case .flexible: "A neutral workspace you shape yourself"
        }
    }

    var defaultSections: [ProjectSection] {
        switch self {
        case .creativeProduction:
            return ProjectSection.defaultEnabled
        case .service:
            return [.overview, .tasks, .brief, .schedule, .crew, .files, .delivery, .time]
        case .consulting:
            return [.overview, .tasks, .brief, .script, .schedule, .files, .delivery, .time]
        case .event:
            return [.overview, .tasks, .brief, .schedule, .crew, .kit, .files, .delivery, .time]
        case .flexible:
            return [.overview, .tasks, .brief, .schedule, .files, .time]
        }
    }

    static func inferred(from kind: ProjectKind?) -> ModoWorkType {
        guard let kind else { return .flexible }
        switch kind {
        case .commercial, .documentary, .social, .music, .photography:
            return .creativeProduction
        case .event:
            return .event
        case .personal:
            return .flexible
        }
    }
}

enum ProjectSection: String, Codable, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case tasks = "Tasks"
    case brief = "Brief"
    case script = "Script"
    case storyboard = "Storyboard"
    case shots = "Shot list"
    case schedule = "Schedule"
    case crew = "Crew"
    case kit = "Kit list"
    case files = "Files"
    case delivery = "Delivery"
    case time = "Time log"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .crew: return "People"
        case .kit: return "Kit"
        case .time: return "Time"
        default: return rawValue
        }
    }
    var icon: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .tasks: "checklist"
        case .brief: "doc.text"
        case .script: "text.alignleft"
        case .storyboard: "rectangle.grid.3x2"
        case .shots: "camera.viewfinder"
        case .schedule: "calendar"
        case .crew: "person.2"
        case .kit: "shippingbox"
        case .files: "folder"
        case .delivery: "paperplane"
        case .time: "timer"
        }
    }

    static let defaultEnabled: [ProjectSection] = [
        .overview, .tasks, .brief, .script, .storyboard, .shots, .schedule, .crew, .kit, .files, .delivery, .time
    ]
}

enum InterfacePalette: String, Codable, CaseIterable, Identifiable, Hashable {
    case neutral = "Neutral"
    case graphite = "Graphite"
    case paper = "Paper"
    case warm = "Warm"
    case vibrant = "Vibrant"
    var id: String { rawValue }
}


enum PluginTarget: String, Codable, CaseIterable, Identifiable, Hashable {
    case project = "Project"
    case linkedFile = "Linked file"
    case task = "Task"
    case shot = "Shot"
    case storyboard = "Storyboard"
    case delivery = "Delivery"

    var id: String { rawValue }
}

enum PluginPermission: String, Codable, CaseIterable, Identifiable, Hashable {
    case projectData = "Project data"
    case linkedFiles = "Linked files"
    case externalVolumes = "External volumes"
    case network = "Network"
    case backgroundProcess = "Background process"
    case notifications = "Notifications"

    var id: String { rawValue }
}

struct PluginActionManifest: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var targets: [PluginTarget]
    var supportedExtensions: [String]? = nil
    var shortcut: String? = nil
    var destructive: Bool? = nil

    func supports(target: PluginTarget, fileExtension: String?) -> Bool {
        guard targets.contains(target) else { return false }
        guard let supportedExtensions, !supportedExtensions.isEmpty else { return true }
        guard let fileExtension else { return false }
        return supportedExtensions.contains { $0.caseInsensitiveCompare(fileExtension) == .orderedSame }
    }
}

struct FramoPluginManifest: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var version: String
    var author: String
    var summary: String
    var license: String
    var minimumFramoVersion: String? = nil
    var permissions: [PluginPermission]
    var actions: [PluginActionManifest]
    var executable: String? = nil
    var sourceURL: String? = nil
    var homepageURL: String? = nil
    var builtInAdapter: Bool? = nil

    var isBuiltInAdapter: Bool { builtInAdapter ?? false }
}

struct RegisteredPluginAction: Identifiable, Hashable {
    var plugin: FramoPluginManifest
    var action: PluginActionManifest
    var id: String { "\(plugin.id)::\(action.id)" }
}

struct PluginInvocationContext: Codable, Hashable {
    var target: PluginTarget
    var projectID: UUID? = nil
    var projectTitle: String? = nil
    var linkedFileID: UUID? = nil
    var taskID: UUID? = nil
    var paths: [String] = []
    var fileNames: [String] = []
}

enum SyncthingMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case existing = "Existing Syncthing"
    case managed = "Managed by MODO"
    var id: String { rawValue }
}

struct SyncthingDevice: Identifiable, Codable, Hashable {
    var id: String { deviceID }
    var deviceID: String
    var name: String
    var connected: Bool
    var paused: Bool
    var address: String
}

struct SyncthingFolder: Identifiable, Codable, Hashable {
    var id: String
    var label: String
    var path: String
    var paused: Bool
    var deviceIDs: [String]
}

struct SyncthingFolderStatus: Codable, Hashable {
    var state: String
    var globalBytes: Int64
    var inSyncBytes: Int64
    var needBytes: Int64
    var needFiles: Int

    var progress: Double {
        guard globalBytes > 0 else { return needBytes == 0 ? 1 : 0 }
        return min(max(Double(inSyncBytes) / Double(globalBytes), 0), 1)
    }
}

struct StudioProject: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var client: String
    var description: String
    var status: ProjectStatus
    var startDate: Date
    var dueDate: Date
    var location: String
    var colorHex: String
    var coverSymbol: String
    var kind: ProjectKind? = nil
    // MODO work type controls the default depth of the project without removing
    // the production-specific tools that make creative work powerful.
    var workType: ModoWorkType? = nil
    var bannerPath: String? = nil
    var editingSoftware: String
    var aspectRatio: String
    var resolution: String
    var frameRate: String
    var brief: String
    var script: String
    var deliverable: String
    var favorite: Bool
    var createdAt: Date
    var shots: [Shot]
    var crew: [CrewMember]
    var kit: [KitItem]
    var storyboard: [StoryboardCard]
    var timeEntries: [TimeEntry]

    var hourlyRate: Double? = nil
    var fixedFee: Double? = nil

    // Business-core links. Optional so existing production workspaces migrate cleanly.
    var customerID: UUID? = nil
    var opportunityID: UUID? = nil
    var originatingQuoteID: UUID? = nil
    var scopeSnapshot: String? = nil
    var budgetAmount: Double? = nil
    // MODO 0.37 work-depth fields. Optional for backwards-compatible decoding.
    var ownerName: String? = nil
    var nextAction: String? = nil
    var milestones: [ModoMilestone]? = nil

    var enabledSections: [ProjectSection]? = nil
    var clientContacts: [ClientContact]? = nil
    var bannerAssetName: String? = nil
    var bannerHeight: Double? = nil
    var bannerFocusY: Double? = nil
    var frameIOURL: String? = nil
    var clientShareURL: String? = nil
    var briefDocumentURL: String? = nil
    var notionProjectURL: String? = nil
    var driveFolderURL: String? = nil
    // Native Google connector identifiers. URLs remain mirrored into the generic
    // fields above so older MODO builds can still open the links.
    var googleDriveFolderID: String? = nil
    var googleDriveFolderURL: String? = nil
    var googleBriefDocumentID: String? = nil
    var googleBriefDocumentURL: String? = nil
    var googleBriefLastSyncedAt: Date? = nil
    var googleBriefLastSyncedHash: String? = nil
    var googleBriefRemoteModifiedAt: Date? = nil
    var googleBriefSyncStatus: String? = nil

    // Frame.io V4 linkage. IDs are stored independently from display URLs so
    // MODO never has to reverse-engineer Frame.io web URLs.
    var frameIOAccountID: String? = nil
    var frameIOWorkspaceID: String? = nil
    var frameIOProjectID: String? = nil
    var frameIORootFolderID: String? = nil
    var frameIOLastSyncedAt: Date? = nil
    var briefRTF: Data? = nil
    var scriptRTF: Data? = nil
    var linkedFiles: [LinkedProjectFile]? = nil
    var syncthingFolderPath: String? = nil
    var syncthingFolderBookmark: Data? = nil
    var syncthingFolderID: String? = nil
    var syncthingDeviceIDs: [String]? = nil

    var effectiveWorkType: ModoWorkType {
        workType ?? ModoWorkType.inferred(from: kind)
    }

    var effectiveSections: [ProjectSection] {
        let stored = enabledSections ?? effectiveWorkType.defaultSections
        return ProjectSection.allCases.filter { $0 == .overview || stored.contains($0) }
    }

    var effectiveBannerHeight: CGFloat { CGFloat(bannerHeight ?? 170) }
    var effectiveBannerFocusY: CGFloat { CGFloat(min(max(bannerFocusY ?? 0.5, 0), 1)) }
}

struct StudioSpace: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var subtitle: String
    var emoji: String
    var colorHex: String
    var bannerPath: String?
    var projectIDs: [UUID]
    var notes: String
    var bannerAssetName: String? = nil
    var bannerHeight: Double? = nil
    var bannerFocusY: Double? = nil

    var effectiveBannerHeight: CGFloat { CGFloat(bannerHeight ?? 210) }
    var effectiveBannerFocusY: CGFloat { CGFloat(min(max(bannerFocusY ?? 0.5, 0), 1)) }
}

struct ModoChecklistItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var isComplete: Bool = false
}

struct ModoTaskComment: Identifiable, Codable, Hashable {
    var id = UUID()
    var author: String
    var body: String
    var createdAt: Date = .now
}

struct ModoMilestone: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var dueDate: Date
    var isComplete: Bool = false
    var completedAt: Date? = nil
    var evidence: String = ""
    var notes: String = ""
}

struct StudioTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var dueDate: Date?
    var isComplete: Bool = false
    var projectID: UUID?
    var priority: Int = 1
    // Optional so older workspace JSON remains decodable.
    var assigneePersonID: UUID? = nil
    var checklist: [ModoChecklistItem]? = nil
    var dependencyIDs: [UUID]? = nil
    var comments: [ModoTaskComment]? = nil
    var createdAt: Date? = nil
    var completedAt: Date? = nil
}

struct StudioEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var endDate: Date
    var projectID: UUID?
    var location: String
    var colorHex: String
    /// Stable EventKit identifier when this MODO event is linked to Apple Calendar.
    /// Optional so older workspaces decode without a destructive migration.
    var appleEventIdentifier: String? = nil
}

struct Shot: Identifiable, Codable, Hashable {
    var id = UUID()
    var number: Int
    var title: String
    var description: String
    var shotSize: String
    var movement: String
    var lens: String
    var frameRate: String
    var duration: String
    var completed: Bool
}

struct StoryboardCard: Identifiable, Codable, Hashable {
    var id = UUID()
    var shotNumber: Int
    var title: String
    var notes: String
    var assetPath: String?
}


struct LinkedProjectFile: Identifiable, Codable, Hashable {
    var id = UUID()
    var displayName: String
    var bookmarkData: Data
    var originalPath: String
    var byteSize: Int64
    var volumeName: String
    var contentType: String
    var addedAt: Date = .now

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

struct ClientContact: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var company: String
    var email: String
    var phone: String
}

struct CrewMember: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var role: String
    var email: String
    var initials: String
    var phone: String? = nil
    var handle: String? = nil
    var photoPath: String? = nil
    var notes: String? = nil
}

struct KitItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var category: String
    var packed: Bool
    var quantity: Int
    var photoPath: String? = nil
    var serialNumber: String? = nil
    var lentToCrewID: UUID? = nil
    var dueBack: Date? = nil
    var notes: String? = nil
}

struct StudioPlace: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var notes: String
    var latitude: Double
    var longitude: Double
    var photoPaths: [String] = []
    var projectIDs: [UUID] = []
    var contactName: String? = nil
    var contactEmail: String? = nil
    var createdAt: Date = .now
}

struct TimeEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var seconds: TimeInterval
    var billable: Bool
}

enum FramoLanguage: String, Codable, CaseIterable, Identifiable, Hashable {
    case english = "English"
    case dutch = "Nederlands"
    case french = "Français"
    case german = "Deutsch"
    case spanish = "Español"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .dutch: "nl-BE"
        case .french: "fr-BE"
        case .german: "de"
        case .spanish: "es"
        }
    }

    var shortCode: String {
        switch self {
        case .english: "EN"
        case .dutch: "NL"
        case .french: "FR"
        case .german: "DE"
        case .spanish: "ES"
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Hashable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct FramoSemanticVersion: Comparable, Hashable, CustomStringConvertible {
    let components: [Int]

    init(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? raw
        let parsed = cleaned.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        components = parsed.isEmpty ? [0] : parsed
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: FramoSemanticVersion, rhs: FramoSemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum FramoUpdateChannel: String, Codable, CaseIterable, Identifiable {
    case stable = "Stable"
    case beta = "Beta"
    var id: String { rawValue }
}

enum FramoFeature: String, CaseIterable, Identifiable {
    case placesWorkspace
    case resourceHub
    case sharingHub
    case updateCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .placesWorkspace: "Places & Maps"
        case .resourceHub: "Crew & Devices"
        case .sharingHub: "MODO Connect"
        case .updateCenter: "Update Center"
        }
    }

    var summary: String {
        switch self {
        case .placesWorkspace: "Saved production locations, project linking and map tools."
        case .resourceHub: "Workspace-wide crew and device management."
        case .sharingHub: "Nearby Mac-to-Mac transfer and private remote connections over Tor."
        case .updateCenter: "Release checks, changelog and version-gated features."
        }
    }

    var minimumVersion: String {
        switch self {
        case .sharingHub: "0.26.0"
        case .placesWorkspace, .resourceHub, .updateCenter: "0.22.0"
        }
    }
}

struct FramoReleaseNote: Identifiable, Hashable {
    let version: String
    let build: String
    let date: String
    let title: String
    let highlights: [String]

    var id: String { version + "-" + build }
}

enum FramoReleaseCatalog {
    static let releases: [FramoReleaseNote] = [
        FramoReleaseNote(
            version: "0.38.0",
            build: "380",
            date: "12 Oct 2026",
            title: "One system — adaptive work, trust & brand",
            highlights: [
                "Made enabled modules a workspace-wide rule across Today, navigation, commands, notifications and MCP instead of a sidebar-only preference.",
                "Made MODO modes reshape Today around production, business, finance or a three-item Focus view, and introduced adaptive work types for creative production, service, consulting, events and flexible work.",
                "Connected Brand assets to quote and invoice PDFs plus native delivery exports, and tightened the quote → work → invoice path.",
                "Hardened workspace access with PBKDF2 password derivation and legacy migration, made MCP read-only by default, and separated workspace reset from a true local factory reset.",
                "Moved experimental or unfinished extensions behind explicit disclosure, hid unfinished Remote Connect in release builds and consolidated the duplicate customer UI source."
            ]
        ),
        FramoReleaseNote(
            version: "0.37.0",
            build: "370",
            date: "12 Oct 2026",
            title: "Work, relationships & trust",
            highlights: [
                "Rebuilt the project experience around Work: customer, origin quote, owner, next action, budget, dates, milestones and progress are visible before production-specific tools.",
                "Added richer task assignments, dependencies, checklists and comments plus first-class project milestones and cleaner schedule, people, kit, storyboard, shot, delivery and time workspaces.",
                "Simplified project files into a calm default browser while preserving advanced local, nearby, remote, Syncthing and Frame.io sources behind progressive disclosure.",
                "Added a practical customer CSV import flow with mapping, dry-run counts, duplicate review and activity logging, plus a System Health settings surface for storage, backup, sync, connectors and MCP.",
                "Removed the obsolete project-page implementation so the source now reflects the new MODO Work design instead of compiling two generations of UI side by side."
            ]
        ),
        FramoReleaseNote(
            version: "0.36.0",
            build: "360",
            date: "12 Oct 2026",
            title: "Business core — from workspace to operating system",
            highlights: [
                "Reframed Home as Today and added first-class Customers, Sales, Work and Money areas around the inquiry-to-paid journey.",
                "Added organizations, people, opportunities, versioned quotes, payments and activity records with explicit relationships to projects and invoices.",
                "Added quote revision, PDF export, acceptance-to-project conversion, invoice creation, immutable issue snapshots and payment recording.",
                "Expanded CloudKit entity sync and MCP around business records while keeping consequential financial actions out of the initial MCP write surface.",
                "Made MODO Modes meaningful by changing visible modules and role-relevant Today metrics instead of acting as cosmetic presets."
            ]
        ),
        FramoReleaseNote(
            version: "0.35.8",
            build: "358",
            date: "12 Oct 2026",
            title: "Free-first finance, Apple polish & faster MODO Time",
            highlights: [
                "Rebuilt Home project cards as compact immersive cover cards with better hierarchy, hover motion and no awkward nested shelf geometry.",
                "Made MODO Time substantially smaller and added spring, fade, hover, pulse and notch-panel animations across the timer experience.",
                "Made Peppol recipient lookup and Peppol BIS XML export free without an Access Point account; MODO adds no e-invoicing surcharge.",
                "Replaced the Storecove-specific prototype with optional Peppyrus one-click transport and surfaces the provider's published free-plan limits instead of hiding them.",
                "Polished global button interaction with native-feeling press feedback and consistent continuous-corner control geometry."
            ]
        ),
        FramoReleaseNote(
            version: "0.35.6",
            build: "356",
            date: "12 Oct 2026",
            title: "MODO modes, onboarding recovery & Peppol",
            highlights: [
                "Fixed the onboarding security step so validation never traps the user behind a silently disabled Continue button.",
                "Added Photoshop-style MODO workspace modes that reshape navigation and Home around Studio, Production, Business, Finance or Focus work.",
                "Added a Finance workspace with invoice drafting and real Peppol sending through Storecove, a certified Peppol Access Point provider.",
                "Added Belgian Peppol participant validation for scheme 0208/BE:EN and transparent compliance messaging that MODO itself is not an Access Point.",
                "Completed the visible MODO rebrand in the macOS bundle name and menu commands while retaining legacy internal identifiers for migration safety."
            ]
        ),
        FramoReleaseNote(
            version: "0.35.3",
            build: "353",
            date: "11 Oct 2026",
            title: "MODO — sharing, connectors & instant actions",
            highlights: [
                "Rebranded the product to MODO — Your business. Your way. while retaining legacy storage/API identifiers where migration compatibility requires them.",
                "Added cross-account CloudKit workspace sharing with owner invitations, share links and shared-database sync for projects, tasks, events, Spaces and Places.",
                "Google Drive now has an in-app folder/document browser plus incremental Drive change tracking for linked Creative Brief documents.",
                "Frame.io V4 is now a live OAuth Native App/PKCE connector with account, workspace and project discovery plus per-project linking.",
                "Added MODO-native MCP names, connector resources and deterministic quick commands for creating projects/tasks, starting timers and syncing without adding AI inside MODO."
            ]
        ),
        FramoReleaseNote(
            version: "0.34.0",
            build: "34",
            date: "10 Oct 2026",
            title: "Entity sync, Google connector & MCP",
            highlights: [
                "Added real Google Drive + Docs OAuth with PKCE, project folders and two-way Creative Brief text sync.",
                "Added CloudKit entity sync for projects, tasks and calendar events with per-entity conflict tracking and offline-first local storage.",
                "Added a loopback-only MCP server exposing MODO resources and safe project/task/calendar/time tools to compatible AI clients.",
                "Added the MODO Notch Timer: a top-center hover HUD on notched Macs with a menu-bar fallback elsewhere.",
                "Replaced connector placeholders with live status, connect/disconnect actions, sync controls and copyable MCP configuration."
            ]
        ),
        FramoReleaseNote(
            version: "0.33.0",
            build: "33",
            date: "10 Oct 2026",
            title: "Cloud & connector foundation",
            highlights: [
                "Fixed project/sidebar layout drift and replaced automatic branded project covers with clean color-driven artwork.",
                "Added an open connector store surface for Drive, Docs, Frame.io, Notion, Dropbox, OneDrive, Slack and native Apple services.",
                "Added project link fields for a creative-brief document, Notion project hub and Drive folder.",
                "First-run onboarding now appears once per launch and includes MODO's open-source initiative."
            ]
        ),
        FramoReleaseNote(
            version: "0.32.0",
            build: "32",
            date: "10 Oct 2026",
            title: "Project workflow refinement",
            highlights: [
                "Made Home overview metrics actionable, aligned Home controls, refined project cards and tightened Project Pulse spacing.",
                "Reworked project writing, storyboard, schedule, people, kit and delivery surfaces so editable areas are unmistakable and line-heavy layouts are gone.",
                "Polished project task filters, limited completed-task clutter with an archive, clarified Calendar controls and added breathing room between adjacent events.",
                "Redesigned crew-add dialogs, stabilized the Places inspector layout, unified Settings into one visual tone and simplified the top account switcher.",
                "New workspaces now require an app password and supported Macs can unlock protected workspaces with Touch ID."
            ]
        ),
        FramoReleaseNote(
            version: "0.31.0",
            build: "31",
            date: "9 Oct 2026",
            title: "Workspace profiles & interaction polish",
            highlights: [
                "Added startup workspace switching, optional password locks, inactivity auto-lock and portable workspaces that can live on removable drives.",
                "Rebuilt the Time launcher around fast project switching and project creation, while removing the broken floating timer dock.",
                "Calendar items now open a proper inspector and support deterministic automatic colors plus quick manual color changes.",
                "Apple Contacts can be imported into Crew, notification controls now live in Settings, and the notification panel is more compact.",
                "Removed decorative emoji UI, refined project strokes, flattened Settings and Extensions controls, and fixed several layout artifacting issues."
            ]
        ),
        FramoReleaseNote(
            version: "0.30.0",
            build: "30",
            date: "9 Oct 2026",
            title: "Interface polish",
            highlights: [
                "Redesigned Home and Search around calmer, flatter layouts with fewer borders, boxes and decorative icons.",
                "Calendar week view now stays a real timeline with sidebars open, overlapping events share horizontal lanes, and event colors are selectable when planning.",
                "Crew and Devices now use responsive grids, project navigation uses native menus, and dropdowns no longer fight custom hover overlays.",
                "Project symbols are consistently monochrome and dark-mode aware, while notifications and floating map surfaces follow the active appearance.",
                "Long-form writing gained a cleaner document toolbar with text styles, lists, quotes, code, richer formatting and a less boxed-in canvas."
            ]
        ),
        FramoReleaseNote(
            version: "0.29.0",
            build: "29",
            date: "9 Oct 2026",
            title: "Reliability & open-source hardening",
            highlights: [
                "Removed the obsolete duplicate FramoAI interface layer; MODO remains intentionally local-first and non-AI.",
                "Workspace loading now distinguishes first launch from corruption, preserves failed databases, and can recover from the previous valid snapshot.",
                "Project, space and storyboard image pickers now copy selected images into MODO-managed storage so Downloads/Desktop originals can be removed safely.",
                "Apple Calendar push now updates previously linked events instead of creating duplicates on every sync.",
                "Managed media is mirrored into configured backups, connection secrets move to macOS Keychain, and stale project relationships are repaired automatically."
            ]
        ),
        FramoReleaseNote(
            version: "0.28.0",
            build: "28",
            date: "29 Sep 2026",
            title: "Usability overhaul",
            highlights: [
                "Simplified MODO Connect into clear Nearby and Remote flows with guided Tor setup and readable permission diagnostics.",
                "Places is map-first again: smaller saved-place UI, no separate photo gallery, and saved-place photos appear directly on map pins.",
                "Crew is now grouped by person with an assignment dialog for choosing exactly which projects each person works on.",
                "Place, crew and device photos are copied into MODO-managed storage so they remain available after the original picker permission ends.",
                "Settings, Workspace data controls, Extensions and Version pages were simplified; in-app update checking is no longer part of the normal UI."
            ]
        ),
        FramoReleaseNote(
            version: "0.26.0",
            build: "26",
            date: "28 Sep 2026",
            title: "MODO Connect",
            highlights: [
                "MODO Connect combines nearby Mac-to-Mac transfer and remote device access in one workspace.",
                "Remote Connect can expose the local MODO Host as a Tor v3 Onion Service without a MODO cloud server.",
                "Connection invites carry an onion address plus a workspace access token and can be copied between trusted Macs.",
                "Remote workspace snapshots can be pulled over Tor while keeping the receiving Mac's local MODO settings.",
                "Tor can be bundled with MODO or selected from a local Homebrew/manual installation."
            ]
        ),
        FramoReleaseNote(
            version: "0.22.0",
            build: "22",
            date: "28 Sep 2026",
            title: "Maps, resources and update control",
            highlights: [
                "Reworked Places & Maps workspace with saved locations and project links.",
                "Crew & Devices hub with fast add flows and sidebar hover statistics.",
                "Update Center, changelog, release channels and version-gated features.",
                "Privacy & Legal area with local Terms, Privacy and third-party notices.",
                "Collapsed sharing control now uses the bundled sharepoint.svg artwork."
            ]
        ),
        FramoReleaseNote(
            version: "0.21.0",
            build: "21",
            date: "27 Sep 2026",
            title: "Sharing and production workspace",
            highlights: [
                "Local sharing and hosted workspace controls.",
                "Production-focused sidebar and project navigation.",
                "Starter workspace and skippable feature introductions."
            ]
        ),
        FramoReleaseNote(
            version: "0.20.0",
            build: "20",
            date: "26 Sep 2026",
            title: "MODO foundation",
            highlights: [
                "Unified projects, tasks, calendar, crew, kit and delivery workspace.",
                "Local-first database with optional backups and plug-ins."
            ]
        )
    ]

    static var latestBundled: FramoReleaseNote { releases[0] }
}

struct FramoRemoteRelease: Codable, Identifiable, Hashable {
    let version: String
    let build: String?
    let title: String?
    let notes: [String]?
    let downloadURL: String?
    let publishedAt: String?

    var id: String { version + "-" + (build ?? "") }
}

enum FramoUpdateStatus: Equatable {
    case idle
    case checking
    case current
    case updateAvailable(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready to check"
        case .checking: "Checking…"
        case .current: "MODO is up to date"
        case .updateAvailable(let version): "MODO \(version) is available"
        case .failed(let message): message
        }
    }
}

enum ModoInvoiceStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case draft = "Draft"
    case ready = "Ready"
    case sending = "Sending"
    case issued = "Issued"
    case sent = "Sent"
    case partlyPaid = "Partly paid"
    case paid = "Paid"
    case overdue = "Overdue"
    case voided = "Voided"
    case credited = "Credited"
    case failed = "Failed"
    var id: String { rawValue }
}

struct ModoInvoiceLine: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var quantity: Double = 1
    var unitPrice: Double = 0
    var vatRate: Double = 21

    var subtotal: Double { quantity * unitPrice }
    var vatAmount: Double { subtotal * vatRate / 100 }
    var total: Double { subtotal + vatAmount }
}

struct ModoInvoice: Identifiable, Codable, Hashable {
    var id = UUID()
    var invoiceNumber: String
    var projectID: UUID? = nil
    var customerID: UUID? = nil
    var quoteID: UUID? = nil
    var issueDate: Date = .now
    var dueDate: Date = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    var customerName: String = ""
    var customerEmail: String = ""
    var customerStreet: String = ""
    var customerZip: String = ""
    var customerCity: String = ""
    var customerCountryCode: String = "BE"
    var customerPeppolScheme: String = "BE:EN"
    var customerPeppolID: String = ""
    var currency: String = "EUR"
    var lines: [ModoInvoiceLine] = [ModoInvoiceLine()]
    var notes: String = ""
    var status: ModoInvoiceStatus = .draft
    var issuedAt: Date? = nil
    var issuedSnapshot: Data? = nil
    var submissionGUID: String? = nil
    var lastTransmissionMessage: String? = nil
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var subtotal: Double { lines.reduce(0) { $0 + $1.subtotal } }
    var vatTotal: Double { lines.reduce(0) { $0 + $1.vatAmount } }
    var total: Double { lines.reduce(0) { $0 + $1.total } }

    var canSendViaPeppol: Bool {
        !invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !customerPeppolID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lines.isEmpty && lines.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.quantity > 0 }
    }
}

// MARK: - MODO business core

enum ModoOpportunityStage: String, Codable, CaseIterable, Identifiable, Hashable {
    case new = "New"
    case qualified = "Qualified"
    case proposal = "Proposal"
    case won = "Won"
    case lost = "Lost"
    var id: String { rawValue }
}

enum ModoQuoteStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case draft = "Draft"
    case sent = "Sent"
    case accepted = "Accepted"
    case declined = "Declined"
    case expired = "Expired"
    var id: String { rawValue }
}

enum ModoActivitySource: String, Codable, CaseIterable, Identifiable, Hashable {
    case app = "App"
    case importData = "Import"
    case automation = "Rule"
    case api = "API"
    case mcp = "MCP"
    var id: String { rawValue }
}

enum ModoActivityKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case created = "Created"
    case updated = "Updated"
    case statusChanged = "Status changed"
    case note = "Note"
    case quoteAccepted = "Quote accepted"
    case projectCreated = "Project created"
    case invoiceCreated = "Invoice created"
    case invoiceIssued = "Invoice issued"
    case paymentRecorded = "Payment recorded"
    var id: String { rawValue }
}

struct ModoOrganization: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var email: String = ""
    var phone: String = ""
    var website: String = ""
    var vatNumber: String = ""
    var peppolID: String = ""
    var street: String = ""
    var postalCode: String = ""
    var city: String = ""
    var countryCode: String = "BE"
    var notes: String = ""
    var tags: [String] = []
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

struct ModoPerson: Identifiable, Codable, Hashable {
    var id = UUID()
    var organizationIDs: [UUID] = []
    var name: String
    var role: String = ""
    var email: String = ""
    var phone: String = ""
    var notes: String = ""
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

struct ModoOpportunity: Identifiable, Codable, Hashable {
    var id = UUID()
    var customerID: UUID? = nil
    var title: String
    var stage: ModoOpportunityStage = .new
    var expectedValue: Double = 0
    var currency: String = "EUR"
    var owner: String = ""
    var workType: ModoWorkType? = nil
    var source: String = ""
    var nextAction: String = ""
    var nextActionDate: Date? = nil
    var closeReason: String = ""
    var notes: String = ""
    var acceptedQuoteID: UUID? = nil
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

struct ModoQuoteLine: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var description: String = ""
    var quantity: Double = 1
    var unitPrice: Double = 0
    var taxRate: Double = 21

    var subtotal: Double { quantity * unitPrice }
    var taxAmount: Double { subtotal * taxRate / 100 }
    var total: Double { subtotal + taxAmount }
}

struct ModoQuote: Identifiable, Codable, Hashable {
    var id = UUID()
    var quoteNumber: String
    var revision: Int = 1
    var customerID: UUID? = nil
    var opportunityID: UUID? = nil
    var projectID: UUID? = nil
    var issueDate: Date = .now
    var validUntil: Date = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    var status: ModoQuoteStatus = .draft
    var currency: String = "EUR"
    var lines: [ModoQuoteLine] = [ModoQuoteLine()]
    var terms: String = ""
    var notes: String = ""
    var acceptedAt: Date? = nil
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var subtotal: Double { lines.reduce(0) { $0 + $1.subtotal } }
    var taxTotal: Double { lines.reduce(0) { $0 + $1.taxAmount } }
    var total: Double { lines.reduce(0) { $0 + $1.total } }
}

struct ModoPayment: Identifiable, Codable, Hashable {
    var id = UUID()
    var invoiceID: UUID
    var amount: Double
    var date: Date = .now
    var method: String = "Bank transfer"
    var reference: String = ""
    var notes: String = ""
    var createdAt: Date = .now
}

struct ModoActivityEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date = .now
    var actor: String = ""
    var source: ModoActivitySource = .app
    var kind: ModoActivityKind
    var summary: String
    var recordType: String
    var recordID: UUID
    var relatedRecordIDs: [UUID] = []
}

struct ModoBusinessState: Codable, Hashable {
    var organizations: [ModoOrganization] = []
    var people: [ModoPerson] = []
    var opportunities: [ModoOpportunity] = []
    var quotes: [ModoQuote] = []
    var payments: [ModoPayment] = []
    var activities: [ModoActivityEntry] = []
}


enum ModoBrandAssetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case logo = "Logo"
    case icon = "Icon"
    case mark = "Brand mark"
    case image = "Image"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .logo: "rectangle.3.group"
        case .icon: "app"
        case .mark: "seal"
        case .image: "photo"
        }
    }
}

struct ModoBrandAsset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: ModoBrandAssetKind
    var path: String
    var createdAt: Date = .now
}

struct StudioSettings: Codable {
    var ownerName = ""
    var studioName = "MODO Studio"
    var defaultRate: Double = 65
    var currency = "EUR"
    var businessType: String? = nil
    var businessCity: String? = nil
    var businessCountryCode: String? = nil
    var timeZoneIdentifier: String? = nil
    var notchTimerEnabled: Bool? = nil
    var dockTimerBadgeEnabled: Bool? = nil
    var appearance: AppAppearance = .system
    var language: FramoLanguage? = nil
    var autoBackupEnabled: Bool? = nil
    var backupFolderBookmark: Data? = nil
    var backupFolderPath: String? = nil
    var autoBackupIntervalMinutes: Int? = nil
    var autoBackupKeepCount: Int? = nil
    var pinnedProjectIDs: [UUID]? = nil
    var lastBackupDate: Date? = nil
    var onboardingVersion: Int? = nil
    var workspaceMode: ModoWorkspaceMode? = nil

    // Onboarding-selected modules. Home, Search and Settings are always available.
    var enabledDestinations: [SidebarDestination]? = nil

    // Workspace brand library. Files are copied into MODO Managed Media.
    var brandAssets: [ModoBrandAsset]? = nil
    var primaryBrandLogoID: UUID? = nil
    var primaryBrandIconID: UUID? = nil
    var brandPrimaryHex: String? = nil
    var brandSecondaryHex: String? = nil

    var automaticUpdateChecks: Bool? = nil
    var updateChannel: FramoUpdateChannel? = nil
    var lastUpdateCheck: Date? = nil
    var dismissedUpdateVersion: String? = nil

    var pinnedPages: [SidebarDestination]? = nil
    var interfaceScale: Double? = nil
    var palette: InterfacePalette? = nil
    var highContrast: Bool? = nil
    var grayscaleEmoji: Bool? = nil
    var accentHex: String? = nil
    var defaultProjectSections: [ProjectSection]? = nil
    var fixedProjectTabIDs: [UUID]? = nil
    var sidebarProjectIDs: [UUID]? = nil
    var sidebarShowsProjectPages: Bool? = nil
    var localTransferEnabled: Bool? = nil

    var hostSharingEnabled: Bool? = nil
    var hostPort: Int? = nil
    // Legacy decode-only fields; migrated to macOS Keychain on load.
    var hostAccessToken: String? = nil
    var hostShareWorkspace: Bool? = nil
    var hostShareLinkedFiles: Bool? = nil
    var remoteHostAddress: String? = nil
    var remoteHostPort: Int? = nil
    var remoteHostToken: String? = nil

    var framoConnectRemoteEnabled: Bool? = nil
    var framoConnectAutoStart: Bool? = nil
    var framoConnectTorExecutableBookmark: Data? = nil
    var framoConnectTorExecutablePath: String? = nil
    var framoConnectSocksPort: Int? = nil

    var installedPluginIDs: [String]? = nil
    var disabledPluginIDs: [String]? = nil
    var syncthingBaseURL: String? = nil
    var syncthingMode: SyncthingMode? = nil
    var syncthingAutoStart: Bool? = nil
    var syncthingExecutableBookmark: Data? = nil
    var syncthingExecutablePath: String? = nil

    // Cloud + connector settings. OAuth refresh/access tokens and MCP secrets are
    // deliberately kept in Keychain, not in the workspace JSON.
    var googleOAuthClientID: String? = nil
    var frameIOOAuthClientID: String? = nil
    var frameIOOAuthScopes: String? = nil
    var cloudSyncEnabled: Bool? = nil
    var cloudAutoSyncEnabled: Bool? = nil
    // When populated, this workspace syncs against another iCloud user's
    // CloudKit shared database instead of the owner's private database.
    var cloudSharedZoneName: String? = nil
    var cloudSharedZoneOwnerName: String? = nil
    var cloudShareURL: String? = nil
    var cloudSharePermission: String? = nil
    var mcpEnabled: Bool? = nil
    var mcpPort: Int? = nil
    // MCP is read-only by default. Explicit opt-in is required for mutations.
    var mcpAllowWrites: Bool? = nil

    // Peppol. MODO never adds a transmission surcharge. API credentials live in
    // Keychain; workspace JSON only keeps non-secret business/setup metadata.
    // peppolLegalEntityID is kept for backwards decoding from the Storecove prototype.
    var peppolLegalEntityID: Int? = nil
    var peppolBusinessIBAN: String? = nil
    var peppolSenderParticipantID: String? = nil
    var peppolBusinessVAT: String? = nil
    var peppolBusinessStreet: String? = nil
    var peppolBusinessZip: String? = nil
    var peppolBusinessCity: String? = nil
    var peppolBusinessCountryCode: String? = nil
    var peppolUseTestEnvironment: Bool? = nil

    var effectiveLanguage: FramoLanguage { language ?? .english }
    var effectiveBusinessType: String { businessType?.isEmpty == false ? businessType! : "Service business" }
    var effectiveBusinessCountryCode: String { businessCountryCode?.isEmpty == false ? businessCountryCode! : "BE" }
    var effectiveTimeZoneIdentifier: String { timeZoneIdentifier?.isEmpty == false ? timeZoneIdentifier! : TimeZone.current.identifier }
    var effectiveWorkspaceMode: ModoWorkspaceMode { workspaceMode ?? .studio }

    var effectiveEnabledDestinations: Set<SidebarDestination> {
        var destinations = Set(enabledDestinations ?? SidebarDestination.allCases)
        destinations.insert(.home)
        destinations.insert(.search)
        destinations.insert(.settings)
        return destinations
    }

    /// The single source of truth for what MODO exposes. Onboarding modules and
    /// workspace modes both participate, so hiding Money/Sales/etc. is respected
    /// by Today, navigation, commands and automation rather than only the sidebar.
    var effectiveVisibleDestinations: Set<SidebarDestination> {
        var destinations = effectiveEnabledDestinations.intersection(effectiveWorkspaceMode.visibleDestinations)
        destinations.insert(.home)
        destinations.insert(.search)
        destinations.insert(.settings)
        return destinations
    }

    func isModuleEnabled(_ destination: SidebarDestination) -> Bool {
        effectiveEnabledDestinations.contains(destination)
    }

    func isDestinationEnabled(_ destination: SidebarDestination) -> Bool {
        effectiveVisibleDestinations.contains(destination)
    }

    var effectiveBrandAssets: [ModoBrandAsset] { brandAssets ?? [] }
    var effectiveBrandPrimaryHex: String { brandPrimaryHex?.isEmpty == false ? brandPrimaryHex! : "111111" }
    var effectiveBrandSecondaryHex: String { brandSecondaryHex?.isEmpty == false ? brandSecondaryHex! : "E9E9E6" }

    var effectiveAutomaticUpdateChecks: Bool { automaticUpdateChecks ?? true }
    var effectiveUpdateChannel: FramoUpdateChannel { updateChannel ?? .stable }
    var effectiveScale: Double { min(max(interfaceScale ?? 1.0, 0.85), 1.20) }
    var effectiveAutoBackupIntervalMinutes: Int { min(max(autoBackupIntervalMinutes ?? 30, 2), 120) }
    var effectiveAutoBackupKeepCount: Int { min(max(autoBackupKeepCount ?? 12, 3), 60) }
    var effectivePalette: InterfacePalette { palette ?? .neutral }
    var effectiveHighContrast: Bool { highContrast ?? false }
    var effectiveGrayscaleEmoji: Bool { true }
    var effectiveAccentHex: String { accentHex ?? "6B6B68" }
    var effectiveDefaultSections: [ProjectSection] { defaultProjectSections ?? ProjectSection.defaultEnabled }
    var effectiveNotchTimerEnabled: Bool { notchTimerEnabled ?? true }
    var effectiveDockTimerBadgeEnabled: Bool { dockTimerBadgeEnabled ?? true }
    var effectiveCloudSyncEnabled: Bool { cloudSyncEnabled ?? false }
    var effectiveCloudAutoSyncEnabled: Bool { cloudAutoSyncEnabled ?? true }
    var effectiveFrameIOOAuthScopes: String {
        let configured = frameIOOAuthScopes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? "openid,email,profile" : configured
    }
    var hasSharedCloudWorkspace: Bool {
        !(cloudSharedZoneName?.isEmpty ?? true) && !(cloudSharedZoneOwnerName?.isEmpty ?? true)
    }
    var effectiveMCPEnabled: Bool { mcpEnabled ?? false }
    var effectiveMCPAllowWrites: Bool { mcpAllowWrites ?? false }
    var effectiveMCPPort: Int { min(max(mcpPort ?? 7346, 1024), 65535) }
    var effectiveSidebarShowsProjectPages: Bool { sidebarShowsProjectPages ?? true }
    var effectiveLocalTransferEnabled: Bool { localTransferEnabled ?? false }
    var effectiveHostSharingEnabled: Bool { hostSharingEnabled ?? false }
    var effectiveHostPort: Int { min(max(hostPort ?? 45888, 1024), 65535) }
    var effectiveHostShareWorkspace: Bool { hostShareWorkspace ?? true }
    var effectiveHostShareLinkedFiles: Bool { hostShareLinkedFiles ?? true }
    var effectiveRemoteHostPort: Int { min(max(remoteHostPort ?? 45888, 1), 65535) }
    var effectiveFramoConnectRemoteEnabled: Bool { framoConnectRemoteEnabled ?? false }
    var effectiveFramoConnectAutoStart: Bool { framoConnectAutoStart ?? true }
    var effectiveFramoConnectSocksPort: Int { min(max(framoConnectSocksPort ?? 19050, 1024), 65535) }
    var effectiveInstalledPluginIDs: [String] { installedPluginIDs ?? [] }
    var effectiveDisabledPluginIDs: [String] { disabledPluginIDs ?? [] }
    var effectiveSyncthingBaseURL: String { syncthingBaseURL ?? "http://127.0.0.1:8384" }
    var effectiveSyncthingMode: SyncthingMode { syncthingMode ?? .existing }
    var effectiveSyncthingAutoStart: Bool { syncthingAutoStart ?? false }
}

enum FramoProfileStorageKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case local = "On this Mac"
    case portable = "Portable folder"
    var id: String { rawValue }
}


struct ModoRecoveryKit: Identifiable, Hashable {
    let id = UUID()
    let workspaceName: String
    let backupCodes: [String]
    let authenticatorSecret: String

    var authenticatorURL: String {
        let label = "MODO:\(workspaceName)"
        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "MODO"
        let encodedIssuer = "MODO".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "MODO"
        return "otpauth://totp/\(encodedLabel)?secret=\(authenticatorSecret)&issuer=\(encodedIssuer)&digits=6&period=30"
    }
}

struct FramoWorkspaceProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt: Date = .now
    var storageKind: FramoProfileStorageKind = .local
    /// Nil keeps the first/legacy profile at the historical Application Support root.
    var localFolderName: String? = nil
    var externalPath: String? = nil
    var externalBookmark: Data? = nil
    var passwordSaltHex: String? = nil
    var passwordDigestHex: String? = nil
    // Nil means a legacy pre-PBKDF2 profile and is migrated after the next
    // successful password unlock.
    var passwordKDF: String? = nil
    var passwordIterations: Int? = nil
    var recoveryCodeDigests: [String]? = nil
    var autoLockMinutes: Int? = nil

    var isPasswordProtected: Bool {
        guard let digest = passwordDigestHex else { return false }
        return !digest.isEmpty
    }

    var hasRecoveryCodes: Bool {
        !(recoveryCodeDigests ?? []).isEmpty
    }

    var effectiveAutoLockMinutes: Int {
        let value = autoLockMinutes ?? 15
        return max(0, min(value, 240))
    }
}

struct StudioDatabase: Codable {
    /// Increment only when a migration changes persisted semantics.
    var schemaVersion: Int? = 4
    var projects: [StudioProject]
    var tasks: [StudioTask]
    var events: [StudioEvent]
    var settings: StudioSettings
    var spaces: [StudioSpace]? = nil
    var places: [StudioPlace]? = nil
    var invoices: [ModoInvoice]? = nil
    var business: ModoBusinessState? = nil
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            opacity: 1
        )
    }
}

enum FramoNotificationKind: String, Codable { case task, event, information }

struct FramoNotificationItem: Identifiable, Codable {
    var id: String
    var kind: FramoNotificationKind
    var title: String
    var date: Date
    var detail: String?
    var taskID: UUID?
    var eventID: UUID?
    var projectID: UUID?
    var isRead = false
    var isDismissed = false
}

struct FramoNotificationState: Codable {
    var items: [FramoNotificationItem] = []
    var tasksEnabled = true
    var eventsEnabled = true
    var messagesEnabled = true
}
