# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Goals

@docs/GOAL.md

Read docs/GOAL.md before planning any change. Section goals live in docs/goals/; each lists the code folders it governs in its front matter. Before changing code, read every goal file whose `code` covers the files you touch, plus each of its parents.

- When a change would cross a Non-goal or a Constraint, stop and ask Joseph.
- When a change alters what a section should do, edit that goal file in the same pull request, with Joseph's approval.

The v1 build design is `docs/superpowers/specs/2026-11-05-clicky-fork-design.md`.

## Read on demand

| Before you... | Open |
|---|---|
| change how a session, provider, brain search, speech, capture, pointing or answer display works, or need to know what the app does end to end | `docs/architecture.md` |
| change the chat window, cursor answer panel, menu bar panel, question key or chat key, or the usage-limit switch | `docs/architecture.md` (Key Architecture Decisions) |
| look for which file holds something, or add, rename or delete a source file | `docs/key-files.md` |

## Overview

Nothing is captured, heard or sent outside a session, and nothing goes to any AI between questions. There are no API keys and no network calls of the app's own; the CLIs make the only AI requests.

## Code layout and data

- **Shared logic:** the local Swift package `Packages/ClickyCore`, tested with `make test` (swift-testing; it runs `ClickySpeechTests` on their own after the rest, because their 2 s deadline checks miss under the full suite's process-blocking tests, so keep the two runs apart). Target `ClickyCore` holds everything pure: contracts, question key detection, capture policy, the session store and log, the per-question payload, the providers, vault save and session browsing. Target `ClickySpeech` holds local speech (FluidAudio Parakeet, Apple Speech fallback). The app target `leanring-buddy` holds only AppKit glue and views.
- **Data:** `~/Library/Application Support/Clicky Fork/` (or `CLICKY_DATA_DIR`): `sessions/<yyyy-MM-dd-HHmmss>/` with `session.json`, `events.jsonl`, `shots.jsonl`, `shots/` and `log.md`, plus `providers/` and `brain-index/`. The only write outside it is Save, into the notes folder set in Settings (or `CLICKY_VAULT_ROOT`; `CLICKY_VAULT_DRY_RUN=1` writes nothing).

## Build & Run

```bash
# Build the app (Debug by default; the last printed line is the path of Clicky Fork.app)
bash scripts/build-app.sh            # or: make build
bash scripts/build-app.sh --configuration Release
bash scripts/build-app.sh --install  # also copies the app to /Applications

# Run the shared-logic tests (Packages/ClickyCore)
make test

# Render SwiftUI previews to PNG files without opening the app (no permission prompts)
"<app>/Contents/MacOS/Clicky Fork" --render-ui-previews <folder>
```

Build only through `scripts/build-app.sh`. It signs with `$CLICKY_DEVELOPMENT_TEAM`, else with the team of the first "Apple Development" identity in the keychain, so macOS permissions (screen recording, microphone, accessibility) stick across rebuilds. With no identity it signs ad hoc and prints a warning, and permissions need re-granting after each rebuild. No team id is stored in the project file. The script never launches the app.

Merges to `main` install the app automatically: the deploy-on-merge job (My-Life `automations/deploy-on-merge`) builds origin/main and replaces `/Applications/Clicky Fork.app` within 5 minutes, waiting while a session is live.

Known non-blocking warnings: Swift 6 concurrency warnings, deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Fork rules

- Build the environment of every `claude` or `codex` child only through `ProviderProcessSupport.scrubbedEnvironment`: an allowlist (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`, `TERM`, `__CF_USER_TEXT_ENCODING`) plus the app's own `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Every `codex exec` and `exec resume` carries `CodexToolRestrictions.arguments`. Never pass `--bare` to `claude`. The only tools `claude` may get are the two brain tools, and only through the bundled helper.
- Any step in the question flow or a provider that awaits re-checks that the session or conversation is still running afterwards, and ends any conversation it opened if Stop landed meanwhile.
- Build question text (instructions, notes, recaps) only in `ClickyCore/Questions`, so both providers send the same thing.
- In ClickyCore, loop by index instead of calling `.enumerated().count` or similar on a sequence: it crashed at the macOS 14 deployment target.
- New windows host SwiftUI through `Windows/WindowHosting.swift` with `sizingOptions = []`, and use the `DS` tokens and `PillOutline` from `DesignSystem.swift` and `WindowComponents.swift`.
- Read only channel 0 of a microphone input with more than two channels (the test Mac's fake input has 16).
- Tests write vault files only under a temporary `CLICKY_VAULT_ROOT`, never the user's real notes folder.
- Spoken output goes through `SpeechOwner.shared` (one `AVSpeechSynthesizer`; `SpeechTurnTracker` in ClickyCore decides who is reported speaking), so a Settings sample and a session answer never talk over each other. Never create another `AVSpeechSynthesizer`.
- A pointer flight carries a token (`PointerFlightTokens`): its hold and return timers and `finishFlight` act only for the current flight, never one a newer flight or Stop replaced. A new question ends a flight with `endCurrentFlightByReturningToCursor()`, never `cancelFlight` (which hides the whole overlay). The target counts in the bubble's clearance frame only while the pointer holds at it.
- Every file the brain helper or the index opens goes through `BrainFileRules` and, for reads, `BrainFileReader` (realpath, inside a search folder, never-readable checked on the given and the resolved path, nothing below a hidden folder inside the search folder). Open such a file once, by its resolved path, with `O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK`, `fstat` the descriptor (a regular file with one link, under the size cap), re-check the descriptor's `F_GETPATH` path (the on-disk spelling) against the same rules, comparing with the folders' own `F_GETPATH` form, never byte-equality with the checked path (the reader), and read from that descriptor; never re-open by path. A search folder may not be `/`, the home folder, a folder that contains it, or `~/Library` or anything inside it. Tests and benches use temporary folders, never `~/brain` or a real `.env`.
- Start the brain helper only with `BrainToolServer.helperArguments`: it passes `--folders-file <data>/brain-index/folders.json`, which the app writes only through `BrainServiceFolderListWriter.writeNewest()` (serialized; it reads the current lists itself, never a caller's snapshot) on every folder-list change and after each index run (`{"folders": [...], "indexedFolders": [...]}`, the second naming what the last completed update covered) and the helper re-reads on every tool call: it uses the intersection with its launch folders, so a removed folder is closed at once, and `search_brain` says when a folder is still being indexed instead of "No notes matched". Passages use the same intersection at each question. A search filtered by the folders pages through the ranked rows until it has enough readable hits, never a fixed over-fetch. Index builds run on their own serial `DispatchQueue`, never on Swift's cooperative pool.
- A new question during a running answer ends it: the flow shows listening first, then `stopCurrentAnswer()`, which returns only once the ended answer has returned. Work for an ended question is dropped by the flow's question serial. Every answer report in `SessionFlowOutput` carries the question's `answerNumber`; each number gets one `answerReceived` or one `answerCutShort`, or nothing, and the flow re-checks `isCurrent(serial)` after every await before an output call. `GrowingAnswerChatState` keys chat cards by that number and drops reports for a number that is not current; nothing reaches the app after Stop began. Codex answer state is keyed by an answer token.
- Run the `testenv/` driver commands only inside the test Mac, never on the host.
- App-target logic that needs a test goes in a new file in `Packages/ClickyCore`: the app target has no test target because the GUI never launches on the build Mac.

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table in `docs/key-files.md` with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update `docs/architecture.md` if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
