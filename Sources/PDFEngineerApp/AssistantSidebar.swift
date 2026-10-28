import Assistant
import SwiftUI

/// Chat sidebar driven by the on-device model.
///
/// Deliberately not a general chatbot. The model parses a request into an
/// ``Intent``; our tested code executes it. So the transcript is a log of
/// actions taken, not a conversation — which is what makes a 1.7B model
/// genuinely useful here instead of merely plausible.
struct AssistantSidebar: View {

    @ObservedObject var controller: AppController
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if controller.chatMessages.isEmpty {
                            suggestions
                        }
                        ForEach(controller.chatMessages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                        if controller.assistantIsThinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .id("thinking")
                        }
                    }
                    .padding(10)
                }
                // Keep the newest message in view as the transcript grows.
                .onChange(of: controller.chatMessages.count) {
                    if let last = controller.chatMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            inputRow
        }
        .frame(minWidth: 260, idealWidth: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Assistant")
                .font(.headline)
            Spacer()
            // Surfaces model state without a separate settings screen: the user
            // needs to know whether the thing is loaded.
            Text(controller.assistantStatusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Shown on an empty transcript, so the scope is obvious without docs.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs entirely on this Mac. No network.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach([
                "find every mention of invoice",
                "how many times does Acme appear",
                "replace every Acme with Globex",
                "rotate page 2 clockwise",
                "make this searchable",
            ], id: \.self) { example in
                Button {
                    controller.chatInput = example
                    controller.sendChatMessage()
                } label: {
                    Text(example)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.link)
            }
        }
        .padding(.bottom, 6)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask about this document…", text: $controller.chatInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { controller.sendChatMessage() }
                .disabled(!controller.hasDocument)

            Button {
                controller.sendChatMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(
                controller.chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                || controller.assistantIsThinking
                || !controller.hasDocument
            )
        }
        .padding(10)
    }
}

/// One line of the transcript.
private struct ChatBubble: View {
    @ObservedObject var message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.role == .user {
                Text(message.text)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A pending action shows what will happen before it happens —
                // the same consent idea as the MCP layer,
                // applied to a local model.
                if message.pendingIntent != nil, !message.isResolved {
                    HStack(spacing: 8) {
                        Button("Do it") { message.confirm() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { message.cancel() }
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .font(.callout)
    }
}
