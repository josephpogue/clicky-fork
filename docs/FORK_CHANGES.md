# Changes from upstream Clicky

Every way this fork differs from upstream Clicky ([farzaa/clicky](https://github.com/farzaa/clicky)), built or planned.
The goal, stories and requirements are in `docs/GOAL.md`. Update this file in the same PR as any change from upstream.

**Upstream base:** commit `e71105ce091d71dff4d89cf5d8d37ea1df460961` ("README: official HeyClicky for Mac and Windows (#148)").

## Features

| Feature | What it does | Status |
|---|---|---|
| Sessions | The user starts and stops a session from the menu bar; nothing is watched outside one. Foundation has the Start session / Stop session button and the icon with a red dot while one runs; it only flips state. | Planned for: the sessions slice |
| Question key | Right Command on its own starts and ends a spoken question. | Planned for: the question key slice |
| Local speech | Speech-to-text on the Mac (FluidAudio, Parakeet), with no AI request. The `ClickySpeech` package target links FluidAudio already. | Planned for: the speech slice |
| Session log | Each question, answer, app switch and spoken line, with its time and screens, kept on the Mac. | Planned for: the session log slice |
| Save to vault | Writes the log and the screens tied to questions into the notes folder and links it from a project page. | Planned for: the Save slice |
| Claude and ChatGPT sign-in | Claude and ChatGPT through their own command line tools on the user's own login, with a switch between them. | Planned for: the providers slice |
| Shared contracts and tooling | `Packages/ClickyCore` (contract types, data folder locations, CLI process helpers, tests), `make test`, `make build`, `scripts/build-app.sh`, `--render-ui-previews`. | Built (foundation) |
| Fork identity | Product `Clicky Fork`, bundle id `com.clickyfork.app`, no signing team in the project file. | Built (foundation) |

## Removed

| What | Why |
|---|---|
| `worker/` (Cloudflare Worker key proxy) | Non-goal: no paid services and no API keys. |
| `AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAudioTranscriptionProvider.swift`, `BuddyTranscriptionProvider.swift`, `BuddyDictationManager.swift`, `BuddyAudioConversionSupport.swift`, `AppleSpeechTranscriptionProvider.swift` | Cloud speech services; local speech replaces them in the speech slice. |
| `GlobalPushToTalkShortcutMonitor.swift` | Control+Option push-to-talk; the question key slice writes its own key handling. |
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
