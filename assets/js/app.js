// Bundled by esbuild (see `config :esbuild` in config/config.exs).

// Handles method=PUT/DELETE in links and forms.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/salamendar"
import topbar from "../vendor/topbar"
import {Calendar} from "./hooks/calendar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // The calendar shows times in this zone, so the server reads forms in it.
  params: {_csrf_token: csrfToken, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone},
  hooks: {...colocatedHooks, Calendar},
})

// Show a progress bar on live navigation and form submits.
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

// For debugging in the browser console:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Stream server logs to the browser console.
    reloader.enableServerLogs()
    window.liveReloader = reloader
  })
}
