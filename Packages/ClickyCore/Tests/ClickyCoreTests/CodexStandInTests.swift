import Foundation
@testable import ClickyCore

/// A stand-in `codex` command line tool written into a temp folder. It records how it was called
/// (arguments, environment, stdin) and answers in the JSON line shapes the real CLI printed on 2026-11-05
/// (codex-cli 0.155.1). The test picks its behaviour by writing a word into the `mode` file.
///
/// Modes: normal, limit, unauthorized, hang, apikey, notloggedin, hangstatus (login status never answers),
/// quote401 (the answer quotes "401 Unauthorized" and stderr prints it too).
final class CodexStandIn {
    let folder: URL
    let executableURL: URL
    let locations: AppDataLocations

    /// The text the stand-in answers with in normal mode.
    static let answerText = "Open the File menu and choose Save. [POINT:40,12:file menu]"

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        executableURL = folder.appendingPathComponent("codex")
        try Self.script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        locations = AppDataLocations(root: folder.appendingPathComponent("data", isDirectory: true))
        setMode("normal")
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func setMode(_ mode: String) {
        try? mode.write(to: folder.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    /// Replaces what `codex debug models` prints.
    func setModelCatalogJSON(_ json: String) {
        try? json.write(to: folder.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
    }

    func makeProvider(
        environment: [String: String] = [:],
        answerTimeoutSeconds: Double = 20
    ) -> CodexCLIProvider {
        CodexCLIProvider(
            locations: locations,
            executableURL: executableURL,
            environment: environment,
            answerTimeoutSeconds: answerTimeoutSeconds
        )
    }

    func makeAccount(environment: [String: String] = [:]) -> CodexCLIAccount {
        CodexCLIAccount(locations: locations, executableURL: executableURL, environment: environment)
    }

    // MARK: Recorded calls

    /// Every call the stand-in received, oldest first, as its argument list.
    func recordedCalls() -> [[String]] {
        var calls: [[String]] = []
        var number = 1
        while let arguments = readArguments(callNumber: number) {
            calls.append(arguments)
            number += 1
        }
        return calls
    }

    /// Only the `exec` calls (first turns, resumes, summaries).
    func recordedExecCalls() -> [[String]] {
        recordedCalls().filter { $0.first == "exec" }
    }

    private func readArguments(callNumber: Int) -> [String]? {
        let file = folder.appendingPathComponent("calls/\(callNumber).argv")
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Arguments are separated by NUL bytes because a prompt can hold newlines.
        let parts = data.split(separator: 0, omittingEmptySubsequences: false)
        let arguments = parts.map { String(decoding: $0, as: UTF8.self) }
        return Array(arguments.dropLast())
    }

    /// The environment text recorded for call number `callNumber` (1-based, counting every call).
    func recordedEnvironment(callNumber: Int) -> [String: String] {
        let file = folder.appendingPathComponent("calls/\(callNumber).env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            result[String(line[..<equalsIndex])] = String(line[line.index(after: equalsIndex)...])
        }
        return result
    }

    func recordedWorkingDirectory(callNumber: Int) -> String? {
        let file = folder.appendingPathComponent("calls/\(callNumber).cwd")
        return try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the stand-in saw its standard input as /dev/null in call number `callNumber`.
    func recordedStandardInputWasDevNull(callNumber: Int) -> Bool? {
        let file = folder.appendingPathComponent("calls/\(callNumber).stdinisnull")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    func recordedProcessID(callNumber: Int) -> Int32? {
        let file = folder.appendingPathComponent("calls/\(callNumber).pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True while a process with this id exists (a zombie that was not reaped counts as existing).
    static func processExists(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0
    }

    /// Waits up to `seconds` for the process to be gone.
    static func waitForProcessToExit(_ processID: Int32, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !processExists(processID) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !processExists(processID)
    }

    /// Waits up to `seconds` for call number `callNumber` to have recorded its process id.
    func waitForCall(callNumber: Int, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if recordedProcessID(callNumber: callNumber) != nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: The script

    private static let script = #"""
    #!/bin/bash
    dir="$(cd "$(dirname "$0")" && pwd)"
    mode="$(cat "$dir/mode" 2>/dev/null || echo normal)"
    mkdir -p "$dir/calls"
    number=$(( $(cat "$dir/counter" 2>/dev/null || echo 0) + 1 ))
    echo "$number" > "$dir/counter"
    : > "$dir/calls/$number.argv"
    for argument in "$@"; do
      printf '%s\0' "$argument" >> "$dir/calls/$number.argv"
    done
    env > "$dir/calls/$number.env"
    pwd > "$dir/calls/$number.cwd"
    echo $$ > "$dir/calls/$number.pid"
    if [ /dev/stdin -ef /dev/null ]; then echo yes > "$dir/calls/$number.stdinisnull"; else echo no > "$dir/calls/$number.stdinisnull"; fi

    if [ "$1" = "login" ] && [ "$2" = "status" ]; then
      case "$mode" in
        hangstatus) exec sleep 1000 ;;
        notloggedin) echo "Not logged in" >&2; exit 1 ;;
        apikey) echo "Logged in using an API key - sk-proj-***abcd" >&2; exit 0 ;;
        *) echo "Logged in using ChatGPT" >&2; exit 0 ;;
      esac
    fi
    if [ "$1" = "login" ]; then
      case "$mode" in
        loginfails) echo "login was cancelled" >&2; exit 1 ;;
        *) echo "Successfully logged in"; exit 0 ;;
      esac
    fi
    if [ "$1" = "delete" ]; then echo "Deleted"; exit 0; fi
    if [ "$1" = "logout" ]; then echo "Successfully logged out"; exit 0; fi
    if [ "$1" = "debug" ] && [ "$2" = "models" ]; then
      cat "$dir/models.json" 2>/dev/null || echo '{"models":[]}'
      exit 0
    fi

    if [ "$1" = "exec" ]; then
      # Real codex waits for stdin when it is open, so reading here proves stdin is closed.
      cat > "$dir/calls/$number.stdin"
      thread="thread-standin-$number"
      if [ "$2" = "resume" ]; then
        for argument in "$@"; do
          case "$argument" in thread-standin-*) thread="$argument" ;; esac
        done
      fi
      case "$mode" in
        hang)
          echo "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
          exec sleep 1000 ;;
        limit)
          echo "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
          echo '{"type":"turn.started"}'
          echo '{"type":"error","message":"You'"'"'ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits"}'
          echo '{"type":"turn.failed","error":{"message":"You'"'"'ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits"}}'
          exit 1 ;;
        unauthorized)
          echo "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
          echo '{"type":"turn.started"}'
          echo '{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses)"}'
          exec sleep 1000 ;;
        quote401)
          echo "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
          echo '{"type":"turn.started"}'
          echo "401 Unauthorized: the page you showed me said this" >&2
          echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"The page says 401 Unauthorized, so sign in first. [POINT:40,12:sign in]"}}'
          echo '{"type":"turn.completed","usage":{"input_tokens":22663,"cached_input_tokens":12160,"output_tokens":25}}'
          exit 0 ;;
        *)
          echo "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
          echo '{"type":"turn.started"}'
          echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Open the File menu and choose Save. [POINT:40,12:file menu]"}}'
          echo '{"type":"turn.completed","usage":{"input_tokens":22663,"cached_input_tokens":12160,"output_tokens":25}}'
          exit 0 ;;
      esac
    fi
    exit 2
    """#
}
