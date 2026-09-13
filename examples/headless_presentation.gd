extends Node

const HungryConfig := preload("../game/hungry_config.gd")
const HungryParty := preload("../game/hungry_party.gd")
const HungryPresentation := preload("../game/client/hungry_presentation.gd")
const HungryServices := preload("../game/hungry_services.gd")
const HungrySound := preload("../game/client/hungry_sound.gd")
const HungrySoundSink := preload("../game/client/hungry_sound_sink.gd")

## Settings, audio, effects, the console and the private arena.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]The point of this game's integration is what it does NOT duplicate[/b], so that is
## what most of these checks are about: the settings schema is read out of `HungryConfig`
## rather than written beside it, and dot-audio's sink is `HungrySound` rather than a
## second bank. Both are the same decision twice — two copies of one list is this family's
## most repeated bug.
##
## Exits non-zero on any failure.

const CHECKS := 48

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario: the presentation layer")

	_test_schema_is_the_config()
	_test_sound_is_still_the_bank()
	_test_limits_the_bank_never_had()
	_test_effects()
	_test_console()
	_test_party()
	_test_chat_box()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _make() -> HungryPresentation:
	var p := HungryPresentation.new()
	p.name = "P%d" % _entered
	p.config = HungryConfig.new()
	p.sound = HungrySound.make()
	add_child(p.sound)
	add_child(p)
	p.setup()
	# A memory store, replacing the file one this game ships with.
	#
	# [b]A suite that writes to `user://` is a suite whose result depends on what the last
	# run left there.[/b] This game already shipped that bug once: `dedicated` recorded
	# bites against a fixed player key, the totals accumulated across runs, and it began
	# failing on its ninth run for a reason that had nothing to do with the code. Here it
	# was subtler -- a value stored by the previous run made `set_value` a no-op, the
	# signal never fired, and the check failed for a setting that was already correct.
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_schema_is_the_config() -> void:
	_section("The schema is HungryConfig, read rather than repeated")

	var config := HungryConfig.new()
	var schema := DotSettingsSchema.from_config(config, HungryPresentation.SCOPES)

	_check(schema.validate().ok, "a schema derived from the config validates")
	_check(
		schema.keys().size() == config.config_keys().size(),
		"with one entry per config key (%d against %d)"
		% [schema.keys().size(), config.config_keys().size()]
	)
	_check(schema.has(&"volume_db"), "including the volume")

	var vol := schema.find(&"volume_db")
	_check(
		vol.min_value < vol.max_value,
		"and its bounds come from the @export_range, so tightening the config tightens "
		+ "the slider and the console at once"
	)

	_check(
		schema.find(&"show_names").scope == DotSettingsDef.Scope.ACCOUNT,
		"the scope is the one thing a config cannot say, so it is passed in"
	)
	_check(
		schema.find(&"follow_sec").scope == DotSettingsDef.Scope.DEVICE,
		"and a camera follow time stays with the machine, because it is about this screen"
	)

	var p := _make()
	p.settings.set_value(&"volume_db", -20.0)
	_check(
		is_equal_approx(p.config.volume_db, -20.0),
		"a setting written through dot-settings reaches the config the game actually reads"
	)
	_check(
		is_equal_approx(p.sound.volume_db, -20.0),
		"and the bank, which is the value a player can hear"
	)
	p.queue_free()
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_sound_is_still_the_bank() -> void:
	_section("dot-audio's sink is the bank this game already had")

	var p := _make()
	var sink := p.audio.sink as HungrySoundSink
	_check(sink != null, "the sink is this game's, not dot-audio's own")
	if sink == null:
		p.queue_free()
		_done()
		return

	_check(sink.sound == p.sound, "with the generated bank behind it")
	_check(
		sink.sink_name() == "hungry",
		"and it says so, because a sink that lies about what it is makes a log useless"
	)

	# Every id in the catalogue has to have a cue, or it is a sound dot-audio decided
	# should be heard and nothing can make.
	var missing := PackedStringArray()
	for id in p.audio.catalogue.ids():
		if not HungrySoundSink.CUES.has(String(id)):
			missing.append(String(id))
	_check(
		missing.is_empty(),
		"every catalogue id maps to a cue (%s)" % ", ".join(missing)
	)

	_check(
		p.sound.baked() > 0,
		"the bank is baked arithmetically, so this ships no audio files at all"
	)
	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_limits_the_bank_never_had() -> void:
	_section("A monster in a dense field eats several times a second")

	var p := _make()
	var sink := p.audio.sink as HungrySoundSink
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	for _i in range(20):
		p.on_food_eaten(Vector2(5, 5), 2)
	_check(
		sink.count_of(&"eat") <= 4,
		"twenty bites in one tick make at most four sounds (%d), because nine blips in "
		% sink.count_of(&"eat")
		+ "one frame is a click rather than eating"
	)

	# The pitch is information -- bigger is lower -- and it has to survive the trip
	# through dot-audio rather than being played around it.
	# Past the cooldown the burst above just used. A check that measures a pitch while the
	# sound is being refused for a cooldown measures nothing, and reads as the pitch
	# mapping being broken.
	OS.delay_msec(60)
	sink.forget()
	p.on_food_eaten(Vector2(5, 5), 0)
	var small := sink.last_pitch(&"eat")
	OS.delay_msec(60)
	sink.forget()
	p.on_food_eaten(Vector2(5, 5), 5)
	var big := sink.last_pitch(&"eat")
	_check(small > 0.0 and big > 0.0, "both bites were heard")
	_check(
		big < small,
		"and a bigger mouthful is lower (%.2f against %.2f), which is the one mapping "
		% [big, small] + "nobody has to be taught"
	)

	sink.forget()
	p.on_food_eaten(Vector2(9000, 9000), 2)
	_check(
		sink.count_of(&"eat") == 0,
		"a bite on the far side of the arena costs nothing, because it is not information"
	)

	# The three that must never lose a voice to a crumb.
	var die := p.audio.catalogue.find(&"die")
	var eat := p.audio.catalogue.find(&"eat")
	_check(
		die.priority > eat.priority,
		"dying outranks eating, so a burst of crumbs cannot silence it"
	)

	p.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_effects() -> void:
	_section("Only your own burst shakes your camera")

	var p := _make()
	p.fx.viewer_position = Vector3.ZERO

	p.fx.flash_colour.a = 0.0
	p.on_burst(Vector2(10, 10), false)
	p.present(0.016, Vector2.ZERO)
	_check(
		p.camera_shake() == Vector2.ZERO,
		"somebody else bursting across the arena is a picture and not a shake"
	)
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and does not tint the screen either"
	)

	p.on_burst(Vector2(10, 10), true)
	p.present(0.016, Vector2.ZERO)
	_check(p.camera_shake() != Vector2.ZERO, "while your own does both")
	_check(p.fx.flash_colour.a > 0.0, "including the tint")

	p.on_round_reset()
	_check(p.fx.live_count() == 0, "a round reset takes every effect with it")

	p.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("Every config key is a console variable")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in p.settings.schema.keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(
		missing.is_empty(),
		"every setting is reachable from a keyboard (%s)" % ", ".join(missing)
	)

	p.console.submit("volume_db -30")
	_check(
		is_equal_approx(p.config.volume_db, -30.0),
		"a console line writes the config, not a second copy of the value"
	)
	_check(
		is_equal_approx(p.sound.volume_db, -30.0),
		"and the bank, because there is one path"
	)

	p.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_party() -> void:
	_section("A private arena whose host may leave")

	DotP2PSignallerLoopback.reset_all()

	var party := HungryParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The axis where this game disagrees with game-arena, and it follows from what kind of
	# game it is: there is no round to be in the middle of.
	_check(
		party.session.config.migrate_host,
		"a continuous arena migrates its host, where a round-based deathmatch does not"
	)
	_check(
		party.session.config.trust == DotP2PConfig.Trust.SANDBOXED,
		"and files nothing anywhere, because this game unlocks achievements and a "
		+ "peer-to-peer host can lie about how much they ate"
	)

	_check(party.reporting_allowed(), "an ordinary session files what it likes")
	party.session._state = &"hosting"
	_check(not party.reporting_allowed(), "and a live private one files nothing")

	party.queue_free()
	_done()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition


func _test_chat_box() -> void:
	_section("A chat box that is not a screen, and the three answers to whether it is drawn")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds a chat box at all")

	if window == null:
		_done()
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)

	# The channels are the server's own definitions rather than a second list.
	var ids := PackedStringArray()
	for entry in window.channels:
		ids.append(String(entry.get("id", "")))
	_check(
		Array(ids).has(String(HungryServices.CHANNEL_ALL))
			and Array(ids).has(String(HungryServices.CHANNEL_NEAR)),
		"offering the channels the server actually routes (%s)" % [ids]
	)

	_check(window.enabled, "drawn by default, on a server that said nothing")

	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes it away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.settings.set_value(&"chat_window", &"auto")
	p.set_chat_relayed(false)
	_check(window.enabled, "and auto gives it back")

	# [b]The binding is stored beside the config, never in it.[/b] A `DotConfig` is layered
	# from a file, the environment and argv, and a chat key arriving from a server's
	# command line would rebind every player on it.
	_check(
		not p.config.has_key("chat_open_key"),
		"the chat key is NOT a config value a server could set"
	)

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# Split, throw, boost and eject are all keys here: "gg boost" splits you twice.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does, so a typed key is not a split")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	_done()
