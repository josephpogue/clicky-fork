# Plan: answers that search the brain (2026-11-06)

Builds `docs/superpowers/specs/2026-11-06-brain-context-design.md`. Read the design first; this plan only adds what was
verified, the shapes the parts share, and how the work is split.

## What the early checks decided

| Check (claude 2.1.318, codex 0.155.1) | Result | So |
|---|---|---|
| Does `--safe-mode` block `--mcp-config`? | Yes: init shows no tools and no MCP server. | With the brain on, Claude drops `--safe-mode` and keeps `--tools ""`, `--setting-sources ""`, `--strict-mcp-config`, `--disable-slash-commands`, `--no-session-persistence`, plus `--mcp-config <helper>` and `--allowedTools mcp__brain__search_brain,mcp__brain__read_brain_file` (required, or the call is denied). The init tool list is exactly the two brain tools. Time to first text was no slower (median 0.74 s with MCP, 0.82 s today). With the brain off the flags stay as today, `--safe-mode` included, plus `--include-partial-messages` so every answer streams. |
| Can Codex run the helper as its only working tool with every `CodexToolRestrictions` flag kept? | No. Subscription models are `code_mode_only`: MCP tools are reachable only from code-mode `exec`, which the restrictions turn off on purpose. With it off, no MCP call happens. | ChatGPT gets the passages from the Mac only, and no tools. `CodexToolRestrictions` is unchanged. Its instructions say to answer from the screen and the passages, and to say when the notes it was given do not cover the question. |
| Can Claude effort change in place in a stream-json session? | Yes: control request `apply_flag_settings` with `{"effortLevel": "high"}` succeeds, and `get_settings` shows the change. | Dig deeper changes both model (`set_model`) and effort in place on Claude, and restores both for the next question. Codex takes `-m` and `model_reasoning_effort` per `exec`. |

## Shapes the parts share (the foundation commit holds them)

- `Contracts/BrainContracts.swift`: `BrainPassage`, `BrainFileExcerpt`, `BrainFileRefusal`, `BrainToolName`
  (`search_brain`, `read_brain_file`, server `brain`), `BrainToolCall`, `BrainToolServer` (helper launch:
  `--index <db> --folder <a> --folder <b>`), `BrainToolText` (every tool result names its file on a `File: <path> lines a-b`
  line), `BrainToolBackend`, `AnswerEffort`, `AnswerRequest`, `AnswerProgress`.
- `AnswerProvider.answer(_:request:progress:)` streams; `stopCurrentAnswer()` ends the answer under way (a new question);
  `supportsBrainTools`. `QuestionTurn.brainNote` carries the rendered passages. `ProviderAnswer` gains the first-text time,
  the tool calls, the notes read, the tool result size and `wasCutShort`.
- Log events: `digDeeperAsked`, `passagesAttached`, `brainToolCalled`, `answerTiming`.
- `SessionFlowOutput.answerTextChanged`, `checkingNotesShown`, and `notesRead` on `answerReceived`.
- `SessionQuestionFlowDependencies`: `findPassages`, `isBrainOn`, `brainMapPaths`, `digDeeperRequest`.
- `AppDataLocations.brainIndexDatabaseURL` (`<data>/brain-index/index.sqlite`).
- `Brain/BrainFileRules.swift` (written by the lead in the foundation, since the index and the reader both call it; the
  brain-files slice owns its tests and any change).
- Stubs with their final names, filled by their slices: `Brain/BrainFileReader.swift`, `Brain/BrainIndex.swift`, `Sources/ClickyBrainTools/main.swift`, `leanring-buddy/Brain/BrainIndexService.swift`.
- Settings keys (UserDefaults): `settings.brainSearchFolderPaths` ([String]), `settings.digDeeperClaudeModel`,
  `settings.digDeeperChatgptModel`, `settings.digDeeperEffort` (`AnswerEffort` raw value, default `high`).

## Slices

Each slice is one feature end to end, owns its files, and lands as one squashed commit on `feature/brain-context`.

| Slice | Wave | Owns | Done when |
|---|---|---|---|
| brain-files | 1 | `Brain/BrainFileRules.swift`, `Brain/BrainFileReader.swift`, their tests | Path confinement and deny tests pass: symlink out, `..`, absolute paths, a search folder that is a symlink, every secret pattern. |
| brain-index | 1 | `Brain/BrainIndex.swift` and new `Brain/*` index files, tests | A fixture folder indexes, updates by mtime, ranks title and heading hits first, boosts the front-window project, and returns at most 4 passages within about 1,500 tokens above the floor. |
| brain-helper | 1 | `Sources/ClickyBrainTools/main.swift`, `Brain/BrainToolServerCore.swift`, `scripts/build-app.sh`, tests | The built app holds a signed `Contents/MacOS/ClickyBrainTools` that answers MCP `initialize`, `tools/list` (exactly two tools) and `tools/call` over stdio. |
| claude-stream | 1 | `Providers/Claude/*`, Claude tests | With a tool server the real CLI streams text, makes a brain call and is interrupted by a new question; without one the flags are today's plus `--include-partial-messages`, `--safe-mode` kept. |
| codex-stream | 1 | `Providers/Codex/*` except `CodexToolRestrictions.swift`'s list, Codex tests | Passages go in the prompt, agent messages report as they arrive, dig deeper sets model and effort for one exec, and a new question ends the exec. |
| answer-text | 1 | `Questions/*`, `SessionLog/SessionLogRenderer.swift`, `Browsing/SessionBrowsing.swift`, tests | Passage note, brain instructions, dig-deeper matching, the checking-notes rule, streaming point tags, spoken sentences, the size budget and the log lines all pass their expected values. |
| designer-views | 1 | `leanring-buddy/Views/*`, `WindowSupport/CursorBubbleLayout.swift` | Rendered previews show the folder list, the dig-deeper picker, a growing bubble with newest lines, the checking line, and the chat's notes-read list. |
| testenv-brain | 1 | `testenv/*` | Stand-ins stream text, call the bundled helper and show a first part, "Checking your notes" and a later finding; a fixture brain holds a `.env` that can never be read. |
| flow-brain | 2 | `Session/SessionQuestionFlow.swift`, flow tests | Flow tests show passages, dig deeper, streaming, the checking line, a new question ending the old answer, and the log order. |
| app-brain-settings | 2 | `AppSettings.swift`, `Brain/BrainIndexService.swift`, `Session/SessionProviderFactory.swift`, `Windows/SettingsWindowController.swift`, `leanring_buddyApp.swift` | Settings adds and removes folders and picks the dig-deeper model; the index builds at launch and refreshes at Start; Claude gets the helper. |
| app-streaming-answer | 2 | `Session/SessionCoordinator.swift`, `Session/CursorAnswerPresenter.swift`, `Session/SpokenAnswerPlayer.swift` | A growing answer grows the bubble, re-shows it after a click, speaks sentence by sentence, and fills the chat with the notes read. |

Docs (`docs/GOAL.md`, `CLAUDE.md`, `docs/FORK_CHANGES.md`) are the lead's, at integration.

## Measuring (after integration)

On about 40 note questions and 10 screen-only questions taken from Joseph's own words, with the gold note for each:
time to first text, screen-only time to first text against today's flags, how often the model searches, how often the gold
note is in the top 5 passages, and how often an answer has a correction. The numbers set the floor and the passage counts.
