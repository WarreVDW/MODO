import Foundation
import AppKit
import Network
import Security

@MainActor
final class FramoMCPServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(Int)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running(let port): return "Running on 127.0.0.1:\(port)"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var requestCount = 0

    private weak var store: FramoStudioStore?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "be.bywarre.framo.mcp", qos: .userInitiated)

    func install(store: FramoStudioStore) { self.store = store }

    var endpointURL: String {
        let port = store?.settings.effectiveMCPPort ?? 7346
        return "http://127.0.0.1:\(port)/mcp"
    }

    var accessToken: String {
        guard let profileID = store?.activeProfileID else { return "" }
        if let existing = FramoV5Keychain.readMCPToken(profileID: profileID), !existing.isEmpty { return existing }
        let token = Self.randomToken()
        FramoV5Keychain.saveMCPToken(token, profileID: profileID)
        return token
    }

    func start() {
        guard listener == nil, let store, !store.profileGatePresented else { return }
        let portValue = store.settings.effectiveMCPPort
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            state = .failed("Invalid MCP port")
            return
        }
        state = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handle(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self else { return }
                    switch newState {
                    case .ready: self.state = .running(portValue)
                    case .failed(let error): self.state = .failed(error.localizedDescription); self.stop()
                    case .cancelled: self.state = .stopped
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    func restart() { stop(); start() }

    func rotateAccessToken() {
        guard let profileID = store?.activeProfileID else { return }
        FramoV5Keychain.clearMCPToken(profileID: profileID)
        _ = accessToken
        if store?.settings.effectiveMCPEnabled == true { restart() }
    }

    func copyConfigToPasteboard() {
        let token = accessToken
        let config: [String: Any] = [
            "mcpServers": [
                "modo": [
                    "type": "streamable-http",
                    "url": endpointURL,
                    "headers": ["Authorization": "Bearer \(token)"]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                if let error {
                    self.sendHTTP(
                        status: 400,
                        body: self.errorObject(id: NSNull(), code: -32700, message: error.localizedDescription),
                        on: connection
                    )
                    return
                }
                if let request = self.parseHTTPRequest(buffer) {
                    self.requestCount += 1
                    let response = await self.route(request)
                    self.sendHTTP(status: response.status, body: response.body, on: connection, extraHeaders: response.headers)
                } else if isComplete {
                    self.sendHTTP(
                        status: 400,
                        body: self.errorObject(id: NSNull(), code: -32700, message: "Invalid HTTP/MCP request"),
                        on: connection
                    )
                } else {
                    self.receiveRequest(on: connection, accumulated: buffer)
                }
            }
        }
    }

    private struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private struct MCPHTTPResponse {
        var status: Int
        var body: Any
        var headers: [String: String] = [:]
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let marker = "\r\n\r\n".data(using: .utf8),
              let range = data.range(of: marker),
              let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    private func route(_ request: HTTPRequest) async -> MCPHTTPResponse {
        guard request.path == "/mcp" || request.path == "/mcp/" else {
            return MCPHTTPResponse(status: 404, body: ["error": "Not found"])
        }
        guard request.method == "POST" else {
            return MCPHTTPResponse(status: 405, body: ["error": "MODO MCP accepts POST /mcp"])
        }
        let host = (request.headers["host"] ?? "").lowercased()
        guard host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:") || host == "127.0.0.1" || host == "localhost" else {
            return MCPHTTPResponse(status: 403, body: ["error": "MODO MCP is loopback-only"])
        }
        if let origin = request.headers["origin"], !origin.isEmpty {
            let lower = origin.lowercased()
            guard lower.hasPrefix("http://127.0.0.1") || lower.hasPrefix("http://localhost") else {
                return MCPHTTPResponse(status: 403, body: ["error": "Origin not allowed"])
            }
        }
        let expected = accessToken
        guard request.headers["authorization"] == "Bearer \(expected)" else {
            return MCPHTTPResponse(status: 401, body: ["error": "Missing or invalid MODO MCP token"], headers: ["WWW-Authenticate": "Bearer"])
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = object["method"] as? String else {
            return MCPHTTPResponse(status: 400, body: errorObject(id: NSNull(), code: -32700, message: "Invalid JSON-RPC request"))
        }
        let id = object["id"] ?? NSNull()
        let params = object["params"] as? [String: Any] ?? [:]

        if request.headers["mcp-protocol-version"] == "2026-07-28" {
            guard request.headers["mcp-method"] == method else {
                return MCPHTTPResponse(status: 400, body: errorObject(id: id, code: -32600, message: "Mcp-Method header does not match the JSON-RPC method"))
            }
            if ["tools/call", "resources/read", "prompts/get"].contains(method) {
                let expectedName = (params["name"] as? String) ?? (params["uri"] as? String)
                if let expectedName, request.headers["mcp-name"] != expectedName {
                    return MCPHTTPResponse(status: 400, body: errorObject(id: id, code: -32600, message: "Mcp-Name header does not match the request"))
                }
            }
        }

        switch method {
        case "server/discover":
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: modernDiscoverResult()))
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]
            let negotiated = requested.flatMap { supported.contains($0) ? $0 : nil } ?? "2025-11-25"
            let result: [String: Any] = [
                "protocolVersion": negotiated,
                "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                "serverInfo": ["name": "MODO", "version": FramoStudioStore.appVersion],
                "instructions": store?.settings.effectiveMCPAllowWrites == true ? "MODO exposes the active unlocked workspace. Explicit write access is enabled; mutating tools write directly to the local workspace." : "MODO exposes the active unlocked workspace in read-only mode. Enable MCP write access explicitly in MODO Settings before mutating tools are exposed."
            ]
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: result))
        case "notifications/initialized":
            return MCPHTTPResponse(status: 202, body: [:])
        case "ping":
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: [:]))
        case "tools/list":
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: ["tools": tools(), "ttlMs": 60_000, "cacheScope": "private"]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return MCPHTTPResponse(status: 200, body: errorObject(id: id, code: -32602, message: "Missing tool name"))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = callTool(name: name, arguments: arguments)
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: result))
        case "resources/list":
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: ["resources": resources(), "ttlMs": 15_000, "cacheScope": "private"]))
        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return MCPHTTPResponse(status: 200, body: errorObject(id: id, code: -32602, message: "Missing resource URI"))
            }
            guard let content = readResource(uri) else {
                return MCPHTTPResponse(status: 200, body: errorObject(id: id, code: -32602, message: "Resource not found"))
            }
            return MCPHTTPResponse(status: 200, body: resultObject(id: id, result: ["contents": [content], "ttlMs": 5_000, "cacheScope": "private"]))
        default:
            return MCPHTTPResponse(status: 200, body: errorObject(id: id, code: -32601, message: "Method not found"))
        }
    }

    private func modernDiscoverResult() -> [String: Any] {
        [
            "protocolVersions": ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"],
            "capabilities": ["tools": [:], "resources": [:]],
            "instructions": store?.settings.effectiveMCPAllowWrites == true ? "MODO is a local-first business workspace. Read and safe workspace mutation tools are available for enabled modules. Consequential financial actions such as issuing invoices or recording payments remain unavailable." : "MODO is a local-first business workspace. This MCP endpoint is read-only by default; only resources and read tools for enabled modules are exposed.",
            "ttlMs": 60_000,
            "cacheScope": "private",
            "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "MODO", "version": FramoStudioStore.appVersion]]
        ]
    }

    private func tools() -> [[String: Any]] {
        func schema(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var result: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            if !required.isEmpty { result["required"] = required }
            return result
        }
        let string: [String: Any] = ["type": "string"]
        var items: [[String: Any]] = [
            tool("modo_search", "Search MODO", "Search customers, quotes, work, tasks, invoices, events and places.", schema(["query": string], required: ["query"])),
            tool("modo_list_customers", "List customers", "List customer organizations in the active workspace.", schema()),
            tool("modo_get_customer", "Get customer", "Read a customer and its linked record counts by UUID.", schema(["customer_id": string], required: ["customer_id"])),
            tool("modo_list_open_quotes", "List open quotes", "List quote drafts and sent quotes that still need a decision.", schema()),
            tool("modo_create_quote_draft", "Create quote draft", "Create a draft quote for an existing customer. This does not send or issue anything.", schema(["customer_id": string], required: ["customer_id"])),
            tool("modo_get_invoice", "Get invoice", "Read one invoice by UUID without issuing, sending or modifying it.", schema(["invoice_id": string], required: ["invoice_id"])),
            tool("modo_get_activity", "Get activity timeline", "Read the activity timeline related to one MODO record UUID.", schema(["record_id": string], required: ["record_id"])),
            tool("modo_list_projects", "List projects", "List projects in the active MODO workspace.", schema()),
            tool("modo_get_project", "Get project", "Read one MODO project by UUID.", schema(["project_id": string], required: ["project_id"])),
            tool("modo_create_project", "Create project", "Create a MODO project.", schema(["title": string, "client": string], required: ["title"])),
            tool("modo_update_project", "Update project", "Update common project fields.", schema(["project_id": string, "title": string, "client": string, "description": string, "status": string, "due_date": string], required: ["project_id"])),
            tool("modo_list_tasks", "List tasks", "List tasks; optionally filter by project UUID.", schema(["project_id": string])),
            tool("modo_create_task", "Create task", "Create a task with optional project and ISO-8601 due date.", schema(["title": string, "project_id": string, "due_date": string], required: ["title"])),
            tool("modo_complete_task", "Complete task", "Mark a task complete or open.", schema(["task_id": string, "complete": ["type": "boolean"]], required: ["task_id"])),
            tool("modo_list_events", "List calendar events", "List MODO calendar events.", schema()),
            tool("modo_create_event", "Create calendar event", "Create a MODO event using ISO-8601 start/end timestamps.", schema(["title": string, "start": string, "end": string, "project_id": string, "location": string], required: ["title", "start"])),
            tool("modo_get_timer", "Get active timer", "Read the current MODO time-tracking state.", schema()),
            tool("modo_start_timer", "Start timer", "Start or switch time tracking to a project.", schema(["project_id": string], required: ["project_id"])),
            tool("modo_pause_timer", "Pause timer", "Pause the current timer and commit the running segment.", schema()),
            tool("modo_stop_timer", "Stop timer", "Stop time tracking.", schema()),
            tool("modo_add_time_entry", "Add time entry", "Add a manual time entry to a project.", schema(["project_id": string, "title": string, "seconds": ["type": "number"], "date": string, "billable": ["type": "boolean"]], required: ["project_id", "seconds"])),
            tool("modo_list_places", "List places", "List saved MODO places.", schema()),
            tool("modo_create_place", "Create place", "Create a saved production place.", schema(["name": string, "address": string, "latitude": ["type": "number"], "longitude": ["type": "number"], "notes": string], required: ["name"])),
            tool("modo_update_place", "Update place", "Update a saved production place.", schema(["place_id": string, "name": string, "address": string, "latitude": ["type": "number"], "longitude": ["type": "number"], "notes": string], required: ["place_id"])),
            tool("modo_list_people", "List people", "List crew/client people derived from projects.", schema()),
            tool("modo_add_crew_member", "Add crew member", "Add a person to a project crew.", schema(["project_id": string, "name": string, "role": string, "email": string, "phone": string], required: ["project_id", "name"])),
            tool("modo_update_crew_member", "Update crew member", "Update a crew member inside a project.", schema(["project_id": string, "member_id": string, "name": string, "role": string, "email": string, "phone": string], required: ["project_id", "member_id"])),
            tool("modo_list_linked_files", "List linked files", "List linked production files without exposing bookmark credentials or file contents.", schema(["project_id": string]))
        ]

        if let store {
            items.removeAll { item in
                guard let name = item["name"] as? String else { return true }
                return !toolIsVisible(name, store: store)
            }
            if !store.settings.effectiveMCPAllowWrites {
                items.removeAll { item in
                    guard let name = item["name"] as? String else { return false }
                    return isMutatingTool(name)
                }
            }
        } else {
            items.removeAll { item in
                guard let name = item["name"] as? String else { return false }
                return isMutatingTool(name)
            }
        }

        return items
    }

    private func isMutatingTool(_ name: String) -> Bool {
        let canonical = name.hasPrefix("modo_") ? String(name.dropFirst("modo_".count)) : name
        return [
            "create_quote_draft", "create_project", "update_project",
            "create_task", "complete_task", "create_event",
            "start_timer", "pause_timer", "stop_timer", "add_time_entry",
            "create_place", "update_place", "add_crew_member", "update_crew_member"
        ].contains(canonical)
    }

    private func toolIsVisible(_ name: String, store: FramoStudioStore) -> Bool {
        let canonical = name.hasPrefix("modo_") ? String(name.dropFirst("modo_".count)) : name
        switch canonical {
        case "search", "get_activity":
            return true
        case "list_customers", "get_customer":
            return store.isDestinationEnabled(.customers)
        case "list_open_quotes", "create_quote_draft":
            return store.isDestinationEnabled(.sales)
        case "get_invoice":
            return store.isDestinationEnabled(.finance)
        case "list_projects", "get_project", "create_project", "update_project",
             "get_timer", "start_timer", "pause_timer", "stop_timer", "add_time_entry",
             "list_linked_files":
            return store.isDestinationEnabled(.projects)
        case "list_tasks", "create_task", "complete_task":
            return store.isDestinationEnabled(.tasks)
        case "list_events", "create_event":
            return store.isDestinationEnabled(.calendar)
        case "list_places", "create_place", "update_place":
            return store.isDestinationEnabled(.places)
        case "list_people":
            return store.isDestinationEnabled(.resources) || store.isDestinationEnabled(.customers)
        case "add_crew_member", "update_crew_member":
            return store.isDestinationEnabled(.projects) && store.isDestinationEnabled(.resources)
        default:
            return true
        }
    }

    private func tool(_ name: String, _ title: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": inputSchema]
    }

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        guard let store, !store.profileGatePresented else { return toolError("MODO is locked") }
        let canonicalName = name.hasPrefix("modo_")
            ? "framo_" + String(name.dropFirst("modo_".count))
            : name

        let publicName = canonicalName.hasPrefix("framo_")
            ? "modo_" + String(canonicalName.dropFirst("framo_".count))
            : canonicalName
        guard toolIsVisible(publicName, store: store) else {
            return toolError("That MODO module is disabled in this workspace")
        }
        if isMutatingTool(publicName), !store.settings.effectiveMCPAllowWrites {
            return toolError("MODO MCP is read-only. Enable write access explicitly in Settings → Integrations.")
        }

        do {
            let structured: Any
            switch canonicalName {
            case "framo_search":
                let q = arguments["query"] as? String ?? ""
                structured = search(q, store: store)
            case "framo_list_customers":
                structured = ["customers": store.business.organizations.map { customerDictionary($0, store: store) }]
            case "framo_get_customer":
                let id = try uuid(arguments, "customer_id")
                guard let customer = store.business.organizations.first(where: { $0.id == id }) else { return toolError("Customer not found") }
                structured = ["customer": customerDictionary(customer, store: store)]
            case "framo_list_open_quotes":
                structured = ["quotes": store.business.quotes.filter { [.draft, .sent].contains($0.status) }.map { quoteDictionary($0, store: store) }]
            case "framo_create_quote_draft":
                let customerID = try uuid(arguments, "customer_id")
                guard store.business.organizations.contains(where: { $0.id == customerID }) else { return toolError("Customer not found") }
                let quoteID = store.createQuote(customerID: customerID)
                guard let quote = store.business.quotes.first(where: { $0.id == quoteID }) else { return toolError("Quote could not be created") }
                store.recordBusinessActivity(kind: .created, summary: "Quote draft created through MCP", recordType: "quote", recordID: quote.id, related: [customerID])
                structured = ["quote": quoteDictionary(quote, store: store)]
            case "framo_get_invoice":
                let id = try uuid(arguments, "invoice_id")
                guard let invoice = store.invoices.first(where: { $0.id == id }) else { return toolError("Invoice not found") }
                structured = ["invoice": invoiceDictionary(invoice, store: store)]
            case "framo_get_activity":
                let id = try uuid(arguments, "record_id")
                structured = ["activity": store.activities(for: id)
                    .filter { activityIsVisible($0, store: store) }
                    .map(activityDictionary)]
            case "framo_list_projects": structured = ["projects": store.projects.map(projectDictionary)]
            case "framo_get_project":
                let id = try uuid(arguments, "project_id")
                guard let project = store.projects.first(where: { $0.id == id }) else { return toolError("Project not found") }
                structured = ["project": projectDictionary(project)]
            case "framo_create_project":
                let title = try requiredString(arguments, "title")
                let client = arguments["client"] as? String ?? ""
                store.createProject(title: title, client: client)
                guard let id = store.selectedProjectID, let project = store.projects.first(where: { $0.id == id }) else { return toolError("Project could not be created") }
                structured = ["project": projectDictionary(project)]
            case "framo_update_project":
                let id = try uuid(arguments, "project_id")
                guard let index = store.projects.firstIndex(where: { $0.id == id }) else { return toolError("Project not found") }
                var project = store.projects[index]
                if let value = arguments["title"] as? String { project.title = value }
                if let value = arguments["client"] as? String { project.client = value }
                if let value = arguments["description"] as? String { project.description = value }
                if let value = arguments["status"] as? String, let status = ProjectStatus.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }) { project.status = status }
                if let value = arguments["due_date"] as? String, let date = Self.parseISO(value) { project.dueDate = date }
                store.updateProject(project)
                structured = ["project": projectDictionary(project)]
            case "framo_list_tasks":
                let projectID = (arguments["project_id"] as? String).flatMap(UUID.init(uuidString:))
                structured = ["tasks": store.tasks.filter { projectID == nil || $0.projectID == projectID }.map(taskDictionary)]
            case "framo_create_task":
                let title = try requiredString(arguments, "title")
                let projectID = (arguments["project_id"] as? String).flatMap(UUID.init(uuidString:))
                let due = (arguments["due_date"] as? String).flatMap(Self.parseISO)
                store.addTask(title: title, dueDate: due, projectID: projectID)
                guard let task = store.tasks.first else { return toolError("Task could not be created") }
                structured = ["task": taskDictionary(task)]
            case "framo_complete_task":
                let id = try uuid(arguments, "task_id")
                guard let index = store.tasks.firstIndex(where: { $0.id == id }) else { return toolError("Task not found") }
                store.tasks[index].isComplete = arguments["complete"] as? Bool ?? true
                structured = ["task": taskDictionary(store.tasks[index])]
            case "framo_list_events": structured = ["events": store.events.map(eventDictionary)]
            case "framo_create_event":
                let title = try requiredString(arguments, "title")
                guard let start = Self.parseISO(try requiredString(arguments, "start")) else { return toolError("Invalid start date; use ISO-8601") }
                let end = (arguments["end"] as? String).flatMap(Self.parseISO) ?? start.addingTimeInterval(3600)
                let projectID = (arguments["project_id"] as? String).flatMap(UUID.init(uuidString:))
                store.createEvent(title: title, start: start, end: end, projectID: projectID, location: arguments["location"] as? String ?? "")
                structured = ["event": store.events.last.map(eventDictionary) ?? [:]]
            case "framo_get_timer": structured = timerDictionary(store)
            case "framo_start_timer":
                let id = try uuid(arguments, "project_id"); store.startTimer(for: id); structured = timerDictionary(store)
            case "framo_pause_timer": store.pauseTimer(); structured = timerDictionary(store)
            case "framo_stop_timer": store.stopTimer(); structured = timerDictionary(store)
            case "framo_add_time_entry":
                let projectID = try uuid(arguments, "project_id")
                guard let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return toolError("Project not found") }
                let seconds = max(0, (arguments["seconds"] as? NSNumber)?.doubleValue ?? 0)
                guard seconds > 0 else { return toolError("seconds must be greater than zero") }
                let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let date = (arguments["date"] as? String).flatMap(Self.parseISO) ?? .now
                let billable = arguments["billable"] as? Bool ?? true
                let entry = TimeEntry(title: (title?.isEmpty == false ? title! : "Manual entry"), date: date, seconds: seconds, billable: billable)
                store.projects[index].timeEntries.insert(entry, at: 0)
                store.projectRefreshToken = UUID()
                structured = ["time_entry": timeEntryDictionary(entry), "project_id": projectID.uuidString]
            case "framo_list_places": structured = ["places": store.places.map(placeDictionary)]
            case "framo_create_place":
                let name = try requiredString(arguments, "name")
                let address = arguments["address"] as? String ?? ""
                let latitude = (arguments["latitude"] as? NSNumber)?.doubleValue ?? 50.8503
                let longitude = (arguments["longitude"] as? NSNumber)?.doubleValue ?? 4.3517
                let id = store.createPlace(name: name, address: address, latitude: latitude, longitude: longitude)
                if let idx = store.places.firstIndex(where: { $0.id == id }), let notes = arguments["notes"] as? String { store.places[idx].notes = notes }
                guard let place = store.places.first(where: { $0.id == id }) else { return toolError("Place could not be created") }
                structured = ["place": placeDictionary(place)]
            case "framo_update_place":
                let id = try uuid(arguments, "place_id")
                guard let index = store.places.firstIndex(where: { $0.id == id }) else { return toolError("Place not found") }
                var place = store.places[index]
                if let value = arguments["name"] as? String { place.name = value }
                if let value = arguments["address"] as? String { place.address = value }
                if let value = (arguments["latitude"] as? NSNumber)?.doubleValue { place.latitude = value }
                if let value = (arguments["longitude"] as? NSNumber)?.doubleValue { place.longitude = value }
                if let value = arguments["notes"] as? String { place.notes = value }
                store.updatePlace(place)
                structured = ["place": placeDictionary(place)]
            case "framo_list_people": structured = ["people": people(store)]
            case "framo_add_crew_member":
                let projectID = try uuid(arguments, "project_id")
                let name = try requiredString(arguments, "name")
                let role = arguments["role"] as? String ?? "Crew"
                let email = arguments["email"] as? String ?? ""
                let phone = arguments["phone"] as? String ?? ""
                guard let memberID = store.addCrewMember(to: projectID, name: name, role: role, email: email, phone: phone),
                      let project = store.projects.first(where: { $0.id == projectID }),
                      let member = project.crew.first(where: { $0.id == memberID }) else { return toolError("Crew member could not be added") }
                structured = ["person": crewDictionary(member, projectID: projectID)]
            case "framo_update_crew_member":
                let projectID = try uuid(arguments, "project_id")
                let memberID = try uuid(arguments, "member_id")
                guard let projectIndex = store.projects.firstIndex(where: { $0.id == projectID }),
                      let memberIndex = store.projects[projectIndex].crew.firstIndex(where: { $0.id == memberID }) else { return toolError("Crew member not found") }
                var member = store.projects[projectIndex].crew[memberIndex]
                if let value = arguments["name"] as? String { member.name = value; member.initials = Self.initials(value) }
                if let value = arguments["role"] as? String { member.role = value }
                if let value = arguments["email"] as? String { member.email = value }
                if let value = arguments["phone"] as? String { member.phone = value.isEmpty ? nil : value }
                store.projects[projectIndex].crew[memberIndex] = member
                store.projectRefreshToken = UUID()
                structured = ["person": crewDictionary(member, projectID: projectID)]
            case "framo_list_linked_files":
                let projectID = (arguments["project_id"] as? String).flatMap(UUID.init(uuidString:))
                let projects = store.projects.filter { projectID == nil || $0.id == projectID }
                structured = ["files": projects.flatMap { project in (project.linkedFiles ?? []).map { linkedFileDictionary($0, projectID: project.id) } }]
            default: return toolError("Unknown tool: \(name)")
            }
            return toolSuccess(structured)
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func resources() -> [[String: Any]] {
        guard let store else { return [] }
        var result: [[String: Any]] = [["uri": "modo://workspace", "name": "MODO Workspace", "description": "Active workspace summary", "mimeType": "application/json"]]

        if store.isDestinationEnabled(.customers) {
            result += store.business.organizations.map { ["uri": "modo://customers/\($0.id.uuidString)", "name": $0.name, "description": $0.email, "mimeType": "application/json"] }
        }
        if store.isDestinationEnabled(.projects) {
            result += store.projects.map { ["uri": "modo://projects/\($0.id.uuidString)", "name": $0.title, "description": $0.client, "mimeType": "application/json"] }
        }
        if store.isDestinationEnabled(.tasks) {
            result.append(["uri": "modo://tasks", "name": "MODO Tasks", "description": "Workspace tasks", "mimeType": "application/json"])
        }
        if store.isDestinationEnabled(.calendar) {
            result.append(["uri": "modo://calendar", "name": "MODO Calendar", "description": "Workspace calendar events", "mimeType": "application/json"])
        }
        if store.isDestinationEnabled(.finance) {
            result.append(["uri": "modo://invoices", "name": "MODO Invoices", "description": "Invoice summaries", "mimeType": "application/json"])
        }
        result.append(["uri": "modo://connectors", "name": "MODO Connectors", "description": "Connector and cloud status", "mimeType": "application/json"])
        return result
    }

    private func readResource(_ uri: String) -> [String: Any]? {
        guard let store, !store.profileGatePresented else { return nil }
        let normalizedURI = uri.replacingOccurrences(of: "framo://", with: "modo://")
        let value: Any
        if normalizedURI == "modo://workspace" {
            var summary: [String: Any] = ["name": store.activeProfileName, "mode": store.settings.effectiveWorkspaceMode.rawValue]
            if store.isDestinationEnabled(.customers) { summary["customers"] = store.business.organizations.count }
            if store.isDestinationEnabled(.sales) { summary["open_quotes"] = store.business.quotes.filter { [.draft, .sent].contains($0.status) }.count }
            if store.isDestinationEnabled(.projects) {
                summary["projects"] = store.projects.count
                summary["timer"] = timerDictionary(store)
            }
            if store.isDestinationEnabled(.tasks) { summary["tasks"] = store.tasks.count }
            if store.isDestinationEnabled(.finance) { summary["invoices"] = store.invoices.count }
            if store.isDestinationEnabled(.calendar) { summary["events"] = store.events.count }
            value = summary
        } else if normalizedURI.hasPrefix("modo://customers/"), store.isDestinationEnabled(.customers), let id = UUID(uuidString: String(normalizedURI.dropFirst("modo://customers/".count))), let customer = store.business.organizations.first(where: { $0.id == id }) {
            value = ["customer": customerDictionary(customer, store: store)]
        } else if normalizedURI == "modo://invoices", store.isDestinationEnabled(.finance) {
            value = ["invoices": store.invoices.map { invoiceDictionary($0, store: store) }]
        } else if normalizedURI == "modo://tasks", store.isDestinationEnabled(.tasks) {
            value = ["tasks": store.tasks.map(taskDictionary)]
        } else if normalizedURI == "modo://calendar", store.isDestinationEnabled(.calendar) {
            value = ["events": store.events.map(eventDictionary)]
        } else if normalizedURI == "modo://connectors" {
            value = [
                "google": store.googleConnector.state.label,
                "frameio": store.frameIOConnector.state.label,
                "cloud": store.cloudSync.state.label,
                "sharing": store.cloudSync.sharingStatus
            ]
        } else if normalizedURI.hasPrefix("modo://projects/"), store.isDestinationEnabled(.projects), let id = UUID(uuidString: String(normalizedURI.dropFirst("modo://projects/".count))), let project = store.projects.first(where: { $0.id == id }) {
            value = ["project": projectDictionary(project)]
        } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return nil }
        return ["uri": normalizedURI, "mimeType": "application/json", "text": text]
    }

    private func search(_ query: String, store: FramoStudioStore) -> [String: Any] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ["customers": [], "quotes": [], "projects": [], "tasks": [], "invoices": [], "events": [], "places": []] }
        let customers = store.isDestinationEnabled(.customers) ? store.business.organizations.filter { [$0.name, $0.email, $0.phone, $0.city, $0.vatNumber, $0.notes].joined(separator: " ").localizedCaseInsensitiveContains(q) } : []
        let quotes = store.isDestinationEnabled(.sales) ? store.business.quotes.filter { [$0.quoteNumber, $0.status.rawValue, store.customerName(id: $0.customerID)].joined(separator: " ").localizedCaseInsensitiveContains(q) || $0.lines.contains { $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) } } : []
        let projects = store.isDestinationEnabled(.projects) ? store.projects.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.client.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) } : []
        let tasks = store.isDestinationEnabled(.tasks) ? store.tasks.filter { $0.title.localizedCaseInsensitiveContains(q) } : []
        let invoices = store.isDestinationEnabled(.finance) ? store.invoices.filter { [$0.invoiceNumber, $0.customerName, $0.notes].joined(separator: " ").localizedCaseInsensitiveContains(q) } : []
        let events = store.isDestinationEnabled(.calendar) ? store.events.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.location.localizedCaseInsensitiveContains(q) } : []
        let places = store.isDestinationEnabled(.places) ? store.places.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q) || $0.notes.localizedCaseInsensitiveContains(q) } : []
        return ["customers": customers.map { customerDictionary($0, store: store) }, "quotes": quotes.map { quoteDictionary($0, store: store) }, "projects": projects.map(projectDictionary), "tasks": tasks.map(taskDictionary), "invoices": invoices.map { invoiceDictionary($0, store: store) }, "events": events.map(eventDictionary), "places": places.map(placeDictionary)]
    }

    private func customerDictionary(_ customer: ModoOrganization, store: FramoStudioStore) -> [String: Any] {
        [
            "id": customer.id.uuidString,
            "name": customer.name,
            "email": customer.email,
            "phone": customer.phone,
            "city": customer.city,
            "country_code": customer.countryCode,
            "vat_number": customer.vatNumber,
            "opportunities": store.isDestinationEnabled(.sales) ? store.business.opportunities.filter { $0.customerID == customer.id }.count : 0,
            "quotes": store.isDestinationEnabled(.sales) ? store.business.quotes.filter { $0.customerID == customer.id }.count : 0,
            "projects": store.isDestinationEnabled(.projects) ? store.projects.filter { $0.customerID == customer.id }.count : 0,
            "invoices": store.isDestinationEnabled(.finance) ? store.invoices.filter { $0.customerID == customer.id }.count : 0,
            "updated_at": Self.iso.string(from: customer.updatedAt)
        ]
    }
    private func quoteDictionary(_ quote: ModoQuote, store: FramoStudioStore) -> [String: Any] {
        [
            "id": quote.id.uuidString,
            "number": quote.quoteNumber,
            "revision": quote.revision,
            "customer_id": quote.customerID?.uuidString ?? "",
            "customer": store.customerName(id: quote.customerID),
            "status": quote.status.rawValue,
            "currency": quote.currency,
            "subtotal": quote.subtotal,
            "tax": quote.taxTotal,
            "total": quote.total,
            "valid_until": Self.iso.string(from: quote.validUntil),
            "updated_at": Self.iso.string(from: quote.updatedAt)
        ]
    }
    private func invoiceDictionary(_ invoice: ModoInvoice, store: FramoStudioStore) -> [String: Any] {
        let paid = store.business.payments.filter { $0.invoiceID == invoice.id }.reduce(0) { $0 + $1.amount }
        return [
            "id": invoice.id.uuidString,
            "number": invoice.invoiceNumber,
            "customer_id": invoice.customerID?.uuidString ?? "",
            "customer": invoice.customerName,
            "status": invoice.status.rawValue,
            "currency": invoice.currency,
            "total": invoice.total,
            "paid": paid,
            "outstanding": max(0, invoice.total - paid),
            "issue_date": Self.iso.string(from: invoice.issueDate),
            "due_date": Self.iso.string(from: invoice.dueDate)
        ]
    }
    private func activityIsVisible(_ activity: ModoActivityEntry, store: FramoStudioStore) -> Bool {
        switch activity.recordType.lowercased() {
        case "customer", "organization", "person", "contact":
            return store.isDestinationEnabled(.customers)
        case "opportunity", "quote":
            return store.isDestinationEnabled(.sales)
        case "project", "work", "time", "file":
            return store.isDestinationEnabled(.projects)
        case "task":
            return store.isDestinationEnabled(.tasks)
        case "event", "calendar":
            return store.isDestinationEnabled(.calendar)
        case "place", "location":
            return store.isDestinationEnabled(.places)
        case "invoice", "payment":
            return store.isDestinationEnabled(.finance)
        default:
            return true
        }
    }

    private func activityDictionary(_ activity: ModoActivityEntry) -> [String: Any] {
        [
            "id": activity.id.uuidString,
            "date": Self.iso.string(from: activity.date),
            "actor": activity.actor,
            "source": activity.source.rawValue,
            "kind": activity.kind.rawValue,
            "summary": activity.summary,
            "record_type": activity.recordType,
            "record_id": activity.recordID.uuidString,
            "related_record_ids": activity.relatedRecordIDs.map(\.uuidString)
        ]
    }

    private func projectDictionary(_ p: StudioProject) -> [String: Any] {
        ["id": p.id.uuidString, "title": p.title, "client": p.client, "description": p.description, "status": p.status.rawValue, "start_date": Self.iso.string(from: p.startDate), "due_date": Self.iso.string(from: p.dueDate), "location": p.location, "brief": p.brief, "deliverable": p.deliverable]
    }
    private func taskDictionary(_ t: StudioTask) -> [String: Any] {
        var out: [String: Any] = ["id": t.id.uuidString, "title": t.title, "complete": t.isComplete, "priority": t.priority]
        if let projectID = t.projectID { out["project_id"] = projectID.uuidString }
        if let due = t.dueDate { out["due_date"] = Self.iso.string(from: due) }
        return out
    }
    private func eventDictionary(_ e: StudioEvent) -> [String: Any] {
        var out: [String: Any] = ["id": e.id.uuidString, "title": e.title, "start": Self.iso.string(from: e.date), "end": Self.iso.string(from: e.endDate), "location": e.location, "color": e.colorHex]
        if let projectID = e.projectID { out["project_id"] = projectID.uuidString }
        return out
    }
    private func placeDictionary(_ p: StudioPlace) -> [String: Any] {
        ["id": p.id.uuidString, "name": p.name, "address": p.address, "notes": p.notes, "latitude": p.latitude, "longitude": p.longitude, "project_ids": p.projectIDs.map(\.uuidString)]
    }
    private func crewDictionary(_ person: CrewMember, projectID: UUID) -> [String: Any] {
        ["id": person.id.uuidString, "project_id": projectID.uuidString, "name": person.name, "role": person.role, "email": person.email, "phone": person.phone ?? ""]
    }
    private func linkedFileDictionary(_ file: LinkedProjectFile, projectID: UUID) -> [String: Any] {
        ["id": file.id.uuidString, "project_id": projectID.uuidString, "name": file.displayName, "original_path": file.originalPath, "byte_size": file.byteSize, "volume": file.volumeName, "content_type": file.contentType, "added_at": Self.iso.string(from: file.addedAt)]
    }
    private func timeEntryDictionary(_ entry: TimeEntry) -> [String: Any] {
        ["id": entry.id.uuidString, "title": entry.title, "date": Self.iso.string(from: entry.date), "seconds": entry.seconds, "billable": entry.billable]
    }
    private func people(_ store: FramoStudioStore) -> [[String: Any]] {
        var seen = Set<String>(); var result: [[String: Any]] = []
        for project in store.projects {
            for person in project.crew {
                let key = person.email.isEmpty ? person.name.lowercased() : person.email.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(["id": person.id.uuidString, "name": person.name, "role": person.role, "email": person.email, "phone": person.phone ?? ""])
            }
        }
        return result
    }
    private func timerDictionary(_ store: FramoStudioStore) -> [String: Any] {
        guard let id = store.activeTimerProjectID else { return ["active": false] }
        return ["active": true, "running": store.activeTimerStartedAt != nil, "project_id": id.uuidString, "project": store.projects.first(where: { $0.id == id })?.title ?? "", "elapsed_seconds": Int(store.focusElapsedSeconds())]
    }

    private func toolSuccess(_ structured: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": false]
    }
    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "structuredContent": ["error": message], "isError": true]
    }

    private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError.invalidArgument(key) }
        return value
    }
    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let value = args[key] as? String, let id = UUID(uuidString: value) else { throw MCPError.invalidArgument(key) }
        return id
    }

    private func resultObject(id: Any, result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    private func errorObject(id: Any, code: Int, message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }

    private func sendHTTP(status: Int, body: Any, on connection: NWConnection, extraHeaders: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let statusText: String
        switch status { case 200: statusText = "OK"; case 202: statusText = "Accepted"; case 400: statusText = "Bad Request"; case 401: statusText = "Unauthorized"; case 403: statusText = "Forbidden"; case 404: statusText = "Not Found"; case 405: statusText = "Method Not Allowed"; default: statusText = "Error" }
        var header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        for (key, value) in extraHeaders { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var response = Data(header.utf8); response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let iso: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private static let isoBasic: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime]; return value
    }()
    private static func parseISO(_ value: String) -> Date? { iso.date(from: value) ?? isoBasic.date(from: value) }

    private static func initials(_ name: String) -> String {
        let result = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return result.isEmpty ? "?" : result
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = bytes.withUnsafeMutableBytes { buffer in guard let base = buffer.baseAddress else { return errSecAllocate }; return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    enum MCPError: LocalizedError {
        case invalidArgument(String)
        var errorDescription: String? { switch self { case .invalidArgument(let key): return "Invalid or missing argument: \(key)" } }
    }
}
