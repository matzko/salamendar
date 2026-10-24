// The web calendar, drawn by EventCalendar. EventCalendar is a global from
// its own <script> tag in the root layout: its build is
// `var EventCalendar = (…)`, which esbuild would make private to app.js.
//
// Times: the server sends timed events as UTC instants and all-day events as
// dates, and `timeZone: "local"` shows them in the browser's zone (see
// "Time handling" in docs/web-calendar-plan.md).

const NARROW = "(max-width: 640px)"
const REFETCH_DEBOUNCE_MS = 300

// `YYYY-MM-DD` from a Date's local fields. `toISOString()` would give the
// UTC date, which is the next day east of UTC.
const localDate = (date) => {
  const pad = (n) => String(n).padStart(2, "0")
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

// EventCalendar's `startStr`/`endStr` have no offset, so send both edges of
// the range in both forms: instants for timed events, local dates for
// all-day ones.
const range = ({start, end}) => ({
  start: start.toISOString(),
  end: end.toISOString(),
  start_date: localDate(start),
  end_date: localDate(end),
})

// An event's new times for `reschedule`: local dates for all-day events,
// UTC instants for timed ones. Never `delta`, which is in wall-clock terms
// and is an hour off across a DST change.
const eventTimes = ({allDay, start, end}) =>
  allDay
    ? {start: localDate(start), end: localDate(end)}
    : {start: start.toISOString(), end: end.toISOString()}

const tooltip = ({title, extendedProps: {owner, channels}}) =>
  [title, owner && `by ${owner}`, channels?.length && channels.map((c) => `#${c}`).join(" ")]
    .filter(Boolean)
    .join("\n")

export const Calendar = {
  mounted() {
    const narrow = window.matchMedia(NARROW)
    const view = (isNarrow) => (isNarrow ? "listWeek" : "dayGridMonth")

    this.ec = EventCalendar.create(this.el, {
      view: view(narrow.matches),
      headerToolbar: {
        start: "prev,next today",
        center: "title",
        end: "dayGridMonth,timeGridWeek,listWeek",
      },
      // Both week views are labelled "week" by default.
      buttonText: (text) => ({...text, listWeek: "list"}),
      firstDay: Number(this.el.dataset.weekStart),
      timeZone: "local",
      height: "100%",
      // A crowded day in the month grid shows "+N more" instead of growing.
      dayMaxEvents: true,
      eventSources: [
        {
          // A rejected push (e.g. while reconnecting) shows nothing rather
          // than an error; the next refetch fills it in.
          events: (info) =>
            this.pushEvent("fetch", range(info))
              .then((reply) => reply.events)
              .catch(() => []),
        },
      ],
      // Selecting a range opens the panel for a new event there.
      selectable: true,
      select: (info) => {
        this.pushEvent("new", {...range(info), all_day: info.allDay})
        this.ec.unselect()
      },
      eventClick: ({event}) => this.pushEvent("open", {id: event.id}),
      eventDrop: (info) => this.reschedule(info),
      eventResize: (info) => this.reschedule(info),
      eventDidMount: ({el, event}) => {
        el.title = tooltip(event)
      },
    })

    this.onNarrowChange = (e) => this.ec.setOption("view", view(e.matches))
    narrow.addEventListener("change", this.onNarrowChange)
    this.narrow = narrow

    // A burst of changes becomes one fetch.
    this.handleEvent("refetch", () => {
      clearTimeout(this.refetchTimer)
      this.refetchTimer = setTimeout(() => this.ec.refetchEvents(), REFETCH_DEBOUNCE_MS)
    })
  },

  // The server checks the owner again; anything but `ok: true` puts the
  // event back where it was.
  reschedule({event, revert}) {
    this.pushEvent("reschedule", {id: event.id, ...eventTimes(event)})
      .then((reply) => reply.ok || revert())
      .catch(() => revert())
  },

  destroyed() {
    clearTimeout(this.refetchTimer)
    this.narrow.removeEventListener("change", this.onNarrowChange)
    EventCalendar.destroy(this.ec)
  },
}
