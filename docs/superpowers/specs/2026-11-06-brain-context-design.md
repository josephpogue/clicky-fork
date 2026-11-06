# Clicky Fork: answers that can look in Joseph's brain (2026-11-06)

## Intent

Joseph wants Clicky to be able to use anything in his second brain (`~/brain`) when a question needs it, the way a Claude Code session reads a small map and searches on demand. In his words: "it should have 'access' to any information in my brain. Loading it in the beginning is a different story b/c that would mean more context more cost more time. The whole point is to search and respond on demand."

He is balancing response time against accuracy. He wants a first answer in a couple of seconds, and when the AI needs to dig, it keeps going and shows what it finds as it finds it.

Research behind the choices: `~/brain/wiki/_sources/research/2026-11-06-clicky-on-demand-brain-context.md` (benches on his real vault and on the CLIs, 2026-11-06). Read it before planning.

## Goals

- Any text Joseph keeps under his brain is reachable by a question, read-only.
- A question about only the screen is as fast as today, and costs no more.
- A question his notes answer gets a first answer in about 2 seconds.
- A question that needs digging shows a first part fast, then each finding as it arrives.
- "Dig deeper" asks again with a stronger model and more thinking time.

## Non-goals

- Loading the brain, or any project's pages, into the conversation up front.
- Writing to the brain. Save stays exactly as it is today and is the only write.
- A second AI request on its own when the AI is unsure. Escalation is "dig deeper" only, for now (Joseph's call).
- Embeddings or any other model-based search in this version. Keyword search on the Mac first; embeddings are the later step if real questions miss (the research measured top-5 hit 87% keywords alone, 100% with embeddings, at the cost of a 274 MB model and a slow index build).
- Reading text off screenshots. Unchanged.

## Anti-goals (a failure even if it works)

- The first sentence states a guess as fact and a later finding contradicts it. A spoken guess cannot be taken back.
- Any file outside the search folders can be read, by either provider, through any path (symlinks, `..`, absolute paths).
- The model gets any tool beyond the two brain tools below: no commands, no writes, no web.
- Anything is sent to an AI between questions.
- Screen-only questions get slower or carry note passages they do not need.

## Constraints

- Subscription CLIs only, as today. No API keys, no direct API calls.
- One AI request per question plus the optional summary at Stop. A searched answer is still one request; Claude may take several model steps inside it (Joseph accepted this).
- No path built into the code: the search folders are a setting.
- Question text (instructions, passages, recaps) is built only in `ClickyCore/Questions`, so both providers get the same thing.
- Every child process environment still goes through `ProviderProcessSupport.scrubbedEnvironment`.

## What Joseph decided

- Access: read-only, to everything in his brain, work material included. He knows this sends work notes to the AI provider when a question needs them.
- Nothing is loaded up front beyond what a question needs.
- First answer fast, findings added as they arrive.
- The answer beside the cursor stays until he clicks or types, never on a timer. A finding that arrives after he clicked shows beside the cursor again.
- Escalation is "dig deeper" for now, not automatic.

## The design

### 1. Search folders (Settings)

Settings gets a "Folders Clicky can search" list. Joseph adds `~/brain` and `~/.claude/routing` (the routing list, which names every project and its folder). Empty list means the feature is off and Clicky behaves exactly as today.

My call: a list of folders rather than one brain folder, because the routing list lives outside `~/brain` and this keeps the code free of his layout.

### 2. The brain index (on the Mac, no AI)

Clicky keeps a SQLite FTS5 (BM25) index in its data folder (`brain-index/`) over the text documents in the search folders, chunked by markdown heading, with titles and headings weighted higher.

- Indexed: markdown and plain text files. Skipped: `.git`, `node_modules`, worktree folders (`*-worktrees/`), production checkouts (`*-prod/`), build output, binaries, files over a size cap. The research measured this set at about 2,859 files, 37 MB, 28,000 chunks: 0.8 s to build, about 5 ms per query.
- Built at app launch in the background and brought up to date at session Start by file modification time. My call: during a session, files changed on disk are picked up at the next Start, not live.
- Why not let the CLIs grep the folders themselves: the research found that searching from `~/brain` hides the wiki and every repo (the brain's `.gitignore`), and a file search walked 1.5 million files and timed out in 4 of 6 runs. One index Clicky owns fixes both and works the same for both providers.

### 3. Before each question: passages from the Mac

After the question is transcribed, Clicky searches the index with the question's words and boosts chunks from the project the front window points to. My call: the project names come from the vault's project page names (like Save's project suggestion) and from the folder names of git repos found while indexing, so no file format of Joseph's tools is built into the app.

- Only chunks above a score floor go with the question: at most about 4 passages, about 1,500 tokens in total, each with its file path. When nothing clears the floor, nothing is added, so screen-only questions are unchanged.
- The floor, the counts and the boost are the builder's to tune by measurement (see Testing).

### 4. During the answer: two brain tools

The model gets exactly two read-only tools, served by a small helper program inside the app bundle that the CLI starts over MCP (stdio):

- `search_brain(query, limit)`: runs the same index search; returns passages with file paths and line numbers.
- `read_brain_file(path, start_line, line_count)`: returns lines of one text file. It refuses any path that, after resolving symlinks, is not inside a search folder, and caps how much it returns per call.

What `read_brain_file` may open (my call): any text file under a search folder, source code included, except a deny list that is never readable and never indexed: secrets (`.env*`, `*.pem`, `*.key`, `id_*` keys, files named like `credentials*`, `secrets*`, `*.p12`, `*token*`), `.git` internals, `node_modules`, and binaries. The builder found 13 `.env*` files under `~/brain/departments` (for example `ai-showcase/.env.production.local`); none of them may reach a provider. Worktree and `-prod` copies stay readable when the model asks by path, but are skipped by the index so search results are not duplicated.

The routing list and the knowledge base index are named in the instructions as the maps to read first when the passages do not cover the question. They are not attached up front. My call on finding them without a path in the code: the knowledge base index is `Wiki/index.md` under the notes folder setting (as `VaultProjects` already finds `Wiki/Projects`); the routing list is whatever `registry.md` the index holds in a search folder, named to the model by its path at session start. Clicky never parses the routing list's format.

Claude: keep `--tools ""` (no built-in tools), add `--mcp-config` for the helper with `--strict-mcp-config`, and allow only the two brain tools. The builder checks first whether `--safe-mode` blocks a server given through `--mcp-config`. If it does, drop `--safe-mode` and keep the other isolation flags (`--setting-sources ""`, `--strict-mcp-config`, `--disable-slash-commands`, `--no-session-persistence`), and measure that answers are not slower.

ChatGPT: keep every `CodexToolRestrictions` flag and add the same helper as Codex's only MCP server through `-c`. The builder confirms, by reading the tool list in the request (as `CodexToolRestrictions` was checked), that the two brain tools are the only working tools. If Codex cannot run the helper with everything else off, ChatGPT gets the passages from step 3 only and no tools. Codex's own read-only sandbox is never used for this: in the research it read files outside the folder, `~/.zshrc` included.

Cost of a screen-only question (my call): a small fixed cost is accepted, namely the two tool definitions and a few more lines of instructions in each request. No passages are added. For ChatGPT the helper starts with every `codex exec`; if that adds more than about 300 ms to an answer, ChatGPT gets the tools only on questions whose passages fell below the floor. The measurement in Testing must show screen-only answers within about 200 ms of today's.

Limits per question: at most about 6 tool calls and about 30 seconds of searching. The instructions state the limit; Clicky also ends the turn if the time runs out (Claude's stream-json interrupt) and keeps what was said so far. Numbers are the builder's to tune.

### 5. Answering as findings arrive

- Claude streams text with `--include-partial-messages`. Codex delivers whole messages between tool calls; Clicky shows each as it arrives.
- The bubble beside the cursor shows text as it arrives and grows. Spoken answers are read sentence by sentence as sentences complete.
- When the model starts a tool call, Clicky shows and says its own short line, "Checking your notes", unless the model has already said it is checking. The model never fills the wait with a guess.
- The instructions say: answer from the screen and the passages first; when they do not cover the question, say in a few words that you are checking and what, then search; never state a guess as fact; when a finding changes what you said, start that sentence with "Correction:"; keep the one-or-two-sentence default for each part.
- The point tag is acted on once it is complete, wherever it appears in the answer.
- The bubble stays until a click or key, as Joseph decided. A later part re-shows the bubble beside the cursor. When the grown answer passes the line cap, my call: the bubble shows the newest lines and the Open chat footer.
- The chat window shows the whole answer and, under it, the notes that were read (file names). The spoken answer does not read file names.
- A new question ends any answer still running (Claude: interrupt; Codex: end the process), the same way it stops the voice today. Every await re-checks that the session and conversation are still running, per the fork rules.

### 6. Dig deeper

When a question's transcript starts with "dig deeper" (allowing small speech-to-text variants), Clicky sends it as a normal new question on the stronger model and effort from Settings (default: the strongest model of the signed-in provider, high effort), then goes back to the normal model for the next question. It is one request, so it keeps the one-request rule.

My calls on what dig deeper changes: the search limits rise (about 15 tool calls and 90 seconds), the answer may run longer, the way "explain more" does today, and the passage search uses the previous question's words plus any words spoken after "dig deeper".

- Claude changes model in place with `set_model`, as today. The builder checks whether effort can change in place; if not, dig deeper changes the model only and says so in Settings.
- Codex takes model and reasoning effort per `exec`, so both change for that one question.

### 7. Log and Save

- `events.jsonl` and `log.md` record, per question: the passages attached (file paths), each brain tool call (query or path), and whether it was a dig-deeper question.
- Save is unchanged.
- The recap after 15 turns or 40 images stays. My call: passages and tool results count toward a conversation size limit too, so a session that reads many notes starts a fresh conversation with a recap before it slows down. The builder picks the limit.

## Docs to change in the same pull request (Joseph approves)

- `docs/GOAL.md`: a user story for answers that use his notes (search on demand, first answer fast, findings as they arrive, dig deeper), and an edit to the requirement that the only AI requests are one per question, to say one request may include several searches inside it.
- `CLAUDE.md`: the fork rule "no tools" becomes "only the two brain tools", the Codex restriction note, the new Settings list, the index and the helper in Architecture and Key Files.
- `docs/FORK_CHANGES.md`: the new difference from upstream.

## Testing

- ClickyCore tests (swift-testing, `make test`): indexing and the skip rules; search ranking and the project boost; the passage floor and budget; path confinement in `read_brain_file` (symlink out, `..`, absolute paths, a search folder that is itself a symlink); dig-deeper detection; parsing streamed text and tool-call events for both CLIs; ending a running answer on a new question.
- The test Mac (`testenv/`): the stand-in `claude` and `codex` learn to emit tool calls and streamed text so a user-mock walk can see a first part, "Checking your notes", and a later finding.
- Measure on 30 to 50 of Joseph's real questions (the builder asks him for them, or takes them from past session logs): time to first text, how often the model searches, how often the right note is in the top 5 passages, and how often an answer has a correction. These numbers set the floor, the counts and the limits.

## Left to the builder

- Chunk size, ranking weights, score floor, passage counts, tool call and time limits.
- The helper's name and how it shares the index code with the app (a ClickyCore target is the natural place).
- The exact skip rules and size cap for the index.
- How "dig deeper" is matched in the transcript.
- The Settings layout of the folder list and the dig-deeper model picker (the designer's job for the look).
