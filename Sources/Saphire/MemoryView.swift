import SwiftUI

/// Editor for persistent facts the model remembers across every session.
/// Embedded as the "Memoria" tab in `SettingsView`. The model can also propose
/// facts via the `remember_fact` tool (which asks the user to confirm).
struct MemorySection: View {
    @EnvironmentObject var state: AppState
    @State private var newFact: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("gemma4 recordará estos datos en todas las conversaciones, ahora y en el futuro.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Algo que gemma4 debe recordar…", text: $newFact, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(add)
                Button("Añadir", action: add)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(newFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if state.memory.isEmpty {
                Text("Sin datos guardados todavía.")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.memory) { fact in
                        MemoryRow(fact: fact)
                    }
                    .onDelete { idx in
                        idx.map { state.memory[$0].id }.forEach(state.deleteMemory)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }

    private func add() {
        state.addMemory(newFact)
        newFact = ""
    }
}

/// Single editable fact; commits on blur or Enter.
private struct MemoryRow: View {
    @EnvironmentObject var state: AppState
    let fact: MemoryFact
    @State private var text: String = ""

    var body: some View {
        HStack {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { state.updateMemory(fact.id, text: text) }
            Button {
                state.deleteMemory(fact.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .onAppear { text = fact.text }
        .onChange(of: fact.text) { _, new in text = new }
    }
}
