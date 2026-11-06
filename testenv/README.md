# Test Mac guide for user-mock (Clicky Fork)

How user-mock uses Clicky Fork on a throwaway test Mac. Walk the steps in this order. Every step gets a screenshot (`testenv shot`), and you `Read` the shot before you call the step passed.

Clicky Fork is a menu-bar app: no Dock icon, one icon at the top right of the screen. It never talks to a real Claude or ChatGPT here. Two stand-in programs answer in their place (see section 6), and the microphone is fake (section 5).

## 1. Build

The build is not yours. You are handed the path of the built app. It comes from `bash testenv/build-test-app.sh`, whose last line is the app path. User-mock receives that path and does not build.

## 2. Start

- Start a fresh test Mac: `testenv up clicky-fork --app "<app path>" --recipe <repo>/testenv`. It prints the test Mac's id. Write that id down and type it literally in place of `<id>` in every later command, because shell variables do not carry over between your Bash calls.
- Give the `testenv up` Bash call a 900000 ms timeout. It can wait up to ten minutes for a free slot and two more for the test Mac to start. Exit code 2 from any testenv command is the test Mac failing, not the app.
- Open the app in it: `testenv exec <id> -- bash /Users/admin/launch-app.sh`
- Commands run inside the test Mac use absolute paths under `/Users/admin/`, never `~`, because your own shell expands `~` to the wrong home.
- The app takes a moment to start. Poll `testenv exec <id> -- /Users/admin/testenv-driver/clicky-driver menu-bar-click` until it exits 0 (up to a minute). Exit 3 means the app is not running yet.

Shorthand below: `D` means `testenv exec <id> -- /Users/admin/testenv-driver/clicky-driver` (type it out in full each time).

## 3. Drive

| Command | What it does | Exit codes |
|---|---|---|
| `D read` | Prints the app's windows and its menu-bar item as a tree, one line per control: `role \| title \| identifier \| value` | 0 done, 3 app not running |
| `D wait "<text-or-identifier>" [secs]` | Waits until a control with that text or identifier is on screen (30 s default) | 0 found, 1 not found in time |
| `D click "<text-or-identifier>"` | Presses the control (waits up to 10 s for it) | 0, 1 not found |
| `D type "<text>"` | Types into the focused field | 0 |
| `D menu-bar-click` | Opens the app's menu-bar panel | 0, 1 no menu-bar item |
| `D tap-right-command` | Presses and releases the right Command key, 80 ms apart | 0 |
| `D chord-right-command <key>` | Holds right Command while pressing one letter or digit key, then releases both. Use it for the "this must not start a question" case | 0, 64 |
| `D cursor <x> <y>` | Moves the pointer to a screen point | 0 |
| `D listen [secs]` | Prints the keyboard and mouse events a listen-only tap sees. Proves the posted taps arrive | 0 |

Exit 64 is a usage mistake in the command.

Screen controls have identifiers. Click by text for the menu panel and by identifier elsewhere:

- Menu-bar panel (after `menu-bar-click`): `Start session` or `Stop session` (one button that flips), rows `Open chat`, `Sessions`, `Settings`, and `Quit Clicky Fork`.
- Chat window: `chat.latestAnswer` (the newest answer text), `chat.status`.
- Settings: `settings.signIn.claude`, `settings.status.claude` (and the ChatGPT pair).
- Sessions: `sessions.row.0` (the first row); inside a session `sessionDetail.save`; the Save sheet has `save.project`, `save.confirm`, `save.result`.

Use `D read` to see the real names on the current screen; wait for a control with `D wait` before clicking it.

The start/stop state shows in the menu-bar icon (an amber ring while it starts, a red dot while it runs). While it starts, the panel button reads `Starting...` and pressing it cancels; while it stops, it reads `Stopping...` and is disabled. Sessions does not offer Save while a session runs. The pointer and its labels are drawn by the app in a transparent full-screen window: they show in `testenv shot` and not in `D read`.

## 4. Ask a question with the right Command key

1. `D click "Start session"` (open the panel first with `D menu-bar-click`). A session is now running.
2. Press right Command once: `D tap-right-command`. Wait a second.
3. Play the clip (section 5). It plays for the clip's length; the command returns when it ends.
4. Press right Command again: `D tap-right-command`.
5. Read the answer: `D wait chat.latestAnswer 30`, then `D read`. `testenv shot <id> answer` shows the pointer.
6. Negative case: `D chord-right-command a` (right Command with another key) must not start a question.
7. `D click "Stop session"`.

## 5. Speak into the fake microphone

The fake microphone is BlackHole 16ch (the default input). Clips live in `/Users/admin/clips/`; each has a `.txt` with its exact words:

| Clip | Words |
|---|---|
| `where-is-the-save-button.wav` | where is the save button |
| `explain-more-about-that.wav` | explain more about that |
| `what-was-the-error-before.wav` | what was the error before |
| `talking-to-myself.wav` | this is just me talking to myself (not a question) |
| `limit.wav` | how close am I to the usage limit |

Play one between the two taps: `testenv play <id> mic /Users/admin/clips/where-is-the-save-button.wav`

To check that a clip reached the fake microphone, record it in the test Mac while it plays (record all 16 channels; the clip is on channel 1): `sox -q -t coreaudio "BlackHole 16ch" -c 16 /tmp/rec.wav trim 0 8` then `sox /tmp/rec.wav -n remix 1 stat` shows a maximum amplitude above 0.

Read the sidecar for the words: `testenv exec <id> -- cat /Users/admin/clips/limit.txt`

## 6. The stand-ins and their log

`claude` and `codex` are stand-ins at `/Users/admin/standin/claude` and `/Users/admin/standin/codex`. The app is started with `CLICKY_CLAUDE_BIN` and `CLICKY_CODEX_BIN` pointing at them. They answer from a keyword table (the first row whose word is in the question wins):

| Question contains | Answer |
|---|---|
| `limit` | the real CLI's usage-limit message (Claude: `You've hit your limit` ...; Codex: `You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage ...`) |
| `save` | `Click the Save button at the top right. [POINT:1180,40:save button:screen1]` |
| `explain` | a four sentence answer about the menu bar |
| `error` | an answer about a red banner saying a file could not be found |
| anything else | `I can see your screen. [POINT:none]` |

Signing in and out only flips a flag file in the stand-in's config folder (inside `/Users/admin/clicky-data`); no browser opens. Both start signed in.

Every call is logged, one JSON line each, in `/Users/admin/standin-log/claude.jsonl` and `codex.jsonl`: the command line, the names of the environment variables it received, and each message it was sent (images shown as byte counts). Count calls to check that nothing went to the AI between questions:

- `testenv exec <id> -- wc -l /Users/admin/standin-log/claude.jsonl`
- `testenv exec <id> -- tail -3 /Users/admin/standin-log/claude.jsonl`

A line with a `stdin` field is a question sent; a line with only `argv` is a process start or a status/sign-in call.

## 7. Read what the app saved

- Sessions: `testenv exec <id> -- ls -R /Users/admin/clicky-data` (each session has its own folder).
- The notes folder: `testenv exec <id> -- ls -R /Users/admin/vault/Wiki` and `cat` a page. It is a git repo: `testenv exec <id> -- git -C /Users/admin/vault log --stat`. The fixture holds three project pages: `clicky-fork.md`, `homelab.md`, `meetily-fork.md`, each with a title.
- App log: `testenv exec <id> -- cat /tmp/testenv-app.log`

## 8. Reset between walks

- `testenv exec <id> -- bash /Users/admin/reset-walk.sh` quits the app and restores everything: vault, app data (sessions and both stand-in sign-in flags) and the stand-in logs. Then run `launch-app.sh` again.
- Only the vault: `testenv exec <id> -- bash /Users/admin/reset-vault.sh`.

## 9. Finish

`testenv down <id>`. Run output (screenshots, collected logs) stays in `~/.cache/testenv/runs/<id>/`.

## For whoever changes this recipe

- Any change under `testenv/` (except `*.md`, `build/`, `test/`) makes the image stale: run `testenv bake clicky-fork --recipe <worktree>/testenv` before the next `up`.
- The stand-ins' reply tables are the `REPLY_TABLE` list at the top of each stand-in; edit one place.
- The driver is `driver/main.swift`, built on the host by `driver/build.sh` during the bake.
- Do not move `/opt/homebrew` aside in the image: tart-guest-agent's Screen Recording grant is keyed by that path, and `screencapture` would show only the wallpaper.
- A stale permission prompt on screen: `testenv exec <id> -- killall universalAccessAuthWarn UserNotificationCenter`.
- Find the app process: `testenv exec <id> -- pgrep -f 'MacOS/Clicky Fork'`.
