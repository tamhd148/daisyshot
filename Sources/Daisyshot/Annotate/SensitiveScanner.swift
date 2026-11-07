import AppKit
import CoreText
import Vision

/// What Auto Redact looks for. Each kind is a group the user turns on or off (Settings › Screenshots).
enum SensitiveKind: String, CaseIterable, Codable {
    case secret, password, email, phone, card, nationalID, account, ip, urlToken, face, custom

    var title: String {
        switch self {
        case .secret: return "Secrets & API keys"
        case .password: return "Passwords"
        case .email: return "Emails"
        case .phone: return "Phone numbers"
        case .card: return "Card numbers"
        case .nationalID: return "ID numbers (CCCD/CMND)"
        case .account: return "Bank accounts"
        case .ip: return "IP addresses"
        case .urlToken: return "Tokens in URLs"
        case .face: return "Faces"
        case .custom: return "Custom patterns"
        }
    }

    /// Singular / plural noun for messages ("2 API keys").
    func noun(_ n: Int) -> String {
        let one: String, many: String
        switch self {
        case .secret: (one, many) = ("%d API key", "%d API keys")
        case .password: (one, many) = ("%d password", "%d passwords")
        case .card: (one, many) = ("%d card number", "%d card numbers")
        default: (one, many) = ("%d item", "%d items")
        }
        return (n == 1 ? one : many).loc(n)
    }

    /// Off at install: noisy (IP addresses) or not text (faces).
    var defaultOn: Bool { self != .ip && self != .face }
    /// Kinds that trigger the copy / share warning.
    var isDangerous: Bool { self == .secret || self == .password || self == .card }
    var key: Prefs.Key { Prefs.Key("autoRedact.\(rawValue)", defaultOn) }
    /// Custom patterns are on whenever the user has written some.
    var isEnabled: Bool { self == .custom || Prefs.bool(key) }
}

struct SensitiveFinding: Equatable, Sendable {
    let kind: SensitiveKind
    let rect: CGRect   // image points, top-left origin, already padded
    let text: String
}

/// Finds sensitive text (OCR via the shared `TextScan`) and faces in a screenshot. Pure string matching is in
/// `SensitiveMatcher`; this adds geometry: only the matched substring is boxed, never the whole line.
@MainActor
enum SensitiveScanner {
    /// Points added on every side of a box so glyph edges don't peek out.
    nonisolated static let padding: CGFloat = 2

    private static var cache: (image: CGImage, patterns: String, task: Task<[SensitiveFinding], Never>)?

    /// Every kind is reported (the panel shows disabled groups unticked); callers filter with `isEnabled`.
    /// Cached per image + custom patterns, so re-running Auto or the copy warning never rescans.
    static func scan(_ image: CGImage, size: CGSize) async -> [SensitiveFinding] {
        let patterns = Prefs.string(.autoRedactCustomPatterns)
        if let c = cache, c.image === image, c.patterns == patterns { return await c.task.value }
        let matcher = SensitiveMatcher(custom: patterns)
        let task = Task<[SensitiveFinding], Never> {
            async let faces = Task.detached(priority: .userInitiated) { detectFaces(image, size: size) }.value
            let lines = await TextScan.lines(image, size: size)
            let text = await Task.detached(priority: .userInitiated) { findings(in: lines, matcher) }.value
            return text + (await faces)
        }
        cache = (image, patterns, task)
        return await task.value
    }

    nonisolated static func findings(in lines: [ScannedLine], _ matcher: SensitiveMatcher) -> [SensitiveFinding] {
        var out: [SensitiveFinding] = []
        // PEM private keys span several lines: everything between BEGIN … PRIVATE KEY and END is the key.
        var inKey = false
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            if line.text.range(of: #"BEGIN[A-Z ]*PRIVATE KEY"#, options: .regularExpression) != nil { inKey = true }
            else if inKey, line.text.contains("END") { inKey = false }
            else if inKey { out.append(SensitiveFinding(kind: .secret, rect: line.rect.insetBy(dx: -padding, dy: -padding), text: line.text)) }
        }
        for line in lines {
            for m in matcher.matches(line.text) {
                guard let r = Range(m.range, in: line.text), let box = line.box(r) else { continue }
                out.append(SensitiveFinding(kind: m.kind, rect: box.insetBy(dx: -padding, dy: -padding), text: String(line.text[r])))
            }
        }
        return out
    }

    nonisolated static func detectFaces(_ image: CGImage, size: CGSize) -> [SensitiveFinding] {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).map { o in
            let r = TextScan.convert(o.boundingBox, size)
            return SensitiveFinding(kind: .face, rect: r.insetBy(dx: -r.width * 0.12, dy: -r.height * 0.12), text: "")
        }
    }
}

// MARK: - Substring boxes

extension ScannedLine {
    /// Box of `range`. Vision only boxes whole words (`OPENAI_API_KEY=sk-…` is one word), so a range inside a word is
    /// cut out of the word's box by measuring the text in the font that best explains the line's word widths.
    func box(_ range: Range<String.Index>) -> CGRect? {
        var lo = range.lowerBound, hi = range.upperBound
        while lo > text.startIndex, !text[text.index(before: lo)].isWhitespace { lo = text.index(before: lo) }
        while hi < text.endIndex, !text[hi].isWhitespace { hi = text.index(after: hi) }
        guard let words = rect(for: lo ..< hi) else { return nil }
        if lo == range.lowerBound, hi == range.upperBound { return words }
        let total = String(text[lo ..< hi]), head = String(text[lo ..< range.lowerBound]), tail = String(text[range.upperBound ..< hi])
        func cut(_ font: CTFont) -> (CGFloat, CGFloat) {
            let w = max(Self.width(total, font), 0.001)
            return (words.minX + words.width * Self.width(head, font) / w, words.maxX - words.width * Self.width(tail, font) / w)
        }
        let edges: (CGFloat, CGFloat)
        if let font = fittingFont { edges = cut(font) } else {
            // Can't tell: take the outer edges of both guesses (redacting a glyph too many beats leaking one).
            let a = cut(Self.mono), b = cut(Self.proportional)
            edges = (min(a.0, b.0), max(a.1, b.1))
        }
        // Estimated edges err outwards by a third of a character, so no glyph of the match is left showing.
        let slack = words.width / CGFloat(max(total.count, 1)) / 3
        let x0 = head.isEmpty ? words.minX : edges.0 - slack, x1 = tail.isEmpty ? words.maxX : edges.1 + slack
        return CGRect(x: x0, y: words.minY, width: max(1, x1 - x0), height: words.height)
    }

    /// Monospaced or proportional: whichever better predicts where this line's words start and end (needs 2+ words;
    /// the spaces between words tell the two apart even when the words alone don't).
    private var fittingFont: CTFont? {
        var words: [(Range<String.Index>, CGRect)] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard !text[i].isWhitespace else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            if let r = rect(for: i ..< j) { words.append((i ..< j, r)) }
            i = j
        }
        guard words.count >= 2, let first = words.first?.0.lowerBound, let last = words.last?.0.upperBound else { return nil }
        let span = words.last!.1.maxX - words.first!.1.minX
        func error(_ font: CTFont) -> CGFloat {
            let k = span / max(Self.width(String(text[first ..< last]), font), 0.001)
            func x(_ at: String.Index) -> CGFloat { words[0].1.minX + k * Self.width(String(text[first ..< at]), font) }
            return words.map { abs($0.1.minX - x($0.0.lowerBound)) + abs($0.1.maxX - x($0.0.upperBound)) }.reduce(0, +)
        }
        let m = error(Self.mono), p = error(Self.proportional)
        guard abs(m - p) > 0.15 * min(m, p) + 1 else { return nil }
        return m < p ? Self.mono : Self.proportional
    }

    private static let mono = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    private static let proportional = CTFontCreateUIFontForLanguage(.system, 12, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)

    private static func width(_ s: String, _ font: CTFont) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - Pure matching

/// Regex rules over one line of OCR text. Rules are tried in table order; a match inside an earlier one is dropped,
/// so order is priority (a card number is never also reported as a phone number).
struct SensitiveMatcher: Sendable {
    struct Match: Equatable { let kind: SensitiveKind; let range: NSRange }

    private struct Rule: @unchecked Sendable {   // NSRegularExpression is immutable and thread-safe
        let kind: SensitiveKind
        let regex: NSRegularExpression
        var group = 0
        var check: (@Sendable (String) -> Bool)? = nil
    }

    /// OCR confusions (O/0, l/1/I, S/5) as character classes, for fixed key prefixes: `fz("AKIA")` also matches `AKlA`.
    private static func fz(_ s: String) -> String {
        s.map { c -> String in
            switch c {
            case "O", "0": return "[O0o]"
            case "o": return "[o0O]"
            case "I", "l", "1": return "[Il1|]"
            case "S", "5": return "[S5]"
            case "s": return "[s5S]"
            default: return NSRegularExpression.escapedPattern(for: String(c))
            }
        }.joined()
    }

    /// Before a key prefix: not glued to a preceding word.
    private static let start = #"(?<![A-Za-z0-9_])"#

    /// The table. To add a pattern, add a row.
    private static let rules: [Rule] = {
        func r(_ kind: SensitiveKind, _ p: String, group: Int = 0, _ check: (@Sendable (String) -> Bool)? = nil) -> Rule {
            Rule(kind: kind, regex: try! NSRegularExpression(pattern: p), group: group, check: check)
        }
        let key = "[A-Za-z0-9_-]"
        return [
            // Secrets: provider prefixes (OCR-tolerant), then labelled high-entropy values.
            r(.secret, start + fz("sk-ant-") + key + "{20,}"),
            r(.secret, start + fz("sk-") + "(?:proj-|svcacct-)?" + key + "{20,}", { looksRandom($0) }),
            r(.secret, start + "gh[pousr]_[A-Za-z0-9]{30,}"),
            r(.secret, start + "github_pat_[A-Za-z0-9_]{30,}"),
            r(.secret, start + "(?:" + fz("AKIA") + "|" + fz("ASIA") + ")[A-Za-z0-9]{16}(?![A-Za-z0-9])"),
            r(.secret, start + "xox[abposr]-[A-Za-z0-9-]{10,}"),
            r(.secret, start + fz("AIza") + key + "{30,}"),
            r(.secret, start + "[sr]k_(?:live|test)_[0-9A-Za-z]{16,}"),
            r(.secret, start + "eyJ" + key + "{10,}(?:\\." + key + "{4,}){1,2}"),
            r(.secret, #"BEGIN[A-Z ]*PRIVATE KEY-*\s*([A-Za-z0-9+/=]{16,})"#, group: 1),
            r(.secret, #"(?i)(?:api[_-]?key|access[_-]?key|secret|token|password|passwd|bearer|authorization|auth|key)["']?(?:\s*[:=]\s*|\s+)["']?(?:bearer\s+)?([A-Za-z0-9_\-+/=.~]{24,})"#,
              group: 1, { looksRandom($0) }),
            // Passwords: only the value after the label.
            r(.password, #"(?<![A-Za-z])(?:(?i:password|passwd|passcode|pwd|mật khẩu|mat khau)|PASS)["']?\s*[:=]\s*["']?([^\s"']{3,})"#,
              group: 1, { !$0.allSatisfy { "•*●·.".contains($0) } }),
            // Tokens in URLs: only the parameter value.
            r(.urlToken, #"[?&#](?i:access_token|refresh_token|id_token|token|api_key|apikey|key|secret|client_secret|password|pwd|sig|signature|auth|code|session|sessionid|sid|jwt)=([^&#\s]{4,})"#, group: 1),
            // Cards: 13–19 digits (OCR letters allowed) in card-like groups, valid Luhn and a card network's first digit.
            r(.card, #"(?<![A-Za-z0-9])(?:C{4}[ -]?C{6}[ -]?C{4,5}|(?:C{4}[ -]?){2,4}C{1,4}|C{13,19})(?![A-Za-z0-9])"#
                .replacingOccurrences(of: "C", with: "[0-9OolIS]"), { isCard($0) }),
            // ID / account numbers only next to their label.
            r(.nationalID, #"(?i)(?:CCCD|CMND|CMT|căn cước|can cuoc|chứng minh|chung minh)[^0-9\n]{0,24}?(\d{12}|\d{9}|\d{3}[ .]\d{3}[ .]\d{3}(?:[ .]\d{3})?)(?![0-9])"#, group: 1),
            r(.account, #"(?i)(?:STK|số tài khoản|so tai khoan|số TK|account(?:\s*(?:number|no\.?|#))?|acct(?:\s*(?:no\.?|#))?|A/C)(?![A-Za-z])[^0-9\n]{0,20}?((?:\d ?){7,18}\d)(?![0-9])"#, group: 1),
            r(.account, #"(?<![A-Za-z])IBAN[^A-Z0-9\n]{0,6}([A-Z]{2}\d{2}(?: ?[A-Z0-9]){10,30})"#, group: 1),
            r(.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#),
            // Vietnamese mobiles; other numbers come from NSDataDetector below.
            r(.phone, #"(?<![0-9+])(?:\+84[ .-]?|0)[35789](?:[ .-]?[0-9]){8}(?![0-9])"#),
            r(.ip, #"(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])"#, { isIP($0, v6: false) }),
            r(.ip, #"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"#, { isIP($0, v6: true) }),
        ]
    }()

    private static let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    private let custom: [NSRegularExpression]

    /// `custom`: one pattern per line, a keyword (case-insensitive) or `/regex/` (`/regex/i` for case-insensitive).
    init(custom: String = "") {
        self.custom = custom.split(whereSeparator: \.isNewline).compactMap { Self.customRegex(String($0)) }
    }

    static func customRegex(_ line: String) -> NSRegularExpression? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.count > 2, s.hasPrefix("/"), let end = s.lastIndex(of: "/"), end > s.startIndex {
            let body = String(s[s.index(after: s.startIndex) ..< end]), flags = s[s.index(after: end)...]
            return try? NSRegularExpression(pattern: body, options: flags.contains("i") ? [.caseInsensitive] : [])
        }
        return try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: s), options: [.caseInsensitive])
    }

    func matches(_ text: String) -> [Match] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        var out: [Match] = []
        func add(_ kind: SensitiveKind, _ r: NSRange) {
            guard r.location != NSNotFound, r.length > 0, !out.contains(where: { NSIntersectionRange($0.range, r) == r }) else { return }
            out.append(Match(kind: kind, range: r))
        }
        for rule in Self.rules {
            for m in rule.regex.matches(in: text, range: all) {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound, rule.check?(ns.substring(with: r)) ?? true else { continue }
                add(rule.kind, r)
            }
        }
        for m in Self.phoneDetector?.matches(in: text, range: all) ?? [] {
            let digits = ns.substring(with: m.range).filter(\.isNumber).count
            if (9 ... 15).contains(digits) { add(.phone, m.range) }
        }
        for re in custom { for m in re.matches(in: text, range: all) { add(.custom, m.range) } }
        return out
    }

    // MARK: Checks

    /// Random-looking token: letters and digits mixed, high character entropy.
    static func looksRandom(_ s: String) -> Bool {
        guard s.count >= 16, s.contains(where: \.isLetter), s.contains(where: \.isNumber) else { return false }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        let entropy = counts.values.reduce(0.0) { e, k in let p = Double(k) / n; return e - p * log2(p) }
        return entropy >= 3.0
    }

    /// OCR-normalised digits pass Luhn, start like a card network (2–6) and are mostly real digits.
    static func isCard(_ s: String) -> Bool {
        let raw = s.filter { $0 != " " && $0 != "-" }
        guard raw.filter(\.isNumber).count * 10 >= raw.count * 8 else { return false }
        let digits = raw.map { c -> Int in
            switch c {
            case "O", "o": return 0
            case "l", "I": return 1
            case "S": return 5
            default: return c.wholeNumberValue ?? 0
            }
        }
        guard (13 ... 19).contains(digits.count), (2 ... 6).contains(digits[0]), Set(digits).count > 1 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { s, e in
            let d = e.offset % 2 == 1 ? e.element * 2 : e.element
            return s + (d > 9 ? d - 9 : d)
        }
        return sum % 10 == 0
    }

    static func isIP(_ s: String, v6: Bool) -> Bool {
        var buf = [UInt8](repeating: 0, count: 16)
        guard inet_pton(v6 ? AF_INET6 : AF_INET, s, &buf) == 1 else { return false }
        return !v6 || s.filter(\.isHexDigit).count >= 3
    }
}

// MARK: - Self-test

extension SensitiveScanner {
    /// Pure matcher on strings, then the real scanner (TextScan OCR) on rendered images: true positives with their
    /// exact boxes, and look-alikes that must not be redacted. Debug builds run it once at launch.
    static func selfTest() {
        let failures = matcherSelfTest()
        assert(failures.isEmpty, "SensitiveMatcher: \(failures)")
        Task {
            let f = await ocrSelfTest()
            if !f.isEmpty { assertionFailure("SensitiveScanner: \(f)") }
        }
    }

    /// Failure descriptions (empty = pass).
    nonisolated static func matcherSelfTest() -> [String] {
        let m = SensitiveMatcher(custom: "Project Falcon\n/INT-\\d{4}/")
        var fails: [String] = []
        func found(_ s: String) -> [(SensitiveKind, String)] { m.matches(s).map { ($0.kind, (s as NSString).substring(with: $0.range)) } }
        func expect(_ s: String, _ kind: SensitiveKind, _ value: String) {
            if !found(s).contains(where: { $0.0 == kind && $0.1 == value }) { fails.append("missed \(kind) '\(value)' in '\(s)': \(found(s))") }
        }
        func none(_ s: String) { if !found(s).isEmpty { fails.append("false positive in '\(s)': \(found(s))") } }

        expect("export OPENAI_API_KEY=sk-proj-Abc123XyZ987qwertyUIOP456lkjh", .secret, "sk-proj-Abc123XyZ987qwertyUIOP456lkjh")
        expect("ANTHROPIC_API_KEY=sk-ant-api03-Zx81kQ_pLm29vB7nTr4Ws6YdJ0", .secret, "sk-ant-api03-Zx81kQ_pLm29vB7nTr4Ws6YdJ0")
        expect("aws_access_key_id = AKlAIOSFODNN7EXAMPLE", .secret, "AKlAIOSFODNN7EXAMPLE")   // OCR read I as l
        expect("token ghp_16C7e42F292c6912E7710c838347Ae178B4a", .secret, "ghp_16C7e42F292c6912E7710c838347Ae178B4a")
        expect("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N", .secret,
               "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N")
        expect("SLACK=xoxb-2048-99887766-AbCdEfGhIjKl", .secret, "xoxb-2048-99887766-AbCdEfGhIjKl")
        expect("client_secret: 9fK2mQ7xL4pR8sT1vW6yZ3bN5cD0hJ", .secret, "9fK2mQ7xL4pR8sT1vW6yZ3bN5cD0hJ")
        expect("password: hunter2", .password, "hunter2")
        expect("DB_PASSWORD=tr0ub4dor&3", .password, "tr0ub4dor&3")
        expect("Mật khẩu: abc@123", .password, "abc@123")
        expect("Liên hệ: an.nguyen@company.vn", .email, "an.nguyen@company.vn")
        expect("call 0912 345 678 now", .phone, "0912 345 678")
        expect("+84 912 345 678", .phone, "+84 912 345 678")
        expect("Tel +1 (415) 555-0132", .phone, "+1 (415) 555-0132")
        expect("Card 4111 1111 1111 1111 exp 12/27", .card, "4111 1111 1111 1111")
        expect("Card 4111 1111 1111 111l", .card, "4111 1111 1111 111l")       // OCR read 1 as l
        expect("Amex 3782 822463 10005", .card, "3782 822463 10005")
        expect("Số CCCD: 001203004567", .nationalID, "001203004567")
        expect("CMND 123456789", .nationalID, "123456789")
        expect("STK: 0123456789012 Vietcombank", .account, "0123456789012")
        expect("Account number: 12345678", .account, "12345678")
        expect("IBAN: DE89 3704 0044 0532 0130 00", .account, "DE89 3704 0044 0532 0130 00")
        expect("server 192.168.1.10 up", .ip, "192.168.1.10")
        expect("addr fe80::1ff:fe23:4567:890a", .ip, "fe80::1ff:fe23:4567:890a")
        expect("https://api.example.com/v1?user=7&token=Zq81xLm2&lang=en", .urlToken, "Zq81xLm2")
        expect("Codename Project Falcon ships", .custom, "Project Falcon")
        expect("see INT-2041 for details", .custom, "INT-2041")
        // Only the value: the label stays readable.
        if found("export OPENAI_API_KEY=sk-proj-Abc123XyZ987qwertyUIOP456lkjh").contains(where: { $0.1.contains("OPENAI") }) { fails.append("label redacted") }

        none("Order #20231015-8812 shipped")
        none("Invoice INV-2024-000123")
        none("Date 2024-10-08 12:30:45")
        none("Order ID 1234567890")
        none("1234 5678 9012 3456")                       // fails Luhn
        none("Total 1,234,567 VND")
        none("Tracking 1Z999AA10123456784")
        none("Ref 20241008123456")
        none("Forgot password?")
        none("Password: ••••••••")
        none("Account created 2024-10-08")
        none("Version 1.2.3")
        none("task-management-system-design-guide")
        none("the keyboard_shortcuts_reference_manual")
        none("Meeting at 10:30, room 4")
        none("Total amount 0912")
        none("Thanh toán: 1.250.000đ")
        none("1 2 3 4 5 6 7 8 9 0 1 2 3")
        none("A secret, a token and a password walk into a bar")

        if !SensitiveMatcher.isCard("4111111111111111") || SensitiveMatcher.isCard("1234567890123456") || SensitiveMatcher.isCard("0000000000000000") { fails.append("Luhn") }
        if SensitiveMatcher.isIP("256.1.1.1", v6: false) || !SensitiveMatcher.isIP("10.0.0.1", v6: false) { fails.append("IPv4 octets") }
        if SensitiveMatcher.customRegex("/[/") != nil || SensitiveMatcher.customRegex("  ") != nil { fails.append("custom regex parsing") }
        return fails
    }

    /// Renders lines in a monospaced and a proportional font and checks what the real scanner boxes.
    static func ocrSelfTest() async -> [String] {
        var fails: [String] = []
        // (text, the substring that must be boxed or nil for "nothing", its kind)
        let cases: [(String, String?, SensitiveKind?)] = [
            ("export OPENAI_API_KEY=sk-proj-Abc123XyZ987qwertyUIOP456kjh", "sk-proj-Abc123XyZ987qwertyUIOP456kjh", .secret),
            ("Contact: an.nguyen@company.vn today", "an.nguyen@company.vn", .email),
            ("From: hoa.tran@example.org", "hoa.tran@example.org", .email),
            ("Reply to support@daisyshot.app", "support@daisyshot.app", .email),
            ("Hotline 0912 345 678", "0912 345 678", .phone),
            ("Card 4111 1111 1111 1111 exp 12/27", "4111 1111 1111 1111", .card),
            ("password: hunter2", "hunter2", .password),
            ("Order #20231015-8812 shipped", nil, nil),
            ("Invoice INV-2024-000123 due 2024-10-08", nil, nil),
            ("Number 1234 5678 9012 3456", nil, nil),
        ]
        for mono in [true, false] {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: 22, weight: .regular) : NSFont.systemFont(ofSize: 22)
            let lineHeight: CGFloat = 54, size = CGSize(width: 900, height: lineHeight * CGFloat(cases.count) + 20)
            guard let ctx = AnnotateRenderer.bitmapContext(Int(size.width * 2), Int(size.height * 2)) else { return ["no context"] }
            ctx.scaleBy(x: 2, y: 2)
            ctx.setFillColor(.white)
            ctx.fill(CGRect(origin: .zero, size: size))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            var expected: [(CGRect, String?, SensitiveKind?, String)] = []
            for (i, c) in cases.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let y = size.height - 10 - lineHeight * CGFloat(i + 1) + 14
                NSAttributedString(string: c.0, attributes: attrs).draw(at: CGPoint(x: 20, y: y))
                // Where the secret's glyphs really are (top-left origin, image points).
                var r = CGRect(x: 20, y: size.height - y - (font.ascender - font.descender), width: 0, height: font.ascender - font.descender)
                if let s = c.1, let at = c.0.range(of: s) {
                    r.origin.x += (String(c.0[..<at.lowerBound]) as NSString).size(withAttributes: attrs).width
                    r.size.width = (s as NSString).size(withAttributes: attrs).width
                }
                expected.append((r, c.1, c.2, c.0))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let image = ctx.makeImage() else { return ["no image"] }
            let found = await scan(image, size: size).filter { $0.kind != .face }
            let label = mono ? "mono" : "proportional"
            for (truth, secret, kind, line) in expected {
                let hits = found.filter { $0.rect.intersects(truth.insetBy(dx: 0, dy: 4)) || abs($0.rect.midY - truth.midY) < 10 }
                guard let secret, let kind else {
                    if !hits.isEmpty { fails.append("\(label): false positive in '\(line)': \(hits.map(\.text))") }
                    continue
                }
                guard let hit = hits.first(where: { $0.kind == kind }) else { fails.append("\(label): missed '\(secret)' in '\(line)': \(hits)"); continue }
                // Covers every glyph of the secret, and doesn't eat more than ~half a character of the neighbours. A space
                // next to the secret has no glyph, so covering it is free (Vision's word boxes often include it).
                let slack = font.pointSize * 0.35 + padding, space = (" " as NSString).size(withAttributes: [.font: font]).width
                let at = line.range(of: secret)!
                let left = slack + (at.lowerBound > line.startIndex && line[line.index(before: at.lowerBound)] == " " ? space : 0)
                let right = slack + (at.upperBound < line.endIndex && line[at.upperBound] == " " ? space : 0)
                if hit.rect.minX > truth.minX + 1 || hit.rect.maxX < truth.maxX - 1 || hit.rect.minX < truth.minX - left || hit.rect.maxX > truth.maxX + right {
                    fails.append("\(label): box for '\(secret)' is \(hit.rect.integral), glyphs at \(truth.integral)")
                }
            }
        }
        return fails
    }
}
