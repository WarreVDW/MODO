//
//  ModoCustomersView.swift
//  BywarreStudio
//
//  Created by WarreVdW on 12/10/2026.
//


import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Business-core store operations

@MainActor
extension FramoStudioStore {
    func possibleDuplicateCustomers(name: String, email: String = "", vatNumber: String = "", excluding id: UUID? = nil) -> [ModoOrganization] {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanVAT = vatNumber.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "").uppercased()
        guard !cleanName.isEmpty || !cleanEmail.isEmpty || !cleanVAT.isEmpty else { return [] }
        return business.organizations.filter { customer in
            guard customer.id != id else { return false }
            let sameName = !cleanName.isEmpty && customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cleanName
            let sameEmail = !cleanEmail.isEmpty && customer.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cleanEmail
            let sameVAT = !cleanVAT.isEmpty && customer.vatNumber.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "").uppercased() == cleanVAT
            return sameName || sameEmail || sameVAT
        }
    }

    @discardableResult
    func createCustomer(name: String) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let customer = ModoOrganization(name: clean)
        business.organizations.insert(customer, at: 0)
        recordBusinessActivity(kind: .created, summary: "Customer \(clean) created", recordType: "customer", recordID: customer.id)
        return customer.id
    }

    func updateCustomer(_ customer: ModoOrganization) {
        guard let index = business.organizations.firstIndex(where: { $0.id == customer.id }) else { return }
        var value = customer
        value.updatedAt = .now
        business.organizations[index] = value
        recordBusinessActivity(kind: .updated, summary: "Customer \(value.name) updated", recordType: "customer", recordID: value.id)
    }

    func deleteCustomer(_ id: UUID) {
        business.organizations.removeAll { $0.id == id }
        business.people.removeAll { $0.organizationIDs.contains(id) }
        for index in business.opportunities.indices where business.opportunities[index].customerID == id {
            business.opportunities[index].customerID = nil
        }
        for index in business.quotes.indices where business.quotes[index].customerID == id {
            business.quotes[index].customerID = nil
        }
        for index in projects.indices where projects[index].customerID == id {
            projects[index].customerID = nil
        }
        for index in invoices.indices where invoices[index].customerID == id {
            invoices[index].customerID = nil
        }
    }

    @discardableResult
    func createPerson(organizationID: UUID?, name: String, email: String = "", phone: String = "", role: String = "") -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let person = ModoPerson(organizationIDs: organizationID.map { [$0] } ?? [], name: clean, role: role, email: email, phone: phone)
        business.people.insert(person, at: 0)
        recordBusinessActivity(kind: .created, summary: "Contact \(clean) created", recordType: "person", recordID: person.id, related: organizationID.map { [$0] } ?? [])
        return person.id
    }

    func updatePerson(_ person: ModoPerson) {
        guard let index = business.people.firstIndex(where: { $0.id == person.id }) else { return }
        var value = person
        value.updatedAt = .now
        business.people[index] = value
        recordBusinessActivity(kind: .updated, summary: "Contact \(value.name) updated", recordType: "person", recordID: value.id, related: value.organizationIDs)
    }

    @discardableResult
    func createOpportunity(customerID: UUID?, title: String) -> UUID? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let opportunity = ModoOpportunity(customerID: customerID, title: clean, currency: settings.currency, owner: settings.ownerName)
        business.opportunities.insert(opportunity, at: 0)
        recordBusinessActivity(kind: .created, summary: "Opportunity \(clean) created", recordType: "opportunity", recordID: opportunity.id, related: customerID.map { [$0] } ?? [])
        return opportunity.id
    }

    func updateOpportunity(_ opportunity: ModoOpportunity) {
        guard let index = business.opportunities.firstIndex(where: { $0.id == opportunity.id }) else { return }
        let oldStage = business.opportunities[index].stage
        var value = opportunity
        value.updatedAt = .now
        business.opportunities[index] = value
        if oldStage != value.stage {
            recordBusinessActivity(kind: .statusChanged, summary: "Opportunity moved to \(value.stage.rawValue)", recordType: "opportunity", recordID: value.id, related: value.customerID.map { [$0] } ?? [])
        }
    }

    @discardableResult
    func createQuote(customerID: UUID?, opportunityID: UUID? = nil) -> UUID {
        let year = Calendar.current.component(.year, from: .now)
        let sequence = business.quotes.count + 1
        let quote = ModoQuote(
            quoteNumber: String(format: "Q-%d-%04d", year, sequence),
            customerID: customerID,
            opportunityID: opportunityID,
            currency: settings.currency
        )
        business.quotes.insert(quote, at: 0)
        recordBusinessActivity(kind: .created, summary: "Quote \(quote.quoteNumber) created", recordType: "quote", recordID: quote.id, related: [customerID, opportunityID].compactMap { $0 })
        return quote.id
    }

    func updateQuote(_ quote: ModoQuote) {
        guard let index = business.quotes.firstIndex(where: { $0.id == quote.id }) else { return }
        var value = quote
        value.updatedAt = .now
        business.quotes[index] = value
    }

    @discardableResult
    func createQuoteRevision(from id: UUID) -> UUID? {
        guard let original = business.quotes.first(where: { $0.id == id }) else { return nil }
        var revision = original
        revision.id = UUID()
        revision.revision += 1
        revision.status = .draft
        revision.acceptedAt = nil
        revision.projectID = nil
        revision.createdAt = .now
        revision.updatedAt = .now
        business.quotes.insert(revision, at: 0)
        recordBusinessActivity(kind: .created, summary: "Revision \(revision.revision) created for \(revision.quoteNumber)", recordType: "quote", recordID: revision.id, related: [original.id, original.customerID].compactMap { $0 })
        return revision.id
    }

    func exportQuotePDF(_ id: UUID) {
        guard let quote = business.quotes.first(where: { $0.id == id }) else { return }
        let customer = quote.customerID.flatMap { self.customer(id: $0) }
        let root = ModoQuotePrintView(
            quote: quote,
            customer: customer,
            businessName: settings.studioName,
            businessCity: settings.businessCity ?? "",
            businessCountryCode: settings.effectiveBusinessCountryCode
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 595, height: 842)
        hosting.layoutSubtreeIfNeeded()
        let data = hosting.dataWithPDF(inside: hosting.bounds)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(quote.quoteNumber)-r\(quote.revision).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            pluginNotice = "Quote PDF exported"
        } catch {
            pluginNotice = "Couldn’t export quote: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func acceptQuote(_ id: UUID) -> UUID? {
        guard let quoteIndex = business.quotes.firstIndex(where: { $0.id == id }) else { return nil }
        var quote = business.quotes[quoteIndex]
        quote.status = .accepted
        quote.acceptedAt = .now
        quote.updatedAt = .now

        if let opportunityID = quote.opportunityID,
           let opportunityIndex = business.opportunities.firstIndex(where: { $0.id == opportunityID }) {
            business.opportunities[opportunityIndex].stage = .won
            business.opportunities[opportunityIndex].acceptedQuoteID = quote.id
            business.opportunities[opportunityIndex].updatedAt = .now
        }

        let customer = quote.customerID.flatMap { customer(id: $0) }
        let projectTitle = business.opportunities.first(where: { $0.id == quote.opportunityID })?.title
            ?? customer?.name
            ?? "Accepted work"
        let projectID = createProject(title: projectTitle, client: customer?.name ?? "Customer", kind: .commercial, fixedFee: quote.subtotal)
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }

        projects[projectIndex].customerID = quote.customerID
        projects[projectIndex].opportunityID = quote.opportunityID
        projects[projectIndex].originatingQuoteID = quote.id
        projects[projectIndex].scopeSnapshot = quote.lines.map { "\($0.quantity.formatted()) × \($0.name)" }.joined(separator: "\n")
        projects[projectIndex].budgetAmount = quote.subtotal
        projects[projectIndex].fixedFee = quote.subtotal
        projects[projectIndex].status = .preproduction

        quote.projectID = projectID
        business.quotes[quoteIndex] = quote
        recordBusinessActivity(kind: .quoteAccepted, summary: "Quote \(quote.quoteNumber) accepted", recordType: "quote", recordID: quote.id, related: [quote.customerID, quote.opportunityID, projectID].compactMap { $0 })
        recordBusinessActivity(kind: .projectCreated, summary: "Work created from accepted quote", recordType: "project", recordID: projectID, related: [quote.id, quote.customerID].compactMap { $0 })
        return projectID
    }

    @discardableResult
    func createInvoiceFromQuote(_ quoteID: UUID) -> UUID? {
        guard let quote = business.quotes.first(where: { $0.id == quoteID }) else { return nil }
        let year = Calendar.current.component(.year, from: .now)
        let sequence = invoices.count + 1
        let customer = quote.customerID.flatMap { customer(id: $0) }
        let invoice = ModoInvoice(
            invoiceNumber: String(format: "%d-%04d", year, sequence),
            projectID: quote.projectID,
            customerID: quote.customerID,
            quoteID: quote.id,
            customerName: customer?.name ?? "",
            customerEmail: customer?.email ?? "",
            customerStreet: customer?.street ?? "",
            customerZip: customer?.postalCode ?? "",
            customerCity: customer?.city ?? "",
            customerCountryCode: customer?.countryCode ?? "BE",
            customerPeppolID: customer?.peppolID ?? "",
            currency: quote.currency,
            lines: quote.lines.map { ModoInvoiceLine(name: $0.name, quantity: $0.quantity, unitPrice: $0.unitPrice, vatRate: $0.taxRate) },
            notes: quote.notes
        )
        invoices.insert(invoice, at: 0)
        recordBusinessActivity(kind: .invoiceCreated, summary: "Invoice \(invoice.invoiceNumber) created from \(quote.quoteNumber)", recordType: "invoice", recordID: invoice.id, related: [quote.id, quote.customerID, quote.projectID].compactMap { $0 })
        return invoice.id
    }

    func issueInvoice(_ id: UUID) {
        guard let index = invoices.firstIndex(where: { $0.id == id }), invoices[index].status == .draft || invoices[index].status == .ready else { return }
        invoices[index].status = .issued
        invoices[index].issuedAt = .now
        invoices[index].updatedAt = .now
        invoices[index].issuedSnapshot = try? JSONEncoder().encode(invoices[index])
        recordBusinessActivity(kind: .invoiceIssued, summary: "Invoice \(invoices[index].invoiceNumber) issued", recordType: "invoice", recordID: id, related: [invoices[index].customerID, invoices[index].projectID, invoices[index].quoteID].compactMap { $0 })
    }

    func recordPayment(invoiceID: UUID, amount: Double, method: String = "Bank transfer", reference: String = "") {
        guard amount > 0, let invoiceIndex = invoices.firstIndex(where: { $0.id == invoiceID }) else { return }
        let payment = ModoPayment(invoiceID: invoiceID, amount: amount, method: method, reference: reference)
        business.payments.insert(payment, at: 0)
        let paid = business.payments.filter { $0.invoiceID == invoiceID }.reduce(0) { $0 + $1.amount }
        if paid + 0.005 >= invoices[invoiceIndex].total {
            invoices[invoiceIndex].status = .paid
        } else if paid > 0 {
            invoices[invoiceIndex].status = .partlyPaid
        }
        invoices[invoiceIndex].updatedAt = .now
        recordBusinessActivity(kind: .paymentRecorded, summary: "Payment recorded for \(invoices[invoiceIndex].invoiceNumber)", recordType: "payment", recordID: payment.id, related: [invoiceID, invoices[invoiceIndex].customerID].compactMap { $0 })
    }

    func customer(id: UUID) -> ModoOrganization? {
        business.organizations.first { $0.id == id }
    }

    func customerName(id: UUID?) -> String {
        guard let id else { return "No customer" }
        return customer(id: id)?.name ?? "Unknown customer"
    }

    func activities(for recordID: UUID) -> [ModoActivityEntry] {
        business.activities
            .filter { $0.recordID == recordID || $0.relatedRecordIDs.contains(recordID) }
            .sorted { $0.date > $1.date }
    }

    var outstandingInvoiceTotal: Double {
        invoices.filter { ![.paid, .voided, .credited].contains($0.status) }.reduce(0) { partial, invoice in
            let paid = business.payments.filter { $0.invoiceID == invoice.id }.reduce(0) { $0 + $1.amount }
            return partial + max(0, invoice.total - paid)
        }
    }

    var openQuoteTotal: Double {
        business.quotes.filter { [.draft, .sent].contains($0.status) }.reduce(0) { $0 + $1.total }
    }

    var opportunitiesNeedingFollowUp: [ModoOpportunity] {
        let endOfToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: .now) ?? .now
        return business.opportunities
            .filter { ![.won, .lost].contains($0.stage) && ($0.nextActionDate ?? .distantFuture) <= endOfToday }
            .sorted { ($0.nextActionDate ?? .distantFuture) < ($1.nextActionDate ?? .distantFuture) }
    }

    func recordBusinessActivity(kind: ModoActivityKind, summary: String, recordType: String, recordID: UUID, related: [UUID] = []) {
        business.activities.insert(
            ModoActivityEntry(
                actor: settings.ownerName.isEmpty ? "You" : settings.ownerName,
                source: .app,
                kind: kind,
                summary: summary,
                recordType: recordType,
                recordID: recordID,
                relatedRecordIDs: related
            ),
            at: 0
        )
        if business.activities.count > 5000 {
            business.activities.removeLast(business.activities.count - 5000)
        }
    }
}

// MARK: - Customers

struct ModoCustomersView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var showNewCustomer = false

    private var filtered: [ModoOrganization] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.business.organizations }
        return store.business.organizations.filter {
            [$0.name, $0.email, $0.phone, $0.city, $0.vatNumber, $0.notes].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            HSplitView {
                customerList
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 410)
                customerDetail
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showNewCustomer) {
            ModoCustomerEditor(customer: ModoOrganization(name: "")) { customer in
                if let id = store.createCustomer(name: customer.name), var created = store.customer(id: id) {
                    created.email = customer.email
                    created.phone = customer.phone
                    created.website = customer.website
                    created.vatNumber = customer.vatNumber
                    created.street = customer.street
                    created.postalCode = customer.postalCode
                    created.city = customer.city
                    created.countryCode = customer.countryCode
                    created.notes = customer.notes
                    store.updateCustomer(created)
                    selectedID = id
                }
            }
            .environmentObject(store)
        }
        .onAppear {
            if selectedID == nil { selectedID = filtered.first?.id }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customers").font(.system(size: 29, weight: .semibold))
                Text("Relationships, work, quotes and money in one record.")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Button("New customer") { showNewCustomer = true }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
    }

    private var customerList: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.tertiary)
                TextField("Search customers", text: $searchText).textFieldStyle(.plain).studioTextCursor()
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(StudioTheme.soft).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16).padding(.top, 8)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filtered) { customer in
                        Button { selectedID = customer.id } label: {
                            HStack(spacing: 11) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioTheme.soft)
                                    Text(initials(customer.name)).font(.system(size: 11, weight: .semibold))
                                }
                                .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(customer.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(customer.email.isEmpty ? customer.city : customer.email)
                                        .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                }
                                Spacer()
                                if selectedID == customer.id {
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
                                }
                            }
                            .foregroundStyle(StudioTheme.primary)
                            .padding(.horizontal, 10).frame(height: 52)
                            .background(selectedID == customer.id ? StudioTheme.selected : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 16)
            }
        }
        .background(StudioTheme.sidebar.opacity(0.45))
    }

    @ViewBuilder private var customerDetail: some View {
        if let id = selectedID, let customer = store.customer(id: id) {
            ModoCustomerDetail(customer: customer)
                .environmentObject(store)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.2").font(.system(size: 28)).foregroundStyle(StudioTheme.tertiary)
                Text("Select a customer").font(.system(size: 15, weight: .semibold))
                Text("Customer context, quotes, work and invoices stay connected here.")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

private struct ModoCustomerDetail: View {
    @EnvironmentObject private var store: FramoStudioStore
    let customer: ModoOrganization
    @State private var editing = false
    @State private var contactDraft: ModoPerson?

    private var contacts: [ModoPerson] { store.business.people.filter { $0.organizationIDs.contains(customer.id) } }
    private var opportunities: [ModoOpportunity] { store.business.opportunities.filter { $0.customerID == customer.id } }
    private var quotes: [ModoQuote] { store.business.quotes.filter { $0.customerID == customer.id } }
    private var projects: [StudioProject] { store.projects.filter { $0.customerID == customer.id } }
    private var invoices: [ModoInvoice] { store.invoices.filter { $0.customerID == customer.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(customer.name).font(.system(size: 28, weight: .semibold))
                        HStack(spacing: 10) {
                            if !customer.email.isEmpty { Text(customer.email) }
                            if !customer.phone.isEmpty { Text(customer.phone) }
                            if !customer.city.isEmpty { Text(customer.city) }
                        }
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = true }.buttonStyle(SecondaryButtonStyle())
                    Button("New opportunity") { _ = store.createOpportunity(customerID: customer.id, title: "New opportunity") }.buttonStyle(PrimaryButtonStyle())
                }

                HStack(spacing: 10) {
                    relationMetric("Open opportunities", opportunities.filter { ![.won, .lost].contains($0.stage) }.count)
                    relationMetric("Quotes", quotes.count)
                    relationMetric("Active work", projects.filter { $0.status != .delivered }.count)
                    relationMetric("Invoices", invoices.count)
                }

                detailSection("Contacts") {
                    VStack(spacing: 7) {
                        HStack {
                            Text(contacts.isEmpty ? "No contacts yet" : "\(contacts.count) saved")
                                .font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
                            Spacer()
                            Button("Add contact") {
                                contactDraft = ModoPerson(organizationIDs: [customer.id], name: "")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        ForEach(contacts) { person in
                            Button { contactDraft = person } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.name).font(.system(size: 11, weight: .semibold))
                                        Text([person.role, person.email, person.phone].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
                                }
                                .foregroundStyle(StudioTheme.primary).padding(10).background(StudioTheme.soft.opacity(0.52)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                    }
                }

                if !customer.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detailSection("Notes") { Text(customer.notes).font(.system(size: 12)).textSelection(.enabled) }
                }

                detailSection("Connected work") {
                    VStack(spacing: 7) {
                        ForEach(projects) { project in
                            Button { store.openProject(project.id) } label: {
                                HStack {
                                    Capsule().fill(Color(hex: project.colorHex)).frame(width: 4, height: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.title).font(.system(size: 12, weight: .semibold))
                                        Text(project.status.rawValue).font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
                                    }
                                    Spacer()
                                    Text(project.dueDate.shortStudioDate).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                                }
                                .foregroundStyle(StudioTheme.primary).padding(10).background(StudioTheme.soft.opacity(0.68)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                        if projects.isEmpty { emptyLine("No work linked yet") }
                    }
                }

                detailSection("Timeline") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.activities(for: customer.id).prefix(30)) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(StudioTheme.tertiary).frame(width: 5, height: 5).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.summary).font(.system(size: 11, weight: .medium))
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary)
                                }
                            }
                        }
                        if store.activities(for: customer.id).isEmpty { emptyLine("No activity yet") }
                    }
                }
            }
            .padding(28).frame(maxWidth: 980, alignment: .topLeading)
        }
        .sheet(isPresented: $editing) {
            ModoCustomerEditor(customer: customer) { store.updateCustomer($0) }.environmentObject(store)
        }
        .sheet(item: $contactDraft) { person in
            ModoPersonEditor(person: person) { value in
                if store.business.people.contains(where: { $0.id == value.id }) {
                    store.updatePerson(value)
                } else {
                    _ = store.createPerson(organizationID: customer.id, name: value.name, email: value.email, phone: value.phone, role: value.role)
                }
            }
            .environmentObject(store)
        }
    }

    private func relationMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 20, weight: .semibold))
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(StudioTheme.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(StudioTheme.soft.opacity(0.68)).clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(StudioTheme.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}

private struct ModoCustomerEditor: View {
    @EnvironmentObject private var store: FramoStudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModoOrganization
    let onSave: (ModoOrganization) -> Void

    init(customer: ModoOrganization, onSave: @escaping (ModoOrganization) -> Void) {
        _draft = State(initialValue: customer)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(draft.name.isEmpty ? "New customer" : "Edit customer").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            field("Name", text: $draft.name)
            HStack(spacing: 10) { field("Email", text: $draft.email); field("Phone", text: $draft.phone) }
            HStack(spacing: 10) { field("VAT number", text: $draft.vatNumber); field("Peppol ID", text: $draft.peppolID) }
            field("Street", text: $draft.street)
            HStack(spacing: 10) { field("Postal code", text: $draft.postalCode); field("City", text: $draft.city); field("Country", text: $draft.countryCode) }
            let duplicates = store.possibleDuplicateCustomers(name: draft.name, email: draft.email, vatNumber: draft.vatNumber, excluding: draft.id)
            if !duplicates.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Possible duplicate", systemImage: "person.2.badge.gearshape")
                        .font(.system(size: 10, weight: .semibold))
                    ForEach(duplicates.prefix(3)) { existing in
                        Text(existing.name + (existing.email.isEmpty ? "" : " · \(existing.email)"))
                            .font(.system(size: 9))
                            .foregroundStyle(StudioTheme.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.soft.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
                TextEditor(text: $draft.notes).font(.system(size: 12)).scrollContentBackground(.hidden).padding(8).frame(height: 90).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()); Button("Save") { onSave(draft); dismiss() }.buttonStyle(PrimaryButtonStyle()).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(24).frame(width: 620)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
            TextField(title, text: text).textFieldStyle(.plain).studioTextCursor().padding(.horizontal, 10).frame(height: 36).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ModoPersonEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModoPerson
    let onSave: (ModoPerson) -> Void

    init(person: ModoPerson, onSave: @escaping (ModoPerson) -> Void) {
        _draft = State(initialValue: person)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(draft.name.isEmpty ? "New contact" : "Contact").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            personField("Name", text: $draft.name)
            personField("Role", text: $draft.role)
            HStack(spacing: 8) { personField("Email", text: $draft.email); personField("Phone", text: $draft.phone) }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
                TextEditor(text: $draft.notes).font(.system(size: 11)).scrollContentBackground(.hidden).padding(8).frame(height: 80).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()); Button("Save") { onSave(draft); dismiss() }.buttonStyle(PrimaryButtonStyle()).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(22).frame(width: 520)
    }

    private func personField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
            TextField(title, text: text).textFieldStyle(.plain).studioTextCursor().padding(.horizontal, 10).frame(height: 36).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sales

struct ModoSalesView: View {
    @EnvironmentObject private var store: FramoStudioStore
    @State private var tab: Tab = .pipeline
    @State private var editingOpportunity: ModoOpportunity?
    @State private var editingQuote: ModoQuote?

    private enum Tab: String, CaseIterable { case pipeline = "Pipeline", quotes = "Quotes" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tab == .pipeline { pipeline } else { quotes }
        }
        .sheet(item: $editingOpportunity) { opportunity in
            ModoOpportunityEditor(opportunity: opportunity) { store.updateOpportunity($0) }.environmentObject(store)
        }
        .sheet(item: $editingQuote) { quote in
            ModoQuoteEditor(quote: quote).environmentObject(store)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sales").font(.system(size: 29, weight: .semibold))
                Text("Move an inquiry to a quote, then turn accepted work into delivery.").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
            }
            Spacer()
            Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 190)
            Menu("New") {
                Button("Opportunity") {
                    let opportunity = ModoOpportunity(title: "New opportunity", currency: store.settings.currency, owner: store.settings.ownerName)
                    store.business.opportunities.insert(opportunity, at: 0)
                    editingOpportunity = opportunity
                }
                Button("Quote") {
                    let id = store.createQuote(customerID: store.business.organizations.first?.id)
                    editingQuote = store.business.quotes.first { $0.id == id }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
    }

    private var pipeline: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(ModoOpportunityStage.allCases) { stage in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(stage.rawValue).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(store.business.opportunities.filter { $0.stage == stage }.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.tertiary)
                        }
                        ForEach(store.business.opportunities.filter { $0.stage == stage }) { opportunity in
                            Button { editingOpportunity = opportunity } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(opportunity.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                    Text(store.customerName(id: opportunity.customerID)).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                                    HStack {
                                        Text(opportunity.expectedValue, format: .currency(code: opportunity.currency)).font(.system(size: 10, weight: .semibold))
                                        Spacer()
                                        if let date = opportunity.nextActionDate { Text(date.shortStudioDate).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary) }
                                    }
                                }
                                .foregroundStyle(StudioTheme.primary).padding(12).frame(width: 238, alignment: .leading).background(StudioTheme.soft.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain).studioPointerCursor()
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 238, alignment: .top)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
    }

    private var quotes: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(store.business.quotes.sorted { $0.updatedAt > $1.updatedAt }) { quote in
                    Button { editingQuote = quote } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(quote.quoteNumber).font(.system(size: 12, weight: .semibold))
                                Text(store.customerName(id: quote.customerID)).font(.system(size: 10)).foregroundStyle(StudioTheme.secondary)
                            }
                            Spacer()
                            Text(quote.status.rawValue).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 8).frame(height: 24).background(StudioTheme.soft).clipShape(Capsule())
                            Text(quote.total, format: .currency(code: quote.currency)).font(.system(size: 12, weight: .semibold)).frame(width: 100, alignment: .trailing)
                            Text(quote.validUntil.shortStudioDate).font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary).frame(width: 72, alignment: .trailing)
                        }
                        .foregroundStyle(StudioTheme.primary).padding(.horizontal, 14).frame(height: 56).background(StudioTheme.soft.opacity(0.48)).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain).studioPointerCursor()
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 36)
        }
    }
}

private struct ModoOpportunityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FramoStudioStore
    @State private var draft: ModoOpportunity
    let onSave: (ModoOpportunity) -> Void

    init(opportunity: ModoOpportunity, onSave: @escaping (ModoOpportunity) -> Void) {
        _draft = State(initialValue: opportunity)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Opportunity").font(.system(size: 22, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            TextField("Opportunity name", text: $draft.title).textFieldStyle(.plain).font(.system(size: 16, weight: .semibold)).padding(10).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Picker("Customer", selection: $draft.customerID) {
                    Text("No customer").tag(UUID?.none)
                    ForEach(store.business.organizations) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Stage", selection: $draft.stage) { ForEach(ModoOpportunityStage.allCases) { Text($0.rawValue).tag($0) } }
            }
            HStack { TextField("Expected value", value: $draft.expectedValue, format: .number).textFieldStyle(.roundedBorder); TextField("Owner", text: $draft.owner).textFieldStyle(.roundedBorder) }
            TextField("Next action", text: $draft.nextAction).textFieldStyle(.roundedBorder)
            DatePicker("Follow up", selection: Binding(get: { draft.nextActionDate ?? .now }, set: { draft.nextActionDate = $0 }), displayedComponents: [.date])
            TextEditor(text: $draft.notes).frame(height: 90).scrollContentBackground(.hidden).padding(8).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()); Button("Save") { onSave(draft); dismiss() }.buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(24).frame(width: 580)
    }
}

private struct ModoQuoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FramoStudioStore
    @State private var draft: ModoQuote

    init(quote: ModoQuote) { _draft = State(initialValue: quote) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.quoteNumber).font(.system(size: 22, weight: .semibold))
                        Text("Revision \(draft.revision)").font(.system(size: 10)).foregroundStyle(StudioTheme.tertiary)
                    }
                    Spacer()
                    Button("Export PDF") { store.updateQuote(draft); store.exportQuotePDF(draft.id) }.buttonStyle(SecondaryButtonStyle())
                    Button("New revision") {
                        store.updateQuote(draft)
                        if let id = store.createQuoteRevision(from: draft.id), let revision = store.business.quotes.first(where: { $0.id == id }) {
                            draft = revision
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Close") { store.updateQuote(draft); dismiss() }.buttonStyle(SecondaryButtonStyle())
                }

                HStack(spacing: 12) {
                    Picker("Customer", selection: $draft.customerID) {
                        Text("No customer").tag(UUID?.none)
                        ForEach(store.business.organizations) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Status", selection: $draft.status) { ForEach(ModoQuoteStatus.allCases) { Text($0.rawValue).tag($0) } }
                    DatePicker("Valid until", selection: $draft.validUntil, displayedComponents: [.date])
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Line items").font(.system(size: 13, weight: .semibold)); Spacer(); Button("Add line") { draft.lines.append(ModoQuoteLine()) }.buttonStyle(SecondaryButtonStyle()) }
                    ForEach(draft.lines.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField("Service or product", text: $draft.lines[index].name).textFieldStyle(.roundedBorder)
                            TextField("Qty", value: $draft.lines[index].quantity, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                            TextField("Rate", value: $draft.lines[index].unitPrice, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                            TextField("Tax", value: $draft.lines[index].taxRate, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                            Text(draft.lines[index].total, format: .currency(code: draft.currency)).font(.system(size: 11, weight: .semibold)).frame(width: 100, alignment: .trailing)
                            Button { if draft.lines.count > 1 { draft.lines.remove(at: index) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Subtotal  \(draft.subtotal.formatted(.currency(code: draft.currency)))").foregroundStyle(StudioTheme.secondary)
                        Text("Tax  \(draft.taxTotal.formatted(.currency(code: draft.currency)))").foregroundStyle(StudioTheme.secondary)
                        Text(draft.total.formatted(.currency(code: draft.currency))).font(.system(size: 20, weight: .semibold))
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Terms").font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
                        TextEditor(text: $draft.terms).font(.system(size: 11)).scrollContentBackground(.hidden).padding(8).frame(height: 82).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
                        TextEditor(text: $draft.notes).font(.system(size: 11)).scrollContentBackground(.hidden).padding(8).frame(height: 82).background(StudioTheme.input).clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }

                HStack {
                    Button("Save") { store.updateQuote(draft) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    if draft.status != .accepted {
                        Button("Accept & create work") {
                            store.updateQuote(draft)
                            _ = store.acceptQuote(draft.id)
                            dismiss()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else if draft.projectID == nil {
                        Button("Create work") { _ = store.acceptQuote(draft.id); dismiss() }.buttonStyle(PrimaryButtonStyle())
                    }
                    if draft.status == .accepted {
                        Button("Create invoice") {
                            store.updateQuote(draft)
                            _ = store.createInvoiceFromQuote(draft.id)
                            store.openDestination(.finance)
                            dismiss()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 820, height: 620)
    }
}


private struct ModoQuotePrintView: View {
    let quote: ModoQuote
    let customer: ModoOrganization?
    let businessName: String
    let businessCity: String
    let businessCountryCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(businessName.isEmpty ? "MODO" : businessName)
                        .font(.system(size: 22, weight: .bold))
                    Text([businessCity, businessCountryCode].filter { !$0.isEmpty }.joined(separator: ", "))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("QUOTE").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    Text(quote.quoteNumber).font(.system(size: 20, weight: .semibold))
                    Text("Revision \(quote.revision)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prepared for").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(customer?.name ?? "Customer").font(.system(size: 13, weight: .semibold))
                    if let customer {
                        Text([customer.street, [customer.postalCode, customer.city].filter { !$0.isEmpty }.joined(separator: " "), customer.countryCode].filter { !$0.isEmpty }.joined(separator: "\n"))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Issued \(quote.issueDate.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 9))
                    Text("Valid until \(quote.validUntil.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 9))
                }
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Qty").frame(width: 44, alignment: .trailing)
                    Text("Rate").frame(width: 80, alignment: .trailing)
                    Text("Total").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
                Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1)
                ForEach(quote.lines) { line in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.name).font(.system(size: 10, weight: .semibold))
                            if !line.description.isEmpty { Text(line.description).font(.system(size: 8)).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(line.quantity.formatted()).frame(width: 44, alignment: .trailing)
                        Text(line.unitPrice, format: .currency(code: quote.currency)).frame(width: 80, alignment: .trailing)
                        Text(line.total, format: .currency(code: quote.currency)).frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 9)).padding(.vertical, 9)
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
                }
            }

            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("Subtotal  \(quote.subtotal.formatted(.currency(code: quote.currency)))").font(.system(size: 9))
                    Text("Tax  \(quote.taxTotal.formatted(.currency(code: quote.currency)))").font(.system(size: 9))
                    Text(quote.total.formatted(.currency(code: quote.currency))).font(.system(size: 18, weight: .semibold))
                }
            }

            if !quote.terms.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Terms").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(quote.terms).font(.system(size: 9))
                }
            }
            if !quote.notes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Notes").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(quote.notes).font(.system(size: 9))
                }
            }
            Spacer()
            Text("Generated by MODO — Your business. Your way.").font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .padding(44)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}
