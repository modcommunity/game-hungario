class_name HungryPresentation
extends Node

## Settings, audio, effects and a console — every one of them wired to something this game
## already had, rather than beside it.
##
## [b]This is the game where the integration is mostly about NOT duplicating.[/b] hungario
## already generates its whole sound bank arithmetically, already has a `HungryConfig` that
## dot-ui builds a settings panel from, and already draws its own world. So:
##
## - **dot-audio does not replace `HungrySound`.** [HungrySoundSink] is dot-audio's sink and
##   the generation stays. What the addon adds is the half this game never had: a
##   catalogue, per-id caps, cooldowns, a distance cull, priorities, a proper volume curve,
##   and a manager that says *why* a sound was refused.
## - **dot-settings does not replace `HungryConfig`.**
##   [method DotSettingsSchema.from_config] reads it, so there is still one list — ranges
##   come from the `@export_range` hints, and the only thing added is the part a config
##   genuinely cannot say, which is the scope.
##
## Both are the same decision twice: **two copies of one list is this family's most
## repeated bug**, and an addon that makes you write a second one is an addon that has
## cost you something.

const CHANNEL := "hungry.presentation"

const FX_DIR := "res://scenes/fx"

## Which of the config's keys follow the person rather than the machine.
##
## The one thing `HungryConfig` cannot say about itself. A camera follow time is about this
## screen; a name plate preference and a feed length are about the person, and somebody who
## set them here should not set them again in the next game.
const SCOPES := {
	&"show_names": DotSettingsDef.Scope.ACCOUNT,
	&"show_threat": DotSettingsDef.Scope.ACCOUNT,
	&"feed_lines": DotSettingsDef.Scope.ACCOUNT,
	&"show_minimap": DotSettingsDef.Scope.ACCOUNT,
}

var settings: DotSettingsManager = null
var audio: DotAudioManager = null
var fx: DotFxManager = null
var console: DotConsoleController = null
var console_panel: DotConsolePanel = null

## The in-game chat box. See [method _build_chat].
var chat_window: DotChatWindow = null

## The game's own configuration, which stays the declaration.
var config: HungryConfig = null

## The generated bank, which stays the noise.
var sound: HungrySound = null

var client: Node = null

var _layer: CanvasLayer = null
var _chat_layer: CanvasLayer = null

## Whether the server said something else is carrying chat. See [method set_chat_relayed].
var _chat_relayed: bool = false


func setup() -> DotResult:
	if config == null:
		config = HungryConfig.new()

	var settled := _build_settings()
	if not settled.ok:
		return settled
	var heard := _build_audio()
	if not heard.ok:
		return heard
	var drawn := _build_fx()
	if not drawn.ok:
		return drawn
	var consoled := _build_console()
	if not consoled.ok:
		return consoled

	_build_chat()

	# [b]And then every value is pushed once, which is the half that was missing.[/b]
	# Everything below reacts to `changed`, and a value loaded from disk has not changed --
	# so a player who set the volume to -30, quit and came back got -8, because only the
	# change handler ever pushed it. That is this family's most repeated bug exactly: a
	# value produced correctly and consumed by nothing, with the symptom pointing at the
	# thing that consumes rather than at the thing that never told it.
	apply_all()
	return DotResult.success(null)


## Pushes every current setting at whatever reads it.
##
## Called once after building, and callable again after a document is replaced -- a load,
## a reset, or a server releasing its clamps.
func apply_all() -> void:
	for key in settings.schema.keys():
		_on_setting_changed(key, settings.get_value(key), &"applied")


# --- Settings ---------------------------------------------------------------

func _build_settings() -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Settings"
	# Read out of the config rather than written beside it. Tightening a range in
	# HungryConfig tightens the slider, the console and the stored document at once.
	settings.schema = DotSettingsSchema.from_config(config, SCOPES)
	settings.local_store = DotSettingsStoreFile.new("user://hungry_settings")
	settings.app_namespace = &"game_hungario"
	settings.shared_namespace = &"tmc_account"
	add_child(settings)

	var res := settings.setup()
	if not res.ok:
		return res.wrap("hungario's settings")

	# And back into the config on the way in, because the config is what the game reads.
	# A settings document that does not reach it is a document nothing consumes, which is
	# this family's single most repeated bug.
	settings.schema.apply_to_config(config, settings.to_config().values())
	_add_chat_settings()
	settings.changed.connect(_on_setting_changed)
	return DotResult.success(null)


## The three chat settings, added BESIDE the config rather than read out of it.
##
## [b]Everything else here comes from [HungryConfig] on purpose[/b] — tightening a range
## there tightens the slider, the console and the stored document at once — and these three
## deliberately do not. A `DotConfig` is layered from a JSON file, the environment and the
## command line, and a keyboard binding has no business arriving from a server's argv:
## `HUNGRY_CHAT_OPEN_KEY=Q` in a container would rebind every player's chat key. What key
## a person opens chat with is theirs, stored under `ACCOUNT` scope, and reaches nothing
## that runs on a server.
func _add_chat_settings() -> void:
	settings.schema.add(DotSettingsDef.choice(
		&"chat_window",
		&"auto",
		[&"auto", &"on", &"off"] as Array[StringName],
		&"chat"
	).with_scope(DotSettingsDef.Scope.ACCOUNT).with_description(
		"auto hides the box on a server already carrying chat somewhere the player can "
		+ "see it; on always draws it; off never does."
	))
	settings.schema.add(DotSettingsDef.binding(&"chat_open_key", "Y", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	settings.schema.add(DotSettingsDef.binding(&"chat_near_key", "U", &"chat").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	).with_description("Opens chat on the proximity channel rather than on all."))


func _on_setting_changed(key: StringName, value: Variant, _why: StringName) -> void:
	# One key at a time rather than a whole re-application: a re-application on every
	# keystroke of a console line would write ten keys to change one, and every one of
	# those writes is a signal something else is listening to.
	if config != null and config.has_key(String(key)):
		var def := settings.schema.find(key)
		if def != null and def.kind == DotSettingsDef.Kind.ENUM:
			config.set(key, maxi(0, def.options.find(StringName(str(value)))))
		else:
			config.set(key, value)

	match key:
		&"chat_window":
			_apply_chat_visibility()
		&"chat_open_key":
			_bind_chat(chat_window.open_action if chat_window != null else &"", str(value))
		&"chat_near_key":
			_bind_chat(chat_window.team_action if chat_window != null else &"", str(value))
		&"volume_db":
			if sound != null:
				sound.volume_db = float(value)
			if audio != null:
				# The mixer carries a LINEAR amplitude and the config carries decibels,
				# which is the one conversion everybody gets wrong in the other direction:
				# a 0..1 slider mapped straight onto dB is a control where everything
				# below 0.9 is silence.
				audio.mixer.master = clampf(db_to_linear(float(value)), 0.0, 1.0)
				audio.mixer.apply_to_buses()
		&"muted":
			if sound != null:
				sound.muted = bool(value)
			if audio != null:
				audio.mixer.master = 0.0 if bool(value) else clampf(
					db_to_linear(config.volume_db), 0.0, 1.0
				)
		_:
			pass


# --- Audio ------------------------------------------------------------------

## What hungario makes a noise about, with the limits it never had.
##
## Every entry is `generated`: there is no file behind any of them, because `HungrySound`
## bakes the whole bank arithmetically at boot. dot-audio refused a def with no path on the
## first run of this integration, which is how `DotAudioDef.generated` came to exist -- and
## it is the setting that makes the sink seam mean what it says.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	# Eating is the common case: a monster in a dense field eats several times a second,
	# and past a handful of overlapping blips it is noise anyway. A cap and a short
	# cooldown are what turn that from a texture into a rhythm.
	var eat := DotAudioDef.new()
	eat.id = &"eat"
	eat.generated = true
	eat.kind = DotAudioDef.Kind.POSITIONAL_2D
	eat.bus = &"SFX"
	eat.max_concurrent = 4
	eat.cooldown_ms = 35
	eat.priority = 20
	# The arena is thousands of units across and a bite on the far side of it is not
	# information. Culling here costs one subtraction; not culling costs a voice.
	eat.max_distance = 1400.0
	c.add(eat)

	var fruit := DotAudioDef.new()
	fruit.id = &"fruit"
	fruit.generated = true
	fruit.kind = DotAudioDef.Kind.POSITIONAL_2D
	fruit.bus = &"SFX"
	fruit.max_concurrent = 2
	fruit.priority = 60
	fruit.max_distance = 2000.0
	c.add(fruit)

	for id in [&"pickup", &"split", &"eject", &"throw"]:
		var d := DotAudioDef.new()
		d.id = id
		d.generated = true
		d.bus = &"SFX"
		d.max_concurrent = 2
		d.cooldown_ms = 60
		d.priority = 50
		c.add(d)

	# The three that must never be refused for a cheaper sound: being burst, eating
	# somebody, and dying are the only moments in this game that change everything.
	for id in [&"burst", &"devour", &"die"]:
		var d := DotAudioDef.new()
		d.id = id
		d.generated = true
		d.bus = &"SFX"
		d.max_concurrent = 2
		d.priority = 100
		c.add(d)

	var click := DotAudioDef.new()
	click.id = &"click"
	click.generated = true
	click.bus = &"UI"
	click.cooldown_ms = 40
	click.priority = 30
	c.add(click)

	return c


func _build_audio() -> DotResult:
	audio = DotAudioManager.new()
	audio.name = "Audio"
	audio.catalogue = sound_catalogue()
	audio.mixer = DotAudioMixer.new()
	audio.mixer.master = clampf(db_to_linear(config.volume_db), 0.0, 1.0)
	audio.voices = HungrySound.VOICES
	audio.apply_mixer_to_buses = false
	# The seam. Everything above it is dot-audio's; the last four lines are this game's.
	audio.sink = HungrySoundSink.new(sound)
	add_child(audio)

	var res := audio.setup()
	if not res.ok:
		return res.wrap("hungario's audio")
	return DotResult.success(null)


## Rebinds the sink when the bank is built after this layer was.
func use_sound(p_sound: HungrySound) -> void:
	sound = p_sound
	if audio != null and audio.sink is HungrySoundSink:
		(audio.sink as HungrySoundSink).sound = p_sound


# --- Effects ----------------------------------------------------------------

static func fx_catalogue() -> DotFxCatalogue:
	var c := DotFxCatalogue.new()

	var pop := DotFxDef.new()
	pop.id = &"eat_pop"
	pop.scene_path = "%s/eat_pop.tscn" % FX_DIR
	pop.lifetime_ms = 320
	pop.cost = 1
	pop.priority = 20
	pop.max_distance = 1400.0
	pop.max_concurrent = 12
	# The first thing a low tier should not have: it is the effect that happens most
	# often, so it is the one whose absence saves the most.
	pop.min_quality = 1
	c.add(pop)

	var burst := DotFxDef.new()
	burst.id = &"burst"
	burst.scene_path = "%s/burst.tscn" % FX_DIR
	burst.lifetime_ms = 900
	burst.cost = 10
	burst.priority = 95
	burst.max_distance = 0.0
	c.add(burst)

	var threat := DotFxDef.new()
	threat.id = &"threat"
	threat.kind = DotFxDef.Kind.SCREEN
	threat.flash_peak = 0.22
	threat.flash_colour = Color(0.9, 0.2, 0.25)
	threat.flash_decay_ms = 400
	c.add(threat)

	var shake := DotFxDef.new()
	shake.id = &"burst_shake"
	shake.kind = DotFxDef.Kind.SHAKE
	shake.shake_trauma = 0.55
	c.add(shake)

	return c


func _build_fx() -> DotResult:
	fx = DotFxManager.new()
	fx.name = "Fx"
	fx.catalogue = fx_catalogue()
	fx.config = DotFxConfig.new()
	fx.config.max_decals = 0
	add_child(fx)

	var res := fx.setup()
	if not res.ok:
		return res.wrap("hungario's effects")
	return DotResult.success(null)


# --- Console ----------------------------------------------------------------

# --- Chat -------------------------------------------------------------------

## The box a player types in, and the three settings that decide it.
##
## [b]This replaces a chat box that already existed, and the replacement is the point.[/b]
## `HungryMenus.ChatScreen` was a modal [DotScreen] on Enter with one line edit in it: it
## worked, and it was the only one of its kind in the family, with no log, no channels and
## no way to tell whether anything else was carrying the conversation. Five games with five
## chat boxes is this tree's most expensive shape. The behaviour a player loses is the
## Enter key, and it is a setting away.
##
## Bottom left, at the default inset: this game's HUD keeps its score and its feed along
## the top and the right, so the corner is free.
func _build_chat() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.name = "ChatLayer"
	_chat_layer.layer = 100
	add_child(_chat_layer)

	var offered: Array[Dictionary] = []

	# The channels the server actually routes, rather than a second list here.
	for channel in HungryServices.chat_channels():
		if channel.admin_only or channel.server_only:
			continue

		offered.append({
			"id": channel.id,
			"label": "Say" if channel.display_name == "" else "Say (%s)" % channel.display_name,
			"colour": channel.colour,
			# No teams in this game; what the second key opens is the proximity channel.
			"team": channel.scope == DotChatChannel.Scope.RADIUS,
		})

	chat_window = DotChatWindow.new()
	chat_window.name = "ChatWindow"
	chat_window.open_action = &"hungry_chat"
	chat_window.team_action = &"hungry_chat_near"
	chat_window.channels = offered
	_chat_layer.add_child(chat_window)


## Puts one binding from the settings document onto its action.
##
## Empty is left alone rather than applied: a settings file somebody cleared the field in
## would otherwise unbind chat with no way to get it back from inside the game.
func _bind_chat(action: StringName, text: String) -> void:
	if action == &"" or text.strip_edges() == "":
		return

	var bound := DotInputBinding.apply(action, text)

	if bound == "":
		DotLog.warn(CHANNEL, "a chat key was not understood", {
			"action": String(action), "binding": text
		})


## The server said whether anything else is carrying this conversation.
func set_chat_relayed(relayed: bool) -> void:
	if _chat_relayed == relayed:
		return

	_chat_relayed = relayed
	_apply_chat_visibility()


## Resolves the three-way setting against what the server said.
##
## `on` is both halves at once — a relayed server AND a box in front of the game. `off` is
## a player who chats somewhere else. `auto` draws it unless this server is already putting
## these lines somewhere this player can see them. In every case the log keeps drawing what
## other people said.
func _apply_chat_visibility() -> void:
	if chat_window == null or settings == null:
		return

	match StringName(str(settings.get_value(&"chat_window"))):
		&"on":
			chat_window.enabled = true
		&"off":
			chat_window.enabled = false
		_:
			chat_window.enabled = not _chat_relayed


func _build_console() -> DotResult:
	console = DotConsoleController.new()
	console.name = "Console"
	console.config = DotConsoleConfig.new()
	console.config.mirror_log = true
	console.config.mirror_from = DotLog.Level.INFO
	add_child(console)

	var res := console.setup()
	if not res.ok:
		return res.wrap("hungario's console")

	var local := DotConsoleLocal.new()
	local.add_command(&"help", "List what this client can do", func(_a: PackedStringArray) -> Variant:
		var lines := PackedStringArray(["Client commands:"])
		for n in console.all_names():
			lines.append("  %-18s %s" % [n, console.help_for(n)])
		return lines
	)
	local.add_command(&"quit", "Leave", func(_a: PackedStringArray) -> Variant:
		get_tree().quit()
		return null
	)
	local.add_command(&"settings", "Show every setting", func(_a: PackedStringArray) -> Variant:
		return settings.describe_lines()
	)
	local.add_command(&"audio", "Show the audio system", func(_a: PackedStringArray) -> Variant:
		return audio.describe_lines()
	)
	local.add_command(&"clear", "Empty the scrollback", func(_a: PackedStringArray) -> Variant:
		console.buffer.clear()
		return null
	)
	for key in settings.schema.keys():
		local.bind_setting(key, settings)
	console.add_source(local)

	var server: Object = DotRegistry.get_service(&"dot_server")
	if server != null and server.get("console") != null:
		console.add_source(DotConsoleBridge.wrap(server.get("console"), "server"))

	_layer = CanvasLayer.new()
	_layer.name = "ConsoleLayer"
	_layer.layer = 128
	add_child(_layer)

	console_panel = DotConsolePanel.new()
	console_panel.name = "ConsolePanel"
	console_panel.controller = console
	_layer.add_child(console_panel)
	return DotResult.success(null)


# --- What the game asks for -------------------------------------------------

func present(delta: float, listener: Vector2) -> void:
	audio.listener_position = Vector3(listener.x, 0.0, listener.y)
	fx.viewer_position = Vector3(listener.x, 0.0, listener.y)
	fx.advance(delta)


## Whether something on screen owns the keyboard right now.
##
## [b]The chat box belongs here for the reason the console does.[/b] This game is steered
## with the mouse, so a typed key does not walk anybody into a wall — but split, throw,
## boost and eject are all keys, and a player typing "gg boost" who splits twice and
## ejects their mass has lost the round to a chat box.
func swallows_input() -> bool:
	if console_panel != null and console_panel.has_keyboard_focus():
		return true

	return chat_window != null and chat_window.is_open()


func camera_shake() -> Vector2:
	return fx.shake.offset_2d()


# --- The events this game has -----------------------------------------------

func on_food_eaten(at: Vector2, tier: int) -> void:
	# The pitch comes from the food's size, which is `HungrySound`'s own mapping and the
	# one thing nobody has to be taught: bigger is lower. It goes through dot-audio as a
	# caller's pitch rather than being played beside it, because a sound played twice --
	# once through the manager's caps and once around them -- is two sounds and one of
	# them is not limited by anything.
	audio.play_at_2d(&"eat", at, 1.0, HungrySound.food_pitch(tier))
	fx.spawn_2d(&"eat_pop", at)


func on_fruit_eaten(at: Vector2) -> void:
	audio.play_at_2d(&"fruit", at)
	fx.spawn_2d(&"eat_pop", at)


## Eating somebody. Flat, because it is your own event and not a place in the world.
func on_devour() -> void:
	audio.play(&"devour")


func on_burst(at: Vector2, mine: bool) -> void:
	audio.play_at_2d(&"burst", at)
	fx.spawn_2d(&"burst", at)
	if mine:
		# Only your own. Somebody bursting across the arena is a picture; shaking the
		# camera for it in a game where that happens constantly is unplayable.
		fx.spawn(&"burst_shake", Transform3D.IDENTITY)
		fx.flash(&"threat")


func on_split() -> void:
	audio.play(&"split")


func on_pickup() -> void:
	audio.play(&"pickup")


func on_throw() -> void:
	audio.play(&"throw")


func on_died() -> void:
	audio.play(&"die")
	fx.flash(&"threat")


func on_click() -> void:
	audio.play(&"click")


func on_round_reset() -> void:
	# A round that announced itself before it reset left every client holding twice as
	# much food as existed, half of it phantoms. This is the drawing half of the same
	# thing: an effect about something that no longer exists.
	fx.clear()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("hungario's presentation layer")
	out.append_array(settings.describe_lines())
	out.append_array(audio.describe_lines())
	out.append_array(fx.describe_lines())
	return out
