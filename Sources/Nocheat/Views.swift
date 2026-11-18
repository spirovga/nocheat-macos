import SwiftUI

@main
struct NocheatApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("nocheat") {
            Group {
                switch model.access {
                case .signedOut: KeyView()
                case .waiting(let pending): WaitingView(pending: pending)
                case .ready: SessionView()
                }
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.35), value: model.access)
            .environmentObject(model)
            .frame(minWidth: 300, minHeight: 380)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(.primary)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 420, height: 640)
    }
}

/// Black, white and grey only: everything is drawn with primary/secondary on the window background.
struct MonoButton: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        MonoButtonBody(configuration: configuration, filled: filled)
    }
}

private struct MonoButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(filled ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .background(Color.primary.opacity(filled ? (hovering ? 0.82 : 1) : (hovering ? 0.08 : 0)), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(filled ? 0 : (hovering ? 0.5 : 0.25))))
            // The whole rounded rectangle is clickable, not just the label (an outlined button has a clear fill).
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.5)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: enabled)
            .onHover { hovering = $0 }
    }
}

struct Wordmark: View {
    var body: some View {
        Text("nocheat").font(.system(size: 13, weight: .semibold)).tracking(0.5)
    }
}

struct KeyView: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Wordmark()
            Text("Sign in")
                .font(.system(size: 26, weight: .light))
            Button(busy ? "Waiting for Google…" : "Continue with Google") {
                busy = true
                Task {
                    await model.signInWithGoogle()
                    busy = false
                }
            }
            .buttonStyle(MonoButton())
            .disabled(busy || !model.googleAvailable)
            if !model.googleAvailable {
                Text("Google sign-in isn't set up on this server.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("OR ENTER AN ACCESS KEY")
                .font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                .padding(.top, 10)
            SecureField("ac_…", text: $model.accessKey)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.25)))
                .onSubmit(submit)
            Button("Use access key", action: submit)
                .buttonStyle(MonoButton(filled: false))
                .disabled(busy || model.accessKey.isEmpty)
            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Server", text: model.$serverURL)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .onSubmit { Task { await model.checkServer() } }
        }
        .padding(32)
        .task { await model.checkServer() }
    }

    private func submit() {
        busy = true
        Task {
            await model.signIn()
            busy = false
        }
    }
}

/// Signed in with Google, but no access key has been issued to the account yet.
struct WaitingView: View {
    @EnvironmentObject var model: AppModel
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Wordmark()
            Text(pending ? "Waiting for approval" : "Request an access key")
                .font(.system(size: 26, weight: .light))
            Text(pending
                 ? "Your request has been sent. This window unlocks by itself once it is approved."
                 : "Your account doesn't have access yet. New accounts start with free minutes once approved.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if !pending {
                Button("Request access key") { Task { await model.requestAccess() } }.buttonStyle(MonoButton())
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Text(model.email ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Sign out", action: model.signOut).buttonStyle(.plain).font(.system(size: 11)).underline()
            }
        }
        .padding(32)
        .task(id: pending) {
            // Poll so an approval on the server reaches the app without a restart.
            while !Task.isCancelled {
                await model.refreshAccount()
                try? await Task.sleep(for: .seconds(pending ? 8 : 30))
            }
        }
    }
}

struct SessionView: View {
    @EnvironmentObject var model: AppModel

    /// The value currently drawn, 0 to 1. It runs up from zero each time a result arrives.
    @State private var shown = 0.0
    @State private var confirmingClear = false
    @State private var showingSessions = false
    private var urgent: Bool { model.lowBalance || model.outOfMinutes }

    private static let bottom = "transcript-bottom"

    /// Jumps to the end of the transcript. Rows are built lazily with estimated heights, so one jump
    /// can land short; repeating it after layout has caught up reaches the real end.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        for delay in [0, 0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }

    private static let languages = [
        ("multi", "Detect automatically"), ("ru", "Russian"), ("en", "English"), ("uk", "Ukrainian"),
        ("de", "German"), ("es", "Spanish"), ("fr", "French"),
    ]
    private var balance: String {
        guard let s = model.balanceSeconds else { return "" }
        if s <= 0 { return "No minutes left" }
        return s < 60 ? "Under 1 min left" : "\(Int(s / 60)) min left"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark()
                Spacer()
                // Turns into a solid pill when minutes are running low, so it is noticed in time.
                Text(balance).font(.system(size: 11, weight: urgent ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(urgent ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                    .padding(.horizontal, urgent ? 8 : 0).padding(.vertical, urgent ? 3 : 0)
                    .background(Color.primary.opacity(urgent ? 1 : 0), in: Capsule())
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: balance)
                Menu {
                    Picker("Language", selection: model.$language) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .disabled(model.phase != .idle)
                    Button("Previous sessions…") { showingSessions = true }
                    Button("Export chat history…", action: model.exportHistory)
                        .disabled(model.lines.isEmpty)
                    Button("Clear chat history…") { confirmingClear = true }
                        .disabled(model.lines.isEmpty || model.phase != .idle)
                    Divider()
                    if let email = model.email { Text(email) }
                    Button("Sign out", action: model.signOut)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .task {
                await model.refreshAccount()
                await model.refreshBalance()
            }
            .sheet(isPresented: $showingSessions) { PreviousSessions().environmentObject(model) }
            .confirmationDialog("Clear the chat history?", isPresented: $confirmingClear) {
                Button("Clear history", role: .destructive, action: model.clearHistory)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The transcript is removed from this Mac and cannot be restored. Export it first if you need a copy.")
            }

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Group {
                        if model.overall == nil { Text("—") } else { CountingNumber(value: shown * 100) }
                    }
                    .font(.system(size: 96, weight: .thin)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    if model.overall != nil { Text("%").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary) }
                }
                Text(model.verdict.map { $0.uppercased() } ?? "AI-GENERATION PROBABILITY")
                    .font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.12))
                        Rectangle().fill(Color.primary).frame(width: geo.size.width * (model.overall == nil ? 0 : shown))
                    }
                }
                .frame(height: 2)
                .padding(.top, 10)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, model.timing == nil ? 16 : 10)
            // Every result, even one equal to the last, restarts the count from zero; the bar follows.
            .onChange(of: model.scoreTick) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { shown = 0 }
                DispatchQueue.main.async {
                    withAnimation(.smooth(duration: 0.9)) { shown = model.overall ?? 0 }
                }
            }
            .animation(.smooth(duration: 0.3), value: model.verdict)
            .animation(.smooth(duration: 0.3), value: model.timing)

            if let timing = model.timing {
                TimingLine(timing: timing)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity)
            }

            Divider()
            if model.phase == .live {
                SpeakerSignals(levels: model.levels)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.lines.isEmpty {
                            Text(model.phase == .live ? "Listening…" : "Start before the interview begins. The transcript appears here as people speak.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                            Group {
                                if line.speaker == TranscriptLine.divider {
                                    SessionDivider(time: line.text)
                                } else {
                                    Bubble(line: line, showsName: index == 0 || model.lines[index - 1].speaker != line.speaker)
                                }
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    // The true end of the content, below the last bubble and its padding.
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                // The transcript always shows its newest text: on opening, while words arrive,
                // and when the area changes size.
                .defaultScrollAnchor(.bottom)
                .onAppear { scrollToBottom(proxy) }
                .animation(.smooth(duration: 0.25), value: model.lines.count)
                .onChange(of: model.lines.last.map { $0.text + $0.interim }) { scrollToBottom(proxy) }
                .onChange(of: model.lines.count) { scrollToBottom(proxy) }
                .onChange(of: model.phase) { scrollToBottom(proxy) }
                .onChange(of: model.timing) { scrollToBottom(proxy) }
            }
            Divider()

            VStack(spacing: 8) {
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.phase == .live && model.lowBalance {
                    LowBalanceBanner().transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Group {
                switch model.phase {
                case .idle:
                    if model.outOfMinutes {
                        OutOfMinutes()
                    } else {
                        Button("Start listening", action: model.start).buttonStyle(MonoButton())
                    }
                case .connecting: Button("Connecting…") {}.buttonStyle(MonoButton(filled: false)).disabled(true)
                case .live:
                    HStack(spacing: 8) {
                        Button(model.evaluating ? "Evaluating…" : "Evaluate", action: model.evaluate)
                            .buttonStyle(MonoButton())
                            .disabled(model.evaluating)
                        Button("Stop", action: model.stop).buttonStyle(MonoButton(filled: false))
                    }
                    .animation(.smooth(duration: 0.25), value: model.evaluating)
                case .stopping: Button("Finishing…") {}.buttonStyle(MonoButton(filled: false)).disabled(true)
                }
                }
                .id(model.phase)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                Text("An estimate, not proof. Tell the candidate the call is being analysed.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(20)
            .animation(.smooth(duration: 0.3), value: model.phase)
            .animation(.smooth(duration: 0.3), value: model.lowBalance)
            .animation(.smooth(duration: 0.3), value: model.outOfMinutes)
            .animation(.smooth(duration: 0.3), value: model.topUpRequested)
            .animation(.smooth(duration: 0.3), value: model.notice)
        }
    }
}

/// One transcript line, messenger-style: the candidate on the left, you (the interviewer) on the right.
struct Bubble: View {
    let line: TranscriptLine
    let showsName: Bool

    private var mine: Bool { line.speaker == "interviewer" }
    private var ink: Color { mine ? Color(nsColor: .windowBackgroundColor) : Color.primary }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showsName {
                Text(mine ? "YOU" : "CANDIDATE")
                    .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            // Settled words, then the ones still being recognised in a fainter tone. A long sentence
            // simply wraps onto further lines inside the same bubble.
            (Text(line.text) + Text(line.text.isEmpty || line.interim.isEmpty ? line.interim : " " + line.interim).foregroundColor(ink.opacity(0.5)))
                .font(.system(size: 13))
                .foregroundStyle(ink)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(mine ? Color.primary : Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .textSelection(.enabled)
        }
        .padding(mine ? .leading : .trailing, 44)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// A whole number that counts through the intermediate values when animated.
struct CountingNumber: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
    }
}

/// The line between two listening sessions in the transcript.
struct SessionDivider: View {
    let time: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1)
            Text("NEW SESSION · \(time)")
                .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1)
        }
        .padding(.vertical, 14)
    }
}

/// Shown while listening with under five minutes left.
struct LowBalanceBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.topUpRequested ? "Running low. More minutes requested." : "Running low on minutes.")
                .font(.system(size: 12))
            Spacer()
            if !model.topUpRequested {
                Button("Request more") { Task { await model.requestMinutes() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).underline()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.25)))
    }
}

/// Replaces the Start button when the balance is zero. It keeps checking, so the app unlocks
/// by itself as soon as minutes are added.
struct OutOfMinutes: View {
    @EnvironmentObject var model: AppModel
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.topUpRequested ? "More minutes requested" : "You're out of minutes")
                .font(.system(size: 15, weight: .medium))
            Text(model.topUpRequested
                 ? "Listening unlocks by itself as soon as they are added. Your transcript is saved."
                 : "Listening has stopped. Your transcript is saved and can still be exported.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.topUpRequested {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Button(sending ? "Sending…" : "Request more minutes") {
                    sending = true
                    Task {
                        await model.requestMinutes()
                        sending = false
                    }
                }
                .buttonStyle(MonoButton())
                .disabled(sending)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.25)))
        .task(id: model.topUpRequested) {
            while !Task.isCancelled {
                await model.refreshBalance()
                try? await Task.sleep(for: .seconds(model.topUpRequested ? 6 : 20))
            }
        }
    }
}

/// Opened from the menu: recent finished sessions, each with its result and a Re-evaluate button.
struct PreviousSessions: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Previous sessions").font(.system(size: 15, weight: .medium))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)

            if model.recent.isEmpty {
                Text(loading ? "Loading…" : "No finished sessions yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.recent) { SessionRow(session: $0) }
                    }
                }
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            }
        }
        .padding(20)
        .frame(width: 380)
        .frame(minHeight: 200, maxHeight: 440)
        .task {
            await model.loadRecent()
            loading = false
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: PastSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.started?.formatted(date: .abbreviated, time: .shortened) ?? "Session \(session.id)")
                    .font(.system(size: 12))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.probability.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 18, weight: .light)).monospacedDigit()
                .contentTransition(.numericText())
                .opacity(session.busy ? 0.35 : 1)
            Button(session.busy ? "Evaluating…" : "Re-evaluate") { Task { await model.evaluatePast(session.id) } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 84)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.3)))
                .contentShape(Capsule())
                .disabled(session.busy || session.words == 0)
                .opacity(session.words == 0 ? 0.35 : 1)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
        .animation(.smooth(duration: 0.4), value: session.probability)
        .animation(.smooth(duration: 0.2), value: session.busy)
    }

    private var subtitle: String {
        let length = session.seconds < 60 ? "under 1 min" : "\(Int(session.seconds / 60)) min"
        if session.words == 0 { return "\(length) · the candidate said nothing" }
        return [length, "\(session.words) words", session.detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// The response-timing signal under the score: plain while unremarkable, a solid pill when answers
/// keep starting 3 seconds or more after the question.
struct TimingLine: View {
    let timing: ResponseTiming

    var body: some View {
        HStack(spacing: 8) {
            if timing.flagged {
                Text("CONSISTENT DELAY OVER 3 S")
                    .font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary, in: Capsule())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                Text("ANSWER DELAY").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
        }
    }

    private var detail: String {
        let average = timing.meanSeconds.map { String(format: "avg %.1f s", $0) } ?? ""
        let answers = timing.samples == 1 ? "1 answer" : "\(timing.samples) answers"
        return "\(timing.inBand) of \(answers) after 3 s · \(average)"
    }
}
