import DLTidyCore
import DLTidyKit
import DLTidyMedia
import DLTidyNaming
import Darwin
import Foundation

// dltidy: no arguments runs the daemon; a subcommand runs the CLI. The CLI reads the ledger or
// queues a `commands` row; only the daemon changes files.

let usage = """
    usage: dltidy [--watch-dir DIR] [--state-dir DIR] [--log-dir DIR] [--label LABEL] [--no-keychain] [command]

    commands:
      (none)                     run the daemon (launchd starts it)
      set-key                    store the Anthropic API key in the Keychain (hidden prompt)
      status                     health, breaker, cap usage, pending items
      log [-n N]                 recent actions (default 20)
      doctor                     run the checks and print the results
      pause                      stop processing
      resume [--skip-backlog]    restart processing (optionally skipping files that arrived while paused)
      undo [--last | <name>]     restore the old names of the last renamed file, or of <name>
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("dltidy: \(message)\n".utf8))
    exit(code)
}

var watchDir: URL?
var stateDir: URL?
var label = "local.dltidy"
var logDir: URL?
var useKeychain = true
var rest: [String] = []
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--no-keychain":
        useKeychain = false   // tests: never read the real key
    case "--watch-dir", "--state-dir", "--label", "--log-dir":
        guard !argv.isEmpty else { fail("\(a) needs a value") }
        let v = argv.removeFirst()
        if a == "--watch-dir" { watchDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true) }
        else if a == "--state-dir" { stateDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true) }
        else if a == "--log-dir" { logDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true) }
        else { label = v }
    case "-h", "--help", "help":
        print(usage)
        exit(0)
    default:
        rest.append(a)
    }
}

var config = Config.standard(watchDir: watchDir, stateDir: stateDir, label: label)
if let logDir { config.logDir = logDir.standardizedFileURL }

guard let command = rest.first else {
    Daemon.run(config: config, useKeychain: useKeychain)
}
let args = Array(rest.dropFirst())

@MainActor func client() -> ControlClient {
    do { return try ControlClient(config: config) } catch { fail("\(error)") }
}

/// Queues a command and prints the daemon's answer, or a note that it is queued.
@MainActor func sendAndReport(_ cmd: CommandName, arg: String? = nil) {
    do {
        if let result = try client().send(cmd, arg: arg, timeout: 10) {
            print(result)
        } else {
            print("queued; the daemon applies it on its next pass (is it running? `launchctl print gui/\(getuid())/\(label)`)")
        }
    } catch {
        fail("\(error)")
    }
}

switch command {
case "set-key":
    let key: String
    if isatty(STDIN_FILENO) == 0 {
        // Piped input, e.g. `pbpaste | dltidy set-key`: the key never appears on screen or in argv.
        let data = FileHandle.standardInput.readDataToEndOfFile().prefix(512)
        key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        var buf = [CChar](repeating: 0, count: 512)
        guard readpassphrase("Anthropic API key: ", &buf, buf.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil else {
            fail("could not read the key (needs a terminal, or pipe it: pbpaste | dltidy set-key)")
        }
        key = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        for i in buf.indices { buf[i] = 0 }
    }
    guard !key.isEmpty else { fail("empty key; nothing stored") }
    if !key.hasPrefix("sk-ant-") { print("warning: the key does not start with sk-ant-") }
    do { try Keychain.storeAPIKey(key) } catch { fail("Keychain: \(error)") }
    print("key stored in the login Keychain (service \(Keychain.service))")
    if FileManager.default.fileExists(atPath: config.ledgerURL.path) {
        _ = try? client().send(.keyUpdated, timeout: 3)
    }

case "status":
    do { print(try client().status()) } catch { fail("\(error)") }

case "log":
    var n = 20
    if args.count == 2, args[0] == "-n", let v = Int(args[1]), v > 0 { n = v }
    else if !args.isEmpty { fail("usage: dltidy log [-n N]") }
    do { print(try client().recentActions(limit: n)) } catch { fail("\(error)") }

case "doctor":
    var failures = 0
    func line(_ ok: Bool, _ name: String, _ detail: String) {
        print("\(ok ? "ok  " : "FAIL") \(name): \(detail)")
        if !ok { failures += 1 }
    }
    print("local checks (this process):")
    let runner = ToolRunner()
    for tool in MediaProcessor.requiredTools {
        let path = runner.resolve(tool)
        line(path != nil, tool, path ?? "not found on PATH or in /opt/homebrew/bin")
    }
    let policyProblem = MediaProcessor(tools: runner).policyProblem()
    line(policyProblem == nil, "magick-policy", policyProblem ?? "present")
    let hasKey = useKeychain && Keychain.readAPIKey() != nil
    line(hasKey, "key", hasKey ? "present" : "absent; run `dltidy set-key`")
    if let c = try? ControlClient(config: config) {
        line(c.quickCheck(), "ledger", c.quickCheck() ? "quick_check ok" : "quick_check failed")
        print("\ndaemon checks (requested from the running daemon):")
        if let report = try? c.send(.health, timeout: 10) {
            print(report)
            failures += report.split(separator: "\n").filter { $0.hasPrefix("FAIL") }.count
        } else if let last = c.lastHealthReport() {
            print("daemon did not answer within 10 s; last report from \(last.at):\n\(last.report)")
            failures += 1
        } else {
            print("FAIL daemon: no answer and no earlier report")
            failures += 1
        }
    } else {
        line(false, "ledger", "not created yet (the daemon has not started)")
    }
    print(failures == 0 ? "\nall checks pass" : "\n\(failures) check(s) failing")
    exit(failures == 0 ? 0 : 1)

case "pause":
    sendAndReport(.pause)

case "resume":
    if args == ["--skip-backlog"] { sendAndReport(.resume, arg: "skip-backlog") }
    else if args.isEmpty { sendAndReport(.resume) }
    else { fail("usage: dltidy resume [--skip-backlog]") }

case "undo":
    if args.isEmpty || args == ["--last"] { sendAndReport(.undo) }
    else if args.count == 1 { sendAndReport(.undo, arg: args[0]) }
    else { fail("usage: dltidy undo [--last | <name>]") }

default:
    fail("unknown command \(command)\n\(usage)", code: 2)
}
