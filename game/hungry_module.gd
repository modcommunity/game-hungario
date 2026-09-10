class_name HungryModule
extends DotModule

## Binds a [HungryWorld] and its netcode to a [DotServer].
##
## The only file in this project that names dot-server, and the whole of the dedicated
## server integration: the tick, the join, the console surface, the bots, and the two game
## descriptors that make `changegame` mean something.
##
## [codeblock]
## server.modules.load_module("res://game/hungry_module.gd")
## [/codeblock]
##
## [b]The manager outlives the world, and that is the point.[/b] A game change frees the
## scene the world lives in and instantiates the next one; rebuilding the
## [DotNetManager] with it would reset the message ids, the peer records and the clock,
## which is a disconnect for everybody — exactly what changing the map is supposed to
## avoid. So the manager and the bridge are the module's, and the bridge is rebound.

const CHANNEL := "hungry.module"

## Snapshots a second. Twenty is the number [Dot2DNetSync.estimated_bits] was sized
## against: a hundred visible pieces at 104 bits each is about 1.3 kB a snapshot, so 20 Hz
## is 26 kB/s to a player in a crowd and a great deal less to everybody else.
const SNAPSHOT_RATE := 20

## Ids at or above this belong to bots. Well clear of anything [DotServer] hands out,
## which counts up from 1.
const BOT_ID_BASE := 900001

## The three modes this server can switch between.
const GAME_CLASSIC := "hungry_classic"
const GAME_FRENZY := "hungry_frenzy"
const GAME_GAUNTLET := "hungry_gauntlet"

var world: HungryWorld = null
var net: DotNetManager = null
var bridge: HungryNetBridge = null

## What players may bring in, and where their choices are kept.
##
## Backed by memory, which is the right default for a dedicated server: a loadout that
## outlives a session is a profile, and a profile is dot-user's. An operator who wants
## them to persist points the config at the local backend, or subclasses
## [DotLoadoutStore] and points it at their own service — that is the seam, and it is why
## this is a manager rather than a dictionary.
var loadouts: DotLoadoutManager = null

## Chat, moderation and voice. Built here rather than in the world, because they are about
## the people connected rather than about the arena — a game change frees the world and
## these have to survive it, exactly as the netcode manager does.
var services: HungryServices = null

## NPC monsters, and the director that decides when they arrive.
var hunters: HungryHunters = null

## Rocks, spikes and lures.
var hazards: HungryHazards = null

## What a throwable does to somebody, through dot-combat's rules.
var combat: HungryCombat = null

## Boards and achievements over the numbers this game already counts.
var progress: HungryProgress = null

## The three modes as maps, the rotation, and the vote over them.
var maps: HungryMaps = null

## Reports this server to its site listing, when an operator has configured one.
##
## Null on a server with no integration token, which is every LAN game and every test.
var backbone: DotBackboneClient = null

## Counts what every monster did, and reports it through [member backbone].
##
## Always built, because the session figures are the game's own (a match summary
## reads them) and counting costs nothing; reporting happens only when there is a
## backbone to report through. Players are keyed by the scoped id dot-platform
## resolved, never the account id — a session with no scoped key, which is every
## guest on a LAN server, is counted under nothing and reported nowhere.
var stats: DotStatsTracker = null

## userid -> the scoped key the tracker knows them by.
var _stat_keys: Dictionary = {}

## userid -> true, for the humans this module put in the world.
var _joined: Dictionary = {}

## player id -> display name, for the bots.
var _bots: Dictionary = {}

var _next_bot_id: int = BOT_ID_BASE
var _tick: int = 0

var _cv_bots: DotConVar = null
var _cv_pack: DotConVar = null
var _cv_auth_config: DotConVar = null
var _cv_hunters: DotConVar = null
var _cv_hazards: DotConVar = null

## Who last said something. What `hungry_status` reports, off the accepted line.
var _last_spoke: String = ""


func _module_name() -> String:
	return "hungry"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "Monsters that eat: food, fruit, throwables, and each other."


func _module_author() -> String:
	return "dot"


# --- Lifecycle -------------------------------------------------------------

func _module_load() -> DotResult:
	world = DotRegistry.get_node_service(HungryWorld.SERVICE) as HungryWorld

	if world == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No HungryWorld is registered.",
			"load a mode scene first, or set DotGameManager.initial_game to '%s'"
				% GAME_CLASSIC
		)

	var netted := _build_netcode()

	if not netted.ok:
		return netted

	var loadouts_ready := _build_loadouts()

	if not loadouts_ready.ok:
		return loadouts_ready

	hook_post("client_spawn", _on_client_spawn)
	server.client_disconnected.connect(_on_client_disconnected)

	# [b]dot-server's own chat is cancelled here rather than listened to.[/b]
	# [DotChatRouter] has the rules now — channels, a radius, a backlog, a `/me`, and a
	# gag that survives a reconnect — and the one thing that must not happen is both
	# running: two sets of rules to keep in step, and the one that skipped the filter
	# would be the one that leaked admin chat. A pre-hook is what can cancel;
	# [method DotChatManager.handle_message] broadcasts the moment the event returns.
	hook_pre("player_chat", _on_player_chat)

	# dot-chat makes the join and leave notices now, so dot-server's would be a second
	# one on a second path.
	if server.chat != null:
		server.chat.announce_joins = false

	_register_games()
	_register_console()

	_build_reporting()
	_build_stats()

	var extras := _build_extras()

	if not extras.ok:
		return extras

	if Engine.physics_ticks_per_second != world.tick_rate:
		# Not corrected here: `sv_tickrate` is the operator's and this module is a guest
		# in their server. Loud, because the symptom otherwise is a game that runs at the
		# wrong speed with nothing in the log about it.
		log_warn("sv_tickrate does not match the world's tick rate", {
			"engine": Engine.physics_ticks_per_second,
			"world": world.tick_rate,
		})

	world.start(0)

	if maps != null:
		maps.note_playing(StringName(world.preset.id))

	log_info("hungry loaded", {
		"preset": String(world.preset.id),
		"world": world.world_size,
		"food": world.field.food_count(),
	})

	return DotResult.success(null)


func _module_unload() -> void:
	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	# Every player this module put in the world comes out with it. A module that unloaded
	# and left them there would leave the world holding monsters whose sessions no longer
	# exist, and a netcode manager holding peers nothing will ever drive.
	if bridge != null and is_instance_valid(bridge):
		for userid in _joined.keys():
			bridge.remove_peer(bridge.peer_for_player(int(userid)))

	if world != null and is_instance_valid(world):
		for bot_id in _bots.keys():
			world.remove_player(int(bot_id))

	_joined.clear()
	_bots.clear()

	if backbone != null and is_instance_valid(backbone):
		# A listing that shows a dead server as full for the length of the backbone's
		# staleness window is worse than one that shows nothing, so this is worth trying —
		# and it is only a try. `report_offline` suspends on an HTTP request and this is
		# not a coroutine, so what actually happens is the request is issued and the node
		# is freed at the end of the frame with the reply unread. A process that exits
		# first abandons it, which is exactly what the staleness window exists to cover.
		#
		# Queued rather than removed: taking it out of the tree now would pull the HTTP
		# client out from under the request that was just started.
		backbone.report_offline()
		backbone.queue_free()
		backbone = null

	if net != null and is_instance_valid(net):
		net.stop()


## Rebinds onto the world the new mode brought with it.
##
## Called by [DotModuleHost] after [DotGameManager] has swapped the scene. The world is a
## different object; every player and every connection is the same one.
func _module_game_changed(content_key: String) -> void:
	var next := DotRegistry.get_node_service(HungryWorld.SERVICE) as HungryWorld

	if next == null:
		log_warn("the new game registered no world; the module is now idle", {
			"content_key": content_key
		})
		world = null
		return

	if next == world:
		return

	world = next

	# Everything that holds a world holds the new one. A layer left pointing at a freed
	# scene is a use-after-free on the next tick, and the ones that hold *placements*
	# rather than nodes have to be told to forget them — the arena is a different shape
	# now and a rock from the last mode would be a rock in the wall.
	if hunters != null:
		hunters.world = world
		hunters.spawner.clear_all()

	if hazards != null:
		hazards.world = world
		hazards.clear_all()

	if services != null:
		services.world = world

	if combat != null:
		world.damage_gate = combat.gate

	if progress != null:
		progress.mode_id = StringName(next.preset.id)

	if maps != null:
		maps.note_playing(StringName(next.preset.id))

	var rebound := bridge.rebind(world)

	if not rebound.ok:
		log_warn("could not rebind the bridge", {"error": str(rebound.error)})
		return

	# The bots are the old world's. Their ids are not reused, because a client that still
	# holds the old monster under that id would otherwise be handed a new one silently.
	_bots.clear()

	world.start(_tick)

	log_info("rebound onto a new world", {
		"preset": String(world.preset.id), "content_key": content_key
	})


## Everything that is not the netcode, the loadouts or the stats.
##
## [b]Built in this order because each one needs the last.[/b] The services register a
## mute source that the chat router warns about the absence of; the progress layer takes
## its readings from the stats tracker; the hunters and the hazards both act on the world
## and are announced through the bridge. None of it suspends, because
## [method DotModuleHost.load_module] does not await `_module_load` and a module whose load
## suspends returns null to it.
func _build_extras() -> DotResult:
	var serviced := _build_services()

	if not serviced.ok:
		return serviced

	var fought := _build_combat()

	if not fought.ok:
		return fought

	var hunted := _build_hunters()

	if not hunted.ok:
		return hunted

	var earned := _build_progress()

	if not earned.ok:
		return earned

	return _build_maps()


func _build_services() -> DotResult:
	services = HungryServices.new()
	services.name = "Services"
	services.bridge = bridge
	services.world = world
	services.server = server
	services.punishments_path = "user://hungry_punishments.json"
	add_child(services)

	var ready := services.setup()

	if not ready.ok:
		return ready.wrap("The services could not be set up")

	bridge.say_requested.connect(_on_say_requested)
	bridge.voice_requested.connect(_on_voice_requested)
	bridge.vote_requested.connect(_on_vote_requested)
	services.command_entered.connect(_on_chat_command)

	# The server's own view of a bubble, off the one signal that fires after a line has
	# been accepted — not off the request, or a line refused for being a duplicate would
	# still be attributed to somebody.
	services.chat.message_accepted.connect(_on_chat_accepted)

	return DotResult.success(null)


func _build_combat() -> DotResult:
	combat = HungryCombat.new()
	combat.name = "Combat"
	add_child(combat)

	var ready := combat.setup()

	if not ready.ok:
		return ready.wrap("The combat rules could not be set up")

	# The world asks and dot-combat answers. Unset — which is what every deployment
	# without this addon has — leaves the constants this game has always used.
	world.damage_gate = combat.gate

	return DotResult.success(null)


func _build_hunters() -> DotResult:
	hunters = HungryHunters.new()
	hunters.name = "Hunters"
	add_child(hunters)

	var ready := hunters.setup(true, world)

	if not ready.ok:
		return ready.wrap("The hunters could not be set up")

	hazards = HungryHazards.new()
	hazards.name = "Hazards"
	add_child(hazards)

	var placed := hazards.setup(true, world)

	if not placed.ok:
		return placed.wrap("The hazards could not be set up")

	hunters.hunter_changed.connect(_on_hunter_changed)
	hunters.piece_hunted.connect(_on_piece_hunted)
	hazards.placed.connect(_on_hazard_placed)
	hazards.cleared.connect(_on_hazard_cleared)
	hazards.struck.connect(_on_hazard_struck)

	return DotResult.success(null)


func _build_progress() -> DotResult:
	progress = HungryProgress.new()
	progress.name = "Progress"
	progress.stats = stats
	progress.backbone = backbone
	progress.mode_id = StringName(world.preset.id)
	add_child(progress)

	var ready := progress.setup()

	if not ready.ok:
		return ready.wrap("Progress could not be set up")

	progress.earned.connect(_on_earned)

	return DotResult.success(null)


func _build_maps() -> DotResult:
	maps = HungryMaps.new()
	maps.name = "Maps"
	maps.player_count_fn = func() -> int: return world.player_ids().size()
	maps.is_admin_fn = _voter_is_admin
	add_child(maps)

	var ready := maps.setup(server.games)

	if not ready.ok:
		return ready.wrap("The map rotation could not be set up")

	maps.change_due.connect(_on_change_due)
	maps.announced.connect(_on_vote_announced)

	return DotResult.success(null)


# --- Netcode ---------------------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	# The module drives the tick, because the world's tick has to happen *inside*
	# dot-net's — between applying inputs and building the snapshot. See
	# [method HungryNetBridge.server_tick].
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = world.tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	# The pieces are what a snapshot is made of, and a crowded fight is a lot of them.
	config.max_entities_per_snapshot = 120
	config.world_extent = Dot2DNetSync.WORLD_EXTENT
	net.config = config

	add_child(net)

	var ready_result := net.setup()

	if not ready_result.ok:
		return ready_result.wrap("The netcode could not start")

	bridge = HungryNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	# The link is parented to the server node, because Godot routes an RPC by the
	# receiver's path and a client's [DotClientLink] is named to match. See
	# [HungryNetLink].
	var attached := bridge.attach(world, net, server)

	if not attached.ok:
		return attached

	var started := net.start()

	if not started.ok:
		return started

	return DotResult.success(null)


# --- Loadouts --------------------------------------------------------------

func _build_loadouts() -> DotResult:
	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.schema = bridge.loadout_schema
	loadouts.register_service = true
	loadouts.load_layered_config = false
	loadouts.config_file = ""

	var config := DotLoadoutConfig.new()
	config.backend = "memory"
	config.allow_default_loadout = true
	# Conform on the way out of the store, validate on the way in from a client. Retiring
	# an item or revoking an unlock makes a saved loadout invalid, and refusing it is a
	# player who has not played for a month loading into an error rather than into a
	# slightly different monster.
	config.conform_on_load = true
	config.enforce_entitlements = true
	# A player changing their trait mid-fight would change it the moment they were losing.
	# A published loadout takes effect on the next spawn.
	config.allow_live_changes = false
	loadouts.config = config

	add_child(loadouts)

	var ready_result := loadouts.setup()

	if not ready_result.ok:
		return ready_result.wrap("The loadout manager could not start")

	loadouts.entitlement_source = _entitlements_for_key
	bridge.entitlement_source = _entitlements_for_player
	bridge.loadout_sink = _store_loadout

	return DotResult.success(null)


## What a player owns.
##
## [b]Nothing, by default, and deliberately.[/b] A server that granted everything would
## work perfectly in every test, ship, and quietly be a game where every unlock is free —
## and nobody reports that as a bug. Only items marked free are permitted until something
## says otherwise, and the something is dot-platform: an entitlement source there is
## whatever a deployment's store or backbone says.
func _entitlements_for_key(user_key: String) -> DotLoadoutEntitlements:
	var granted := DotLoadoutEntitlements.none()
	var platform: Object = server.modules.get_module("platform")

	if platform == null or not platform.has_method("entitlements_for"):
		return granted

	var owned: Variant = platform.call("entitlements_for", user_key)

	if owned is PackedStringArray or owned is Array:
		for id in (owned as Array if owned is Array else Array(owned)):
			granted.grant(StringName(str(id)))

	return granted


func _entitlements_for_player(player_id: int) -> DotLoadoutEntitlements:
	return _entitlements_for_key(HungryContent.loadout_key(player_id))


## Saves a published loadout, so it survives a respawn and a mode change.
##
## Through the manager rather than straight to the store, because the manager is the trust
## boundary: rate limit, per-player cap, schema membership, entitlements and key
## usability, in that order. The bridge has already validated the document against the
## schema; doing it twice costs nothing and means neither half can be the only check.
func _store_loadout(player_id: int, loadout: DotLoadout) -> DotResult:
	# Awaited: a store write may be slow — the whole reason DotLoadoutStore is pluggable
	# is that somebody will point it at a database — and the cache must not be updated
	# before the write succeeds. A player who sees their change, plays with it and loses
	# it at the next load with no explanation is worse than a refusal.
	return await loadouts.publish(HungryContent.loadout_key(player_id), loadout, 0)


## The loadout a player spawns with, loaded from the store.
##
## Awaited, and therefore not on the join path: a store may be slow and a join may not be.
## The player is in the world with the schema's default and their own arrives a moment
## later, which is the same trade game-arena makes for the same reason.
func _apply_stored_loadout(player_id: int) -> void:
	var active: DotResult = await loadouts.active_for(
		HungryContent.loadout_key(player_id)
	)

	if not active.ok or world == null:
		return

	var monster := world.monster_for(player_id)

	if monster == null:
		return

	monster.wear_loadout(active.value)
	bridge._announce(monster)


# --- Reporting to the site -------------------------------------------------

## Starts reporting this server to its listing, if an operator has configured one.
##
## [b]The token comes from a config file and from nowhere else.[/b] `DotAuthConfig` lists
## `integration_token` in its sensitive keys, so the layered loader refuses it from the
## environment and from argv — both are readable by other processes on the box and both
## end up in `ps` output and in pasted bug reports. A cvar would be worse still: it is
## settable over RCON and printable by anybody with the `cvar` flag.
##
## Absent one, nothing here runs and the server is simply not listed, which is the correct
## behaviour for a LAN game and for every test.
func _build_reporting() -> void:
	var config := DotAuthConfig.new()
	var path := _cv_auth_config.get_string() if _cv_auth_config != null else ""

	if path != "" and FileAccess.file_exists(path):
		var loaded := config.load_layered(path)

		if not loaded.ok:
			log_warn("could not read the backbone configuration", {
				"path": path, "error": str(loaded.error)
			})
			return

	if config.integration_token.strip_edges() == "":
		log_info("no integration token; this server will not appear in a listing", {
			"config": path
		})
		return

	backbone = DotBackboneClient.new()
	backbone.name = "Backbone"
	backbone.config = config
	# Sampled when they are sent rather than pushed when they change, which is the whole
	# reason these are callables: a report is a snapshot of now, not of the last time
	# somebody joined.
	backbone.stats_provider = stats_report
	backbone.roster_provider = roster_report
	add_child(backbone)

	var started := backbone.start()

	if not started.ok:
		log_warn("backbone reporting did not start", {"error": str(started.error)})
		remove_child(backbone)
		backbone.queue_free()
		backbone = null
		return

	log_info("reporting to the site listing", {"url": config.backbone_url})


## What this server looks like from outside.
##
## [b]dot-server's own report says `bots: 0` unconditionally[/b], because dot-server has no
## bots and no way to know a game has any. This one does, and a listing that shows eight
## players on a server holding one human is a listing that stops being trusted. The map is
## the mode rather than the content id for the same reason: `hungry_frenzy` means something
## to somebody reading a server browser.
##
## Public so it can be checked without a token, which is the only way it is ever checked
## here — nothing in this repository has a backbone to send it to.
func stats_report() -> Dictionary:
	var report := server.to_stats_report()

	report["bots"] = bot_count()
	report["curUsers"] = _joined.size()
	report["gameMode"] = "ffa"

	if world != null and world.preset != null:
		report["map"] = String(world.preset.id)

	return report


func roster_report() -> Array:
	return server.to_roster_report()


# --- Statistics -------------------------------------------------------------

## What this game counts per player. Declared once; the site learns it at boot.
##
## Every stat is published: a grow-by-eating game has nothing to count privately.
## The kinds are the contract — `top_mass` is a BEST, so a monster that shrank
## keeps its record, and everything else adds.
static func stats_schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()
	for id in [&"food", &"fruit", &"pieces_eaten", &"kills", &"deaths", &"bursts", &"items"]:
		schema.define(id).publish = true
	var mass := schema.define(&"mass_eaten", DotStatsDef.Kind.COUNTER, "Mass eaten")
	mass.publish = true
	mass.decimals = 1
	var top := schema.define(&"top_mass", DotStatsDef.Kind.BEST, "Biggest")
	top.publish = true
	top.decimals = 1
	return schema


func _build_stats() -> void:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = stats_schema()
	stats.report_to_backbone = backbone != null
	stats.reporter.client = backbone
	add_child(stats)

	world.food_eaten.connect(_on_stat_food)
	world.fruit_eaten.connect(_on_stat_fruit)
	world.item_taken.connect(_on_stat_item)
	world.piece_eaten.connect(_on_stat_piece)
	world.player_died.connect(_on_stat_death)
	world.monster_burst.connect(_on_stat_burst)


## The tracker's key for a world player id, or empty for a bot or a keyless guest.
func _stat_key(player_id: int) -> StringName:
	return StringName(str(_stat_keys.get(player_id, "")))


func _note_mass(player_id: int) -> void:
	var key := _stat_key(player_id)
	if key == &"":
		return
	var monster := world.monster_for(player_id)
	if monster != null:
		stats.record(key, &"top_mass", monster.mass())


func _on_stat_food(player_id: int, _grid_id: int, mass: float) -> void:
	var key := _stat_key(player_id)
	if key == &"":
		return
	stats.record(key, &"food")
	stats.record(key, &"mass_eaten", mass)
	_note_mass(player_id)


func _on_stat_fruit(player_id: int, _grid_id: int, _kind: HungryContent.Fruit) -> void:
	var key := _stat_key(player_id)
	if key != &"":
		stats.record(key, &"fruit")


func _on_stat_item(player_id: int, _grid_id: int, _item: StringName) -> void:
	var key := _stat_key(player_id)
	if key != &"":
		stats.record(key, &"items")


func _on_stat_piece(eater_id: int, _victim: int, mass: float) -> void:
	var key := _stat_key(eater_id)
	if key == &"":
		return
	stats.record(key, &"pieces_eaten")
	stats.record(key, &"mass_eaten", mass)
	_note_mass(eater_id)


func _on_stat_death(player_id: int, killer_id: int) -> void:
	var victim := _stat_key(player_id)
	if victim != &"":
		stats.record(victim, &"deaths")
	var killer := _stat_key(killer_id)
	if killer != &"" and killer_id != player_id:
		stats.record(killer, &"kills")


func _on_stat_burst(_player_id: int, by_player: int, _pieces: int) -> void:
	var key := _stat_key(by_player)
	if key != &"":
		stats.record(key, &"bursts")


## Starts counting for a session, under the scoped key dot-platform resolved.
##
## Duck-typed like [method _avatar_for]: a LAN server has no platform module,
## and a session without a key is counted under nothing rather than under the
## account id the identity carries — which is the one thing that must never be
## filed. The tracker's reporter would refuse it anyway; not offering it is the
## first line.
func _begin_stats(session: DotClientSession) -> void:
	if stats == null:
		return
	var platform: Object = server.modules.get_module("platform")
	if platform == null or not platform.has_method("player_for"):
		return
	var player: Object = platform.call("player_for", session)
	if player == null or not player.has_method("key"):
		return
	var key := str(player.call("key"))
	if key == "":
		return
	_stat_keys[session.userid] = StringName(key)
	stats.begin(StringName(key), session.display_name)


func _end_stats(session: DotClientSession) -> void:
	if stats == null or not _stat_keys.has(session.userid):
		return
	stats.end(_stat_keys[session.userid])
	_stat_keys.erase(session.userid)


# --- The tick --------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null or world == null:
		return

	_tick += 1
	_drive_bots()
	bridge.server_tick(_tick)

	# [b]After the world's own tick, and this is the ordering that matters.[/b] The hunters
	# read where everybody is and the hazards push pieces out of rocks, and both have to
	# happen on positions the movement has just produced — a list built before the tick is
	# a list of where everybody WAS, which is the one-tick lag this family has now
	# documented three times.
	if hunters != null and hunters.is_enabled():
		hunters.tick(1.0 / float(world.tick_rate))

	if hazards != null:
		hazards.resolve()

	if maps != null:
		maps.advance(1.0 / float(world.tick_rate))


# --- Joining ---------------------------------------------------------------

## A client finished joining.
##
## [b]The event carries `userid`, not `peer_id`.[/b] Looking a session up by a peer id
## that is not in the payload returns null every time, so the handler returns early,
## every time, and nobody is ever added to the world — with no error, because a null
## session is a legitimate thing to find. game-blob's module has the same line and has
## never connected a client, so it has never run.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null or _joined.has(session.userid):
		return

	# The session id, not the peer id: a peer id is reassigned on reconnect and the next
	# player to join would inherit this one's monster.
	var added := bridge.add_player(
		session.peer_id,
		session.userid,
		session.display_name,
		_avatar_for(session)
	)

	if not added.ok:
		log_warn("could not add a player", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true
	_apply_stored_loadout(session.userid)
	_begin_stats(session)

	# Voice and chat learn about them before anything is sent, so a frame or a line that
	# lands in the same flush as the admission has somewhere to go.
	if services != null:
		services.add_peer(session.peer_id)

	if progress != null:
		progress.begin(str(_stat_keys.get(session.userid, "")))

	_welcome(session)


## What somebody is told once they are in: the backlog, and what is already in the arena.
##
## [b]After the admission, never before it.[/b] Nothing may be sent to a peer before it has
## said it can receive — dot-server's signon finishes and *then* the client builds its
## scene, and everything sent in between lands on a node that does not exist and is lost,
## one "Node not found" per call.
func _welcome(session: DotClientSession) -> void:
	if not bridge.peer_is_ready(session.peer_id):
		return

	if services != null:
		# The backlog: what was said before they walked in. dot-chat computes it per peer,
		# because a channel with `backlog = 0` — the proximity one — must not replay a
		# line somebody said quietly in a corner to a stranger who was not there.
		for line in services.chat.backlog_for(session.peer_id):
			bridge.send_chat(session.peer_id, line)

		services.chat.join_notice(session.peer_id, HungryServices.CHANNEL_ALL)

	# The hunters and the hazards already in the arena. A client that joined mid-wave
	# would otherwise be told about a hunter only when it next moved, and would walk
	# through a rock in the meantime — both ends resolve the same list.
	if hunters != null:
		for row in hunters.wire_rows():
			bridge.send_hunter(
				session.peer_id, row[0], row[1], row[2], row[3], row[4]
			)

	if hazards != null:
		for row in hazards.wire_rows():
			bridge.send_hazard(session.peer_id, row[0], row[1], row[2], true)


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	# [b]Off the broadcast set first.[/b] Everything below announces something about this
	# person to everybody ELSE, and their socket has already gone — the "Attempt to call
	# RPC with unknown peer ID" that ends up in the log of every single disconnect, which
	# is where somebody looks when something else is wrong.
	bridge.mark_not_ready(session.peer_id)

	if services != null:
		services.chat.leave_notice(session.peer_id, HungryServices.CHANNEL_ALL)
		services.remove_peer(session.peer_id)

	if maps != null and maps.director != null:
		# The vote forgets them, or a rock-the-vote threshold counts a ballot from
		# somebody who has left — which is how a server ends up unable to change at all.
		maps.director.forget_voter(StringName(str(session.userid)))

	if progress != null:
		progress.end(str(_stat_keys.get(_player_of_session(session), "")))

	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)
	_end_stats(session)


## The world player id a session is in the arena under, or zero.
func _player_of_session(session: DotClientSession) -> int:
	return bridge.player_for_peer(session.peer_id) if bridge != null else 0


# --- Chat, voice and votes -------------------------------------------------

## Somebody said something through dot-server's own chat path.
##
## Taken and cancelled, not watched: this game's rules are [DotChatRouter]'s now, and
## cancelling is what makes there be exactly one path. The line still reaches every player,
## through a router that has already sanitised it, checked the gag and worked out who can
## hear it.
func _on_player_chat(event: DotEvent) -> void:
	event.cancel("routed by the game's chat", _module_name())

	var session := event.get_session()

	if session == null or services == null or services.chat == null:
		return

	# A browser shell's own chat box has no way to name a channel, so the legacy path
	# lands on the room channel — which is the one they would have picked.
	_on_say_requested(
		session.peer_id, HungryServices.CHANNEL_ALL, event.get_string("text")
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said := services.chat.submit(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		# Back to the sender and nowhere else. dot-chat is deliberate that a rate-limited
		# or gagged player must not be able to measure the difference from outside, and a
		# refusal broadcast to the room is exactly that measurement.
		services.chat.notice(peer_id, said.error.message, channel_id)


## A voice frame. Relayed, never inspected — the router stamps the speaker from the
## transport's own sender id, and without that any client can put words in any other
## player's mouth.
func _on_voice_requested(peer_id: int, payload: PackedByteArray) -> void:
	services.voice.relay(peer_id, payload)


func _on_chat_accepted(message: DotChatMessage, _recipients: PackedInt32Array) -> void:
	# Nothing to draw over a head here — a monster is not a nameplate — but the server's
	# own view of who last spoke is what `hungry_status` reports from, and it is taken off
	# the accepted line rather than off the request so a refused one is not counted.
	if message.sender_peer > 0:
		_last_spoke = message.sender_name


## An unclaimed `!command` from chat.
##
## Routed into dot-server's own console with the player's permissions rather than given a
## second command table here: dot-server already decides what a session may run, logs it to
## the audit log and answers it, and a game that reimplemented that would be a game whose
## chat commands were not audited.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer_id)

	if session == null:
		return

	if server.console.find_command(command) == null:
		DotLog.debug(CHANNEL, "an unknown chat command was ignored", {
			"peer": peer_id, "command": command,
		})
		return

	var ctx := session.make_context(
		command,
		args,
		DotCmdContext.Source.CHAT,
		func(line: String) -> void:
			services.chat.notice(peer_id, line, HungryServices.CHANNEL_ALL)
	)

	var line := command

	for arg in args:
		line += " " + arg

	server.console.execute(line, ctx)


## `rtv`, `nominate <id>`, `vote <n>`, `extend` — from this game's own wire.
##
## [b]A token, resolved here rather than an enum on the wire.[/b] What can be voted for is
## a [DotVoteSource]'s business, which is what lets one engine drive dot-server's games and
## dot-map's maps without this file naming either.
func _on_vote_requested(peer_id: int, token: String) -> void:
	if maps == null or maps.director == null:
		return

	var voter := StringName(str(bridge.player_for_peer(peer_id)))
	var parts := token.strip_edges().split(" ", false)

	if parts.is_empty():
		return

	var result: DotResult = null

	match parts[0].to_lower():
		"rtv":
			result = maps.director.rock_the_vote(voter)
		"nominate":
			if parts.size() > 1:
				result = maps.director.nominate(voter, StringName(parts[1]))
		"vote":
			if parts.size() > 1:
				result = maps.director.cast_one(voter, StringName(parts[1]))
		"extend":
			result = maps.director.extend()

	if result != null and not result.ok and services != null:
		services.chat.notice(
			peer_id, result.error.message, HungryServices.CHANNEL_ALL
		)


func _voter_is_admin(voter: StringName) -> bool:
	var player_id := String(voter).to_int()
	var peer_id := bridge.peer_for_player(player_id)
	var session := server.session_of(peer_id) if peer_id > 0 else null
	return session != null and session.is_admin()


func _on_vote_announced(line: String) -> void:
	if services != null and services.chat != null:
		services.chat.announce(line, HungryServices.CHANNEL_ALL)


## The vote picked something. dot-server changes the game; nothing here does.
func _on_change_due(game_id: StringName) -> void:
	if not maps.available(game_id):
		log_warn("the vote picked a mode this head count cannot play", {
			"game": String(game_id)
		})
		return

	server.games.change_game(game_id, "vote")


# --- Hunters, hazards and progress -----------------------------------------

func _on_hunter_changed(hunter_id: int) -> void:
	var state := hunters.state_of(hunter_id)

	if state.is_empty():
		# Gone. Announced as not-alive so a client drops it, rather than simply stopping
		# being mentioned — which would leave it drawn for ever.
		bridge.broadcast_hunter(hunter_id, 0, Vector2.ZERO, 0.0, false)
		return

	bridge.broadcast_hunter(
		hunter_id,
		HungryHunters.index_of(state["kind"]),
		state["at"],
		float(state["radius"]),
		bool(state["alive"])
	)


## A hunter ate somebody's piece. Counted, so the secret achievement can be earned.
func _on_piece_hunted(player_id: int, _mass: float) -> void:
	var key := _stat_key(player_id)

	if key != &"":
		stats.record(key, &"hunted", 1.0)


func _on_hazard_placed(place_id: int, def: DotPropDef, at: Vector2) -> void:
	bridge.broadcast_hazard(place_id, HungryHazards.index_of(def.id), at, true)


func _on_hazard_cleared(place_id: int) -> void:
	bridge.broadcast_hazard(place_id, 0, Vector2.ZERO, false)


## A spike. What "burst" means is the world's; this is where it is asked for.
func _on_hazard_struck(player_id: int, _piece_id: int, effect: StringName) -> void:
	if effect == &"burst":
		world.burst(world.monster_for(player_id), 0)


func _on_earned(player_key: String, id: StringName, title: String, points: int) -> void:
	# The player id the key belongs to, so a client can colour the line. Linear over at
	# most a few dozen players, a few times a session.
	for player_id in _stat_keys.keys():
		if str(_stat_keys[player_id]) != player_key:
			continue

		bridge.broadcast_progress(int(player_id), id, title, points)
		return


# --- The avatar ------------------------------------------------------------


## The avatar dot-platform resolved for this session, if there is a dot-platform.
##
## [b]Duck-typed on purpose.[/b] This game needs dot-user-avatar — the schema is what a
## rider is — but it does not need the whole identity stack, and naming
## [code]DotPlatformModule[/code] here would make a LAN server impossible without
## dot-auth, dot-user and a profile store. A module that answers to `player_for` is
## enough, which is the same contract dot-server uses for its admin sources.
func _avatar_for(session: DotClientSession) -> DotAvatar:
	var platform: Object = server.modules.get_module("platform")

	if platform == null or not platform.has_method("player_for"):
		return null

	var player: Variant = platform.call("player_for", session)

	if player == null or not (player is Object):
		return null

	var avatar: Variant = (player as Object).get("avatar")
	return avatar as DotAvatar if avatar is DotAvatar else null


# --- Bots ------------------------------------------------------------------

## Keeps the bot population at `hungry_bots` and hands each one its command.
func _drive_bots() -> void:
	var wanted := _cv_bots.get_int() if _cv_bots != null else 0

	while _bots.size() < wanted:
		if not _add_bot():
			break

	while _bots.size() > wanted:
		var doomed: int = _bots.keys()[_bots.size() - 1]
		world.remove_player(doomed)
		_bots.erase(doomed)

	for bot_id in _bots.keys():
		var monster := world.monster_for(int(bot_id))

		if monster == null:
			continue

		bridge.note_command(
			int(bot_id), HungryBot.command_for(world, monster, _tick)
		)


func _add_bot() -> bool:
	var bot_id := _next_bot_id
	_next_bot_id += 1

	var index := bot_id - BOT_ID_BASE
	var display_name := "Bot %d" % (index + 1)
	var added := bridge.add_player(0, bot_id, display_name)

	if not added.ok:
		log_warn("could not add a bot", {"error": str(added.error)})
		return false

	# Bots take turns through the traits and the throwables. Not for their sake — they
	# play the same either way — but so that an operator watching a server full of them
	# sees the loadout doing something, and so that the paths a human's choice takes are
	# exercised on a server nobody has joined yet.
	var monster: HungryMonster = added.value
	var loadout := DotLoadout.empty(bridge.loadout_schema.id)
	loadout.set_item(
		HungryContent.SLOT_STARTER,
		HungryContent.ITEM_IDS[index % HungryContent.ITEM_IDS.size()]
	)
	# Only the free ones: a bot is not entitled to anything either, and handing it an
	# unlock nobody has would be a server quietly deciding entitlements do not apply.
	loadout.set_item(
		HungryContent.SLOT_TRAIT,
		HungryContent.TRAIT_IDS[index % 2]
	)

	var legal := DotLoadoutValidator.validate(
		loadout, bridge.loadout_schema, DotLoadoutEntitlements.none()
	)

	if legal.ok:
		monster.wear_loadout(loadout)
	else:
		log_warn("a bot loadout was not legal", {"error": str(legal.error)})

	_bots[bot_id] = display_name
	return true


func bot_count() -> int:
	return _bots.size()


## Pushes the cosmetics manifest URL onto the bridge, so joining clients are told it.
##
## Clients already connected are not re-told: the hello is sent once, on admission, and a
## cosmetic that arrives mid-session is a nicety rather than a requirement. An operator
## setting this on a running server means it from the next join.
func _sync_pack() -> void:
	if bridge != null and _cv_pack != null:
		bridge.avatar_pack_url = _cv_pack.get_string()


# --- Games -----------------------------------------------------------------

## The three modes, so `changegame` and a vote have something to change to.
##
## Both ship inside the build, so [member DotGameDescriptor.manifest_url] is empty and no
## client has to download anything to follow a change. A game whose content lives on a CDN
## sets that instead, and dot-server's sync step then does the waiting.
static func game_descriptors() -> Array[DotGameDescriptor]:
	var out: Array[DotGameDescriptor] = []

	for row in [
		[GAME_CLASSIC, "Hungario: Classic", "res://game/modes/classic.tscn"],
		[GAME_FRENZY, "Hungario: Frenzy", "res://game/modes/frenzy.tscn"],
		[GAME_GAUNTLET, "Hungario: Gauntlet", "res://game/modes/gauntlet.tscn"],
	]:
		var descriptor := DotGameDescriptor.new()
		descriptor.game_id = String(row[0])
		descriptor.display_name = String(row[1])
		descriptor.scene = String(row[2])
		# Deliberately empty. [DotClientLink] refuses an absolute scene path that is not
		# already inside dot-cloud's mount prefix, because a server that could name one
		# could ask every client to load any scene in their build — and this game ships
		# inside the build rather than as downloadable content, so there is no mount for
		# it to be inside. The client owns its own scene ([HungryClient]) and the signon
		# takes the no-scene path, which is the shape every game shipped with its server
		# has. A game delivered through dot-cloud sets a *relative* path here instead.
		descriptor.client_scene = ""
		descriptor.min_players = 0
		out.append(descriptor)

	return out


## Registers both modes, unless the host already did.
##
## A host that wants one of these to be [member DotGameManager.initial_game] has to add
## them [i]before[/i] the server boots, because the initial game is loaded during the
## game manager's setup and this module cannot load until there is a world to bind to.
## [method game_descriptors] is the same list for that case, which is why the registration
## here is idempotent rather than an error.
func _register_games() -> void:
	if server.games == null:
		return

	for descriptor in game_descriptors():
		if server.games.find_game(descriptor.game_id) != null:
			continue

		var added := server.games.add_game(descriptor)

		if not added.ok:
			log_warn("could not register a game", {
				"game": descriptor.game_id, "error": str(added.error)
			})


# --- Console ---------------------------------------------------------------

func _register_console() -> void:
	add_command(
		"hungry_status", _cmd_status, "Show the world", DotAdminFlags.GENERIC
	)
	add_command("hungry_top", _cmd_top, "Show the leaderboard", "")
	add_command(
		"hungry_loadouts", _cmd_loadouts, "Show what players brought in",
		DotAdminFlags.GENERIC
	)
	add_command("hungry_net", _cmd_net, "Show the netcode", DotAdminFlags.GENERIC)
	add_command(
		"hungry_restart", _cmd_restart, "Restart the round", DotAdminFlags.CHANGEMAP
	)
	add_command(
		"hungry_give",
		_cmd_give,
		"hungry_give <player> <pepper|frost|lure> — hand somebody a throwable",
		DotAdminFlags.CHEATS
	)
	add_command(
		"hungry_burst",
		_cmd_burst,
		"hungry_burst <player> — blow somebody apart",
		DotAdminFlags.CHEATS
	)

	add_command(
		"hungry_services", _cmd_services,
		"Show chat, voice and moderation", DotAdminFlags.GENERIC
	)
	add_command(
		"hungry_hunters", _cmd_hunters,
		"hungry_hunters [on|off|clear] — the NPC monsters", DotAdminFlags.GENERIC
	)
	add_command(
		"hungry_hazards", _cmd_hazards,
		"hungry_hazards [scatter <n>|clear] — rocks, spikes and lures",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"hungry_boards", _cmd_boards,
		"hungry_boards [board] — the persistent leaderboards", ""
	)
	add_command(
		"hungry_vote", _cmd_vote,
		"hungry_vote [open|status|next] — what plays next", DotAdminFlags.CHANGEMAP
	)
	# MUTE rather than BAN: quieting somebody and removing them are different powers, and
	# dot-server's own flags are what distinguish them.
	add_command(
		"hungry_gag", _cmd_gag,
		"hungry_gag <who> <seconds> [reason]", DotAdminFlags.MUTE
	)
	add_command(
		"hungry_mute", _cmd_mute,
		"hungry_mute <who> <seconds> [reason]", DotAdminFlags.MUTE
	)

	_cv_bots = add_cvar("hungry_bots", "0", "Bots to keep in the world")

	# [b]Hunters are off by default, and that is an operator's decision rather than an
	# addon's.[/b] A mode about eating food and a mode about being hunted are different
	# games, and turning one into the other silently because an addon was installed is
	# exactly what a cvar exists to prevent.
	_cv_hunters = add_cvar("hungry_hunters_on", "0", "Release NPC hunters into the arena")
	_cv_hunters.changed.connect(func(_old: String, value: String) -> void:
		if hunters != null:
			hunters.set_enabled(value != "0")
	)

	_cv_hazards = add_cvar(
		"hungry_hazards_count", "0", "Rocks scattered into the arena at load"
	)

	# Where this server's rider cosmetics live. Empty means "whatever the client shipped
	# with", which is every deployment that has not published a pack — and a client with
	# no dot-cloud installed ignores it either way.
	_cv_pack = add_cvar(
		"hungry_avatar_pack", "", "Manifest URL for this server's rider content"
	)
	_cv_pack.changed.connect(func(_old: String, _new: String) -> void: _sync_pack())
	_sync_pack()

	# A path, not the token. See [method _build_reporting].
	_cv_auth_config = add_cvar(
		"hungry_backbone_config",
		"user://cfg/auth.json",
		"Config file holding this server's site integration token"
	)


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(world.describe_lines())
	ctx.reply_lines(bridge.describe_lines())

	if _last_spoke != "":
		ctx.reply("last spoke   %s" % _last_spoke)

	if hunters != null:
		ctx.reply_lines(hunters.describe_lines())

	if hazards != null:
		ctx.reply_lines(hazards.describe_lines())

	if maps != null:
		ctx.reply_lines(maps.describe_lines())


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())

	if combat != null:
		ctx.reply_lines(combat.describe_lines())


func _cmd_hunters(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			hunters.set_enabled(true)
			ctx.reply("Hunters are on.")
		"off":
			hunters.set_enabled(false)
			ctx.reply("Hunters are off, and the arena is cleared of them.")
		"clear":
			var gone := hunters.spawner.clear_all()
			ctx.reply("Cleared %d." % gone)
		_:
			ctx.reply_lines(hunters.describe_lines())


func _cmd_hazards(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"scatter":
			var count := maxi(1, ctx.arg_int(1, 8))
			# Seeded from the world rather than from a clock, so `hungry_hazards scatter`
			# twice on one world lays out the same arena twice. A server an operator can
			# reproduce is worth more than one that surprises them.
			var made := hazards.scatter(&"rock", count, world.field.seed_value())
			ctx.reply("Scattered %d rocks." % made)
		"clear":
			ctx.reply("Cleared %d." % hazards.clear_all())
		_:
			ctx.reply_lines(hazards.describe_lines())


func _cmd_boards(ctx: DotCmdContext) -> void:
	var board_id := StringName(ctx.arg(0, "top_mass"))
	var rows := progress.page(board_id, 10)

	if rows.is_empty():
		ctx.reply("Nothing on '%s' yet." % String(board_id))
		return

	var rank := 1

	for row in rows:
		var entry: DotLeaderboardEntry = row
		ctx.reply("%2d. %-24s %s" % [rank, entry.player_name, entry.value])
		rank += 1


func _cmd_vote(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"open":
			var opened := maps.director.open_vote()
			ctx.reply_error(opened) if not opened.ok else ctx.reply("Vote opened.")
		"next":
			ctx.reply("Next in rotation: %s" % String(maps.next_in_rotation()))
		_:
			ctx.reply_lines(maps.describe_lines())


func _cmd_gag(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.GAG, "gagged")


func _cmd_mute(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.VOICE_MUTE, "muted")


## The shared half of gag and mute.
##
## One function because the only difference is a kind: dot-moderation already models both
## as one record with an expiry, a scope and a revocation, and writing them separately
## would be two chances to forget the duration parsing or the immunity.
func _punish(ctx: DotCmdContext, kind: DotPunishment.Kind, verb: String) -> void:
	if ctx.args.size() < 2:
		ctx.reply("Usage: %s <who> <seconds, 0 for permanent> [reason]" % ctx.command)
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	if targets.size() > 1:
		# Refused rather than applied to all of them: `@me` and a name prefix both match
		# more than one person, and a mute applied to four people by accident is a thing
		# an operator finds out about from the four people.
		ctx.reply("'%s' matches %d people. Be more specific." % [
			ctx.args[0], targets.size()
		])
		return

	var session := targets[0]
	var seconds := maxi(0, ctx.arg_int(1))
	var reason := ctx.rest(2) if ctx.args.size() > 2 else "No reason given."

	var issued: DotResult = await services.moderation.issue(
		kind,
		DotPunishmentSubject.for_uid(session.uid()),
		reason,
		ctx.caller_label(),
		seconds,
		ctx.immunity
	)

	if not issued.ok:
		ctx.reply("Refused: %s" % issued.error.message)
		return

	ctx.reply("%s %s: %s" % [
		session.display_name, verb, DotPunishment.format_duration(seconds)
	])

	# Told to the person it happened to, on the channel they are reading. A mute nobody is
	# told about is a microphone that has stopped working, which is what they report.
	services.chat.notice(
		session.peer_id,
		(issued.value as DotPunishment).player_message(),
		HungryServices.CHANNEL_ALL
	)


func _cmd_top(ctx: DotCmdContext) -> void:
	var rank := 1

	for monster in world.leaderboard(10):
		ctx.reply("%2d. %-18s %8.0f  %d pieces" % [
			rank, monster.display_name, monster.mass(), monster.piece_count()
		])
		rank += 1


func _cmd_loadouts(ctx: DotCmdContext) -> void:
	for monster in world.leaderboard(20):
		ctx.reply("%-18s %-8s %-8s" % [
			monster.display_name.substr(0, 18),
			String(monster.trait_id),
			String(monster.starter_item()),
		])

	ctx.reply_lines(loadouts.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	ctx.reply_lines(net.describe_lines())
	ctx.reply("link     %s" % str(bridge.link.describe()))


func _cmd_restart(ctx: DotCmdContext) -> void:
	world.start(_tick)
	ctx.reply("Round restarted.")


func _cmd_give(ctx: DotCmdContext) -> void:
	if ctx.args.size() < 2:
		ctx.reply("hungry_give <player> <pepper|frost|lure>")
		return

	var item := StringName(ctx.args[1])

	if world.items.find(item) == null:
		ctx.reply("There is no item called '%s'." % ctx.args[1])
		return

	var monster := _target(ctx, ctx.args[0])

	if monster == null:
		return

	if not monster.take_item(item):
		ctx.reply("%s is already carrying the maximum." % monster.display_name)
		return

	bridge.send_carry(monster.id)
	ctx.reply("Gave %s a %s." % [monster.display_name, ctx.args[1]])


func _cmd_burst(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		ctx.reply("hungry_burst <player>")
		return

	var monster := _target(ctx, ctx.args[0])

	if monster == null:
		return

	var made := world.burst(monster, 0)
	ctx.reply("Burst %s into %d more pieces." % [monster.display_name, made])


## Resolves a console argument to a monster: a session, or a bot by name.
##
## Sessions go through [method DotServer.resolve_target] so that the usual `#userid`,
## partial-name and `@all` forms work; bots have no session, so they are matched by name
## afterwards rather than being invisible to every command.
func _target(ctx: DotCmdContext, needle: String) -> HungryMonster:
	var sessions := server.find_sessions(needle)

	if sessions.size() == 1:
		var monster := world.monster_for(sessions[0].userid)

		if monster != null:
			return monster

	var lowered := needle.to_lower()

	for bot_id in _bots.keys():
		if String(_bots[bot_id]).to_lower().contains(lowered):
			return world.monster_for(int(bot_id))

	ctx.reply(
		"No player matched '%s'." % needle if sessions.size() != 1
		else "That player is not in the world."
	)
	return null


func describe() -> Dictionary:
	var out := super.describe()
	out["players"] = _joined.size()
	out["bots"] = _bots.size()
	out["tick"] = _tick
	out["world"] = String(world.preset.id) if world != null else "<none>"
	out["loadouts"] = loadouts.describe() if loadouts != null else {}
	return out
