import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CallViewModel()
    @State private var selectedTab: Tab = .home

    enum Tab {
        case home, call, history
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Content
                Group {
                    switch selectedTab {
                    case .home:
                        HomeView(vm: vm, onNewCall: { selectedTab = .call }, onOpenTracker: { selectedTab = .call })
                    case .call:
                        if vm.isActive {
                            ActiveCallView(vm: vm)
                        } else {
                            NewCallView(vm: vm)
                        }
                    case .history:
                        HistoryView(vm: vm)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Tab bar
                TabBarView(selected: $selectedTab, hasActiveCall: vm.isActive)
            }
        }
        .task {
            await vm.loadInitialData()
        }
    }
}

// MARK: - Tab Bar

struct TabBarView: View {
    @Binding var selected: ContentView.Tab
    let hasActiveCall: Bool

    var body: some View {
        HStack(spacing: 0) {
            tabItem(tab: .home, icon: "house", label: "Home")
            tabItem(tab: .call, icon: "phone.fill", label: hasActiveCall ? "Live" : "Call", badge: hasActiveCall)
            tabItem(tab: .history, icon: "clock", label: "History")
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Theme.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.rule).frame(height: 0.5)
        }
    }

    private func tabItem(tab: ContentView.Tab, icon: String, label: String, badge: Bool = false) -> some View {
        Button {
            selected = tab
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                    if badge {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -2)
                    }
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(selected == tab ? Theme.accent : Theme.inkMid)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var vm: CallViewModel
    let onNewCall: () -> Void
    let onOpenTracker: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Notification warning banner
                if vm.notificationStatus == "denied" {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(Theme.error)
                        Text("Notifications are OFF — enable in Settings > MeWantHuman")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.error)
                        Spacer()
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.accent)
                    }
                    .padding(12)
                    .background(Theme.error.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(Theme.error.opacity(0.2), lineWidth: 0.5))
                    .padding(.bottom, 16)
                }

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(dateString().uppercased())
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.inkMid)
                        .tracking(1.2)

                    HStack(spacing: 0) {
                        Text("Skip the hold, get ")
                            .font(.system(size: 26, weight: .medium))
                        Text("a human.")
                            .font(.custom("Georgia", size: 26))
                            .italic()
                            .foregroundColor(Theme.accent)
                    }
                }
                .padding(.bottom, 24)

                // Active call banner or CTA
                if vm.isActive {
                    activeCallBanner
                } else {
                    ctaCard
                }

                // Recent calls
                if !vm.history.isEmpty {
                    recentCalls
                }
            }
            .padding(24)
        }
    }

    private var activeCallBanner: some View {
        Button(action: onOpenTracker) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    PulsingDot()
                    Text("ON THE LINE NOW")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .tracking(1.2)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.phone)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(Theme.ink)
                        Text("\(vm.elapsed) elapsed")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.inkMid)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text("Track")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accent)
                    .clipShape(Capsule())
                }
            }
            .padding(20)
            .background(Theme.paper)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rLg)
                    .stroke(Theme.accent.opacity(0.3), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.rLg))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 28)
    }

    private var ctaCard: some View {
        Button(action: onNewCall) {
            VStack(alignment: .leading, spacing: 8) {
                Text("START SOMETHING")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.inkMid)
                    .tracking(1.2)

                Text("Give us a number — we'll handle the menu maze.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .multilineTextAlignment(.leading)

                Text("A bot calls, navigates the IVR, waits on hold, and connects you to a human.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.inkMid)

                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text("New call")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.accent)
                    .clipShape(Capsule())
                }
                .padding(.top, 8)
            }
            .padding(22)
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rLg))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 28)
    }

    private var recentCalls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT CALLS")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.inkMid)
                .tracking(1.2)

            VStack(spacing: 0) {
                ForEach(Array(vm.history.prefix(5).enumerated()), id: \.element.id) { index, entry in
                    historyRow(entry: entry)
                    if index < min(vm.history.count - 1, 4) {
                        Rectangle().fill(Theme.rule).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rLg))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }

    private func historyRow(entry: HistoryEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.phone)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(Theme.ink)
                Text(entry.reason ?? "No reason given")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.inkLow)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.status == "completed" ? "Completed" : entry.status)
                    .font(.system(size: 12))
                    .foregroundColor(entry.status == "completed" ? Theme.success : Theme.inkMid)
                if let ts = entry.endedAt ?? entry.startedAt {
                    Text(formatTimestamp(ts))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.inkLow)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    private func formatTimestamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - New Call

struct NewCallView: View {
    @ObservedObject var vm: CallViewModel
    @State private var phoneInput = ""
    @State private var reason = ""
    @State private var showPasteHint = false

    private var normalizedDigits: String {
        phoneInput.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
    }

    private var isValidPhone: Bool {
        let d = normalizedDigits
        return d.count >= 7 && d.count <= 15
    }

    private var formattedPreview: String {
        let d = normalizedDigits
        if d.count == 10 {
            let area = d.prefix(3)
            let mid = d.dropFirst(3).prefix(3)
            let last = d.suffix(4)
            return "(\(area)) \(mid)-\(last)"
        } else if d.count == 11 && d.first == "1" {
            let area = d.dropFirst(1).prefix(3)
            let mid = d.dropFirst(4).prefix(3)
            let last = d.suffix(4)
            return "+1 (\(area)) \(mid)-\(last)"
        }
        return phoneInput
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("NEW CALL")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.inkLow)
                    .tracking(1.2)

                HStack(spacing: 0) {
                    Text("Who do you need to ")
                        .font(.system(size: 26, weight: .medium))
                    Text("reach?")
                        .font(.custom("Georgia", size: 26))
                        .italic()
                        .foregroundColor(Theme.accent)
                }
                .padding(.top, 10)

                Text("Enter any phone number \u{2014} we'll dial it, navigate their menus and hold music, and notify you the instant a real human picks up.")
                    .font(.system(size: 13.5))
                    .foregroundColor(Theme.inkMid)
                    .padding(.top, 6)

                // Phone number input
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Phone number")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.ink)
                        Spacer()
                        Button {
                            if let clip = UIPasteboard.general.string {
                                let digits = clip.replacingOccurrences(of: "[^0-9+() \\-.]", with: "", options: .regularExpression)
                                if !digits.isEmpty {
                                    phoneInput = clip
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 10))
                                Text("Paste")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(Theme.accent)
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.inkLow)

                        TextField("(555) 123-4567", text: $phoneInput)
                            .font(.system(size: 18, design: .monospaced))
                            .keyboardType(.phonePad)
                            .foregroundColor(Theme.ink)

                        if isValidPhone {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Ready")
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                            .foregroundColor(Theme.success)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Theme.success.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.success.opacity(0.3), lineWidth: 0.5))
                        }
                    }
                    .padding(14)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(isValidPhone ? Theme.success.opacity(0.4) : Theme.rule, lineWidth: 0.5))
                }
                .padding(.top, 28)

                // Reason
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("What do you need")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.ink)
                        Spacer()
                        Text("Optional")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.inkMid)
                    }

                    TextField("e.g. dispute a charge, cancel subscription...", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(size: 14))
                        .padding(14)
                        .background(Theme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(Theme.rule, lineWidth: 0.5))
                }
                .padding(.top, 24)

                // Submit
                HStack {
                    Spacer()
                    Button {
                        Task { await vm.startCall(phoneNumber: phoneInput, reason: reason) }
                    } label: {
                        HStack(spacing: 8) {
                            if vm.isBusy {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.white)
                                Text("Agent Working...")
                            } else {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 12))
                                Text("Place call")
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(isValidPhone ? Theme.accent : Theme.inkLow)
                        .clipShape(Capsule())
                    }
                    .disabled(vm.isBusy || !isValidPhone)
                    .opacity(vm.isBusy ? 0.6 : 1)
                }
                .padding(.top, 24)
            }
            .padding(24)
        }
    }
}

// MARK: - Active Call (Tracker)

struct ActiveCallView: View {
    @ObservedObject var vm: CallViewModel
    @State private var showTranscript = false

    private var phaseSteps: [(phase: CallViewModel.CallPhase, label: String, icon: String)] {
        [
            (.spawn, "Starting", "bolt.fill"),
            (.call, "Dialing", "phone.arrow.up.right"),
            (.nav, "Navigating menus", "list.bullet"),
            (.hold, "Waiting on hold", "music.note"),
            (.human, "Human found", "person.fill"),
            (.xfer, "Connecting you", "arrow.right.arrow.left"),
        ]
    }

    private var currentStepIndex: Int {
        phaseSteps.firstIndex(where: { $0.phase == vm.phase }) ?? -1
    }

    private var phaseDescription: String {
        switch vm.phase {
        case .idle: return "Getting ready..."
        case .spawn: return "Spinning up an AI agent to handle this call for you."
        case .call: return "Dialing the number now. We'll navigate their phone system automatically."
        case .nav: return "Working through the automated menu. Pressing buttons, saying the right things."
        case .hold: return "We're in the hold queue. Sit tight \u{2014} we'll notify you the moment a human answers."
        case .human: return "A real person picked up! Get ready \u{2014} we're about to connect you."
        case .xfer: return "Transferring the call to your phone now."
        case .completed: return "All done. The call has been completed."
        case .error: return "Something went wrong. You can try again."
        }
    }

    private var phaseColor: Color {
        switch vm.phase {
        case .human, .xfer, .completed: return Theme.success
        case .error: return Theme.error
        default: return Theme.accent
        }
    }

    private var phaseIcon: String {
        switch vm.phase {
        case .completed: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        default: return phaseSteps.first(where: { $0.phase == vm.phase })?.icon ?? "circle"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Status header strip
                statusStrip
                    .padding(.bottom, 20)

                // Hero phase card
                heroCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                // Progress stepper
                progressStepper
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                // Latest activity preview
                if let lastMsg = vm.messages.last(where: { $0.type == "assistant" || $0.type == "transcript" }) {
                    latestActivity(message: lastMsg)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }

                // Expandable transcript
                transcriptSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                // Action button
                actionButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack {
            HStack(spacing: 8) {
                if vm.phase != .completed && vm.phase != .error {
                    PulsingDot()
                }
                Text(vm.phase == .completed ? "COMPLETED" : vm.phase == .error ? "FAILED" : "LIVE")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(phaseColor)
                    .tracking(1.2)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.inkMid)
                Text(vm.elapsed)
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 0.5)
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: 16) {
            // Phase icon
            ZStack {
                Circle()
                    .fill(phaseColor.opacity(0.1))
                    .frame(width: 72, height: 72)

                Image(systemName: phaseIcon)
                    .font(.system(size: 28))
                    .foregroundColor(phaseColor)
            }

            // Phase title
            Text(vm.phase == .completed ? "Call Completed" : vm.phase == .error ? "Call Failed" : (phaseSteps.first(where: { $0.phase == vm.phase })?.label ?? vm.phase.label))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.ink)

            // Description
            Text(phaseDescription)
                .font(.system(size: 14))
                .foregroundColor(Theme.inkMid)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            // Phone number pill
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 10))
                Text(vm.phone)
                    .font(.system(size: 13, design: .monospaced))
            }
            .foregroundColor(Theme.inkMid)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.stone.opacity(0.6))
            .clipShape(Capsule())
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rLg))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    // MARK: - Progress Stepper

    private var progressStepper: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(phaseSteps.enumerated()), id: \.offset) { index, step in
                let isDone = index < currentStepIndex
                let isActive = index == currentStepIndex
                let isSuccess = isActive && (step.phase == .human || step.phase == .xfer)
                let dotColor = isDone ? Theme.success : isSuccess ? Theme.success : isActive ? Theme.accent : Theme.rule

                HStack(spacing: 14) {
                    // Vertical line + dot
                    VStack(spacing: 0) {
                        if index > 0 {
                            Rectangle()
                                .fill(isDone ? Theme.success.opacity(0.4) : Theme.rule)
                                .frame(width: 2, height: 12)
                        } else {
                            Spacer().frame(height: 12)
                        }

                        ZStack {
                            Circle()
                                .fill(dotColor)
                                .frame(width: isDone || isActive ? 10 : 8, height: isDone || isActive ? 10 : 8)

                            if isDone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }

                        if index < phaseSteps.count - 1 {
                            Rectangle()
                                .fill(isDone ? Theme.success.opacity(0.4) : Theme.rule)
                                .frame(width: 2, height: 12)
                        } else {
                            Spacer().frame(height: 12)
                        }
                    }
                    .frame(width: 16)

                    // Label
                    HStack(spacing: 8) {
                        Image(systemName: step.icon)
                            .font(.system(size: 12))
                            .foregroundColor(isActive ? phaseColor : isDone ? Theme.success : Theme.inkLow)
                            .frame(width: 18)

                        Text(step.label)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? Theme.ink : isDone ? Theme.inkMid : Theme.inkLow)

                        if isActive && vm.phase != .completed && vm.phase != .error {
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(phaseColor)
                        }
                    }

                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rLg))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - Latest Activity

    private func latestActivity(message: CallViewModel.TranscriptMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATEST")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.inkLow)
                .tracking(1)

            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(message.type == "assistant" ? Theme.accent : Theme.ink)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundColor(Theme.ink2)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - Expandable Transcript

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showTranscript.toggle()
                }
            } label: {
                HStack {
                    Text("ACTIVITY LOG")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.inkMid)
                        .tracking(1)

                    if !vm.messages.isEmpty {
                        Text("\(vm.messages.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.inkLow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.stone)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.inkLow)
                        .rotationEffect(.degrees(showTranscript ? 90 : 0))
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            if showTranscript {
                Rectangle().fill(Theme.rule).frame(height: 0.5)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(vm.messages) { msg in
                                TranscriptRow(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: vm.messages.count) { _ in
                        if let last = vm.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Group {
            if vm.isActive && vm.phase != .completed && vm.phase != .error {
                Button {
                    vm.dismissCall()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                        Text("End session")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(Theme.error)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.error.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(Theme.error.opacity(0.2), lineWidth: 0.5))
                }
            } else if vm.phase == .completed || vm.phase == .error {
                Button {
                    vm.dismissCall()
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Theme.stone)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rMd))
                }
            }
        }
    }
}

// MARK: - Transcript Row

struct TranscriptRow: View {
    let message: CallViewModel.TranscriptMessage

    private var config: (label: String, color: Color, bg: Color) {
        switch message.type {
        case "assistant": return ("AGENT", Theme.accent, Theme.accent.opacity(0.06))
        case "transcript": return ("PHONE", Theme.ink, Color.clear)
        case "status": return ("STATUS", Theme.inkLow, Color.clear)
        case "summary": return ("DONE", Theme.success, Theme.success.opacity(0.06))
        case "error": return ("ERROR", Theme.error, Theme.error.opacity(0.06))
        case "system": return ("SYS", Theme.inkLow, Color.clear)
        default: return ("SYS", Theme.inkLow, Color.clear)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message.time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.inkLow)
                .frame(width: 54, alignment: .leading)

            Text(config.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(config.color)
                .tracking(0.5)
                .frame(width: 44, alignment: .leading)

            Text(message.text)
                .font(.system(size: 13.5))
                .foregroundColor(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(config.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var vm: CallViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("ALL CALLS\(vm.history.isEmpty ? "" : " \u{00B7} \(vm.history.count)")")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.inkMid)
                    .tracking(1.2)

                Text("History")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .padding(.top, 6)
                    .padding(.bottom, 22)

                if vm.history.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(vm.history.enumerated()), id: \.element.id) { index, entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.phone)
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundColor(Theme.ink)
                                    Text(entry.reason ?? "No reason given")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Theme.inkLow)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(entry.status == "completed" ? "Completed" : entry.status)
                                        .font(.system(size: 12))
                                        .foregroundColor(entry.status == "completed" ? Theme.success : Theme.inkMid)
                                    if let ts = entry.endedAt ?? entry.startedAt {
                                        Text(formatTimestamp(ts))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(Theme.inkLow)
                                    }
                                }
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 4)

                            if index < vm.history.count - 1 {
                                Rectangle().fill(Theme.rule).frame(height: 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rLg))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
                }
            }
            .padding(24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 36))
                .foregroundColor(Theme.inkLow)
            Text("No calls yet")
                .font(.system(size: 15))
                .foregroundColor(Theme.inkLow)
            Text("Place your first call to see history here.")
                .font(.system(size: 13))
                .foregroundColor(Theme.inkLow)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func formatTimestamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 2)
                    .scaleEffect(animating ? 2.5 : 1)
                    .opacity(animating ? 0 : 0.6)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
    }
}

#Preview {
    ContentView()
}
