import Foundation

/// RFC 4180-ish CSV reader: quoted fields, doubled quotes, commas and new lines
/// inside quotes, CRLF, a UTF-8 BOM, and ragged rows.
public enum CSVReader {
    public static func rows(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case delimiter: row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        }
        return rows
    }

    /// Guesses ";" or tab for European exports, else ",".
    public static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let counts: [(Character, Int)] = [(",", firstLine.filter { $0 == "," }.count),
                                          (";", firstLine.filter { $0 == ";" }.count),
                                          ("\t", firstLine.filter { $0 == "\t" }.count)]
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }
}

public enum CSVDate {
    /// Tries UK-first formats. `hint` (e.g. "dd/MM/yyyy") is tried first.
    public static func parse(_ date: String, time: String? = nil, hint: String? = nil, timeZone: TimeZone) -> Date? {
        let d = date.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        if let iso = ISO8601.parse(d), d.contains("T") { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = timeZone
        let t = time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dateFormats = [hint, "dd/MM/yyyy", "d/M/yyyy", "dd/MM/yy", "yyyy-MM-dd", "dd-MM-yyyy", "dd.MM.yyyy", "d MMM yyyy",
                           "dd MMM yyyy", "MM/dd/yyyy"].compactMap { $0 }
        let timeFormats = t.isEmpty ? [""] : [" HH:mm:ss", " HH:mm"]
        for df in dateFormats {
            for tf in timeFormats {
                f.dateFormat = df + tf
                if let r = f.date(from: t.isEmpty ? d : d + " " + t) { return r }
                // Dates that already include a time ("12/10/2026 14:03").
                if t.isEmpty {
                    for extra in [" HH:mm:ss", " HH:mm"] {
                        f.dateFormat = df + extra
                        if let r = f.date(from: d) { return r }
                    }
                }
            }
        }
        return nil
    }
}

/// Imports the CSV the Monzo app exports (Account → Statements / Export transactions).
///
/// Columns: Transaction ID, Date (dd/MM/yyyy), Time, Type, Name, Emoji, Category, Amount,
/// Currency, Local amount, Local currency, Notes and #tags, Address, Receipt,
/// Description, Category split, Money Out, Money In. Missing columns are fine.
public enum MonzoCSVImporter {
    public struct Result: Sendable {
        public var transactions: [MoneyTransaction]
        public var skippedRows: Int
        public var warnings: [String]
    }

    public static func looksLikeMonzo(_ headers: [String]) -> Bool {
        let h = Set(headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return h.contains("transaction id") && h.contains("date") && (h.contains("amount") || h.contains("money out"))
    }

    public static func parse(_ text: String, accountID: String = "monzo-current",
                             timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) -> Result {
        let rows = CSVReader.rows(text, delimiter: CSVReader.detectDelimiter(text))
        guard let header = rows.first else { return Result(transactions: [], skippedRows: 0, warnings: ["The file is empty."]) }
        let index = Dictionary(header.enumerated().map { ($0.element.trimmingCharacters(in: .whitespaces).lowercased(), $0.offset) },
                               uniquingKeysWith: { a, _ in a })
        func col(_ row: [String], _ name: String) -> String? {
            guard let i = index[name], i < row.count else { return nil }
            let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        var warnings: [String] = []
        if !looksLikeMonzo(header) { warnings.append("This doesn't look like a Monzo export; try the generic CSV import.") }
        var out: [MoneyTransaction] = []
        var skipped = 0
        var seen: [String: Int] = [:]
        for row in rows.dropFirst() {
            guard let dateText = col(row, "date"),
                  let date = CSVDate.parse(dateText, time: col(row, "time"), hint: "dd/MM/yyyy", timeZone: timeZone) else {
                skipped += 1; continue
            }
            var amount = col(row, "amount").flatMap(MoneyFormat.parsePence)
            if amount == nil {
                let paidOut = col(row, "money out").flatMap(MoneyFormat.parsePence).map { -abs($0) } ?? 0
                let paidIn = col(row, "money in").flatMap(MoneyFormat.parsePence).map { abs($0) } ?? 0
                if paidOut != 0 || paidIn != 0 { amount = paidOut + paidIn }
            }
            guard let pence = amount else { skipped += 1; continue }
            let type = col(row, "type")
            let name = col(row, "name") ?? col(row, "description") ?? ""
            let t = (type ?? "").lowercased()
            let internalMove = t.contains("pot transfer") || t.contains("account transfer") || t == "savings"
                || (col(row, "category")?.lowercased() == "savings" && t.contains("pot"))
            let key = "\(accountID)|\(dateText)|\(col(row, "time") ?? "")|\(pence)|\(name)"
            seen[key, default: 0] += 1
            let id = col(row, "transaction id") ?? "csv-" + MD5.hex("\(key)|\(seen[key]!)")
            out.append(MoneyTransaction(
                id: id, accountID: accountID, date: date, amountPence: pence, currency: col(row, "currency") ?? "GBP",
                name: name, descriptionText: col(row, "description") ?? "", bankCategory: col(row, "category"), type: type,
                notes: col(row, "notes and #tags"), isPending: false, isDeclined: t.contains("declined"),
                isInternal: internalMove, source: .monzoCSV))
        }
        if skipped > 0 { warnings.append("Skipped \(skipped) row\(skipped == 1 ? "" : "s") without a readable date or amount.") }
        return Result(transactions: out, skippedRows: skipped, warnings: warnings)
    }
}

/// Column mapping for any bank's CSV.
public struct CSVColumnMapping: Codable, Hashable, Sendable {
    public var date: Int
    public var time: Int?
    /// e.g. "dd/MM/yyyy"; nil tries the usual UK formats.
    public var dateFormat: String?
    public var name: Int
    public var description: Int?
    /// One signed amount column…
    public var amount: Int?
    /// …or separate money out / money in columns.
    public var moneyOut: Int?
    public var moneyIn: Int?
    public var category: Int?
    public var id: Int?
    /// Flip the sign when the bank shows spending as positive.
    public var invertAmounts: Bool

    public init(date: Int, time: Int? = nil, dateFormat: String? = nil, name: Int, description: Int? = nil, amount: Int? = nil,
                moneyOut: Int? = nil, moneyIn: Int? = nil, category: Int? = nil, id: Int? = nil, invertAmounts: Bool = false) {
        self.date = date; self.time = time; self.dateFormat = dateFormat; self.name = name; self.description = description
        self.amount = amount; self.moneyOut = moneyOut; self.moneyIn = moneyIn; self.category = category; self.id = id
        self.invertAmounts = invertAmounts
    }

    public var isComplete: Bool { amount != nil || moneyOut != nil || moneyIn != nil }
}

public enum GenericCSVImporter {
    /// A best guess at the mapping from header names (the UI lets the student fix it).
    public static func suggestMapping(_ headers: [String]) -> CSVColumnMapping? {
        let h = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func find(_ names: [String], fuzzy: Bool = true) -> Int? {
            for n in names { if let i = h.firstIndex(of: n) { return i } }
            guard fuzzy else { return nil }
            for n in names where n.count > 3 { if let i = h.firstIndex(where: { $0.contains(n) }) { return i } }
            return nil
        }
        guard let date = find(["date", "transaction date", "posted date", "completed date", "value date"]) else { return nil }
        let name = find(["name", "merchant", "payee", "counterparty", "description", "details", "narrative", "reference"]) ?? date
        var description = find(["description", "details", "reference", "narrative", "memo"])
        if description == name { description = nil }
        return CSVColumnMapping(
            date: date, time: find(["time"]), name: name, description: description,
            amount: find(["amount", "value", "amount (gbp)", "transaction amount"]),
            moneyOut: find(["money out", "paid out", "debit", "withdrawals", "out"]),
            moneyIn: find(["money in", "paid in", "credit", "deposits", "in"]),
            category: find(["category", "type"]), id: find(["transaction id", "id", "reference number"], fuzzy: false))
    }

    public static func parse(_ text: String, mapping: CSVColumnMapping, accountID: String, hasHeader: Bool = true,
                             timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) -> MonzoCSVImporter.Result {
        let rows = CSVReader.rows(text, delimiter: CSVReader.detectDelimiter(text))
        var out: [MoneyTransaction] = []
        var skipped = 0
        func cell(_ row: [String], _ i: Int?) -> String? {
            guard let i, i < row.count else { return nil }
            let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        var seen: [String: Int] = [:]
        for row in rows.dropFirst(hasHeader ? 1 : 0) {
            guard let dateText = cell(row, mapping.date),
                  let date = CSVDate.parse(dateText, time: cell(row, mapping.time), hint: mapping.dateFormat, timeZone: timeZone) else {
                skipped += 1; continue
            }
            var pence: Int?
            if let a = cell(row, mapping.amount).flatMap(MoneyFormat.parsePence) {
                pence = mapping.invertAmounts ? -a : a
            } else {
                let o = cell(row, mapping.moneyOut).flatMap(MoneyFormat.parsePence).map { -abs($0) } ?? 0
                let i = cell(row, mapping.moneyIn).flatMap(MoneyFormat.parsePence).map { abs($0) } ?? 0
                if o != 0 || i != 0 { pence = o + i }
            }
            guard let amount = pence else { skipped += 1; continue }
            let name = cell(row, mapping.name) ?? ""
            // Same day, amount and payee twice in one file → numbered, so re-imports still match.
            let key = "\(accountID)|\(dateText)|\(cell(row, mapping.time) ?? "")|\(amount)|\(name)"
            seen[key, default: 0] += 1
            let id = cell(row, mapping.id).map { "\(accountID)-\($0)" } ?? "csv-" + MD5.hex("\(key)|\(seen[key]!)")
            out.append(MoneyTransaction(id: id, accountID: accountID, date: date, amountPence: amount, name: name,
                                        descriptionText: cell(row, mapping.description) ?? "",
                                        bankCategory: cell(row, mapping.category), source: .csv))
        }
        return MonzoCSVImporter.Result(transactions: out, skippedRows: skipped,
                                       warnings: skipped > 0 ? ["Skipped \(skipped) row\(skipped == 1 ? "" : "s") without a readable date or amount."] : [])
    }
}
