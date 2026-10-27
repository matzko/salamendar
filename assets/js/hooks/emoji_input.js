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
const SUGGEST_MAX = 8

// `:term` right before the caret, at the start of a word (so not `10:30`
// or `https://`), and `:name:` just closed.
const TERM = /(?:^|[\s([{"'])(:([a-z0-9_+-]{2,}))$/i
const CLOSED = /(?:^|[\s([{"'])(:([a-z0-9_+-]+):)$/i

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

// How well `name` matches `term`: 0 if it starts with it, 1 if a word in
// it does (`cake` in `birthday_cake`), 2 if it contains it, else 3.
const matchRank = (name, term) => {
  const at = name.indexOf(term)
  if (at === 0) return 0
  if (at > 0 && /[_-]/.test(name[at - 1])) return 1
  return at > 0 ? 2 : 3
}

// The name of `emoji` that best matches `term`.
export const matchedName = (emoji, term) =>
  emoji.names.reduce((best, name) => (matchRank(name, term) < matchRank(best, term) ? name : best))

// Emoji matching `term`, best match first. Within each rank, the chars in
// `first` (such as the frequently used ones) lead, then Slack's order.
export const search = (data, term, first = []) => {
  const groups = [[], [], []]

  for (const emoji of data.all) {
    const rank = Math.min(...emoji.names.map((name) => matchRank(name, term)))
    if (rank < 3) groups[rank].push(emoji)
  }

  const order = (emoji) => {
    const at = first.indexOf(emoji.char)
    return at < 0 ? Infinity : at
  }
  return groups.flatMap((group) => group.sort((a, b) => order(a) - order(b)))
}

// Where `position` in `textarea` is drawn, relative to the textarea's
// border box: a hidden copy with the same styles, measured up to there.
const MIRRORED = [
  "boxSizing", "width", "borderTopWidth", "borderRightWidth", "borderBottomWidth",
  "borderLeftWidth", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
  "fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "letterSpacing",
  "wordSpacing", "tabSize", "textIndent", "textTransform",
]

const caretCoordinates = (textarea, position) => {
  const style = getComputedStyle(textarea)
  const mirror = document.createElement("div")
  for (const property of MIRRORED) mirror.style[property] = style[property]
  Object.assign(mirror.style, {
    position: "absolute",
    visibility: "hidden",
    top: "0",
    left: "-9999px",
    whiteSpace: "pre-wrap",
    overflowWrap: "break-word",
  })

  mirror.textContent = textarea.value.slice(0, position)
  const marker = document.createElement("span")
  marker.textContent = "\u200b"
  mirror.append(marker)
  document.body.append(mirror)

  const lineHeight = marker.offsetHeight
  const coordinates = {
    top: marker.offsetTop - textarea.scrollTop + lineHeight,
    left: marker.offsetLeft - textarea.scrollLeft,
  }
  mirror.remove()
  return coordinates
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
      const matches = search(this.data, term, recentEmoji()).slice(0, SEARCH_MAX)
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
    this.list = this.el.querySelector(".emoji-suggest")
    this.picker = null
    this.suggestions = []

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

    // `:name` autocomplete. Not while an IME is composing: its text isn't
    // final until `compositionend`.
    this.input.addEventListener("input", (event) => event.isComposing || this.autocomplete())
    this.input.addEventListener("compositionend", () => this.autocomplete())
    this.input.addEventListener("click", () => this.autocomplete())
    this.input.addEventListener("keydown", (event) => this.suggestKeydown(event))
    this.input.addEventListener("blur", () => this.closeSuggest())
    // Rows take clicks without taking focus from the input.
    this.list.addEventListener("pointerdown", (event) => event.preventDefault())
    this.list.addEventListener("click", (event) => {
      const row = event.target.closest("[role=option]")
      if (row) this.choose(Number(row.dataset.index))
    })
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.outside, true)
  },

  async open() {
    this.closeSuggest()
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

  // Looks at the text before the caret: a closed `:name:` we know becomes
  // its emoji, and an open `:term` shows the list.
  async autocomplete() {
    const data = await loadEmoji().catch(() => null)
    const {input} = this
    const caret = input.selectionStart
    if (!data || document.activeElement !== input || caret !== input.selectionEnd) {
      return this.closeSuggest()
    }

    const before = input.value.slice(0, caret)
    const closed = before.match(CLOSED)
    const named = closed && data.byName.get(closed[2].toLowerCase())
    if (named) {
      this.closeSuggest()
      this.replace(caret - closed[1].length, caret, named)
      return
    }

    const open = before.match(TERM)
    const term = open?.[2].toLowerCase()
    const matches = open ? search(data, term, recentEmoji()).slice(0, SUGGEST_MAX) : []
    if (matches.length === 0) return this.closeSuggest()

    this.suggestStart = caret - open[1].length
    this.suggestions = matches
    this.drawSuggestions(term)
    this.select(0)
  },

  drawSuggestions(term) {
    const rows = this.suggestions.map((emoji, index) => {
      const name = matchedName(emoji, term)
      const at = name.indexOf(term)
      const label = element("span", {className: "emoji-suggestion-name"}, [
        `:${name.slice(0, at)}`,
        element("strong", {textContent: term}),
        `${name.slice(at + term.length)}:`,
      ])
      return element(
        "li",
        {id: `${this.list.id}-${index}`, role: "option", className: "emoji-suggestion"},
        [element("span", {className: "emoji-suggestion-char", textContent: emoji.char}), label],
      )
    })
    rows.forEach((row, index) => (row.dataset.index = index))
    const opening = this.list.hidden
    this.list.replaceChildren(...rows)
    this.list.hidden = false
    this.input.ariaExpanded = "true"
    this.placeSuggestions()
    // Only when it opens, so the page doesn't jump while typing.
    if (opening) this.list.scrollIntoView({block: "nearest"})
  },

  // Under the line being typed on: the input's bottom, or in a textarea,
  // under the `:` (kept inside the field).
  placeSuggestions() {
    const {input, list} = this
    let top = input.offsetTop + input.offsetHeight
    let left = input.offsetLeft

    if (input.tagName === "TEXTAREA") {
      const caret = caretCoordinates(input, this.suggestStart)
      top = input.offsetTop + Math.min(caret.top, input.clientHeight)
      left = input.offsetLeft + caret.left
    }

    const maxLeft = input.offsetLeft + input.offsetWidth - list.offsetWidth
    list.style.top = `${top + 2}px`
    list.style.left = `${Math.max(input.offsetLeft, Math.min(left, maxLeft))}px`
  },

  select(index) {
    const count = this.suggestions.length
    this.active = (index + count) % count
    for (const row of this.list.children) {
      row.ariaSelected = String(Number(row.dataset.index) === this.active)
    }
    const row = this.list.children[this.active]
    this.input.setAttribute("aria-activedescendant", row.id)
    row.scrollIntoView({block: "nearest"})
  },

  choose(index) {
    const emoji = this.suggestions[index]
    const end = this.input.selectionStart
    this.closeSuggest()
    this.replace(this.suggestStart, end, emoji)
  },

  closeSuggest() {
    if (this.list.hidden) return
    this.list.hidden = true
    this.suggestions = []
    this.input.ariaExpanded = "false"
    this.input.removeAttribute("aria-activedescendant")
  },

  // While the list is open: Up/Down move, Enter or Tab picks, Escape closes.
  // Those keys go no further: Enter doesn't submit the form, and Escape
  // doesn't close the event panel (`phx-window-keydown`).
  suggestKeydown(event) {
    if (this.list.hidden || event.isComposing) return

    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp":
        this.select(this.active + (event.key === "ArrowDown" ? 1 : -1))
        break
      case "Enter":
      case "Tab":
        this.choose(this.active)
        break
      case "Escape":
        this.closeSuggest()
        break
      case "ArrowLeft":
      case "ArrowRight":
      case "Home":
      case "End":
        this.closeSuggest()
        return
      default:
        return
    }

    event.preventDefault()
    event.stopPropagation()
  },

  replace(start, end, emoji) {
    if (insert(this.input, emoji.char, start, end)) rememberEmoji(emoji.char)
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
