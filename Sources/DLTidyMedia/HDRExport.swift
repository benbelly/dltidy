import AVFoundation
import DLTidyKit
import Foundation

private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

extension MediaProcessor {
    /// AVFoundation export to H.264 SDR (the 1080p/2160p presets tone-map HLG and PQ to BT.709).
    /// Metadata items of the source are carried over. Throws `.failed` or `.timeout`.
    func exportHDRToSDR(input: URL, dest: URL, info: MediaInfo) async throws {
        let asset = AVURLAsset(url: input)
        let longEdge = max(info.width ?? 0, info.height ?? 0)
        let preset = longEdge > 1920 ? AVAssetExportPreset3840x2160 : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.failed("AVAssetExportSession unavailable for \(preset)")
        }
        if let items = try? await asset.load(.metadata), !items.isEmpty { session.metadata = items }
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: dest)

        let box = ExportBox(session)
        let timeout = Self.encodeTimeout(duration: info.durationSeconds)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await box.session.export(to: dest, as: .mp4)
                } onCancel: {
                    box.session.cancelExport()
                }
                return true
            }
            group.addTask {
                try await SuspendingClock().sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            do {
                guard let finished = try await group.next() else { throw MediaError.failed("export ended without result") }
                if !finished { throw MediaError.timeout("AVFoundation export exceeded its time limit") }
            } catch let e as MediaError {
                throw e
            } catch is CancellationError {
                throw MediaError.failed("export cancelled")
            } catch {
                throw MediaError.failed("AVFoundation export: \(error.localizedDescription)")
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)??.int64Value ?? 0
        guard size > 0 else { throw MediaError.failed("export produced no output") }
    }
}
