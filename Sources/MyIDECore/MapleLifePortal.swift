import Foundation

/// The demo web site the Assistant operates on: a fake insurance member portal
/// modeled on the real-world claim portals our recorded automations came from.
/// It deliberately keeps two of their signature quirks — radios that ignore
/// clicks and comboboxes that only commit via ArrowDown/Enter — so recorded
/// automations (and the agents that create them) have something real to cope with.
///
/// Pages are pure renders of the portal's state; all mutation happens in
/// `perform(_:on:)`. Every label, title and message here is load-bearing: the
/// bundled harness scenario and the self-tests assert these exact strings.
public final class MapleLifePortal: MockWebSite {
    public let host = "portal.maplelife.example"

    // MARK: - State

    private var loggedIn = false
    private var usernameValue = ""
    private var passwordValue = ""
    private var signedInUsername = ""

    private var claimant = ""
    private var category = ""
    private var dateValue = ""
    private var visitTypeValue = ""
    private var amountValue = ""
    private var expenses: [(date: String, visit: String, amount: String)] = []

    /// Element id of the combobox whose option list is open, if any.
    private var openComboboxID: String?
    private var highlightIndex: Int?

    public private(set) var submittedClaimCount = 0
    public private(set) var lastSubmittedTotal: String?

    public init() {}

    public func reset() {
        loggedIn = false
        usernameValue = ""
        passwordValue = ""
        signedInUsername = ""
        clearClaim()
        submittedClaimCount = 0
        lastSubmittedTotal = nil
    }

    private func clearClaim() {
        claimant = ""
        category = ""
        clearExpenseFields()
        expenses = []
        openComboboxID = nil
        highlightIndex = nil
    }

    private func clearExpenseFields() {
        dateValue = ""
        visitTypeValue = ""
        amountValue = ""
    }

    // MARK: - Comboboxes

    /// The portal's two custom dropdowns, declared once so rendering and key
    /// handling can't drift apart.
    private struct Combobox {
        let id: String
        let label: String
        let options: [String]
        let read: (MapleLifePortal) -> String
        let write: (MapleLifePortal, String) -> Void
    }

    private static let comboboxes: [Combobox] = [
        Combobox(
            id: "who.claimant",
            label: "Claim for",
            options: ["Jude Gao", "Alex Gao"],
            read: { $0.claimant },
            write: { $0.claimant = $1 }
        ),
        Combobox(
            id: "expense.visitType",
            label: "Visit type",
            options: ["Initial visit", "Subsequent visit"],
            read: { $0.visitTypeValue },
            write: { $0.visitTypeValue = $1 }
        ),
    ]

    private func combobox(withID id: String) -> Combobox? {
        Self.comboboxes.first { $0.id == id }
    }

    /// Maps `who.claimant.option.1` back to its combobox and option index.
    private func optionTarget(for elementID: String) -> (Combobox, Int)? {
        for combobox in Self.comboboxes where elementID.hasPrefix(combobox.id + ".option.") {
            let suffix = elementID.dropFirst(combobox.id.count + ".option.".count)
            if let index = Int(suffix), combobox.options.indices.contains(index) {
                return (combobox, index)
            }
        }
        return nil
    }

    // MARK: - Rendering

    public func page(for url: String) -> BrowserPage? {
        guard let path = Self.path(of: url), pathExists(path) else { return nil }
        // Real portals bounce you to sign-in; so does the demo.
        let effectivePath = (!loggedIn && path != "/login") ? "/login" : path
        switch effectivePath {
        case "/login": return loginPage()
        case "/overview": return overviewPage()
        case "/claim/who": return whoPage()
        case "/claim/category": return categoryPage()
        case "/claim/expense": return expensePage()
        case "/claim/review": return reviewPage()
        case "/claim/done": return donePage()
        default: return nil
        }
    }

    private func pathExists(_ path: String) -> Bool {
        ["/login", "/overview", "/claim/who", "/claim/category", "/claim/expense", "/claim/review", "/claim/done"]
            .contains(path)
    }

    private static func path(of url: String) -> String? {
        guard let components = URL(string: url) else { return nil }
        let path = components.path
        return path.isEmpty ? "/login" : path
    }

    private func url(_ path: String) -> String { "https://\(host)\(path)" }

    private func loginPage() -> BrowserPage {
        BrowserPage(url: url("/login"), title: "Maple Life — Sign in", elements: [
            BrowserElement(id: "login.heading", role: .heading, label: "Sign in to Maple Life"),
            BrowserElement(id: "login.hint", role: .text, label: "Demo portal — any username and password will work."),
            BrowserElement(id: "login.username", role: .textbox, label: "Username", value: usernameValue),
            BrowserElement(id: "login.password", role: .textbox, label: "Password", value: passwordValue),
            BrowserElement(id: "login.submit", role: .button, label: "Sign in"),
        ])
    }

    private func overviewPage() -> BrowserPage {
        BrowserPage(url: url("/overview"), title: "My Maple Life", elements: [
            BrowserElement(id: "overview.heading", role: .heading, label: "Welcome back, \(signedInUsername)"),
            BrowserElement(id: "overview.blurb", role: .text, label: "Your benefits at a glance."),
            BrowserElement(id: "overview.makeClaim", role: .button, label: "Make a claim"),
            BrowserElement(id: "overview.signOut", role: .button, label: "Sign out"),
        ])
    }

    private func comboboxElement(_ combobox: Combobox) -> BrowserElement {
        var children: [BrowserElement] = []
        if openComboboxID == combobox.id {
            children = combobox.options.enumerated().map { index, option in
                BrowserElement(
                    id: "\(combobox.id).option.\(index)",
                    role: .option,
                    label: option,
                    highlighted: index == highlightIndex
                )
            }
        }
        return BrowserElement(
            id: combobox.id,
            role: .combobox,
            label: combobox.label,
            value: combobox.read(self),
            children: children
        )
    }

    private func whoPage() -> BrowserPage {
        BrowserPage(url: url("/claim/who"), title: "Make a claim — Who", elements: [
            BrowserElement(id: "who.heading", role: .heading, label: "Who is this claim for?"),
            comboboxElement(Self.comboboxes[0]),
            BrowserElement(id: "who.continue", role: .button, label: "Continue", disabled: claimant.isEmpty),
        ])
    }

    private func categoryPage() -> BrowserPage {
        let categories: [(id: String, label: String)] = [
            ("category.massage", "Massage therapist"),
            ("category.physio", "Physiotherapist"),
            ("category.chiro", "Chiropractor"),
        ]
        var elements: [BrowserElement] = [
            BrowserElement(id: "category.heading", role: .heading, label: "What kind of care did you receive?"),
        ]
        elements += categories.map { entry in
            BrowserElement(id: entry.id, role: .radio, label: entry.label, checked: category == entry.label)
        }
        elements.append(
            BrowserElement(id: "category.continue", role: .button, label: "Continue", disabled: category.isEmpty)
        )
        return BrowserPage(url: url("/claim/category"), title: "Make a claim — Category", elements: elements)
    }

    private func expensePage() -> BrowserPage {
        var elements: [BrowserElement] = [
            BrowserElement(id: "expense.heading", role: .heading, label: "Add your expenses"),
            BrowserElement(id: "expense.date", role: .textbox, label: "Service date (YYYY-MM-DD)", value: dateValue),
            comboboxElement(Self.comboboxes[1]),
            BrowserElement(id: "expense.amount", role: .textbox, label: "Amount", value: amountValue),
            BrowserElement(id: "expense.add", role: .button, label: "Add expense"),
        ]
        elements += expenses.enumerated().map { index, expense in
            BrowserElement(id: "expense.item.\(index)", role: .text, label: Self.expenseLine(index: index, expense: expense))
        }
        elements.append(
            BrowserElement(id: "expense.continue", role: .button, label: "Continue", disabled: expenses.isEmpty)
        )
        return BrowserPage(url: url("/claim/expense"), title: "Make a claim — Expenses", elements: elements)
    }

    private func reviewPage() -> BrowserPage {
        var elements: [BrowserElement] = [
            BrowserElement(id: "review.heading", role: .heading, label: "Review your claim"),
            BrowserElement(id: "review.for", role: .text, label: "For: \(claimant)"),
            BrowserElement(id: "review.care", role: .text, label: "Care: \(category)"),
        ]
        elements += expenses.enumerated().map { index, expense in
            BrowserElement(id: "review.item.\(index)", role: .text, label: Self.expenseLine(index: index, expense: expense))
        }
        elements.append(BrowserElement(id: "review.total", role: .text, label: "Total: \(formattedTotal())"))
        elements.append(BrowserElement(id: "review.submit", role: .button, label: "Submit claim"))
        return BrowserPage(url: url("/claim/review"), title: "Make a claim — Review", elements: elements)
    }

    private func donePage() -> BrowserPage {
        let total = lastSubmittedTotal ?? "$0.00"
        return BrowserPage(url: url("/claim/done"), title: "Claim submitted", elements: [
            BrowserElement(id: "done.heading", role: .heading, label: "Claim successfully submitted!"),
            BrowserElement(
                id: "done.blurb",
                role: .text,
                label: "We received your claim for \(total). You'll hear from us within 2 business days."
            ),
            BrowserElement(id: "done.again", role: .button, label: "Make another claim"),
        ])
    }

    private static func expenseLine(index: Int, expense: (date: String, visit: String, amount: String)) -> String {
        "\(index + 1). \(expense.date) — \(expense.visit) — \(formattedAmount(expense.amount))"
    }

    private static func formattedAmount(_ raw: String) -> String {
        String(format: "$%.2f", Double(raw) ?? 0)
    }

    private func formattedTotal() -> String {
        let total = expenses.reduce(0.0) { $0 + (Double($1.amount) ?? 0) }
        return String(format: "$%.2f", total)
    }

    // MARK: - Actions

    public func perform(_ action: BrowserAction, on elementID: String) -> BrowserActionOutcome {
        // Interacting anywhere else closes an open dropdown, like a real page.
        if let open = openComboboxID, elementID != open, !elementID.hasPrefix(open + ".option.") {
            openComboboxID = nil
            highlightIndex = nil
        }

        if let combobox = combobox(withID: elementID) {
            return performOnCombobox(combobox, action: action)
        }
        if let (combobox, index) = optionTarget(for: elementID) {
            guard case .click = action else {
                return BrowserActionOutcome(ok: false, message: "That key does nothing here.")
            }
            return commit(combobox, optionIndex: index)
        }

        switch elementID {
        // MARK: Login
        case "login.username":
            return textboxOutcome(action: action, label: "Username") { self.usernameValue = $0 }
        case "login.password":
            return textboxOutcome(action: action, label: "Password") { self.passwordValue = $0 }
        case "login.submit":
            guard isActivation(action) else { return keyDoesNothing() }
            guard !usernameValue.isEmpty, !passwordValue.isEmpty else {
                return BrowserActionOutcome(ok: false, message: "Enter your username and password first.")
            }
            loggedIn = true
            signedInUsername = usernameValue
            return BrowserActionOutcome(ok: true, message: "Signed in as \(signedInUsername)", navigateTo: url("/overview"))

        // MARK: Overview
        case "overview.makeClaim":
            guard isActivation(action) else { return keyDoesNothing() }
            return BrowserActionOutcome(ok: true, message: "Starting a new claim.", navigateTo: url("/claim/who"))
        case "overview.signOut":
            guard isActivation(action) else { return keyDoesNothing() }
            reset()
            return BrowserActionOutcome(ok: true, message: "Signed out.", navigateTo: url("/login"))

        // MARK: Claim wizard — who
        case "who.continue":
            return continueOutcome(action: action, blockedReason: claimant.isEmpty ? "choose who the claim is for first" : nil, destination: "/claim/category")

        // MARK: Claim wizard — category (the radio gotcha)
        case "category.massage", "category.physio", "category.chiro":
            return radioOutcome(action: action, elementID: elementID)
        case "category.continue":
            return continueOutcome(action: action, blockedReason: category.isEmpty ? "select a category first" : nil, destination: "/claim/expense")

        // MARK: Claim wizard — expenses
        case "expense.date":
            return textboxOutcome(action: action, label: "Service date (YYYY-MM-DD)") { self.dateValue = $0 }
        case "expense.amount":
            return textboxOutcome(action: action, label: "Amount") { self.amountValue = $0 }
        case "expense.add":
            guard isActivation(action) else { return keyDoesNothing() }
            return addExpense()
        case "expense.continue":
            return continueOutcome(action: action, blockedReason: expenses.isEmpty ? "add at least one expense first" : nil, destination: "/claim/review")

        // MARK: Review & done
        case "review.submit":
            guard isActivation(action) else { return keyDoesNothing() }
            lastSubmittedTotal = formattedTotal()
            submittedClaimCount += 1
            let total = lastSubmittedTotal ?? "$0.00"
            expenses = []
            return BrowserActionOutcome(ok: true, message: "Claim submitted — total \(total)", navigateTo: url("/claim/done"))
        case "done.again":
            guard isActivation(action) else { return keyDoesNothing() }
            clearClaim()
            return BrowserActionOutcome(ok: true, message: "Starting another claim.", navigateTo: url("/claim/who"))

        default:
            // Headings, hint texts and expense lines: clicking them is a no-op,
            // which conveniently doubles as "click a neutral element to blur".
            if case .click = action {
                return BrowserActionOutcome(ok: true, message: "Nothing to do there.")
            }
            return keyDoesNothing()
        }
    }

    // MARK: - Widget behaviors

    /// Buttons activate on click or Space (standard accessibility behavior).
    private func isActivation(_ action: BrowserAction) -> Bool {
        switch action {
        case .click: return true
        case .press(let key): return key == .space || key == .enter
        case .setValue: return false
        }
    }

    private func keyDoesNothing() -> BrowserActionOutcome {
        BrowserActionOutcome(ok: false, message: "That key does nothing here.")
    }

    private func textboxOutcome(action: BrowserAction, label: String, write: (String) -> Void) -> BrowserActionOutcome {
        switch action {
        case .click:
            return BrowserActionOutcome(ok: true, message: "Focused \"\(label)\"")
        case .setValue(let value):
            write(value)
            return BrowserActionOutcome(ok: true, message: "Set \"\(label)\" to \"\(value)\"")
        case .press:
            return keyDoesNothing()
        }
    }

    /// The signature quirk carried over from the real portal this feature was born
    /// on: custom radios swallow clicks and only respond to focus + Space.
    private func radioOutcome(action: BrowserAction, elementID: String) -> BrowserActionOutcome {
        let labels = ["category.massage": "Massage therapist", "category.physio": "Physiotherapist", "category.chiro": "Chiropractor"]
        guard let label = labels[elementID] else {
            return BrowserActionOutcome(ok: false, message: "Unknown radio.")
        }
        switch action {
        case .click:
            return BrowserActionOutcome(
                ok: false,
                message: "The click didn't register on this custom radio. Focus it and press Space instead."
            )
        case .press(.space):
            category = label
            return BrowserActionOutcome(ok: true, message: "Selected \"\(label)\"")
        case .setValue:
            return BrowserActionOutcome(ok: false, message: "Radios can't be typed into — press Space to select.")
        case .press:
            return keyDoesNothing()
        }
    }

    private func performOnCombobox(_ combobox: Combobox, action: BrowserAction) -> BrowserActionOutcome {
        let isOpen = openComboboxID == combobox.id
        switch action {
        case .click:
            openComboboxID = isOpen ? nil : combobox.id
            highlightIndex = nil
            return BrowserActionOutcome(ok: true, message: isOpen ? "Closed \"\(combobox.label)\"" : "Opened \"\(combobox.label)\"")
        case .setValue:
            return BrowserActionOutcome(
                ok: false,
                message: "This is a custom dropdown — open it and use ArrowDown and Enter to choose."
            )
        case .press(.arrowDown):
            if !isOpen {
                openComboboxID = combobox.id
                highlightIndex = 0
            } else {
                let next = (highlightIndex.map { $0 + 1 }) ?? 0
                highlightIndex = min(next, combobox.options.count - 1)
            }
            let highlighted = combobox.options[highlightIndex ?? 0]
            return BrowserActionOutcome(ok: true, message: "Highlighted \"\(highlighted)\"")
        case .press(.arrowUp):
            guard isOpen else {
                return BrowserActionOutcome(ok: false, message: "The list isn't open — click it or press ArrowDown first.")
            }
            highlightIndex = max((highlightIndex ?? 0) - 1, 0)
            let highlighted = combobox.options[highlightIndex ?? 0]
            return BrowserActionOutcome(ok: true, message: "Highlighted \"\(highlighted)\"")
        case .press(.enter):
            guard isOpen else {
                return BrowserActionOutcome(ok: false, message: "The list isn't open — click it or press ArrowDown first.")
            }
            guard let index = highlightIndex else {
                return BrowserActionOutcome(ok: false, message: "Nothing is highlighted — press ArrowDown to choose an option.")
            }
            return commit(combobox, optionIndex: index)
        case .press:
            return keyDoesNothing()
        }
    }

    private func commit(_ combobox: Combobox, optionIndex: Int) -> BrowserActionOutcome {
        let option = combobox.options[optionIndex]
        combobox.write(self, option)
        openComboboxID = nil
        highlightIndex = nil
        return BrowserActionOutcome(ok: true, message: "Selected \"\(option)\"")
    }

    private func continueOutcome(action: BrowserAction, blockedReason: String?, destination: String) -> BrowserActionOutcome {
        guard isActivation(action) else { return keyDoesNothing() }
        if let reason = blockedReason {
            return BrowserActionOutcome(ok: false, message: "\"Continue\" is disabled — \(reason)")
        }
        return BrowserActionOutcome(ok: true, message: "Continuing.", navigateTo: url(destination))
    }

    private func addExpense() -> BrowserActionOutcome {
        guard !visitTypeValue.isEmpty else {
            return BrowserActionOutcome(ok: false, message: "Choose a visit type first.")
        }
        guard dateValue.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else {
            return BrowserActionOutcome(ok: false, message: "Enter the date as YYYY-MM-DD.")
        }
        guard amountValue.range(of: "^\\d+(\\.\\d{1,2})?$", options: .regularExpression) != nil else {
            return BrowserActionOutcome(ok: false, message: "Enter the amount as a number, like 84.50.")
        }
        let amount = Self.formattedAmount(amountValue)
        expenses.append((date: dateValue, visit: visitTypeValue, amount: amountValue))
        clearExpenseFields()
        return BrowserActionOutcome(ok: true, message: "Added expense — \(amount)")
    }
}
