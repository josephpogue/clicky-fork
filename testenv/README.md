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
| `D click-at <x> <y>` | Moves the pointer to a screen point and clicks it with a real left mouse down and up. Use it to prove a click hides the answer text | 0, 64 |
| `D press-key <key>` | Presses and releases one letter or digit key with no modifier (a plain typed key). Use it to prove typing hides the answer text | 0, 64 |
| `D cursor <x> <y>` | Moves the pointer to a screen point | 0 |
| `D listen [secs]` | Prints the keyboard and mouse events a listen-only tap sees. Proves the posted taps arrive | 0 |

Exit 64 is a usage mistake in the command.

Screen controls have identifiers. Click by text for the menu panel and by identifier elsewhere:

- Menu-bar panel (after `menu-bar-click`): `Start session` or `Stop session` (one button that flips), rows `Open chat`, `Sessions`, `Settings`, and `Quit Clicky Fork`.
- Beside the cursor (a small window with no title, listed by `D read` only while it shows): `cursor.answer` (the answer text; its value is the whole answer even when the bubble cuts it), `cursor.notice` (a notice such as a failed Start or the usage limit), `cursor.answer.more` (the footer "The rest is in Open chat, in the menu bar", shown only when the answer is cut), `cursor.speaking` (the speaker capsule while an answer is read aloud and no text shows).
- Chat window (opens only after `Open chat` in the panel): `chat.latestAnswer` (the newest answer text), `chat.status`.
- Settings: `settings.signIn.claude`, `settings.status.claude` (and the ChatGPT pair).
  Close Settings by clicking its red close button (top-left corner of the window) with `D click-at <x> <y>`: the tree cannot name that traffic-light button, so take `testenv shot` and find it. It sits at about `265 39` when Settings opens on its own, and further left (about `70 38`) when the chat window is open too. After it, `D read` lists no `settings.nswindow` (if it still does, click once more: the first click can only focus the window). Do not use `osascript`: it raises a System Events permission prompt that covers the screen.
- Sessions: `sessions.row.0` (the first row); inside a session `sessionDetail.save`; the Save sheet has `save.project`, `save.confirm`, `save.result`.

Use `D read` to see the real names on the current screen; wait for a control with `D wait` before clicking it.

The start/stop state shows in the menu-bar icon (an amber ring while it starts, a red dot while it runs). While it starts, the panel button reads `Starting...` and pressing it cancels; while it stops, it reads `Stopping...` and is disabled. Sessions does not offer Save while a session runs. The pointer and its labels are drawn by the app in a transparent full-screen window: they show in `testenv shot` and not in `D read`.

## 4. Ask a question with the right Command key

1. `D click "Start session"` (open the panel first with `D menu-bar-click`). A session is now running.
2. Press right Command once: `D tap-right-command`. Wait a second.
3. Play the clip (section 5). It plays for the clip's length; the command returns when it ends.
4. Press right Command again: `D tap-right-command`.
5. Read the answer: `D wait cursor.answer 30`, then `D read`; the chat window does not open at Start, so `chat.latestAnswer` exists only after `Open chat` from the panel. `testenv shot <id> answer` shows the bubble beside the cursor and the pointer. Moving the pointer (`D cursor <x> <y>`) keeps the bubble and it follows. Then `D click-at <x> <y>` on an empty spot, or `D press-key a`, hides it: `D wait cursor.answer 3` now fails and `D read` shows no `cursor.answer`.
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
| `what-port-does-the-demo-server-use.wav` | what port does the demo server use |
| `how-do-i-deploy-this.wav` | how do I deploy this |
| `what-is-in-the-env-file.wav` | what is in the env file |
| `is-this-the-right-build-correction.wav` | is this the right build, correction |
| `tell-me-something-long.wav` | tell me something long |
| `say-something-slow.wav` | say something slow |
| `dig-deeper-on-the-deploy.wav` | dig deeper on the deploy |

The last seven are for the brain search walk (section 6b).

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
| `port`, `deploy`, `secret`, `env`, `correction` | the brain rows, section 6b (Claude only, and only when the brain is on; with it off they get the default answer) |
| `long` | Claude: a 20 sentence answer streamed over about 6 s |
| `slow` | Claude: one word every half second for 30 s; Codex: a 30 s wait before one short answer |
| starts with `dig deeper` (checked before every row) | `Digging deeper on <model>, effort <effort>.` with the model and effort of that call |
| anything else | `I can see your screen. [POINT:none]` |

Signing in and out only flips a flag file in the stand-in's config folder (inside `/Users/admin/clicky-data`); no browser opens. Both start signed in.

Every call is logged, one JSON line each, in `/Users/admin/standin-log/claude.jsonl` and `codex.jsonl`: the command line, the names of the environment variables it received, and each message it was sent (images shown as byte counts). Count calls to check that nothing went to the AI between questions:

- `testenv exec <id> -- wc -l /Users/admin/standin-log/claude.jsonl`
- `testenv exec <id> -- tail -3 /Users/admin/standin-log/claude.jsonl`

The summary call (plain `claude -p`, no `--input-format`, prompt on stdin, plain text back) logs one line whose `stdin` is `{"kind":"summary","text":...}` and prints one plain sentence (`Asked where the save button is and about an earlier error.`), which becomes the session title. Questions use `--input-format stream-json` and log one `stdin` line per message.

A line with a `stdin` field is a question sent; a line with only `argv` is a process start or a status/sign-in call.

## 6b. Brain search walk

With search folders set, the app gives Claude a helper that searches a notes folder, and the Claude stand-in uses it the way the real CLI would: text arrives a few words at a time, then a tool call, then more text. ChatGPT (Codex) gets no tools; the Mac finds the passages and puts them in the prompt.

**The fixture brain** is `/Users/admin/brain-fixture` (invented notes): `Wiki/Projects/demo-server.md` (says the demo server listens on port 4417), `Wiki/Projects/release.md` (deploys go through the release script; test builds use Release), `Wiki/index.md`, and `projects/demo-app/` with `README.md`, a secret `.env` (`SENTINEL_SECRET=never-shown-8812`), a `.git/` folder, and `link-out.md`, a symlink to `/Users/admin/outside-secret.md` (holds `OUTSIDE-SENTINEL-5531`). `launch-app.sh` writes the app setting `settings.brainSearchFolderPaths` to that one folder before it opens the app. Check: `testenv exec <id> -- defaults read com.clickyfork.app settings.brainSearchFolderPaths`.

**Brain off** (empty list, Clicky as before): `testenv exec <id> -- bash /Users/admin/launch-app.sh brain-off`. Quit the app first (`reset-walk.sh` does).

Steps (start a session, then for each: tap right Command, play the clip, tap right Command, `D read`, `testenv shot`). Use Claude first, then ChatGPT from Settings for step 7. Look for the text with `D read` (`cursor.answer`, `cursor.notice`) and in the chat window (`chat.latestAnswer`; Open chat).

1. `what-port-does-the-demo-server-use`: within about a second the cursor bubble shows `Let me check your notes for the demo port.` (the first part). Then a finding replaces or follows it: `Your notes say the demo server listens on port 4417.` The chat shows the answer and a Notes read list that names `demo-server.md`. The 4417 comes from the helper, so seeing it proves the search ran on the fixture brain.
2. `how-do-i-deploy-this`: the stand-in starts its search call at once (no preamble text) and the search takes 3 s, so the bubble shows the app's own `Checking your notes` during that wait (shoot at about 1 s after the send tap), then `Deploys go through the release script in your notes.` Notes read lists `release.md`.
3. `what-is-in-the-env-file`: the answer is `I can't open that file: That file is never readable: it may hold secrets.` The secret value never shows anywhere. Notes read does not list the `.env` as read.
4. `is-this-the-right-build-correction`: first `From the screen this looks like the Debug build.`, then the later finding `Correction: your notes say test builds use Release.` Both parts are visible in the chat answer, the correction last.
5. `tell-me-something-long`: the bubble keeps showing the newest lines as the sentences stream in (over about 6 s) and ends with the cut footer pointing to Open chat; `cursor.answer` holds the whole text.
6. `say-something-slow` and then, after about 3 s, a second question (`where-is-the-save-button`): the slow answer stops at the next question (it would otherwise run 30 s) and the second answer arrives at once. In `claude.jsonl` the second question is preceded by a `control_request` with subtype `interrupt`.
7. Dig deeper: play `dig-deeper-on-the-deploy` (only the spoken words matter). The answer reads `Digging deeper on <the stronger model>, effort high.` Ask `where-is-the-save-button` next: it is answered on the normal model again (check `claude.jsonl` for `set_model` and `apply_flag_settings` going out and coming back). With ChatGPT selected the answer reads `Digging deeper on <model>, effort high.` from the call's `-m` and `-c model_reasoning_effort` flags (`codex.jsonl` argv shows them).
8. ChatGPT with passages: select ChatGPT in Settings, close Settings, Stop and Start the session again (a running session keeps the provider it started with), then ask the port question. The answer starts `From demo-server.md:` followed by the sentence under its heading, which proves the Mac put the passages in the prompt (`codex.jsonl` `prompt` holds a `Notes from the user's own files` block). `codex.jsonl` argv must show no MCP or tool flags.

**Checks from the logs** (run after the walk; `<id>` typed literally):

- The helper ran: `testenv exec <id> -- grep -c '"mcp"' /Users/admin/standin-log/claude.jsonl` is more than 0; `grep '"mcp_config"' /Users/admin/standin-log/claude.jsonl` shows the `ClickyBrainTools` command and its `--folder`; `grep '"dir": "from_helper"'` shows its replies; the init line has `mcp__brain__search_brain` and `mcp__brain__read_brain_file` as its only tools.
- Secrets never left the Mac: `testenv exec <id> -- grep -c never-shown-8812 /Users/admin/standin-log/claude.jsonl /Users/admin/standin-log/codex.jsonl` and the same for `OUTSIDE-SENTINEL-5531` and `GITDIR-MARKER-2290` must print 0 for every file. A count above 0 is a bug in the app or helper, not in the stand-in: the stand-in logs everything it was sent and everything the helper answered.
- With brain off, `grep -c '"mcp_config"'` is 0 and no question carries a `Notes from the user's own files` block.

Reset: `testenv exec <id> -- bash /Users/admin/reset-walk.sh` (restores the brain fixture and the outside file too); only the brain: `testenv exec <id> -- bash /Users/admin/reset-brain.sh`.

For a host run of the stand-ins (no test Mac): `STANDIN_LOG_DIR=<dir> STANDIN_TIME_SCALE=0.05 testenv/claude-standin/claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model m --mcp-config '<json naming a helper>'` and pipe user lines in. `STANDIN_TIME_SCALE` shortens every pause.

## 7. Read what the app saved

- Sessions: `testenv exec <id> -- ls -R /Users/admin/clicky-data` (each session has its own folder).
- The notes folder: `testenv exec <id> -- ls -R /Users/admin/vault/Wiki` and `cat` a page. It is a git repo: `testenv exec <id> -- git -C /Users/admin/vault log --stat`. The fixture holds three project pages: `clicky-fork.md`, `homelab.md`, `meetily-fork.md`, each with a title.
- App log: `testenv exec <id> -- cat /tmp/testenv-app.log`

## 8. Reset between walks

- `testenv exec <id> -- bash /Users/admin/reset-walk.sh` quits the app and restores everything: vault, brain fixture, app data (sessions and both stand-in sign-in flags) and the stand-in logs. Then run `launch-app.sh` again.
- Only the vault: `testenv exec <id> -- bash /Users/admin/reset-vault.sh`. Only the brain fixture: `bash /Users/admin/reset-brain.sh`.

## 9. Finish

`testenv down <id>`. Run output (screenshots, collected logs) stays in `~/.cache/testenv/runs/<id>/`.

## For whoever changes this recipe

- Any change under `testenv/` (except `*.md`, `build/`, `test/`) makes the image stale: run `testenv bake clicky-fork --recipe <worktree>/testenv` before the next `up`.
- The stand-ins' reply tables are the `REPLY_TABLE` list at the top of each stand-in; edit one place.
- The driver is `driver/main.swift`, built on the host by `driver/build.sh` during the bake.
- Do not move `/opt/homebrew` aside in the image: tart-guest-agent's Screen Recording grant is keyed by that path, and `screencapture` would show only the wallpaper.
- A stale permission prompt on screen: `testenv exec <id> -- killall universalAccessAuthWarn UserNotificationCenter`.
- Find the app process: `testenv exec <id> -- pgrep -f 'MacOS/Clicky Fork'`.
