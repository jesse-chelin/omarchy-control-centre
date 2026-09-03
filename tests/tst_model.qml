import QtQuick
import QtTest
import "../Model.js" as Model

// Everything the Control Centre decides is in Model.js precisely so it can be
// tested without a shell, a compositor or a device.
TestCase {
  id: suite
  name: "ControlCentreModel"

  readonly property var allAvailable: ({
    wifi: true, bluetooth: true, dnd: true, nightlight: true, stayawake: true,
    mic: true, recording: true, volume: true, brightness: true, power: true,
    media: true, actions: true
  })

  // ---- settings are untrusted input ---------------------------------------

  function test_defaults_cover_every_tile() {
    var settings = Model.defaultSettings()
    compare(settings.tiles.length, Model.TILES.length)
    compare(settings.position, "bar-end")
    compare(settings.reduceMotion, false)
    compare(settings.barWidget, true, "the bar pill is on by default")
    compare(settings.hintSeen, false)
  }

  function test_parse_survives_garbage() {
    var cases = ["not json", "[]", "null", '"a string"', "42"]
    for (var i = 0; i < cases.length; i++) {
      var parsed = Model.parseSettings(cases[i])
      compare(parsed.settings.tiles.length, Model.TILES.length, "case " + cases[i])
      verify(parsed.rejected !== "", "case " + cases[i] + " should report a reason")
    }
  }

  function test_parse_empty_is_not_a_rejection() {
    var parsed = Model.parseSettings("")
    compare(parsed.rejected, "")
    compare(parsed.settings.position, "bar-end")
  }

  function test_parse_refuses_oversized_text() {
    var padding = new Array(70000).join("x")
    var parsed = Model.parseSettings('{"position":"centre","pad":"' + padding + '"}')
    compare(parsed.settings.position, "bar-end")
    verify(parsed.rejected.indexOf("too large") !== -1)
  }

  function test_parse_carries_a_reader_rejection_through() {
    var parsed = Model.parseSettings('{"rejected":"it is a symlink, which is never followed"}')
    compare(parsed.rejected, "it is a symlink, which is never followed")
    compare(parsed.settings.tiles.length, Model.TILES.length)
  }

  function test_parse_drops_unknown_tiles_and_appends_missing_ones() {
    var parsed = Model.parseSettings(JSON.stringify({
      tiles: [{ id: "made-up", enabled: true }, { id: "media", enabled: false }, { id: "media", enabled: true }]
    }))
    var ids = []
    for (var i = 0; i < parsed.settings.tiles.length; i++) ids.push(parsed.settings.tiles[i].id)
    compare(ids.indexOf("made-up"), -1, "an unknown id must not survive")
    compare(ids[0], "media", "an ordering from the file is kept")
    compare(ids.length, Model.TILES.length, "every known tile is present exactly once")
    compare(Model.tileEnabled(parsed.settings, "media"), false, "the first entry wins")
    compare(Model.tileEnabled(parsed.settings, "wifi"), true, "a tile missing from the file arrives enabled")
  }

  function test_parse_refuses_an_option_row_as_a_tile() {
    var parsed = Model.parseSettings(JSON.stringify({ tiles: [{ id: "opt-motion", enabled: true }] }))
    for (var i = 0; i < parsed.settings.tiles.length; i++)
      verify(parsed.settings.tiles[i].id.indexOf("opt-") !== 0)
  }

  function test_parse_clamps_scalars() {
    var parsed = Model.parseSettings(JSON.stringify({
      position: "somewhere-else", reduceMotion: "yes", barWidget: 1, hintSeen: null
    }))
    compare(parsed.settings.position, "bar-end", "an unknown position falls back")
    compare(parsed.settings.reduceMotion, false, "only a real true counts")
    compare(parsed.settings.barWidget, false)
    compare(parsed.settings.hintSeen, false)
  }

  function test_an_absent_key_keeps_its_default() {
    // Written before the key existed, or hand-edited down to one line.
    var parsed = Model.parseSettings('{"position":"centre"}')
    compare(parsed.settings.barWidget, true, "a default of true survives an absent key")
    compare(parsed.settings.reduceMotion, false)
    compare(parsed.settings.hintSeen, false)
    compare(parsed.settings.position, "centre")
  }

  function test_the_pill_can_be_turned_off_and_stays_off() {
    var settings = Model.withOption(Model.defaultSettings(), "barWidget", false)
    compare(settings.barWidget, false)
    compare(Model.parseSettings(Model.serializeSettings(settings)).settings.barWidget, false)
  }

  function test_settings_round_trip() {
    var settings = Model.defaultSettings()
    settings.position = "centre"
    settings.reduceMotion = true
    settings.hintSeen = true
    settings = Model.withTileEnabled(settings, "media", false)
    var back = Model.parseSettings(Model.serializeSettings(settings)).settings
    compare(back.position, "centre")
    compare(back.reduceMotion, true)
    compare(back.hintSeen, true)
    compare(Model.tileEnabled(back, "media"), false)
  }

  function test_move_is_clamped_not_wrapped() {
    var settings = Model.defaultSettings()
    var first = settings.tiles[0].id
    var second = settings.tiles[1].id
    var moved = Model.withTileMoved(settings, first, -1)
    compare(moved.tiles[0].id, first, "the first tile cannot move off the front")
    moved = Model.withTileMoved(settings, first, 1)
    compare(moved.tiles[0].id, second, "moving right puts it past its neighbour")
    compare(moved.tiles[1].id, first)
    compare(moved.tiles.length, settings.tiles.length, "nothing is lost in a move")
  }

  function test_move_steps_past_tiles_shown_the_same_way() {
    // wifi and dnd are on, and everything between them is hidden. Edit mode
    // draws them side by side, so one press has to swap them rather than
    // shuffling wifi past something invisible.
    var settings = Model.defaultSettings()
    settings = Model.withTileEnabled(settings, "bluetooth", false)
    var moved = Model.withTileMoved(settings, "wifi", 1)
    var order = []
    for (var i = 0; i < moved.tiles.length; i++) if (moved.tiles[i].enabled) order.push(moved.tiles[i].id)
    compare(order[0], "dnd", "wifi moved past the next shown tile")
    compare(order[1], "wifi")
    // The hidden tile is untouched by a move it was not part of.
    compare(Model.tileEnabled(moved, "bluetooth"), false)
    compare(moved.tiles.length, settings.tiles.length)
  }

  function test_a_drop_inserts_next_to_its_anchor() {
    var settings = Model.defaultSettings()
    var before = Model.withTileMovedNextTo(settings, "volume", "wifi", false)
    compare(before.tiles[0].id, "volume")
    compare(before.tiles[1].id, "wifi")
    var after = Model.withTileMovedNextTo(settings, "volume", "wifi", true)
    compare(after.tiles[0].id, "wifi")
    compare(after.tiles[1].id, "volume")
    compare(after.tiles.length, settings.tiles.length)
  }

  function test_a_tile_takes_the_company_it_is_dropped_into() {
    var settings = Model.defaultSettings()
    compare(Model.tileEnabled(settings, "qr"), false)
    var onto = Model.withTileMovedNextTo(settings, "qr", "wifi", false)
    compare(Model.tileEnabled(onto, "qr"), true, "landing on the card puts it on the card")
    var away = Model.withTileMovedNextTo(settings, "wifi", "transcode", false)
    compare(Model.tileEnabled(away, "wifi"), false, "landing among the hidden takes it off")
  }

  function test_a_drop_that_goes_nowhere_changes_nothing() {
    var settings = Model.defaultSettings()
    var before = Model.serializeSettings(settings)
    compare(Model.serializeSettings(Model.withTileMovedNextTo(settings, "wifi", "wifi", false)), before)
    compare(Model.serializeSettings(Model.withTileMovedNextTo(settings, "wifi", "", false)), before)
    compare(Model.serializeSettings(Model.withTileMovedNextTo(settings, "made-up", "wifi", false)), before)
  }

  function test_showing_a_tile_lands_it_at_the_end_of_the_card() {
    var settings = Model.withTileShown(Model.defaultSettings(), "transcode")
    var shown = []
    for (var i = 0; i < settings.tiles.length; i++) if (settings.tiles[i].enabled) shown.push(settings.tiles[i].id)
    compare(shown[shown.length - 1], "transcode")
    compare(Model.tileEnabled(settings, "transcode"), true)
  }

  function test_position_cycles() {
    compare(Model.nextPosition("bar-end"), "centre")
    compare(Model.nextPosition("centre"), "bar-end")
    compare(Model.nextPosition("nonsense"), "bar-end")
  }

  // ---- the grid -----------------------------------------------------------

  function test_grid_hides_what_the_machine_cannot_do() {
    var available = JSON.parse(JSON.stringify(suite.allAvailable))
    available.bluetooth = false
    available.brightness = false
    var ids = Model.gridIds(Model.defaultSettings(), available, false)
    compare(ids.indexOf("bluetooth"), -1)
    compare(ids.indexOf("brightness"), -1)
    verify(ids.indexOf("wifi") >= 0)
  }

  function test_grid_hides_a_disabled_tile_but_edit_mode_shows_it() {
    var settings = Model.withTileEnabled(Model.defaultSettings(), "media", false)
    compare(Model.gridIds(settings, suite.allAvailable, false).indexOf("media"), -1)
    verify(Model.gridIds(settings, suite.allAvailable, true).indexOf("media") >= 0)
  }

  function test_edit_mode_appends_the_option_rows() {
    // Named rather than counted from the end, so adding a settings row is not
    // a test change: what matters is that they are last and in order.
    var ids = Model.gridIds(Model.defaultSettings(), suite.allAvailable, true)
    var wanted = ["opt-keybind", "opt-position", "opt-density", "opt-motion",
                  "opt-pill", "opt-reset"]
    compare(ids.slice(ids.length - wanted.length).join(","), wanted.join(","))
  }

  function test_reset_restores_the_arrangement_and_nothing_else() {
    var settings = Model.defaultSettings()
    settings = Model.withOption(settings, "density", "compact")
    settings = Model.withOption(settings, "position", "centre")
    settings = Model.withTileEnabled(settings, "volume", false)
    settings = Model.withTileShown(settings, "transcode")
    settings = Model.withTileMoved(settings, "wifi", 1)
    verify(!Model.tileEnabled(settings, "volume"))

    var reset = Model.withDefaultTiles(settings)
    compare(reset.tiles.length, Model.defaultSettings().tiles.length)
    for (var i = 0; i < reset.tiles.length; i++) {
      compare(reset.tiles[i].id, Model.defaultSettings().tiles[i].id, "order at " + i)
      compare(reset.tiles[i].enabled, Model.defaultSettings().tiles[i].enabled, "shown at " + i)
    }
    // A reset is about the arrangement. Everything under Settings, and the
    // shortcut, are not part of one.
    compare(reset.density, "compact")
    compare(reset.position, "centre")
  }

  function test_reset_does_not_edit_the_settings_it_was_given() {
    var settings = Model.withTileEnabled(Model.defaultSettings(), "volume", false)
    Model.withDefaultTiles(settings)
    verify(!Model.tileEnabled(settings, "volume"))
  }

  function test_density_is_a_choice_with_a_default() {
    compare(Model.defaultSettings().density, "comfortable")
    compare(Model.nextDensity("comfortable"), "compact")
    compare(Model.nextDensity("compact"), "comfortable")
    compare(Model.nextDensity("nonsense"), "comfortable")
    compare(Model.parseSettings('{"density":"tiny"}').settings.density, "comfortable",
            "an unknown density falls back")
    compare(Model.parseSettings('{"position":"centre"}').settings.density, "comfortable",
            "an absent density keeps the default")
    var compact = Model.withOption(Model.defaultSettings(), "density", "compact")
    compare(Model.parseSettings(Model.serializeSettings(compact)).settings.density, "compact")
  }

  function test_layout_wraps_and_never_splits_a_wide_tile() {
    var ids = ["wifi", "bluetooth", "volume", "dnd"]
    var out = Model.layout(ids, 100, 10, { toggle: 70, slider: 60 })
    compare(out.cells[0].row, 0)
    compare(out.cells[1].row, 0)
    compare(out.cells[2].row, 1, "a 4-wide tile starts its own row")
    compare(out.cells[2].span, 4)
    compare(out.cells[3].row, 2, "the tile after a full row starts the next one")
    compare(out.cells[2].width, 4 * 100 + 3 * 10)
    compare(out.cells[0].x, 0)
    compare(out.cells[1].x, 110)
  }

  function test_layout_row_height_is_the_tallest_in_the_row() {
    var out = Model.layout(["wifi", "bluetooth"], 100, 10, { toggle: 70 })
    compare(out.cells[0].height, 70)
    compare(out.height, 70)
  }

  function test_layout_of_nothing_is_empty() {
    var out = Model.layout([], 100, 10, { toggle: 70 })
    compare(out.cells.length, 0)
    compare(out.height, 0)
  }

  // ---- the cursor ---------------------------------------------------------

  function gridCells() {
    // wifi bluetooth dnd nightlight / stayawake mic recording / volume
    var ids = ["wifi", "bluetooth", "dnd", "nightlight", "stayawake", "mic", "recording", "volume"]
    return Model.layout(ids, 100, 10, { toggle: 70, slider: 60 }).cells
  }

  function test_cursor_moves_in_reading_order() {
    var cells = suite.gridCells()
    compare(Model.moveCursor(cells, 0, 1, 0), 1)
    compare(Model.moveCursor(cells, 1, -1, 0), 0)
    compare(Model.moveCursor(cells, 0, -1, 0), 0, "left from the first tile stays put")
    compare(Model.moveCursor(cells, cells.length - 1, 1, 0), cells.length - 1, "right from the last stays put")
  }

  function test_cursor_keeps_its_column_going_down() {
    var cells = suite.gridCells()
    compare(Model.moveCursor(cells, 1, 0, 1), 5, "column 1 on row 0 lands on column 1 on row 1")
    compare(Model.moveCursor(cells, 5, 0, -1), 1)
  }

  function test_cursor_falls_to_the_nearest_cell_on_a_short_row() {
    var cells = suite.gridCells()
    // nightlight sits at column 3; the row below has three tiles, so the
    // nearest is recording at column 2.
    compare(Model.moveCursor(cells, 3, 0, 1), 6)
  }

  function test_cursor_lands_on_a_wide_tile_from_any_column() {
    var cells = suite.gridCells()
    compare(Model.moveCursor(cells, 4, 0, 1), 7)
    compare(Model.moveCursor(cells, 6, 0, 1), 7)
  }

  function test_cursor_will_not_leave_the_grid() {
    var cells = suite.gridCells()
    compare(Model.moveCursor(cells, 0, 0, -1), 0)
    compare(Model.moveCursor(cells, 7, 0, 1), 7)
    compare(Model.moveCursor([], 0, 1, 0), -1)
    compare(Model.moveCursor(cells, -1, 0, 1), 0, "an unset cursor lands on the first tile")
  }

  function test_tab_walks_sections_and_wraps() {
    var ids = ["wifi", "bluetooth", "volume", "brightness", "power", "media", "actions"]
    compare(Model.moveSection(ids, 0, 1), 2, "toggles to sliders")
    compare(Model.moveSection(ids, 2, 1), 4, "sliders to power")
    compare(Model.moveSection(ids, 6, 1), 0, "the last section wraps to the first")
    compare(Model.moveSection(ids, 0, -1), 6, "back from the first wraps to the last")
  }

  function test_cursor_follows_its_tile_when_the_grid_changes() {
    var before = ["wifi", "dnd", "volume", "actions"]
    var after = ["wifi", "bluetooth", "dnd", "volume", "media", "actions"]
    // The cursor sat on "volume" at index 2; a Bluetooth adapter appearing
    // must not leave it pointing at "dnd".
    compare(Model.reindexCursor(after, "volume", 2), 3)
    compare(Model.reindexCursor(before, "volume", 2), 2)
  }

  function test_cursor_clamps_when_its_tile_disappears() {
    var after = ["wifi", "dnd"]
    compare(Model.reindexCursor(after, "media", 5), 1)
    compare(Model.reindexCursor(after, "", 0), 0)
    compare(Model.reindexCursor([], "wifi", 3), -1)
  }

  function test_digits_pick_the_nth_toggle() {
    var ids = ["volume", "wifi", "bluetooth", "media"]
    compare(Model.toggleIndexForDigit(ids, 1), 1)
    compare(Model.toggleIndexForDigit(ids, 2), 2)
    compare(Model.toggleIndexForDigit(ids, 3), -1, "there is no third toggle")
  }

  function test_first_index_of_kind() {
    var ids = ["volume", "wifi", "media"]
    compare(Model.firstIndexOfKind(ids, "toggle"), 1)
    compare(Model.firstIndexOfKind(ids, "actions"), 0, "an absent kind falls back to the first tile")
    compare(Model.firstIndexOfKind([], "toggle"), -1)
  }

  // ---- the catalogue ------------------------------------------------------

  function test_every_tile_is_whole() {
    for (var i = 0; i < Model.TILES.length; i++) {
      var tile = Model.TILES[i]
      verify(tile.id.length > 0, "a tile with no id")
      verify(tile.label.length > 0, tile.id + " has no label")
      verify(tile.span >= 1 && tile.span <= 4, tile.id + " has an impossible span")
      verify(Model.categoryLabel(tile.category) !== tile.category || tile.category === "",
             tile.id + " is in a category with no heading: " + tile.category)
      verify(typeof tile.on === "boolean", tile.id + " does not say whether it ships on")
    }
  }

  function test_every_action_tile_has_something_to_run() {
    for (var i = 0; i < Model.TILES.length; i++) {
      var tile = Model.TILES[i]
      if (tile.kind !== "action") continue
      var hasCommand = Model.actionCommand(tile.id) !== null
      var hasSummon = Model.actionSummon(tile.id) !== ""
      verify(hasCommand || hasSummon, tile.id + " is an action with nothing behind it")
      verify(!(hasCommand && hasSummon), tile.id + " has two ways to run and would do both")
    }
  }

  function test_action_commands_are_fixed_vectors() {
    for (var id in Model.ACTIONS) {
      var argv = Model.actionCommand(id)
      verify(argv.length > 0, id + " has an empty command")
      for (var i = 0; i < argv.length; i++) {
        verify(typeof argv[i] === "string" && argv[i].length > 0, id + " has an empty argument")
        // Nothing here is ever handed to a shell, so a command that reads
        // like shell is a mistake rather than a feature.
        verify(!/[;&|$`><\n]/.test(argv[i]), id + " argument looks like shell: " + argv[i])
      }
    }
  }

  function test_the_command_table_is_the_only_way_to_run_something() {
    compare(Model.actionCommand("made-up"), null)
    compare(Model.actionCommand(""), null)
    compare(Model.actionSummon("made-up"), "")
  }

  function test_every_tile_that_needs_a_glyph_has_one() {
    for (var i = 0; i < Model.TILES.length; i++) {
      var tile = Model.TILES[i]
      if (tile.kind !== "action" && tile.kind !== "toggle") continue
      // These draw their glyph from live state instead of the table.
      var live = ["wifi", "bluetooth", "dnd", "nightlight", "stayawake", "mic", "recording"]
      if (live.indexOf(tile.id) !== -1) continue
      var glyph = Model.glyphOf(tile.id)
      verify(glyph.length > 0, tile.id + " has no glyph")
      var cp = glyph.codePointAt(0)
      verify((cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0xFFFFD),
             tile.id + " has a glyph outside the private use areas")
    }
  }

  function test_headings_are_not_tiles() {
    verify(Model.isHeader(Model.headerFor("sound")))
    verify(!Model.isHeader("volume"))
    compare(Model.kindOf(Model.headerFor("sound")), "header")
    compare(Model.spanOf(Model.headerFor("sound")), 4)
    compare(Model.labelOf(Model.headerFor("sound")), "Sound")
    verify(!Model.isFocusable(Model.headerFor("sound")))
    verify(Model.isFocusable("volume"))
  }

  function test_the_gallery_groups_and_the_grid_does_not() {
    var available = {}
    for (var i = 0; i < Model.TILES.length; i++) available[Model.TILES[i].id] = true
    var settings = Model.defaultSettings()

    var plain = Model.gridIds(settings, available, false)
    for (var p = 0; p < plain.length; p++) verify(!Model.isHeader(plain[p]), "a heading leaked into the card")

    var gallery = Model.gridIds(settings, available, true)
    verify(gallery.length > plain.length, "the gallery shows more than the card")
    var headings = 0
    for (var g = 0; g < gallery.length; g++) if (Model.isHeader(gallery[g])) headings += 1
    verify(headings >= 5, "the gallery is not grouped")
    // Every heading is followed by something, never by another heading.
    for (var h = 0; h < gallery.length; h++) {
      if (!Model.isHeader(gallery[h])) continue
      verify(h + 1 < gallery.length && !Model.isHeader(gallery[h + 1]), "an empty group was shown")
    }
  }

  function test_a_tile_the_machine_cannot_back_is_absent_from_both() {
    var available = {}
    for (var i = 0; i < Model.TILES.length; i++) available[Model.TILES[i].id] = true
    available.touchscreen = false
    var settings = Model.defaultSettings()
    compare(Model.gridIds(settings, available, false).indexOf("touchscreen"), -1)
    compare(Model.gridIds(settings, available, true).indexOf("touchscreen"), -1)
  }

  function test_a_tile_new_since_the_file_was_written_lands_on_its_own_default() {
    // A file that predates the whole catalogue: only two tiles named.
    var parsed = Model.parseSettings(JSON.stringify({
      tiles: [{ id: "wifi", enabled: true }, { id: "volume", enabled: false }]
    })).settings
    compare(Model.tileEnabled(parsed, "wifi"), true)
    compare(Model.tileEnabled(parsed, "volume"), false, "an explicit choice survives")
    compare(Model.tileEnabled(parsed, "screenshot"), true, "a new tile that ships on arrives on")
    compare(Model.tileEnabled(parsed, "transcode"), false, "a new tile that ships off arrives off")
  }

  // ---- where a drop lands -------------------------------------------------

  readonly property int gap: 10
  readonly property int gridWidth: 4 * 100 + 3 * 10

  function dragCells() {
    // wifi bluetooth dnd nightlight / volume(full width) / heading / setting
    var ids = ["wifi", "bluetooth", "dnd", "nightlight", "volume",
               Model.headerFor("sound"), "opt-motion"]
    return Model.layout(ids, 100, suite.gap, { toggle: 70, slider: 60, header: 20, option: 40 }).cells
  }

  function cellFor(cells, id) {
    for (var i = 0; i < cells.length; i++) if (cells[i].id === id) return cells[i]
    return null
  }

  function test_two_narrow_tiles_sit_side_by_side() {
    var cells = suite.dragCells()
    var target = suite.cellFor(cells, "bluetooth")
    var left = Model.dropPlan(cells, target.x + 10, target.y + 10, "nightlight", suite.gap, suite.gridWidth)
    compare(left.anchorId, "bluetooth")
    compare(left.after, false, "the left half means before it")
    verify(left.vertical, "between two narrow tiles the line stands up")

    var right = Model.dropPlan(cells, target.x + target.width - 10, target.y + 10, "nightlight", suite.gap, suite.gridWidth)
    compare(right.anchorId, "bluetooth")
    compare(right.after, true, "the right half means after it")
  }

  function test_a_full_width_tile_only_goes_above_or_below() {
    var cells = suite.dragCells()
    var target = suite.cellFor(cells, "bluetooth")
    // Dragging the full-width Volume row onto a narrow tile: it cannot sit
    // beside it, so the answer is the row above or the row below, anchored to
    // the ends of that row rather than to the tile the pointer happens to be
    // over.
    var above = Model.dropPlan(cells, target.x + 10, target.y + 5, "volume", suite.gap, suite.gridWidth)
    compare(above.anchorId, "wifi", "above the row means before the row's first tile")
    compare(above.after, false)
    verify(!above.vertical, "a full-width move draws a line across")

    var below = Model.dropPlan(cells, target.x + 10, target.y + target.height - 5, "volume", suite.gap, suite.gridWidth)
    compare(below.anchorId, "nightlight", "below the row means after the row's last tile")
    compare(below.after, true)
    verify(!below.vertical)
  }

  function test_a_narrow_tile_cannot_sit_beside_a_full_width_one() {
    var cells = suite.dragCells()
    var wide = suite.cellFor(cells, "volume")
    var above = Model.dropPlan(cells, wide.x + 300, wide.y + 5, "wifi", suite.gap, suite.gridWidth)
    compare(above.anchorId, "volume")
    compare(above.after, false)
    verify(!above.vertical, "beside a full-width row is not a place, so the line lies flat")

    var below = Model.dropPlan(cells, wide.x + 300, wide.y + wide.height - 5, "wifi", suite.gap, suite.gridWidth)
    compare(below.after, true)
  }

  function test_the_line_is_drawn_where_the_tile_would_land() {
    var cells = suite.dragCells()
    var target = suite.cellFor(cells, "bluetooth")
    var left = Model.dropPlan(cells, target.x + 10, target.y + 10, "nightlight", suite.gap, suite.gridWidth)
    verify(left.indicator.x < target.x, "the line sits in the gap before the tile")
    compare(left.indicator.y, target.y)
    compare(left.indicator.height, target.height)
    verify(left.indicator.width <= suite.gap, "a standing line is thin")

    var wide = suite.cellFor(cells, "volume")
    var above = Model.dropPlan(cells, wide.x + 300, wide.y + 5, "wifi", suite.gap, suite.gridWidth)
    compare(above.indicator.x, 0, "a flat line runs the whole width")
    compare(above.indicator.width, suite.gridWidth)
    verify(above.indicator.y < wide.y)
    verify(above.indicator.height <= suite.gap)
  }

  function test_the_dragged_tile_reports_itself() {
    var cells = suite.dragCells()
    var plan = Model.dropPlan(cells, 50, 30, "wifi", suite.gap, suite.gridWidth)
    compare(plan.self, true, "back over its own slot is a drop that should do nothing")
  }

  function test_nothing_takes_a_drop_that_should_not() {
    var cells = suite.dragCells()
    var heading = suite.cellFor(cells, Model.headerFor("sound"))
    compare(Model.dropPlan(cells, heading.x + 5, heading.y + 5, "wifi", suite.gap, suite.gridWidth), null)
    var option = suite.cellFor(cells, "opt-motion")
    compare(Model.dropPlan(cells, option.x + 5, option.y + 5, "wifi", suite.gap, suite.gridWidth), null)
  }

  function test_a_gap_and_the_void_take_nothing() {
    var cells = suite.dragCells()
    compare(Model.dropPlan(cells, 105, 30, "volume", suite.gap, suite.gridWidth), null, "between two tiles")
    compare(Model.dropPlan(cells, -20, 30, "volume", suite.gap, suite.gridWidth), null, "left of everything")
    compare(Model.dropPlan(cells, 50, 9999, "volume", suite.gap, suite.gridWidth), null, "below everything")
    compare(Model.dropPlan([], 50, 30, "volume", suite.gap, suite.gridWidth), null)
    compare(Model.dropPlan(null, 50, 30, "volume", suite.gap, suite.gridWidth), null)
  }

  function test_the_plan_and_the_move_agree() {
    // Whatever dropPlan names is something withTileMovedNextTo can act on,
    // and the tile ends up on the side the plan said.
    var cells = suite.dragCells()
    var target = suite.cellFor(cells, "bluetooth")
    var plan = Model.dropPlan(cells, target.x + target.width - 10, target.y + 10, "nightlight", suite.gap, suite.gridWidth)
    var moved = Model.withTileMovedNextTo(Model.defaultSettings(), "nightlight", plan.anchorId, plan.after)
    var order = []
    for (var i = 0; i < moved.tiles.length; i++) if (moved.tiles[i].enabled) order.push(moved.tiles[i].id)
    compare(order[order.indexOf(plan.anchorId) + 1], "nightlight")
  }

  // ---- parsing what subprocesses print ------------------------------------

  function test_profiles_parse_and_ignore_anything_unexpected() {
    var parsed = Model.parseProfiles("performance\t0\nbalanced\t1\npower-saver\t0\nrm -rf\t1\n")
    compare(parsed.profiles.length, 3)
    compare(parsed.active, "balanced")
    compare(Model.parseProfiles("").profiles.length, 0)
    compare(Model.parseProfiles(null).active, "")
  }

  function test_key_value_parse_is_bounded() {
    var parsed = Model.parseKeyValue("percentage\t82%\ntime\t3h 10m\nbad key\tx\n")
    compare(parsed.percentage, "82%")
    compare(parsed.time, "3h 10m")
    compare(parsed["bad key"], undefined, "a key that is not a plain word is dropped")
  }

  function test_pid_and_elapsed_refuse_anything_but_digits() {
    compare(Model.parsePid("4321\n99\n"), "4321")
    compare(Model.parsePid("; rm -rf /"), "")
    compare(Model.parsePid(""), "")
    compare(Model.parseElapsed("  128 "), 128)
    compare(Model.parseElapsed("nope"), -1)
    compare(Model.parseElapsed(""), -1)
  }

  function test_elapsed_formats_as_a_clock() {
    compare(Model.formatElapsed(0), "0:00")
    compare(Model.formatElapsed(65), "1:05")
    compare(Model.formatElapsed(3725), "1:02:05")
    compare(Model.formatElapsed(-5), "0:00")
  }

  // ---- argv validation ----------------------------------------------------

  function test_monitor_names_are_validated() {
    verify(Model.isMonitorName("eDP-1"))
    verify(Model.isMonitorName("Virtual-1"))
    verify(!Model.isMonitorName("eDP-1; reboot"))
    verify(!Model.isMonitorName("--monitor"))
    verify(!Model.isMonitorName(""))
    verify(!Model.isMonitorName("$(id)"))
  }

  function test_node_names_and_ids_are_validated() {
    verify(Model.isNodeName("alsa_output.pci-0000_00_1f.3.analog-stereo"))
    verify(!Model.isNodeName("a b"))
    verify(!Model.isNodeName(""))
    verify(Model.isNodeId(42))
    verify(!Model.isNodeId("-1"))
    verify(!Model.isNodeId("4 2"))
  }

  function test_profiles_are_an_allowlist() {
    verify(Model.isProfile("balanced"))
    verify(!Model.isProfile("balanced; reboot"))
    verify(!Model.isProfile(""))
  }

  // ---- formatting ---------------------------------------------------------

  function test_percent_clamping() {
    compare(Model.clampPercent(150), 100)
    compare(Model.clampPercent(-5), 0)
    compare(Model.clampPercent(-5, 1), 1)
    compare(Model.clampPercent("nonsense", 1), 1)
    compare(Model.stepPercent(50, 5), 55)
    compare(Model.stepPercent(98, 5), 100)
  }

  function test_names_join_with_an_overflow_count() {
    compare(Model.joinNames(["AirPods"]), "AirPods")
    compare(Model.joinNames(["AirPods", "Keyboard"]), "AirPods, Keyboard")
    compare(Model.joinNames(["AirPods", "Keyboard", "Mouse"]), "AirPods, Keyboard +1")
    compare(Model.joinNames([]), "")
    compare(Model.joinNames(["", "  "]), "")
  }

  function test_battery_line_says_what_is_happening() {
    compare(Model.batteryLine(false, 0.5, true, {}, false), "")
    compare(Model.batteryLine(true, 0.82, true, { time: "3h 10m" }, false), "82% · 3h 10m left")
    compare(Model.batteryLine(true, 0.4, false, { time: "1h" }, false), "40% · 1h to full")
    compare(Model.batteryLine(true, 1, false, {}, true), "100% · Full")
    compare(Model.batteryLine(true, 0.5, true, {}, false), "50% · On battery")
  }

  function test_glyphs_track_their_value() {
    compare(Model.wifiGlyph(100), "󰤨")
    compare(Model.wifiGlyph(0), "󰤯")
    compare(Model.volumeGlyph(0.8, false, false), "󰕾")
    compare(Model.volumeGlyph(0.1, false, false), "󰕿")
    compare(Model.volumeGlyph(0.8, true, false), "󰝟", "muted beats everything")
    compare(Model.volumeGlyph(0.8, false, true), "󰋋", "headphones beat the level")
    compare(Model.batteryGlyph(1, true, false), "󰁹")
    compare(Model.batteryGlyph(0.5, false, true), "󰂅")
    compare(Model.profileGlyph("balanced"), "󰊚")
    compare(Model.profileLabel("power-saver"), "Saver")
  }
}
