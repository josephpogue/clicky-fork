//
//  SessionCoordinator.swift
//  leanring-buddy
//
//  Owns one Clicky Fork session from Start to Stop: microphone, screen
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

    @Published private(set) var isSessionRunning = false

    /// A short line for the menu bar panel when a session could not start.
    @Published private(set) var panelNotice: String?

    /// Sends a session's id once Stop has finished writing its log and cleanup.
    let sessionFinished = PassthroughSubject<String, Never>()

    private let settings = AppSettings.shared
    private let pointerFlight = PointerFlightController()
    private let markerPanel = QuestionMarkerPanel()
    private let questionKeyMonitor = QuestionKeyMonitor()
    private let frontmostWindowTracker = FrontmostWindowTracker()

    /// Loads the speech model in the background at launch; a session waits for it if it is not ready yet.
    private var speechTranscriberTask: Task<SpeechTranscriber, Never>?
    private var isSpeechTranscriberReady = false

    private var isStartingOrStopping = false
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

        chatWindowState.onStartSession = { [weak self] in self?.startSession() }
        chatWindowState.onStopSession = { [weak self] in self?.stopSession() }
        chatWindowState.onSwitchProvider = { [weak self] in self?.switchToChatGPT() }
        questionKeyMonitor.onSignal = { [weak self] signal in
            Task { @MainActor in await self?.handleQuestionKeySignal(signal) }
        }
    }

    // MARK: - Speech model

    /// Starts loading the speech model. Loading reads no audio and opens no microphone.
    func prepareSpeech() {
        guard speechTranscriberTask == nil else { return }
        speechTranscriberTask = Task.detached(priority: .utility) {
            let transcriber = await SpeechEngineFactory.makePreferredTranscriber()
            await MainActor.run { SessionCoordinator.shared.isSpeechTranscriberReady = true }
            return transcriber
        }
    }

    // MARK: - Start

    func startSession() {
        guard !isSessionRunning, !isStartingOrStopping else { return }
        isStartingOrStopping = true
        panelNotice = nil
        Task {
            await performStart()
            isStartingOrStopping = false
        }
    }

    private func performStart() async {
        // 1. The two permissions the app cannot ask for itself while running.
        var missingPermissions: [String] = []
        if !WindowPositionManager.hasAccessibilityPermission() { missingPermissions.append("Accessibility") }
        if !WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() {
            missingPermissions.append("Screen Recording")
        }
        if !missingPermissions.isEmpty {
            let noticeText = "Turn on \(missingPermissions.joined(separator: " and ")) for Clicky Fork in System Settings, under Privacy and Security, then start the session again."
            failToStart(noticeText)
            return
        }

        // A new session replaces the finished conversation in the chat window.
        let providerID = settings.selectedProvider
        chatWindowState.messages = []
        chatWindowState.usageLimitOffer = nil
        chatWindowState.questionPhase = .idle
        chatWindowState.activeProviderName = ProviderFailureNotice.displayName(for: providerID)
        chatWindowState.activeModel = displayModelName(for: providerID)

        // 2. The log.
        let startedSessionID: String
        do {
            startedSessionID = try await sessionStore.startSession(at: Date()).id
        } catch {
            failToStart("The session log could not be created.")
            return
        }
        sessionID = startedSessionID
        let shotsDirectory = sessionStore.shotsDirectory(sessionID: startedSessionID)

        // Everything that reaches the log from outside the flow goes through one queue, so it is written in order.
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: SessionInput.self)
        sessionInputContinuation = inputContinuation

        let recorder = SessionScreenRecorder(shotsDirectory: shotsDirectory)
        screenRecorder = recorder

        let flow = makeQuestionFlow(sessionID: startedSessionID, shotsDirectory: shotsDirectory, recorder: recorder)
        questionFlow = flow

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

        // 3. Window tracking, then screen recording (it needs to know the starting window).
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
            await abandonStart("Screen Recording is not working. Check that Clicky Fork is allowed in System Settings, under Privacy and Security.")
            return
        }

        // 4. Speech: wait for the model if it is still loading.
        if speechTranscriberTask == nil { prepareSpeech() }
        if !isSpeechTranscriberReady {
            chatWindowState.messages.append(ChatMessage(role: .notice, text: "Getting speech ready"))
            panelNotice = "Getting speech ready"
        }
        let transcriber = await speechTranscriberTask!.value
        panelNotice = nil
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
            await abandonStart(error.localizedDescription)
            return
        }

        // 5. The provider, then the question key last, so no tap can arrive before the conversation exists.
        do {
            try await flow.begin()
        } catch let failure as ProviderFailure {
            await abandonStart(ProviderFailureNotice.text(for: failure, provider: providerID))
            return
        } catch {
            await abandonStart("The AI helper could not be started.")
            return
        }
        guard questionKeyMonitor.start() else {
            await abandonStart("The question key needs Accessibility. Turn it on for Clicky Fork in System Settings, under Privacy and Security.")
            return
        }

        isSessionRunning = true
        chatWindowState.isSessionRunning = true
        AppWindowRouter.shared.showChat()
    }

    /// Stops whatever a failed start had already started, then reports why.
    private func abandonStart(_ noticeText: String) async {
        questionKeyMonitor.stop()
        await speechPipeline?.stop()
        await screenRecorder?.stop()
        frontmostWindowTracker.stop()
        sessionInputContinuation?.finish()
        await sessionInputTask?.value
        _ = await questionFlow?.finish(summaryEnabled: false)
        if let sessionID {
            _ = try? await sessionStore.finishSession(sessionID: sessionID, at: Date(), summary: nil)
        }
        clearSessionObjects()
        failToStart(noticeText)
    }

    private func failToStart(_ noticeText: String) {
        panelNotice = noticeText
        chatWindowState.messages.append(ChatMessage(role: .notice, text: noticeText))
        chatWindowState.isSessionRunning = false
        AppWindowRouter.shared.showChat()
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
        guard isSessionRunning, let questionFlow else { return }
        let outcome = await questionFlow.handle(signal)
        if outcome == .ignoredBecauseBusy, case .questionStarted = signal {
            // The tap was dropped, so forget it: the next tap must start a question, not send one.
            questionKeyMonitor.forgetPendingQuestion()
        }
    }

    private func noteAudioLevel(_ level: Double) {
        guard case .listening = currentPhase, abs(level - lastShownAudioLevel) > 0.02 else { return }
        lastShownAudioLevel = level
        markerPanel.show(phase: .listening(audioLevel: level))
    }

    // MARK: - Switching provider

    private func switchToChatGPT() {
        guard let questionFlow else { return }
        Task { await questionFlow.switchProvider(to: .chatgpt) }
    }

    // MARK: - Stop

    func stopSession() {
        guard isSessionRunning, !isStartingOrStopping else { return }
        isStartingOrStopping = true
        Task {
            await performStop(askForSummary: settings.summaryAtStopEnabled)
            isStartingOrStopping = false
        }
    }

    /// Quitting the app mid-session: the same Stop, without the summary request.
    func stopSessionForQuit() async {
        guard isSessionRunning else { return }
        while isStartingOrStopping { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard isSessionRunning else { return }
        isStartingOrStopping = true
        await performStop(askForSummary: false)
        isStartingOrStopping = false
    }

    private func performStop(askForSummary: Bool) async {
        guard let flow = questionFlow, let finishingSessionID = sessionID else { return }

        // Everything that watches or listens goes off first.
        questionKeyMonitor.stop()
        await speechPipeline?.stop()
        await screenRecorder?.stop()
        frontmostWindowTracker.stop()
        markerPanel.hide()
        pointerFlight.cancelFlight()
        isSessionRunning = false
        chatWindowState.isSessionRunning = false
        chatWindowState.questionPhase = .idle
        chatWindowState.usageLimitOffer = nil
        currentPhase = .idle

        // Let queued log lines land before the stop line.
        sessionInputContinuation?.finish()
        await sessionInputTask?.value

        let summary = await flow.finish(summaryEnabled: askForSummary)
        do {
            _ = try await sessionStore.finishSession(sessionID: finishingSessionID, at: Date(), summary: summary)
        } catch {
            print("Clicky Fork: the session log could not be finished: \(error)")
        }
        clearSessionObjects()
        sessionFinished.send(finishingSessionID)
    }

    // MARK: - What the question flow tells the screen

    fileprivate func showPhase(_ phase: SessionFlowPhase) {
        currentPhase = phase
        let providerName: (ProviderID) -> String = { ProviderFailureNotice.displayName(for: $0) }
        switch phase {
        case .idle:
            chatWindowState.questionPhase = .idle
            markerPanel.show(phase: .idle)
        case .listening:
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
    }

    fileprivate func showNotice(_ text: String) {
        chatWindowState.messages.append(ChatMessage(role: .notice, text: text))
    }

    fileprivate func showUsageLimitOffer(message: String, switchTo provider: ProviderID) {
        chatWindowState.usageLimitOffer = UsageLimitOffer(
            message: message, switchToProviderName: ProviderFailureNotice.displayName(for: provider)
        )
    }

    fileprivate func clearUsageLimitOffer() {
        chatWindowState.usageLimitOffer = nil
    }

    fileprivate func providerChanged(to provider: ProviderID, model: String) {
        // The choice holds for the rest of the session, as the Settings screen shows it too.
        settings.selectedProvider = provider
        let name = ProviderFailureNotice.displayName(for: provider)
        chatWindowState.activeProviderName = name
        chatWindowState.activeModel = model.isEmpty ? "default" : model
        chatWindowState.messages.append(ChatMessage(role: .notice, text: "Switched to \(name)"))
    }

    fileprivate func flyPointer(to point: CGPoint, displayFrameInPoints: CGRect, label: String?) {
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
