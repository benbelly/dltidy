import Foundation
import DLTidyKit

/// Filename classification and slug rules. Pure and stateless.
public struct NameRules: NameRuling {
    public init() {}

    // MARK: NameRuling

    public func classify(filename: String) -> NameClass {
        let stem = baseStem(of: filename)
        if stem.isEmpty { return .unclear }
        if Self.isGeneric(stem) { return .generic }
        if Self.isMeaningful(stem) { return .meaningful }
        return .unclear
    }

    public func baseStem(of filename: String) -> String {
        var name = (filename as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5, !ext.contains(" ") {
            name = (name as NSString).deletingPathExtension
        }
        var stem = name.trimmingCharacters(in: .whitespaces)
        // Repeatedly strip " (n)", " copy", " copy n".
        while true {
            let range = NSRange(stem.startIndex..., in: stem)
            guard let m = Self.duplicateMarker.firstMatch(in: stem, range: range),
                  let r = Range(m.range, in: stem), m.range.location > 0 else { break }
            stem = String(stem[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return stem
    }

    public func slug(from raw: String) -> String? {
        let decomposed = raw.decomposedStringWithCompatibilityMapping
        var ascii = String.UnicodeScalarView()
        for s in decomposed.unicodeScalars where s.isASCII { ascii.append(s) }
        let lowered = String(ascii).lowercased()
        var words: [String] = []
        var current = ""
        for c in lowered {
            if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") {
                current.append(c)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        if words.count > 6 { words = Array(words.prefix(6)) }
        while !words.isEmpty, words.joined(separator: "-").count > 60 { words.removeLast() }
        guard !words.isEmpty else { return nil }
        let slug = words.joined(separator: "-")
        guard slug.count >= 3 else { return nil }
        if words.count == 1, Self.genericWords.contains(words[0]) { return nil }
        if Self.isGeneric(slug) { return nil }
        return slug
    }

    // MARK: Rules

    static let genericWords: Set<String> = [
        "image", "images", "img", "download", "downloads", "downloaded", "untitled", "file", "files",
        "document", "documents", "doc", "docs", "scan", "scans", "scanned", "photo", "photos", "picture",
        "pictures", "pic", "pics", "video", "videos", "movie", "clip", "export", "exported", "output",
        "new", "copy", "temp", "tmp", "data", "attachment", "unknown", "noname", "unnamed", "screenshot",
        "capture", "recording", "audio", "text", "page", "sheet", "presentation", "result", "results",
        "media", "content", "item", "untitled", "of", "the", "and", "for", "with", "from", "final",
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file; a failure is a programmer error caught by the tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let duplicateMarker = regex(#"(\s*\(\d{1,3}\)|\s+copy(\s+\d{1,3})?)$"#)

    private static let genericPatterns: [NSRegularExpression] = [
        // camera prefixes
        regex(#"^(IMG|DSC|DSCF|DSCN|PXL|MVI|VID|GOPR|GH\d{2}|DJI|PANO)[_\- ]?\d"#),
        regex(#"^(FullSizeRender|RPReplay_Final)[ _\-]*\d*$"#),
        // screenshots and recordings
        regex(#"^(Screenshot|Screen Shot|Screen Recording|Screen_Recording|Capture d.écran|Bildschirmfoto)\b"#),
        // UUID anywhere
        regex(#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#),
        // long hex strings
        regex(#"^[0-9a-f]{16,}$"#),
        // AI image tools
        regex(#"^(ChatGPT[ _]Image|ChatGPT_|DALL[·._ \-]?E|Gemini_Generated_Image|Generated Image)"#),
        // messengers and apps
        regex(#"^(WhatsApp (Image|Video|Audio|Document|Ptt)|(IMG|VID|PTT|AUD|DOC)-\d{8}-WA\d+|signal-|FB_IMG_|Snapchat-?\d|telegram-cloud-(photo|document)|photo_\d+_|received_\d+|image_picker|InShot_|IMG_E?\d)"#),
        // numeric / date / time only (>= 6 digits, or date-like): no letters other than am/pm/at/t
        regex(#"^[\d\s._:\-/,+]*\d{6,}[\d\s._:\-/,+]*$"#),
        regex(#"^\d{1,4}[-_./]\d{1,2}[-_./]\d{1,4}([ _T\-]+(at )?\d{1,2}[-_.:]\d{2}([-_.:]\d{2})?\s*(am|pm)?)?$"#),
        regex(#"^(photo|image|video|scan|untitled|new document|document|file)[\s_\-]*(\d{4}[-_.]\d{2}[-_.]\d{2}.*|\d+)$"#),
    ]

    static func isGeneric(_ stem: String) -> Bool {
        let range = NSRange(stem.startIndex..., in: stem)
        for p in genericPatterns where p.firstMatch(in: stem, range: range) != nil { return true }
        let tokens = wordTokens(stem)
        // Only digits, separators, and generic words.
        if tokens.allSatisfy({ genericWords.contains($0.lowercased()) }) { return true }
        return false
    }

    static func isMeaningful(_ stem: String) -> Bool {
        let scalars = Array(stem.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        guard Double(digits) / Double(scalars.count) < 0.5 else { return false }
        let words = wordTokens(stem).filter { token in
            guard token.count >= 3 else { return false }
            if genericWords.contains(token.lowercased()) { return false }
            let isASCII = token.unicodeScalars.allSatisfy(\.isASCII)
            if isASCII { return token.lowercased().contains(where: { "aeiouy".contains($0) }) }
            return true
        }
        return words.count >= 2
    }

    /// Letter runs, with camelCase boundaries split ("QuickSave" -> Quick, Save).
    static func wordTokens(_ stem: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var prev: Character?
        for c in stem {
            if c.isLetter {
                if let p = prev, p.isLetter, p.isLowercase, c.isUppercase, !current.isEmpty {
                    tokens.append(current); current = ""
                }
                current.append(c)
            } else if !current.isEmpty {
                tokens.append(current); current = ""
            }
            prev = c
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
