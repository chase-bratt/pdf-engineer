import Assistant
import Foundation

/// One entry in the assistant transcript.
///
/// A class rather than a struct so the confirmation closures can be attached
/// after construction, when the controller knows how to run them.
@MainActor
final class ChatMessage: Identifiable, ObservableObject {

    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String

    /// Set when the message is asking the user to approve an action.
    let pendingIntent: Intent?

    var onConfirm: ((Intent) -> Void)?
    var onCancel: (() -> Void)?

    /// Set once the user has answered, so a pending action can run at most once.
    @Published private(set) var isResolved = false

    /// Runs the confirmation exactly once, however many times the button is pressed.
    func confirm() {
        guard !isResolved, let pendingIntent else { return }
        isResolved = true
        let handler = onConfirm
        onConfirm = nil
        onCancel = nil
        handler?(pendingIntent)
    }

    func cancel() {
        guard !isResolved else { return }
        isResolved = true
        let handler = onCancel
        onConfirm = nil
        onCancel = nil
        handler?()
    }

    init(role: Role, text: String, pendingIntent: Intent? = nil) {
        self.role = role
        self.text = text
        self.pendingIntent = pendingIntent
    }
}
