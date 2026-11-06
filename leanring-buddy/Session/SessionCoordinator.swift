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
        }
        // Switching to a mode that does not speak stops a reading in progress; switching to Spoken starts nothing.
        settings.$answerDeliveryMode
            .removeDuplicates()
            .sink { [weak self] mode in
                if !mode.speaksAloud { self?.spokenAnswerPlayer.stopSpeaking() }
            }
            .store(in: &settingsSubscriptions)

        // The button in the chat window does what the panel's button does in the current phase (Starting cancels).
        chatWindowState.onStartSession = { [weak self] in self?.handleSessionButton() }
        chatWindowState.onStopSession = { [weak self] in self?.stopSession() }
        chatWindowState.onSwitchProvider = { [weak self] in self?.switchToChatGPT() }
        questionKeyMonitor.onSignal = { [weak self] signal in
            Task { @MainActor in await self?.handleQuestionKeySignal(signal) }
        }
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

        let flow = makeQuestionFlow(sessionID: startedSessionID, shotsDirectory: shotsDirectory, recorder: recorder)
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
    }

    /// Ends a Start that failed or was cancelled: switches off whatever was on, ends the provider, and applies
    /// `SessionStartEnding`: a cancelled Start removes its session folder even when capture had begun; a real
    /// failure after capture began keeps a short session and shows its notice.
    private func discardStart(failure noticeText: String?) async {
        let ending = SessionStartEnding.decide(
            isCancelled: Task.isCancelled, failureNotice: noticeText, captureBegan: didStartCapture
        )
        questionKeyMonitor.stop()
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

    private func makeQuestionFlow(sessionID: String, shotsDirectory: URL, recorder: SessionScreenRecorder) -> SessionQuestionFlow {
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
            timeZone: .current
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

    private func resetMarkerAndQuestionPhase() {
        markerPanel.hide()
        hideCursorAnswerAndStopSpeaking()
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
            // A new question replaces the last answer: its text goes and its reading stops.
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

    fileprivate func showQuestion(_ text: String) {
        chatWindowState.messages.append(ChatMessage(role: .question, text: text))
    }

    fileprivate func showAnswer(
        spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double, pointLabel: String?
    ) {
        chatWindowState.messages.append(ChatMessage(
            role: .answer, text: spokenText, providerName: ProviderFailureNotice.displayName(for: provider),
            model: model, secondsToAnswer: secondsToAnswer, pointLabel: pointLabel
        ))
        chatWindowState.activeModel = model.isEmpty ? "default" : model
        settings.recordMeasuredAnswerSeconds(secondsToAnswer, for: provider)
        if chatWindowState.usageLimitOffer != nil, let switchTarget = usageLimitSwitchTarget,
           UsageLimitOfferRules.answerClearsOffer(switchTarget: switchTarget, answeredBy: provider) {
            chatWindowState.usageLimitOffer = nil
        }
        // An answer that lands during Stop's drain reaches the chat only, like the pointer.
        guard lifecycle.acceptsPointerFlights else { return }
        let deliveryMode = settings.answerDeliveryMode
        if deliveryMode.showsText { cursorAnswerPresenter.showAnswer(text: spokenText) }
        if deliveryMode.speaksAloud { spokenAnswerPlayer.speak(text: spokenText) }
    }

    fileprivate func showNotice(_ text: String) {
        chatWindowState.messages.append(ChatMessage(role: .notice, text: text))
        guard lifecycle.acceptsPointerFlights else { return }
        cursorAnswerPresenter.showNotice(text: text)
    }

    fileprivate func showUsageLimitOffer(message: String, switchTo provider: ProviderID) {
        let switchToProviderName = ProviderFailureNotice.displayName(for: provider)
        chatWindowState.usageLimitOffer = UsageLimitOffer(message: message, switchToProviderName: switchToProviderName)
        usageLimitSwitchTarget = provider
        // The one-tap switch lives in the menu-bar panel; the cursor only says where to find it.
        guard lifecycle.acceptsPointerFlights else { return }
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

    func questionAsked(_ text: String) async {
        await MainActor.run { coordinator?.showQuestion(text) }
    }

    func answerReceived(
        spokenText: String, provider: ProviderID, model: String, secondsToAnswer: Double, pointLabel: String?
    ) async {
        await MainActor.run {
            coordinator?.showAnswer(
                spokenText: spokenText, provider: provider, model: model,
                secondsToAnswer: secondsToAnswer, pointLabel: pointLabel
            )
        }
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
