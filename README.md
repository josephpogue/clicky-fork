# Clicky Fork

An over-the-shoulder assistant for the Mac, forked from [Clicky](https://github.com/farzaa/clicky) by Farza. It sits in the menu bar, and during a session you start it sees your screen, answers your questions about it and points at where to look.

This is a fork, not the official app. The official Clicky is [HeyClicky](https://www.heyclicky.com/). This fork drops upstream's paid services (AssemblyAI, ElevenLabs and the Cloudflare key proxy) and never starts at login. Every difference from upstream is listed in [docs/FORK_CHANGES.md](docs/FORK_CHANGES.md). The goal is in [docs/GOAL.md](docs/GOAL.md).

## Build

Needs macOS 14.2 or later and Xcode.

```bash
make build   # builds and signs "Clicky Fork.app", prints its path
make test    # runs the shared-logic tests in Packages/ClickyCore
```

`make build` runs `scripts/build-app.sh`; see [scripts/README.md](scripts/README.md) for its options and how it picks the signing team.

## Credit and licence

Clicky was made by Farza and released under the MIT licence; this fork keeps that licence (see [LICENSE](LICENSE)). Upstream: [farzaa/clicky](https://github.com/farzaa/clicky).
