# Clicky Fork

An over-the-shoulder assistant for the Mac, forked from [Clicky](https://github.com/farzaa/clicky) by Farza. It sits in the menu bar, and during a session you start it sees your screen, answers your questions about it and points at where to look.

This is a fork, not the official app. The official Clicky is [HeyClicky](https://www.heyclicky.com/). This fork drops upstream's paid services (AssemblyAI, ElevenLabs and the Cloudflare key proxy) and never starts at login. Every difference from upstream is listed in [docs/FORK_CHANGES.md](docs/FORK_CHANGES.md). The goal is in [docs/GOAL.md](docs/GOAL.md).

## Use it

You need the `claude` CLI (Claude Code) for a Claude plan, the `codex` CLI for a ChatGPT plan, or both.

1. Open **Clicky Fork** from Applications. It lives in the menu bar; there is no dock icon.
2. Grant **Microphone**, **Screen Recording** and **Accessibility** when the panel asks. Accessibility is for the question key and window titles.
3. Open **Settings** from the panel. Sign in to Claude or ChatGPT (each opens the CLI's own browser login; these sign-ins are the app's own, separate from any Claude Code or Codex you already use), pick a model, and choose your notes folder if you want Save.
4. Press **Start session**. The menu bar icon shows a red dot.
5. Tap right **Command** on its own and say your question; a marker beside the cursor shows it is listening. Tap right Command again to send it. The answer shows in the chat window, and a pointer flies to the spot it names.
6. Press **Stop** when done. Near-duplicate screenshots are cleaned up and the log is written. Open **Sessions** to look back, and **Save** to file a session under a project in your notes folder.

Nothing is captured, heard or sent outside a session, and nothing goes to an AI between questions. Session data stays in `~/Library/Application Support/Clicky Fork/` until you press Save.

## Build

Needs macOS 14.2 or later and Xcode.

```bash
make build   # builds and signs "Clicky Fork.app", prints its path
make test    # runs the shared-logic tests in Packages/ClickyCore
```

`make build` runs `scripts/build-app.sh`; see [scripts/README.md](scripts/README.md) for its options and how it picks the signing team.

## Credit and licence

Clicky was made by Farza and released under the MIT licence; this fork keeps that licence (see [LICENSE](LICENSE)). Upstream: [farzaa/clicky](https://github.com/farzaa/clicky).
