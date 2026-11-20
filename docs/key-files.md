# Clicky Fork: key files

| File | Purpose |
|------|---------|
| `leanring_buddyApp.swift` | Entry point; the app delegate creates the menu bar panel, starts permission polling and loads speech. Quitting stops a running session. |
| `Session/SessionCoordinator.swift` | Start and Stop: permissions check, session store, window tracker, screen recorder, speech pipeline, question key, provider; bridges `SessionQuestionFlow` to the chat state, marker and pointer. |
| `Session/QuestionMarkerPanel.swift`, `Session/PointerFlight.swift` | The listening marker beside the cursor, and the pointer flight to an answer's point. |
| `Session/CursorAnswerPresenter.swift`, `Session/CursorAttachedPanel.swift` | The answer, notice and speaker capsule beside the cursor: following, flipping, riding the pointer label, fading on a click or key. |
| `Session/SpokenAnswerPlayer.swift` | `SpeechOwner` (the one synthesizer shared by session answers and the Settings sample) and the session's answer player; `InstalledSpokenVoices` lists the Mac's voices for Settings. |
| `Views/AnswerBubbleView.swift`, `Views/SpeakingMarkerView.swift` | The answer bubble (whole cursor sentences, the More in chat footer, footer only, notice; `AnswerBubbleMetrics.fitsInBubble` measures what fits) and the speaker capsule. |
| `Views/AnswerDeliverySettingsSection.swift` | Settings' Showing answers section: Answer by chips, the Voice picker and Play sample. |
| `Views/BrainSearchSettingsSection.swift`, `Views/CheckingNotesLine.swift`, `Views/NotesReadList.swift` | Settings' "Folders Clicky can search" and dig-deeper rows, the "Checking your notes" line, and the chat's Notes read list. |
| `Brain/BrainIndexService.swift` | Keeps the brain index for the Settings folders (refresh at launch, folder change and Start), the passages for each question, the helper's command line and the map paths; its pure rules are `ClickyCore/Brain/BrainService*.swift`. |
| `Views/PanelChatRows.swift`, `Views/ChatWindowState+PanelSummary.swift` | The panel's Open chat row (answer count and the start of the last answer) and the usage-limit switch row. |
| `Session/SessionProviderFactory.swift` | Makes the Claude or ChatGPT provider and picks its model from Settings. |
| `QuestionKey/QuestionKeyMonitor.swift` | Session-only event tap feeding `ClickyCore/QuestionKey` for the question key and the chat key (listen-only, or active when either key has a regular key). |
| `Views/QuestionKeySettingsSection.swift` | Settings' Question key and Chat key sections (one view used twice): the current key, Record (Escape cancels), Reset (right Command, or right ⌘ , for the chat key), and the overlap refusal. |
| `Capture/SessionScreenRecorder.swift`, `Capture/FrontmostWindowTracker.swift`, `CompanionScreenCaptureUtility.swift` | Screenshot saving during a session, app and window switch reports, multi-display capture. |
| `Windows/*.swift`, `AppWindowRouter.swift` | The chat panel, Settings, session list, session detail and Save sheet windows. |
| `Views/*.swift` | The designer's views; `ViewState.swift` holds the state they take. `--render-ui-previews <dir>` renders every state to PNG. |
| `CompanionManager.swift`, `WindowPositionManager.swift` | Permission state and polling, and the Screen Recording and Accessibility permission helpers. |
| `MenuBarPanelManager.swift`, `CompanionPanelView.swift` | The status item, the panel and its Start/Stop, Open chat, Sessions, Settings and permission rows. |
| `OverlayWindow.swift` | Full-screen transparent overlay hosting the pointer and its bezier flight on any display. |
| `AppSettings.swift` | Provider, the question key, models, notes folder, summary at Stop, answer delivery (Text, Spoken, Both), the spoken voice, the measured answer time per provider, the search folders and the dig-deeper models and effort, in UserDefaults. |
| `DesignSystem.swift` | `DS` design tokens. |
| `Packages/ClickyCore/Sources/ClickyCore/` | `Brain/` (file rules, file reader, index, chunker, tool server core), `Contracts/`, `QuestionKey/`, `Capture/`, `SessionLog/`, `Questions/` (instructions, `AnswerParts` cursor and chat parts, streaming text, sentence splitter), `Session/` (question flow, lifecycle phases, spoken voice choice, `CursorLineState` whole-sentence cursor line, `CursorFooter`), `QuestionKey/` also holds `KeyRecordingSession` and `KeyTapHealth`, `Providers/Claude/`, `Providers/Codex/`, `Vault/`, `Browsing/`, `WindowSupport/` (pointer label layout, cursor bubble layout, the panel's chat summary, window fit, `WindowPlacement` keeping opened windows clear of the chat panel, sign-in process ending), `AppDataLocations`, `ProviderProcessSupport`. |
| `Packages/ClickyCore/Sources/ClickySpeech/` | Microphone and file sample sources, energy segmenter, Parakeet and Apple transcribers, `SessionSpeechPipeline`. |
| `Packages/ClickyCore/Sources/ClickyBrainTools/` | The brain helper: an MCP stdio server for `search_brain` and `read_brain_file`, built and signed into `Contents/MacOS/ClickyBrainTools` by `scripts/build-app.sh`. |
| `testenv/` | Tart test Mac recipe for user-mock walks: stand-in `claude` and `codex`, an accessibility driver (with `click-at` and `press-key`), a fake microphone and a fixture vault. Read `testenv/README.md`. |
