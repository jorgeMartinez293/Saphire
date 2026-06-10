import SwiftUI
import AppKit

extension ShapeStyle where Self == LinearGradient {
    /// Brand gradient mirrored from chat.html's `--user-bg`, so the overlay's
    /// send button and active input accent match the message bubbles, icon, etc.
    static var saphire: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.478, green: 0.443, blue: 0.761),
                     Color(red: 0.322, green: 0.522, blue: 0.800),
                     Color(red: 0.204, green: 0.600, blue: 0.867)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Drag handle strip — lets the user reposition the overlay by dragging, and
/// open the full window on double-click.
private struct DragHandleView: NSViewRepresentable {
    var onDoubleClick: () -> Void
    func makeNSView(context: Context) -> DragNSView {
        let v = DragNSView()
        v.onDoubleClick = onDoubleClick
        return v
    }
    func updateNSView(_ v: DragNSView, context: Context) {
        v.onDoubleClick = onDoubleClick
    }

    final class DragNSView: NSView {
        var onDoubleClick: () -> Void = {}
        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// Compact overlay shown by ⌥Space. Starts as a single input row and
/// expands downward once a conversation is underway.
struct OverlayView: View {
    @EnvironmentObject var state: AppState
    var onSubmitExpand: (CGFloat) -> Void
    var onOpenWindow: () -> Void
    @FocusState private var inputFocused: Bool

    private var hasMessages: Bool {
        state.current.messages.contains { $0.role == .user }
    }

    private var height: CGFloat {
        if state.showingInbox {
            // Header + footer nav + one card at a time, scaled to the current
            // item's option count, clamped to the overlay's max height.
            let opts = state.inboxItems.indices.contains(state.inboxIndex)
                ? state.inboxItems[state.inboxIndex].options.count : 0
            return min(620, 200 + CGFloat(opts) * 46)
        }
        var h: CGFloat = 60
        if !state.pendingAttachments.isEmpty { h += 64 }
        if state.errorText != nil { h += 24 }
        if hasMessages { h += 360 }
        return h
    }

    var body: some View {
        Group {
            if state.showingInbox {
                InboxView()
            } else {
                chatBody
            }
        }
        .frame(width: 560, height: height)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        // Matches the panel's animated frame resize (AppDelegate.resizeOverlay)
        // so content and window grow together.
        .animation(.easeOut(duration: 0.22), value: height)
        .onAppear { inputFocused = true; onSubmitExpand(height) }
        .onChange(of: height) { _, h in onSubmitExpand(h) }
        .onKeyPress(.init("n"), phases: .down) { press in
            guard press.modifiers == .option else { return .ignored }
            state.newConversation()
            return .handled
        }
        .memoryConfirmation(state)
        .commandConfirmation(state)
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            if hasMessages {
                ChatWebView(messages: state.current.messages, compact: true,
                            onRegenerate: { state.regenerate(messageID: $0) },
                            onEdit: { state.editQuestion(messageID: $0); inputFocused = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.4)
            }

            if let err = state.errorText {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 4)
                    .transition(.opacity)
            }

            if !state.pendingAttachments.isEmpty {
                AttachmentStrip().padding(.horizontal, 8).padding(.top, 6)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                ThinkToggle(size: 14, circle: 28)
                    .padding(.leading, 8)

                InputBar(showExpand: true, onOpenWindow: onOpenWindow, focused: $inputFocused)
                    .padding(8)

                DragHandleView(onDoubleClick: onOpenWindow)
                    .frame(width: 28, height: 44)
                    .help("Arrastra para mover · doble clic para abrir ventana")
                    .overlay(
                        VStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.white.opacity(0.22))
                                    .frame(width: 14, height: 2)
                            }
                        }
                    )
                    .padding(.trailing, 4)
            }
        }
    }
}

/// Overlay shown when Saphire has queued things for the user (from autonomous
/// runs): questions to answer and informational notices, paged one at a time so
/// the user steps through everything in one place. Each option runs its
/// deterministic action immediately — no model.
struct InboxView: View {
    @EnvironmentObject var state: AppState

    /// The item currently shown, guarding against a stale index.
    private var item: InboxItem? {
        state.inboxItems.indices.contains(state.inboxIndex)
            ? state.inboxItems[state.inboxIndex] : state.inboxItems.first
    }

    private var headerTitle: String {
        switch item?.kind {
        case .notice: return "Saphire te avisa"
        default:      return "Saphire te pregunta"
        }
    }
    private var headerIcon: String {
        item?.kind == .notice ? "bell.badge.fill" : "questionmark.bubble.fill"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: headerIcon).foregroundStyle(Color.accentColor)
                Text(headerTitle).font(.headline)
                Spacer()
                if state.inboxItems.count > 1 {
                    Text("\(state.inboxIndex + 1) / \(state.inboxItems.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button { state.showingInbox = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cerrar")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().opacity(0.4)

            if let item {
                ScrollView {
                    InboxCard(item: item).padding(12)
                        .id(item.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .animation(.snappy(duration: 0.25), value: state.inboxIndex)
                navBar
            } else {
                Spacer()
                Text("No hay nada pendiente.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// Prev / next paging across the queued items. Hidden when only one remains.
    @ViewBuilder private var navBar: some View {
        if state.inboxItems.count > 1 {
            Divider().opacity(0.4)
            HStack {
                Button { step(-1) } label: {
                    Label("Anterior", systemImage: "chevron.left")
                }
                .disabled(state.inboxIndex == 0)
                Spacer()
                Button { step(1) } label: {
                    Label("Siguiente", systemImage: "chevron.right")
                }
                .disabled(state.inboxIndex >= state.inboxItems.count - 1)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func step(_ delta: Int) {
        let next = state.inboxIndex + delta
        if state.inboxItems.indices.contains(next) { state.inboxIndex = next }
    }
}

/// One queued inbox item rendered as a card. Questions show their options (the
/// user must pick or dismiss); notices show the message with any optional
/// one-tap actions plus a "Vale". Resolving routes through `resolveInboxItem`.
private struct InboxCard: View {
    @EnvironmentObject var state: AppState
    let item: InboxItem

    private var isNotice: Bool { item.kind == .notice }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task = item.sourceTaskTitle {
                Text("⏰ \(task)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(item.title).font(.callout).fontWeight(.medium)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(item.options) { opt in
                    InboxOptionButton(label: opt.label, summary: opt.action.summary) {
                        state.resolveInboxItem(item, choosing: opt.id)
                    }
                }
                // Notices just need an acknowledge; questions a way to skip.
                Button(isNotice ? "Vale" : "Descartar") {
                    state.resolveInboxItem(item, choosing: nil)
                }
                .buttonStyle(.plain)
                .font(isNotice && item.options.isEmpty ? .callout : .caption)
                .fontWeight(isNotice && item.options.isEmpty ? .medium : .regular)
                .foregroundStyle(isNotice && item.options.isEmpty ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Inbox option row that brightens on hover so it reads as clickable.
private struct InboxOptionButton: View {
    let label: String
    let summary: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).fontWeight(.medium)
                if !summary.isEmpty {
                    Text(summary).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(hovering ? 0.14 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Discreet chevron that opens a model picker from within the overlay, so the
/// user can switch models without opening the full window or settings.
struct ModelPicker: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            ForEach(state.models, id: \.self) { m in
                Button {
                    state.selectedModel = m
                } label: {
                    if m == state.selectedModel {
                        Label(m, systemImage: "checkmark")
                    } else {
                        Text(m)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cambiar modelo (\(state.selectedModel))")
    }
}

/// Lightbulb toggle for thinking mode, shared by overlay and main window.
/// Soft fill crossfade + slight scale on each flip — no bounce.
struct ThinkToggle: View {
    @EnvironmentObject var state: AppState
    var size: CGFloat = 14
    var circle: CGFloat = 28

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.4)) { state.thinkEnabled.toggle() }
        } label: {
            Image(systemName: state.thinkEnabled ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: size))
                .foregroundStyle(state.thinkEnabled ? AnyShapeStyle(.saphire) : AnyShapeStyle(Color.secondary))
                .scaleEffect(state.thinkEnabled ? 1.06 : 1)
                .frame(width: circle, height: circle)
                .background(
                    Circle().fill(state.thinkEnabled
                        ? AnyShapeStyle(LinearGradient.saphire.opacity(0.18))
                        : AnyShapeStyle(Color.secondary.opacity(0.12)))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Razonamiento (thinking)")
    }
}

/// Shared input row used by overlay and main window.
struct InputBar: View {
    @EnvironmentObject var state: AppState
    var showExpand: Bool = false
    var onOpenWindow: (() -> Void)? = nil
    var focused: FocusState<Bool>.Binding

    private var canSend: Bool {
        !(state.input.trimmingCharacters(in: .whitespaces).isEmpty
          && state.pendingAttachments.isEmpty && state.pendingDocuments.isEmpty)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                state.pickFiles()
            } label: {
                Image(systemName: "paperclip").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help("Adjuntar imagen o documento (txt, md, código, PDF)")

            if state.isListening {
                VoiceSpectrum(levels: state.audioLevels)
                    .transition(.scale.combined(with: .opacity))
            }

            TextField("Pregunta a \(state.selectedModel)…", text: $state.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused(focused)
                .onSubmit { state.send() }
                .onKeyPress(.init("v"), phases: .down) { press in
                    if press.modifiers.contains(.command) { state.addImageFromPasteboard() }
                    return .ignored
                }

            ZStack {
                if state.isStreaming {
                    ProgressView().scaleEffect(0.6)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button { state.send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(canSend ? AnyShapeStyle(.saphire) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                            .scaleEffect(canSend ? 1 : 0.9)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 22, height: 22)
            .animation(.snappy(duration: 0.2), value: state.isStreaming)
            .animation(.snappy(duration: 0.18), value: canSend)

            if showExpand {
                ModelPicker()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.white.opacity(focused.wrappedValue ? 0.08 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    focused.wrappedValue ? AnyShapeStyle(LinearGradient.saphire.opacity(0.55)) : AnyShapeStyle(Color.white.opacity(0.06)),
                    lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: state.isListening)
        .animation(.easeOut(duration: 0.18), value: focused.wrappedValue)
    }
}

/// 5 vertical bars that animate with the live microphone level while the user
/// dictates a question (hold ⌥Space).
struct VoiceSpectrum: View {
    var levels: [CGFloat]   // 5 values, 0…1

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient.saphire)
                    .frame(width: 3, height: 5 + (level(i) * 19))
            }
        }
        .frame(width: 32, height: 24)
        .animation(.easeOut(duration: 0.12), value: levels)
        .help("Escuchando… suelta ⌥Espacio para enviar")
    }

    private func level(_ idx: Int) -> CGFloat {
        idx < levels.count ? levels[idx] : 0
    }
}

struct AttachmentStrip: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(state.pendingAttachments) { att in
                    ZStack(alignment: .topTrailing) {
                        if let img = nsImage(att) {
                            Image(nsImage: img).resizable().scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button {
                            state.pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain).offset(x: 4, y: -4)
                    }
                }
            }
        }
        .frame(height: 52)
    }

    private func nsImage(_ att: Attachment) -> NSImage? {
        guard let data = Data(base64Encoded: att.base64) else { return nil }
        return NSImage(data: data)
    }
}

/// Chips for documents staged for the next message (lightweight RAG context).
struct DocumentStrip: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(state.pendingDocuments) { doc in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 12))
                        Text(doc.name).font(.caption).lineLimit(1)
                        Button { state.removeDocument(doc.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 30)
    }
}
