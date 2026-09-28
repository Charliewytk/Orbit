import Foundation

/// Company name → web domain, used to show firm logos (favicons) in Careers.
///
/// Trackr's company names vary ("J.P. Morgan", "JPMorgan Chase & Co.", "Goldman
/// Sachs", "Bank of America Merrill Lynch"…), so names are normalised (lowercased,
/// punctuation and legal suffixes removed) and matched against a dictionary of
/// the ~130 firms students see most, then against a few prefix rules. Anything
/// else falls back to a guess: "<name without spaces>.com".
public enum FirmDomains {
    /// Normalised name → domain.
    static let known: [String: String] = {
        let pairs: [(String, String)] = [
            // Bulge bracket and big banks
            ("jp morgan", "jpmorgan.com"), ("jpmorgan", "jpmorgan.com"), ("jpmorganchase", "jpmorgan.com"),
            ("jpmorgan chase", "jpmorgan.com"), ("chase", "jpmorgan.com"),
            ("goldman sachs", "goldmansachs.com"), ("goldman", "goldmansachs.com"),
            ("morgan stanley", "morganstanley.com"), ("barclays", "barclays.com"), ("hsbc", "hsbc.com"),
            ("citi", "citi.com"), ("citigroup", "citi.com"), ("citibank", "citi.com"),
            ("deutsche bank", "db.com"), ("ubs", "ubs.com"), ("credit suisse", "ubs.com"),
            ("bank of america", "bankofamerica.com"), ("bofa", "bankofamerica.com"),
            ("bank of america merrill lynch", "bankofamerica.com"), ("bofa securities", "bankofamerica.com"),
            ("merrill lynch", "bankofamerica.com"),
            ("bnp paribas", "bnpparibas.com"), ("societe generale", "societegenerale.com"),
            ("nomura", "nomura.com"), ("mizuho", "mizuhogroup.com"), ("mufg", "mufg.jp"), ("smbc", "smbcgroup.com"),
            ("jefferies", "jefferies.com"), ("macquarie", "macquarie.com"), ("macquarie group", "macquarie.com"),
            ("rbc", "rbccm.com"), ("rbc capital markets", "rbccm.com"), ("royal bank of canada", "rbccm.com"),
            ("santander", "santander.co.uk"), ("natwest", "natwest.com"), ("natwest group", "natwest.com"),
            ("lloyds", "lloydsbankinggroup.com"), ("lloyds banking group", "lloydsbankinggroup.com"),
            ("standard chartered", "sc.com"), ("ing", "ing.com"), ("wells fargo", "wellsfargo.com"),
            ("td securities", "tdsecurities.com"), ("bmo", "bmo.com"), ("scotiabank", "scotiabank.com"),
            ("hsbc global banking and markets", "hsbc.com"), ("investec", "investec.com"), ("nationwide", "nationwide.co.uk"),
            ("bank of england", "bankofengland.co.uk"), ("european investment bank", "eib.org"), ("ebrd", "ebrd.com"),
            ("coutts", "coutts.com"), ("virgin money", "virginmoney.com"), ("monzo", "monzo.com"), ("revolut", "revolut.com"),
            // Elite boutiques and advisory
            ("rothschild", "rothschildandco.com"), ("rothschild co", "rothschildandco.com"),
            ("evercore", "evercore.com"), ("lazard", "lazard.com"), ("pjt partners", "pjtpartners.com"),
            ("centerview", "centerviewpartners.com"), ("centerview partners", "centerviewpartners.com"),
            ("moelis", "moelis.com"), ("perella weinberg", "pwpartners.com"), ("perella weinberg partners", "pwpartners.com"),
            ("guggenheim", "guggenheimpartners.com"), ("houlihan lokey", "hl.com"), ("greenhill", "greenhill.com"),
            ("qatalyst", "qatalyst.com"), ("robey warshaw", "robeywarshaw.com"), ("numis", "numis.com"),
            ("peel hunt", "peelhunt.com"), ("stifel", "stifel.com"), ("william blair", "williamblair.com"),
            ("lincoln international", "lincolninternational.com"), ("alantra", "alantra.com"), ("dc advisory", "dcadvisory.com"),
            ("ondra partners", "ondra.com"), ("liontree", "liontree.com"),
            // Buy side
            ("blackstone", "blackstone.com"), ("kkr", "kkr.com"), ("carlyle", "carlyle.com"), ("the carlyle group", "carlyle.com"),
            ("apollo", "apollo.com"), ("apollo global management", "apollo.com"), ("bain capital", "baincapital.com"),
            ("tpg", "tpg.com"), ("cvc", "cvc.com"), ("cvc capital partners", "cvc.com"), ("eqt", "eqtgroup.com"),
            ("permira", "permira.com"), ("cinven", "cinven.com"), ("ardian", "ardian.com"), ("3i", "3i.com"),
            ("hg", "hgcapital.com"), ("hgcapital", "hgcapital.com"), ("bridgepoint", "bridgepoint.eu"),
            ("ares", "aresmgmt.com"), ("ares management", "aresmgmt.com"), ("blackrock", "blackrock.com"),
            ("pimco", "pimco.com"), ("schroders", "schroders.com"), ("fidelity", "fidelity.co.uk"),
            ("fidelity international", "fidelityinternational.com"), ("vanguard", "vanguard.co.uk"),
            ("m g", "mandg.com"), ("mandg", "mandg.com"), ("m and g", "mandg.com"), ("legal general", "legalandgeneral.com"),
            ("legal and general", "legalandgeneral.com"), ("aviva", "aviva.com"), ("aviva investors", "avivainvestors.com"),
            ("abrdn", "abrdn.com"), ("baillie gifford", "bailliegifford.com"), ("invesco", "invesco.com"),
            ("jupiter", "jupiteram.com"), ("man group", "man.com"), ("man", "man.com"), ("marshall wace", "marshallwace.com"),
            ("millennium", "mlp.com"), ("millennium management", "mlp.com"), ("citadel", "citadel.com"),
            ("citadel securities", "citadelsecurities.com"), ("point72", "point72.com"), ("capula", "capula.com"),
            ("brevan howard", "brevanhoward.com"), ("bridgewater", "bridgewater.com"), ("bridgewater associates", "bridgewater.com"),
            ("d e shaw", "deshaw.com"), ("de shaw", "deshaw.com"), ("two sigma", "twosigma.com"), ("balyasny", "bamfunds.com"),
            ("state street", "statestreet.com"), ("northern trust", "northerntrust.com"), ("bny", "bny.com"),
            ("bny mellon", "bny.com"), ("goldman sachs asset management", "goldmansachs.com"), ("pgim", "pgim.com"),
            ("wellington", "wellington.com"), ("wellington management", "wellington.com"), ("t rowe price", "troweprice.com"),
            ("allianz", "allianz.com"), ("allianz global investors", "allianzgi.com"), ("axa", "axa.com"),
            ("nuveen", "nuveen.com"), ("brookfield", "brookfield.com"), ("icg", "icgam.com"), ("intermediate capital group", "icgam.com"),
            ("partners group", "partnersgroup.com"), ("general atlantic", "generalatlantic.com"), ("warburg pincus", "warburgpincus.com"),
            ("silver lake", "silverlake.com"), ("advent international", "adventinternational.com"), ("advent", "adventinternational.com"),
            ("hellman friedman", "hf.com"), ("thoma bravo", "thomabravo.com"), ("vitol", "vitol.com"), ("trafigura", "trafigura.com"),
            // Trading and quant
            ("jane street", "janestreet.com"), ("optiver", "optiver.com"), ("imc", "imc.com"), ("imc trading", "imc.com"),
            ("drw", "drw.com"), ("hudson river trading", "hudsonrivertrading.com"), ("hrt", "hudsonrivertrading.com"),
            ("g research", "gresearch.com"), ("gresearch", "gresearch.com"), ("sig", "sig.com"),
            ("susquehanna", "sig.com"), ("susquehanna international group", "sig.com"), ("flow traders", "flowtraders.com"),
            ("xtx markets", "xtxmarkets.com"), ("xtx", "xtxmarkets.com"), ("jump trading", "jumptrading.com"),
            ("tower research", "tower-research.com"), ("tower research capital", "tower-research.com"), ("virtu", "virtu.com"),
            ("maven securities", "mavensecurities.com"), ("da vinci", "davincitrading.com"), ("qube", "qube-rt.com"),
            ("squarepoint", "squarepoint-capital.com"), ("five rings", "fiverings.com"), ("akuna", "akunacapital.com"),
            // Consulting and professional services
            ("mckinsey", "mckinsey.com"), ("mckinsey company", "mckinsey.com"), ("bcg", "bcg.com"),
            ("boston consulting group", "bcg.com"), ("bain", "bain.com"), ("bain company", "bain.com"),
            ("deloitte", "deloitte.com"), ("pwc", "pwc.com"), ("pricewaterhousecoopers", "pwc.com"), ("ey", "ey.com"),
            ("ernst young", "ey.com"), ("kpmg", "kpmg.com"), ("accenture", "accenture.com"), ("oliver wyman", "oliverwyman.com"),
            ("lek", "lek.com"), ("l e k consulting", "lek.com"), ("lek consulting", "lek.com"), ("kearney", "kearney.com"),
            ("roland berger", "rolandberger.com"), ("grant thornton", "grantthornton.co.uk"), ("bdo", "bdo.co.uk"),
            ("rsm", "rsmuk.com"), ("fti consulting", "fticonsulting.com"), ("alvarez marsal", "alvarezandmarsal.com"),
            ("alvarez and marsal", "alvarezandmarsal.com"), ("teneo", "teneo.com"), ("capgemini", "capgemini.com"),
            ("ibm", "ibm.com"), ("frontier economics", "frontier-economics.com"), ("oxera", "oxera.com"),
            ("compass lexecon", "compasslexecon.com"), ("nera", "nera.com"), ("cra", "crai.com"),
            // Ratings, data, exchanges, payments
            ("moodys", "moodys.com"), ("s and p global", "spglobal.com"), ("s p global", "spglobal.com"), ("sp global", "spglobal.com"), ("fitch", "fitchratings.com"),
            ("fitch ratings", "fitchratings.com"), ("bloomberg", "bloomberg.com"), ("lseg", "lseg.com"),
            ("london stock exchange group", "lseg.com"), ("ice", "ice.com"), ("cme group", "cmegroup.com"),
            ("msci", "msci.com"), ("visa", "visa.com"), ("mastercard", "mastercard.com"),
            ("american express", "americanexpress.com"), ("amex", "americanexpress.com"), ("paypal", "paypal.com"),
            ("stripe", "stripe.com"), ("wise", "wise.com"), ("klarna", "klarna.com"),
            // Corporates and insurers
            ("glencore", "glencore.com"), ("bp", "bp.com"), ("shell", "shell.com"), ("sky", "sky.com"),
            ("unilever", "unilever.com"), ("gsk", "gsk.com"), ("astrazeneca", "astrazeneca.com"), ("diageo", "diageo.com"),
            ("rio tinto", "riotinto.com"), ("bhp", "bhp.com"), ("google", "google.com"), ("amazon", "amazon.com"),
            ("microsoft", "microsoft.com"), ("apple", "apple.com"), ("meta", "meta.com"), ("prudential", "prudentialplc.com"),
            ("lloyds of london", "lloyds.com"), ("zurich", "zurich.co.uk"), ("hiscox", "hiscox.com"), ("beazley", "beazley.com"),
            ("munich re", "munichre.com"), ("swiss re", "swissre.com"), ("aon", "aon.com"), ("marsh", "marsh.com"),
            ("wtw", "wtwco.com"), ("willis towers watson", "wtwco.com"), ("mercer", "mercer.com"),
            ("tesco", "tesco.com"), ("unite students", "unitestudents.com"), ("rolls royce", "rolls-royce.com"),
            ("bae systems", "baesystems.com"), ("siemens", "siemens.com"), ("ford", "ford.com"),
            ("hmt", "gov.uk"), ("hm treasury", "gov.uk"), ("civil service", "gov.uk"), ("government economic service", "gov.uk"),
            ("fca", "fca.org.uk"), ("financial conduct authority", "fca.org.uk"),
            // Access programmes that show up as "companies"
            ("seo london", "seo-london.org"), ("upreach", "upreach.org.uk"), ("rare", "rarerecruitment.co.uk"),
            ("10000 black interns", "10000blackinterns.com"), ("social mobility foundation", "socialmobility.org.uk"),
            ("bright network", "brightnetwork.co.uk"), ("girls who invest", "girlswhoinvest.org"),
        ]
        var out: [String: String] = [:]
        for (name, domain) in pairs { out[normalise(name)] = domain }
        return out
    }()

    /// Firms shown in onboarding and the Careers empty state (display name, domain).
    public static let popular: [(name: String, domain: String)] = [
        ("J.P. Morgan", "jpmorgan.com"), ("Goldman Sachs", "goldmansachs.com"), ("Morgan Stanley", "morganstanley.com"),
        ("Barclays", "barclays.com"), ("HSBC", "hsbc.com"), ("Citi", "citi.com"), ("Deutsche Bank", "db.com"),
        ("UBS", "ubs.com"), ("Bank of America", "bankofamerica.com"), ("BNP Paribas", "bnpparibas.com"),
        ("Rothschild & Co", "rothschildandco.com"), ("Evercore", "evercore.com"), ("Lazard", "lazard.com"),
        ("PJT Partners", "pjtpartners.com"), ("Blackstone", "blackstone.com"), ("BlackRock", "blackrock.com"),
        ("Citadel", "citadel.com"), ("Jane Street", "janestreet.com"), ("Optiver", "optiver.com"), ("IMC", "imc.com"),
        ("Point72", "point72.com"), ("McKinsey", "mckinsey.com"), ("BCG", "bcg.com"), ("Bain", "bain.com"),
        ("Deloitte", "deloitte.com"), ("PwC", "pwc.com"), ("EY", "ey.com"), ("KPMG", "kpmg.com"),
    ]

    /// Legal and filler words dropped before matching.
    static let fillerWords: Set<String> = [
        "the", "and", "co", "company", "companies", "plc", "ltd", "limited", "llp", "llc", "inc", "incorporated",
        "corp", "corporation", "group", "holdings", "sa", "ag", "nv", "se", "uk", "emea", "europe", "international",
        "global", "london", "bank", "banking", "partners", "securities", "capital", "markets", "asset", "management",
        "investments", "investment", "advisors", "advisers", "llc.", "services", "financial",
    ]

    /// Lowercased, accents and punctuation removed, "&" → "and", single spaces.
    public static func normalise(_ name: String) -> String {
        var s = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        s = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return s.split(separator: " ").joined(separator: " ")
    }

    /// The domain for a company name.
    public static func domain(for company: String) -> String {
        let n = normalise(company)
        guard !n.isEmpty else { return "example.com" }
        if let d = known[n] { return d }
        // "J.P. Morgan" → "j p morgan": also try with the spaces between single letters removed.
        let joinedInitials = joinSingleLetters(n)
        if let d = known[joinedInitials] { return d }
        // Drop legal / filler words ("Barclays Bank PLC", "Evercore Partners International").
        let core = n.split(separator: " ").filter { !fillerWords.contains(String($0)) }.joined(separator: " ")
        if !core.isEmpty {
            if let d = known[core] ?? known[joinSingleLetters(core)] { return d }
        }
        // Longest known prefix ("goldman sachs asset management" → "goldman sachs").
        let words = n.split(separator: " ").map(String.init)
        if words.count > 1 {
            for length in stride(from: words.count - 1, through: 1, by: -1) {
                let prefix = words.prefix(length).joined(separator: " ")
                if let d = known[prefix] ?? known[joinSingleLetters(prefix)] { return d }
            }
        }
        return guess(core.isEmpty ? n : core)
    }

    /// Whether the domain came from the dictionary rather than a guess.
    public static func isKnown(_ company: String) -> Bool {
        let d = domain(for: company)
        return known.values.contains(d)
    }

    /// Favicon URL (Google's service; 128 px).
    public static func logoURL(for company: String, size: Int = 128) -> URL? {
        URL(string: "https://www.google.com/s2/favicons?domain=\(domain(for: company))&sz=\(size)")
    }

    /// One or two letters for a monogram ("Goldman Sachs" → "GS", "Nomura" → "N").
    public static func monogram(_ company: String) -> String {
        let words = normalise(company).split(separator: " ").filter { !fillerWords.contains(String($0)) || $0.count <= 3 }
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        if letters.isEmpty { return String(company.prefix(1)).uppercased() }
        return letters.joined()
    }

    /// A stable hue (0–1) for the monogram circle.
    public static func hue(for company: String) -> Double {
        let hash = normalise(company).unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Double(hash % 360) / 360
    }

    // MARK: Helpers

    private static func joinSingleLetters(_ s: String) -> String {
        var out: [String] = []
        var run = ""
        for word in s.split(separator: " ") {
            if word.count == 1 { run += word } else {
                if !run.isEmpty { out.append(run); run = "" }
                out.append(String(word))
            }
        }
        if !run.isEmpty { out.append(run) }
        return out.joined(separator: " ")
    }

    private static func guess(_ normalised: String) -> String {
        let compact = normalised.replacingOccurrences(of: " ", with: "")
        return (compact.isEmpty ? "example" : compact) + ".com"
    }
}
