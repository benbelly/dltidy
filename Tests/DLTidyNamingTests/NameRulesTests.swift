import Foundation
import Testing
@testable import DLTidyNaming
import DLTidyKit

struct NameRulesTests {
    let rules = NameRules()

    static let classCases: [(String, NameClass)] = [
        // camera and phone
        ("IMG_1234.HEIC", .generic),
        ("IMG_E1234.jpg", .generic),
        ("DSC00123.JPG", .generic),
        ("DSCF0042.jpg", .generic),
        ("PXL_20240101_123456789.jpg", .generic),
        ("MVI_0042.MP4", .generic),
        ("VID_20240101_101010.mp4", .generic),
        ("GOPR0001.MP4", .generic),
        ("DJI_0123.MP4", .generic),
        ("PANO_20240101_101010.jpg", .generic),
        ("FullSizeRender.jpg", .generic),
        ("FullSizeRender 2.jpg", .generic),
        ("RPReplay_Final1700000000.mov", .generic),
        ("IMG_1234 (1).jpg", .generic),
        ("IMG_1234 copy.jpg", .generic),
        // screenshots
        ("Screenshot 2024-05-01 at 10.11.12.png", .generic),
        ("Screen Shot 2021-03-04 at 9.01.02 AM.png", .generic),
        ("Screen Recording 2024-05-01 at 10.11.12.mov", .generic),
        // ids and numbers
        ("3F2504E0-4F89-11D3-9A0C-0305E82C3301.pdf", .generic),
        ("a3f9c2b1d4e5f60718293a4b5c6d7e8f.jpg", .generic),
        ("20240501_101112.jpg", .generic),
        ("2024-05-01 10.11.12.png", .generic),
        ("1714558272.png", .generic),
        ("123456.pdf", .generic),
        ("12-05-2024.pdf", .generic),
        // AI tools
        ("ChatGPT Image May 1, 2024, 10_11_12 AM.png", .generic),
        ("ChatGPT_Image_20240501.png", .generic),
        ("DALL·E 2024-05-01 10.11.12 - A cat.png", .generic),
        ("Gemini_Generated_Image_abc123xyz.png", .generic),
        // messengers
        ("WhatsApp Image 2024-05-01 at 10.11.12.jpeg", .generic),
        ("WhatsApp Video 2024-05-01 at 10.11.12.mp4", .generic),
        ("IMG-20240501-WA0003.jpg", .generic),
        ("signal-2024-05-01-101112.jpg", .generic),
        ("FB_IMG_1714558272123.jpg", .generic),
        ("Snapchat-1234567890.jpg", .generic),
        ("telegram-cloud-photo-size-5-123.jpg", .generic),
        // bare generic words
        ("image.png", .generic),
        ("Image (3).png", .generic),
        ("download.pdf", .generic),
        ("Untitled.png", .generic),
        ("Untitled-2.psd", .generic),
        ("file.txt", .generic),
        ("document.pdf", .generic),
        ("scan_001.pdf", .generic),
        ("New Document.docx", .generic),
        ("photo.jpg", .generic),
        ("export.csv", .generic),
        ("output.mp4", .generic),
        // meaningful
        ("Device_Stand_-_3_Slots.3mf", .meaningful),
        ("QuickSave_399.png", .meaningful),
        ("Quarterly Budget Report.xlsx", .meaningful),
        ("resume-john-smith.pdf", .meaningful),
        ("Invoice from Acme Corp.pdf", .meaningful),
        ("Quarterly Budget Report (1).xlsx", .meaningful),
        ("holiday photos italy.zip", .meaningful),
        ("kitchen-renovation-plan.pdf", .meaningful),
        // unclear
        ("Invoice.pdf", .unclear),
        ("Invoice_20240101.pdf", .unclear),
        ("resume.pdf", .unclear),
        ("xk7q.png", .unclear),
        ("a1b2c3.png", .unclear),
        ("", .unclear),
    ]

    @Test(arguments: classCases)
    func classification(_ name: String, _ expected: NameClass) {
        #expect(rules.classify(filename: name) == expected, "\(name)")
    }

    @Test func tableSize() { #expect(Self.classCases.count >= 40) }

    static let baseStemCases: [(String, String)] = [
        ("IMG_1234.HEIC", "IMG_1234"),
        ("Report (1).pdf", "Report"),
        ("Report (12).pdf", "Report"),
        ("Report copy.pdf", "Report"),
        ("Report copy 2.pdf", "Report"),
        ("Report copy 2 (1).pdf", "Report"),
        ("archive.tar.gz", "archive.tar"),
        ("notes", "notes"),
        ("Device_Stand_-_3_Slots.3mf", "Device_Stand_-_3_Slots"),
        ("photo-1.jpg", "photo-1"),
        ("My Report v2.1.pdf", "My Report v2.1"),
    ]

    @Test(arguments: baseStemCases)
    func baseStem(_ name: String, _ expected: String) {
        #expect(rules.baseStem(of: name) == expected)
    }

    static let slugCases: [(String, String?)] = [
        ("Kitchen Renovation Plan", "kitchen-renovation-plan"),
        ("  Quarterly   Budget--Report!! ", "quarterly-budget-report"),
        ("Café Menü Überblick", "cafe-menu-uberblick"),
        ("résumé of Jane Doe", "resume-of-jane-doe"),
        ("one two three four five six seven eight", "one-two-three-four-five-six"),
        ("Invoice from Acme Corp", "invoice-from-acme-corp"),
        ("ＦＵＬＬ ｗｉｄｔｈ ｔｅｘｔ", "full-width-text"),
        ("ab", nil),
        ("", nil),
        ("日本語", nil),
        ("image", nil),
        ("Untitled", nil),
        ("new document", nil),
        ("IMG_1234", nil),
        ("Screenshot of login page", nil),
        ("2024-05-01", nil),
        ("a3f9c2b1d4e5f60718293a4b5c6d7e8f", nil),
        ("cat", "cat"),
    ]

    @Test(arguments: slugCases)
    func slug(_ raw: String, _ expected: String?) {
        #expect(rules.slug(from: raw) == expected, "\(raw)")
    }

    @Test func slugLengthCutsAtWordBoundary() {
        let raw = "extraordinarily internationalization characterization responsibilities misunderstanding"
        let s = rules.slug(from: raw)
        #expect(s != nil)
        #expect((s?.count ?? 0) <= 60)
        #expect(s == "extraordinarily-internationalization-characterization")
    }

    @Test func slugOverlongSingleWordIsRejected() {
        #expect(rules.slug(from: String(repeating: "a", count: 80)) == nil)
    }

    @Test func slugPropertyOverRandomInput() {
        let pattern = try! NSRegularExpression(pattern: "^[a-z0-9]+(-[a-z0-9]+){0,5}$")
        var rng = SystemRandomNumberGenerator()
        let pool: [Character] = Array("abcXYZ019 -_.!?éüß日本\u{0301}\n\t'\"()[]{}/\\𝔘") + ["·", "—", "…"]
        for _ in 0..<3000 {
            let len = Int.random(in: 0...90, using: &rng)
            let raw = String((0..<len).map { _ in pool.randomElement(using: &rng)! })
            if let s = rules.slug(from: raw) {
                #expect(pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil, "\(raw) -> \(s)")
                #expect(s.count >= 3 && s.count <= 60)
            }
        }
    }
}
