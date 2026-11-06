import Foundation
@testable import ClickyCore

/// A stand-in for the `claude` command line tool, written to a temp folder. It records every start (argv and
/// environment) and every stdin line, and answers in the stream-json shapes captured from Claude Code 2.1.318.
/// It is the only fake in the Claude tests: the provider runs it as a real child process.
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ClaudeStandIn {
    static let defaultAnswer = "The Save button is at the top right. [POINT:1180,40:save button]"

    /// How the stand-in behaves, read from the `mode` file next to the script (the provider hands the child only an
    /// allowlist of environment variables, so a test cannot pass a mode through the environment).
    enum Mode: String {
        case normal
        /// Answers with the plan-limit error
        case limit
        /// Reports an API key login in the init line
        case apiKey = "apikey"
        /// Answers the way the real CLI does with no login, then exits 1
        case notLoggedIn = "notloggedin"
        /// Reads input and never answers
        case silent
        /// Refuses the in-place model change request
        case refuseModelChange = "nosetmodel"
        /// Answers the first question, then exits
        case exitAfterFirstAnswer = "exitafterfirst"
        /// Takes 30 seconds to answer a model change request, so a test can press Stop in the middle of it
        case slowModelChange = "slowsetmodel"
        /// The one-shot run (the summary) ignores the polite stop request and never ends on its own
        case ignoreTerminate = "ignoreterm"
    }

    let directory: URL
    let executableURL: URL
    let mode: Mode

    init(mode: Mode = .normal) throws {
        self.mode = mode
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appendingPathComponent("claude")
        try Self.script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try mode.rawValue.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    /// Variables that must never reach a child: keys and tokens, a base URL, the keychain folder switch, and
    /// other login folders.
    static let variablesThatMustNotReachTheChild: [String: String] = [
        "ANTHROPIC_API_KEY": "sk-test",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:1",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere/keychain",
        "CLAUDE_CODE_OAUTH_TOKEN": "oauth-test",
        "OPENAI_API_KEY": "sk-openai-test",
        "CODEX_HOME": "/elsewhere/codex",
        "CLAUDE_CONFIG_DIR": "/elsewhere/claude",
    ]

    /// The parent environment the provider is given: a real PATH plus every variable that must not reach the child.
    var parentEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in Self.variablesThatMustNotReachTheChild {
            environment[name] = value
        }
        return environment
    }

    /// What a child may have seen of the parent's environment: the allowlist, `LC_*`, and the app's own folder
    /// variable. Python adds `__PYVENV_LAUNCHER__` to itself on macOS when it is started through a launcher.
    static func unexpectedVariableNames(in childEnvironment: [String: String]) -> [String] {
        let allowedNames: Set<String> = [
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING",
            "CLAUDE_CONFIG_DIR", "__PYVENV_LAUNCHER__",
        ]
        return childEnvironment.keys
            .filter { !allowedNames.contains($0) && !$0.hasPrefix("LC_") }
            .sorted()
    }

    func locations() -> AppDataLocations {
        AppDataLocations(root: directory.appendingPathComponent("data", isDirectory: true))
    }

    private func records(_ fileName: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    /// One entry per process start: `pid`, `argv`, `env`.
    var starts: [[String: Any]] { records("starts.jsonl") }
    /// One entry per stdin line: `pid`, `message`.
    var stdinLines: [[String: Any]] { records("stdin.jsonl") }
    var summarizeRuns: [[String: Any]] { records("summarize.jsonl") }
    var authRuns: [[String: Any]] { records("auth.jsonl") }

    var userMessages: [[String: Any]] {
        stdinLines.filter { ($0["message"] as? [String: Any])?["type"] as? String == "user" }
    }

    func argv(ofStart index: Int) -> [String] {
        starts[safe: index]?["argv"] as? [String] ?? []
    }

    func environment(ofStart index: Int) -> [String: String] {
        starts[safe: index]?["env"] as? [String: String] ?? [:]
    }

    /// The environment of the auth run whose command word (after `auth`) is `command`.
    func environment(ofAuthCommand command: String) -> [String: String]? {
        let run = authRuns.first { ($0["argv"] as? [String])?[safe: 1] == command }
        return run?["env"] as? [String: String]
    }

    func pid(ofStart index: Int) -> Int {
        starts[safe: index]?["pid"] as? Int ?? -1
    }

    /// Python takes a moment to start; waits (up to ten seconds) until it has recorded this many starts.
    func waitForStarts(count: Int) async {
        for _ in 0..<200 {
            if starts.count >= count { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The content blocks of a recorded user line.
    func contentBlocks(ofUserLine line: [String: Any]) -> [[String: Any]] {
        let message = (line["message"] as? [String: Any])?["message"] as? [String: Any]
        return message?["content"] as? [[String: Any]] ?? []
    }

    /// True once no process with this pid exists (waits up to two seconds for the exit to land).
    func waitForProcessToBeGone(pid: Int) async -> Bool {
        for _ in 0..<40 {
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static let script = #"""
#!/usr/bin/env python3
import json, os, signal, sys, time

directory = os.path.dirname(os.path.realpath(__file__))
mode = open(os.path.join(directory, "mode")).read().strip()
answer = "The Save button is at the top right. [POINT:1180,40:save button]"
pid = os.getpid()
argv = sys.argv[1:]

def append(name, record):
    with open(os.path.join(directory, name), "a") as handle:
        handle.write(json.dumps(record) + "\n")

def emit(record):
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()

signed_in_marker = os.path.join(directory, "signed-in")

if argv and argv[0] == "auth":
    append("auth.jsonl", {"pid": pid, "argv": argv, "config": os.environ.get("CLAUDE_CONFIG_DIR"),
                                  "env": dict(os.environ)})
    if argv[1] == "status":
        signed_in = os.path.exists(signed_in_marker)
        emit({"loggedIn": signed_in, "authMethod": "claude.ai" if signed_in else "none",
              "apiProvider": "firstParty", "email": "person@example.test" if signed_in else None,
              "subscriptionType": "max" if signed_in else None})
    elif argv[1] == "login":
        open(signed_in_marker, "w").close()
        print("Login successful.")
    elif argv[1] == "logout":
        if os.path.exists(signed_in_marker):
            os.remove(signed_in_marker)
        print("Successfully logged out from your Anthropic account.")
    sys.exit(0)

append("starts.jsonl", {"pid": pid, "argv": argv, "env": dict(os.environ)})

if "--input-format" not in argv:
    prompt = sys.stdin.read()
    append("summarize.jsonl", {"pid": pid, "argv": argv, "stdin": prompt})
    if mode == "ignoreterm":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(1000)
    if mode == "limit":
        print("You've hit your limit · resets 3pm")
        sys.exit(1)
    print("Short summary text.")
    sys.exit(0)

model = argv[argv.index("--model") + 1]
answered = 0

def send_init():
    emit({"type": "system", "subtype": "init", "model": model, "permissionMode": "default",
          "apiKeySource": "ANTHROPIC_API_KEY" if mode == "apikey" else "none", "session_id": "stand-in"})

def send_reply(text, is_error=False, error=None):
    assistant = {"type": "assistant", "message": {"model": model, "role": "assistant",
                 "content": [{"type": "text", "text": text}]}, "session_id": "stand-in"}
    if error:
        assistant["error"] = error
    emit(assistant)
    emit({"type": "result", "subtype": "success", "is_error": is_error, "result": text,
          "stop_reason": "end_turn", "session_id": "stand-in"})

for line in sys.stdin:
    message = json.loads(line)
    append("stdin.jsonl", {"pid": pid, "message": message})
    if message["type"] == "control_request":
        request = message["request"]
        if mode == "slowsetmodel":
            time.sleep(30)
        if mode == "nosetmodel":
            emit({"type": "control_response", "response": {"subtype": "error",
                  "request_id": message["request_id"], "error": "Unsupported control request"}})
        else:
            model = request["model"]
            emit({"type": "control_response", "response": {"subtype": "success",
                  "request_id": message["request_id"], "response": {"model": model}}})
        continue
    send_init()
    if mode == "silent":
        continue
    if mode == "limit":
        send_reply("You've hit your limit · resets 3pm", True, "rate_limit")
        continue
    if mode == "notloggedin":
        send_reply("Not logged in · Please run /login", True, "authentication_failed")
        sys.exit(1)
    send_reply(answer)
    answered += 1
    if mode == "exitafterfirst" and answered == 1:
        sys.exit(0)

append("exits.jsonl", {"pid": pid})
"""#
}
