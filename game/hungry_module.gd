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

## The two modes this server can switch between.
const GAME_CLASSIC := "hungry_classic"
const GAME_FRENZY := "hungry_frenzy"

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

## Reports this server to its site listing, when an operator has configured one.
##
## Null on a server with no integration token, which is every LAN game and every test.
var backbone: DotBackboneClient = null

## userid -> true, for the humans this module put in the world.
var _joined: Dictionary = {}

## player id -> display name, for the bots.
var _bots: Dictionary = {}

var _next_bot_id: int = BOT_ID_BASE
var _tick: int = 0

var _cv_bots: DotConVar = null
var _cv_pack: DotConVar = null
var _cv_auth_config: DotConVar = null


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

	_register_games()
	_register_console()

	_build_reporting()

	if Engine.physics_ticks_per_second != world.tick_rate:
		# Not corrected here: `sv_tickrate` is the operator's and this module is a guest
		# in their server. Loud, because the symptom otherwise is a game that runs at the
		# wrong speed with nothing in the log about it.
		log_warn("sv_tickrate does not match the world's tick rate", {
			"engine": Engine.physics_ticks_per_second,
			"world": world.tick_rate,
		})

	world.start(0)

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


# --- The tick --------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null or world == null:
		return

	_tick += 1
	_drive_bots()
	bridge.server_tick(_tick)


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


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)


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

## The two modes, so `changegame` and a vote have something to change to.
##
## Both ship inside the build, so [member DotGameDescriptor.manifest_url] is empty and no
## client has to download anything to follow a change. A game whose content lives on a CDN
## sets that instead, and dot-server's sync step then does the waiting.
static func game_descriptors() -> Array[DotGameDescriptor]:
	var out: Array[DotGameDescriptor] = []

	for row in [
		[GAME_CLASSIC, "Hungry: Classic", "res://game/modes/classic.tscn"],
		[GAME_FRENZY, "Hungry: Frenzy", "res://game/modes/frenzy.tscn"],
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

	_cv_bots = add_cvar("hungry_bots", "0", "Bots to keep in the world")

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
