import Foundation
import Testing
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
        /// Refuses `apply_flag_settings` (the in-place effort change)
        case refuseEffortChange = "noeffort"
        /// Ignores the interrupt request during a held answer
        case ignoreInterrupt = "ignoreinterrupt"
    }

    /// Words a test puts in a question to pick how the stand-in answers it, in any mode, on the same process.
    enum QuestionTrigger {
        /// Streams the default answer in pieces: text block start, several deltas, result
        static let streamed = "STREAMQUESTION"
        /// Preamble text, a `search_brain` call with its result, then the finding
        static let search = "SEARCHQUESTION"
        /// The same `search_brain` call three times, then waits
        static let repeatedCall = "REPEATQUESTION"
        /// One delta, then holds until an interrupt arrives
        static let held = "HELDQUESTION"
        /// Six deltas 0.5 s apart
        static let trickle = "TRICKLEQUESTION"
        /// Streams text but no `result.result` text (the final text is only in the deltas)
        static let thinking = "THINKINGQUESTION"
    }

    /// The text of the search stream's two blocks and the file its tool result names.
    static let searchPreamble = "Searching the brain for the port."
    static let searchFinding = "design-vault runs on port 4417."
    static let searchResultPath = "/notes/design-vault.md"

    let directory: URL
    let executableURL: URL
    let mode: Mode

    /// `startingEffortLevel` is the effort `get_settings` shows when the process starts; nil means none was set.
    init(mode: Mode = .normal, startingEffortLevel: String? = nil) throws {
        self.mode = mode
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appendingPathComponent("claude")
        try Self.script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try mode.rawValue.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        if let startingEffortLevel {
            try startingEffortLevel.write(to: directory.appendingPathComponent("effort"), atomically: true, encoding: .utf8)
        }
    }

    /// Changes how the running stand-in answers `apply_flag_settings` from the next request on.
    func switchEffortRefusal(on: Bool) throws {
        try (on ? Mode.refuseEffortChange : Mode.normal).rawValue
            .write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
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
            "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_FILE_MENTIONS", "__PYVENV_LAUNCHER__",
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

    /// Every control request the provider sent, in order, as its `request` object.
    var controlRequests: [[String: Any]] {
        stdinLines.compactMap { line in
            guard let message = line["message"] as? [String: Any], message["type"] as? String == "control_request" else { return nil }
            return message["request"] as? [String: Any]
        }
    }

    /// The subtypes of the control requests, in order.
    var controlSubtypes: [String] {
        controlRequests.compactMap { $0["subtype"] as? String }
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
import json, os, queue, signal, sys, threading, time

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
effort = None
effort_file = os.path.join(directory, "effort")
if os.path.exists(effort_file):
    effort = open(effort_file).read().strip()

inbox = queue.Queue()

def read_stdin():
    for raw in sys.stdin:
        inbox.put(raw)
    inbox.put(None)

threading.Thread(target=read_stdin, daemon=True).start()

def send_init():
    emit({"type": "system", "subtype": "init", "model": model, "permissionMode": "default",
          "apiKeySource": "ANTHROPIC_API_KEY" if mode == "apikey" else "none", "session_id": "stand-in"})

def stream_event(event):
    emit({"type": "stream_event", "event": event, "session_id": "stand-in", "parent_tool_use_id": None})

def assistant_blocks(blocks):
    emit({"type": "assistant", "message": {"model": model, "role": "assistant", "content": blocks},
          "parent_tool_use_id": None, "session_id": "stand-in"})

def send_reply(text, is_error=False, error=None):
    assistant = {"type": "assistant", "message": {"model": model, "role": "assistant",
                 "content": [{"type": "text", "text": text}]}, "session_id": "stand-in"}
    if error:
        assistant["error"] = error
    emit(assistant)
    emit({"type": "result", "subtype": "success", "is_error": is_error, "result": text,
          "stop_reason": "end_turn", "session_id": "stand-in"})

def stream_text_block(pieces, index=0, pause=0):
    stream_event({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
    for piece in pieces:
        stream_event({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": piece}})
        if pause:
            time.sleep(pause)
    assistant_blocks([{"type": "text", "text": "".join(pieces)}])
    stream_event({"type": "content_block_stop", "index": index})

tool_counter = [0]

def tool_call(query, result_text, wait_for_result=True):
    tool_counter[0] += 1
    tool_id = "toolu_%d" % tool_counter[0]
    name = "mcp__brain__search_brain"
    stream_event({"type": "content_block_start", "index": 1,
                  "content_block": {"type": "tool_use", "id": tool_id, "name": name, "input": {}}})
    assistant_blocks([{"type": "tool_use", "id": tool_id, "name": name, "input": {"query": query}}])
    stream_event({"type": "content_block_stop", "index": 1})
    if wait_for_result:
        emit({"type": "user", "message": {"role": "user", "content": [
            {"tool_use_id": tool_id, "type": "tool_result", "content": [{"type": "text", "text": result_text}]}]},
            "parent_tool_use_id": None, "session_id": "stand-in"})

def send_result(text):
    emit({"type": "result", "subtype": "success", "is_error": False, "result": text,
          "stop_reason": "end_turn", "session_id": "stand-in"})

def handle_control(message):
    request = message["request"]
    subtype = request["subtype"]
    request_id = message["request_id"]
    global model, effort
    if subtype == "set_model":
        if mode == "slowsetmodel":
            time.sleep(30)
        if mode == "nosetmodel":
            emit({"type": "control_response", "response": {"subtype": "error",
                  "request_id": request_id, "error": "Unsupported control request"}})
            return
        model = request["model"]
        emit({"type": "control_response", "response": {"subtype": "success",
              "request_id": request_id, "response": {"model": model}}})
    elif subtype == "get_settings":
        effective = {"effortLevel": effort} if effort else {}
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": request_id,
              "response": {"effective": effective, "sources": [], "applied": {"model": model, "effort": effort or "medium"}}}})
    elif subtype == "apply_flag_settings":
        if open(os.path.join(directory, "mode")).read().strip() == "noeffort":
            emit({"type": "control_response", "response": {"subtype": "error",
                  "request_id": request_id, "error": "Unsupported control request subtype: apply_flag_settings"}})
            return
        effort = request["settings"].get("effortLevel")
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": request_id}})
    elif subtype == "interrupt":
        emit({"type": "control_response", "response": {"subtype": "success", "request_id": request_id,
              "response": {"still_queued": []}}})
    else:
        emit({"type": "control_response", "response": {"subtype": "error", "request_id": request_id,
              "error": "Unsupported control request subtype: " + subtype}})

def hold_until_interrupted(partial_text):
    # A slow answer: waits for the interrupt request, then ends the way the real CLI does (verified on 2.1.318).
    while True:
        try:
            raw = inbox.get(timeout=0.05)
        except queue.Empty:
            continue
        if raw is None:
            sys.exit(0)
        message = json.loads(raw)
        append("stdin.jsonl", {"pid": pid, "message": message})
        if message["type"] != "control_request":
            continue
        if message["request"]["subtype"] == "interrupt" and mode == "ignoreinterrupt":
            continue
        handle_control(message)
        if message["request"]["subtype"] == "interrupt":
            assistant_blocks([{"type": "text", "text": partial_text}])
            emit({"type": "user", "message": {"role": "user", "content": [
                {"type": "text", "text": "[Request interrupted by user]"}]}, "parent_tool_use_id": None,
                "session_id": "stand-in"})
            emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": None,
                  "stop_reason": None, "session_id": "stand-in"})
            return

while True:
    raw = inbox.get()
    if raw is None:
        break
    message = json.loads(raw)
    append("stdin.jsonl", {"pid": pid, "message": message})
    if message["type"] == "control_request":
        handle_control(message)
        continue
    send_init()
    if mode == "silent":
        continue
    if mode == "limit":
        send_reply("You've hit your limit \u00b7 resets 3pm", True, "rate_limit")
        continue
    if mode == "notloggedin":
        send_reply("Not logged in \u00b7 Please run /login", True, "authentication_failed")
        sys.exit(1)
    # Only the last block holds the new question; a recap in an earlier block may quote old trigger words.
    question = json.dumps(message["message"]["content"][-1])
    if "STREAMQUESTION" in question:
        stream_text_block(["The Save button ", "is at the top right. ", "[POINT:1180,40:save button]"])
        send_result(answer)
    elif "SEARCHQUESTION" in question:
        stream_text_block(["Searching the ", "brain for the port."])
        tool_call("design-vault port", "File: /notes/design-vault.md lines 1-4\nport is 4417")
        stream_text_block(["design-vault runs ", "on port 4417."])
        send_result("design-vault runs on port 4417.")
    elif "REPEATQUESTION" in question:
        stream_text_block(["Looking."])
        tool_call("same query", "File: /notes/a.md lines 1-2\nnothing")
        tool_call("same query", "File: /notes/a.md lines 1-2\nnothing")
        tool_call("same query", "", wait_for_result=False)
        hold_until_interrupted("Looking.")
    elif "HELDQUESTION" in question:
        stream_text_block(["Part one of a long answer."])
        hold_until_interrupted("Part one of a long answer.")
    elif "TRICKLEQUESTION" in question:
        stream_text_block(["a ", "b ", "c ", "d ", "e ", "f"], pause=0.5)
        send_result("a b c d e f")
    elif "THINKINGQUESTION" in question:
        stream_event({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}})
        stream_event({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hmm"}})
        stream_event({"type": "content_block_stop", "index": 0})
        stream_text_block(["Visible."], index=1)
        send_result("Visible.")
    else:
        send_reply(answer)
    answered += 1
    if mode == "exitafterfirst" and answered == 1:
        sys.exit(0)

append("exits.jsonl", {"pid": pid})
"""#
}

// MARK: - The test Mac's own stand-in (testenv/claude-standin/claude), run as a host child process

/// Runs the real test Mac stand-in `claude` from the repo with its pauses shortened. It reads no credentials and talks to no network.
struct TestEnvClaudeStandInRun {
    static let explainText = "This menu bar holds the session controls. [CHAT] The first button starts the session. "
        + "The next ones open the chat, the session list and the settings. "
        + "Everything else on screen is not needed for now. [POINT:none]"

    /// The repo root, found from this file: Packages/ClickyCore/Tests/ClickyCoreTests/<file>.
    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    static var scriptURL: URL { repoRoot.appendingPathComponent("testenv/claude-standin/claude") }

    let logDirectory: URL
    let helperScriptURL: URL

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("testenv-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        logDirectory = folder.appendingPathComponent("log", isDirectory: true)
        helperScriptURL = folder.appendingPathComponent("fake-helper.py")
        try Self.fakeHelper.write(to: helperScriptURL, atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: logDirectory.deletingLastPathComponent()) }

    /// A one-file MCP helper: handshake, one tool list, and a search that finds port 4417.
    private static let fakeHelper = #"""
import json, sys
for raw in sys.stdin:
    message = json.loads(raw)
    if "id" not in message:
        continue
    method = message.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "search_brain"}, {"name": "read_brain_file"}]}
    else:
        result = {"content": [{"type": "text", "text": "demo-server.md: the demo server listens on port 4417."}], "isError": False}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
    sys.stdout.flush()
"""#

    /// One stream-json question; returns every stdout line as a parsed object.
    func ask(_ question: String, withHelper: Bool = false) throws -> [[String: Any]] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--model", "test-model"]
        if withHelper {
            let config: [String: Any] = ["mcpServers": ["brain": ["command": "/usr/bin/python3", "args": [helperScriptURL.path]]]]
            let data = try JSONSerialization.data(withJSONObject: config)
            arguments += ["--mcp-config", String(decoding: data, as: UTF8.self)]
        }
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "Question: \(question)"]]]]
        let input = try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8)
        let output = try Self.run(Self.scriptURL, arguments: arguments, input: input, logDirectory: logDirectory)
        return output.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    static func run(_ script: URL, arguments: [String], input: Data, logDirectory: URL) throws -> Data {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["STANDIN_LOG_DIR"] = logDirectory.path
        environment["STANDIN_TIME_SCALE"] = "0.05"
        environment["CLAUDE_CONFIG_DIR"] = logDirectory.appendingPathComponent("config").path
        environment["CODEX_HOME"] = logDirectory.appendingPathComponent("config").path
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        inPipe.fileHandleForWriting.write(input)
        try inPipe.fileHandleForWriting.close()
        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }

    /// The text deltas of the whole run, in order.
    static func textDeltas(_ lines: [[String: Any]]) -> [String] {
        lines.compactMap { line in
            guard line["type"] as? String == "stream_event", let event = line["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        }
    }

    /// The text of the last assistant text block (the final answer).
    static func lastAssistantText(_ lines: [[String: Any]]) -> String? {
        let texts: [String] = lines.compactMap { line in
            guard line["type"] as? String == "assistant", let message = line["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            return content.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        return texts.last
    }
}

@Suite("Test Mac claude stand-in rows", .serialized)
struct TestEnvClaudeStandInRowTests {
    @Test func theExplainRowStreamsTheMarkerSplitAcrossTwoDeltas() throws {
        let run = try TestEnvClaudeStandInRun()
        defer { run.cleanUp() }
        let deltas = TestEnvClaudeStandInRun.textDeltas(try run.ask("please explain this"))
        #expect(deltas.joined() == TestEnvClaudeStandInRun.explainText)
        let splitAt = deltas.firstIndex { $0.hasSuffix("[CH") }
        #expect(splitAt != nil)
        if let splitAt { #expect(deltas[safe: splitAt + 1]?.hasPrefix("AT]") == true) }
        #expect(deltas.contains { $0.contains("[CHAT]") } == false)
    }

    @Test func theLongRowIsTwentySentencesWithNoMarkerAndNoTalkOfCutting() throws {
        let run = try TestEnvClaudeStandInRun()
        defer { run.cleanUp() }
        let lines = try run.ask("give me a long answer")
        let text = try #require(TestEnvClaudeStandInRun.lastAssistantText(lines))
        #expect(TestEnvClaudeStandInRun.textDeltas(lines).joined() == text)
        #expect(text.hasSuffix(" [POINT:none]"))
        #expect(text.contains("[CHAT]") == false)
        #expect(text.contains("cut") == false)
        var sentences = 0
        var number = 1
        while number <= 20 {
            if text.contains("This is sentence number \(number) of a long answer with no chat marker.") { sentences += 1 }
            number += 1
        }
        #expect(sentences == 20)
        #expect(text.contains("sentence number 21 ") == false)
    }

    @Test func thePortRowEndsWithTheChatPartAfterTheHelpersRealAnswer() throws {
        let run = try TestEnvClaudeStandInRun()
        defer { run.cleanUp() }
        let lines = try run.ask("what port does the demo server use", withHelper: true)
        let final = try #require(TestEnvClaudeStandInRun.lastAssistantText(lines))
        #expect(final == "Your notes say the demo server listens on port 4417. [CHAT] The port is set in demo-server.md under Wiki/Projects. [POINT:none]")
        let first = TestEnvClaudeStandInRun.textDeltas(lines).joined()
        #expect(first.hasPrefix("Let me check your notes for the demo port."))
    }

    @Test func thePortRowWithoutAHelperAnswersWithTheDefaultReply() throws {
        let run = try TestEnvClaudeStandInRun()
        defer { run.cleanUp() }
        let lines = try run.ask("what port does the demo server use")
        #expect(TestEnvClaudeStandInRun.lastAssistantText(lines) == "I can see your screen. [POINT:none]")
    }

    @Test func theSaveRowAndTheSummaryAndStatusCallsStillWork() throws {
        let run = try TestEnvClaudeStandInRun()
        defer { run.cleanUp() }
        let save = try run.ask("where is the save button")
        #expect(TestEnvClaudeStandInRun.lastAssistantText(save) == "Click the Save button at the top right. [POINT:1180,40:save button:screen1]")
        let summary = try TestEnvClaudeStandInRun.run(TestEnvClaudeStandInRun.scriptURL, arguments: ["-p", "--model", "test-model"],
                                                      input: Data("recap this".utf8), logDirectory: run.logDirectory)
        #expect(String(decoding: summary, as: UTF8.self).contains("Asked where the save button is"))
        let status = try TestEnvClaudeStandInRun.run(TestEnvClaudeStandInRun.scriptURL, arguments: ["auth", "status"],
                                                     input: Data(), logDirectory: run.logDirectory)
        #expect(String(decoding: status, as: UTF8.self).contains("\"loggedIn\": true"))
    }
}
