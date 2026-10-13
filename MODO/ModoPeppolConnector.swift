import Foundation
import AppKit
import Security
import UniformTypeIdentifiers

/// Free-first Peppol support.
///
/// MODO itself never charges for e-invoicing. Recipient discovery and UBL export
/// are completely local/public. Live network transport is optional and currently
/// integrates Peppyrus because it publishes a free plan and a documented API.
/// Provider limits/terms are surfaced in the UI instead of being hidden.
@MainActor
final class ModoPeppolConnector: ObservableObject {
    enum State: Equatable {
        case disconnected
        case ready
        case working(String)
        case success(String)
        case error(String)

        var label: String {
            switch self {
            case .disconnected: return "Free tools ready"
            case .ready: return "Peppyrus connected"
            case .working(let value): return value
            case .success(let value): return value
            case .error(let value): return value
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastRecipientCheck: String?

    private weak var store: FramoStudioStore?

    var providerName: String { "Peppyrus" }
    var providerFreeTierLabel: String {
        "MODO adds no fees. Peppyrus currently publishes a free plan with up to 100 Peppol messages/month and unlimited receiving."
    }

    private var baseURL: URL {
        URL(string: store?.settings.peppolUseTestEnvironment == true
            ? "https://api.test.peppyrus.be/v1"
            : "https://api.peppyrus.be/v1")!
    }

    func install(store: FramoStudioStore) {
        self.store = store
        reloadForActiveProfile()
    }

    func reloadForActiveProfile() {
        state = isConfigured ? .ready : .disconnected
        lastRecipientCheck = nil
    }

    /// Sending is configured when a Peppyrus key and sender participant ID exist.
    /// Public recipient lookup and UBL export work without configuration.
    var isConfigured: Bool {
        guard let sender = store?.settings.peppolSenderParticipantID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sender.isEmpty,
              !apiKey.isEmpty else { return false }
        return true
    }

    var apiKey: String {
        guard let profileID = store?.activeProfileID else { return "" }
        return Self.readSecret(profileID: profileID) ?? ""
    }

    func configure(
        apiKey: String,
        senderParticipantID: String,
        iban: String,
        businessVAT: String,
        street: String,
        zip: String,
        city: String,
        countryCode: String,
        useTestEnvironment: Bool
    ) {
        guard let store, let profileID = store.activeProfileID else { return }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty { Self.saveSecret(cleanKey, profileID: profileID) }
        store.settings.peppolSenderParticipantID = Self.canonicalParticipantInput(senderParticipantID)
        store.settings.peppolBusinessIBAN = iban.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.peppolBusinessVAT = businessVAT.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.peppolBusinessStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.peppolBusinessZip = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.peppolBusinessCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.peppolBusinessCountryCode = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        store.settings.peppolUseTestEnvironment = useTestEnvironment
        state = isConfigured ? .ready : .disconnected
    }

    func disconnect() {
        guard let store, let profileID = store.activeProfileID else { return }
        Self.clearSecret(profileID: profileID)
        store.settings.peppolSenderParticipantID = nil
        state = .disconnected
        lastRecipientCheck = nil
    }

    func testConnection() async {
        guard isConfigured else {
            state = .error("Add a Peppyrus API key and sender Peppol ID")
            return
        }
        state = .working("Checking Peppyrus…")
        do {
            _ = try await request(path: "organization/info", method: "GET", body: nil)
            state = .success(store?.settings.peppolUseTestEnvironment == true ? "Connected to Peppyrus test" : "Connected to Peppyrus")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Public lookup against the OpenPeppol Directory. No provider account needed.
    func discoverReceiver(scheme: String, identifier: String) async -> Bool {
        let schemeID = Self.isoScheme(scheme)
        let cleanID = Self.normalizedParticipantID(identifier)
        if schemeID == "0208" {
            guard Self.isValidBelgianEnterpriseNumber(cleanID) else {
                state = .error("Belgian Peppol ID must be a valid 10-digit enterprise number")
                return false
            }
        }

        state = .working("Checking Peppol Directory…")
        do {
            let participant = "iso6523-actorid-upis::\(schemeID):\(cleanID)"
            var components = URLComponents(string: "https://directory.peppol.eu/search/1.0/json")!
            components.queryItems = [URLQueryItem(name: "participant", value: participant)]
            guard let url = components.url else { throw ConnectorError.invalidResponse("Invalid lookup URL") }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ConnectorError.invalidResponse("Peppol Directory lookup failed")
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let matches = (object?["matches"] as? [[String: Any]]) ?? (object?["result"] as? [[String: Any]]) ?? []
            let explicitCount = (object?["total-result-count"] as? Int) ?? (object?["used-result-count"] as? Int)
            let canReceive = explicitCount.map { $0 > 0 } ?? !matches.isEmpty
            lastRecipientCheck = canReceive
                ? "Recipient is listed in the public Peppol Directory"
                : "Not listed in the Directory. That does not always mean the recipient is unavailable."
            state = canReceive ? .success(lastRecipientCheck!) : .error(lastRecipientCheck!)
            return canReceive
        } catch {
            state = .error(error.localizedDescription)
            return false
        }
    }

    func exportUBL(invoiceID: UUID) {
        guard let store,
              let invoice = store.invoices.first(where: { $0.id == invoiceID }) else { return }
        do {
            let data = Data(try ublXML(for: invoice).utf8)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.xml]
            panel.nameFieldStringValue = "\(invoice.invoiceNumber.replacingOccurrences(of: "/", with: "-")).xml"
            panel.title = "Export Peppol BIS invoice"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                state = .success("UBL exported")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func send(invoiceID: UUID) async {
        guard let store,
              let index = store.invoices.firstIndex(where: { $0.id == invoiceID }) else { return }
        var invoice = store.invoices[index]

        guard invoice.canSendViaPeppol else {
            state = .error("Complete the invoice and recipient Peppol ID first")
            return
        }
        guard isConfigured,
              let sender = store.settings.peppolSenderParticipantID, !sender.isEmpty else {
            state = .error("Connect Peppyrus or export the UBL file for another Access Point")
            return
        }

        invoice.status = .sending
        invoice.lastTransmissionMessage = "Submitting the Peppol BIS invoice…"
        store.updateInvoice(invoice)
        state = .working("Sending via Peppol…")

        do {
            let xml = try ublXML(for: invoice)
            let payload: [String: Any] = [
                "sender": Self.apiParticipant(sender),
                "recipient": Self.apiParticipant("\(Self.isoScheme(invoice.customerPeppolScheme)):\(Self.normalizedParticipantID(invoice.customerPeppolID))"),
                "processType": "cenbii-procid-ubl::urn:fdc:peppol.eu:2017:poacc:billing:01:1.0",
                "documentType": "busdox-docid-qns::urn:oasis:names:specification:ubl:schema:xsd:Invoice-2::Invoice##urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0::2.1",
                "fileContent": Data(xml.utf8).base64EncodedString()
            ]

            let data = try await request(path: "message", method: "POST", body: payload)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let messageID = (object?["id"] as? String) ?? (object?["uuid"] as? String), !messageID.isEmpty else {
                throw ConnectorError.invalidResponse("Peppyrus did not return a message ID")
            }

            invoice.submissionGUID = messageID
            invoice.status = .sent
            invoice.lastTransmissionMessage = "Submitted to Peppol through Peppyrus. Delivery status can be refreshed."
            store.updateInvoice(invoice)
            state = .success("Submitted to Peppol")
        } catch {
            invoice.status = .failed
            invoice.lastTransmissionMessage = error.localizedDescription
            store.updateInvoice(invoice)
            state = .error(error.localizedDescription)
        }
    }

    func refreshEvidence(invoiceID: UUID) async {
        guard let store,
              let index = store.invoices.firstIndex(where: { $0.id == invoiceID }) else { return }
        var invoice = store.invoices[index]
        guard let id = invoice.submissionGUID, !id.isEmpty else {
            state = .error("This invoice has no Peppol submission yet")
            return
        }
        guard isConfigured else {
            state = .error("Reconnect Peppyrus to refresh delivery status")
            return
        }

        state = .working("Refreshing delivery status…")
        do {
            let data = try await request(path: "message/\(id)/report", method: "GET", body: nil)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let transmission = object?["transmissionRules"] as? String
            invoice.lastTransmissionMessage = transmission?.isEmpty == false
                ? transmission
                : "Peppyrus returned an updated delivery report."
            if invoice.status == .sending || invoice.status == .failed { invoice.status = .sent }
            store.updateInvoice(invoice)
            state = .success("Delivery report refreshed")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func ublXML(for invoice: ModoInvoice) throws -> String {
        guard let store else { throw ConnectorError.notConfigured }
        let sender = store.settings.peppolSenderParticipantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sender.isEmpty else { throw ConnectorError.invalidResponse("Add the sender Peppol ID first") }

        let senderParts = Self.participantParts(sender)
        let recipientScheme = Self.isoScheme(invoice.customerPeppolScheme)
        let recipientID = Self.normalizedParticipantID(invoice.customerPeppolID)
        let sellerName = store.settings.studioName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sellerVAT = store.settings.peppolBusinessVAT?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sellerCountry = (store.settings.peppolBusinessCountryCode ?? "BE").uppercased()
        let iban = (store.settings.peppolBusinessIBAN ?? "").replacingOccurrences(of: " ", with: "")

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"

        let taxByRate = Dictionary(grouping: invoice.lines, by: \.vatRate).mapValues { lines in
            (
                taxable: lines.reduce(0) { $0 + $1.subtotal },
                tax: lines.reduce(0) { $0 + $1.vatAmount }
            )
        }

        let taxSubtotals = taxByRate.keys.sorted().map { rate -> String in
            let values = taxByRate[rate]!
            let category = rate == 0 ? "Z" : "S"
            return """
            <cac:TaxSubtotal>
              <cbc:TaxableAmount currencyID="\(xml(invoice.currency))">\(money(values.taxable))</cbc:TaxableAmount>
              <cbc:TaxAmount currencyID="\(xml(invoice.currency))">\(money(values.tax))</cbc:TaxAmount>
              <cac:TaxCategory>
                <cbc:ID>\(category)</cbc:ID>
                <cbc:Percent>\(money(rate))</cbc:Percent>
                <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
              </cac:TaxCategory>
            </cac:TaxSubtotal>
            """
        }.joined(separator: "\n")

        let linesXML = invoice.lines.enumerated().map { index, line -> String in
            let category = line.vatRate == 0 ? "Z" : "S"
            return """
            <cac:InvoiceLine>
              <cbc:ID>\(index + 1)</cbc:ID>
              <cbc:InvoicedQuantity unitCode="C62">\(quantity(line.quantity))</cbc:InvoicedQuantity>
              <cbc:LineExtensionAmount currencyID="\(xml(invoice.currency))">\(money(line.subtotal))</cbc:LineExtensionAmount>
              <cac:Item>
                <cbc:Name>\(xml(line.name))</cbc:Name>
                <cac:ClassifiedTaxCategory>
                  <cbc:ID>\(category)</cbc:ID>
                  <cbc:Percent>\(money(line.vatRate))</cbc:Percent>
                  <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
                </cac:ClassifiedTaxCategory>
              </cac:Item>
              <cac:Price><cbc:PriceAmount currencyID="\(xml(invoice.currency))">\(money(line.unitPrice))</cbc:PriceAmount></cac:Price>
            </cac:InvoiceLine>
            """
        }.joined(separator: "\n")

        let paymentXML = iban.isEmpty ? "" : """
          <cac:PaymentMeans>
            <cbc:PaymentMeansCode>30</cbc:PaymentMeansCode>
            <cbc:PaymentID>\(xml(invoice.invoiceNumber))</cbc:PaymentID>
            <cac:PayeeFinancialAccount><cbc:ID>\(xml(iban))</cbc:ID></cac:PayeeFinancialAccount>
          </cac:PaymentMeans>
        """

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
                 xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
                 xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
          <cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0</cbc:CustomizationID>
          <cbc:ProfileID>urn:fdc:peppol.eu:2017:poacc:billing:01:1.0</cbc:ProfileID>
          <cbc:ID>\(xml(invoice.invoiceNumber))</cbc:ID>
          <cbc:IssueDate>\(date.string(from: invoice.issueDate))</cbc:IssueDate>
          <cbc:DueDate>\(date.string(from: invoice.dueDate))</cbc:DueDate>
          <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
          <cbc:DocumentCurrencyCode>\(xml(invoice.currency))</cbc:DocumentCurrencyCode>
          \(invoice.notes.isEmpty ? "" : "<cbc:Note>\(xml(invoice.notes))</cbc:Note>")
          <cac:AccountingSupplierParty>
            <cac:Party>
              <cbc:EndpointID schemeID="\(xml(senderParts.scheme))">\(xml(senderParts.id))</cbc:EndpointID>
              <cac:PostalAddress>
                <cbc:StreetName>\(xml(store.settings.peppolBusinessStreet ?? ""))</cbc:StreetName>
                <cbc:CityName>\(xml(store.settings.peppolBusinessCity ?? ""))</cbc:CityName>
                <cbc:PostalZone>\(xml(store.settings.peppolBusinessZip ?? ""))</cbc:PostalZone>
                <cac:Country><cbc:IdentificationCode>\(xml(sellerCountry))</cbc:IdentificationCode></cac:Country>
              </cac:PostalAddress>
              \(sellerVAT.isEmpty ? "" : "<cac:PartyTaxScheme><cbc:CompanyID>\(xml(sellerVAT))</cbc:CompanyID><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:PartyTaxScheme>")
              <cac:PartyLegalEntity><cbc:RegistrationName>\(xml(sellerName.isEmpty ? "MODO business" : sellerName))</cbc:RegistrationName></cac:PartyLegalEntity>
            </cac:Party>
          </cac:AccountingSupplierParty>
          <cac:AccountingCustomerParty>
            <cac:Party>
              <cbc:EndpointID schemeID="\(xml(recipientScheme))">\(xml(recipientID))</cbc:EndpointID>
              <cac:PostalAddress>
                <cbc:StreetName>\(xml(invoice.customerStreet))</cbc:StreetName>
                <cbc:CityName>\(xml(invoice.customerCity))</cbc:CityName>
                <cbc:PostalZone>\(xml(invoice.customerZip))</cbc:PostalZone>
                <cac:Country><cbc:IdentificationCode>\(xml(invoice.customerCountryCode.uppercased()))</cbc:IdentificationCode></cac:Country>
              </cac:PostalAddress>
              <cac:PartyLegalEntity><cbc:RegistrationName>\(xml(invoice.customerName))</cbc:RegistrationName></cac:PartyLegalEntity>
            </cac:Party>
          </cac:AccountingCustomerParty>
          \(paymentXML)
          <cac:TaxTotal>
            <cbc:TaxAmount currencyID="\(xml(invoice.currency))">\(money(invoice.vatTotal))</cbc:TaxAmount>
            \(taxSubtotals)
          </cac:TaxTotal>
          <cac:LegalMonetaryTotal>
            <cbc:LineExtensionAmount currencyID="\(xml(invoice.currency))">\(money(invoice.subtotal))</cbc:LineExtensionAmount>
            <cbc:TaxExclusiveAmount currencyID="\(xml(invoice.currency))">\(money(invoice.subtotal))</cbc:TaxExclusiveAmount>
            <cbc:TaxInclusiveAmount currencyID="\(xml(invoice.currency))">\(money(invoice.total))</cbc:TaxInclusiveAmount>
            <cbc:PayableAmount currencyID="\(xml(invoice.currency))">\(money(invoice.total))</cbc:PayableAmount>
          </cac:LegalMonetaryTotal>
          \(linesXML)
        </Invoice>
        """
    }

    private func request(path: String, method: String, body: [String: Any]?) async throws -> Data {
        guard !apiKey.isEmpty else { throw ConnectorError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.invalidResponse("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ConnectorError.api(message)
        }
        return data
    }

    private func money(_ value: Double) -> String { String(format: "%.2f", value) }
    private func quantity(_ value: Double) -> String {
        let raw = String(format: "%.4f", value)
        return raw.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                  .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func normalizedParticipantID(_ value: String) -> String {
        let afterColon = value.split(separator: ":").last.map(String.init) ?? value
        return afterColon.uppercased()
            .replacingOccurrences(of: "BE", with: "")
            .filter(\.isNumber)
    }

    static func isoScheme(_ value: String) -> String {
        let upper = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if upper == "BE:EN" || upper == "0208" { return "0208" }
        return upper.filter { $0.isNumber || $0.isLetter }
    }

    static func canonicalParticipantInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { return "\(isoScheme(parts[0])):\(normalizedParticipantID(parts[1]))" }
        }
        let id = normalizedParticipantID(trimmed)
        return "0208:\(id)"
    }

    static func apiParticipant(_ value: String) -> String {
        let parts = participantParts(value)
        return "\(parts.scheme):\(parts.id)"
    }

    static func participantParts(_ value: String) -> (scheme: String, id: String) {
        let clean = value.replacingOccurrences(of: "iso6523-actorid-upis::", with: "")
        let parts = clean.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (isoScheme(parts[0]), normalizedParticipantID(parts[1])) }
        return ("0208", normalizedParticipantID(clean))
    }

    static func isValidBelgianEnterpriseNumber(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        guard digits.count == 10, digits.first == "0" || digits.first == "1" else { return false }
        guard let base = Int(digits.prefix(8)), let check = Int(digits.suffix(2)) else { return false }
        let expected = 97 - (base % 97)
        return expected == check
    }

    private enum ConnectorError: LocalizedError {
        case notConfigured
        case invalidResponse(String)
        case api(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Peppol transport is not configured"
            case .invalidResponse(let message): return message
            case .api(let message): return message
            }
        }
    }

    private static func service(profileID: UUID) -> String { "be.modo.peppol.\(profileID.uuidString)" }

    private static func saveSecret(_ secret: String, profileID: UUID) {
        clearSecret(profileID: profileID)
        guard let data = secret.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(profileID: profileID),
            kSecAttrAccount as String: "peppyrus-api-key",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func readSecret(profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(profileID: profileID),
            kSecAttrAccount as String: "peppyrus-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func clearSecret(profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(profileID: profileID),
            kSecAttrAccount as String: "peppyrus-api-key"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
