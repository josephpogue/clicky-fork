//
//  SessionCoordinator.swift
//  leanring-buddy
//
//  Owns one Clicky Fork session from Start to Stop (phases idle, starting, running,
//  stopping, ruled by `SessionLifecycle` in ClickyCore): microphone, screen
//  recording, window tracking, the question key, the session log and the AI
//  provider. The windows read its state and call startSession and stopSession.
//
//  Nothing here runs outside a session. The one thing started at launch is
//  loading the speech model, which reads no audio. The questions themselves
//  (key signals in, provider calls, answers out) run in `SessionQuestionFlow`
//  in ClickyCore, where they are tested; this file wires it to the hardware
//  and the windows.
//

import AppKit
import AVFoundation
import ClickyCore
import ClickySpeech
import Combine
import Foundation

@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()

    /// App data folders (sessions, provider sign-in folders). Honours CLICKY_DATA_DIR.
    let locations: AppDataLocations
    let sessionStore: SessionStore

    /// The chat window shows this state; the coordinator fills it during a session.
    let chatWindowState = ChatWindowState()

    /// The phase rules (idle, starting, running, stopping) live in ClickyCore, where every phase and action is tested.
    @Published private(set) var lifecycle = SessionLifecycle() {
        // The chat window shows the same phase and start step as the menu panel.
        didSet {
            chatWindowState.sessionPhase = lifecycle.phase
            chatWindowState.startStepText = lifecycle.startStep?.statusText
        }
    }

    /// True only while the session runs and everything that captures is on.
    var isSessionRunning: Bool { lifecycle.isRunning }

    /// A short line for the menu bar panel when a session could not start.
    @Published private(set) var panelNotice: String?

    /// Sends a session's id once Stop has finished writing its log and cleanup.
    let sessionFinished = PassthroughSubject<String, Never>()

    private let settings = AppSettings.shared
    private let pointerFlight = PointerFlightController()
    private let markerPanel = QuestionMarkerPanel()
    /// The answer bubble, notices and speaker capsule beside the cursor. No window opens during a session.
    private let cursorAnswerPresenter: CursorAnswerPresenter
    /// Reads answers aloud when Settings asks for spoken answers.
    private let spokenAnswerPlayer = SpokenAnswerPlayer()
    private var settingsSubscriptions = Set<AnyCancellable>()
    /// Which chat message is the answer still coming, and whether the checking line shows (pure rules in ClickyCore).
    private var growingAnswerChat = GrowingAnswerChatState()
    /// The chat message of each answer, by the answer token `growingAnswerChat` gave it.
    private var answerMessageIDs: [Int: UUID] = [:]
    /// Each answer's parts (cursor text and chat text), by answer number, so a late cut-short report of an older
    /// answer still gets its own paragraphs. An entry goes once its chat card is finished.
    private var answerPartsByNumber: [Int: AnswerPartsTracker] = [:]
    /// Which whole sentences of the current answer show beside the cursor and have been read aloud.
    private var cursorLineState = CursorLineState()
    /// The provider the open usage-limit offer switches to; an answer from any other provider clears the offer.
    private var usageLimitSwitchTarget: ProviderID?
    private let questionKeyMonitor = QuestionKeyMonitor()
    private let frontmostWindowTracker = FrontmostWindowTracker()

    /// Loads the speech model in the background at launch; a session waits for it if it is not ready yet.
    private var speechTranscriberTask: Task<SpeechTranscriber, Never>?
    private var isSpeechTranscriberReady = false

    /// Finishes the session folders a crash left open, once at launch. Start waits for it, so it can never
    /// finish the session that is about to begin.
    private var abandonedSessionsTask: Task<Void, Never>?

    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    /// The summary request while Stop waits for it; Quit cancels it.
    private var summaryTask: Task<String?, Never>?
    private var isSummarySkipped = false
    /// The one chat line that names what Start is waiting for; removed when Start ends.
    private var startStatusMessageID: UUID?
    /// True once the screen, microphone or key tap was switched on for the session being started.
    private var didStartCapture = false
    /// True between a finished Start and Stop: the chat key's tap is on, so the footer may name the key.
    private var chatKeyWorks = false

    private var sessionID: String?
    private var screenRecorder: SessionScreenRecorder?
    private var speechPipeline: SessionSpeechPipeline?
    private var questionFlow: SessionQuestionFlow?
    private var sessionInputContinuation: AsyncStream<SessionInput>.Continuation?
    private var sessionInputTask: Task<Void, Never>?

    private var currentPhase: SessionFlowPhase = .idle
    private var lastShownAudioLevel = 0.0

    /// Everything that reaches the session log from outside the question flow, in arrival order.
    private enum SessionInput {
        case event(SessionEvent)
        case shotGroup(ShotGroup)
    }

    private init() {
        locations = AppDataLocations.standard(environment: ProcessInfo.processInfo.environment)
        try? locations.createDirectories()
        sessionStore = SessionStore(locations: locations)
        cursorAnswerPresenter = CursorAnswerPresenter(pointerFlight: pointerFlight)
        spokenAnswerPlayer.onSpeakingChanged = { [weak self] isSpeaking in
            self?.cursorAnswerPresenter.showSpeaking(isSpeaking)
            // Spoken-only: the waiting marker stays until the voice actually starts. A late start event of an old
            // answer's voice (after the new question's listening marker showed) must not hide that marker.
            if isSpeaking, let self, case .waitingForAnswer = self.currentPhase { self.markerPanel.hide() }
        }
        // Switching to a mode that does not speak stops a reading in progress; switching to Spoken starts nothing.
        settings.$answerDeliveryMode
            .removeDuplicates()
            .sink { [weak self] mode in
                if !mode.speaksAloud { self?.spokenAnswerPlayer.stopSpeaking() }
            }
            .store(in: &settingsSubscriptions)

        // A new question key applies at once, also in a running session.
        settings.$questionKey
            .removeDuplicates()
            .sink { [weak self] key in
                guard let self else { return }
                self.questionKeyMonitor.apply(questionKey: key)
                self.refreshChatKeyName(question: key, chat: self.settings.chatKey)
            }
            .store(in: &settingsSubscriptions)

        // A new chat key applies at once, also in a running session, and the footer names it.
        settings.$chatKey
            .removeDuplicates()
            .sink { [weak self] key in
                guard let self else { return }
                self.questionKeyMonitor.apply(chatKey: key)
                self.refreshChatKeyName(question: self.settings.questionKey, chat: key)
            }
            .store(in: &settingsSubscriptions)
        questionKeyMonitor.onChatKeyPressed = { [weak self] in self?.handleChatKeyPressed() }

        // The button in the chat window does what the panel's button does in the current phase (Starting cancels).
        chatWindowState.onStartSession = { [weak self] in self?.handleSessionButton() }
        chatWindowState.onStopSession = { [weak self] in self?.stopSession() }
        chatWindowState.onSwitchProvider = { [weak self] in self?.switchToChatGPT() }
        questionKeyMonitor.onSignal = { [weak self] signal in
            Task { @MainActor in await self?.handleQuestionKeySignal(signal) }
        }
    }

    /// Settings is recording a new question key: the old one must not start a question meanwhile.
    func setQuestionKeyRecording(_ isRecording: Bool) {
        questionKeyMonitor.isSuspended = isRecording
    }

    // MARK: - Work at launch

    /// Starts loading the speech model. Loading reads no audio and opens no microphone.
    func prepareSpeech() {
        guard speechTranscriberTask == nil else { return }
        speechTranscriberTask = Task.detached(priority: .utility) {
            let transcriber = await SpeechEngineFactory.makePreferredTranscriber()
            await MainActor.run { SessionCoordinator.shared.isSpeechTranscriberReady = true }
            return transcriber
        }
    }

    /// Finishes session folders an earlier crash or force quit left open. Runs off the main actor.
    func finishAbandonedSessionsAtLaunch() {
        guard abandonedSessionsTask == nil else { return }
        let sessionStore = self.sessionStore
        abandonedSessionsTask = Task.detached(priority: .utility) {
            _ = try? await sessionStore.finishAbandonedSessions(exceptSessionID: nil)
        }
    }

    // MARK: - The Start / Stop button

    /// What the panel's button does in the current phase: start, cancel a start, stop, or nothing.
    func handleSessionButton() {
        switch lifecycle.decideButtonPress() {
        case .startSession: startSession()
        case .cancelStart: cancelStart()
        case .stopSession: beginStop(askForSummary: settings.summaryAtStopEnabled)
        case .ignore: break
        }
    }

    // MARK: - Start

    func startSession() {
        guard lifecycle.beginStart() else { return }
        panelNotice = nil
        didStartCapture = false
        // A new session replaces the finished conversation in the chat window.
        chatWindowState.messages = []
        growingAnswerChat.reset()
        answerMessageIDs = [:]
        answerPartsByNumber = [:]
        cursorLineState = CursorLineState()
        chatWindowState.isCheckingNotes = false
        chatWindowState.usageLimitOffer = nil
        chatWindowState.questionPhase = .idle
        // Start opens no window: the chat window opens only from the menu-bar panel's Open chat row.
        hideCursorAnswerAndStopSpeaking()
        startTask = Task {
            await performStart()
            startTask = nil
        }
    }

    /// Cancels a Start in progress, at any step. The session never showed as running, so its folder is removed
    /// and everything switched on is switched off, even when capture had begun.
    func cancelStart() {
        guard lifecycle.phase == .starting else { return }
        startTask?.cancel()
    }

    private func advanceStart(to step: SessionStartStep) {
        lifecycle.advanceStart(to: step)
        showStartStatus(step.statusText)
    }

    private func showStartStatus(_ text: String) {
        if let startStatusMessageID, let index = chatWindowState.messages.firstIndex(where: { $0.id == startStatusMessageID }) {
            chatWindowState.messages[index].text = text
        } else {
            let message = ChatMessage(role: .notice, text: text)
            startStatusMessageID = message.id
            chatWindowState.messages.append(message)
        }
    }

    private func removeStartStatus() {
        guard let startStatusMessageID else { return }
        chatWindowState.messages.removeAll { $0.id == startStatusMessageID }
        self.startStatusMessageID = nil
    }

    /// Turns on nothing that captures until speech is ready, the microphone is allowed and the provider has
    /// started; then screen, microphone and key tap start together and the session is running.
    private func performStart() async {
        // The brain index refreshes while the permission and speech steps run; Start awaits it before the first
        // question can be asked (step 5).
        let brainRefreshTask = Task { await BrainIndexService.shared.refreshForSessionStart() }

        // 1. The two permissions the app cannot ask for itself while running.
        var missingPermissions: [String] = []
        if !WindowPositionManager.hasAccessibilityPermission() { missingPermissions.append("Accessibility") }
        if !WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() {
            missingPermissions.append("Screen Recording")
        }
        if !missingPermissions.isEmpty {
            await discardStart(failure: "Turn on \(missingPermissions.joined(separator: " and ")) for Clicky Fork in System Settings, under Privacy and Security, then start the session again.")
            return
        }

        let providerID = settings.selectedProvider
        let providerName = ProviderFailureNotice.displayName(for: providerID)
        chatWindowState.activeProviderName = providerName
        chatWindowState.activeModel = displayModelName(for: providerID)

        // 2. Crash leftovers are finished before any new session folder exists.
        advanceStart(to: .preparingSessionLog)
        if abandonedSessionsTask == nil { finishAbandonedSessionsAtLaunch() }
        if let abandonedSessionsTask {
            guard await CancellableWait.result(of: { await abandonedSessionsTask.value }) != nil else {
                await discardStart(failure: nil)
                return
            }
        }

        // 3. Speech: wait for the model if it is still loading.
        if speechTranscriberTask == nil { prepareSpeech() }
        guard let speechTranscriberTask else {
            await discardStart(failure: "Speech could not be prepared.")
            return
        }
        if !isSpeechTranscriberReady { advanceStart(to: .gettingSpeechReady) }
        guard let transcriber = await CancellableWait.result(of: { await speechTranscriberTask.value }) else {
            await discardStart(failure: nil)
            return
        }
        let usesAppleSpeech = !(transcriber is ParakeetSpeechTranscriber)

        // 4. The microphone permission, asked here while nothing is on yet.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            advanceStart(to: .waitingForMicrophonePermission)
            guard let isMicrophoneGranted = await CancellableWait.result(of: { await MicrophoneSampleSource.requestPermission() }) else {
                await discardStart(failure: nil)
                return
            }
            if !isMicrophoneGranted {
                await discardStart(failure: "Turn on Microphone for Clicky Fork in System Settings, under Privacy and Security, then start the session again.")
                return
            }
        default:
            await discardStart(failure: "Turn on Microphone for Clicky Fork in System Settings, under Privacy and Security, then start the session again.")
            return
        }
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }

        // 4b. Apple Speech needs its own Speech Recognition permission. Ask now, while nothing is on,
        // so the prompt never lands in the middle of the first question.
        if usesAppleSpeech {
            advanceStart(to: .waitingForSpeechRecognitionPermission)
            guard let isSpeechRecognitionGranted = await CancellableWait.result(of: { await AppleSpeechTranscriber.requestAuthorization() }) else {
                await discardStart(failure: nil)
                return
            }
            if !isSpeechRecognitionGranted {
                await discardStart(failure: "Turn on Speech Recognition for Clicky Fork in System Settings, under Privacy and Security, then start the session again.")
                return
            }
        }
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }

        // 5. The log and the provider. The provider starts its helper process; it reads no screen or sound.
        advanceStart(to: .startingProvider(providerName: providerName))
        let startedSessionID: String
        do {
            startedSessionID = try await sessionStore.startSession(at: Date()).id
        } catch {
            await discardStart(failure: "The session log could not be created.")
            return
        }
        // Set before the cancellation check, so the cancelled path removes the folder just made.
        sessionID = startedSessionID
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }
        let shotsDirectory = sessionStore.shotsDirectory(sessionID: startedSessionID)

        // Everything that reaches the log from outside the flow goes through one queue, so it is written in order.
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: SessionInput.self)
        sessionInputContinuation = inputContinuation

        let recorder = SessionScreenRecorder(shotsDirectory: shotsDirectory)
        screenRecorder = recorder

        // The index is ready before the flow exists, so the first question can find passages.
        guard await CancellableWait.result(of: { await brainRefreshTask.value }) != nil else {
            await discardStart(failure: nil)
            return
        }
        let flow = makeQuestionFlow(
            sessionID: startedSessionID, shotsDirectory: shotsDirectory, recorder: recorder,
            isBrainOn: BrainIndexService.shared.isBrainOn)
        questionFlow = flow
        do {
            try await flow.begin()
        } catch let failure as ProviderFailure {
            await discardStart(failure: ProviderFailureNotice.text(for: failure, provider: providerID))
            return
        } catch {
            await discardStart(failure: "The AI helper could not be started.")
            return
        }
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }

        // 6. Everything is ready: screen, microphone and key tap start together.
        didStartCapture = true
        let sessionStore = self.sessionStore
        sessionInputTask = Task {
            for await input in inputStream {
                switch input {
                case .event(let event):
                    await flow.noteEvent(event)
                case .shotGroup(let group):
                    try? await sessionStore.recordShotGroup(group, sessionID: startedSessionID)
                    await flow.noteShotGroup(group)
                }
            }
        }
        inputContinuation.yield(.event(SessionEvent(time: Date(), kind: .sessionStarted)))

        let pipeline = SessionSpeechPipeline(transcriber: transcriber, source: MicrophoneSampleSource())
        speechPipeline = pipeline
        await pipeline.setHandlers(
            onUtterance: { text, spokenFrom, _ in
                inputContinuation.yield(.event(SessionEvent(time: spokenFrom, kind: .utterance(text: text))))
            },
            onAudioLevel: { [weak self] level in
                Task { @MainActor in self?.noteAudioLevel(level) }
            }
        )
        do {
            try await pipeline.start()
        } catch {
            await discardStart(failure: error.localizedDescription)
            return
        }
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }

        // Window tracking, then screen recording (it needs to know the starting window).
        frontmostWindowTracker.start { [weak self] appName, windowTitle, isAppSwitch in
            inputContinuation.yield(.event(SessionEvent(
                time: Date(), kind: .focusChanged(appName: appName, windowTitle: windowTitle)
            )))
            Task { await self?.screenRecorder?.noteFocusChanged(appName: appName, windowTitle: windowTitle, isAppSwitch: isAppSwitch) }
        }
        await recorder.noteFocusChanged(
            appName: frontmostWindowTracker.currentAppName,
            windowTitle: frontmostWindowTracker.currentWindowTitle,
            isAppSwitch: false
        )
        do {
            try await recorder.start { group in inputContinuation.yield(.shotGroup(group)) }
        } catch {
            await discardStart(failure: "Screen Recording is not working. Check that Clicky Fork is allowed in System Settings, under Privacy and Security.")
            return
        }
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }

        // The question key last, so no tap can arrive before the conversation exists.
        guard questionKeyMonitor.start() else {
            await discardStart(failure: "The question key needs Accessibility. Turn it on for Clicky Fork in System Settings, under Privacy and Security.")
            return
        }
        // The last check. Nothing awaits between it and finishStart, so a Cancel or Quit cannot land in between:
        // after this the session shows as running and Quit stops it as a short session.
        if Task.isCancelled {
            await discardStart(failure: nil)
            return
        }

        removeStartStatus()
        if usesAppleSpeech {
            chatWindowState.messages.append(ChatMessage(role: .notice, text: "Using Apple speech: the Parakeet model is not available"))
        }
        _ = lifecycle.finishStart()
        // From now on the chat key works, so a bubble with more in the chat names it.
        chatKeyWorks = true
        refreshChatKeyName(question: settings.questionKey, chat: settings.chatKey)
    }

    /// The footer names the chat key only while pressing it opens the chat: during a session, and while it does not
    /// overlap the question key (an overlapping chat key is inactive). Otherwise it points at the menu bar's Open chat.
    /// The sinks pass the new key themselves, since `@Published` sends before the property changes.
    private func refreshChatKeyName(question: QuestionKeySpec, chat: QuestionKeySpec) {
        let isActive = chatKeyWorks && KeyOverlap.isChatKeyActive(chat, question: question)
        cursorAnswerPresenter.chatKeyName = isActive ? chat.displayName : nil
    }

    /// Ends a Start that failed or was cancelled: switches off whatever was on, ends the provider, and applies
    /// `SessionStartEnding`: a cancelled Start removes its session folder even when capture had begun; a real
    /// failure after capture began keeps a short session and shows its notice.
    private func discardStart(failure noticeText: String?) async {
        let ending = SessionStartEnding.decide(
            isCancelled: Task.isCancelled, failureNotice: noticeText, captureBegan: didStartCapture
        )
        questionKeyMonitor.stop()
        chatKeyWorks = false
        cursorAnswerPresenter.chatKeyName = nil
        // The window tracker goes first: its callback feeds the recorder and the input queue.
        frontmostWindowTracker.stop()
        await speechPipeline?.stop()
        await screenRecorder?.stop()
        sessionInputContinuation?.finish()
        await sessionInputTask?.value
        _ = await questionFlow?.finish(summaryEnabled: false)
        if let sessionID {
            switch ending.folderOutcome {
            case .keepAsShortSession:
                _ = try? await sessionStore.finishSession(sessionID: sessionID, at: Date(), summary: nil)
            case .removeFolder:
                try? FileManager.default.removeItem(at: locations.sessionsDirectory.appendingPathComponent(sessionID))
            }
        }
        clearSessionObjects()
        removeStartStatus()
        didStartCapture = false
        lifecycle.endStartWithoutSession()
        if let noticeText = ending.noticeText { failToStart(noticeText) }
    }

    private func failToStart(_ noticeText: String) {
        panelNotice = noticeText
        chatWindowState.messages.append(ChatMessage(role: .notice, text: noticeText))
        // The notice shows in the panel and beside the cursor; no window opens for it.
        cursorAnswerPresenter.showNotice(text: noticeText)
    }

    private func clearSessionObjects() {
        sessionID = nil
        screenRecorder = nil
        speechPipeline = nil
        questionFlow = nil
        sessionInputContinuation = nil
        sessionInputTask = nil
        currentPhase = .idle
    }

    private func makeQuestionFlow(
        sessionID: String, shotsDirectory: URL, recorder: SessionScreenRecorder, isBrainOn: Bool
    ) -> SessionQuestionFlow {
        let locations = self.locations
        let sessionStore = self.sessionStore
        let speechPipelineProvider: @Sendable () async -> SessionSpeechPipeline? = { [weak self] in
            await self?.speechPipeline
        }
        let dependencies = SessionQuestionFlowDependencies(
            makeProvider: { providerID in SessionProviderFactory.makeProvider(for: providerID, locations: locations) },
            model: { providerID in await SessionProviderFactory.modelName(for: providerID) },
            instructions: AnswerInstructions.questionInstructions,
            markQuestionStarted: { date in await speechPipelineProvider()?.markQuestionStarted(at: date) },
            transcribeQuestion: { speechFrom, speechTo in
                guard let pipeline = await speechPipelineProvider() else { throw SpeechError.noSessionRunning }
                return try await pipeline.transcribeQuestion(speechFrom: speechFrom, speechTo: speechTo)
            },
            captureCurrentGroup: { try await recorder.captureForQuestion() },
            logEvent: { event in
                // The store already writes the start line and each screenshot line itself.
                switch event.kind {
                case .sessionStarted, .screenshot: return
                default: try? await sessionStore.append(event, sessionID: sessionID)
                }
            },
            shotsDirectory: shotsDirectory,
            timeZone: .current,
            findPassages: { question, frontAppName, frontWindowTitle in
                await BrainIndexService.shared.passages(
                    forQuestion: question, frontAppName: frontAppName, frontWindowTitle: frontWindowTitle)
            },
            isBrainOn: isBrainOn,
            brainMapPaths: { await BrainIndexService.shared.mapPaths() },
            digDeeperRequest: { providerID in
                await MainActor.run { SessionProviderFactory.digDeeperRequest(for: providerID) }
            }
        )
        return SessionQuestionFlow(
            initialProvider: settings.selectedProvider,
            dependencies: dependencies,
            output: SessionFlowBridge(coordinator: self)
        )
    }

    // MARK: - Question key

    private func handleQuestionKeySignal(_ signal: QuestionKeySignal) async {
        guard lifecycle.acceptsQuestionKeySignals, let questionFlow else { return }
        let outcome = await questionFlow.handle(signal)
        if outcome == .ignoredBecauseBusy, case .questionStarted = signal {
            // The tap was dropped, so forget it: the next tap must start a question, not send one.
            questionKeyMonitor.forgetPendingQuestion()
        }
    }

    /// The chat key opens the chat panel, or closes it when it is open. The key tap exists only during a session.
    private func handleChatKeyPressed() {
        guard lifecycle.acceptsQuestionKeySignals else { return }
        AppWindowRouter.shared.toggleChat()
    }

    private func noteAudioLevel(_ level: Double) {
        guard lifecycle.acceptsFlowPhaseUpdates, case .listening = currentPhase,
              abs(level - lastShownAudioLevel) > 0.02 else { return }
        lastShownAudioLevel = level
        markerPanel.show(phase: .listening(audioLevel: level))
    }

    // MARK: - Switching provider

    private func switchToChatGPT() {
        guard lifecycle.isRunning, let questionFlow else { return }
        chatWindowState.isSwitchInProgress = true
        Task {
            await questionFlow.switchProvider(to: .chatgpt)
            chatWindowState.isSwitchInProgress = false
        }
    }

    // MARK: - Stop

    /// The chat window's Stop: stops a running session, or cancels a Start in progress.
    func stopSession() {
        switch lifecycle.decideButtonPress() {
        case .stopSession: beginStop(askForSummary: settings.summaryAtStopEnabled)
        case .cancelStart: cancelStart()
        case .startSession, .ignore: break
        }
    }

    /// Leaves running at once (so no key signal or phase update passes), then finishes the stop in the background.
    private func beginStop(askForSummary: Bool) {
        guard lifecycle.beginStop() else { return }
        // The slow parts of Stop (the speech and screen shutdown) come next: close the answer now, so the card does
        // not say "still coming", the checking line does not animate and no queued sentence is read meanwhile.
        closeAnswerAsStopped()
        stopTask = Task {
            await performStop(askForSummary: askForSummary)
            stopTask = nil
        }
    }

    private func performStop(askForSummary: Bool) async {
        guard let flow = questionFlow, let finishingSessionID = sessionID else {
            lifecycle.finishStop()
            return
        }

        // Everything that watches or listens goes off first.
        questionKeyMonitor.stop()
        chatKeyWorks = false
        cursorAnswerPresenter.chatKeyName = nil
        await speechPipeline?.stop()
        await screenRecorder?.stop()
        frontmostWindowTracker.stop()
        resetMarkerAndQuestionPhase()
        pointerFlight.cancelFlight()
        chatWindowState.usageLimitOffer = nil
        currentPhase = .idle

        // Let queued log lines land before the stop line.
        sessionInputContinuation?.finish()
        await sessionInputTask?.value

        let wantsSummary = askForSummary && !isSummarySkipped
        let finishTask = Task { await flow.finish(summaryEnabled: wantsSummary) }
        if wantsSummary { summaryTask = finishTask }
        let summary = await finishTask.value
        summaryTask = nil

        // A tap queued before Stop may have landed a phase while the flow finished.
        resetMarkerAndQuestionPhase()

        do {
            _ = try await sessionStore.finishSession(sessionID: finishingSessionID, at: Date(), summary: summary)
        } catch {
            print("Clicky Fork: the session log could not be finished: \(error)")
        }
        clearSessionObjects()
        isSummarySkipped = false
        lifecycle.finishStop()
        sessionFinished.send(finishingSessionID)
    }

    /// Ends the answer in flight as "(Stopped.)", hides the bubble and stops the voice. Called at the very start of
    /// Stop and of Quit (both go through `beginStop`); later calls find nothing left to end.
    private func closeAnswerAsStopped() {
        apply(growingAnswerChat.abandon(reason: .stopped), details: nil)
        answerPartsByNumber.removeAll()
        hideCursorAnswerAndStopSpeaking()
    }

    private func resetMarkerAndQuestionPhase() {
        closeAnswerAsStopped()
        markerPanel.hide()
        chatWindowState.questionPhase = .idle
    }

    private func hideCursorAnswerAndStopSpeaking() {
        cursorAnswerPresenter.hideAll()
        spokenAnswerPlayer.stopSpeaking()
    }

    // MARK: - Quit

    /// Decides at once what Quit must do in the current phase.
    func requestQuit() -> SessionQuitDecision {
        lifecycle.requestQuit()
    }

    /// Carries out the decision: cancel a Start, stop a running session without the summary, or let a Stop
    /// finish with its summary skipped. Returns when the session work is done and the app may quit.
    func carryOutQuit(_ decision: SessionQuitDecision) async {
        switch decision {
        case .terminateNow, .alreadyHandled:
            return
        case .cancelStartThenTerminate:
            cancelStart()
            await startTask?.value
            // The start may have finished just before the cancel landed.
            beginStop(askForSummary: false)
            await stopTask?.value
        case .stopWithoutSummaryThenTerminate:
            beginStop(askForSummary: false)
            await stopTask?.value
        case .skipSummaryAndWaitForStopThenTerminate:
            skipSummary()
            await stopTask?.value
        }
    }

    /// Drops the summary: cancels the request and ends the provider's helper processes so it returns at once.
    private func skipSummary() {
        isSummarySkipped = true
        guard let summaryTask else { return }
        summaryTask.cancel()
        ChildProcessTerminator.terminateDirectChildren()
    }

    // MARK: - What the question flow tells the screen

    fileprivate func showPhase(_ phase: SessionFlowPhase) {
        // Once Stop has begun, a late phase (a tap queued just before Stop) must not light the marker again.
        guard lifecycle.acceptsFlowPhaseUpdates else { return }
        currentPhase = phase
        let providerName: (ProviderID) -> String = { ProviderFailureNotice.displayName(for: $0) }
        switch phase {
        case .idle:
            chatWindowState.questionPhase = .idle
            markerPanel.show(phase: .idle)
        case .listening:
            // A new question replaces the last answer: its text goes and its reading stops. An answer still coming
            // (when the flow did not already report it cut short) ends here as cut short; its own late cut report
            // then finds this same card instead of adding a second one.
            apply(growingAnswerChat.newQuestionListening(), details: nil)
            // The ended answer keeps its parts for its own late cut-short report; nothing more of it shows or is said.
            cursorLineState = CursorLineState()
            cursorAnswerPresenter.hideAll()
            spokenAnswerPlayer.stopAllSpeaking()
            // The old pointer flies home, so the next answer sits by the cursor, not under the old label.
            pointerFlight.endCurrentFlightByReturningToCursor()
            lastShownAudioLevel = 0
            chatWindowState.questionPhase = .listening(audioLevel: 0)
            markerPanel.show(phase: .listening(audioLevel: 0))
        case .transcribing:
            chatWindowState.questionPhase = .transcribing
            markerPanel.show(phase: .transcribing)
        case .waitingForAnswer(let provider):
            chatWindowState.questionPhase = .waitingForAnswer(providerName: providerName(provider))
            markerPanel.show(phase: .waitingForAnswer(providerName: providerName(provider)))
        }
    }

    fileprivate func showQuestion(_ text: String, answerNumber: Int) {
        chatWindowState.messages.append(ChatMessage(role: .question, text: text))
        // The answer number is the card's token: every later report names it, so a report of an older answer finds
        // its own card (or is dropped) and never reaches this one.
        apply(growingAnswerChat.beginAnswer(answerNumber: answerNumber), details: nil)
        answerPartsByNumber[answerNumber] = AnswerPartsTracker()
        cursorLineState = CursorLineState()
    }

    fileprivate func showAnswer(
        answerNumber: Int, spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double, pointLabel: String?,
        notesRead: [String]
    ) {
        let details = ComingAnswerDetails(
            providerName: ProviderFailureNotice.displayName(for: provider), model: model,
            secondsToAnswer: secondsToAnswer, pointLabel: pointLabel, notesRead: notesRead)
        // A final answer for a number that is not the current answer (a newer question or Stop already ended it) is
        // dropped: no card, no bubble, no voice. The measurements below still count as a provider answer.
        let isCurrentAnswer = growingAnswerChat.isCurrent(answerNumber: answerNumber)
        if isCurrentAnswer {
            // The chat card holds the whole answer: every part's cursor text and chat text, no marker.
            var answerParts = answerPartsByNumber[answerNumber] ?? AnswerPartsTracker()
            answerParts.finalReported(spokenText)
            answerPartsByNumber[answerNumber] = answerParts
            apply(growingAnswerChat.finalAnswerReceived(answerNumber: answerNumber, text: answerParts.chatText), details: details)
        }
        chatWindowState.activeModel = model.isEmpty ? "default" : model
        settings.recordMeasuredAnswerSeconds(secondsToAnswer, for: provider)
        if chatWindowState.usageLimitOffer != nil, let switchTarget = usageLimitSwitchTarget,
           UsageLimitOfferRules.answerClearsOffer(switchTarget: switchTarget, answeredBy: provider) {
            chatWindowState.usageLimitOffer = nil
        }
        // An answer that lands during Stop's drain finds its number already retired by Stop (the card ended as
        // "(Stopped.)"), so it reaches nothing: no chat card, no bubble, no voice, and no pointer (`flyPointer`).
        guard isCurrentAnswer, lifecycle.acceptsPointerFlights else {
            answerPartsByNumber[answerNumber] = nil
            return
        }
        refreshCursorLine(answerNumber: answerNumber)
        // "Checking your notes" never stays on a finished answer, also when the final line is the one already shown.
        if settings.answerDeliveryMode.showsText { cursorAnswerPresenter.answerFinished() }
        answerPartsByNumber[answerNumber] = nil
    }

    /// The answer so far: the chat message grows, the bubble grows in place and finished sentences are spoken.
    fileprivate func showAnswerText(
        answerNumber: Int, visibleText: String, endsBeforeHiddenText: Bool, provider: ProviderID, model: String
    ) {
        guard lifecycle.acceptsPointerFlights, growingAnswerChat.isCurrent(answerNumber: answerNumber) else { return }
        var answerParts = answerPartsByNumber[answerNumber] ?? AnswerPartsTracker()
        answerParts.textReported(visibleText, endsBeforeHiddenText: endsBeforeHiddenText)
        answerPartsByNumber[answerNumber] = answerParts
        let details = ComingAnswerDetails(
            providerName: ProviderFailureNotice.displayName(for: provider), model: model,
            secondsToAnswer: nil, pointLabel: nil, notesRead: [])
        apply(growingAnswerChat.textReported(answerNumber: answerNumber, text: answerParts.chatText), details: details)
        refreshCursorLine(answerNumber: answerNumber)
    }

    /// Recomputes the current answer's cursor line from its parts: the bubble shows only whole sentences that fit,
    /// and the voice reads exactly the sentences the bubble shows for the first time, with Spoken only too.
    private func refreshCursorLine(answerNumber: Int) {
        guard let answerParts = answerPartsByNumber[answerNumber] else { return }
        let update = cursorLineState.update(
            parts: answerParts.parts, fits: { candidateText in AnswerBubbleMetrics.fitsInBubble(text: candidateText) })
        let deliveryMode = settings.answerDeliveryMode
        if deliveryMode.showsText, let line = update.line {
            // The listening or waiting marker has done its job once the answer shows; for Spoken-only it stays until
            // the voice starts (see onSpeakingChanged).
            markerPanel.hide()
            cursorAnswerPresenter.showCursorLine(line)
        }
        if deliveryMode.speaksAloud { spokenAnswerPlayer.speak(sentences: update.newSentencesToSpeak) }
    }

    fileprivate func showCheckingNotes(answerNumber: Int) {
        guard lifecycle.acceptsPointerFlights, growingAnswerChat.isCurrent(answerNumber: answerNumber) else { return }
        apply(growingAnswerChat.checkingReported(answerNumber: answerNumber), details: nil)
        let deliveryMode = settings.answerDeliveryMode
        if deliveryMode.showsText { markerPanel.hide() }
        if deliveryMode.showsText { cursorAnswerPresenter.showCheckingLine() }
        if deliveryMode.speaksAloud { spokenAnswerPlayer.speakCheckingLine() }
    }

    /// An answer ended early: the chat message ends with the line for the reason, once. The bubble keeps the text it
    /// shows until the new question's listening phase hides it, as it does today (a failure's notice arrives
    /// separately), but "Checking your notes" goes now: no search is running once the answer has ended.
    fileprivate func showAnswerCutShort(
        answerNumber: Int, visibleText: String, provider: ProviderID, model: String, notesRead: [String], reason: AnswerCutReason
    ) {
        // After Stop began, only the Stop's own report may finish the card (Stop ended it as "(Stopped.)" already).
        guard lifecycle.acceptsPointerFlights || reason == .stopped else { return }
        let details = ComingAnswerDetails(
            providerName: ProviderFailureNotice.displayName(for: provider), model: model,
            secondsToAnswer: nil, pointLabel: nil, notesRead: notesRead)
        // Only the answer on screen owns the bubble: an older answer's late report must not touch the new one's.
        let endedAnswerIsCurrent = growingAnswerChat.isCurrent(answerNumber: answerNumber)
        // The card keeps the answer's own paragraphs: its tracker when it still has one, else the text alone.
        let chatText: String
        if var answerParts = answerPartsByNumber.removeValue(forKey: answerNumber) {
            answerParts.textReported(visibleText)
            chatText = answerParts.chatText
        } else {
            chatText = AnswerPartsTracker.chatText(ofVisibleText: visibleText)
        }
        apply(
            growingAnswerChat.cutShort(answerNumber: answerNumber, visibleText: chatText, reason: reason),
            details: details)
        if endedAnswerIsCurrent, settings.answerDeliveryMode.showsText { cursorAnswerPresenter.answerFinished() }
    }

    /// The model began a tool call: the bubble now treats new text as a new finding, and a Spoken answer says the
    /// sentence that just ended ("Let me check your notes.") instead of waiting through the whole search in silence.
    fileprivate func showToolCallStarted(answerNumber: Int) {
        guard lifecycle.acceptsPointerFlights, growingAnswerChat.isCurrent(answerNumber: answerNumber) else { return }
        // The tool call ends the current part, so its last sentence is complete and may show and be spoken now.
        answerPartsByNumber[answerNumber]?.toolCallStarted()
        // The line first, then the note: after a click, the ended part's last sentence completing is not a new finding,
        // only the next part's line is.
        refreshCursorLine(answerNumber: answerNumber)
        if settings.answerDeliveryMode.showsText { cursorAnswerPresenter.noteToolCallStarted() }
    }

    private struct ComingAnswerDetails {
        let providerName: String
        let model: String
        let secondsToAnswer: Double?
        let pointLabel: String?
        let notesRead: [String]
    }

    /// Carries out the pure chat steps on the chat window's state.
    private func apply(_ steps: [GrowingAnswerChatState.Step], details: ComingAnswerDetails?) {
        for step in steps {
            switch step {
            case .setCheckingNotes(let isChecking):
                chatWindowState.isCheckingNotes = isChecking
            case .appendComingMessage(let token, let text):
                let message = ChatMessage(
                    role: .answer, text: text, providerName: details?.providerName, model: details?.model,
                    isStillComing: true)
                answerMessageIDs[token] = message.id
                chatWindowState.messages.append(message)
            case .replaceComingText(let token, let text):
                updateAnswerMessage(token: token) { $0.text = text }
            case .finishComingMessage(let token, let text):
                updateAnswerMessage(token: token) { message in
                    message.text = text
                    if let details {
                        message.model = details.model
                        message.secondsToAnswer = details.secondsToAnswer
                        message.pointLabel = details.pointLabel
                        message.notesRead = details.notesRead
                    }
                    message.isStillComing = false
                }
            case .appendFinishedMessage(let text):
                chatWindowState.messages.append(ChatMessage(
                    role: .answer, text: text, providerName: details?.providerName, model: details?.model,
                    secondsToAnswer: details?.secondsToAnswer, pointLabel: details?.pointLabel,
                    notesRead: details?.notesRead ?? []))
            }
        }
    }

    private func updateAnswerMessage(token: Int, _ change: (inout ChatMessage) -> Void) {
        guard let messageID = answerMessageIDs[token],
              let index = chatWindowState.messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&chatWindowState.messages[index])
    }

    fileprivate func showNotice(_ text: String) {
        // A notice takes the answer's place: a message still coming ends, the checking line stops, the voice stops.
        let endedSteps = growingAnswerChat.noticeShown()
        apply(endedSteps, details: nil)
        chatWindowState.messages.append(ChatMessage(role: .notice, text: text))
        guard lifecycle.acceptsPointerFlights else { return }
        // Only an answer still coming (or its checking line) is cut off by the notice. A notice that arrives with
        // nothing in flight (the failed switch to ChatGPT) leaves a finished answer being read aloud.
        if !endedSteps.isEmpty { spokenAnswerPlayer.stopSpeaking() }
        cursorAnswerPresenter.showNotice(text: text)
    }

    fileprivate func showUsageLimitOffer(message: String, switchTo provider: ProviderID) {
        let switchToProviderName = ProviderFailureNotice.displayName(for: provider)
        chatWindowState.usageLimitOffer = UsageLimitOffer(message: message, switchToProviderName: switchToProviderName)
        usageLimitSwitchTarget = provider
        let endedSteps = growingAnswerChat.noticeShown()
        apply(endedSteps, details: nil)
        // The one-tap switch lives in the menu-bar panel; the cursor only says where to find it.
        guard lifecycle.acceptsPointerFlights else { return }
        if !endedSteps.isEmpty { spokenAnswerPlayer.stopSpeaking() }
        cursorAnswerPresenter.showNotice(
            text: UsageLimitOfferRules.cursorNotice(message: message, switchToProviderName: switchToProviderName))
    }

    fileprivate func clearUsageLimitOffer() {
        chatWindowState.usageLimitOffer = nil
    }

    fileprivate func providerChanged(to provider: ProviderID, model: String) {
        // The switch holds for this session only; the saved setting stays as the user set it.
        let name = ProviderFailureNotice.displayName(for: provider)
        chatWindowState.activeProviderName = name
        chatWindowState.activeModel = model.isEmpty ? "default" : model
        chatWindowState.messages.append(ChatMessage(role: .notice, text: "Switched to \(name)"))
    }

    fileprivate func flyPointer(to point: CGPoint, displayFrameInPoints: CGRect, label: String?) {
        // An answer that lands during Stop's drain still reaches the chat as text, but the pointer stays put.
        guard lifecycle.acceptsPointerFlights else { return }
        pointerFlight.flyPointer(to: point, onDisplayWithFrame: displayFrameInPoints, label: label)
    }

    private func displayModelName(for provider: ProviderID) -> String {
        let name = SessionProviderFactory.modelName(for: provider)
        return name.isEmpty ? "default" : name
    }
}

/// Carries the question flow's output onto the main actor. The flow runs off the main thread.
private final class SessionFlowBridge: SessionFlowOutput, @unchecked Sendable {
    private weak var coordinator: SessionCoordinator?

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    func phaseChanged(_ phase: SessionFlowPhase) async {
        await MainActor.run { coordinator?.showPhase(phase) }
    }

    func questionAsked(_ text: String, answerNumber: Int) async {
        await MainActor.run { coordinator?.showQuestion(text, answerNumber: answerNumber) }
    }

    func answerReceived(
        answerNumber: Int, spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double,
        pointLabel: String?, notesRead: [String]
    ) async {
        await MainActor.run {
            coordinator?.showAnswer(
                answerNumber: answerNumber, spokenText: spokenText, provider: provider, model: model,
                secondsToAnswer: secondsToAnswer, pointLabel: pointLabel, notesRead: notesRead
            )
        }
    }

    func answerTextChanged(
        answerNumber: Int, visibleText: String, endsBeforeHiddenText: Bool, provider: ProviderID, model: String
    ) async {
        await MainActor.run { coordinator?.showAnswerText(
                answerNumber: answerNumber, visibleText: visibleText, endsBeforeHiddenText: endsBeforeHiddenText,
                provider: provider, model: model) }
    }

    func answerTextChanged(answerNumber: Int, visibleText: String, provider: ProviderID, model: String) async {
        await answerTextChanged(
            answerNumber: answerNumber, visibleText: visibleText, endsBeforeHiddenText: false, provider: provider, model: model)
    }

    func checkingNotesShown(answerNumber: Int) async {
        await MainActor.run { coordinator?.showCheckingNotes(answerNumber: answerNumber) }
    }

    func answerCutShort(
        answerNumber: Int, visibleText: String, provider: ProviderID, model: String, notesRead: [String],
        reason: AnswerCutReason
    ) async {
        await MainActor.run {
            coordinator?.showAnswerCutShort(
                answerNumber: answerNumber, visibleText: visibleText, provider: provider, model: model, notesRead: notesRead, reason: reason)
        }
    }

    func toolCallStarted(answerNumber: Int) async {
        await MainActor.run { coordinator?.showToolCallStarted(answerNumber: answerNumber) }
    }

    func noticeShown(_ text: String) async {
        await MainActor.run { coordinator?.showNotice(text) }
    }

    func usageLimitOffered(message: String, switchTo: ProviderID) async {
        await MainActor.run { coordinator?.showUsageLimitOffer(message: message, switchTo: switchTo) }
    }

    func usageLimitOfferCleared() async {
        await MainActor.run { coordinator?.clearUsageLimitOffer() }
    }

    func providerChanged(to provider: ProviderID, model: String) async {
        await MainActor.run { coordinator?.providerChanged(to: provider, model: model) }
    }

    func pointerRequested(globalPoint: CGPoint, displayFrameInPoints: CGRect, label: String?) async {
        await MainActor.run {
            coordinator?.flyPointer(to: globalPoint, displayFrameInPoints: displayFrameInPoints, label: label)
        }
    }
}
