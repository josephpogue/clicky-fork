# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Goals

@docs/GOAL.md

Read docs/GOAL.md before planning any change. Section goals live in docs/goals/; each lists the code folders it governs in its front matter. Before changing code, read every goal file whose `code` covers the files you touch, plus each of its parents.

- When a change would cross a Non-goal or a Constraint, stop and ask Joseph.
- When a change alters what a section should do, edit that goal file in the same pull request, with Joseph's approval.

The v1 build design is `docs/superpowers/specs/2026-11-05-clicky-fork-design.md`.

## Overview

Clicky Fork is a macOS menu-bar assistant (no dock icon, no main window). The user starts a session from the menu bar. During a session the app listens on the microphone and transcribes speech on the Mac, saves screenshots of every display when the app or window changes or the screen changes clearly, and logs it all to a session folder. A lone tap of right Command starts a spoken question; the next lone tap sends it. The question goes, with the current screens, a short note of what happened since the last question and (when the question is about an earlier moment) that moment's screenshot, to Claude through the official `claude` CLI or to ChatGPT through the official `codex` CLI, each on the user's own subscription login kept in the app's own config folder. The answer shows in a small floating chat window, and a pointer flies to the spot its `[POINT:...]` tag names. Stop turns everything off, cleans up near-duplicate screenshots, writes `log.md`, and (when on) asks for one text-only summary. Save files a session into the user's notes folder under a project.

Nothing is captured, heard or sent outside a session, and nothing goes to any AI between questions. There are no API keys and no network calls of the app's own; the CLIs make the only AI requests.

## Architecture

- **App type:** menu bar only (`LSUIElement=true`), SwiftUI with AppKit bridging (`NSStatusItem`, `NSPanel`, `NSHostingView`), `@MainActor` UI state, async/await.
- **Shared logic:** the local Swift package `Packages/ClickyCore`, tested with `make test` (swift-testing). Target `ClickyCore` holds everything pure: contracts, question key detection, capture policy, the session store and log, the per-question payload, the providers, vault save and session browsing. Target `ClickySpeech` holds local speech (FluidAudio Parakeet, Apple Speech fallback). The app target `leanring-buddy` holds only AppKit glue and views.
- **Session:** `SessionCoordinator` (app) starts and stops the pieces; `SessionQuestionFlow` (ClickyCore actor) runs each question: transcribe, capture, pick an earlier moment, build the turn, ask, parse the point, log, and start a fresh conversation with a text recap after 15 turns or 40 images.
- **Providers:** both behind `AnswerProvider` / `ProviderAccount`. Claude: one long-lived `claude -p --input-format stream-json --output-format stream-json` process per session with `--safe-mode`, no tools and no settings, `CLAUDE_CONFIG_DIR` = the app's `providers/claude-config`; model changes use the CLI's in-place `set_model`. ChatGPT: `codex exec` then `codex exec resume <thread>` per question, `CODEX_HOME` = the app's `providers/codex-home`, low reasoning effort, the thread deleted at Stop. Both refuse an API-key login and scrub API-key variables from the child environment.
- **Speech:** `SessionSpeechPipeline` reads the microphone only between Start and Stop, splits utterances with an energy segmenter, and transcribes them with Parakeet TDT 0.6b v3 on the Mac. The model loads at app launch (about 45 s the first time on a Mac, under a second after).
- **Screen capture:** ScreenCaptureKit, all displays, the app's own windows excluded, 1280 px long side, JPEG about 75 KB. Saves on session start, each question, app or window switches and clear screen changes (32x20 grayscale thumbnail difference), at most one save every 2 s. Screens are numbered by display order. No text is ever read off a screenshot.
- **Pointing:** answers end with `[POINT:x,y:label:screenN]` in that screenshot's pixels; `PointMapper` maps it to the display and the overlay flies the pointer there along upstream's bezier arc.
- **Data:** `~/Library/Application Support/Clicky Fork/` (or `CLICKY_DATA_DIR`): `sessions/<yyyy-MM-dd-HHmmss>/` with `session.json`, `events.jsonl`, `shots.jsonl`, `shots/` and `log.md`, plus `providers/`. The only write outside it is Save, into the notes folder set in Settings (or `CLICKY_VAULT_ROOT`; `CLICKY_VAULT_DRY_RUN=1` writes nothing).

### Key Architecture Decisions

**Menu bar panel:** `NSStatusItem` plus a custom borderless non-activating `NSPanel`, dismissed by a global click-outside monitor. The icon shows a red dot while a session runs.

**Chat window:** a floating non-activating `NSPanel` whose `canBecomeKey` is false, so showing or updating it never takes keyboard focus from the user's app. Fixed-size hosting views set `sizingOptions = []` or they can render blank.

**Question key:** a listen-only `CGEvent` tap installed only during a session. A tap counts only when right Command is pressed and released within 1 s with no other key, modifier or mouse button in between.

**One provider interface:** the session, recap and log code never knows which provider answers; a usage-limit failure on Claude offers a one-tap switch to ChatGPT that carries the conversation over as a text recap.

## Key Files

| File | Purpose |
|------|---------|
| `leanring_buddyApp.swift` | Entry point; the app delegate creates the menu bar panel, starts permission polling and loads speech. Quitting stops a running session. |
| `Session/SessionCoordinator.swift` | Start and Stop: permissions check, session store, window tracker, screen recorder, speech pipeline, question key, provider; bridges `SessionQuestionFlow` to the chat state, marker and pointer. |
| `Session/QuestionMarkerPanel.swift`, `Session/PointerFlight.swift` | The listening marker beside the cursor, and the pointer flight to an answer's point. |
| `Session/SessionProviderFactory.swift` | Makes the Claude or ChatGPT provider and picks its model from Settings. |
| `QuestionKey/QuestionKeyMonitor.swift` | Session-only listen-only event tap feeding `ClickyCore/QuestionKey`. |
| `Capture/SessionScreenRecorder.swift`, `Capture/FrontmostWindowTracker.swift`, `CompanionScreenCaptureUtility.swift` | Screenshot saving during a session, app and window switch reports, multi-display capture. |
| `Windows/*.swift`, `AppWindowRouter.swift` | The chat panel, Settings, session list, session detail and Save sheet windows. |
| `Views/*.swift` | The designer's views; `ViewState.swift` holds the state they take. `--render-ui-previews <dir>` renders every state to PNG. |
| `CompanionManager.swift`, `WindowPositionManager.swift` | Permission state and polling, and the Screen Recording and Accessibility permission helpers. |
| `MenuBarPanelManager.swift`, `CompanionPanelView.swift` | The status item, the panel and its Start/Stop, Open chat, Sessions, Settings and permission rows. |
| `OverlayWindow.swift` | Full-screen transparent overlay hosting the pointer and its bezier flight on any display. |
| `AppSettings.swift` | Provider, models, notes folder, summary at Stop and the measured answer time per provider, in UserDefaults. |
| `DesignSystem.swift` | `DS` design tokens. |
| `Packages/ClickyCore/Sources/ClickyCore/` | `Contracts/`, `QuestionKey/`, `Capture/`, `SessionLog/`, `Questions/`, `Session/`, `Providers/Claude/`, `Providers/Codex/`, `Vault/`, `Browsing/`, `AppDataLocations`, `ProviderProcessSupport`. |
| `Packages/ClickyCore/Sources/ClickySpeech/` | Microphone and file sample sources, energy segmenter, Parakeet and Apple transcribers, `SessionSpeechPipeline`. |
| `testenv/` | Tart test Mac recipe for user-mock walks: stand-in `claude` and `codex`, an accessibility driver, a fake microphone and a fixture vault. Read `testenv/README.md`. |

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

- Build the environment of every `claude` or `codex` child through `ProviderProcessSupport` (which drops the API-key and OAuth-token variables) and the provider's command line type (`ClaudeCommandLine` also drops every `ANTHROPIC_*`, `CLAUDE_CODE_*` and `CLAUDECODE`), and set the app's own `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Never pass `--bare` to `claude`.
- Build question text (instructions, notes, recaps) only in `ClickyCore/Questions`, so both providers send the same thing.
- In ClickyCore, loop by index instead of calling `.enumerated().count` or similar on a sequence: it crashed at the macOS 14 deployment target.
- New windows host SwiftUI through `Windows/WindowHosting.swift` with `sizingOptions = []`, and use the `DS` tokens and `PillOutline` from `DesignSystem.swift` and `WindowComponents.swift`.
- Read only channel 0 of a microphone input with more than two channels (the test Mac's fake input has 16).
- Tests write vault files only under a temporary `CLICKY_VAULT_ROOT`, never the user's real notes folder.
- Run the `testenv/` driver commands only inside the test Mac, never on the host.

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

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
