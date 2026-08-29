class_name HungryClient
extends Node2D

## The playable client: a world, a camera, a renderer, a HUD and a socket.
##
## [b]This is the scene a [DotClientLink] loads.[/b] dot-server's signon gets a player
## from "typed an address" to "in the world" and then hands over by instantiating the
## descriptor's client scene under the client's game root; everything from that point is
## this file's.
##
## [codeblock]
## HungryClient
##   World      HungryWorld, not authoritative
##   Net        DotNetManager, a client
##   Bridge     HungryNetBridge — creates the link under the DotClientLink
##   Renderer   HungryRenderer
##   Camera     HungryCamera
##   Input      HungryInput
##   UI         CanvasLayer
##     Screens  DotScreenStack — pause, settings, controls, scoreboard, chat
##     Hud      HungryHud
## [/codeblock]
##
## [b]It also runs standalone.[/b] With no [DotClientLink] to be found it builds an
## authoritative world with bots in it and plays that, which is what
## [code]--offline[/code] is for and what makes the controls testable without a server.

const CHANNEL := "hungry.client"

## Registry name [DotClientLink] publishes itself under.
const LINK_SERVICE := &"dot_client_link"

## How often the leaderboard is rebuilt. It is a table of [Label]s and the numbers on it
## change slowly; rebuilding it per frame is most of a frame's layout budget for nothing.
const BOARD_INTERVAL_SEC := 0.5

## Bots to keep alive in offline mode, so there is something to play against.
@export_range(0, 32, 1) var offline_bots: int = 6

## Play alone against bots even if a link is available. Set by `--offline`.
@export var force_offline: bool = false

var world: HungryWorld = null
var net: DotNetManager = null
var bridge: HungryNetBridge = null
var renderer: HungryRenderer = null
var camera: HungryCamera = null
var sampler: HungryInput = null
var hud: HungryHud = null
var sound: HungrySound = null
var screens: DotScreenStack = null
var ui_config: DotUiConfig = null

## What this player has chosen. Loaded at startup, written back on Apply.
var settings: HungryConfig = null

## The connection, when there is one.
var link: Node = null

var _pause: HungryMenus.PauseScreen = null
var _offline: bool = false
var _tick: int = 0
var _board_accum: float = 0.0

## What the local monster weighed and carried last frame, for the sound. See
## [method _watch_mass].
var _last_mass: float = 0.0
var _last_carried: int = 0

## Who ate us, so a dead player has somebody to watch. See [method _watched].
var _watching: int = 0
var _bots: Array[int] = []


func _ready() -> void:
	DotLog.info(CHANNEL, "client starting")

	link = DotRegistry.get_node_service(LINK_SERVICE)
	_offline = force_offline or link == null \
		or "--offline" in OS.get_cmdline_user_args()

	var built := _build()

	if not built.ok:
		DotLog.result(CHANNEL, "the client could not start", built)
		return

	if _offline:
		_start_offline()
	elif link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_for_world()
	elif link.has_signal("spawned"):
		# The scene can legitimately exist before the signon finishes — a host that
		# instantiates it up front, an editor run — and asking a server that has not
		# admitted this peer yet is a request it will drop. Waiting for `spawned` is the
		# same wait [DotClientLink] already does.
		link.connect("spawned", bridge.ask_for_world, CONNECT_ONE_SHOT)
	else:
		bridge.ask_for_world()


func _build() -> DotResult:
	world = HungryWorld.new()
	world.name = "World"
	world.preset = HungryPreset.classic()
	world.tick_rate = HungryContent.TICK_RATE
	# Authoritative only when there is nobody else to be. A client that resolved its own
	# eating would be a client that decides what it weighs.
	world.is_authority = _offline
	world.register_service = true
	world.service_scope = &"client"
	add_child(world)

	var ready_result := world.setup()

	if not ready_result.ok:
		return ready_result

	if _offline:
		world.start(0)
	else:
		var netted := _build_netcode()

		if not netted.ok:
			return netted

	_build_view()
	_build_ui()
	return DotResult.success(self)


func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.service_scope = &"client"
	# The tick is driven here, because the input has to be recorded before the prediction
	# that replays it. See [method _physics_process].
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = world.tick_rate
	config.snapshot_rate = 20
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 120
	config.world_extent = Dot2DNetSync.WORLD_EXTENT
	net.config = config
	add_child(net)

	var ready_result := net.setup()

	if not ready_result.ok:
		return ready_result

	bridge = HungryNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	# Parented to the link, which is named to match the server's node, because Godot
	# routes an RPC by the receiver's path relative to its MultiplayerAPI root. See
	# [HungryNetLink].
	var attached := bridge.attach(world, net, link)

	if not attached.ok:
		return attached

	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.cue.connect(_on_cue)
	bridge.roster_changed.connect(_on_roster_changed)

	if link.has_signal("chat_received"):
		link.connect("chat_received", _on_chat)

	return net.start()


func _build_view() -> void:
	camera = HungryCamera.framing(_me_source(), world.arena)
	add_child(camera)
	camera.make_current()

	renderer = HungryRenderer.new()
	renderer.name = "Renderer"
	add_child(renderer)
	renderer.bind(world, camera, _local_player())

	sampler = HungryInput.measuring(_me_source(), camera)
	add_child(sampler)

	sound = HungrySound.make()
	add_child(sound)

	# The world's own signals fire only where this process is the authority, which for a
	# netted client is nowhere. Eating is therefore *watched* rather than listened for —
	# see [method _watch_mass] — and these three are the ones an offline game needs and a
	# netted one gets as cues instead.
	world.projectile_thrown.connect(_on_projectile_thrown)
	world.player_died.connect(_on_player_died)
	world.monster_burst.connect(_on_monster_burst)


func _build_ui() -> void:
	settings = HungryConfig.load_saved()

	ui_config = DotUiConfig.new()
	ui_config.allow_pause = _offline

	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)

	screens = DotScreenStack.new()
	screens.name = "Screens"
	screens.config = ui_config
	screens.load_layered_config = false
	screens.register_service = true
	screens.service_scope = &"hungry"
	# A blob game is played with a visible cursor: the cursor is the control.
	screens.idle_mouse_mode = DotScreen.Mouse.VISIBLE
	screens.ui_theme = DotUiTheme.dark()
	layer.add_child(screens)
	screens.setup()

	hud = HungryHud.new()
	hud.name = "Hud"
	hud.config = ui_config
	layer.add_child(hud)
	hud.build(world, bridge, _local_player())
	hud.bind_stack(screens)

	# The sampler reads the on-screen buttons directly. Built here rather than in the
	# sampler because whether a device wants them is a HUD question, and because the HUD
	# is what puts them inside the safe area.
	sampler.touch = hud.touch

	_pause = HungryMenus.install(screens, world, bridge, ui_config, settings)
	_pause.leave_pressed.connect(_on_leave)

	var settings_screen := screens.screen(&"settings") as HungryMenus.SettingsScreen

	if settings_screen != null:
		settings_screen.applied.connect(_on_settings_applied)

	_apply_settings()

	var chat := screens.screen(&"chat") as HungryMenus.ChatScreen

	if chat != null:
		chat.submitted.connect(_on_say)

	var loadout := screens.screen(&"loadout") as HungryMenus.LoadoutScreen

	if loadout != null:
		loadout.chosen.connect(_on_loadout_chosen)

	hud.say(
		"Move with the mouse — near is slow, far is fast.",
		Color(0.70, 0.78, 0.90)
	)
	hud.say(
		"Space splits, W ejects, Q throws. Let go of the mouse to gather.",
		Color(0.70, 0.78, 0.90)
	)
	hud.say(
		"Tab is the board, Enter is chat, Escape is the menu and your loadout.",
		Color(0.62, 0.68, 0.78)
	)


## What the camera frames and the pointer is measured from.
##
## [b]Not always your own monster.[/b] Being eaten in this game means having nothing at
## all — no pieces, no position, nowhere for a camera to be — and a camera left where you
## died is a black rectangle for three seconds while the fight that killed you carries on
## somewhere else. So a dead player watches whoever ate them, and if that player has since
## been eaten too, the leader.
##
## The [i]input[/i] reads the same source, which is deliberate: a dead player's pointer is
## measured from the monster they are watching, so the mouse is not silently pointing at
## nothing when they respawn.
func _me_source() -> Callable:
	return func() -> Variant:
		return _watched()


## The monster this client is looking at.
func _watched() -> HungryMonster:
	if world == null:
		return null

	var mine := world.monster_for(_local_player())

	if mine != null and mine.alive:
		return mine

	var killer := world.monster_for(_watching)

	if killer != null and killer.alive:
		return killer

	var board := world.leaderboard(1)
	return board[0] if not board.is_empty() and board[0].alive else mine


func _local_player() -> int:
	return bridge.local_player_id if bridge != null else 1


# --- The loop --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if world == null:
		return

	if _offline:
		_tick_offline(delta)
		return

	if net == null or not net.is_running():
		return

	# The clock is what puts the input ahead of the server. A command for tick N has to be
	# in the server's hands *before* it simulates N, so a client running level with the
	# server has every input arrive one tick late — for ever, with no error, and the only
	# symptom a player who feels heavy.
	var ticks := net.clock.advance(delta)

	for _i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick(), sampler.sample(delta))


func _process(delta: float) -> void:
	if net != null and net.is_running():
		# Interpolation runs at frame rate, not tick rate. Applying it on the tick would
		# quantise every remote monster's motion to 60 Hz and undo the point of it.
		net.interpolate_frame()

	_watch_mass()

	_board_accum += delta

	if _board_accum >= BOARD_INTERVAL_SEC:
		_board_accum = 0.0

		if hud != null:
			hud.refresh_leaderboard()

		var board := screens.screen(&"scoreboard") as HungryMenus.ScoreboardScreen \
			if screens != null else null

		if board != null and screens.is_open(&"scoreboard"):
			board.refresh()


# --- Offline ---------------------------------------------------------------

## Builds a world with bots in it, for playing without a server.
##
## Not a demo mode bolted on: it is the same world, the same motor and the same
## [HungryBot] the dedicated server runs, with the netcode taken out. That it plays
## identically is the useful property — a control that feels wrong offline is wrong, and
## debugging it does not need two processes.
func _start_offline() -> void:
	world.add_player(1, "You")

	for index in range(offline_bots):
		var id := 100 + index
		world.add_player(id, "Bot %d" % (index + 1))
		_bots.append(id)

	DotLog.info(CHANNEL, "playing offline", {"bots": _bots.size()})


func _tick_offline(_delta: float) -> void:
	_tick += 1

	var commands: Dictionary = {1: sampler.sample()}

	for id in _bots:
		var monster := world.monster_for(id)

		if monster != null:
			commands[id] = HungryBot.command_for(world, monster, _tick)

	world.tick(commands)


# --- Events ----------------------------------------------------------------

func _on_hello(player_id: int) -> void:
	DotLog.info(CHANNEL, "admitted", {"player": player_id})

	if hud != null:
		hud.follow(player_id)
		hud.watching_source = _watched

	if renderer != null:
		renderer.local_player_id = player_id

	# The screen opens on what the player is actually wearing rather than on the schema's
	# default, which is what the server sent in the join.
	var loadout := screens.screen(&"loadout") as HungryMenus.LoadoutScreen
	var monster := world.monster_for(player_id)

	if loadout != null and monster != null and monster.loadout != null:
		loadout.show_loadout(monster.loadout)

	_fetch_cosmetics(bridge.avatar_pack_url)

	# The rider goes up as soon as there is somebody to put one on. A stored avatar would
	# come from dot-user-avatar's manager; without one the deterministic guest is what
	# every other client already draws for this id, so publishing it costs nothing and
	# keeps one code path.
	bridge.publish_avatar(HungryContent.default_avatar(player_id))


## Downloads this server's rider content, if it has any and this build can.
##
## [b]Nothing waits for it.[/b] A rider whose parts have not arrived is drawn instead, so
## a player is in the world immediately and their cosmetics improve when they land. That
## ordering is the whole reason [HungryRider] draws a fallback: a cosmetic somebody else
## is wearing is not something you can be made to wait for.
##
## dot-cloud is duck-typed, so a build without it simply never has anything to ask.
func _fetch_cosmetics(manifest_url: String) -> void:
	if manifest_url == "":
		return

	var cloud := DotRegistry.get_service(HungryContentSource.CLOUD_SERVICE)

	if cloud == null or not cloud.has_method("acquire"):
		DotLog.info(CHANNEL, "the server has rider content and this build cannot fetch it")
		return

	DotLog.info(CHANNEL, "fetching rider content", {"url": manifest_url})

	var acquired: Variant = await cloud.call("acquire", manifest_url)

	if acquired is DotResult and not (acquired as DotResult).ok:
		# Not a failure worth interrupting anybody for: the parts fall back to being
		# drawn, which is what every client without the pack already sees.
		DotLog.info(CHANNEL, "rider content did not arrive", {
			"error": str((acquired as DotResult).error)
		})


func _on_cue(kind: int, data: Dictionary) -> void:
	if hud != null:
		hud.note(kind, data)

	if sound == null:
		return

	# Only what happened to somebody. A cue is the authority telling every client, so
	# playing all of them would mean hearing every death on the map — which at sixteen
	# players is a wall of noise that says nothing about your own game.
	var me := _local_player()

	match kind:
		HungryEvents.Kind.DIED:
			if int(data.get("first", 0)) == me:
				sound.play(HungrySound.Cue.DIE)
				_watching = int(data.get("second", 0))
			elif int(data.get("second", 0)) == me:
				sound.play(HungrySound.Cue.DEVOUR)

		HungryEvents.Kind.BURST:
			if int(data.get("first", 0)) == me or int(data.get("second", 0)) == me:
				sound.play(HungrySound.Cue.BURST)

		HungryEvents.Kind.THROW:
			sound.play(HungrySound.Cue.THROW)


## Turns "I got bigger" into a noise.
##
## [b]Watched rather than listened for, and that is not a shortcut.[/b]
## [signal HungryWorld.food_eaten] fires on the authority, which on a netted client is
## somewhere else — so a client that hooked it would be silent for the entire game and
## perfectly noisy offline, which is exactly the kind of difference nothing catches. What
## a player actually perceives is their own mass going up, and that arrives either way.
##
## Several crumbs swallowed between two snapshots become one blip. That is the right
## trade: nine blips in the same frame is a click, and the pitch already says how much it
## was worth.
func _watch_mass() -> void:
	if sound == null:
		return

	var monster := world.monster_for(_local_player()) if world != null else null

	if monster == null or not monster.alive:
		_last_mass = 0.0
		_last_carried = 0
		return

	var mass := monster.mass()

	if _last_mass <= 0.0:
		# First look, or the first frame after a respawn. A monster appearing at its
		# starting mass has not eaten anything.
		_last_mass = mass
		_last_carried = monster.carried.size()
		return

	var gained := mass - _last_mass
	_last_mass = mass

	if gained >= HungryContent.FRUIT_MASS * 0.8:
		sound.play(HungrySound.Cue.FRUIT)
	elif gained >= 0.5:
		# Pitched by how much it was worth, through the same curve the food tiers use, so
		# a haunch and a crumb are the same blip an octave apart.
		sound.play(
			HungrySound.Cue.EAT,
			HungrySound.food_pitch(HungryContent.food_tier(
				clampf(gained / 30.0, 0.0, 0.999)
			))
		)

	var carried := monster.carried.size()

	if carried > _last_carried:
		sound.play(HungrySound.Cue.PICKUP)

	_last_carried = carried


func _on_projectile_thrown(shot: HungryProjectile) -> void:
	if sound != null and shot.thrower_id == _local_player():
		sound.play(HungrySound.Cue.THROW)


func _on_player_died(player_id: int, killer_id: int) -> void:
	if sound == null:
		return

	if player_id == _local_player():
		sound.play(HungrySound.Cue.DIE)
		_watching = killer_id
	elif killer_id == _local_player():
		sound.play(HungrySound.Cue.DEVOUR)


func _on_monster_burst(player_id: int, by_player: int, _count: int) -> void:
	if sound != null and (
		player_id == _local_player() or by_player == _local_player()
	):
		sound.play(HungrySound.Cue.BURST)


func _on_roster_changed(player_id: int) -> void:
	if renderer != null and world != null and world.monster_for(player_id) == null:
		renderer.forget(player_id)


## Sends a chosen loadout, and says what happens next.
##
## The server validates it and it takes effect on the next spawn — a player who could
## change their trait mid-fight would change it the moment they were losing — so the feed
## says so rather than leaving them wondering whether the button did anything.
## Pushes the player's settings at everything that reads one.
##
## [b]Pushed rather than read.[/b] The camera, the sound and the HUD each hold the value
## they were given; making them ask a config every frame would put a dictionary lookup in
## the draw path for something that changes when somebody opens a menu.
func _apply_settings() -> void:
	if settings == null:
		return

	if sound != null:
		sound.volume_db = settings.volume_db
		sound.muted = settings.muted

	if camera != null:
		camera.follow_sec = settings.follow_sec
		camera.zoom_with_size = settings.zoom_with_size

	if renderer != null:
		renderer.show_names = settings.show_names
		renderer.show_threat = settings.show_threat

	if hud != null:
		hud.set_minimap_visible(settings.show_minimap)

		if hud.feed != null:
			hud.feed.max_lines = settings.feed_lines


func _on_settings_applied(_config: DotConfig) -> void:
	_apply_settings()

	var saved := settings.save()

	if not saved.ok:
		DotLog.result(CHANNEL, "could not save the settings", saved)
		return

	if hud != null:
		hud.say("Settings saved.", Color(0.62, 0.78, 0.68))


func _on_loadout_chosen(loadout: DotLoadout) -> void:
	if bridge != null:
		bridge.publish_loadout(loadout)

	if hud != null:
		hud.say(
			"Loadout sent. It takes effect the next time you spawn.",
			Color(0.70, 0.82, 0.95)
		)


func _on_chat(payload: Dictionary) -> void:
	if hud != null:
		hud.chat(payload)


func _on_say(text: String) -> void:
	if link != null and link.has_method("send_chat"):
		link.call("send_chat", text, false)
	elif hud != null:
		hud.say("(offline) %s" % text, Color(0.6, 0.62, 0.66))


func _on_leave() -> void:
	if link != null and link.has_method("disconnect_from_server"):
		link.call("disconnect_from_server", "left")
	else:
		get_tree().quit(0)


# --- Input -----------------------------------------------------------------

## The three keys that are not movement.
##
## Handled here rather than in [HungryInput] because they open screens, and which screens
## exist is this file's business. [DotScreenStack] already owns the back key.
func _unhandled_input(event: InputEvent) -> void:
	if screens == null or not event.is_pressed() or event.is_echo():
		return

	if event.is_action_pressed(&"ui_text_newline") or _is_key(event, KEY_ENTER):
		if not screens.is_open(&"chat"):
			screens.push(&"chat")
			get_viewport().set_input_as_handled()
		return

	if _is_key(event, KEY_TAB):
		screens.toggle(&"scoreboard")
		get_viewport().set_input_as_handled()
		return

	if _is_key(event, KEY_ESCAPE) and not screens.any_open():
		screens.push(&"pause")
		get_viewport().set_input_as_handled()


static func _is_key(event: InputEvent, key: Key) -> bool:
	var typed := event as InputEventKey
	return typed != null and typed.physical_keycode == key


func describe() -> Dictionary:
	return {
		"offline": _offline,
		"player": _local_player(),
		"world": world.describe() if world != null else {},
		"bridge": bridge.describe() if bridge != null else {},
	}
