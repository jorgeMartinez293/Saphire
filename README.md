# Saphire

Chat de escritorio nativo (macOS) para tu modelo local **gemma4** vía Ollama.
Dos modos: overlay compacto invocado con `⌥Space` y ventana extendida con historial.

## Características

- **Overlay `⌥Space`**: panel flotante que aparece sobre cualquier app (incluido
  pantalla completa). Empieza minúsculo (una línea) y se expande hacia abajo con
  la respuesta. `Esc` lo cierra. Mantener pulsado ⌥Space ≥1s dicta por voz.
- **Ventana extendida**: barra lateral con conversaciones anteriores, selector de
  modelo, toggle de *thinking* (razonamiento).
- **Herramientas**: búsqueda web, deep research, leer Mail y WhatsApp, terminal,
  Recordatorios, Calendario, tareas programadas autónomas y bandeja de
  preguntas/avisos.
- **Backends**: Ollama local, OpenRouter y cualquier endpoint compatible con
  OpenAI (LM Studio, vLLM…), seleccionados por modelo.
- **Imágenes**: adjunta con el clip o pega con `⌘V` (gemma4 es multimodal).
- **LaTeX**: render con MathJax (`$inline$` y `$$bloque$$`), sin fuentes externas.
- **Markdown** + resaltado de código (highlight.js).
- **Historial** en SQLite (`~/Library/Application Support/Saphire/saphire.sqlite`).

Todo funciona **offline** (assets web incluidos en el bundle); solo necesita
Ollama corriendo en `localhost:11434`.

## Compilar y desplegar

```bash
./deploy.sh        # compila release, firma con cert estable y relanza la app
```

`deploy.sh` es la vía recomendada: firma con una identidad estable para que los
permisos TCC (Acceso a disco completo para Mail/WhatsApp) sobrevivan a cada
redeploy, y sincroniza la copia de `/Applications`. Exporta tu propia identidad
de firma antes de ejecutarlo:

```bash
security find-identity -v -p codesigning      # lista tus certificados
SIGN_ID="<hash o nombre del cert>" ./deploy.sh
```

Un certificado *Apple Development* gratuito de Xcode sirve. Sin `SIGN_ID` cae a
firma ad-hoc (los permisos TCC se pierden en cada build). Alternativa desde
cero: `./scripts/build_app.sh release` (siempre ad-hoc).

Para desarrollo rápido: `swift build && .build/debug/Saphire`.

Depuración: arrancar con la variable de entorno `SAPHIRE_DEBUG=1` escribe una
traza de peticiones y herramientas en `/tmp/saphire-req.log`.

## Primer arranque

Si Gatekeeper se queja: clic derecho sobre `Saphire.app` → **Abrir** la
primera vez.

La app vive en la barra de menú (icono diamante). No tiene icono en el Dock
salvo cuando abres la ventana extendida.

## Arquitectura

| Pieza | Archivo |
|-------|---------|
| Entrypoint / agente | `Main.swift` + `AppDelegate.swift` |
| Hotkey global (Carbon) | `HotKey.swift` |
| Panel overlay | `OverlayPanel.swift` + `OverlayView.swift` |
| Ventana extendida | `MainView.swift` |
| Estado + agente de herramientas | `AppState.swift` |
| Definición/ejecución de tools | `Tools.swift`, `Mail.swift`, `WhatsApp.swift` |
| Cliente Ollama (streaming) | `OllamaClient.swift` |
| Cliente OpenRouter / OpenAI-compat | `OpenRouterClient.swift` |
| Persistencia SQLite | `Database.swift` |
| Render Markdown+LaTeX | `ChatWebView.swift` + `Resources/web/chat.html` |

## Pendiente / ideas

- Cambiar el atajo desde la UI.
- Audio (gemma4 soporta `audio`).
- Streaming token a token sin re-render completo (micro-optimización).

## Licencia

MIT. Ver [LICENSE](LICENSE).
