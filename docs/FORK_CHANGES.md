# Changes from upstream Clicky

Every way this fork differs from upstream Clicky ([farzaa/clicky](https://github.com/farzaa/clicky)), in what is built.
The goal, stories and requirements are in `docs/GOAL.md`. Update this file in the same PR as any change from upstream.

**Upstream base:** commit `e71105ce091d71dff4d89cf5d8d37ea1df460961` ("README: official HeyClicky for Mac and Windows (#148)").

## Features

| Feature | What it does | Status |
|---|---|---|
| Sessions | Start session and Stop in the menu bar panel; the icon shows an amber ring while it starts and a red dot while it runs. Screen, microphone and key tap start together only once speech, the permissions and the provider are ready; Starting can be cancelled (a cancelled Start leaves no session folder), and Stopping shows until the stop is done; the chat window shows the same phase. Microphone, screen capture and the question key run only between Start and Stop. Quitting in any phase stops cleanly and ends any sign-in in progress. Sessions a crash left behind are finished at the next launch. No launch at login. | Built |
| Question key | A lone tap of right Command (pressed and released within 1 s, no other key, modifier or mouse button in between) starts a question; the next lone tap sends it. A small marker beside the cursor shows it is listening. Replaces upstream's Control+Option push-to-talk. | Built |
| Local speech | Every utterance in a session is transcribed on the Mac with FluidAudio's Parakeet TDT 0.6b v3 (Apple Speech as the fallback) and logged. The question is the speech between the two taps. The model loads at app launch. | Built |
| Screen capture during a session | ScreenCaptureKit saves all displays at session start, at each question, on app or window switches and on clear screen changes (thumbnail difference), at most once every 2 s, as JPEG at 1280 px long side. The frontmost app and window title go with each save. No text is read off any screenshot. | Built |
| Per-question payload | Each question sends the current screens (the cursor's display marked as primary focus, with pixel sizes), the spoken question, a short note of switches and speech since the last question, and the screenshot of an earlier moment when the question refers to one (picked by the log's times and window names, on the Mac). | Built |
| Answers | Reading-length instructions rewritten from upstream's spoken ones: one or two sentences unless asked for more, no lists or markdown, ending with an optional `[POINT:x,y:label:screenN]` tag. | Built |
| Chat window | A floating panel that never takes keyboard focus, holding the session's questions and answers, a thinking state, provider errors with a fix, and the one-tap switch to ChatGPT. Replaces upstream's response overlay. | Built |
| Pointer | Upstream's overlay and bezier flight, driven by the answer's point tag on any display. | Kept, rewired |
| Claude | The official `claude` CLI on the user's own login: one long-lived stream-json process per session with safe mode, no tools, no settings, no MCP and no session files. Never `--bare`. Refuses an API-key login. Its sign-in lives in the app's own `CLAUDE_CONFIG_DIR`. | Built |
| ChatGPT | The official `codex` CLI on the user's own ChatGPT login: `codex exec`, then `codex exec resume` per follow-up, with images, low reasoning effort, every model tool turned off and the user's own Codex config ignored; the thread is deleted at Stop. Its sign-in lives in the app's own `CODEX_HOME`. Both CLIs get an allowlisted environment. | Built |
| Long sessions | After 15 turns or 40 images the app starts a fresh conversation seeded with a text recap. | Built |
| Usage-limit switch | When a Claude answer fails on the plan's usage limit, the chat window offers a one-tap switch to ChatGPT for the rest of the session (the saved provider is unchanged); the recap rides on the next question, so nothing is sent at the switch itself. | Built |
| Settings | Sign in and Sign out for Claude and ChatGPT (each CLI's own browser login), each account's state, a model picker per signed-in provider (applies from the next question), the measured answer time of each provider, the notes folder, and the summary-at-Stop switch. | Built |
| Session log and cleanup | Each session folder holds `events.jsonl`, `shots.jsonl`, `session.json`, `shots/` and a markdown `log.md` timeline. At Stop near-duplicate screenshots are deleted on the Mac (kept: question shots, the first shot of each visit, any shot 0.10 or more different from the last kept one, and one every 300 s in a long stretch), and an optional text-only summary goes at the top of the log. | Built |
| Sessions and session detail | A list of past sessions and a detail window with the timeline and its screenshots. | Built |
| Save to vault | Save suggests a project from the notes folder's `Wiki/Projects` pages, offers every project or none, writes the log and the question screenshots to `_sources/sessions/`, links it under `## Sessions` on the project page, and commits only those paths, and only when the notes folder is itself the top of a git repo. It writes only inside the notes folder, never replaces a symlink, and removes what it wrote when it fails. `CLICKY_VAULT_ROOT` and `CLICKY_VAULT_DRY_RUN=1` exist for tests. | Built |
| Shared contracts and tooling | `Packages/ClickyCore` (targets `ClickyCore` and `ClickySpeech`, tested by `make test`), `make build`, `scripts/build-app.sh`, `--render-ui-previews`. | Built |
| Test Mac recipe | `testenv/`: a Tart macOS guest with stand-in `claude` and `codex`, an accessibility driver, a fake microphone, clips and a fixture vault, for user-mock walks. | Built |
| Fork identity | Product `Clicky Fork`, bundle id `com.clickyfork.app`, no signing team in the project file. | Built |

## Removed

| What | Why |
|---|---|
| `worker/` (Cloudflare Worker key proxy) | Non-goal: no paid services and no API keys. |
| `AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAudioTranscriptionProvider.swift`, `BuddyTranscriptionProvider.swift`, `BuddyDictationManager.swift`, `BuddyAudioConversionSupport.swift`, `AppleSpeechTranscriptionProvider.swift` | Cloud speech services and upstream's push-to-talk pipeline; `ClickySpeech` replaces them (it has its own Apple Speech fallback). |
| `GlobalPushToTalkShortcutMonitor.swift` | Control+Option push-to-talk; the right Command question key replaces it. |
| `ClaudeAPI.swift`, `OpenAIAPI.swift`, `ElementLocationDetector.swift` | Direct calls to AI APIs; the app talks only to the `claude` and `codex` command line tools. |
| `ElevenLabsTTSClient.swift` | Paid text-to-speech; spoken answers are a later goal. |
| `ClickyAnalytics.swift` and the PostHog package | No analytics, no network call of the app's own. |
| Sparkle package, `appcast.xml`, `scripts/release.sh`, `SUFeedURL`, `SUPublicEDKey` | No auto-update. |
| `registerAsLoginItemIfNeeded` and all `SMAppService` use | The app never launches at login. |
| `AppBundleConfiguration.swift` | Nothing reads the Info.plist keys it served after the removals. |
| `VoiceTranscriptionProvider` Info.plist key | Chose the removed cloud provider. |
| Camera entitlement | The app never uses the camera. |
| Onboarding: `ff.mp3`, `enter.mp3`, `eshop.mp3`, `steve.jpg`, `codex-add-project.png`, the onboarding image sets, the mux.com intro video, the music, the email form that posted to submit-form.com, the x.com DM button, "Watch Onboarding Again" | Upstream marketing and data collection, not part of the fork. |
| Push-to-talk instructions and the model picker in the panel | Replaced by the session button and the Open chat, Sessions and Settings rows. |
| `DEVELOPMENT_TEAM` values in the project file | No account id in the repo; `scripts/build-app.sh` supplies the team. |
| `CompanionResponseOverlay.swift`, the waveform views and the screen-content row in the panel | The answer shows in the chat window; nothing reads the screen's content. |
| Spoken-answer summary instructions | Answers are read, not heard. |
| `leanring-buddy/AGENTS.md` file list (FloatingSessionButton, ContentView, ScreenshotManager) | Those files are not in the fork; the root `AGENTS.md` describes the app. |
