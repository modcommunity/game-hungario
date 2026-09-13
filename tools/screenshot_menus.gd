extends SceneTree

const HungryContent := preload("../game/hungry_content.gd")
const HungryMenus := preload("../game/client/hungry_menus.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## Renders this game's own screens to `screenshots/` so a person can look at them.
##
## [b]This game had no screenshot tool at all[/b], and it is the one with the most screens:
## a pause menu, a loadout picker, a scoreboard, a rebinder and a chat window. It is also
## where two of the family's table bugs were sitting — its browser and its HUD leaderboard
## both declared columns with no width, and a column with no width used to collapse to
## nothing, so the mass, the pieces, the rank and the ping had never been drawn.
##
## Run through `tools/screenshot_menus.sh`. [b]Not `--headless`[/b]: that gives a null
## renderer, a 64 x 64 viewport, and every frame it saves is empty — which is worse than no
## screenshot because it looks like one.

const OUT_DIR := "res://screenshots"
const SETTLE := 3

var _stack: DotScreenStack = null
var _world: HungryWorld = null
var _seeded := false
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# The movement and action bindings, so the rebinder has rows. `HungryInput` registers
	# them in the real client; without them the picture is an empty screen for a reason
	# that has nothing to do with the code.
	for action in [
		&"hungry_split", &"hungry_throw", &"hungry_boost", &"hungry_eject",
	]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)

	_stack = DotScreenStack.new()
	_stack.name = "Stack"
	_stack.register_service = false
	_stack.manage_mouse = false
	_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_stack)
	_stack.setup()

	var ui_config := DotUiConfig.new()

	var pause := HungryMenus.PauseScreen.new()
	pause.name = "Pause"
	pause.build()
	_stack.register(pause)

	var controls := HungryMenus.ControlsScreen.new()
	controls.name = "Controls"
	controls.build(ui_config)
	_stack.register(controls)

	var loadout := HungryMenus.LoadoutScreen.new()
	loadout.name = "Loadout"
	loadout.build(HungryContent.loadout_schema())
	_stack.register(loadout)

	# A world with monsters of a spread of masses, through the real world rather than a
	# hand-built row list: a picture of a dictionary is a picture of a dictionary.
	var world := HungryWorld.new()
	world.is_authority = true
	world.register_service = false
	root.add_child(world)
	world.setup()

	_world = world

	var scoreboard := HungryMenus.ScoreboardScreen.new()
	scoreboard.name = "Scoreboard"
	scoreboard.build(world, null)
	_stack.register(scoreboard)

	_shots = [
		{"id": &"pause", "file": "menu_pause.png"},
		{"id": &"loadout", "file": "menu_loadout.png"},
		{"id": &"scoreboard", "file": "menu_scoreboard.png"},
		{"id": &"controls", "file": "menu_controls.png"},
	]


func _process(_delta: float) -> bool:
	if _done:
		return true

	# The monsters are added on the FIRST FRAME, not in `_initialize`.
	#
	# `HungryWorld.setup()` creates its `DotMatch` and adds it as a child, and a node added
	# from `SceneTree._initialize` does not get its `_ready` until the first frame -- so the
	# match's scoreboard does not exist yet and `add_player` dies on it. The error is
	# "Nonexistent function 'join' in base 'Nil'", which reads like a missing method rather
	# than like a node that has not started. game-simple-lobby's screenshot tool carries the
	# same warning about the same shape, and this hit it anyway.
	if not _seeded:
		_seeded = true

		var names := [
			"gamemann", "a_very_long_display_name", "bo", "quiet_one", "newcomer",
		]

		for i in names.size():
			var added := _world.add_player(i + 1, names[i])

			if not added.ok:
				push_error("could not add %s: %s" % [names[i], added.error.message])

		return false

	if _at >= _shots.size():
		_done = true
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE:
		_stack.clear()

		var opened := _stack.push(StringName(shot["id"]))

		if not opened.ok:
			# Said out loud rather than saved as a grey rectangle. A screen registered under
			# a name nothing pushes is exactly the bug this tool found in dot-ui, and a
			# picture of an empty viewport is indistinguishable from a broken renderer.
			push_error("could not open '%s': %s" % [shot["id"], opened.error.message])
			_at += 1
			return false

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join(str(shot["file"]))
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false
