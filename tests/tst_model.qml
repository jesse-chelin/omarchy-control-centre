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
    compare(settings.barWidget, false)
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
    var moved = Model.withTileMoved(settings, first, -1)
    compare(moved.tiles[0].id, first, "the first tile cannot move off the front")
    moved = Model.withTileMoved(settings, first, 2)
    compare(moved.tiles[2].id, first)
    compare(moved.tiles.length, settings.tiles.length, "nothing is lost in a move")
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
    var ids = Model.gridIds(Model.defaultSettings(), suite.allAvailable, true)
    compare(ids[ids.length - 3], "opt-position")
    compare(ids[ids.length - 1], "opt-pill")
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
