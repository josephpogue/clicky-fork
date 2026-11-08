//
//  ChatWindowView.swift
//  leanring-buddy
//
//  The chat window. Built to be read in one glance while the user's hands
//  stay on the mouse: the latest answer sits in its own lifted card at the
//  bottom in larger type, earlier exchanges sit above it smaller and dimmer,
//  and one status line at the very bottom says what the app is doing now.
//

import ClickyCore
import SwiftUI

struct ChatWindowView: View {
    @ObservedObject var state: ChatWindowState

    @State private var latestCardContentHeight: CGFloat = 0
    /// History answers show three lines until the user asks for the rest,
    /// so an old "explain more" answer never turns the history into a wall.
    @State private var expandedHistoryAnswerIDs: Set<UUID> = []
    /// Answers whose "Notes read" list shows every name, not just the first three.
    @State private var expandedNotesReadAnswerIDs: Set<UUID> = []

    /// Preview renderer only: freezes the checking line's passing light (see `CheckingNotesLine`).
    var fixedCheckingSweepPhase: Double? = nil
    private let historyAnswerCollapsedLineCount = 3
    /// About three lines at the default window width.
    private let historyAnswerCollapsibleCharacterCount = 150

    /// The latest card may take at most this share of the window, so a long
    /// "explain more" answer scrolls inside its card and some history stays.
    private let latestCardShareOfHeight: CGFloat = 0.68

    var body: some View {
        GeometryReader { windowGeometry in
            VStack(spacing: 0) {
                header
                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 1)

                if transcript.focusedExchange == nil && transcript.historyItems.isEmpty {
                    emptyConversation
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    conversation(maximumLatestCardHeight: windowGeometry.size.height * latestCardShareOfHeight)
                }

                if let usageLimitOffer = state.usageLimitOffer {
                    usageLimitBanner(usageLimitOffer)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }

                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 1)
                statusLine
            }
        }
        .background(DS.Colors.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.window")
    }

    private var transcript: ChatTranscript {
        ChatTranscript(messages: state.messages)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(headerDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: state.isSessionRunning ? DS.Colors.destructive.opacity(0.55) : .clear, radius: 3, x: 0, y: 0.5)

            if state.isSessionRunning {
                Text(state.activeProviderName)
                    .font(DS.WindowText.bodyEmphasis)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(state.activeModel)
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
            } else {
                Text(headerTitleWhenNotRunning)
                    .font(DS.WindowText.bodyEmphasis)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer(minLength: 8)

            if state.isSessionRunning {
                Button(action: state.onStopSession) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("Stop session")
                    }
                }
                .clickyWindowButton(.quietDestructive, isCompact: true)
                .accessibilityIdentifier("chat.stopSession")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// Red means the app is watching. Starting and Stopping use amber, like the menu panel's dot.
    private var headerDotColor: Color {
        switch state.sessionPhase {
        case .running: return DS.Colors.destructive
        case .starting, .stopping: return DS.Colors.warning
        case .idle: return DS.Colors.textTertiary
        }
    }

    private var headerTitleWhenNotRunning: String {
        switch state.sessionPhase {
        case .starting: return "Starting session"
        case .stopping: return "Stopping session"
        case .idle, .running: return "Session ended"
        }
    }

    // MARK: - Conversation

    private func conversation(maximumLatestCardHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(transcript.historyItems) { historyItem in
                        historyRow(historyItem)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
            // Fade the history into the header so the cut-off line reads as "more above".
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Rectangle()
                }
            )

            if let focusedExchange = transcript.focusedExchange {
                latestCard(focusedExchange, maximumHeight: maximumLatestCardHeight)
                    .padding(.horizontal, 12)
                    .padding(.bottom, transcript.trailingNotices.isEmpty ? 12 : 8)
                    .layoutPriority(1)
            }

            ForEach(transcript.trailingNotices) { trailingNotice in
                noticeRow(trailingNotice)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ historyItem: ChatTranscriptItem) -> some View {
        switch historyItem.content {
        case .exchange(let question, let answer):
            VStack(alignment: .leading, spacing: 5) {
                if let question {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(question.message.text)
                            .font(DS.WindowText.bodyEmphasis)
                            .foregroundColor(DS.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chat.message.\(question.index)")
                        Spacer(minLength: 4)
                        Text(WindowTimeFormatting.clockTime(question.message.time))
                            .font(DS.WindowText.metaNumbers)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                if let answer {
                    historyAnswer(answer)
                }
            }
        case .notice(let notice):
            noticeRow(notice)
        }
    }

    private func historyAnswer(_ answer: IndexedChatMessage) -> some View {
        let isCollapsible = answer.message.text.count > historyAnswerCollapsibleCharacterCount
        let isExpanded = expandedHistoryAnswerIDs.contains(answer.message.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(answer.message.text)
                .font(DS.WindowText.body)
                .lineSpacing(DS.WindowText.bodyLineSpacing)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(isCollapsible && !isExpanded ? historyAnswerCollapsedLineCount : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("chat.message.\(answer.index)")
            if isCollapsible {
                Button(action: {
                    if isExpanded {
                        expandedHistoryAnswerIDs.remove(answer.message.id)
                    } else {
                        expandedHistoryAnswerIDs.insert(answer.message.id)
                    }
                }) {
                    Text(isExpanded ? "Show less" : "Show all")
                }
                .buttonStyle(WindowInlineLinkButtonStyle())
                .accessibilityIdentifier("chat.expand.\(answer.index)")
            }
            notesReadList(answer)
                .padding(.top, 2)
        }
    }

    /// Under a finished answer that read notes; nothing for a screen-only answer or one still coming.
    @ViewBuilder
    private func notesReadList(_ answer: IndexedChatMessage) -> some View {
        if !answer.message.isStillComing && !answer.message.notesRead.isEmpty {
            let answerID = answer.message.id
            NotesReadList(
                notePaths: answer.message.notesRead,
                isExpanded: expandedNotesReadAnswerIDs.contains(answerID),
                onToggleExpanded: {
                    if expandedNotesReadAnswerIDs.contains(answerID) {
                        expandedNotesReadAnswerIDs.remove(answerID)
                    } else {
                        expandedNotesReadAnswerIDs.insert(answerID)
                    }
                },
                messageIndex: answer.index)
        }
    }

    private func noticeRow(_ notice: IndexedChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textMuted)
            Text(notice.message.text)
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.message.\(notice.index)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeRow(_ noticeItem: ChatTranscriptItem) -> some View {
        Group {
            if case .notice(let notice) = noticeItem.content {
                noticeRow(notice)
            }
        }
    }

    // MARK: - Latest card

    /// Always a scroll view, sized to its content up to `maximumHeight`: a
    /// short answer gets a card that hugs it, a long one scrolls inside the card.
    private func latestCard(_ focusedExchange: ChatTranscriptItem, maximumHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            latestCardContent(focusedExchange)
                .background(
                    GeometryReader { contentGeometry in
                        Color.clear.preference(key: LatestCardContentHeightKey.self, value: contentGeometry.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(LatestCardContentHeightKey.self) { measuredHeight in
            latestCardContentHeight = measuredHeight
        }
        .frame(height: min(max(latestCardContentHeight, 48), maximumHeight))
        .background(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .fill(DS.Colors.latestAnswerSurface)
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.WindowRadius.card, style: .continuous))
    }

    @ViewBuilder
    private func latestCardContent(_ focusedExchange: ChatTranscriptItem) -> some View {
        if case .exchange(let question, let answer) = focusedExchange.content {
            VStack(alignment: .leading, spacing: 10) {
                if let question {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(question.message.text)
                            .font(DS.WindowText.bodyEmphasis)
                            .foregroundColor(DS.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chat.message.\(question.index)")
                        Spacer(minLength: 4)
                        Text(WindowTimeFormatting.clockTime(question.message.time))
                            .font(DS.WindowText.metaNumbers)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                if let answer {
                    // A growing answer has no text for a moment when its message is made before the first words.
                    if !answer.message.text.isEmpty {
                        Text(answer.message.text)
                            .font(DS.WindowText.latestAnswer)
                            .lineSpacing(DS.WindowText.latestAnswerLineSpacing)
                            .foregroundColor(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat.message.\(answer.index)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("chat.latestAnswer")
                    }

                    if answer.message.isStillComing {
                        if state.isCheckingNotes {
                            CheckingNotesLine(placement: .chatCard, fixedSweepPhase: fixedCheckingSweepPhase)
                                .frame(height: 22, alignment: .leading)
                        } else if answer.message.text.isEmpty {
                            pendingAnswerDots
                        }
                    }

                    notesReadList(answer)

                    answerFooter(answer.message)
                } else if isWaitingForAnswer {
                    if state.isCheckingNotes {
                        CheckingNotesLine(placement: .chatCard, fixedSweepPhase: fixedCheckingSweepPhase)
                            .frame(height: 22, alignment: .leading)
                    } else {
                        pendingAnswerDots
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The pointer chip first (it says where to look), then who answered and how fast.
    private func answerFooter(_ answerMessage: ChatMessage) -> some View {
        HStack(spacing: 8) {
            if let pointLabel = answerMessage.pointLabel {
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 11, weight: .semibold))
                    Text(pointLabel)
                        .font(DS.WindowText.meta)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundColor(DS.Colors.listeningWave)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(DS.Colors.listeningWave.opacity(0.10)))
                .layoutPriority(1)
                .accessibilityIdentifier("chat.pointLabel")
            }

            Spacer(minLength: 4)

            Text(answerMetaLine(answerMessage))
                .font(DS.WindowText.metaNumbers)
                .foregroundColor(DS.Colors.textMuted)
                .lineLimit(1)
        }
    }

    private func answerMetaLine(_ answerMessage: ChatMessage) -> String {
        var metaParts: [String] = []
        if let providerName = answerMessage.providerName { metaParts.append(providerName) }
        // An empty model is the CLI's own default, named as in the header.
        if let model = answerMessage.model { metaParts.append(model.isEmpty ? "default" : model) }
        if answerMessage.isStillComing {
            // No timing until it is done; this word is what tells a growing answer from a finished one.
            metaParts.append("answering")
        } else if let secondsToAnswer = answerMessage.secondsToAnswer {
            metaParts.append(WindowTimeFormatting.seconds(secondsToAnswer))
        }
        return metaParts.joined(separator: " · ")
    }

    private var isWaitingForAnswer: Bool {
        if case .waitingForAnswer = state.questionPhase { return true }
        return false
    }

    private var pendingAnswerDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { dotIndex in
                Circle()
                    .fill(DS.Colors.textMuted.opacity(0.55 + Double(dotIndex) * 0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(height: 22)
        .accessibilityLabel("Waiting for the answer")
    }

    // MARK: - Empty

    private var emptyConversation: some View {
        VStack(spacing: 14) {
            QuestionKeyCap(keyLabel: state.questionKeyLabel, isLarge: true)
            VStack(spacing: 6) {
                Text(state.isSessionRunning ? "Ask about what's on your screen" : emptyTitleWhenNotRunning)
                    .font(DS.WindowText.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(state.isSessionRunning
                     ? "Press \(state.questionKeyLabel), say your question, then press it again. The answer shows up here."
                     : emptyBodyWhenNotRunning)
                    .font(DS.WindowText.body)
                    .lineSpacing(DS.WindowText.bodyLineSpacing)
                    .foregroundColor(DS.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 260)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.empty")
    }

    private var emptyTitleWhenNotRunning: String {
        switch state.sessionPhase {
        case .starting: return "Starting session"
        case .stopping: return "Stopping session"
        case .idle, .running: return "No session running"
        }
    }

    private var emptyBodyWhenNotRunning: String {
        switch state.sessionPhase {
        case .starting: return "Nothing is watched until the session is running. Press Starting... to cancel."
        case .stopping: return "Finishing the session log."
        case .idle, .running: return "Start a session, then press \(state.questionKeyLabel) to ask a question."
        }
    }

    // MARK: - Usage limit

    private func usageLimitBanner(_ usageLimitOffer: UsageLimitOffer) -> some View {
        let switchState = UsageLimitOfferRules.switchButtonState(
            isQuestionPhaseIdle: state.questionPhase == .idle,
            isSwitchInProgress: state.isSwitchInProgress)
        return usageLimitBannerContent(usageLimitOffer, switchState: switchState)
    }

    private func usageLimitBannerContent(_ usageLimitOffer: UsageLimitOffer, switchState: UsageLimitSwitchButtonState) -> some View {
        WindowCallout(kind: .warning, message: usageLimitOffer.message, messageIdentifier: "chat.usageLimitMessage") {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: state.onSwitchProvider) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .bold))
                        Text("Switch to \(usageLimitOffer.switchToProviderName)")
                    }
                }
                .clickyWindowButton(.primary, isFullWidth: true)
                .disabled(!switchState.isEnabled)
                .opacity(switchState.isEnabled ? 1 : 0.45)
                .accessibilityIdentifier("chat.switchProvider")

                Text(switchState.caption ?? "This conversation comes with you.")
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
            }
        }
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 9) {
            if state.isSessionRunning && state.questionPhase == .idle,
               case .plain(let keyLostText) = ChatFooter.idleLine(isKeyTapLost: state.isKeyTapLost) {
                // The keys are gone: say so, with no key pill.
                Text(keyLostText)
                    .font(DS.WindowText.meta)
                    .foregroundColor(DS.Colors.textMuted)
                    .lineLimit(2)
                    .accessibilityIdentifier("chat.status")
            } else if state.isSessionRunning && state.questionPhase == .idle {
                // "Press [⌘ right] to ask": the key sits inside the sentence.
                HStack(spacing: 6) {
                    Text("Press")
                    QuestionKeyCap(keyLabel: state.questionKeyLabel)
                    Text("to ask")
                }
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Press \(state.questionKeyLabel) to ask")
                .accessibilityIdentifier("chat.status")
            } else {
                statusLeadingMark
                statusText
                    // A start step ("Waiting for microphone permission") is longer than the room beside the button.
                    .lineLimit(state.sessionPhase == .starting ? 2 : 1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("chat.status")
            }
            Spacer(minLength: 6)
            if !state.isSessionRunning {
                // Same button as the menu panel: Start session, Starting... (press to cancel), Stopping... (disabled).
                Button(action: state.onStartSession) {
                    Text(sessionButtonTitle)
                }
                .clickyWindowButton(state.sessionPhase == .idle ? .primary : .secondary, isCompact: true)
                .disabled(state.sessionPhase == .stopping)
                .accessibilityIdentifier("chat.startSession")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(DS.Colors.surface1)
    }

    private var sessionButtonTitle: String {
        switch state.sessionPhase {
        case .idle, .running: return "Start session"
        case .starting: return "Starting..."
        case .stopping: return "Stopping..."
        }
    }

    @ViewBuilder
    private var statusLeadingMark: some View {
        if state.sessionPhase == .starting || state.sessionPhase == .stopping {
            WindowSpinner(diameter: 13)
        } else if !state.isSessionRunning {
            Image(systemName: "pause.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textMuted)
        } else {
            switch state.questionPhase {
            case .idle:
                EmptyView()
            case .listening(let audioLevel):
                ListeningLevelBars(audioLevel: audioLevel, maximumBarHeight: 14)
            case .transcribing, .waitingForAnswer:
                WindowSpinner(diameter: 13)
            }
        }
    }

    private var statusText: Text {
        if state.sessionPhase == .starting {
            return Text(state.startStepText ?? "Starting session")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textSecondary)
        }
        if state.sessionPhase == .stopping {
            return Text("Stopping session")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textSecondary)
        }
        if !state.isSessionRunning {
            return Text("Start a session to ask again.")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
        }
        switch state.questionPhase {
        case .idle:
            return Text("Press to ask")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
        case .listening:
            return Text("Listening")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.listeningWave)
            + Text("  ·  press \(state.questionKeyLabel) to send")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textMuted)
        case .transcribing:
            return Text("Writing down your question")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textSecondary)
        case .waitingForAnswer(let providerName):
            return Text("Waiting for \(providerName)")
                .font(DS.WindowText.meta)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

// MARK: - Transcript grouping

struct IndexedChatMessage: Identifiable {
    /// The message's position in `ChatWindowState.messages`, used in its
    /// `chat.message.<n>` identifier.
    let index: Int
    let message: ChatMessage
    var id: UUID { message.id }
}

struct ChatTranscriptItem: Identifiable {
    enum Content {
        /// A question and its answer. Either side can be missing: a question
        /// still waiting, or an answer that arrived with no question before it.
        case exchange(question: IndexedChatMessage?, answer: IndexedChatMessage?)
        case notice(IndexedChatMessage)
    }

    let id: UUID
    let content: Content
}

/// Groups the flat message list into exchanges, then splits it into the
/// latest exchange (the focus), what came before it, and notices after it.
struct ChatTranscript {
    let historyItems: [ChatTranscriptItem]
    let focusedExchange: ChatTranscriptItem?
    let trailingNotices: [ChatTranscriptItem]

    init(messages: [ChatMessage]) {
        var groupedItems: [ChatTranscriptItem] = []
        var openQuestion: IndexedChatMessage?

        func closeOpenQuestionWithoutAnswer() {
            if let unansweredQuestion = openQuestion {
                groupedItems.append(ChatTranscriptItem(id: unansweredQuestion.id, content: .exchange(question: unansweredQuestion, answer: nil)))
                openQuestion = nil
            }
        }

        for (messageIndex, message) in messages.enumerated() {
            let indexedMessage = IndexedChatMessage(index: messageIndex, message: message)
            switch message.role {
            case .question:
                closeOpenQuestionWithoutAnswer()
                openQuestion = indexedMessage
            case .answer:
                let questionForThisAnswer = openQuestion
                openQuestion = nil
                groupedItems.append(ChatTranscriptItem(id: (questionForThisAnswer ?? indexedMessage).id, content: .exchange(question: questionForThisAnswer, answer: indexedMessage)))
            case .notice:
                closeOpenQuestionWithoutAnswer()
                groupedItems.append(ChatTranscriptItem(id: indexedMessage.id, content: .notice(indexedMessage)))
            }
        }
        closeOpenQuestionWithoutAnswer()

        let lastExchangePosition = groupedItems.lastIndex { groupedItem in
            if case .exchange = groupedItem.content { return true }
            return false
        }

        if let lastExchangePosition {
            historyItems = Array(groupedItems[..<lastExchangePosition])
            focusedExchange = groupedItems[lastExchangePosition]
            trailingNotices = Array(groupedItems[(lastExchangePosition + 1)...])
        } else {
            historyItems = groupedItems
            focusedExchange = nil
            trailingNotices = []
        }
    }
}

private struct LatestCardContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
