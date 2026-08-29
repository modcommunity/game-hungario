class_name HungryMenus
extends RefCounted

## The in-game screens: pause, settings, controls, scoreboard and chat.
##
## [b]Five screens and about two hundred lines, because dot-ui does the hard part.[/b] The
## stack owns z-order, input blocking, mouse mode and the back key; the settings panel
## builds itself from a [DotConfig]; the rebinder handles conflicts and persistence. What
## is left is deciding which screens exist and what is on them, which is a game's own.
##
## The chat screen is the one that is not in game-arena, and it is the one worth reading.
## Chat is dot-server's: a client sends through [method DotClientLink.send_chat] and
## receives on [signal DotClientLink.chat_received], and everything about sanitising,
## flood control, muting and admin-only routing already happened on the server. This is a
## line edit and a key binding.

const CHANNEL := "hungry.menus"


## The pause menu. Opaque, so the HUD goes away behind it.
class PauseScreen extends DotScreen:
	signal resume_pressed()
	signal loadout_pressed()
	signal settings_pressed()
	signal controls_pressed()
	signal leave_pressed()

	func _screen_id() -> StringName:
		return &"pause"

	func build() -> void:
		hides_below = true
		blocks_input = true
		mouse_mode = DotScreen.Mouse.VISIBLE

		var panel := PanelContainer.new()
		panel.name = "Panel"
		panel.set_anchors_preset(Control.PRESET_CENTER)
		panel.offset_left = -170.0
		panel.offset_right = 170.0
		panel.offset_top = -150.0
		panel.offset_bottom = 150.0
		add_child(panel)

		var column := VBoxContainer.new()
		column.name = "Column"
		panel.add_child(column)

		var title := Label.new()
		title.text = "Paused"
		title.theme_type_variation = &"DotHeading"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(title)

		_add_button(column, "Resume", func() -> void: resume_pressed.emit())
		_add_button(column, "Loadout", func() -> void: loadout_pressed.emit())
		_add_button(column, "Settings", func() -> void: settings_pressed.emit())
		_add_button(column, "Controls", func() -> void: controls_pressed.emit())
		_add_button(column, "Leave", func() -> void: leave_pressed.emit())

		# Without this the menu opens with nothing focused: unusable with a gamepad, and
		# invisible to anybody testing with a mouse.
		#
		# A path by name, not `button.get_path()`: this runs before the screen is
		# registered with a stack, so it is not in the tree yet and `get_path()` pushes an
		# error and returns nothing. game-arena's pause menu shipped with exactly that.
		initial_focus = NodePath("Panel/Column/Resume")

	func _add_button(into: Control, text: String, action: Callable) -> Button:
		var button := Button.new()
		button.name = text
		button.text = text
		button.pressed.connect(action)
		into.add_child(button)
		return button


## Settings, generated from a [DotConfig].
##
## The panel reads the config's own `@export` annotations, so this screen never restates a
## setting and cannot drift from one.
class SettingsScreen extends DotScreen:
	signal applied(config: DotConfig)

	var panel: DotSettingsPanel = null

	func _screen_id() -> StringName:
		return &"settings"

	func build(config: DotConfig) -> void:
		blocks_input = true

		var container := PanelContainer.new()
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -290.0
		container.offset_right = 290.0
		container.offset_top = -230.0
		container.offset_bottom = 230.0
		add_child(container)

		var column := VBoxContainer.new()
		container.add_child(column)

		var title := Label.new()
		title.text = "Settings"
		title.theme_type_variation = &"DotHeading"
		column.add_child(title)

		panel = DotSettingsPanel.new()
		# Edits are held until Apply. A live panel would call validate() on a half-edited
		# config, which can legitimately be invalid on its way to being valid.
		panel.live = false
		column.add_child(panel)
		panel.bind(config)

		var buttons := HBoxContainer.new()
		column.add_child(buttons)

		var apply := Button.new()
		apply.text = "Apply"
		apply.pressed.connect(func() -> void:
			var res := panel.apply()

			if not res.ok:
				DotLog.result(CHANNEL, "settings", res)
				return

			# Applied and then announced, so a listener never reads a config that failed
			# validation — which is a legitimate state on the way to a valid one, and the
			# reason the panel holds edits until Apply rather than writing them live.
			applied.emit(panel.bound_config())
		)
		buttons.add_child(apply)

		var revert := Button.new()
		revert.text = "Revert"
		revert.pressed.connect(panel.revert)
		buttons.add_child(revert)

		var back := Button.new()
		back.text = "Back"
		back.pressed.connect(close)
		buttons.add_child(back)


## Key bindings, with conflict detection and a file that survives a restart.
class ControlsScreen extends DotScreen:
	var panel: DotBindingsPanel = null

	func _screen_id() -> StringName:
		return &"controls"

	func build(config: DotUiConfig) -> void:
		blocks_input = true

		var container := PanelContainer.new()
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -270.0
		container.offset_right = 270.0
		container.offset_top = -230.0
		container.offset_bottom = 230.0
		add_child(container)

		var column := VBoxContainer.new()
		container.add_child(column)

		var title := Label.new()
		title.text = "Controls"
		title.theme_type_variation = &"DotHeading"
		column.add_child(title)

		panel = DotBindingsPanel.new()
		panel.config = config
		panel.prefix = "hungry_"
		column.add_child(panel)
		panel.build()
		panel.load_saved()

		# Saved on every change rather than on Back: a player who rebinds and then closes
		# the tab should not lose it, and there is nothing to batch.
		panel.binding_changed.connect(func(_a: StringName, _e: InputEvent) -> void:
			panel.save()
		)

		var buttons := HBoxContainer.new()
		column.add_child(buttons)

		var reset := Button.new()
		reset.text = "Defaults"
		reset.pressed.connect(func() -> void:
			panel.reset_all()
			panel.save()
		)
		buttons.add_child(reset)

		var back := Button.new()
		back.text = "Back"
		back.pressed.connect(close)
		buttons.add_child(back)


## The scoreboard. Transparent, and does not block input.
##
## Both matter: it is held down during a live game, so it must not stop the player moving
## and must not hide what they are looking at. That is exactly the distinction between
## [member DotScreen.blocks_input] and [member DotScreen.hides_below].
class ScoreboardScreen extends DotScreen:
	var table: DotTableView = null

	var _world: HungryWorld = null
	var _bridge: HungryNetBridge = null

	func _screen_id() -> StringName:
		return &"scoreboard"

	func build(world: HungryWorld, bridge: HungryNetBridge) -> void:
		_world = world
		_bridge = bridge
		blocks_input = false
		hides_below = false
		mouse_mode = DotScreen.Mouse.INHERIT

		var container := PanelContainer.new()
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -320.0
		container.offset_right = 320.0
		container.offset_top = -210.0
		container.offset_bottom = 210.0
		add_child(container)

		table = DotTableView.new()
		table.max_rows = 20
		container.add_child(table)
		table.set_columns([
			{"key": &"rank", "title": "#", "align": HORIZONTAL_ALIGNMENT_RIGHT},
			{"key": &"name", "title": "Monster", "width": 3.0},
			{"key": &"mass", "title": "Mass", "align": HORIZONTAL_ALIGNMENT_RIGHT},
			{"key": &"pieces", "title": "Pieces", "align": HORIZONTAL_ALIGNMENT_RIGHT},
		])

	func _on_push() -> void:
		refresh()

	func refresh() -> void:
		if _world == null or table == null:
			return

		var rows: Array[Dictionary] = []
		var rank := 1
		var me := _bridge.local_player_id if _bridge != null else 0

		for monster in _world.leaderboard(20):
			rows.append({
				&"rank": rank,
				&"name": monster.display_name,
				&"mass": int(monster.mass()),
				&"pieces": monster.piece_count(),
				"highlight": monster.id == me,
				"colour": monster.colour,
			})
			rank += 1

		table.set_rows(rows)


## What you bring in: a starting throwable and a trait.
##
## [b]The screen never decides what is legal.[/b] It offers what
## [method DotLoadoutSchema.choices_for] says this player may take — which is the schema
## and their entitlements, and nothing else — and the server validates the result anyway.
## A screen that filtered on its own would drift from the server the first time an unlock
## changed, and a screen the server trusted would be a client choosing its own stats.
##
## Two option buttons rather than a grid of cards, because there are two slots and three
## choices each. A loadout screen is worth building properly when there is something to
## build it for.
class LoadoutScreen extends DotScreen:
	signal chosen(loadout: DotLoadout)

	var schema: DotLoadoutSchema = null
	var entitlements: DotLoadoutEntitlements = null

	var _pickers: Dictionary = {}
	var _summary: Label = null

	func _screen_id() -> StringName:
		return &"loadout"

	func build(p_schema: DotLoadoutSchema) -> void:
		schema = p_schema
		# Nothing owned until a server says otherwise. Showing everything and letting the
		# server refuse it is a screen that offers things it cannot deliver.
		entitlements = DotLoadoutEntitlements.none()

		blocks_input = true
		mouse_mode = DotScreen.Mouse.VISIBLE

		var container := PanelContainer.new()
		container.name = "Panel"
		container.set_anchors_preset(Control.PRESET_CENTER)
		container.offset_left = -260.0
		container.offset_right = 260.0
		container.offset_top = -190.0
		container.offset_bottom = 190.0
		add_child(container)

		var column := VBoxContainer.new()
		column.name = "Column"
		container.add_child(column)

		var title := Label.new()
		title.text = "Loadout"
		title.theme_type_variation = &"DotHeading"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(title)

		for slot in schema.ordered_slots():
			var row := HBoxContainer.new()
			column.add_child(row)

			var label := Label.new()
			label.text = slot.display_name
			label.custom_minimum_size = Vector2(190.0, 0.0)
			row.add_child(label)

			var picker := OptionButton.new()
			picker.name = String(slot.id)
			picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			picker.item_selected.connect(func(_index: int) -> void: _describe())
			row.add_child(picker)

			_pickers[slot.id] = picker

		_summary = Label.new()
		_summary.name = "Summary"
		_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_summary.custom_minimum_size = Vector2(0.0, 60.0)
		column.add_child(_summary)

		var buttons := HBoxContainer.new()
		column.add_child(buttons)

		var apply := Button.new()
		apply.name = "Apply"
		apply.text = "Take this in"
		apply.pressed.connect(_apply)
		buttons.add_child(apply)

		var back := Button.new()
		back.text = "Back"
		back.pressed.connect(close)
		buttons.add_child(back)

		initial_focus = NodePath("Panel/Column/HBoxContainer/starter")
		refresh()

	## Rebuilds the choices from the schema and what this player owns.
	func refresh() -> void:
		for slot in schema.ordered_slots():
			var picker: OptionButton = _pickers[slot.id]
			var previous := _selected_id(slot.id)
			picker.clear()

			for item in schema.choices_for(slot.id, entitlements):
				picker.add_item(item.display_name)
				picker.set_item_metadata(picker.item_count - 1, item.id)

				if item.id == previous:
					picker.select(picker.item_count - 1)

			if picker.selected < 0 and picker.item_count > 0:
				picker.select(0)

		_describe()

	## Takes what a server says this player owns, and re-offers accordingly.
	func allow(owned: DotLoadoutEntitlements) -> void:
		entitlements = owned if owned != null else DotLoadoutEntitlements.none()
		refresh()

	## Shows a saved choice, so the screen opens on what the player is actually wearing.
	func show_loadout(loadout: DotLoadout) -> void:
		if loadout == null:
			return

		for slot in schema.ordered_slots():
			var picker: OptionButton = _pickers[slot.id]
			var wanted := loadout.item_in(slot.id)

			for index in range(picker.item_count):
				if StringName(str(picker.get_item_metadata(index))) == wanted:
					picker.select(index)
					break

		_describe()

	func _selected_id(slot_id: StringName) -> StringName:
		var picker: OptionButton = _pickers.get(slot_id)

		if picker == null or picker.selected < 0:
			return &""

		return StringName(str(picker.get_item_metadata(picker.selected)))

	## The loadout the screen currently describes.
	func current() -> DotLoadout:
		var loadout := DotLoadout.empty(schema.id)

		for slot in schema.ordered_slots():
			var chosen := _selected_id(slot.id)

			if chosen != &"":
				loadout.set_item(slot.id, chosen)

		return loadout

	## Says what the choice actually does, in the units the player sees.
	##
	## A trait called "Nimble" tells nobody anything. The numbers come from
	## [HungryContent] rather than being written out here, so the screen cannot describe a
	## trade the game does not make.
	func _describe() -> void:
		if _summary == null:
			return

		var trait_id := _selected_id(HungryContent.SLOT_TRAIT)
		var starter := _selected_id(HungryContent.SLOT_STARTER)

		_summary.text = (
			"%+.0f%% speed   %+.0f%% starting mass   %+.0f%% from food\n"
			+ "Spawn holding one %s. Takes effect next time you spawn."
		) % [
			(HungryContent.trait_speed(trait_id) - 1.0) * 100.0,
			(HungryContent.trait_mass(trait_id) - 1.0) * 100.0,
			(HungryContent.trait_food(trait_id) - 1.0) * 100.0,
			String(starter),
		]

	func _apply() -> void:
		chosen.emit(current())
		close()


## One line of chat, on its way to the server.
##
## [b]It blocks input while it is open and that is the whole reason it is a screen.[/b] A
## chat box that let the movement keys through is a player who drives into a wall while
## typing "hello", and getting that consistently right across a HUD, a pause menu and a
## scoreboard is what [DotScreenStack] is for.
class ChatScreen extends DotScreen:
	signal submitted(text: String)

	var line: LineEdit = null

	func _screen_id() -> StringName:
		return &"chat"

	func build() -> void:
		blocks_input = true
		hides_below = false
		mouse_mode = DotScreen.Mouse.VISIBLE

		var panel := PanelContainer.new()
		panel.name = "Panel"
		panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		panel.offset_left = 20.0
		panel.offset_right = -20.0
		panel.offset_top = -110.0
		panel.offset_bottom = -70.0
		add_child(panel)

		line = LineEdit.new()
		line.name = "Line"
		line.placeholder_text = "Say something…"
		# The server truncates anyway, but a client that let somebody type four thousand
		# characters and then silently sent forty is a client that looks broken.
		line.max_length = 180
		line.text_submitted.connect(_on_submitted)
		panel.add_child(line)

		initial_focus = NodePath("Panel/Line")

	func _on_submitted(text: String) -> void:
		var trimmed := text.strip_edges()
		line.text = ""

		if trimmed != "":
			submitted.emit(trimmed)

		close()

	func _on_push() -> void:
		if line != null:
			line.text = ""
			line.grab_focus()


## Registers every screen with a stack and wires the buttons that navigate.
##
## Returns the pause screen, because that is the one a game opens.
static func install(
	stack: DotScreenStack,
	world: HungryWorld,
	bridge: HungryNetBridge,
	ui_config: DotUiConfig,
	game_config: DotConfig = null
) -> PauseScreen:
	var loadout := LoadoutScreen.new()
	loadout.name = "Loadout"
	loadout.build(
		bridge.loadout_schema if bridge != null and bridge.loadout_schema != null
		else HungryContent.loadout_schema()
	)
	stack.register(loadout)

	var pause := PauseScreen.new()
	pause.name = "Pause"
	pause.build()
	stack.register(pause)

	var settings := SettingsScreen.new()
	settings.name = "Settings"
	# The game's own settings when there are any, the interface's otherwise. The panel does
	# not care which: it reads whatever `@export` annotations the config has.
	settings.build(game_config if game_config != null else ui_config)
	stack.register(settings)

	var controls := ControlsScreen.new()
	controls.name = "Controls"
	controls.build(ui_config)
	stack.register(controls)

	var scoreboard := ScoreboardScreen.new()
	scoreboard.name = "Scoreboard"
	scoreboard.build(world, bridge)
	stack.register(scoreboard)

	var chat := ChatScreen.new()
	chat.name = "Chat"
	chat.build()
	stack.register(chat)

	pause.resume_pressed.connect(func() -> void: stack.pop(&"pause"))
	pause.loadout_pressed.connect(func() -> void: stack.push(&"loadout"))
	pause.settings_pressed.connect(func() -> void: stack.push(&"settings"))
	pause.controls_pressed.connect(func() -> void: stack.push(&"controls"))

	return pause
