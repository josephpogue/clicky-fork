# Clicky Fork: a short cursor line and a chat key (2026-11-08)

## Intent

Long answers get cut off in the bubble beside the cursor today: past about 9 lines the bubble stops and says "The rest is in Open chat, in the menu bar", and the only way to the rest is the menu-bar panel. Joseph wants the cursor to carry only what fits and the chat window to carry the rest, with a key to bring the chat window up during a session.

In his words: "I want for Clicky to not cut off anything in the cursor response and if its too long it should go in the chat window." And: "The responses on the cursor needs to be as short as possible." The hotkey he had in mind is right Command + comma, "but let me change it if needed like the voice hotkey". The chat window opens "only on the hotkey for now".

Background: upstream Clicky had the same length rule (one or two sentences by default) but spoke every answer, so it never had to fit text on screen. The fork shows text, so the length now has to be enforced.

## Goals

- Nothing beside the cursor is ever cut off, mid-sentence or mid-line, by any path (streaming, notes search, corrections, notices).
- A short answer shows in full beside the cursor, exactly as today.
- A long answer shows one short line beside the cursor, and the whole answer is in the chat window.
- During a session, right Command + comma opens the chat window, and pressing it again closes it.
- The chat key can be changed in Settings the same way as the question key.

## Non-goals

- The chat window opening by itself. It opens only from the chat key or the menu-bar panel's Open chat row (Joseph: "open only on the hotkey for now").
- Scrolling, clicking or any input inside the cursor bubble. It stays a panel that ignores the mouse and never takes a key.
- Changing how the question key works, including whether a question-key combination tells left from right.
- The chat key outside a session. The key tap exists only during a session, as today.
- A second AI request to shorten an answer. The model writes both parts in the one request.

## Anti-goals (a failure even if it works)

- A bubble that shows the start of a sentence or paragraph and stops.
- The chat key typing a comma, or opening the front app's Settings, when pressed with right Command.
- Left Command + comma stops opening Settings in the user's other apps.
- The chat window taking keyboard focus from the user's app when it opens.
- The spoken answer and the bubble saying different things.

## The design

### What the model writes

Every answer has a cursor part, and a long answer also has a chat part.

- The cursor part is the answer itself in one short sentence (two at most), written to stand alone. It is never a lead-in such as "Here is how that works."
- When the answer needs more than that, the model writes a marker after the cursor part and then the chat part: the fuller explanation, steps or detail.
- A short answer has no marker and no chat part. It looks exactly like today's answers.
- The point tag stays at the very end of the whole answer, as today.
- The instructions live in `ClickyCore/Questions/AnswerInstructions.swift`, so Claude and ChatGPT get the same rule. The marker's exact spelling is the builder's call; it must be something the model would not write by accident, and it is hidden while half-written the same way a half-written point tag is today (`StreamingAnswerText`).
- "Explain more", "go step by step" and "dig deeper" answers follow the same shape: a short cursor part, and the long answer in the chat part.

### Beside the cursor

- The bubble shows the cursor part only. Text after the marker never shows beside the cursor.
- When there is a chat part, a footer under the cursor part says "More in chat: " followed by the current chat key's name (for example "Right ⌘ ,"). It replaces today's "The rest is in Open chat, in the menu bar" and "The start is in Open chat, in the menu bar".
- The bubble never cuts text. It shows only whole sentences that fit under today's height cap (`CursorBubbleLayout.maximumBodyHeight`). The newest whole part that fits wins: a correction or a later finding from a notes search replaces the earlier cursor text instead of piling up under it.
- When even one cursor sentence does not fit, the bubble shows only the footer line ("Answer in chat: Right ⌘ ," or similar wording, builder's call), never part of the sentence.
- While text streams in, the bubble grows with whole sentences only; a sentence still being written that would not fit does not show until the app knows it fits, or the footer takes its place.
- "Checking your notes" works as today.
- Notices (failed start, provider error, usage limit) follow the same no-cut rule.
- Everything else about the bubble is unchanged: it follows the cursor, flips near edges, rides under the pointer's label, and fades on any click or keypress.

### The chat window

- The chat window shows the whole answer for each question: the cursor part followed by the chat part, as one message.
- The chat key opens it during a session and closes it when it is open. Opening it never takes keyboard focus, as today (`ChatPanelController`).
- The Open chat row in the menu-bar panel works as today.
- Pressing the chat key does not count as the keypress that fades the bubble, since Clicky removes that key press before any app sees it (builder may decide otherwise if the event path makes this awkward, but the bubble must not flicker).

### The chat key

- Default: right Command + comma, and only right Command. Left Command + comma passes through to the front app untouched.
- Clicky removes the chat key press, and its release, so it never types a comma or reaches the front app.
- It runs on the same session-only event tap as the question key (`QuestionKeyMonitor`), so it exists only between Start and Stop.
- Settings gets a Chat key section next to the Question key section: the current key, Record (Escape cancels) and Reset to right ⌘ ,. Recording works like the question key's recorder.
- The chat key keeps which side each modifier was pressed on. Question-key combinations today match either side (`ModifierFamily`, "side-agnostic"); the chat key needs sides so right Command + comma leaves left Command + comma alone. How the spec carries sides is the builder's call; the question key's behaviour must not change.
- Settings refuses a chat key that is the same as the question key, and refuses a question key that is the same as the chat key. A bare regular key is refused, as for the question key.
- The default question key (a lone tap of right Command) does not fire when comma is pressed during the press, as today, so the two defaults do not clash.
- The choice is kept between launches in `AppSettings`.

### Read aloud

- When answers are spoken, only the cursor part is read. The chat part is never spoken.
- With "Both", the voice and the bubble say the same thing.

## Constraints

- Every rule in the repo's CLAUDE.md "Fork rules" holds, in particular: question text is built only in `ClickyCore/Questions`; answer reports carry the question's answer number; nothing reaches the app after Stop began.
- Testable logic goes in `Packages/ClickyCore` (the app target has no test target). The split of an answer into cursor and chat parts, the no-cut fitting rule and the chat-key matching all need tests there.
- The test Mac stand-ins in `testenv/` (stand-in `claude` and `codex`) need answers with and without a chat part so user-mock can walk both.

## Docs to change in the same pull request (Joseph approved this design on 2026-11-08)

- `docs/GOAL.md`:
  - Requirement "No window opens during a session unless the user opens it; the chat window holding the whole conversation opens only from the menu-bar panel" becomes: the chat window opens only from the menu-bar panel or the chat key.
  - "Short answers first": the cursor shows the answer in one or two sentences; a longer answer goes to the chat window in full, and the cursor never shows cut-off text.
  - A new story for the chat key: during a session, the chat key opens and closes the chat window; it can be recorded in Settings; it defaults to right Command + comma.
- `docs/FORK_CHANGES.md`: the "Answers beside the cursor", "Chat window", "Question key" and "Settings" rows.
- `CLAUDE.md`: the overview's chat-window sentence, the Chat window and Cursor answer panel decisions, and the Key Files rows that change.

## Left to the builder

- The marker's spelling and how the stream parser hides it.
- The exact footer wording, within "More in chat" plus the key's name.
- How the key spec carries modifier sides, and how the two keys share one event tap.
- The Settings layout of the Chat key section, matching the Question key section.
