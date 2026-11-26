/// The decompression-bomb rule shared by probing (DLTidyMedia) and thumbnailing (DLTidyNaming).
/// A small file can declare a huge canvas; real photos have a modest pixels-per-byte ratio.
public enum ImageLimits {
    /// Always rejected above this many pixels.
    public static let maxPixels = 1_000_000_000
    /// Images up to this many pixels skip the ratio test.
    public static let ratioFloorPixels = 50_000_000
    /// Above the floor, more than this many pixels per file byte is rejected.
    public static let maxPixelsPerByte = 1_000

    /// False for non-positive dimensions, more than `maxPixels` pixels, or more than
    /// `ratioFloorPixels` pixels with `pixels / fileBytes > maxPixelsPerByte`.
    public static func isAcceptable(width: Int, height: Int, fileBytes: Int64) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else { return false }
        guard pixels > ratioFloorPixels else { return true }
        let (limit, limitOverflow) = Int(max(fileBytes, 0)).multipliedReportingOverflow(by: maxPixelsPerByte)
        return limitOverflow || pixels <= limit
    }
}
