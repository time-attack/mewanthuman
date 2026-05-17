import Foundation
import SwiftUI
import UserNotifications

@MainActor
class CallViewModel: ObservableObject {
    @Published var isActive = false
    @Published var sessionId: String?
    @Published var messages: [TranscriptMessage] = []
    @Published var phase: CallPhase = .idle
    @Published var elapsed: String = "0:00"
    @Published var callStatus: String = ""
    @Published var isBusy = false
    @Published var history: [HistoryEntry] = []
    @Published var notificationStatus: String = "unknown"

    private var timer: Timer?
    private var startedAt: Date?
    private var pollTask: Task<Void, Never>?
    private var notifiedCallStarted = false
    private var notifiedCallPlaced = false
    private var notifiedHumanReached = false

    let phone = "(818) 448-9009"

    enum CallPhase: String, CaseIterable {
        case idle, spawn, call, nav, hold, human, xfer, completed, error

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .spawn: return "Spawning agent"
            case .call: return "Placing call"
            case .nav: return "Navigating IVR"
            case .hold: return "On hold"
            case .human: return "Human reached"
            case .xfer: return "Transferred to you"
            case .completed: return "Completed"
            case .error: return "Error"
            }
        }

        var icon: String {
            switch self {
            case .idle: return "circle"
            case .spawn: return "bolt.fill"
            case .call: return "phone.arrow.up.right"
            case .nav: return "list.bullet"
            case .hold: return "music.note"
            case .human: return "person.fill"
            case .xfer: return "arrow.right.arrow.left"
            case .completed: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }

    struct TranscriptMessage: Identifiable {
        let id = UUID()
        let type: String
        let text: String
        let time: String
        let role: String?
    }

    // MARK: - Lifecycle

    func loadInitialData() async {
        // Check notification permission status
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? "authorized" : "denied"
        print("[VM] Notification status: \(notificationStatus)")

        // If not authorized, request again
        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            notificationStatus = granted ? "authorized" : "denied"
            print("[VM] Re-requested permission: \(granted)")
        }

        do {
            history = try await APIService.shared.getHistory()
            let active = try await APIService.shared.getActiveCalls()
            if let first = active.first {
                isActive = true
                sessionId = first.sessionId
                callStatus = first.status
                phase = inferPhaseFromStatus(first.status)
                startedAt = Date(timeIntervalSince1970: Double(first.startedAt ?? 0) / 1000)
                startTimer()
                startPolling(sessionId: first.sessionId)
            }
        } catch {
            print("[init] Error: \(error)")
        }
    }

    // MARK: - Start Call

    func startCall(reason: String) async {
        isBusy = true
        isActive = true
        messages = []
        phase = .spawn
        elapsed = "0:00"
        callStatus = "Spawning agent"
        startedAt = Date()
        notifiedCallStarted = false
        notifiedCallPlaced = false
        notifiedHumanReached = false
        startTimer()

        addMessage(type: "system", text: "Spawning agent to call \(phone)...")

        do {
            let response = try await APIService.shared.startCall(reason: reason)
            sessionId = response.sessionId
            addMessage(type: "system", text: "Agent spawned — session \(response.sessionId.prefix(8))")

            // Notify: call confirmed started
            if !notifiedCallStarted {
                notifiedCallStarted = true
                fireNotification(title: "Call Started", body: phone)
            }

            startPolling(sessionId: response.sessionId)
        } catch {
            addMessage(type: "error", text: "Failed: \(error.localizedDescription)")
            phase = .error
            isBusy = false
        }
    }

    // MARK: - Polling via async Task (no Timer issues)

    private func startPolling(sessionId: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollSession(sessionId: sessionId)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }
    }

    private func pollSession(sessionId: String) async {
        do {
            let session = try await APIService.shared.getSession(id: sessionId)

            if let msgs = session.messages {
                let newMessages = msgs.dropFirst(messages.count)
                for msg in newMessages {
                    let text = msg.text ?? ""
                    addMessage(type: msg.type, text: text, role: msg.role)
                    inferPhase(from: text)
                }
            }

            if let status = session.status {
                callStatus = status

                // Notify when server confirms the call is actively being placed
                if (status == "calling" || status == "in_progress") && !notifiedCallPlaced {
                    notifiedCallPlaced = true
                    fireNotification(title: "Calling", body: phone)
                }

                if status == "completed" || status == "error" {
                    endCall(status: status)
                }
            }
        } catch {
            // Silent retry
            print("[poll] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - End Call

    func endCall(status: String = "completed") {
        pollTask?.cancel()
        pollTask = nil
        timer?.invalidate()
        timer = nil
        isBusy = false
        phase = status == "completed" ? .completed : .error
        callStatus = status == "completed" ? "Done" : "Failed"

        Task {
            history = (try? await APIService.shared.getHistory()) ?? history
        }
    }

    func dismissCall() {
        endCall()
        isActive = false
        messages = []
        phase = .idle
        sessionId = nil
    }

    // MARK: - Helpers

    private func addMessage(type: String, text: String, role: String? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date())
        messages.append(TranscriptMessage(type: type, text: text, time: time, role: role))

        // Notification: human detected from server-side status message
        if type == "status" && text.contains("human detected") && !notifiedHumanReached {
            notifiedHumanReached = true
            fireNotification(title: "Human Reached", body: phone)
        }

        // Notification: call placed (server sends "Call placed!" message)
        if type == "assistant" && text.lowercased().contains("call placed") && !notifiedCallPlaced {
            notifiedCallPlaced = true
            fireNotification(title: "Calling", body: phone)
        }
    }

    private func inferPhase(from text: String) {
        let lc = text.lowercased()
        if lc.contains("transfer") && (lc.contains("success") || lc.contains("completed")) {
            phase = .xfer
        } else if lc.contains("my name is") || lc.contains("how can i help") || lc.contains("how can i assist") || lc.contains("how may i assist") || lc.contains("you're speaking with") {
            phase = .human
            if !notifiedHumanReached {
                notifiedHumanReached = true
                fireNotification(title: "Human Reached", body: phone)
            }
        } else if lc.contains("hold") || lc.contains("waiting") || lc.contains("queue") {
            phase = .hold
        } else if lc.contains("navigat") || lc.contains("ivr") || lc.contains("menu") || lc.contains("press") {
            phase = .nav
        } else if lc.contains("call placed") || lc.contains("calling") {
            phase = .call
            if !notifiedCallPlaced {
                notifiedCallPlaced = true
                fireNotification(title: "Calling Now", body: "Agent is dialing \(phone) — we'll notify you when a human picks up.")
            }
        }
    }

    private func inferPhaseFromStatus(_ status: String) -> CallPhase {
        switch status {
        case "starting": return .spawn
        case "calling": return .call
        case "in_progress", "running": return .nav
        case "completed": return .completed
        case "error": return .error
        default: return .spawn
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let started = self.startedAt else { return }
                let seconds = Int(Date().timeIntervalSince(started))
                self.elapsed = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
            }
        }
    }

    // MARK: - Notification (with permission check)

    private func fireNotification(title: String, body: String) {
        print("[NOTIFY] Firing: \(title) — \(body)")

        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            print("[NOTIFY] Auth status: \(settings.authorizationStatus.rawValue)")

            if settings.authorizationStatus == .notDetermined {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                print("[NOTIFY] Requested permission: \(granted)")
                if !granted {
                    print("[NOTIFY] NOT AUTHORIZED — notification will not show")
                    return
                }
            } else if settings.authorizationStatus != .authorized {
                print("[NOTIFY] NOT AUTHORIZED — notification will not show")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = "CALL_UPDATE"

            let request = UNNotificationRequest(
                identifier: "mewanthuman-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
                print("[NOTIFY] Successfully scheduled: \(title)")
            } catch {
                print("[NOTIFY] FAILED to schedule: \(error.localizedDescription)")
            }
        }
    }
}
