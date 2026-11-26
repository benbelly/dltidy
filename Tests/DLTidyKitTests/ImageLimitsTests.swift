import Testing
@testable import DLTidyKit

@Suite struct ImageLimitsTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var w: Int, h: Int, bytes: Int64
        var accepted: Bool
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // Real photos
        Case(name: "Fujifilm GFX100 11648x8736, 40 MB", w: 11_648, h: 8_736, bytes: 40_000_000, accepted: true),
        Case(name: "200 MP phone, 60 MB", w: 16_320, h: 12_240, bytes: 60_000_000, accepted: true),
        Case(name: "wide panorama 40000x5000 (200 MP), 30 MB", w: 40_000, h: 5_000, bytes: 30_000_000, accepted: true),
        Case(name: "flat 4000x4000 PNG, 50 KB", w: 4_000, h: 4_000, bytes: 50_000, accepted: true),
        // Bombs
        Case(name: "30000x30000 1-bit PNG, 109 KB", w: 30_000, h: 30_000, bytes: 109_000, accepted: false),
        Case(name: "110 MP in 5 KB", w: 11_000, h: 10_000, bytes: 5_000, accepted: false),
        // Pixel ceiling
        Case(name: "exactly 1e9 pixels, huge file", w: 40_000, h: 25_000, bytes: 4_000_000_000, accepted: true),
        Case(name: "1e9 + 1 pixels, huge file", w: 1_000_000_001, h: 1, bytes: 4_000_000_000, accepted: false),
        // Ratio floor at 50 MP
        Case(name: "exactly 50 MP, 1 byte", w: 10_000, h: 5_000, bytes: 1, accepted: true),
        Case(name: "50 MP + 1, 1 byte", w: 50_000_001, h: 1, bytes: 1, accepted: false),
        // Ratio boundary: pixels / bytes == 1000 passes, > 1000 fails
        Case(name: "60 MP, ratio exactly 1000", w: 10_000, h: 6_000, bytes: 60_000, accepted: true),
        Case(name: "60 MP, ratio just over 1000", w: 10_000, h: 6_000, bytes: 59_999, accepted: false),
        Case(name: "50 MP + 1, ratio just over 1000", w: 50_000_001, h: 1, bytes: 50_000, accepted: false),
        Case(name: "50 MP + 1 at 50001 bytes", w: 50_000_001, h: 1, bytes: 50_001, accepted: true),
        // Degenerate input
        Case(name: "zero width", w: 0, h: 100, bytes: 100, accepted: false),
        Case(name: "negative height", w: 100, h: -1, bytes: 100, accepted: false),
        Case(name: "overflowing product", w: Int.max, h: 3, bytes: Int64.max, accepted: false),
        Case(name: "unknown size (0 bytes), small image", w: 1_000, h: 1_000, bytes: 0, accepted: true),
        Case(name: "unknown size (0 bytes), 60 MP", w: 10_000, h: 6_000, bytes: 0, accepted: false),
    ]

    @Test(arguments: cases)
    func rule(_ c: Case) {
        #expect(ImageLimits.isAcceptable(width: c.w, height: c.h, fileBytes: c.bytes) == c.accepted)
    }
}
