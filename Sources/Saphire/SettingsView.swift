import SwiftUI

/// Unified preferences: generation parameters, tools, and persistent memory.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GenerationSettings()
                    .tabItem { Label("Generación", systemImage: "slider.horizontal.3") }
                ToolsSettings()
                    .tabItem { Label("Herramientas", systemImage: "wrench.and.screwdriver") }
                SchedulesSettings()
                    .tabItem { Label("Tareas", systemImage: "clock.arrow.circlepath") }
                MemorySection()
                    .tabItem { Label("Memoria", systemImage: "brain.head.profile") }
            }
            .padding(.top, 8)

            Divider()
            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }
}

// MARK: - Reusable help popover

/// Small "?" button that reveals an explanation on click, replacing the long
/// gray caption walls that used to sit under every control.
private struct HelpButton: View {
    let text: String
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(width: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Section header with a leading SF Symbol for a more polished, consistent look.
private func sectionHeader(_ title: String, _ symbol: String) -> some View {
    Label(title, systemImage: symbol)
        .font(.headline)
        .foregroundStyle(.secondary)
}

// MARK: - Generation parameters

private struct GenerationSettings: View {
    @EnvironmentObject var state: AppState
    private let ctxPresets = [4096, 8192, 16384, 32768, 65536, 131072]

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Contexto (num_ctx)", selection: $state.numCtx) {
                        ForEach(ctxPresets, id: \.self) { Text(ctxLabel($0)).tag($0) }
                        if !ctxPresets.contains(state.numCtx) {
                            Text(ctxLabel(state.numCtx)).tag(state.numCtx)
                        }
                    }
                    HelpButton(text: "Ventana de contexto en tokens. Más alto = recuerda más "
                               + "de la conversación, pero usa más RAM. gemma4 admite hasta 256K.")
                }
            } header: {
                sectionHeader("Contexto", "rectangle.expand.vertical")
            }

            Section {
                sliderRow("Temperatura", value: $state.temperature, range: 0...2, step: 0.05,
                          help: "Aleatoriedad de la respuesta. Bajo (0.2) = preciso y "
                                + "repetible; alto (1+) = creativo y variado.")
                sliderRow("top_p", value: $state.topP, range: 0...1, step: 0.01,
                          help: "Muestreo por núcleo: solo considera los tokens más "
                                + "probables que sumen esta probabilidad. 0.9 es típico.")
                intSliderRow("top_k", value: $state.topK, range: 0...200,
                             help: "Limita la elección a los k tokens más probables. "
                                   + "0 = sin límite. Valores bajos = más enfocado.")
                sliderRow("repeat_penalty", value: $state.repeatPenalty, range: 0.8...1.5, step: 0.01,
                          help: "Penaliza repetir lo ya dicho. >1 reduce repeticiones; "
                                + "demasiado alto degrada la coherencia.")
            } header: {
                sectionHeader("Muestreo", "dial.medium")
            }

            Section {
                HStack {
                    Text("Máx. tokens de respuesta")
                    Spacer()
                    HelpButton(text: "Longitud máxima de la respuesta en tokens. "
                               + "0 = sin límite (∞).")
                    TextField("0 = ∞", value: $state.numPredict, format: .number)
                        .frame(width: 80).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("keep_alive")
                    Spacer()
                    HelpButton(text: "Cuánto se mantiene el modelo cargado tras responder "
                               + "(p.ej. 30m, 1h, 0 para descargar ya). Mantenerlo caliente "
                               + "acelera la siguiente invocación del overlay.")
                    TextField("30m", text: $state.keepAlive)
                        .frame(width: 90).multilineTextAlignment(.trailing)
                }
            } header: {
                sectionHeader("Respuesta", "text.bubble")
            }

            Section {
                DisclosureGroup {
                    providerBlock(
                        title: "OpenRouter",
                        help: "Cada id (p.ej. anthropic/claude-3.7-sonnet, openai/gpt-4o, "
                            + "google/gemini-2.0-flash) aparece en el selector de modelos. Al "
                            + "elegir uno, Saphire usa la API de OpenRouter en vez de Ollama "
                            + "local. Consigue tu key en openrouter.ai/keys.")
                    {
                        SecureField("API key de OpenRouter (sk-or-…)", text: $state.openRouterKey)
                            .textFieldStyle(.roundedBorder)
                        modelsEditor("Modelos remotos (uno por línea)",
                                     text: $state.openRouterModelsRaw, height: 72)
                            .onChange(of: state.openRouterModelsRaw) {
                                Task { await state.loadModels() }
                            }
                    }

                    Divider().padding(.vertical, 4)

                    providerBlock(
                        title: "Compatible con OpenAI",
                        help: "Cualquier servidor compatible con la API de OpenAI: LM Studio "
                            + "(http://localhost:1234/v1), OpenAI (https://api.openai.com/v1), "
                            + "vLLM, etc. Los modelos listados aparecen en el selector y usan "
                            + "este endpoint en vez de Ollama.")
                    {
                        TextField("http://localhost:1234/v1", text: $state.openAICompatBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: state.openAICompatBaseURL) {
                                Task { await state.loadModels() }
                            }
                        SecureField("API key (opcional, vacío en local)", text: $state.openAICompatKey)
                            .textFieldStyle(.roundedBorder)
                        modelsEditor("Modelos (uno por línea)",
                                     text: $state.openAICompatModelsRaw, height: 60)
                            .onChange(of: state.openAICompatModelsRaw) {
                                Task { await state.loadModels() }
                            }
                    }
                } label: {
                    Label("Proveedores remotos", systemImage: "cloud")
                }
            }

            Section {
                Button("Restaurar valores recomendados") { state.restoreGenerationDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private func ctxLabel(_ n: Int) -> String {
        n % 1024 == 0 ? "\(n / 1024)K" : "\(n)"
    }

    /// One remote-provider sub-block: a titled header with a "?" popover above
    /// its fields. Used for both OpenRouter and the OpenAI-compatible endpoint.
    @ViewBuilder
    private func providerBlock<Content: View>(
        title: String, help: String,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.medium)
                HelpButton(text: help)
                Spacer()
            }
            content()
        }
    }

    @ViewBuilder
    private func modelsEditor(_ caption: String, text: Binding<String>,
                              height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(height: height)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25)))
        }
    }

    @ViewBuilder
    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                HelpButton(text: help)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    @ViewBuilder
    private func intSliderRow(_ title: String, value: Binding<Int>,
                             range: ClosedRange<Int>, help: String) -> some View {
        let dbl = Binding(get: { Double(value.wrappedValue) },
                          set: { value.wrappedValue = Int($0.rounded()) })
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                HelpButton(text: help)
                Spacer()
                Text("\(value.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: dbl, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
        }
    }
}

// MARK: - Tools

private struct ToolsSettings: View {
    @EnvironmentObject var state: AppState

    /// A toggle row with an optional "?" popover for permission-sensitive tools.
    @ViewBuilder
    private func toolToggle(_ title: String, isOn: Binding<Bool>,
                            help: String? = nil) -> some View {
        if let help {
            HStack {
                HelpButton(text: help)
                Toggle(title, isOn: isOn)
            }
        } else {
            Toggle(title, isOn: isOn)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Permitir herramientas", isOn: $state.toolsEnabled)
                Text("Si lo desactivas, el modelo responde sin usar ninguna herramienta.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                toolToggle("Búsqueda web", isOn: $state.webSearchEnabled)
                toolToggle("Investigación profunda (deep_search)", isOn: $state.deepSearchEnabled)
                toolToggle("Leer URL (fetch_url)", isOn: $state.fetchUrlEnabled)
                toolToggle("Fecha y hora (get_datetime)", isOn: $state.datetimeEnabled)
                toolToggle("Calculadora (calculate)", isOn: $state.calculateEnabled)
                toolToggle("Leer correo (read_email)", isOn: $state.readEmailEnabled,
                           help: "Accede a Mail en solo lectura, sin abrir ventana. La "
                                 + "primera vez macOS pedirá permiso para controlar Mail.")
                toolToggle("Leer WhatsApp (read_whatsapp)", isOn: $state.whatsappEnabled,
                           help: "Lee conversaciones de WhatsApp en solo lectura. Puede "
                                 + "requerir permisos de accesibilidad la primera vez.")
                toolToggle("Ejecutar comandos (run_command)", isOn: $state.runCommandEnabled,
                           help: "Deja al modelo usar la terminal del Mac. El comando y su "
                                 + "salida se muestran en el chat; borrar, crear, instalar o "
                                 + "sobrescribir algo requiere tu aprobación.")
                toolToggle("Recordatorios (manage_reminders)", isOn: $state.remindersEnabled,
                           help: "Listar, crear, completar y borrar recordatorios en la app "
                                 + "Recordatorios. La primera vez macOS pedirá permiso.")
                toolToggle("Calendario (manage_calendar)", isOn: $state.calendarEnabled,
                           help: "Listar y gestionar eventos del Calendario. La primera vez "
                                 + "macOS pedirá permiso.")
                toolToggle("Tareas programadas (manage_scheduled_tasks)", isOn: $state.scheduleTaskToolEnabled)
                toolToggle("Buscar archivos (search_files)", isOn: $state.searchFilesEnabled,
                           help: "Localiza archivos por nombre o contenido con el índice "
                                 + "de Spotlight. Solo lectura.")
                toolToggle("Vigilantes (manage_watchers)", isOn: $state.watchdogEnabled,
                           help: "Avisos automáticos cuando llega un correo o WhatsApp "
                                 + "concreto. La comprobación periódica es local y no usa "
                                 + "el modelo. Se gestionan en la pestaña Tareas.")
                toolToggle("Guardar en memoria (remember_fact)", isOn: $state.rememberFactEnabled,
                           help: "Guarda datos persistentes entre conversaciones. Pedirá tu "
                                 + "confirmación antes de guardar nada.")
            } header: {
                sectionHeader("Herramientas disponibles", "wrench.and.screwdriver")
            }
            .disabled(!state.toolsEnabled)

            if state.webSearchEnabled && state.toolsEnabled {
                Section {
                    Picker("Proveedor", selection: $state.searchBackendKind) {
                        Text("Tavily").tag(SearchBackendKind.tavily.rawValue)
                        Text("SearXNG (self-host)").tag(SearchBackendKind.searxng.rawValue)
                    }
                    .pickerStyle(.segmented)

                    if state.searchBackendKind == SearchBackendKind.tavily.rawValue {
                        SecureField("API key de Tavily (tvly-…)", text: $state.tavilyKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Gratis hasta 1.000 búsquedas/mes en tavily.com")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        TextField("http://localhost:8080", text: $state.searxngURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Requiere `format: json` habilitado en settings.yml")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if !state.webSearchReady {
                        Label("Falta configurar el proveedor seleccionado.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    sectionHeader("Proveedor de búsqueda", "magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Scheduled tasks

/// Weekday order shown in the UI (Monday-first) mapped to Calendar weekday
/// numbers (1=domingo … 7=sábado).
private let weekdayChips: [(label: String, weekday: Int)] = [
    ("L", 2), ("M", 3), ("X", 4), ("J", 5), ("V", 6), ("S", 7), ("D", 1)
]

private struct SchedulesSettings: View {
    @EnvironmentObject var state: AppState

    // New-task draft.
    @State private var title = ""
    @State private var prompt = ""
    @State private var time = Calendar.current.date(
        bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = []   // empty = todos los días
    @State private var model = ""                // empty = aún sin inicializar

    var body: some View {
        Form {
            Section {
                Toggle("Esperar a que el equipo esté inactivo", isOn: $state.taskRequireIdle)
                if state.taskRequireIdle {
                    Stepper(value: $state.taskIdleMinutes, in: 1...180) {
                        HStack {
                            Text("Inactivo durante")
                            Spacer()
                            Text("\(state.taskIdleMinutes) min")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Toggle("No ejecutar mientras se reproduce vídeo", isOn: $state.taskPauseDuringVideo)
            } header: {
                HStack {
                    sectionHeader("Condiciones de ejecución", "moon.zzz")
                    HelpButton(text: "Si llega la hora pero sigues usando el equipo, la tarea "
                               + "espera. Se ejecutará en cuanto lleve el tiempo indicado sin "
                               + "recibir entradas (ratón/teclado) y no haya un vídeo o "
                               + "presentación manteniendo la pantalla encendida. La app debe "
                               + "seguir abierta.")
                }
            }

            Section {
                Toggle("Vigilancia activa", isOn: $state.watchdogEnabled)
                if state.watchdogEnabled {
                    Stepper(value: $state.watchdogMinutes, in: 1...60) {
                        HStack {
                            Text("Comprobar cada")
                            Spacer()
                            Text("\(state.watchdogMinutes) min")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if state.watchers.isEmpty {
                        Text("Sin vigilantes. Pídeselo a Saphire en el chat: "
                             + "«avísame cuando reciba un correo de Juan».")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(state.watchers) { w in
                            WatcherRow(watcher: w)
                        }
                    }
                }
            } header: {
                HStack {
                    sectionHeader("Vigilantes (watchdog)", "eye")
                    HelpButton(text: "Comprobaciones ligeras que revisan el correo o "
                               + "WhatsApp cada pocos minutos y te avisan cuando llega "
                               + "algo que coincida. No cargan el modelo: son una "
                               + "consulta local instantánea. La app debe seguir abierta.")
                }
            }

            if state.scheduledTasks.isEmpty {
                Section {
                    Text("No tienes tareas programadas. Crea una abajo: Saphire la "
                         + "ejecutará por su cuenta a la hora indicada (con la app abierta).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Programadas") {
                    ForEach(state.scheduledTasks) { task in
                        TaskRow(task: task)
                    }
                }
            }

            if !state.taskRuns.isEmpty {
                Section {
                    ForEach(state.taskRuns) { run in
                        TaskRunRow(run: run)
                    }
                } header: {
                    HStack {
                        Text("Historial de ejecuciones")
                        Spacer()
                        Button("Limpiar") { state.clearTaskRuns() }
                            .buttonStyle(.plain)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Registro de las tareas que Saphire ha ejecutado por su cuenta. "
                         + "No aparecen en la lista de conversaciones. Se conservan 30 días.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Nueva tarea") {
                TextField("Título (p.ej. «Revisar correo»)", text: $title)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instrucción").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .frame(height: 64)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25)))
                }

                DatePicker("Hora", selection: $time, displayedComponents: .hourAndMinute)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Días").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(weekdayChips, id: \.weekday) { chip in
                            let on = weekdays.contains(chip.weekday)
                            Button(chip.label) {
                                if on { weekdays.remove(chip.weekday) }
                                else { weekdays.insert(chip.weekday) }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 26, height: 26)
                            .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .clipShape(Circle())
                        }
                    }
                    Text(weekdays.isEmpty ? "Sin selección = todos los días."
                                          : "Solo los días marcados.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Picker("Modelo", selection: $model) {
                    ForEach(state.models, id: \.self) { Text($0).tag($0) }
                    if !model.isEmpty && !state.models.contains(model) {
                        Text(model).tag(model)
                    }
                }

                Button("Añadir tarea") { add() }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear { if model.isEmpty { model = state.selectedModel } }
    }

    private func add() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        state.addScheduledTask(
            title: title, prompt: prompt,
            hour: comps.hour ?? 0, minute: comps.minute ?? 0,
            weekdays: weekdays, model: model.isEmpty ? state.selectedModel : model)
        title = ""; prompt = ""; weekdays = []
    }
}

/// One watcher in the watchdog list: what it watches, its filters, and the
/// optional smart instruction, with enable/delete controls.
private struct WatcherRow: View {
    @EnvironmentObject var state: AppState
    let watcher: Watcher

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: watcher.source == .email ? "envelope" : "message")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(watcher.title).fontWeight(.medium)
                Text(criteriaLabel)
                    .font(.caption).foregroundStyle(.secondary)
                if !watcher.instruction.isEmpty {
                    Text("Acción: \(watcher.instruction)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { watcher.enabled },
                set: { state.setWatcherEnabled(watcher.id, $0) }))
                .labelsHidden()
            Button {
                state.deleteWatcher(watcher.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private var criteriaLabel: String {
        var parts: [String] = [watcher.source == .email ? "Correo" : "WhatsApp"]
        if !watcher.filter.isEmpty { parts.append("de «\(watcher.filter)»") }
        if !watcher.contains.isEmpty { parts.append("con «\(watcher.contains)»") }
        parts.append(watcher.once ? "aviso único" : "permanente")
        return parts.joined(separator: " · ")
    }
}

private struct TaskRow: View {
    @EnvironmentObject var state: AppState
    let task: ScheduledTask

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).fontWeight(.medium)
                Text("\(task.timeLabel) · \(daysLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(task.prompt)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                if let last = task.lastRun {
                    Text("Última ejecución: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Picker("Modelo", selection: Binding(
                    get: { task.model },
                    set: { var t = task; t.model = $0; state.updateScheduledTask(t) })) {
                    ForEach(state.models, id: \.self) { Text($0).tag($0) }
                    if !state.models.contains(task.model) {
                        Text(task.model).tag(task.model)
                    }
                }
                .labelsHidden()
                .font(.caption2)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { state.setScheduledTaskEnabled(task.id, $0) }))
                .labelsHidden()
            Button {
                state.deleteScheduledTask(task.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private var daysLabel: String {
        if task.weekdays.isEmpty { return "todos los días" }
        return weekdayChips.filter { task.weekdays.contains($0.weekday) }
            .map(\.label).joined(separator: " ")
    }
}

/// One entry in the headless run log: a disclosure row showing the full output
/// of a past autonomous execution. Read-only except for delete.
private struct TaskRunRow: View {
    @EnvironmentObject var state: AppState
    let run: TaskRun
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(run.output)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            HStack(alignment: .top) {
                Image(systemName: run.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.ok ? Color.green : Color.orange)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).fontWeight(.medium)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.deleteTaskRun(run.id)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
