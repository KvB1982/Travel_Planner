import Foundation

/// A household sharing the costs of a trip. It may hold people without the app (children, partners).
public struct LedgerParty: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var adults: Int
    public var children: Int
    public var memberIds: [String]
    public var paidCents: Int
    public var shareCents: Int
    /// Positive: gets money back. Negative: still owes.
    public var balanceCents: Int

    public var heads: Int { adults + children }

    public init(id: String, name: String, adults: Int = 1, children: Int = 0, memberIds: [String] = [],
                paidCents: Int = 0, shareCents: Int = 0, balanceCents: Int = 0) {
        self.id = id; self.name = name; self.adults = adults; self.children = children; self.memberIds = memberIds
        self.paidCents = paidCents; self.shareCents = shareCents; self.balanceCents = balanceCents
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Haushalt"
        adults = try c.decodeIfPresent(Int.self, forKey: .adults) ?? 1
        children = try c.decodeIfPresent(Int.self, forKey: .children) ?? 0
        memberIds = try c.decodeIfPresent([String].self, forKey: .memberIds) ?? []
        paidCents = try c.decodeIfPresent(Int.self, forKey: .paidCents) ?? 0
        shareCents = try c.decodeIfPresent(Int.self, forKey: .shareCents) ?? 0
        balanceCents = try c.decodeIfPresent(Int.self, forKey: .balanceCents) ?? 0
    }
}

/// What the app sends for a household. A new one has no id yet.
public struct PartyDraft: Codable, Identifiable, Hashable, Sendable {
    /// Only for lists in the app, never sent.
    public var localID = UUID()
    public var serverID: String?
    public var name: String
    public var adults: Int
    public var children: Int
    public var memberIds: [String]

    public var id: UUID { localID }

    public init(serverID: String? = nil, name: String, adults: Int = 2, children: Int = 0, memberIds: [String] = []) {
        self.serverID = serverID; self.name = name; self.adults = adults; self.children = children; self.memberIds = memberIds
    }

    public init(_ party: LedgerParty) {
        self.init(serverID: party.id, name: party.name, adults: party.adults, children: party.children, memberIds: party.memberIds)
    }

    enum CodingKeys: String, CodingKey { case serverID = "id", name, adults, children, memberIds }
}

public struct Expense: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var amountCents: Int
    public var paidBy: String?
    public var spentOn: String?
    public var category: String?
    /// nil: as the trip splits. "heads": by heads. "custom": by `weights`.
    public var mode: String?
    /// Only these households share; empty means all.
    public var among: [String]?
    public var weights: [String: Double]?
    public var note: String?
    /// The expense cannot be shared (a household was removed) and is not counted.
    public var unsplit: Bool?

    public init(id: String, title: String, amountCents: Int, paidBy: String?, spentOn: String? = nil, category: String? = nil,
                mode: String? = nil, among: [String]? = nil, weights: [String: Double]? = nil, note: String? = nil, unsplit: Bool? = nil) {
        self.id = id; self.title = title; self.amountCents = amountCents; self.paidBy = paidBy; self.spentOn = spentOn
        self.category = category; self.mode = mode; self.among = among; self.weights = weights; self.note = note; self.unsplit = unsplit
    }
}

/// What the app sends for a new or changed expense.
public struct ExpenseDraft: Encodable, Hashable, Sendable {
    public var title: String
    public var amountCents: Int
    public var paidBy: String
    public var spentOn: String?
    public var category: String?
    public var mode: String?
    public var among: [String]
    public var weights: [String: Double]
    public var note: String?

    public init(title: String, amountCents: Int, paidBy: String, spentOn: String? = nil, category: String? = nil,
                mode: String? = nil, among: [String] = [], weights: [String: Double] = [:], note: String? = nil) {
        self.title = title; self.amountCents = amountCents; self.paidBy = paidBy; self.spentOn = spentOn; self.category = category
        self.mode = mode; self.among = among; self.weights = weights; self.note = note
    }

    // The server tells "as the trip splits" from an explicit null, so nothing is left out.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(amountCents, forKey: .amountCents); try c.encode(paidBy, forKey: .paidBy)
        try c.encode(spentOn, forKey: .spentOn); try c.encode(category, forKey: .category); try c.encode(mode, forKey: .mode)
        try c.encode(among, forKey: .among); try c.encode(weights, forKey: .weights); try c.encode(note, forKey: .note)
    }
    enum CodingKeys: String, CodingKey { case title, amountCents, paidBy, spentOn, category, mode, among, weights, note }
}

/// A settling payment that has been made.
public struct LedgerPayment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var fromParty: String
    public var toParty: String
    public var amountCents: Int
    public init(id: String, fromParty: String, toParty: String, amountCents: Int) {
        self.id = id; self.fromParty = fromParty; self.toParty = toParty; self.amountCents = amountCents
    }
}

/// A settling payment the server suggests.
public struct LedgerTransfer: Codable, Identifiable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var amountCents: Int
    public var id: String { "\(from)>\(to)>\(amountCents)" }
    public init(from: String, to: String, amountCents: Int) { self.from = from; self.to = to; self.amountCents = amountCents }
}

public struct Ledger: Decodable, Hashable, Sendable {
    /// "equal": every household the same. "heads": by heads.
    public var splitMode: String
    public var childWeight: Double
    public var myPartyId: String?
    public var totalCents: Int
    public var parties: [LedgerParty]
    public var expenses: [Expense]
    public var payments: [LedgerPayment]
    public var transfers: [LedgerTransfer]

    public init(splitMode: String = "equal", childWeight: Double = 1, myPartyId: String? = nil, totalCents: Int = 0,
                parties: [LedgerParty] = [], expenses: [Expense] = [], payments: [LedgerPayment] = [], transfers: [LedgerTransfer] = []) {
        self.splitMode = splitMode; self.childWeight = childWeight; self.myPartyId = myPartyId; self.totalCents = totalCents
        self.parties = parties; self.expenses = expenses; self.payments = payments; self.transfers = transfers
    }

    enum CodingKeys: String, CodingKey { case splitMode, childWeight, myPartyId, totalCents, parties, expenses, payments, transfers }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        splitMode = try c.decodeIfPresent(String.self, forKey: .splitMode) ?? "equal"
        childWeight = try c.decodeIfPresent(Double.self, forKey: .childWeight) ?? 1
        myPartyId = try c.decodeIfPresent(String.self, forKey: .myPartyId)
        totalCents = try c.decodeIfPresent(Int.self, forKey: .totalCents) ?? 0
        parties = try c.decodeIfPresent([LedgerParty].self, forKey: .parties) ?? []
        expenses = try c.decodeIfPresent([Expense].self, forKey: .expenses) ?? []
        payments = try c.decodeIfPresent([LedgerPayment].self, forKey: .payments) ?? []
        transfers = try c.decodeIfPresent([LedgerTransfer].self, forKey: .transfers) ?? []
    }

    public func name(of partyID: String?) -> String {
        parties.first { $0.id == partyID }?.name ?? "Entfernter Haushalt"
    }
}

/// The sums behind the sample data, the way the server reckons: shares per expense, balances, fewest settling payments.
public enum LedgerMath {
    /// The share of every household in one expense, in cents. nil when it cannot be shared.
    public static func shares(of expense: Expense, parties: [LedgerParty], splitMode: String, childWeight: Double) -> [String: Int]? {
        guard let payer = expense.paidBy, parties.contains(where: { $0.id == payer }) else { return nil }
        let among = expense.among ?? []
        let sharing = among.isEmpty ? parties : parties.filter { among.contains($0.id) }
        let mode = expense.mode ?? splitMode
        let weights: [(String, Double)] = sharing.map { party in
            switch mode {
            case "heads": (party.id, Double(party.adults) + Double(party.children) * childWeight)
            case "custom": (party.id, max(0, expense.weights?[party.id] ?? 0))
            default: (party.id, 1)
            }
        }
        let sum = weights.reduce(0) { $0 + $1.1 }
        guard sum > 0 else { return nil }
        // Whole cents, the leftover going to the largest remainders, so the shares add up exactly.
        var result: [String: Int] = [:]
        var rest: [(String, Double)] = []
        var given = 0
        for (id, weight) in weights {
            let exact = Double(expense.amountCents) * weight / sum
            let whole = Int(exact.rounded(.down))
            result[id] = whole; given += whole
            rest.append((id, exact - Double(whole)))
        }
        for (id, _) in rest.sorted(by: { $0.1 > $1.1 }).prefix(expense.amountCents - given) { result[id, default: 0] += 1 }
        return result
    }

    public static func ledger(parties: [LedgerParty], expenses: [Expense], payments: [LedgerPayment],
                              splitMode: String, childWeight: Double, myPartyId: String?) -> Ledger {
        var paid: [String: Int] = [:], share: [String: Int] = [:]
        var total = 0
        let marked = expenses.map { expense -> Expense in
            var expense = expense
            if let shares = shares(of: expense, parties: parties, splitMode: splitMode, childWeight: childWeight), let payer = expense.paidBy {
                paid[payer, default: 0] += expense.amountCents
                for (id, cents) in shares { share[id, default: 0] += cents }
                total += expense.amountCents
                expense.unsplit = false
            } else {
                expense.unsplit = true
            }
            return expense
        }
        var balance: [String: Int] = [:]
        for party in parties { balance[party.id] = paid[party.id, default: 0] - share[party.id, default: 0] }
        for payment in payments {
            balance[payment.fromParty, default: 0] += payment.amountCents
            balance[payment.toParty, default: 0] -= payment.amountCents
        }
        let rows = parties.map { party -> LedgerParty in
            var party = party
            party.paidCents = paid[party.id, default: 0]; party.shareCents = share[party.id, default: 0]; party.balanceCents = balance[party.id, default: 0]
            return party
        }
        return Ledger(splitMode: splitMode, childWeight: childWeight, myPartyId: myPartyId, totalCents: total, parties: rows,
                      expenses: marked, payments: payments, transfers: transfers(rows))
    }

    /// The largest debtor pays the largest creditor, until everyone is even.
    public static func transfers(_ parties: [LedgerParty]) -> [LedgerTransfer] {
        var open = parties.map { ($0.id, $0.balanceCents) }
        var result: [LedgerTransfer] = []
        while let debtor = open.indices.min(by: { open[$0].1 < open[$1].1 }), let creditor = open.indices.max(by: { open[$0].1 < open[$1].1 }),
              open[debtor].1 < 0, open[creditor].1 > 0 {
            let amount = min(-open[debtor].1, open[creditor].1)
            result.append(LedgerTransfer(from: open[debtor].0, to: open[creditor].0, amountCents: amount))
            open[debtor].1 += amount; open[creditor].1 -= amount
        }
        return result
    }
}

public extension Format {
    /// Money to the cent, for the shared purse.
    static func euroExact(cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "EUR").precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
    }

    /// Reads an amount as people type it: "84,50", "84.5", "1.234,00", "12 €". nil when it is no positive amount.
    static func cents(from text: String) -> Int? {
        var cleaned = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains(",") {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if let dot = cleaned.lastIndex(of: "."), cleaned.distance(from: dot, to: cleaned.endIndex) == 4 {
            // "1.234" is a thousand and something, not one euro and a bit.
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
        }
        guard cleaned.filter({ $0 == "." }).count <= 1, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        var scaled = value * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
