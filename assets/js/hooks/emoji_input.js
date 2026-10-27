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
      return {categories, all, byName}
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

export const EmojiInput = {
  mounted() {
    this.input = this.el.querySelector("input, textarea")
    this.button = this.el.querySelector(".field-emoji-button")
    this.popup = this.el.querySelector(".emoji-popup")

    // Start loading early, so the data is there by the first click or `:`.
    this.load = () => loadEmoji().catch(() => {})
    this.input.addEventListener("focus", this.load)
    this.button.addEventListener("pointerenter", this.load)
  },
}
