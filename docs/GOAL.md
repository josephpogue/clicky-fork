---
last_reviewed: 2026-11-05
---

# Clicky Fork: goal

## Goal

An over-the-shoulder assistant that sits beside the user on their Mac: it sees what they see as they work, answers their questions about what is on the screen, and guides them through what to do next, the way a colleague looking over their shoulder would, without getting in the way of the work.

## User stories

- **Ask without stopping work:** As a user, I want to ask a question out loud while I keep working, so that I never take my hands off the mouse.
  - Acceptance: When the user presses the question key on its own during a session, the app shall show that it is listening for a question.
  - Acceptance: When the user presses the question key again, the app shall send what was said between the two presses as the question.
  - Acceptance: When the question key is pressed together with another key, the app shall not start a question.
- **Answers about my screen:** As a user, I want answers that use what is on my screen, so that I get help with what I am doing right now.
  - Acceptance: When a question is sent, the app shall include the current view of every display.
  - Acceptance: When an answer arrives and text answers are on, the app shall show it as text beside the cursor.
  - Acceptance: When the user clicks or types after an answer appears, the app shall hide the answer text.
  - Acceptance: When the user asks about something seen earlier in the session, the app shall include the view from that moment.
- **Show me where:** As a user, I want to be shown where on the screen to look or click, so that I can follow the guidance without searching for it.
  - Acceptance: When an answer refers to a spot on the screen, the app shall move a pointer to that spot.
  - Acceptance: When the spot is on another display, the app shall point on that display.
- **Hear it or read it:** As a user, I want to choose whether answers are spoken, shown as text, or both, so that I can take them in the way that suits what I am doing.
  - Acceptance: When the user opens Settings, the app shall offer spoken answers, text answers, or both.
  - Acceptance: When spoken answers are on, the app shall read each answer aloud.
  - Acceptance: When the user asks a new question while an answer is being read, the app shall stop reading.
- **Short answers first:** As a user, I want short answers unless I ask for more, so that I can take them in at a glance while I work.
  - Acceptance: When the user asks a question, the app shall answer in one or two sentences.
  - Acceptance: When the user asks it to explain more, the app shall give the longer answer.
- **Answers from my notes:** As a user, I want answers to draw on my own notes and project files only when a question needs them, so that I get accurate answers without waiting for everything to load.
  - Acceptance: When no search folder is set, the app shall answer from the screen alone, as before.
  - Acceptance: When a question is sent and search folders are set, the app shall attach the passages from those folders that match the question, found on the Mac.
  - Acceptance: When the passages do not answer the question, the app shall let the answer search and read files inside the search folders, and never any file outside them or any file that may hold secrets.
  - Acceptance: When the first words of an answer arrive, the app shall show or speak them at once, and add later findings to the same answer as they arrive.
  - Acceptance: When the answer is searching the notes and has not said so, the app shall show "Checking your notes" beside the cursor.
  - Acceptance: When the user asks a new question while an answer is still coming, the app shall end that answer and take the new question.
  - Acceptance: When a question starts with "dig deeper", the app shall answer it on the stronger model and effort from Settings, and use the normal model again from the next question.
- **Watch only when I say so:** As a user, I want the assistant to watch only during a session I start and stop, so that it never uses my plan or sees my screen when I have not asked it to.
  - Acceptance: When the Mac starts up, the app shall not start a session.
  - Acceptance: When no session is running, the app shall not capture the screen or the microphone.
  - Acceptance: When no question is being asked, the app shall send nothing to any AI service.
- **Look back at a session:** As a user, I want each session logged with the screens that matter and everything I said and asked, so that I can look back at what I did.
  - Acceptance: When a session runs, the app shall log each question, answer, app switch and spoken line with its time and the screen at that moment.
  - Acceptance: When the user stops a session, the app shall remove near-duplicate screens and keep the log in the app.
  - Acceptance: When the user opens the session list, the app shall show past sessions to reopen.
- **File a session with a project:** As a user, I want to file a session under one of my projects, so that it sits with the rest of that project's notes.
  - Acceptance: When the user presses Save, the app shall suggest a project and let the user pick any project or none.
  - Acceptance: When the user confirms, the app shall write the log and the screens tied to questions into the notes folder and link it from the project page.
- **Use the plan I already have:** As a user with a Claude or ChatGPT subscription, I want to sign in with it and switch between the two, so that I pay nothing extra and can keep going when one runs out.
  - Acceptance: When the user opens Settings, the app shall offer a sign-in for Claude and for ChatGPT and show whether each is signed in.
  - Acceptance: When the user picks a different model, the app shall use it from the next question.
  - Acceptance: When the Claude plan runs out during a session, the app shall offer a one-tap switch to ChatGPT that keeps the conversation.

## Requirements

- Sessions start and stop only by the user's action; the app never launches at login.
- The question key is right Command by default.
- No window opens during a session unless the user opens it; the chat window holding the whole conversation opens only from the menu-bar panel.
- Spoken answers use the voices built into macOS.
- Screenshots, speech-to-text, change detection, cleanup and the notes index and passage search run on the Mac with no AI request.
- The app does not read text off screenshots.
- Notes are read only from the search folders set in Settings, read-only, and files that may hold secrets (`.env` files, keys, credentials, tokens, `.git`) are never indexed or read.
- The only AI requests are one per question and one optional text-only summary at Stop. One question's request may search and read the notes several times inside it.
- Claude runs through the official Claude Code CLI on the user's own login; ChatGPT runs through the official Codex CLI on the user's own login.
- The app keeps its own sign-ins, apart from any Claude Code or Codex the user already has.
- The notes folder is a setting; no path or account is built into the code.
- Every difference from upstream Clicky is listed in `docs/FORK_CHANGES.md`.

## Constraints

- Subscription only: no API keys, no direct API calls with a subscription login token (Anthropic usage policy from 2026-11-12).
- The first target Mac runs macOS Sequoia 15.7.7, which asks the user to re-approve screen recording about monthly; the app cannot suppress it.
- All session data stays on the Mac until the user presses Save.
- The app may see any screen, work material included.

## Non-goals

- Recording all day or starting at login.
- Reading screen text, by Apple's text reader or any other.
- The paid services upstream Clicky uses: AssemblyAI, ElevenLabs and the Cloudflare key proxy.
- Windows support.

## Later

- Clicking and typing for the user.
- Other people installing it with their own Claude or ChatGPT login, once that use is confirmed to fit Anthropic's and OpenAI's terms.
