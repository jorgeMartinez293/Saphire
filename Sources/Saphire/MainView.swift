import SwiftUI

/// Bundle images loaded once at first use. The views below previously re-read
/// these PNGs from disk on every body evaluation — which during streaming
/// happens ~25×/s (each render-flush mutates the conversations array).
enum AppAssets {
    static let logo: NSImage? = Bundle.main
        .url(forResource: "saphire-logo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    static let searchIcon: NSImage? = Bundle.main
        .url(forResource: "search", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

/// Extended window: conversation sidebar + chat detail with model controls.
struct MainView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var inputFocused: Bool

    /// Collapse the window back into the ⌥Space overlay.
    var onReturnToOverlay: () -> Void = {}

    // Sidebar starts hidden — the window opens focused on the chat.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    // Rename sheet/alert state.
    @State private var renamingID: UUID? = nil
    @State private var renameText: String = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 520)
        .task { await state.loadModels() }
        .sheet(item: $state.activeSheet) { _ in
            SettingsView()
        }
        .memoryConfirmation(state)
        .commandConfirmation(state)
        .alert("Renombrar conversación", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } })) {
            TextField("Título", text: $renameText)
            Button("Guardar") {
                if let id = renamingID { state.renameConversation(id, to: renameText) }
                renamingID = nil
            }
            Button("Cancelar", role: .cancel) { renamingID = nil }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { state.currentID },
            set: { if let id = $0 { state.select(id) } }
        )) {
            ForEach(state.filteredConversations) { c in
                HStack(spacing: 6) {
                    if c.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(c.model)
                            Text("·")
                            Text(c.updatedAt, format: .relative(presentation: .named))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .tag(c.id)
                .contextMenu {
                    Button(c.pinned ? "Desfijar" : "Fijar",
                           systemImage: c.pinned ? "pin.slash" : "pin") {
                        state.togglePin(c.id)
                    }
                    Button("Renombrar", systemImage: "pencil") {
                        renameText = c.title
                        renamingID = c.id
                    }
                    Button("Exportar a Markdown", systemImage: "square.and.arrow.up") {
                        state.exportConversationMarkdown(c.id)
                    }
                    Divider()
                    Button("Eliminar", role: .destructive) { state.deleteConversation(c.id) }
                }
            }
        }
        .searchable(text: $state.searchQuery, placement: .sidebar, prompt: "Buscar conversaciones")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        // Lives next to the system sidebar-toggle in the unified title bar, so
        // both animate together when the sidebar collapses/expands.
        .toolbar {
            ToolbarItem {
                Button { state.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .help("Nueva conversación")
            }
        }
    }

    /// Row above the input: a Detener button while the model is streaming. The
    /// Repetir / Editar actions now live to the left of each question bubble
    /// (see chat.html), so they aren't repeated here.
    @ViewBuilder private var actionStrip: some View {
        if state.isStreaming {
            HStack {
                Spacer()
                Button(role: .destructive) { state.cancelStreaming() } label: {
                    Label("Detener", systemImage: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Cancelar la respuesta en curso")
            }
            .controlSize(.small)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ZStack {
                ChatWebView(messages: state.current.messages,
                            onRegenerate: { state.regenerate(messageID: $0) },
                            onEdit: { state.editQuestion(messageID: $0); inputFocused = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if state.current.messages.isEmpty {
                    EmptyChatView()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.25), value: state.current.messages.isEmpty)

            Divider()

            VStack(spacing: 6) {
                if let err = state.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let activity = state.toolActivity {
                    HStack(spacing: 6) {
                        if let icon = AppAssets.searchIcon {
                            PulsingView {
                                Image(nsImage: icon)
                                    .renderingMode(.template)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(.white)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(activity).font(.caption).foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !state.pendingAttachments.isEmpty {
                    AttachmentStrip()
                }
                if !state.pendingDocuments.isEmpty {
                    DocumentStrip()
                }

                actionStrip

                // Same layout as the overlay: reasoning toggle on the left, the
                // input in the middle, and a button to collapse back into the
                // overlay on the right (model picker stays up in the title bar).
                HStack(alignment: .center, spacing: 10) {
                    ThinkToggle(size: 16, circle: 32)

                    InputBar(focused: $inputFocused)

                    Button { onReturnToOverlay() } label: {
                        VStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.white.opacity(0.22))
                                    .frame(width: 14, height: 2)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Volver al overlay (⌥Espacio)")
                }
            }
            .padding(12)
            .animation(.snappy(duration: 0.22), value: state.isStreaming)
            .animation(.snappy(duration: 0.22), value: state.toolActivity == nil)
            .animation(.snappy(duration: 0.22), value: state.errorText == nil)
        }
        // Logo lives centered in the unified title bar.
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    logoImage
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    logoImage
                }
            }
        }
    }

    @ViewBuilder
    private var logoImage: some View {
        if let nsImg = AppAssets.logo {
            Image(nsImage: nsImg)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
        }
    }
}

/// Placeholder shown over the (empty) chat webview before the first message:
/// logo, greeting and the ⌥Space hint, fading in with a gentle rise.
private struct EmptyChatView: View {
    @EnvironmentObject var state: AppState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            if let nsImg = AppAssets.logo {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            } else {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }
            Text("¿En qué te ayudo?")
                .font(.title3.weight(.medium))
            Text("Escribe abajo, o pulsa ⌥Espacio desde cualquier app")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
    }
}

/// Slowly pulses its content's opacity — used for the tool-activity icon so
/// "working" reads at a glance without a spinner.
private struct PulsingView<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var dim = false

    var body: some View {
        content
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// Model picker + settings, hosted inside the window's title-bar accessory
/// (added in AppDelegate, trailing). Living in the title bar keeps these
/// clickable above the window's drag region; the logo/title sit in the unified
/// toolbar's principal slot (see MainView.detail).
struct TitlebarControls: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Modelo", selection: $state.selectedModel) {
                    ForEach(state.models, id: \.self) { Text($0).tag($0) }
                    if !state.models.contains(state.selectedModel) {
                        Text(state.selectedModel).tag(state.selectedModel)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(state.selectedModel).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Seleccionar modelo")

            Button { state.activeSheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ajustes")
        }
        .padding(.trailing, 14)
        .padding(.leading, 8)
    }
}

extension View {
    /// Presents the yes/no prompt when the model proposes a `remember_fact`.
    /// Attached to both the main window and the overlay so whichever is visible
    /// can resolve the pending confirmation.
    func memoryConfirmation(_ state: AppState) -> some View {
        alert("¿Recordar este dato?",
              isPresented: Binding(
                get: { state.pendingMemoryConfirmation != nil },
                set: { if !$0 { state.resolveMemoryConfirmation(false) } }),
              presenting: state.pendingMemoryConfirmation) { _ in
            Button("Guardar") { state.resolveMemoryConfirmation(true) }
            Button("No", role: .cancel) { state.resolveMemoryConfirmation(false) }
        } message: { pending in
            Text(pending.fact)
        }
    }

    /// Presents the approval prompt when the model proposes a mutating
    /// `run_command` (delete / create / install / overwrite). Attached to both
    /// the main window and the overlay.
    func commandConfirmation(_ state: AppState) -> some View {
        alert("¿Ejecutar este comando en tu terminal?",
              isPresented: Binding(
                get: { state.pendingCommandConfirmation != nil },
                set: { if !$0 { state.resolveCommandConfirmation(false) } }),
              presenting: state.pendingCommandConfirmation) { _ in
            Button("Ejecutar", role: .destructive) { state.resolveCommandConfirmation(true) }
            Button("Cancelar", role: .cancel) { state.resolveCommandConfirmation(false) }
        } message: { pending in
            let command = truncatedForAlert(pending.command)
            Text(pending.reason.isEmpty
                 ? command
                 : "\(command)\n\n\(pending.reason)")
        }
    }
}

/// Caps overly long command strings so the confirmation alert never grows
/// past the screen and hides its buttons. Keeps head and tail (the tail is
/// often where the dangerous part lives) and marks the cut with an ellipsis.
private func truncatedForAlert(_ command: String, limit: Int = 400) -> String {
    guard command.count > limit else { return command }
    let keep = limit - 1
    let head = command.prefix(keep * 2 / 3)
    let tail = command.suffix(keep - head.count)
    return "\(head)…\(tail)"
}
