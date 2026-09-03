.pragma library

// Everything the Control Centre decides that does not need a shell, a
// compositor or a device: the tile catalogue, the settings file, the grid
// layout and the keyboard cursor. Pure functions over plain data, so the
// qmltestrunner suite can reach all of it.

var SETTINGS_VERSION = 1
var MAX_STATE_BYTES = 65536
var COLUMNS = 4
var POSITIONS = ["bar-end", "centre"]
var DENSITIES = ["comfortable", "compact"]
var PROFILES = ["power-saver", "balanced", "performance"]

// The catalogue. This is the whole vocabulary of the card: what a tile is
// called, what shape it takes, which group it belongs to in edit mode, and
// whether a fresh install shows it. Order here is the default tile order.
//
//   kind      toggle | action | slider | power | media | actions | session
//             | theme | warmth | option | header
//   span      grid columns out of COLUMNS
//   category  the group it appears under in edit mode
//   on        whether a fresh install shows it
//
// A tile being in this list does not mean it appears: `gridIds` also asks
// whether the machine can back it, so a laptop-only control is absent on a
// desktop rather than dead on it.
var TILES = [
  // Connectivity
  { id: "wifi",       kind: "toggle", span: 1, section: "toggles", category: "connectivity", label: "Wi-Fi",       on: true },
  { id: "bluetooth",  kind: "toggle", span: 1, section: "toggles", category: "connectivity", label: "Bluetooth",   on: true },

  // Focus
  { id: "dnd",        kind: "toggle", span: 1, section: "toggles", category: "focus", label: "Do Not Disturb", on: true },
  { id: "stayawake",  kind: "toggle", span: 1, section: "toggles", category: "focus", label: "Stay Awake",     on: true },
  { id: "nightlight", kind: "toggle", span: 1, section: "toggles", category: "display", label: "Night Light",  on: true },
  { id: "mic",        kind: "toggle", span: 1, section: "toggles", category: "sound", label: "Microphone",     on: true },
  { id: "recording",  kind: "toggle", span: 1, section: "toggles", category: "capture", label: "Recording",    on: true },

  // One-shot actions, the things the Omarchy menu calls triggers.
  { id: "screenshot", kind: "action", span: 1, section: "toggles", category: "capture", label: "Screenshot",   on: true },
  { id: "colour",     kind: "action", span: 1, section: "toggles", category: "capture", label: "Color Picker", on: true },
  { id: "text",       kind: "action", span: 1, section: "toggles", category: "capture", label: "Grab Text",    on: false },
  { id: "qr",         kind: "action", span: 1, section: "toggles", category: "capture", label: "Scan QR",      on: false },
  { id: "emoji",      kind: "action", span: 1, section: "toggles", category: "tools", label: "Emoji",          on: true },
  { id: "clipboard",  kind: "action", span: 1, section: "toggles", category: "tools", label: "Clipboard",      on: true },
  { id: "reminder",   kind: "action", span: 1, section: "toggles", category: "tools", label: "Reminder",       on: false },
  { id: "share",      kind: "action", span: 1, section: "toggles", category: "tools", label: "Share",          on: false },
  { id: "transcode",  kind: "action", span: 1, section: "toggles", category: "tools", label: "Transcode",      on: false },
  { id: "netspeed",   kind: "action", span: 1, section: "toggles", category: "tools", label: "Net Speed",      on: false },
  { id: "diskspeed",  kind: "action", span: 1, section: "toggles", category: "tools", label: "Disk Speed",     on: false },

  // Desktop toggles, all flag-file backed.
  { id: "bar",        kind: "toggle", span: 1, section: "toggles", category: "desktop", label: "Menu Bar",     on: false },
  { id: "gaps",       kind: "toggle", span: 1, section: "toggles", category: "desktop", label: "Window Gaps",  on: false },
  { id: "ratio",      kind: "toggle", span: 1, section: "toggles", category: "desktop", label: "Square Ratio", on: false },
  { id: "layout",     kind: "toggle", span: 1, section: "toggles", category: "desktop", label: "Scrolling",    on: false },
  { id: "screensaver", kind: "toggle", span: 1, section: "toggles", category: "focus", label: "Screensaver",   on: false },
  { id: "crashcapture", kind: "toggle", span: 1, section: "toggles", category: "focus", label: "Crash Capture", on: false },

  // Hardware, each hidden unless the machine has the part.
  { id: "touchpad",   kind: "toggle", span: 1, section: "toggles", category: "hardware", label: "Touchpad",    on: false },
  { id: "touchscreen", kind: "toggle", span: 1, section: "toggles", category: "hardware", label: "Touchscreen", on: false },
  { id: "laptopdisplay", kind: "toggle", span: 1, section: "toggles", category: "hardware", label: "Laptop Screen", on: false },
  { id: "mirror",     kind: "toggle", span: 1, section: "toggles", category: "hardware", label: "Mirror",      on: false },
  { id: "hybridgpu",  kind: "action", span: 1, section: "toggles", category: "hardware", label: "Hybrid GPU",  on: false },

  // Sliders and wide rows.
  { id: "volume",     kind: "slider", span: 4, section: "sliders", category: "sound",   label: "Volume",      on: true },
  { id: "miclevel",   kind: "slider", span: 4, section: "sliders", category: "sound",   label: "Mic Level",   on: false },
  { id: "brightness", kind: "slider", span: 4, section: "sliders", category: "display", label: "Brightness",  on: true },
  { id: "warmth",     kind: "warmth", span: 4, section: "sliders", category: "display", label: "Warmth",      on: false },
  { id: "theme",      kind: "theme",  span: 4, section: "sliders", category: "desktop", label: "Theme",       on: false },
  { id: "power",      kind: "power",  span: 4, section: "power",   category: "power",   label: "Power",       on: true },
  { id: "media",      kind: "media",  span: 4, section: "media",   category: "media",   label: "Media",       on: true },
  { id: "actions",    kind: "actions", span: 4, section: "actions", category: "system", label: "Lock, Sleep, Screensaver", on: true },
  { id: "session",    kind: "session", span: 4, section: "actions", category: "system", label: "Log Out, Restart, Shut Down", on: false }
]

// Group headings in edit mode, in the order they appear.
var CATEGORIES = [
  { id: "connectivity", label: "Connectivity" },
  { id: "sound",        label: "Sound" },
  { id: "display",      label: "Display" },
  { id: "focus",        label: "Focus" },
  { id: "capture",      label: "Capture" },
  { id: "tools",        label: "Tools" },
  { id: "desktop",      label: "Desktop" },
  { id: "hardware",     label: "Hardware" },
  { id: "power",        label: "Power" },
  { id: "media",        label: "Media" },
  { id: "system",       label: "System" },
  { id: "settings",     label: "Settings" },
  { id: "card",         label: "On your card" }
]

// Edit mode groups the catalogue under headings. A heading is a cell in the
// same grid so it scrolls and lays out with everything else, but the cursor
// steps over it: there is nothing to activate on a label.
var HEADER_PREFIX = "header:"

function isHeader(id) {
  return String(id).indexOf(HEADER_PREFIX) === 0
}

function headerFor(category) {
  return HEADER_PREFIX + category
}

function headerLabel(id) {
  return categoryLabel(String(id).substring(HEADER_PREFIX.length))
}

function isFocusable(id) {
  return !isHeader(id)
}

// Every one-shot tile's command, as a literal argument vector. Nothing is
// built from user input and nothing reaches a shell, so the only commands
// this plugin can ever run are the ones written here.
var ACTIONS = {
  screenshot:  ["omarchy-capture-screenshot"],
  colour:      ["hyprpicker", "-a"],
  text:        ["omarchy-capture-text"],
  qr:          ["omarchy-capture-qr"],
  reminder:    ["omarchy-reminder", "-i"],
  share:       ["omarchy-menu-share", "file"],
  transcode:   ["omarchy-transcode"],
  hybridgpu:   ["omarchy-launch-floating-terminal-with-presentation", "omarchy-toggle-hybrid-gpu"],
  lock:        ["omarchy-system-lock"],
  sleep:       ["systemctl", "suspend"],
  hibernate:   ["systemctl", "hibernate"],
  screensaver: ["omarchy-launch-screensaver", "force"],
  logout:      ["omarchy-system-logout"],
  reboot:      ["omarchy-system-reboot"],
  shutdown:    ["omarchy-system-shutdown"]
}

// Tiles whose action is another shell plugin. Summoning one costs no
// subprocess at all and does not depend on PATH, so anything the shell
// already hosts goes through here rather than through ACTIONS.
var SUMMONS = {
  emoji:     "omarchy.emojis",
  clipboard: "omarchy.clipboard",
  netspeed:  "omarchy.speedtest",
  diskspeed: "omarchy.disk-speedtest"
}

// The glyph each tile wears. Every one is the glyph the Omarchy menu or bar
// already uses for the same thing, so a user recognises it rather than
// learning a second vocabulary.
var GLYPHS = {
  screenshot: "", colour: "󰃉", text: "󰴑", qr: "󰐲",
  emoji: "", clipboard: "", reminder: "󰢌", share: "",
  transcode: "󰧸", netspeed: "󰓅", diskspeed: "󰋊",
  hybridgpu: "", bar: "󰍜", gaps: "", ratio: "",
  layout: "󱂬", screensaver: "󱄄", crashcapture: "󱚡",
  touchpad: "󰟸", touchscreen: "󰆽", laptopdisplay: "󰛧",
  mirror: "󰍹", theme: "", warmth: "󰔎", miclevel: "󰍬"
}

function glyphOf(id) {
  return GLYPHS[String(id)] || ""
}

// A copy, so a caller cannot edit the table it just read from.
function actionCommand(id) {
  var argv = ACTIONS[String(id)]
  if (!argv) return null
  return argv.slice()
}

function actionSummon(id) {
  return SUMMONS[String(id)] || ""
}

// Edit mode appends these below the catalogue. They ride the same grid and
// cursor so one keyboard model covers the whole card.
var OPTIONS = [
  { id: "opt-keybind",  kind: "option", span: 4, section: "options", category: "settings", label: "Keyboard shortcut", on: true },
  { id: "opt-position", kind: "option", span: 4, section: "options", category: "settings", label: "Position", on: true },
  { id: "opt-density",  kind: "option", span: 4, section: "options", category: "settings", label: "Density", on: true },
  { id: "opt-motion",   kind: "option", span: 4, section: "options", category: "settings", label: "Reduce motion", on: true },
  { id: "opt-pill",     kind: "option", span: 4, section: "options", category: "settings", label: "Bar pill", on: true },
  { id: "opt-reset",    kind: "option", span: 4, section: "options", category: "settings", label: "Reset arrangement", on: true }
]

var _byId = null
function tileById(id) {
  if (!_byId) {
    _byId = {}
    for (var i = 0; i < TILES.length; i++) _byId[TILES[i].id] = TILES[i]
    for (var j = 0; j < OPTIONS.length; j++) _byId[OPTIONS[j].id] = OPTIONS[j]
  }
  return _byId[String(id)] || null
}

function tileIds() {
  var out = []
  for (var i = 0; i < TILES.length; i++) out.push(TILES[i].id)
  return out
}

function categoryOf(id) {
  var t = tileById(id)
  return t ? (t.category || "") : ""
}

function defaultEnabled(id) {
  var t = tileById(id)
  return t ? t.on === true : false
}

function categoryLabel(id) {
  for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].id === id) return CATEGORIES[i].label
  return String(id)
}

function kindOf(id) {
  if (isHeader(id)) return "header"
  var t = tileById(id)
  return t ? t.kind : ""
}

function spanOf(id) {
  if (isHeader(id)) return COLUMNS
  var t = tileById(id)
  return t ? t.span : 1
}

function sectionOf(id) {
  if (isHeader(id)) return "headers"
  var t = tileById(id)
  return t ? t.section : ""
}

function labelOf(id) {
  if (isHeader(id)) return headerLabel(id)
  var t = tileById(id)
  return t ? t.label : String(id)
}

// ------------------------------------------------------------------ settings

function defaultSettings() {
  var tiles = []
  for (var i = 0; i < TILES.length; i++) tiles.push({ id: TILES[i].id, enabled: TILES[i].on === true })
  return {
    version: SETTINGS_VERSION,
    tiles: tiles,
    position: "bar-end",
    density: "comfortable",
    reduceMotion: false,
    barWidget: true,
    hintSeen: false
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// The state file is untrusted input: it lives where anything running as the
// user can write. Every field is rebuilt with its own bound; anything that
// does not fit is dropped rather than trusted, and the caller is told why so
// it can say so once. Unknown tile ids are dropped, known ones missing from
// the file are appended enabled, so a newer plugin never loses a tile to an
// older file.
function parseSettings(raw) {
  var settings = defaultSettings()
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.length === 0) return { settings: settings, rejected: "" }
  if (text.length > MAX_STATE_BYTES) return { settings: settings, rejected: "settings file too large" }

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { settings: settings, rejected: "settings file is not valid JSON" }
  }
  if (!isPlainObject(parsed)) return { settings: settings, rejected: "settings file is not an object" }
  if (typeof parsed.rejected === "string") return { settings: settings, rejected: parsed.rejected.slice(0, 120) }

  var seen = {}
  var tiles = []
  if (Array.isArray(parsed.tiles)) {
    for (var i = 0; i < parsed.tiles.length && i < 64; i++) {
      var entry = parsed.tiles[i]
      var id = isPlainObject(entry) ? String(entry.id || "") : (typeof entry === "string" ? entry : "")
      if (!tileById(id) || kindOf(id) === "option" || seen[id]) continue
      seen[id] = true
      tiles.push({ id: id, enabled: !(isPlainObject(entry) && entry.enabled === false) })
    }
  }
  // A tile the file has never heard of is new since it was written, so it
  // arrives at the default a fresh install would give it rather than on.
  for (var j = 0; j < TILES.length; j++) {
    if (!seen[TILES[j].id]) tiles.push({ id: TILES[j].id, enabled: TILES[j].on === true })
  }
  settings.tiles = tiles

  if (POSITIONS.indexOf(parsed.position) !== -1) settings.position = parsed.position
  if (DENSITIES.indexOf(parsed.density) !== -1) settings.density = parsed.density
  // Present but not exactly `true` means false; absent means the default
  // stands. Those are different answers whenever a default is true.
  if (parsed.reduceMotion !== undefined) settings.reduceMotion = parsed.reduceMotion === true
  if (parsed.barWidget !== undefined) settings.barWidget = parsed.barWidget === true
  if (parsed.hintSeen !== undefined) settings.hintSeen = parsed.hintSeen === true
  return { settings: settings, rejected: "" }
}

function serializeSettings(settings) {
  var s = settings || defaultSettings()
  var tiles = []
  for (var i = 0; i < s.tiles.length; i++) tiles.push({ id: s.tiles[i].id, enabled: s.tiles[i].enabled === true })
  return JSON.stringify({
    version: SETTINGS_VERSION,
    tiles: tiles,
    position: POSITIONS.indexOf(s.position) !== -1 ? s.position : "bar-end",
    density: DENSITIES.indexOf(s.density) !== -1 ? s.density : "comfortable",
    reduceMotion: s.reduceMotion === true,
    barWidget: s.barWidget === true,
    hintSeen: s.hintSeen === true
  }, null, 2) + "\n"
}

function cloneSettings(settings) {
  return parseSettings(serializeSettings(settings)).settings
}

function tileEnabled(settings, id) {
  var tiles = settings && settings.tiles ? settings.tiles : []
  for (var i = 0; i < tiles.length; i++) if (tiles[i].id === id) return tiles[i].enabled === true
  return defaultEnabled(id)
}

// Every control back where it shipped, and nothing else touched: the
// arrangement is the thing someone can spend two minutes making worse, and
// the only way back was once to quit and delete the state file. The settings
// rows and the keyboard shortcut are not part of an arrangement, so a reset
// leaves them where they are.
function withDefaultTiles(settings) {
  var next = cloneSettings(settings)
  next.tiles = defaultSettings().tiles
  return next
}

function withTileEnabled(settings, id, enabled) {
  var next = cloneSettings(settings)
  for (var i = 0; i < next.tiles.length; i++) if (next.tiles[i].id === id) next.tiles[i].enabled = enabled === true
  return next
}

// Moves a tile one place along, past the next tile that is shown the same way
// it is. Stepping one slot in the raw list would hop over hidden tiles and
// look like nothing happened, since edit mode only ever shows the shown ones
// next to each other.
function withTileMoved(settings, id, delta) {
  var next = cloneSettings(settings)
  var index = -1
  for (var i = 0; i < next.tiles.length; i++) if (next.tiles[i].id === id) index = i
  if (index < 0) return next
  var step = delta < 0 ? -1 : 1
  var mine = next.tiles[index].enabled === true
  var target = index + step
  while (target >= 0 && target < next.tiles.length && (next.tiles[target].enabled === true) !== mine) target += step
  if (target < 0 || target >= next.tiles.length) return next
  var entry = next.tiles.splice(index, 1)[0]
  next.tiles.splice(target, 0, entry)
  return next
}

// Puts `id` immediately before or after `anchorId`. This is what a drop
// applies: the two ends of it are tiles, never slot numbers, because the list
// shifts as soon as anything moves.
function withTileMovedNextTo(settings, id, anchorId, after) {
  if (!id || !anchorId || id === anchorId) return cloneSettings(settings)
  var next = cloneSettings(settings)
  var from = -1
  for (var i = 0; i < next.tiles.length; i++) if (next.tiles[i].id === id) from = i
  if (from < 0) return next
  var entry = next.tiles.splice(from, 1)[0]
  var to = -1
  for (var j = 0; j < next.tiles.length; j++) if (next.tiles[j].id === anchorId) to = j
  if (to < 0) { next.tiles.splice(from, 0, entry); return next }
  // A tile takes the company it is dropped into: landing next to something on
  // the card puts it on the card, and landing among the hidden ones takes it
  // off. That is the whole gesture, in both directions.
  entry.enabled = tileEnabled(settings, anchorId)
  next.tiles.splice(after === true ? to + 1 : to, 0, entry)
  return next
}

// Switching a tile on from the gallery lands it at the end of the card,
// which is somewhere the user can predict and then drag from.
function withTileShown(settings, id) {
  var next = cloneSettings(settings)
  var from = -1
  for (var i = 0; i < next.tiles.length; i++) if (next.tiles[i].id === id) from = i
  if (from < 0) return next
  var entry = next.tiles.splice(from, 1)[0]
  entry.enabled = true
  var last = -1
  for (var j = 0; j < next.tiles.length; j++) if (next.tiles[j].enabled === true) last = j
  next.tiles.splice(last + 1, 0, entry)
  return next
}

function withOption(settings, key, value) {
  var next = cloneSettings(settings)
  if (key === "position") next.position = POSITIONS.indexOf(value) !== -1 ? value : next.position
  else if (key === "density") next.density = DENSITIES.indexOf(value) !== -1 ? value : next.density
  else if (key === "reduceMotion") next.reduceMotion = value === true
  else if (key === "barWidget") next.barWidget = value === true
  else if (key === "hintSeen") next.hintSeen = value === true
  return next
}

function nextPosition(position) {
  var index = POSITIONS.indexOf(position)
  return POSITIONS[(index + 1) % POSITIONS.length]
}

function nextDensity(density) {
  var index = DENSITIES.indexOf(density)
  return DENSITIES[(index + 1) % DENSITIES.length]
}

// ---------------------------------------------------------------------- grid

// The ids the grid shows. `available` says which tiles this machine can back
// (no adapter, no backlight, no media: not shown). Normal mode hides disabled
// tiles; edit mode shows every available tile so a disabled one can be turned
// back on, then the option rows.
function gridIds(settings, available, editing) {
  var tiles = settings && settings.tiles ? settings.tiles : []
  if (!editing) {
    var out = []
    for (var i = 0; i < tiles.length; i++) {
      var id = tiles[i].id
      if (!available || available[id] !== true) continue
      if (tiles[i].enabled !== true) continue
      out.push(id)
    }
    return out
  }

  // Edit mode shows the card first, in the order the card uses, because that
  // is the thing being arranged: a gallery sorted by category cannot show
  // what moving a control would do. Everything still available to add sits
  // under it, grouped so a long catalogue stays findable.
  var grouped = []
  var shown = []
  for (var e = 0; e < tiles.length; e++) {
    var shownId = tiles[e].id
    if (!available || available[shownId] !== true) continue
    if (tiles[e].enabled !== true) continue
    shown.push(shownId)
  }
  if (shown.length > 0) {
    grouped.push(headerFor("card"))
    for (var sIdx = 0; sIdx < shown.length; sIdx++) grouped.push(shown[sIdx])
  }
  for (var c = 0; c < CATEGORIES.length; c++) {
    var category = CATEGORIES[c].id
    if (category === "settings" || category === "card") continue
    var members = []
    for (var t = 0; t < tiles.length; t++) {
      var tileId = tiles[t].id
      if (!available || available[tileId] !== true) continue
      if (tiles[t].enabled === true) continue
      if (categoryOf(tileId) !== category) continue
      members.push(tileId)
    }
    if (members.length === 0) continue
    grouped.push(headerFor(category))
    for (var mIdx = 0; mIdx < members.length; mIdx++) grouped.push(members[mIdx])
  }
  grouped.push(headerFor("settings"))
  for (var o = 0; o < OPTIONS.length; o++) grouped.push(OPTIONS[o].id)
  return grouped
}

// Places ids left to right, top to bottom, on a COLUMNS-wide grid. A tile
// that does not fit on the current row starts the next one. Returns pixel
// geometry so the QML side only has to assign x/y/width/height.
//
//   heights: kind -> row height in px
//   returns { cells: [{ id, col, row, span, x, y, width, height }], height }
function layout(ids, cellWidth, gap, heights) {
  var cells = []
  var col = 0
  var row = 0
  var rowHeights = []
  for (var i = 0; i < ids.length; i++) {
    var id = ids[i]
    var span = Math.max(1, Math.min(COLUMNS, spanOf(id)))
    if (col + span > COLUMNS) { col = 0; row += 1 }
    var height = heights[kindOf(id)] || heights.toggle || 0
    rowHeights[row] = Math.max(rowHeights[row] || 0, height)
    cells.push({ id: id, col: col, row: row, span: span })
    col += span
    if (col >= COLUMNS) { col = 0; row += 1 }
  }
  var y = 0
  var rowY = []
  for (var r = 0; r < rowHeights.length; r++) {
    rowY[r] = y
    y += rowHeights[r] + gap
  }
  for (var c = 0; c < cells.length; c++) {
    var cell = cells[c]
    cell.x = cell.col * (cellWidth + gap)
    cell.y = rowY[cell.row]
    cell.width = cell.span * cellWidth + (cell.span - 1) * gap
    cell.height = rowHeights[cell.row]
  }
  return { cells: cells, height: Math.max(0, y - gap) }
}

// -------------------------------------------------------------------- cursor

// Reading order left/right; up/down keeps the column. A row is chosen by
// stepping row numbers so an empty final cell never traps the cursor, and the
// landing cell is whichever one covers the current column, else the nearest.
function moveCursor(cells, index, dx, dy) {
  if (!cells || cells.length === 0) return -1
  if (index < 0 || index >= cells.length) return firstFocusableCell(cells)
  if (dx !== 0) {
    // Step over headings rather than landing on them.
    var next = index + dx
    while (next >= 0 && next < cells.length && !isFocusable(cells[next].id)) next += dx
    return next >= 0 && next < cells.length ? next : index
  }
  if (dy === 0) return index
  var current = cells[index]
  var maxRow = 0
  for (var i = 0; i < cells.length; i++) maxRow = Math.max(maxRow, cells[i].row)
  // Walk whole rows, so a row that holds only a heading is passed through
  // instead of stopping the cursor dead.
  var targetRow = current.row + dy
  while (targetRow >= 0 && targetRow <= maxRow) {
    var best = -1
    var bestDistance = Infinity
    for (var j = 0; j < cells.length; j++) {
      var cell = cells[j]
      if (cell.row !== targetRow || !isFocusable(cell.id)) continue
      var distance
      if (current.col >= cell.col && current.col < cell.col + cell.span) distance = 0
      else distance = Math.min(Math.abs(current.col - cell.col), Math.abs(current.col - (cell.col + cell.span - 1)))
      if (distance < bestDistance) { best = j; bestDistance = distance }
    }
    if (best >= 0) return best
    targetRow += dy
  }
  return index
}

// Which cell a point lands in, or null. The dragged tile is painted away from
// its slot, so asking what is under the pointer would answer with the thing
// being carried; the slots are the truth.
function cellAt(cells, x, y) {
  if (!cells) return null
  for (var i = 0; i < cells.length; i++) {
    var cell = cells[i]
    if (x < cell.x || x > cell.x + cell.width) continue
    if (y < cell.y || y > cell.y + cell.height) continue
    return cell
  }
  return null
}

function cellsInRow(cells, row) {
  var out = []
  for (var i = 0; i < cells.length; i++) {
    if (cells[i].row === row && isFocusable(cells[i].id)) out.push(cells[i])
  }
  return out
}

// Where a drop would put the tile being dragged. An insertion point, not a
// swap: tiles are different widths, and "put it where that one is" has no
// meaning when a full-width row and a quarter-width square trade places.
//
// The rule follows the shape of the grid. A full-width block occupies a whole
// row, so it can only ever go above or below something, never beside it; the
// same is true of anything dropped onto one. Two narrow tiles can sit side by
// side, so between them the answer is left or right. Which side is decided by
// the half of the target the pointer is in.
//
// Returns null when the point is over nothing that can take a drop, so the
// caller can keep the last real answer rather than flickering; { self: true }
// when the pointer is back over the dragged tile's own slot; otherwise an
// anchor to insert next to, and the line to draw for it.
function dropPlan(cells, x, y, draggedId, gap, gridWidth) {
  var cell = cellAt(cells, x, y)
  if (!cell) return null
  if (cell.id === String(draggedId)) return { self: true }
  if (!isFocusable(cell.id) || kindOf(cell.id) === "option") return null

  var thickness = Math.max(2, Math.round(gap / 2))
  var draggedWide = spanOf(draggedId) >= COLUMNS
  var targetWide = cell.span >= COLUMNS

  if (draggedWide || targetWide) {
    var above = y < cell.y + cell.height / 2
    var row = cellsInRow(cells, cell.row)
    if (row.length === 0) return null
    var anchor = above ? row[0] : row[row.length - 1]
    var edge = above ? cell.y - gap / 2 : cell.y + cell.height + gap / 2
    return {
      anchorId: anchor.id,
      after: !above,
      vertical: false,
      indicator: {
        x: 0,
        y: Math.round(edge - thickness / 2),
        width: gridWidth,
        height: thickness
      }
    }
  }

  var left = x < cell.x + cell.width / 2
  var lineX = left ? cell.x - gap / 2 : cell.x + cell.width + gap / 2
  return {
    anchorId: cell.id,
    after: !left,
    vertical: true,
    indicator: {
      x: Math.round(lineX - thickness / 2),
      y: cell.y,
      width: thickness,
      height: cell.height
    }
  }
}

function firstFocusableCell(cells) {
  for (var i = 0; i < cells.length; i++) if (isFocusable(cells[i].id)) return i
  return -1
}

// Tab walks sections, wrapping, landing on the first cell of the next
// section that has one.
function moveSection(ids, index, direction) {
  if (!ids || ids.length === 0) return -1
  var starts = []
  var lastSection = null
  for (var i = 0; i < ids.length; i++) {
    if (!isFocusable(ids[i])) continue
    var section = sectionOf(ids[i])
    if (section !== lastSection) { starts.push(i); lastSection = section }
  }
  if (starts.length === 0) return 0
  var currentSection = index >= 0 && index < ids.length ? sectionOf(ids[index]) : null
  var position = -1
  for (var j = 0; j < starts.length; j++) if (sectionOf(ids[starts[j]]) === currentSection) position = j
  if (position < 0) return starts[0]
  var next = (position + direction + starts.length) % starts.length
  return starts[next]
}

// Digits 1 to 9 land on the nth toggle tile in the grid.
function toggleIndexForDigit(ids, digit) {
  var n = 0
  for (var i = 0; i < ids.length; i++) {
    if (kindOf(ids[i]) !== "toggle") continue
    n += 1
    if (n === digit) return i
  }
  return -1
}

// The cursor is stored as an index, but a tile's identity is its id. Probes
// finishing while the card is open add and remove tiles (a battery appears, a
// song starts, a monitor loses its backlight), and an index that quietly comes
// to mean a different tile is how Enter ends up flipping something the user
// never pointed at. Re-find the pinned tile; if it has genuinely gone, clamp.
function reindexCursor(ids, pinnedId, index) {
  if (!ids || ids.length === 0) return -1
  var found = ids.indexOf(String(pinnedId || ""))
  if (found >= 0 && isFocusable(ids[found])) return found
  var clamped = Math.max(0, Math.min(ids.length - 1, Number(index) || 0))
  if (isFocusable(ids[clamped])) return clamped
  for (var i = clamped; i < ids.length; i++) if (isFocusable(ids[i])) return i
  for (var j = clamped; j >= 0; j--) if (isFocusable(ids[j])) return j
  return -1
}

function firstIndexOfKind(ids, kind) {
  for (var i = 0; i < ids.length; i++) if (kindOf(ids[i]) === kind) return i
  for (var j = 0; j < ids.length; j++) if (isFocusable(ids[j])) return j
  return -1
}

// ---------------------------------------------------------------- formatting

function clampPercent(value, min) {
  var n = Number(value)
  var floor = min === undefined ? 0 : min
  if (!isFinite(n)) return floor
  return Math.max(floor, Math.min(100, Math.round(n)))
}

function stepPercent(current, delta, min) {
  return clampPercent(Number(current) + Number(delta), min)
}

// "AirPods Pro, Keyboard +2" within `max` names.
function joinNames(names, max) {
  var list = []
  for (var i = 0; i < (names || []).length; i++) {
    var name = String(names[i] || "").trim()
    if (name) list.push(name)
  }
  if (list.length === 0) return ""
  var limit = max === undefined ? 2 : max
  var shown = list.slice(0, limit).join(", ")
  return list.length > limit ? shown + " +" + (list.length - limit) : shown
}

// Elapsed seconds as m:ss or h:mm:ss.
function formatElapsed(seconds) {
  var n = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(n / 3600)
  var m = Math.floor((n % 3600) / 60)
  var s = n % 60
  var mm = (h > 0 && m < 10 ? "0" : "") + m
  var ss = (s < 10 ? "0" : "") + s
  return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
}

// `ps -o etimes=` prints one integer, possibly padded. Anything else is
// treated as unknown rather than as zero.
function parseElapsed(raw) {
  var match = String(raw || "").trim().match(/^(\d{1,9})$/)
  return match ? parseInt(match[1], 10) : -1
}

// pgrep prints one pid per line. Only the first is used and it has to look
// like a pid before it is ever placed in an argv.
function parsePid(raw) {
  var first = String(raw || "").split("\n")[0].trim()
  return /^\d{1,10}$/.test(first) ? first : ""
}

// `omarchy-powerprofiles-list --active-state` prints "name\t0|1" per line.
function parseProfiles(raw) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split("\t")
    var name = parts[0]
    if (PROFILES.indexOf(name) === -1) continue
    list.push(name)
    if (parts[1] === "1") active = name
  }
  return { profiles: list, active: active }
}

function profileGlyph(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function profileLabel(name) {
  if (name === "power-saver") return "Saver"
  if (name === "balanced") return "Balanced"
  if (name === "performance") return "Performance"
  return String(name || "")
}

// `omarchy-battery-status --shell` prints "key\tvalue" lines.
function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length && i < 64; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    var key = lines[i].substring(0, idx)
    if (!/^[a-z_]{1,32}$/.test(key)) continue
    next[key] = lines[i].substring(idx + 1).trim().slice(0, 64)
  }
  return next
}

// The battery line under the profile chips: "82% · 3h 10m left".
function batteryLine(present, percent, onBattery, info, fullyCharged) {
  if (!present) return ""
  var pct = clampPercent(percent * 100) + "%"
  var time = info && info.time ? String(info.time) : ""
  if (fullyCharged) return pct + " · Full"
  if (onBattery) return time ? pct + " · " + time + " left" : pct + " · On battery"
  return time ? pct + " · " + time + " to full" : pct + " · Charging"
}

function batteryGlyph(percent, onBattery, fullyCharged) {
  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor((Number(percent) || 0) * 10)))
  if (fullyCharged) return "󰂅"
  return onBattery ? defaultIcons[index] : chargingIcons[index]
}

function wifiGlyph(strength) {
  var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
  var index = Math.max(0, Math.min(4, Math.ceil(Number(strength) / 20) - 1))
  return icons[index]
}

function volumeGlyph(volume, muted, headphones) {
  if (muted) return "󰝟"
  if (headphones) return "󰋋"
  var v = Number(volume) || 0
  if (v >= 0.67) return "󰕾"
  if (v >= 0.34) return "󰖀"
  return "󰕿"
}

// Argument validation for the few subprocesses that take a value. Anything
// that fails here is refused before it reaches an argv.
function isMonitorName(value) {
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(String(value || ""))
}

function isNodeName(value) {
  return /^[A-Za-z0-9][A-Za-z0-9._:+-]{0,255}$/.test(String(value || ""))
}

function isNodeId(value) {
  return /^\d{1,10}$/.test(String(value))
}

function isProfile(value) {
  return PROFILES.indexOf(String(value)) !== -1
}

// ------------------------------------------------------------- keybinding
//
// Qt key codes to the names Hyprland writes in a binding. Numeric rather than
// Qt.Key_* so this stays a plain library the tests can load without a shell.
var KEY_NAMES = {
  0x5C: "BACKSLASH", 0x2F: "SLASH", 0x2E: "PERIOD", 0x2C: "COMMA",
  0x3B: "SEMICOLON", 0x27: "APOSTROPHE", 0x5B: "BRACKETLEFT",
  0x5D: "BRACKETRIGHT", 0x2D: "MINUS", 0x3D: "EQUAL", 0x60: "GRAVE",
  0x20: "SPACE", 0x01000004: "RETURN", 0x01000001: "TAB",
  0x01000003: "BACKSPACE", 0x01000007: "DELETE", 0x01000006: "INSERT",
  0x01000010: "HOME", 0x01000011: "END", 0x01000016: "PRIOR",
  0x01000017: "NEXT", 0x01000013: "UP", 0x01000015: "DOWN",
  0x01000012: "LEFT", 0x01000014: "RIGHT", 0x01000009: "PRINT"
}

// Hyprland's modifier bits, which is how a binding is compared to every other
// binding on the system.
var MOD_BITS = { SHIFT: 1, CTRL: 4, ALT: 8, SUPER: 64 }

// Modifier order in a written binding. Fixed, so the same combination always
// produces the same string and can be compared as one.
var MOD_ORDER = ["SUPER", "CTRL", "ALT", "SHIFT"]

// The number row is deliberately not offered. Hyprland reports its workspace
// bindings with an empty key name, so a digit combination cannot be checked
// against them, and "Super and a number" is a workspace switch on every
// Omarchy install. Refusing beats promising a check that cannot be made.
function isDigitKey(code) {
  return code >= 0x30 && code <= 0x39
}

function keyName(code) {
  var n = Number(code)
  if (n >= 0x41 && n <= 0x5A) return String.fromCharCode(n)
  if (n >= 0x01000030 && n <= 0x0100003B) return "F" + (n - 0x01000030 + 1)
  return KEY_NAMES[n] || ""
}

// mods is { super, ctrl, alt, shift }. Returns "" when the press cannot be a
// binding on its own: a bare key, or a modifier with nothing after it.
function buildCombo(mods, code) {
  var key = keyName(code)
  if (!key) return ""
  var m = mods || {}
  var parts = []
  if (m.super) parts.push("SUPER")
  if (m.ctrl) parts.push("CTRL")
  if (m.alt) parts.push("ALT")
  if (m.shift) parts.push("SHIFT")
  if (parts.length === 0) return ""
  parts.push(key)
  return parts.join(" + ")
}

// The one shape a combination may take, checked again by the writer before
// anything is put in a file.
function isValidCombo(combo) {
  var text = String(combo || "")
  if (!/^[A-Z0-9 +]{3,60}$/.test(text)) return false
  var parts = text.split(" + ")
  if (parts.length < 2) return false
  var key = parts.pop()
  var seen = {}
  for (var i = 0; i < parts.length; i++) {
    if (MOD_BITS[parts[i]] === undefined || seen[parts[i]]) return false
    seen[parts[i]] = true
  }
  if (key.length === 1) return key >= "A" && key <= "Z"
  if (/^F([1-9]|1[0-2])$/.test(key)) return true
  for (var name in KEY_NAMES) if (KEY_NAMES[name] === key) return true
  return false
}

function comboModmask(combo) {
  var parts = String(combo || "").split(" + ")
  var mask = 0
  for (var i = 0; i < parts.length - 1; i++) mask += MOD_BITS[parts[i]] || 0
  return mask
}

function comboKey(combo) {
  var parts = String(combo || "").split(" + ")
  return parts.length > 1 ? parts[parts.length - 1] : ""
}

// `hyprctl -j binds`, reduced to what a conflict check needs. A binding with
// no key name is one Hyprland will not tell us the key for, which is how the
// workspace switches appear; those are dropped rather than guessed at.
function parseBinds(raw) {
  var list = []
  var parsed
  try {
    parsed = JSON.parse(String(raw || "[]"))
  } catch (e) {
    return list
  }
  if (!Array.isArray(parsed)) return list
  for (var i = 0; i < parsed.length && i < 2000; i++) {
    var bind = parsed[i]
    if (!bind || typeof bind.key !== "string" || bind.key.length === 0) continue
    list.push({
      modmask: Number(bind.modmask) || 0,
      key: bind.key.toUpperCase(),
      description: typeof bind.description === "string" ? bind.description.slice(0, 80) : ""
    })
  }
  return list
}

// What already holds this combination, by name where Hyprland gives one.
function conflictFor(binds, combo) {
  var mask = comboModmask(combo)
  var key = comboKey(combo)
  for (var i = 0; i < (binds || []).length; i++) {
    if (binds[i].modmask !== mask || binds[i].key !== key) continue
    return binds[i].description || "another binding"
  }
  return ""
}

// This plugin's own binding, found by the description it writes.
function findOwnBind(binds, description) {
  for (var i = 0; i < (binds || []).length; i++) {
    if (binds[i].description !== description) continue
    var parts = []
    for (var m = 0; m < MOD_ORDER.length; m++) {
      if (binds[i].modmask & MOD_BITS[MOD_ORDER[m]]) parts.push(MOD_ORDER[m])
    }
    parts.push(binds[i].key)
    return parts.join(" + ")
  }
  return ""
}

function hintText() {
  return "Arrows move · Enter toggles · Shift+Enter opens the full panel · Esc closes"
}
