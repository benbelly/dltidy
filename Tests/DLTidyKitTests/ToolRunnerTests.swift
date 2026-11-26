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

    @Test func outputLimitIsEnforcedWhileWriting() async throws {
        // 2 GB of stdout against a 1 KB limit: the group is killed at the limit, nothing goes to disk.
        let tmp = FileManager.default.temporaryDirectory
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        let start = ContinuousClock.now
        let r = try await runner.run("/bin/sh", ["-c", "head -c 2000000000 /dev/zero; echo done >&2"], cwd: nil,
                                     timeout: .seconds(60), outputLimit: 1000)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(r.stdout.count == 1000)
        #expect(r.outputTruncated)
        #expect(!r.succeeded)
        #expect(!String(decoding: r.stderr, as: UTF8.self).contains("done"))   // the shell was killed too
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        #expect(after.subtracting(before).filter { $0.hasPrefix("dltidy-tool-") }.isEmpty)
    }

    @Test func outputExactlyAtLimitIsNotTruncated() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "head -c 4096 /dev/zero"], cwd: nil, timeout: .seconds(10), outputLimit: 4096)
        #expect(r.stdout.count == 4096)
        #expect(!r.outputTruncated)
        #expect(r.succeeded)
    }

    @Test func stderrIsCappedWithoutKilling() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero >&2; echo ok"], timeout: .seconds(10))
        #expect(r.stderr.count == 64 << 10)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "ok\n")
        #expect(r.succeeded)
    }

    @Test func detachedGrandchildHoldingStdoutDoesNotBlock() async throws {
        let start = ContinuousClock.now
        let r = try await runner.run("/usr/bin/perl", ["-e", "use POSIX; if (fork() == 0) { setsid(); sleep 30; exit 0 } print \"hi\\n\";"],
                                     timeout: .seconds(20))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")
        #expect(r.succeeded)
    }

    @Test func environmentIsPassed() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "printf %s \"$DLTIDY_TEST_VAR\""], cwd: nil,
                                     environment: ["DLTIDY_TEST_VAR": "policy"], timeout: .seconds(10), outputLimit: 100)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "policy")
    }

    @Test func runnersWithoutEnvironmentSupportRefuseIt() async throws {
        struct Plain: ToolRunning {
            func run(_ tool: String, _ args: [String], cwd: URL?, timeout: Duration, outputLimit: Int) async throws -> ToolResult {
                try await ToolRunner().run(tool, args, cwd: cwd, timeout: timeout, outputLimit: outputLimit)
            }
        }
        await #expect(throws: ToolError.environmentUnsupported("/bin/echo")) {
            _ = try await Plain().run("/bin/echo", [], cwd: nil, environment: ["A": "1"], timeout: .seconds(5), outputLimit: 10)
        }
        let r = try await Plain().run("/bin/echo", ["x"], cwd: nil, environment: [:], timeout: .seconds(5), outputLimit: 10)
        #expect(r.succeeded)
    }

    @Test func missingToolThrows() async {
        await #expect(throws: ToolError.notFound("no-such-tool-xyz")) {
            _ = try await runner.run("no-such-tool-xyz", [], timeout: .seconds(1))
        }
    }
}
