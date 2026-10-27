// Emoji entry for `<.input emoji>` (see CoreComponents.input/1): a picker
// button and `:name` autocomplete, with Slack's names.
//
// The hook's element is the field's div. It holds the input or textarea,
// and a `phx-update="ignore"` div with the button and an empty popup, so
// LiveView re-renders leave both alone.
//
// The data is `priv/static/vendor/emoji.json` (see
// `mix salamendar.gen.emoji`): `{categories, emoji: [[char, names,
// category_index], ...]}`, in Slack's order.

const DATA_URL = "/vendor/emoji.json"
const RECENT_KEY = "salamendar.emoji.recent"
const RECENT_MAX = 24
const SEARCH_MAX = 200

let loading = null

// The emoji data, fetched once per page. A failed fetch is forgotten, so
// the next call tries again.
export const loadEmoji = () => {
  loading ??= fetch(DATA_URL)
    .then((response) => {
      if (!response.ok) throw new Error(`${DATA_URL}: ${response.status}`)
      return response.json()
    })
    .then(({categories, emoji}) => {
      const all = emoji.map(([char, names, category]) => ({char, names, category}))
      const byName = new Map(all.flatMap((e) => e.names.map((name) => [name, e])))
      const byChar = new Map(all.map((e) => [e.char, e]))
      return {categories, all, byName, byChar}
    })
    .catch((error) => {
      loading = null
      throw error
    })

  return loading
}

// Puts `text` in place of `input`'s selection (or `start`..`end`), with the
// caret after it, and tells LiveView with an `input` event. Returns false,
// changing nothing, when it wouldn't fit in `maxlength` (which, like
// `value.length`, counts UTF-16 code units).
export const insert = (input, text, start = input.selectionStart, end = input.selectionEnd) => {
  const max = input.maxLength
  if (max >= 0 && input.value.length - (end - start) + text.length > max) return false

  input.setRangeText(text, start, end, "end")
  input.dispatchEvent(new Event("input", {bubbles: true}))
  return true
}

// Emoji matching `term`, best first: names starting with it, then names
// with a word starting with it (`cake` finds `birthday_cake`), then names
// containing it. Within each group, Slack's order.
export const search = (data, term) => {
  const groups = [[], [], []]

  for (const emoji of data.all) {
    let best = 3
    for (const name of emoji.names) {
      const at = name.indexOf(term)
      if (at === 0) best = 0
      else if (at > 0 && /[_-]/.test(name[at - 1])) best = Math.min(best, 1)
      else if (at > 0) best = Math.min(best, 2)
    }
    if (best < 3) groups[best].push(emoji)
  }

  return groups.flat()
}

// The last picks, newest first, as chars. Storage can be missing or throw
// (private windows, blocked site data), which just means no history.
export const recentEmoji = () => {
  try {
    const recent = JSON.parse(localStorage.getItem(RECENT_KEY))
    return Array.isArray(recent) ? recent : []
  } catch {
    return []
  }
}

export const rememberEmoji = (char) => {
  const recent = [char, ...recentEmoji().filter((c) => c !== char)].slice(0, RECENT_MAX)
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(recent))
  } catch {
    // No history this time.
  }
}

const element = (tag, props = {}, children = []) => {
  const el = Object.assign(document.createElement(tag), props)
  el.append(...children)
  return el
}

const emojiButton = (emoji) =>
  element("button", {
    type: "button",
    className: "emoji-option",
    tabIndex: -1,
    title: `:${emoji.names[0]}:`,
    textContent: emoji.char,
  })

// The emoji a picker button stands for, found by its char.
const buttonEmoji = (data, button) => data.byChar.get(button.textContent)

// The picker: search, category tabs, a scrolling grid of sections, and a
// footer naming the emoji under the pointer or focus. `onPick(emoji,
// keepOpen)` is called on a click, or Enter in the search box.
class Picker {
  constructor(popup, data, {onPick}) {
    this.popup = popup
    this.data = data
    this.onPick = onPick

    this.searchBox = element("input", {
      type: "search",
      className: "emoji-search",
      placeholder: "Search emoji",
      ariaLabel: "Search emoji",
      autocomplete: "off",
    })
    this.tabs = element("div", {className: "emoji-tabs"})
    this.grid = element("div", {className: "emoji-grid"})
    this.results = element("div", {className: "emoji-section emoji-results", hidden: true})
    this.empty = element("p", {className: "emoji-empty muted", textContent: "No emoji found", hidden: true})
    this.previewChar = element("span", {className: "emoji-preview-char"})
    this.previewName = element("span", {className: "emoji-preview-name"})
    const footer = element("div", {className: "emoji-footer"}, [this.previewChar, this.previewName])

    this.sections = data.categories.map((name, index) =>
      this.section(name, data.all.filter((e) => e.category === index)),
    )
    this.recent = this.section("Frequently used", [])
    this.grid.append(this.results, this.empty, this.recent.el, ...this.sections.map((s) => s.el))

    popup.setAttribute("role", "dialog")
    popup.setAttribute("aria-label", "Emoji")
    popup.replaceChildren(this.searchBox, this.tabs, this.grid, footer)
    this.drawTabs()

    this.searchBox.addEventListener("input", () => this.filter())
    this.searchBox.addEventListener("keydown", (e) => this.searchKeydown(e))
    this.grid.addEventListener("click", (e) => this.click(e))
    this.grid.addEventListener("keydown", (e) => this.gridKeydown(e))
    this.grid.addEventListener("pointerover", (e) => this.preview(e.target))
    this.grid.addEventListener("focusin", (e) => this.preview(e.target))
    this.grid.addEventListener("scroll", () => this.markTab(), {passive: true})
  }

  section(name, emoji) {
    const buttons = element("div", {className: "emoji-options"}, emoji.map(emojiButton))
    const heading = element("h4", {className: "emoji-section-title", textContent: name})
    const el = element("div", {className: "emoji-section"}, [heading, buttons])
    const tab = element("button", {
      type: "button",
      className: "emoji-tab",
      title: name,
      ariaLabel: name,
      textContent: emoji[0]?.char ?? "🕘",
    })
    tab.addEventListener("click", () => this.scrollTo(el))
    return {name, el, buttons, tab}
  }

  drawTabs() {
    const shown = [this.recent, ...this.sections].filter((s) => !s.el.hidden)
    this.tabs.replaceChildren(...shown.map((s) => s.tab))
    this.markTab()
  }

  // Called each time the popup opens.
  open() {
    const recent = recentEmoji()
      .map((char) => this.data.byChar.get(char))
      .filter(Boolean)
    this.recent.buttons.replaceChildren(...recent.map(emojiButton))
    this.recent.el.hidden = recent.length === 0
    this.recent.tab.textContent = "🕘"
    this.drawTabs()

    this.searchBox.value = ""
    this.filter()
    this.grid.scrollTop = 0
    this.preview(null)
    this.searchBox.focus()
  }

  filter() {
    const term = this.searchBox.value.trim().toLowerCase().replace(/^:|:$/g, "")
    const searching = term !== ""

    if (searching) {
      const matches = search(this.data, term).slice(0, SEARCH_MAX)
      this.results.replaceChildren(
        element("div", {className: "emoji-options"}, matches.map(emojiButton)),
      )
      this.empty.hidden = matches.length > 0
      this.preview(this.results.querySelector(".emoji-option"))
    } else {
      this.empty.hidden = true
    }

    this.results.hidden = !searching
    this.tabs.hidden = searching
    for (const section of [this.recent, ...this.sections]) {
      section.el.classList.toggle("emoji-section-off", searching)
    }
    this.grid.scrollTop = 0
  }

  visibleButtons() {
    const selector = this.results.hidden
      ? ".emoji-section:not([hidden]):not(.emoji-section-off) .emoji-option"
      : ".emoji-results .emoji-option"
    return [...this.grid.querySelectorAll(selector)]
  }

  // The grid is `position: relative`, so sections' `offsetTop`s are from
  // its top.
  scrollTo(sectionEl) {
    this.grid.scrollTop = sectionEl.offsetTop
  }

  // Highlights the tab of the section at the top of the grid.
  markTab() {
    const top = this.grid.scrollTop + 1
    let current = null
    for (const section of [this.recent, ...this.sections]) {
      if (!section.el.hidden && section.el.offsetTop <= top) current = section
    }
    current ??= this.recent.el.hidden ? this.sections[0] : this.recent
    for (const section of [this.recent, ...this.sections]) {
      section.tab.ariaPressed = String(section === current)
    }
  }

  preview(button) {
    const emoji = button?.classList?.contains("emoji-option") && buttonEmoji(this.data, button)
    this.previewChar.textContent = emoji ? emoji.char : ""
    this.previewName.textContent = emoji ? `:${emoji.names[0]}:` : "Pick an emoji"
  }

  click(event) {
    const button = event.target.closest(".emoji-option")
    if (!button) return
    this.onPick(buttonEmoji(this.data, button), event.shiftKey)
  }

  searchKeydown(event) {
    if (event.key === "Enter") {
      // Never submit the form from here.
      event.preventDefault()
      const first = this.visibleButtons()[0]
      if (first) this.onPick(buttonEmoji(this.data, first), event.shiftKey)
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      this.visibleButtons()[0]?.focus()
    }
  }

  // Arrow keys move by position, so rows work across sections of any width.
  gridKeydown(event) {
    const current = event.target.closest(".emoji-option")
    if (!current) return

    const buttons = this.visibleButtons()
    const index = buttons.indexOf(current)
    let next = null

    if (event.key === "ArrowLeft") next = buttons[index - 1]
    else if (event.key === "ArrowRight") next = buttons[index + 1]
    else if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      next = this.verticalNeighbour(buttons, current, event.key === "ArrowDown")
      if (!next && event.key === "ArrowUp") {
        event.preventDefault()
        this.searchBox.focus()
        return
      }
    } else {
      return
    }

    event.preventDefault()
    if (next) {
      next.focus()
      next.scrollIntoView({block: "nearest"})
    }
  }

  // The button in the next row up or down, nearest `current` horizontally.
  verticalNeighbour(buttons, current, down) {
    const from = current.getBoundingClientRect()
    const rows = buttons
      .map((button) => ({button, rect: button.getBoundingClientRect()}))
      .filter(({rect}) => (down ? rect.top > from.top + 1 : rect.top < from.top - 1))
    if (rows.length === 0) return null

    const tops = rows.map(({rect}) => rect.top)
    const row = down ? Math.min(...tops) : Math.max(...tops)
    const dx = ({rect}) => Math.abs(rect.left - from.left)

    return rows
      .filter(({rect}) => Math.abs(rect.top - row) <= 1)
      .reduce((best, candidate) => (dx(candidate) < dx(best) ? candidate : best)).button
  }
}

export const EmojiInput = {
  mounted() {
    this.input = this.el.querySelector("input, textarea")
    this.button = this.el.querySelector(".field-emoji-button")
    this.popup = this.el.querySelector(".emoji-popup")
    this.picker = null

    // Start loading early, so the data is there by the first click or `:`.
    this.load = () => loadEmoji().catch(() => {})
    this.input.addEventListener("focus", this.load)
    this.button.addEventListener("pointerenter", this.load)

    this.button.addEventListener("click", () => (this.popup.hidden ? this.open() : this.close()))

    // While the popup is open, its keys stay in it: Escape closes it, not
    // the event panel (`phx-window-keydown`). Its search box's `input`
    // events would otherwise reach the form's `phx-change`.
    this.popup.addEventListener("keydown", (event) => {
      event.stopPropagation()
      if (event.key === "Escape") {
        event.preventDefault()
        this.close()
      }
    })
    this.popup.addEventListener("input", (event) => event.stopPropagation())
    this.popup.addEventListener("change", (event) => event.stopPropagation())

    this.outside = (event) => {
      if (!this.el.querySelector(".field-emoji-control").contains(event.target)) {
        this.close({refocus: false})
      }
    }
    this.focusOut = (event) => {
      if (event.relatedTarget && !this.el.contains(event.relatedTarget)) {
        this.close({refocus: false})
      }
    }
    this.popup.addEventListener("focusout", this.focusOut)
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.outside, true)
  },

  async open() {
    let data
    try {
      data = await loadEmoji()
    } catch {
      return
    }

    // Where the emoji goes: the caret or selection when the popup opened,
    // moved along as emoji are added with Shift.
    this.range = [this.input.selectionStart, this.input.selectionEnd]

    this.picker ??= new Picker(this.popup, data, {
      onPick: (emoji, keepOpen) => this.pick(emoji, keepOpen),
    })
    this.popup.hidden = false
    this.button.ariaExpanded = "true"
    this.picker.open()
    this.popup.scrollIntoView({block: "nearest"})
    document.addEventListener("pointerdown", this.outside, true)
  },

  close({refocus = true} = {}) {
    if (this.popup.hidden) return
    this.popup.hidden = true
    this.button.ariaExpanded = "false"
    document.removeEventListener("pointerdown", this.outside, true)

    if (refocus) {
      this.input.focus()
      this.input.setSelectionRange(...this.range)
    }
  },

  pick(emoji, keepOpen) {
    const [start, end] = this.range
    if (insert(this.input, emoji.char, start, end)) {
      const caret = start + emoji.char.length
      this.range = [caret, caret]
      rememberEmoji(emoji.char)
    }
    if (!keepOpen) this.close()
  },
}
