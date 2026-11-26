import Foundation
import Testing
@testable import DLTidyKit

@Suite struct ToolRunnerTests {
    let runner = ToolRunner()

    @Test func capturesStdoutAndStatus() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "echo hello; echo oops >&2; exit 3"], timeout: .seconds(10))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hello\n")
        #expect(String(decoding: r.stderr, as: UTF8.self) == "oops\n")
        #expect(r.status == 3)
        #expect(!r.timedOut)
    }

    @Test func timeoutKillsProcessGroup() async throws {
        let start = ContinuousClock.now
        let r = try await runner.run("/bin/sh", ["-c", "sleep 30 & sleep 30"], timeout: .seconds(1))
        #expect(r.timedOut)
        #expect(ContinuousClock.now - start < .seconds(4))  // SIGTERM must suffice; SIGKILL comes at 6 s
    }

    @Test func outputLimitTruncates() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "yes | head -c 100000"], cwd: nil, timeout: .seconds(10), outputLimit: 1000)
        #expect(r.stdout.count == 1000)
    }

    @Test func missingToolThrows() async {
        await #expect(throws: ToolError.notFound("no-such-tool-xyz")) {
            _ = try await runner.run("no-such-tool-xyz", [], timeout: .seconds(1))
        }
    }
}
