# Clicky Fork: design (2026-11-05)

The goal, user stories and requirements live in `docs/GOAL.md`. This document records how the first version is built and why. Research behind it: vault `_sources/research/2026-11-05-screen-aware-mac-assistant-clicky-rea.md`.

## Intent

Joseph wants an over-the-shoulder assistant: while he clicks through any app on his Mac, he can speak a question and get a short answer about what is on screen, with a pointer to where he should look or click. His hands are on the mouse while he asks, so voice is the main input and the answer is read, not heard. He does not want it watching or spending his Claude or ChatGPT plan when he has not started it. He wants each session kept like a lab run log so he can look back, without it filling his disk.

No existing product combines a start/stop session, voice questions, on-screen pointing, a saved session with screenshots, and his own Claude or ChatGPT plan. Upstream Clicky (farzaa/clicky, MIT, Swift) has the voice question and the pointer, so the fork adds the rest.

## Anti-goals

The build fails, even if it works, when:

- it sends anything to an AI between questions, or analyses every screenshot with an AI;
- it starts on its own or keeps running after Joseph stops it;
- answers come back as long walls of text by default;
- it bills metered API usage, or uses his subscription login in a way Anthropic's or OpenAI's terms forbid.

## Base and repo

- Fork of `farzaa/clicky` (Swift, Xcode project `leanring-buddy.xcodeproj`, macOS 14.2+). Repo `~/brain/departments/personal/projects/clicky-fork`, GitHub `josephpogue/clicky-fork`, same pattern as `meetily-fork`.
- Upstream says new development continues privately, so the fork does not try to stay mergeable with upstream. `docs/FORK_CHANGES.md` still lists every difference, as in meetily-fork.
- Remove the Cloudflare Worker proxy, AssemblyAI, ElevenLabs and the analytics client. Keep the menu-bar panel, the overlay window, multi-display capture and the `[POINT:x,y:label:screenN]` pointing and coordinate scaling.

## Session lifecycle

- The menu-bar icon has Start session and Stop. Nothing is captured or heard outside a session. No launch at login.
- While a session runs, the menu-bar icon shows it is running (Joseph's call that it must be visible; the look is the builder's).
- Stop runs the cleanup, writes the log, and (if switched on) asks for the summary.

## Asking a question

- During a session the microphone is on and every utterance is transcribed on the Mac into the session log.
- A tap of right Command on its own (pressed and released with no other key) starts a question; the next lone tap sends it. The question is the transcribed speech between the two taps. FluidVoice already uses right Option, so there is no clash.
- My call: a small marker near the cursor shows while a question is being taken, so Joseph knows the first tap registered.
- Speech transcription runs on the Mac. My call: use a local model of the Parakeet class, which beat Whisper on Joseph's own audio in the 2026-09-24 dictation bench on this M4 Pro (see vault `Wiki/Projects/meeting-assistant.md`); upstream's `AppleSpeechTranscriptionProvider` is the fallback. The builder may pick another local engine after testing on his voice.

## What goes to the AI per question

Each question sends:

1. Fresh screenshots of every display, the cursor's display labelled as primary focus, sized the way Clicky sizes them (long side about 1280 to 1456 px) and labelled with pixel dimensions.
2. The spoken question.
3. A short text note of what happened since the last question: app and window switches by their names, with times, and what Joseph said out loud.
4. When the question is about an earlier moment ("that error a few minutes ago"), the screenshot from that moment as well. How the app picks it (window names and log times, or asking the model which logged moment it means) is the builder's choice, within the rule that no AI looks at screenshots outside a question.

The conversation stays in one long-lived CLI session, so earlier questions and answers are remembered. My call: when the session's context grows long, the app starts a fresh CLI session seeded with a short text recap, so answers stay fast and old screenshots do not pile up. The threshold is the builder's.

No text is read off screenshots (Joseph does not trust Apple's text reader, and Clicky and Cluely do without it).

## Answers

- The instructions follow Clicky's: one or two sentences by default; longer only when Joseph asks to explain more; plain sentences, no lists or markdown; refer to specific things on screen; no closing question like "want me to show you?". Rewritten for reading, not speech.
- The answer shows in a small chat window, and the pointer overlay moves to the spot when the answer carries a point tag. The chat window holds the whole session's conversation.
- The chat window's look is the designer's job; Joseph wants it glanceable while his hands are on the mouse.

## AI providers and sign-in

- Claude: the official `claude` CLI on Joseph's own subscription login, one long-lived `claude -p --input-format stream-json --output-format stream-json` process per session, with screenshots sent inline. A minimal setup (no Joseph CLAUDE.md, no MCP servers, safe mode) keeps it fast: the 2026-11-05 bench answered in 2.7 s, follow-ups in 2.4 s, about 1.5k tokens. Never `--bare` (it ignores the login), never a direct API call with the login token.
- ChatGPT: the official `codex` CLI on Joseph's ChatGPT Plus login, with images passed to it. The builder confirms on this Mac how to hold a multi-turn session with images through Codex and what latency it gives. ChatGPT ships in v1 even if it is slower than Claude (Joseph's call); Settings shows the measured answer time of each. Its main use is as the fallback when Joseph's Claude plan runs out.
- My call: when a Claude answer fails because the plan's usage limit is reached, the chat window says so and offers a one-tap switch to ChatGPT for the rest of the session, carrying the conversation over as a text recap.
- Both providers sit behind one shared provider interface from the start, so the session, recap and logging code does not care which one answers.
- Each provider gets its own config folder inside the app's data folder (for Claude `CLAUDE_CONFIG_DIR`, for Codex `CODEX_HOME`), so the app's sign-ins are separate from Joseph's own Claude Code and Codex.
- Settings has Sign in to Claude and Sign in to ChatGPT buttons; each runs the CLI's own login, which opens the browser, and Settings shows each account's state with a Sign out.
- Settings has a model picker listing the models of each signed-in provider. A change applies from the next question, mid-session included. The log records the model of every answer.

## Screen recording during a session

- Capture with ScreenCaptureKit, all displays.
- Save a screenshot when Joseph asks a question, when the frontmost app or window changes, and when the screen changes clearly (compare a small thumbnail with the last saved one). At most one save every two seconds.
- Save compressed (JPEG or HEIC) at the size sent to the AI, about 150 KB each. Estimate: 30 to 60 MB for a busy hour before cleanup.
- Record the frontmost app name and window title with each screenshot and each switch.

## Cleanup at Stop

Runs on the Mac, no AI. Keep: every screenshot tied to a question, the first screenshot of each app or window visit, and one screenshot per long stretch on one screen. Delete screenshots that look almost the same as the one kept before them. Estimate: 5 to 10 MB per hour after cleanup.

## Session log

- One folder per session in the app's data folder: a markdown log plus a `shots/` folder, modelled on the lab runner's run logs.
- The log is a timeline: time, app and window, what Joseph said, each question, each answer with its model, and a link to the screenshot beside each step.
- A short summary at the top, written by one text-only AI request at Stop. A setting turns it off.
- Sessions are listed in the app so Joseph can reopen one.

## Saving to the vault

- Copy meetily-fork's flow (`docs/GOAL.md` there, "Saving the note files it in the vault under a project Joseph confirms"; code `assistant_list_vault_projects` in `frontend/src-tauri/src/assistant/commands.rs`): the session is saved in the app automatically; Save suggests a vault project from the `~/brain/wiki/Wiki/Projects` pages and offers every project plus No project.
- What Save writes (Joseph's call, 2026-11-05): the markdown log plus only the screenshots tied to his questions, about 1 MB per session, into a new `_sources/sessions/` folder in the vault; a link under a `## Sessions` heading on the chosen project page; then a git commit, as meetily's save does (`note.rs`). The other screenshots stay in the app, and the vault copy of the log links to them while they exist.
- The only vault write is behind the Save button. A vault-root override and a dry-run switch exist for tests, as in meetily-fork.

## Permissions

Microphone, Screen Recording, and Accessibility (for the right Command tap and window titles). On Sequoia 15.7.7 macOS asks about monthly to re-approve screen recording; the app explains this the first time and cannot avoid it.

## Testing

The meeting-assistant project has a Tart test Mac and a `claude -p` spawn pattern to reuse. Tests cover the lone-tap detection, capture throttling and change detection, cleanup selection, the per-question payload, the recap restart, and the Save target, with the vault redirected.

## Later

- Clicking and typing for Joseph (reference: Keugene11/cluely, and HeyClicky's agent mode, which reviewers found slow and unreliable).
- Spoken answers using the Mac's built-in voices.

## Left to the builder

Thumbnail comparison method and thresholds, image format, how an earlier screenshot is picked, the recap threshold, the transcription engine after testing, internal structure, and the chat window and marker look (with the designer).
