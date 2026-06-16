import Foundation

// MARK: - Tool schema (Ollama / OpenAI function-calling format)

/// JSON schema for one callable tool, advertised to a tool-capable model in
/// the `tools` field of /api/chat. Codable + Sendable so it crosses the
/// OllamaClient actor boundary cleanly.
struct ToolSpec: Codable, Sendable {
    let type: String
    let function: Function

    struct Function: Codable, Sendable {
        let name: String
        let description: String
        let parameters: Parameters
    }
    struct Parameters: Codable, Sendable {
        let type: String
        let properties: [String: Property]
        let required: [String]
    }
    struct Property: Codable, Sendable {
        /// JSON Schema type: "string", "number", "integer", "boolean", …
        let type: String
        let description: String
        /// Allowed values (JSON Schema `enum`). Omitted from the payload when nil
        /// (Swift's synthesized encoder uses `encodeIfPresent` for optionals).
        var enumValues: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case type, description
            case enumValues = "enum"
        }
    }

    static func function(name: String, description: String,
                         properties: [String: Property], required: [String]) -> ToolSpec {
        ToolSpec(type: "function",
                 function: .init(name: name, description: description,
                                 parameters: .init(type: "object",
                                                   properties: properties,
                                                   required: required)))
    }
}

/// The web search tool exposed to the model.
let webSearchTool = ToolSpec.function(
    name: "web_search",
    description: "Busca información actual en internet. Úsala cuando necesites "
        + "datos recientes, hechos que no conoces, noticias, precios, o cualquier "
        + "cosa posterior a tu fecha de entrenamiento.",
    properties: [
        "query": .init(type: "string", description: "Términos de búsqueda concisos.")
    ],
    required: ["query"]
)

/// Reads one concrete web page in full. Complements `web_search`, which only
/// returns short snippets.
let fetchUrlTool = ToolSpec.function(
    name: "fetch_url",
    description: "Descarga una página web concreta y devuelve su texto limpio. "
        + "Úsala cuando ya tengas una URL (de una búsqueda o del usuario) y "
        + "necesites leer su contenido completo, no solo un fragmento.",
    properties: [
        "url": .init(type: "string",
                     description: "URL completa, incluyendo http:// o https://.")
    ],
    required: ["url"]
)

/// Autonomous deep-research tool: kicks off a multi-step investigation loop
/// (many searches + page reads, cross-checked) that returns a synthesized,
/// sourced report. Use for complex questions that one `web_search` can't
/// settle — e.g. "where is X cheapest", comparisons, surveys of a topic.
let deepSearchTool = ToolSpec.function(
    name: "deep_search",
    description: "Investiga a fondo un tema complejo de forma autónoma. A diferencia "
        + "de web_search (un solo vistazo), realiza varias búsquedas y lee varias "
        + "páginas, cruza las fuentes y devuelve un informe completo con datos "
        + "concretos, una comparación y las fuentes usadas. Úsala cuando el usuario "
        + "pida un estudio, una comparación a fondo, «dónde encontrar X más barato», "
        + "o cualquier pregunta que no se resuelva con una única búsqueda. Es lenta "
        + "(varios pasos): úsala solo cuando merezca la pena.",
    properties: [
        "goal": .init(type: "string",
                      description: "El objetivo de la investigación, redactado de forma "
                          + "completa y específica, p.ej. «Encontrar dónde comprar más "
                          + "barata la PS5 Slim en España, comparando tiendas y envío»."),
        "max_steps": .init(type: "integer",
                           description: "Número máximo de pasos de investigación (2–12; "
                               + "por defecto 6). Más pasos = más exhaustivo pero más lento.")
    ],
    required: ["goal"]
)

/// Spotlight-backed file search. Read-only and fast (uses the existing index),
/// so it never needs the user's confirmation, unlike a `find` via run_command.
let searchFilesTool = ToolSpec.function(
    name: "search_files",
    description: "Busca archivos en el Mac usando el índice de Spotlight. SOLO "
        + "LECTURA: no abre ni modifica nada. Modo 'name' busca por nombre de "
        + "archivo; modo 'content' busca texto dentro del contenido de los "
        + "archivos. Devuelve las rutas encontradas. Úsala para localizar un "
        + "archivo (luego puedes leerlo con run_command y cat).",
    properties: [
        "query": .init(type: "string", description: "Texto a buscar."),
        "mode": .init(type: "string",
                      description: "Dónde buscar: 'name' (nombre de archivo, por defecto) "
                          + "o 'content' (dentro del contenido).",
                      enumValues: ["name", "content"]),
        "folder": .init(type: "string",
                        description: "Carpeta a la que limitar la búsqueda, p.ej. "
                            + "\"~/Documents\". Vacío = todo el Mac."),
        "limit": .init(type: "integer",
                       description: "Máximo de resultados (1–50; por defecto 20).")
    ],
    required: ["query"]
)

/// Runs `mdfind` directly (no shell, so the query can't inject commands) and
/// returns up to `limit` matching paths.
func searchFiles(query: String, mode: String, folder: String, limit: Int) async -> String {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return "Error: falta el parámetro 'query'." }
    let lim = max(1, min(limit, 50))

    var args: [String] = []
    let dir = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    if !dir.isEmpty {
        args += ["-onlyin", NSString(string: dir).expandingTildeInPath]
    }
    if mode.trimmingCharacters(in: .whitespaces).lowercased() == "content" {
        args.append(q)              // plain query → content + metadata search
    } else {
        args += ["-name", q]        // filename search
    }
    let finalArgs = args

    let out: String = await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = finalArgs
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                cont.resume(returning: "Error: no se pudo ejecutar la búsqueda "
                    + "(\(error.localizedDescription)).")
                return
            }
            let killItem = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killItem)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killItem.cancel()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
    if out.hasPrefix("Error:") { return out }

    let paths = out.split(separator: "\n").map(String.init)
    guard !paths.isEmpty else {
        return "Spotlight no encontró archivos para «\(q)»"
            + (dir.isEmpty ? "." : " en \(dir).")
    }
    var lines = paths.prefix(lim).enumerated().map { "\($0.offset + 1). \($0.element)" }
    if paths.count > lim { lines.append("…y \(paths.count - lim) resultados más.") }
    return "Archivos encontrados para «\(q)» (\(min(paths.count, lim)) de \(paths.count)):\n"
        + lines.joined(separator: "\n")
}

/// Current local date and time — stops the model from guessing "now".
let datetimeTool = ToolSpec.function(
    name: "get_datetime",
    description: "Devuelve la fecha y hora local actuales. Úsala siempre que "
        + "necesites saber el momento presente en vez de estimarlo.",
    properties: [:],
    required: []
)

/// Exact arithmetic, so the model doesn't have to compute in its head.
let calculateTool = ToolSpec.function(
    name: "calculate",
    description: "Evalúa una expresión aritmética y devuelve el resultado exacto. "
        + "Úsala para cualquier cálculo numérico en lugar de calcularlo mentalmente.",
    properties: [
        "expression": .init(type: "string",
                            description: "Expresión aritmética, p.ej. \"12*(7+5)\" o \"3.5/2\".")
    ],
    required: ["expression"]
)

/// Lets the model propose saving a durable fact to persistent memory. The app
/// asks the user to confirm before anything is stored.
let rememberFactTool = ToolSpec.function(
    name: "remember_fact",
    description: "Propón guardar un dato duradero sobre el usuario en la memoria "
        + "persistente para futuras conversaciones. El usuario tendrá que "
        + "confirmarlo. Úsala solo para preferencias o hechos estables, no para "
        + "datos efímeros.",
    properties: [
        "fact": .init(type: "string",
                      description: "El dato a recordar, redactado en una sola frase clara.")
    ],
    required: ["fact"]
)

/// Reads the user's mail from Mail.app via AppleScript. Read-only: it never
/// sends, deletes, or modifies anything. Mail is driven in the background (no
/// window is opened), so the only visible trace is Mail's Dock icon while it
/// runs.
let readEmailTool = ToolSpec.function(
    name: "read_email",
    description: "Lee el correo del usuario desde Mail.app. SOLO LECTURA: nunca "
        + "envía, borra ni modifica correos. Úsala para consultar los correos "
        + "recientes del inbox, los no leídos, o buscar por remitente o asunto. "
        + "Devuelve remitente, asunto, fecha y estado de lectura de cada correo; "
        + "con full_body=true incluye también el cuerpo completo (úsalo solo cuando "
        + "el usuario quiera leer el contenido de un correo concreto).",
    properties: [
        "query": .init(type: "string",
                       description: "Texto a buscar en el remitente o el asunto. "
                           + "Déjalo vacío para ver los correos más recientes del inbox."),
        "unread_only": .init(type: "boolean",
                             description: "Si es true, devuelve solo correos no leídos."),
        "limit": .init(type: "integer",
                       description: "Número máximo de correos a devolver (1–25; por defecto 10)."),
        "full_body": .init(type: "boolean",
                           description: "Si es true, incluye el cuerpo completo de cada correo.")
    ],
    required: []
)

/// Lets the model create, list, and delete Saphire's own recurring scheduled
/// tasks — the autonomous jobs that run at a set time when the Mac is idle.
/// Use this when the user asks Saphire to remember to do something on a
/// recurring basis ("cada día…", "todas las mañanas…", "recuérdame revisar…").
let manageScheduledTasksTool = ToolSpec.function(
    name: "manage_scheduled_tasks",
    description: "Gestiona las tareas programadas de Saphire: trabajos recurrentes "
        + "que la propia Saphire ejecuta sola a una hora fija (cuando el equipo "
        + "lleva un rato inactivo). Úsala cuando el usuario pida que Saphire haga "
        + "algo de forma recurrente o automática, p.ej. «cada día a las 8 revisa mi "
        + "correo y apunta lo urgente». Acciones: 'create' para crear una tarea, "
        + "'list' para ver las existentes, 'delete' para borrar una por su título. "
        + "Para 'create' la 'instruction' debe redactarse como una orden directa a "
        + "Saphire (lo que deberá hacer cuando la tarea se ejecute).",
    properties: [
        "action": .init(type: "string", description: "Acción a realizar.",
                        enumValues: ["create", "list", "delete"]),
        "title": .init(type: "string",
                       description: "Título corto de la tarea. Obligatorio para create y delete."),
        "instruction": .init(type: "string",
                             description: "La orden que Saphire ejecutará cuando llegue la hora "
                                 + "(solo create), p.ej. «Revisa mi correo y añade a Recordatorios "
                                 + "lo que sea urgente»."),
        "time": .init(type: "string",
                      description: "Hora de ejecución en formato 24h \"HH:MM\" (solo create)."),
        "days": .init(type: "string",
                      description: "Días de la semana, separados por comas, usando L,M,X,J,V,S,D "
                          + "(lunes a domingo). Vacío o «diario» = todos los días. Solo create.")
    ],
    required: ["action"]
)

/// Lets the model defer a decision to the user instead of guessing or skipping
/// it. It queues a question with pre-defined answers, each tied to a
/// deterministic action the app runs later on its own — so the user can answer
/// without the model being reloaded. In a headless run the item waits for the
/// user; in an interactive chat it's revealed in the overlay when the turn ends.
let askUserTool = ToolSpec.function(
    name: "ask_user",
    description: "Deja una pregunta preparada en la bandeja del usuario, con respuestas "
        + "predefinidas y la acción que Saphire ejecutará sola al elegir cada una. "
        + "Aparece en el overlay como «Saphire te pregunta». Úsala: (1) en tareas "
        + "autónomas, cuando surge una duda que NO puedes resolver solo (¿guardo este "
        + "dato? ¿creo este recordatorio? ¿cuál de estas opciones?) — encola la pregunta "
        + "y CONTINÚA la tarea; (2) en una conversación, siempre que el usuario te pida "
        + "dejarle una pregunta o usar esta herramienta. Para una duda inmediata en "
        + "mitad de un chat normal, pregunta directamente en texto.",
    properties: [
        "question": .init(type: "string",
                          description: "La pregunta clara y breve para el usuario."),
        "context": .init(type: "string",
                         description: "Opcional: por qué surge la duda (de qué dato o tarea)."),
        "options": .init(type: "array",
                         description: "Lista JSON de 2 a 4 opciones. Cada opción es un objeto "
                             + "{\"label\": texto del botón, \"action\": tipo, \"value\": dato}. "
                             + "Tipos de action: \"save_memory\" (value = el dato a guardar), "
                             + "\"create_reminder\" (value = título del recordatorio, opcional "
                             + "\"due\": \"YYYY-MM-DD HH:MM\"), \"enable_task\"/\"disable_task\"/"
                             + "\"delete_task\" (value = título exacto de la tarea programada), "
                             + "o \"none\" (no hace nada, p.ej. «No, gracias»). Ejemplo: "
                             + "[{\"label\":\"Sí, guárdalo\",\"action\":\"save_memory\",\"value\":"
                             + "\"Prefiere reuniones por la mañana\"},{\"label\":\"No\",\"action\":\"none\"}]")
    ],
    required: ["question", "options"]
)

/// Lets the model leave the user an informational notice — something it wants
/// to tell them that does NOT need an answer (p.ej. «Juan dice que el proyecto
/// ya está terminado», «Hay 3 correos sin leer de tu jefe»). The notice waits
/// in the inbox alongside the questions; in an interactive chat it's revealed
/// in the overlay when the turn ends.
let notifyUserTool = ToolSpec.function(
    name: "notify_user",
    description: "Deja un aviso informativo en la bandeja del usuario: información que "
        + "querría saber pero que NO requiere respuesta (un resumen, una novedad, algo "
        + "que alguien le ha dicho). Aparece en el overlay como «Saphire te avisa», "
        + "junto con las preguntas pendientes. Úsala en tareas autónomas cuando "
        + "descubras algo que contarle, y en una conversación siempre que el usuario te "
        + "pida dejarle un aviso o usar esta herramienta. Úsala para INFORMAR; usa "
        + "`ask_user` solo cuando necesites que DECIDA algo.",
    properties: [
        "message": .init(type: "string",
                         description: "El aviso, claro y breve, redactado para el usuario. "
                             + "P.ej. «Juan te ha dicho que el proyecto ya está terminado»."),
        "context": .init(type: "string",
                         description: "Opcional: detalle o fuente del aviso (de qué correo, "
                             + "chat o tarea sale), mostrado como subtítulo."),
        "options": .init(type: "array",
                         description: "Opcional: 0 a 4 acciones de un toque que el usuario "
                             + "puede ejecutar desde el aviso, mismo formato que en `ask_user` "
                             + "({\"label\", \"action\", \"value\", \"due\"}). Útil p.ej. para "
                             + "ofrecer «Guardar en memoria» o «Crear recordatorio». Si el "
                             + "aviso es solo informativo, omítelas: el usuario solo verá «Vale».")
    ],
    required: ["message"]
)

/// Runs a shell command on the user's Mac. Mutating commands (delete / create /
/// install / overwrite) require the user's confirmation before running; the app
/// enforces this, not the model. The command and its output are always shown in
/// the chat.
let runCommandTool = ToolSpec.function(
    name: "run_command",
    description: "Ejecuta un comando en la terminal del Mac del usuario (shell zsh) "
        + "y devuelve su salida (stdout y stderr). Úsala para inspeccionar el "
        + "sistema, leer y modificar archivos, o ejecutar programas. El comando y "
        + "su salida SIEMPRE se muestran en el chat. IMPORTANTE: cualquier comando "
        + "que borre, cree, instale o sobrescriba algo requiere que el usuario lo "
        + "apruebe antes de ejecutarse; no asumas que se ejecutará. Pasa un único "
        + "comando por llamada.",
    properties: [
        "command": .init(type: "string",
                         description: "El comando completo a ejecutar, p.ej. \"ls -la ~/Desktop\"."),
        "reason": .init(type: "string",
                        description: "Explicación breve de qué hace el comando y por qué, "
                            + "que se mostrará al usuario al pedir permiso.")
    ],
    required: ["command"]
)

/// Creates, lists, completes, and deletes reminders in the macOS Reminders.app
/// via AppleScript. Unlike `read_email`, this one mutates: create/complete/delete
/// change the user's reminders. The action and its result are shown in the chat.
let manageRemindersTool = ToolSpec.function(
    name: "manage_reminders",
    description: "Gestiona los recordatorios del usuario en la app Recordatorios "
        + "(Reminders) del Mac. Puede listar, crear, completar y borrar "
        + "recordatorios. La acción y su resultado se muestran en el chat. Usa "
        + "'list' para ver los recordatorios pendientes, 'create' para añadir uno "
        + "nuevo, 'complete' para marcar uno como hecho, y 'delete' para borrarlo. "
        + "Para 'complete' y 'delete' identifica el recordatorio por su título "
        + "exacto; confirma con el usuario antes de borrar si hay ambigüedad.",
    properties: [
        "action": .init(type: "string",
                        description: "Acción a realizar.",
                        enumValues: ["list", "create", "complete", "delete"]),
        "title": .init(type: "string",
                       description: "Título del recordatorio. Obligatorio para "
                           + "create, complete y delete."),
        "notes": .init(type: "string",
                       description: "Notas opcionales del recordatorio (solo create)."),
        "due": .init(type: "string",
                     description: "Fecha y hora de vencimiento opcional (solo create), "
                         + "en formato \"YYYY-MM-DD HH:MM\" o \"YYYY-MM-DD\". Usa "
                         + "get_datetime antes si necesitas calcular fechas relativas "
                         + "como «mañana» o «el viernes»."),
        "list_name": .init(type: "string",
                           description: "Nombre de la lista de recordatorios. Si se "
                               + "omite, se usa la lista por defecto (create) o se "
                               + "buscan todas las listas (list/complete/delete).")
    ],
    required: ["action"]
)

/// Reads and creates events in the macOS Calendar.app via AppleScript. Listing
/// is read-only; creating adds an event to a calendar. The action and its result
/// are shown in the chat. Driven in the background like Mail/Reminders.
let manageCalendarTool = ToolSpec.function(
    name: "manage_calendar",
    description: "Consulta y crea eventos en el Calendario (Calendar) del Mac. Usa "
        + "'list' para ver los próximos eventos en un rango de fechas, y 'create' "
        + "para añadir un evento nuevo. La acción y su resultado se muestran en el "
        + "chat. Para fechas relativas («mañana», «el viernes»), llama antes a "
        + "get_datetime y calcula la fecha absoluta.",
    properties: [
        "action": .init(type: "string", description: "Acción a realizar.",
                        enumValues: ["list", "create"]),
        "title": .init(type: "string",
                       description: "Título del evento. Obligatorio para create."),
        "start": .init(type: "string",
                       description: "Inicio en formato \"YYYY-MM-DD HH:MM\" (o "
                           + "\"YYYY-MM-DD\" para todo el día). Para 'list' es el "
                           + "comienzo del rango (por defecto, ahora)."),
        "end": .init(type: "string",
                     description: "Fin en formato \"YYYY-MM-DD HH:MM\". Para 'create' "
                         + "es el fin del evento (por defecto, 1 hora después de "
                         + "start). Para 'list' es el fin del rango (por defecto, "
                         + "7 días después de start)."),
        "notes": .init(type: "string", description: "Notas opcionales (solo create)."),
        "calendar_name": .init(type: "string",
                               description: "Nombre del calendario. Si se omite, se usa "
                                   + "el primero disponible (create) o todos (list).")
    ],
    required: ["action"]
)

/// Sets, lists, and cancels one-shot alarms on the Mac. An alarm is a local
/// notification (banner + sound) that the system fires at the chosen time, even
/// if Saphire is idle. Unlike `manage_reminders` (a to-do in Reminders.app) an
/// alarm is meant to grab attention at an exact moment ("despiértame a las 7",
/// "avísame dentro de 10 minutos").
let manageAlarmsTool = ToolSpec.function(
    name: "manage_alarms",
    description: "Pone, lista y cancela alarmas en el Mac. Una alarma es un aviso "
        + "(notificación con sonido) que el sistema lanza a una hora exacta, aunque "
        + "Saphire esté inactiva. Úsala cuando el usuario pida que le avises o le "
        + "despiertes a una hora concreta o dentro de un rato («pon una alarma a las "
        + "7:30», «avísame en 20 minutos»). Para un recordatorio/tarea (no un aviso "
        + "puntual con sonido) usa manage_reminders. Acciones: 'create' para poner una "
        + "alarma, 'list' para ver las pendientes, 'delete' para cancelar una por su id "
        + "(el que devuelve 'list'). Para horas relativas («dentro de 10 minutos») llama "
        + "antes a get_datetime y calcula la hora absoluta.",
    properties: [
        "action": .init(type: "string", description: "Acción a realizar.",
                        enumValues: ["create", "list", "delete"]),
        "time": .init(type: "string",
                      description: "Hora de la alarma (solo create). Formato \"HH:MM\" "
                          + "(la próxima vez que ocurra esa hora, hoy o mañana) o "
                          + "\"YYYY-MM-DD HH:MM\" para una fecha y hora concretas."),
        "label": .init(type: "string",
                       description: "Texto opcional de la alarma (solo create), p.ej. "
                           + "«Reunión» o «Sacar la pizza del horno»."),
        "id": .init(type: "string",
                    description: "Identificador de la alarma a cancelar (solo delete); "
                        + "es el id que muestra 'list'.")
    ],
    required: ["action"]
)

/// Drives Calendar.app with AppleScript to list events in a range or create one.
/// Dates are parsed in Swift and passed as integer components so AppleScript can
/// build a proper `date` object regardless of the system locale.
func manageCalendar(action: String, title: String, start: String, end: String,
                    notes: String, calendarName: String) async throws -> String {
    let act = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    switch act {
    case "list":
        let from = parseDueDate(start) ?? Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: Date())
        let toDate = (parseDueDate(end).flatMap { Calendar.current.date(from: $0) })
            ?? (Calendar.current.date(from: from).map { $0.addingTimeInterval(7 * 86_400) })
            ?? Date().addingTimeInterval(7 * 86_400)
        let to = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: toDate)
        let script = """
        on run argv
            set y1 to (item 1 of argv as integer)
            set m1 to (item 2 of argv as integer)
            set d1 to (item 3 of argv as integer)
            set h1 to (item 4 of argv as integer)
            set n1 to (item 5 of argv as integer)
            set y2 to (item 6 of argv as integer)
            set m2 to (item 7 of argv as integer)
            set d2 to (item 8 of argv as integer)
            set h2 to (item 9 of argv as integer)
            set n2 to (item 10 of argv as integer)
            set theCal to item 11 of argv
            set startDate to current date
            set year of startDate to y1
            set month of startDate to m1
            set day of startDate to d1
            set hours of startDate to h1
            set minutes of startDate to n1
            set seconds of startDate to 0
            set endDate to current date
            set year of endDate to y2
            set month of endDate to m2
            set day of endDate to d2
            set hours of endDate to h2
            set minutes of endDate to n2
            set seconds of endDate to 0
            set out to ""
            tell application "Calendar"
                if theCal is "" then
                    set cals to every calendar
                else
                    set cals to (every calendar whose name is theCal)
                end if
                repeat with c in cals
                    repeat with e in (every event of c whose start date is greater than or equal to startDate and start date is less than or equal to endDate)
                        set out to out & "• " & (summary of e as string) & " — " & (start date of e as string) & " [" & (name of c as string) & "]" & linefeed
                    end repeat
                end repeat
            end tell
            return out
        end run
        """
        let raw = try await runAppleScript(script, args: [
            String(from.year ?? 0), String(from.month ?? 0), String(from.day ?? 0),
            String(from.hour ?? 0), String(from.minute ?? 0),
            String(to.year ?? 0), String(to.month ?? 0), String(to.day ?? 0),
            String(to.hour ?? 0), String(to.minute ?? 0),
            calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No hay eventos en ese rango." : trimmed

    case "create":
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Error: falta 'title' para crear el evento." }
        guard let startComps = parseDueDate(start),
              let startDate = Calendar.current.date(from: startComps) else {
            return "Error: 'start' debe ir en formato \"YYYY-MM-DD HH:MM\"."
        }
        let endDate = (parseDueDate(end).flatMap { Calendar.current.date(from: $0) })
            ?? startDate.addingTimeInterval(3600)
        let endComps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: endDate)
        let script = """
        on run argv
            set theTitle to item 1 of argv
            set theNotes to item 2 of argv
            set theCal to item 3 of argv
            set y1 to (item 4 of argv as integer)
            set m1 to (item 5 of argv as integer)
            set d1 to (item 6 of argv as integer)
            set h1 to (item 7 of argv as integer)
            set n1 to (item 8 of argv as integer)
            set y2 to (item 9 of argv as integer)
            set m2 to (item 10 of argv as integer)
            set d2 to (item 11 of argv as integer)
            set h2 to (item 12 of argv as integer)
            set n2 to (item 13 of argv as integer)
            set sd to current date
            set year of sd to y1
            set month of sd to m1
            set day of sd to d1
            set hours of sd to h1
            set minutes of sd to n1
            set seconds of sd to 0
            set ed to current date
            set year of ed to y2
            set month of ed to m2
            set day of ed to d2
            set hours of ed to h2
            set minutes of ed to n2
            set seconds of ed to 0
            tell application "Calendar"
                if theCal is "" then
                    set tgt to calendar 1
                else
                    set tgt to calendar theCal
                end if
                make new event at end of events of tgt with properties {summary:theTitle, start date:sd, end date:ed, description:theNotes}
            end tell
            return "ok"
        end run
        """
        _ = try await runAppleScript(script, args: [
            t, notes, calendarName.trimmingCharacters(in: .whitespacesAndNewlines),
            String(startComps.year ?? 0), String(startComps.month ?? 0), String(startComps.day ?? 0),
            String(startComps.hour ?? 0), String(startComps.minute ?? 0),
            String(endComps.year ?? 0), String(endComps.month ?? 0), String(endComps.day ?? 0),
            String(endComps.hour ?? 0), String(endComps.minute ?? 0)
        ])
        var msg = "Evento creado: «\(t)» el \(start.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !calendarName.isEmpty { msg += " en «\(calendarName)»" }
        return msg + "."

    default:
        return "Error: acción desconocida «\(action)». Usa list o create."
    }
}

/// Drives Reminders.app with AppleScript to list / create / complete / delete.
/// Dates are parsed in Swift (locale-independent) and passed as integer
/// components so the script can build a proper AppleScript `date` object.
func manageReminders(action: String, title: String, notes: String,
                     due: String, listName: String) async throws -> String {
    let act = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    switch act {
    case "list":
        let script = """
        on run argv
            set theList to item 1 of argv
            set out to ""
            set n to 0
            tell application "Reminders"
                if theList is "" then
                    set src to (reminders whose completed is false)
                else
                    set src to (reminders of list theList whose completed is false)
                end if
                repeat with r in src
                    set n to n + 1
                    set out to out & "• " & (name of r as string)
                    try
                        set d to due date of r
                        if d is not missing value then set out to out & "  (vence: " & (d as string) & ")"
                    end try
                    set out to out & linefeed
                end repeat
            end tell
            if n is 0 then return "No hay recordatorios pendientes."
            return out
        end run
        """
        let raw = try await runAppleScript(script, args: [listName])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No hay recordatorios pendientes." : trimmed

    case "create":
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Error: falta 'title' para crear el recordatorio." }
        let comps = parseDueDate(due)
        let script = """
        on run argv
            set theTitle to item 1 of argv
            set theNotes to item 2 of argv
            set theList to item 3 of argv
            set hasDue to (item 4 of argv is "1")
            tell application "Reminders"
                if theList is "" then
                    set tgt to default list
                else
                    set tgt to list theList
                end if
                if hasDue then
                    set dd to current date
                    set year of dd to (item 5 of argv as integer)
                    set month of dd to (item 6 of argv as integer)
                    set day of dd to (item 7 of argv as integer)
                    set hours of dd to (item 8 of argv as integer)
                    set minutes of dd to (item 9 of argv as integer)
                    set seconds of dd to 0
                    make new reminder at end of tgt with properties {name:theTitle, body:theNotes, due date:dd}
                else
                    make new reminder at end of tgt with properties {name:theTitle, body:theNotes}
                end if
            end tell
            return "ok"
        end run
        """
        _ = try await runAppleScript(script, args: [
            t, notes, listName,
            comps == nil ? "0" : "1",
            String(comps?.year ?? 0), String(comps?.month ?? 0), String(comps?.day ?? 0),
            String(comps?.hour ?? 0), String(comps?.minute ?? 0)
        ])
        var msg = "Recordatorio creado: «\(t)»"
        if comps != nil { msg += " (vence \(due.trimmingCharacters(in: .whitespacesAndNewlines)))" }
        if !listName.isEmpty { msg += " en la lista «\(listName)»" }
        return msg + "."

    case "complete", "delete":
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Error: falta 'title' para \(act == "delete" ? "borrar" : "completar") el recordatorio." }
        let verb = act == "delete" ? "delete r" : "set completed of r to true"
        let script = """
        on run argv
            set theTitle to item 1 of argv
            set theList to item 2 of argv
            set n to 0
            tell application "Reminders"
                if theList is "" then
                    set src to (reminders whose name is theTitle and completed is false)
                else
                    set src to (reminders of list theList whose name is theTitle and completed is false)
                end if
                repeat with r in src
                    \(verb)
                    set n to n + 1
                end repeat
            end tell
            return (n as string)
        end run
        """
        let raw = try await runAppleScript(script, args: [t, listName])
        let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if n == 0 { return "No se encontró ningún recordatorio pendiente titulado «\(t)»." }
        let did = act == "delete" ? "borrado" : "completado"
        return n == 1 ? "Recordatorio \(did): «\(t)»."
                      : "\(n) recordatorios titulados «\(t)» \(did)s."

    default:
        return "Error: acción desconocida «\(action)». Usa list, create, complete o delete."
    }
}

/// Maps single-letter Spanish weekday tokens (L M X J V S D) to `Calendar`
/// weekday numbers (1=domingo … 7=sábado).
private let weekdayLetters: [Character: Int] = [
    "L": 2, "M": 3, "X": 4, "J": 5, "V": 6, "S": 7, "D": 1
]

/// Parses a "L,M,X" style day list into Calendar weekday numbers. An empty
/// string or "diario"/"todos" yields an empty set, meaning "every day".
func parseWeekdays(_ s: String) -> Set<Int> {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.isEmpty || t.contains("DIARIO") || t.contains("TODOS") { return [] }
    var out = Set<Int>()
    for ch in t where weekdayLetters[ch] != nil { out.insert(weekdayLetters[ch]!) }
    return out
}

/// Parses an "HH:MM" 24-hour string into (hour, minute). Returns nil if invalid.
func parseHourMinute(_ s: String) -> (hour: Int, minute: Int)? {
    let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return (h, m)
}

/// Parses a "YYYY-MM-DD HH:MM" or "YYYY-MM-DD" string into date components.
/// Returns nil when the string is empty or unparseable.
private func parseDueDate(_ s: String) -> DateComponents? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = fmt
        if let date = df.date(from: trimmed) {
            return Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
        }
    }
    return nil
}

// MARK: - Shell command execution

/// Leading command tokens considered read-only (safe to run without asking).
/// Anything not on this list — or any command that pipes/chains into something
/// not on it, or redirects output — is treated as mutating and gated behind the
/// user's confirmation. Default-deny: safer than trying to enumerate every
/// destructive command.
private let readOnlyCommands: Set<String> = [
    "ls", "pwd", "cat", "bat", "head", "tail", "less", "more", "echo", "printf",
    "grep", "egrep", "fgrep", "rg", "ag", "find", "fd", "wc", "sort", "uniq",
    "cut", "awk", "tr", "diff", "comm", "file", "stat", "du", "df", "tree",
    "whoami", "id", "groups", "hostname", "uname", "sw_vers", "date", "cal",
    "uptime", "env", "printenv", "which", "type", "whereis", "man", "history",
    "ps", "top", "lsof", "netstat", "ifconfig", "ipconfig", "dig", "nslookup",
    "host", "ping", "traceroute", "arp", "say", "pbpaste",
    "basename", "dirname", "realpath", "readlink", "md5", "shasum", "sha256sum",
    "jq", "yq", "column",
    "mdfind", "mdls", "system_profiler", "vm_stat", "sysctl", "w", "who", "last",
    // NOTE: `tee` writes/overwrites files and `open` launches arbitrary apps or
    // files — both have side effects, so they are deliberately NOT read-only and
    // fall through to user confirmation.
]

/// `git` subcommands that only read state.
private let readOnlyGitSubcommands: Set<String> = [
    "status", "log", "diff", "show", "branch", "remote", "config", "ls-files",
    "rev-parse", "describe", "blame", "shortlog", "tag", "stash",
]

/// Decides whether a command must be confirmed by the user before running.
/// Returns true (needs permission) for anything that isn't unambiguously
/// read-only, including redirections and chained/piped non-read commands.
func commandNeedsPermission(_ command: String) -> Bool {
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if cmd.isEmpty { return false }

    // Output redirection writes/overwrites files → always confirm.
    if cmd.contains(">") { return true }

    // Command / process substitution hides an arbitrary command inside an
    // otherwise read-only one (e.g. `echo $(rm -rf ~)` or `echo \`rm x\``).
    // The inner command never reaches segment analysis below, so treat any
    // substitution as mutating and confirm. Covers $(…), `…`, and <(…)/>(…).
    if cmd.contains("$(") || cmd.contains("`") || cmd.contains("<(") || cmd.contains(">(") {
        return true
    }

    // Split on shell separators; every segment must be read-only.
    let separators = ["&&", "||", ";", "|"]
    var segments = [cmd]
    for sep in separators {
        segments = segments.flatMap { $0.components(separatedBy: sep) }
    }
    for seg in segments {
        let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if !segmentIsReadOnly(trimmed) { return true }
    }
    return false
}

/// True only when the first token of a single command segment is a known
/// read-only command (with a special-case for read-only `git` subcommands).
private func segmentIsReadOnly(_ segment: String) -> Bool {
    // Strip leading VAR=value assignments and grab the first real token.
    let tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard let first = tokens.first(where: { !$0.contains("=") }) else { return false }
    let name = (first as NSString).lastPathComponent  // handle /bin/ls → ls

    if name == "sudo" { return false }                 // privilege escalation always confirms
    if name == "git" {
        // git <subcommand> — read-only only for the whitelisted subcommands.
        if let sub = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return readOnlyGitSubcommands.contains(sub)
        }
        return true   // bare `git` is harmless, but be conservative
    }
    return readOnlyCommands.contains(name)
}

/// Result of running a shell command.
struct CommandResult: Sendable {
    let output: String      // combined stdout+stderr, already truncated
    let exitCode: Int32
}

/// Runs `command` through `/bin/zsh -lc` (a login shell, so the user's PATH and
/// profile are honored — a GUI app doesn't inherit the shell environment) and
/// returns the combined stdout+stderr plus the exit code. Runs on a background
/// queue because `waitUntilExit()` blocks.
func runShellCommand(_ command: String, maxChars: Int = 10000,
                     timeout: TimeInterval = 60) async -> CommandResult {
    await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = outPipe   // merge stderr into stdout for one stream
            do {
                try p.run()
            } catch {
                cont.resume(returning: CommandResult(
                    output: "No se pudo ejecutar el comando: \(error.localizedDescription)",
                    exitCode: -1))
                return
            }
            // Kill the process if it runs past the timeout so the chat can't hang.
            let timeoutItem = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timeoutItem.cancel()

            var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n…(salida truncada)" }
            cont.resume(returning: CommandResult(output: text, exitCode: p.terminationStatus))
        }
    }
}

// MARK: - URL fetching

/// Downloads a web page and returns a cleaned, truncated plain-text version.
/// Strips tags rather than rendering, so it is safe to run off the main thread.
func fetchURLText(_ urlString: String, maxChars: Int = 6000) async throws -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        throw SearchError("fetch_url: URL inválida «\(urlString)».")
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    req.setValue("Mozilla/5.0 (Macintosh) Saphire/1.0", forHTTPHeaderField: "User-Agent")

    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
    guard code == 200 else { throw SearchError("fetch_url HTTP \(code)") }

    let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    let text = htmlToText(html)
    let clipped = text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
    return "Contenido de \(url.absoluteString):\n\n\(clipped)"
}

/// Small HTML→text reducer: drops script/style blocks, turns block closers into
/// newlines, strips remaining tags, decodes common entities, collapses runs.
private func htmlToText(_ html: String) -> String {
    var s = html
    for tag in ["script", "style", "head", "noscript", "svg"] {
        // (?s) lets `.` span newlines so whole blocks are removed.
        s = s.replacingOccurrences(of: "(?s)<\(tag)[^>]*>.*?</\(tag)>",
                                   with: " ", options: [.regularExpression, .caseInsensitive])
    }
    s = s.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6]|br|tr|section|article)>",
                               with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                    "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Arithmetic evaluation

/// Minimal, crash-safe arithmetic evaluator (recursive descent). Supports
/// `+ - * / %`, `^` (power, right-associative), parentheses, unary `+/-`, and
/// decimal/scientific numbers. Returns nil on any syntax error instead of
/// throwing — unlike `NSExpression(format:)`, which raises an uncatchable
/// Objective-C exception on malformed input.
struct ArithmeticParser {
    private let s: [Character]
    private var pos = 0
    init(_ text: String) { s = Array(text) }

    mutating func parse() -> Double? {
        let v = parseExpression()
        skipSpaces()
        return pos == s.count ? v : nil   // reject trailing garbage
    }

    private mutating func skipSpaces() { while pos < s.count, s[pos] == " " { pos += 1 } }
    private mutating func peek() -> Character? { skipSpaces(); return pos < s.count ? s[pos] : nil }

    // expression := term (('+' | '-') term)*
    private mutating func parseExpression() -> Double? {
        guard var acc = parseTerm() else { return nil }
        while let c = peek(), c == "+" || c == "-" {
            pos += 1
            guard let rhs = parseTerm() else { return nil }
            acc = (c == "+") ? acc + rhs : acc - rhs
        }
        return acc
    }

    // term := factor (('*' | '/' | '%') factor)*
    private mutating func parseTerm() -> Double? {
        guard var acc = parseFactor() else { return nil }
        while let c = peek(), c == "*" || c == "/" || c == "%" {
            pos += 1
            guard let rhs = parseFactor() else { return nil }
            switch c {
            case "*": acc *= rhs
            case "/": if rhs == 0 { return nil }; acc /= rhs
            default:  if rhs == 0 { return nil }; acc = acc.truncatingRemainder(dividingBy: rhs)
            }
        }
        return acc
    }

    // factor := unary ('^' factor)?   (right-associative power)
    private mutating func parseFactor() -> Double? {
        guard let base = parseUnary() else { return nil }
        if let c = peek(), c == "^" {
            pos += 1
            guard let exp = parseFactor() else { return nil }
            return pow(base, exp)
        }
        return base
    }

    // unary := ('+' | '-')* primary
    private mutating func parseUnary() -> Double? {
        if let c = peek(), c == "+" || c == "-" {
            pos += 1
            guard let v = parseUnary() else { return nil }
            return c == "-" ? -v : v
        }
        return parsePrimary()
    }

    // primary := number | '(' expression ')'
    private mutating func parsePrimary() -> Double? {
        guard let c = peek() else { return nil }
        if c == "(" {
            pos += 1
            guard let v = parseExpression() else { return nil }
            guard let close = peek(), close == ")" else { return nil }
            pos += 1
            return v
        }
        return parseNumber()
    }

    private mutating func parseNumber() -> Double? {
        skipSpaces()
        let start = pos
        while pos < s.count {
            let ch = s[pos]
            if ch.isNumber || ch == "." || ch == "e" || ch == "E" {
                pos += 1
            } else if ch == "+" || ch == "-" {
                // Sign is only part of a number right after an exponent marker.
                let prev = pos > start ? s[pos - 1] : " "
                if prev == "e" || prev == "E" { pos += 1 } else { break }
            } else {
                break
            }
        }
        return start == pos ? nil : Double(String(s[start..<pos]))
    }
}

// MARK: - Search backends (swappable)

enum SearchBackendKind: String, CaseIterable, Sendable {
    case tavily, searxng
}

struct SearchError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// A pluggable web-search provider. Returns model-ready plain text.
protocol SearchBackend: Sendable {
    func search(_ query: String) async throws -> String
}

/// Renders a compact, model-friendly result block shared by all backends.
private func renderResults(query: String, answer: String?,
                           results: [(title: String, url: String, content: String)]) -> String {
    var out = "Resultados de búsqueda web para «\(query)»:\n"
    if let answer, !answer.isEmpty {
        out += "\nResumen: \(answer)\n"
    }
    if results.isEmpty {
        out += "\n(sin resultados)"
        return out
    }
    for (i, r) in results.prefix(5).enumerated() {
        let snippet = String(r.content.prefix(500))
        out += "\n\(i + 1). \(r.title)\n   \(r.url)\n   \(snippet)\n"
    }
    return out
}

/// Tavily Search API — https://tavily.com (LLM-oriented, returns clean text).
struct TavilyBackend: SearchBackend {
    let apiKey: String

    func search(_ query: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 5,
            "search_depth": "basic",
            "include_answer": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SearchError("Tavily HTTP \(code): \(raw)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError("Tavily: respuesta inválida")
        }
        let answer = obj["answer"] as? String
        let results = (obj["results"] as? [[String: Any]] ?? []).map {
            (title: $0["title"] as? String ?? "",
             url: $0["url"] as? String ?? "",
             content: $0["content"] as? String ?? "")
        }
        return renderResults(query: query, answer: answer, results: results)
    }
}

// MARK: - Mail.app reading (AppleScript)

/// Runs an AppleScript and returns its stdout. The script source is fed on
/// stdin (`osascript -`) and `args` are passed as `on run argv`, so user text
/// (e.g. a search query) never gets interpolated into the script — no escaping
/// or injection to worry about.
///
/// The whole thing runs on a background queue because `Process.waitUntilExit()`
/// blocks; awaiting it from the @MainActor caller must not stall the UI.
private func runAppleScript(_ source: String, args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"] + args   // "-" → read script from stdin
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            do {
                try p.run()
            } catch {
                cont.resume(throwing: SearchError("No se pudo ejecutar osascript: \(error.localizedDescription)"))
                return
            }
            // Kill osascript if it stalls — e.g. waiting on an Apple-events TCC
            // grant that never prompts for a background agent — so the tool call
            // fails with an error instead of hanging the response forever.
            let killItem = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killItem)
            let h = inPipe.fileHandleForWriting
            h.write(Data(source.utf8))
            try? h.close()
            // Output is small; read to EOF before waiting to avoid pipe stalls.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killItem.cancel()
            if p.terminationStatus != 0 {
                let raw = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(throwing: SearchError(raw.isEmpty ? "osascript falló (\(p.terminationStatus))" : raw))
                return
            }
            cont.resume(returning: String(data: outData, encoding: .utf8) ?? "")
        }
    }
}

// `read_email` now reads Apple Mail's Envelope Index SQLite directly — see
// `readEmailViaMail` in Mail.swift. The old AppleScript implementation was
// removed: driving Mail over Apple events both needs an Automation TCC grant
// that never prompts for this background agent and crawls when iterating a
// large inbox, so the tool call would hang with no result.

/// SearXNG self-hosted metasearch — set `baseURL` to your instance, e.g.
/// http://localhost:8080. Privacy-friendly, no API key. Wired for an easy
/// swap from Tavily later via Settings.
struct SearXNGBackend: SearchBackend {
    let baseURL: String

    func search(_ query: String) async throws -> String {
        guard var comps = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces)) else {
            throw SearchError("SearXNG: URL inválida")
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/search"
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "format", value: "json")
        ]
        guard let url = comps.url else { throw SearchError("SearXNG: URL inválida") }

        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw SearchError("SearXNG HTTP \(code)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError("SearXNG: respuesta inválida")
        }
        let results = (obj["results"] as? [[String: Any]] ?? []).map {
            (title: $0["title"] as? String ?? "",
             url: $0["url"] as? String ?? "",
             content: $0["content"] as? String ?? "")
        }
        return renderResults(query: query, answer: nil, results: results)
    }
}
