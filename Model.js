.pragma library

// Everything the Control Centre decides that does not need a shell, a
// compositor or a device: the tile catalogue, the settings file, the grid
// layout and the keyboard cursor. Pure functions over plain data, so the
// qmltestrunner suite can reach all of it.

var SETTINGS_VERSION = 1
var MAX_STATE_BYTES = 65536
var COLUMNS = 4
var POSITIONS = ["bar-end", "centre"]
var PROFILES = ["power-saver", "balanced", "performance"]

// The catalogue. Order here is the default tile order; `section` is what Tab
// walks between; `span` is grid columns out of COLUMNS.
var TILES = [
  { id: "wifi",       kind: "toggle",  span: 1, section: "toggles", label: "Wi-Fi" },
  { id: "bluetooth",  kind: "toggle",  span: 1, section: "toggles", label: "Bluetooth" },
  { id: "dnd",        kind: "toggle",  span: 1, section: "toggles", label: "Do Not Disturb" },
  { id: "nightlight", kind: "toggle",  span: 1, section: "toggles", label: "Night Light" },
  { id: "stayawake",  kind: "toggle",  span: 1, section: "toggles", label: "Stay Awake" },
  { id: "mic",        kind: "toggle",  span: 1, section: "toggles", label: "Microphone" },
  { id: "recording",  kind: "toggle",  span: 1, section: "toggles", label: "Recording" },
  { id: "volume",     kind: "slider",  span: 4, section: "sliders", label: "Volume" },
  { id: "brightness", kind: "slider",  span: 4, section: "sliders", label: "Brightness" },
  { id: "power",      kind: "power",   span: 4, section: "power",   label: "Power" },
  { id: "media",      kind: "media",   span: 4, section: "media",   label: "Media" },
  { id: "actions",    kind: "actions", span: 4, section: "actions", label: "Lock, Sleep, Screensaver" }
]

// Edit mode appends these below the tiles. They ride the same grid and cursor
// so one keyboard model covers the whole card.
var OPTIONS = [
  { id: "opt-position", kind: "option", span: 4, section: "options", label: "Position" },
  { id: "opt-motion",   kind: "option", span: 4, section: "options", label: "Reduce motion" },
  { id: "opt-pill",     kind: "option", span: 4, section: "options", label: "Bar pill" }
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

function kindOf(id) {
  var t = tileById(id)
  return t ? t.kind : ""
}

function spanOf(id) {
  var t = tileById(id)
  return t ? t.span : 1
}

function sectionOf(id) {
  var t = tileById(id)
  return t ? t.section : ""
}

function labelOf(id) {
  var t = tileById(id)
  return t ? t.label : String(id)
}

// ------------------------------------------------------------------ settings

function defaultSettings() {
  var tiles = []
  for (var i = 0; i < TILES.length; i++) tiles.push({ id: TILES[i].id, enabled: true })
  return {
    version: SETTINGS_VERSION,
    tiles: tiles,
    position: "bar-end",
    reduceMotion: false,
    barWidget: false,
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
  for (var j = 0; j < TILES.length; j++) {
    if (!seen[TILES[j].id]) tiles.push({ id: TILES[j].id, enabled: true })
  }
  settings.tiles = tiles

  if (POSITIONS.indexOf(parsed.position) !== -1) settings.position = parsed.position
  settings.reduceMotion = parsed.reduceMotion === true
  settings.barWidget = parsed.barWidget === true
  settings.hintSeen = parsed.hintSeen === true
  return { settings: settings, rejected: "" }
}

function serializeSettings(settings) {
  var s = settings || defaultSettings()
  var tiles = []
  for (var i = 0; i < s.tiles.length; i++) tiles.push({ id: s.tiles[i].id, enabled: s.tiles[i].enabled !== false })
  return JSON.stringify({
    version: SETTINGS_VERSION,
    tiles: tiles,
    position: POSITIONS.indexOf(s.position) !== -1 ? s.position : "bar-end",
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
  for (var i = 0; i < tiles.length; i++) if (tiles[i].id === id) return tiles[i].enabled !== false
  return true
}

function withTileEnabled(settings, id, enabled) {
  var next = cloneSettings(settings)
  for (var i = 0; i < next.tiles.length; i++) if (next.tiles[i].id === id) next.tiles[i].enabled = enabled === true
  return next
}

// Moves a tile by `delta` places in the order. Clamped, so moving the first
// tile left is a no-op rather than a wrap; the cursor follows the tile.
function withTileMoved(settings, id, delta) {
  var next = cloneSettings(settings)
  var index = -1
  for (var i = 0; i < next.tiles.length; i++) if (next.tiles[i].id === id) index = i
  if (index < 0) return next
  var target = Math.max(0, Math.min(next.tiles.length - 1, index + delta))
  if (target === index) return next
  var entry = next.tiles.splice(index, 1)[0]
  next.tiles.splice(target, 0, entry)
  return next
}

function withOption(settings, key, value) {
  var next = cloneSettings(settings)
  if (key === "position") next.position = POSITIONS.indexOf(value) !== -1 ? value : next.position
  else if (key === "reduceMotion") next.reduceMotion = value === true
  else if (key === "barWidget") next.barWidget = value === true
  else if (key === "hintSeen") next.hintSeen = value === true
  return next
}

function nextPosition(position) {
  var index = POSITIONS.indexOf(position)
  return POSITIONS[(index + 1) % POSITIONS.length]
}

// ---------------------------------------------------------------------- grid

// The ids the grid shows. `available` says which tiles this machine can back
// (no adapter, no backlight, no media: not shown). Normal mode hides disabled
// tiles; edit mode shows every available tile so a disabled one can be turned
// back on, then the option rows.
function gridIds(settings, available, editing) {
  var out = []
  var tiles = settings && settings.tiles ? settings.tiles : []
  for (var i = 0; i < tiles.length; i++) {
    var id = tiles[i].id
    if (!available || available[id] !== true) continue
    if (!editing && tiles[i].enabled === false) continue
    out.push(id)
  }
  if (editing) for (var j = 0; j < OPTIONS.length; j++) out.push(OPTIONS[j].id)
  return out
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
  if (index < 0 || index >= cells.length) return 0
  if (dx !== 0) return Math.max(0, Math.min(cells.length - 1, index + dx))
  if (dy === 0) return index
  var current = cells[index]
  var maxRow = 0
  for (var i = 0; i < cells.length; i++) maxRow = Math.max(maxRow, cells[i].row)
  var targetRow = current.row + dy
  if (targetRow < 0 || targetRow > maxRow) return index
  var best = -1
  var bestDistance = Infinity
  for (var j = 0; j < cells.length; j++) {
    var cell = cells[j]
    if (cell.row !== targetRow) continue
    var distance
    if (current.col >= cell.col && current.col < cell.col + cell.span) distance = 0
    else distance = Math.min(Math.abs(current.col - cell.col), Math.abs(current.col - (cell.col + cell.span - 1)))
    if (distance < bestDistance) { best = j; bestDistance = distance }
  }
  return best < 0 ? index : best
}

// Tab walks sections, wrapping, landing on the first cell of the next
// section that has one.
function moveSection(ids, index, direction) {
  if (!ids || ids.length === 0) return -1
  var starts = []
  var lastSection = null
  for (var i = 0; i < ids.length; i++) {
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
  if (found >= 0) return found
  return Math.max(0, Math.min(ids.length - 1, Number(index) || 0))
}

function firstIndexOfKind(ids, kind) {
  for (var i = 0; i < ids.length; i++) if (kindOf(ids[i]) === kind) return i
  return ids.length > 0 ? 0 : -1
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

function hintText() {
  return "Arrows move · Enter toggles · Shift+Enter opens the full panel · Esc closes"
}
