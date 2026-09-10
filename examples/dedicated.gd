extends Node

## A real [DotServer] with the game loaded into it, listening for browser clients.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn            # self-test
## godot --headless --path . res://examples/dedicated.tscn -- --serve # run one
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The WebSocket listener is the point.[/b] A browser has no UDP and Godot's web
## template does not ship `ENetMultiplayerPeer` at all, so a server that expects browser
## clients listens on WebSocket — and then, today, [i]all[/i] of its clients do.
## [member DotTransportAuto.require_web_clients] defaults to true for exactly this reason,
## and this is the deployment shape it describes.
##
## It does not connect a client: [code]examples/sandbox.tscn[/code] does that, over a real
## socket, and repeating it here would test dot-server rather than this game.

const PORT := 27081
const SERVER_DIR := "user://hungry_dedicated"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server: DotServer = null


func _ready() -> void:
	# Quiet by default so the checks are readable; `-- --verbose` when one of them
	# fails and the reason is in a log line rather than in the assertion.
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	var serving := "--serve" in OS.get_cmdline_user_args()

	print("game-hungario dedicated server")
	print("")

	if not serving:
		DotPaths.remove_tree(SERVER_DIR)

	var built := await _build(serving)

	if serving:
		if built:
			print("")
			print("listening on ws://0.0.0.0:%d — ctrl-c to stop" % PORT)
			for line in _server.status_lines():
				print("  %s" % line)
		return

	if built:
		_test_world()
		_test_module()
		_test_commands()
		await _test_bots()
		# Awaited, because it now suspends: it lowers the bot population and waits for the
		# module to notice. A suspending section called without `await` runs as far as its
		# first suspension and everything after it — including its own `_done()` — is
		# silently dropped, which is what the completion count at the end exists to catch
		# and did.
		await _test_loadouts()
		_test_reporting()
		await _test_stats()
		_test_netcode()
		_test_services()
		await _test_moderation()
		_test_combat()
		_test_hunters()
		_test_hazards()
		await _test_progress()
		_test_vote()
		await _test_game_change()
		_test_transport()
		_test_unload()

	_teardown()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section aborts that
## function and nothing says so: the checks that already ran still print ok, the ones
## after it never happen, and the total at the bottom cannot reveal a check that never
## ran. dot-net's demo carries the same pair, reached from the other direction — there it
## was a suspending section called without `await`.
var _entered := 0
var _completed := 0


## Opens a section. Pair with [method _done] on every path out of it.
func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


## Waits for a condition, or gives up. Returns whether it happened.
##
## A deadline rather than a fixed number of frames. The module fills its bot population
## and ticks the world from `_physics_process`, so how many frames that takes depends on
## what else the machine is doing — and a check written as "twenty frames is surely
## enough" is a check that passes on an idle box and fails on a busy one, which is the
## worst kind because it looks like a real regression.
func _until(condition: Callable, seconds: float = 8.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return false


func _module() -> HungryModule:
	return _server.modules.get_module("hungry") as HungryModule


func _world() -> HungryWorld:
	return DotRegistry.get_node_service(HungryWorld.SERVICE) as HungryWorld


# --- Boot ------------------------------------------------------------------

func _build(serving: bool) -> bool:
	print("booting")

	var config := DotServerConfig.new()
	config.hostname = "hungry dedicated"
	config.port = PORT
	config.bind_address = "127.0.0.1" if not serving else "0.0.0.0"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	# The addon ships a default `server.cfg` that the search path would find, which is
	# correct layering and would make this test assert against whatever that file says.
	config.startup_config = ""
	config.autoexec_config = ""

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	# Both modes are registered before the first one is loaded, because
	# [DotGameManager.change_game] can only change to a game it already knows about and
	# the module cannot load until there is a world for it to bind to.
	for descriptor in HungryModule.game_descriptors():
		_server.games.add_game(descriptor)

	var loaded: DotResult = await _server.games.change_game(
		HungryModule.GAME_CLASSIC, "boot"
	)

	if not _check(loaded.ok, "the classic mode loads", str(loaded.error)):
		return false

	var module := _server.modules.load_module("res://game/hungry_module.gd")
	return _check(module.ok, "and the module loads into it", str(module.error))


func _teardown() -> void:
	if _server == null or not is_instance_valid(_server):
		return

	_server.shutdown("test over")
	remove_child(_server)

	# Freed rather than queued. A queue_free on the last line before `quit()` is a free
	# that never happens: the deferred call is dropped with the tree, and every node under
	# it — the module, its netcode manager, the loadout manager, the game scene — is
	# reported as leaked at exit. Which is true, and says nothing about a cycle.
	_server.free()


# --- The world -------------------------------------------------------------

func _test_world() -> void:
	_section("the world")

	var world := _world()

	_check(world != null, "the mode scene registered one")

	if world == null:
		_done()
		return

	_check(world.is_authority, "and it is the authority")
	_check(
		world.field.food_count() > 0,
		"with food in it (%d)" % world.field.food_count()
	)
	_check(
		String(world.preset.id) == "classic",
		"under the classic preset (%s)" % world.preset.id
	)
	_done()


func _test_module() -> void:
	_section("the module")

	_check(_server.modules.has_module("hungry"), "is listed among the server's modules")

	var module := _module()
	_check(module != null and module.world == _world(), "and holds the world")

	for command in [
		"hungry_status", "hungry_top", "hungry_net", "hungry_restart",
		"hungry_give", "hungry_burst", "hungry_loadouts",
	]:
		_check(
			_server.console.find_command(command) != null, "registered %s" % command
		)

	for cvar in ["hungry_bots", "hungry_avatar_pack"]:
		_check(_server.console.find_cvar(cvar) != null, "and its %s cvar" % cvar)

	# The cosmetics manifest is a cvar rather than a constant because a community server
	# may ship its own parts, and it reaches joining clients through the hello — a client
	# that had to be told out of band is a client that will not be.
	_check(
		module.bridge.avatar_pack_url == "",
		"with no rider content configured by default"
	)
	_check(
		_server.console.execute(
			"hungry_avatar_pack https://cdn.example/hungry/manifest.json"
		).ok,
		"setting one is accepted"
	)
	_check(
		module.bridge.avatar_pack_url == "https://cdn.example/hungry/manifest.json",
		"and reaches the bridge, which is what tells a client (%s)"
			% module.bridge.avatar_pack_url
	)
	_server.console.execute("hungry_avatar_pack \"\"")

	for game_id in [HungryModule.GAME_CLASSIC, HungryModule.GAME_FRENZY]:
		_check(
			_server.games.find_game(game_id) != null,
			"and the %s descriptor is registered" % game_id
		)
	_done()


func _test_commands() -> void:
	_section("its commands")

	for command in [
		"hungry_status", "hungry_top", "hungry_net", "hungry_restart",
		"hungry_loadouts",
	]:
		_check(_server.console.execute(command).ok, "%s runs" % command)

	# The cheat commands are gated by a permission rather than by a flag on the handler,
	# and a console context is trusted — so what is checked here is that they run, and
	# that their argument handling refuses rather than crashes.
	_check(
		_server.console.execute("hungry_give nobody pepper").ok,
		"hungry_give runs and reports a missing target"
	)
	_check(
		_server.console.execute("hungry_give").ok,
		"and with no arguments prints its usage"
	)
	_check(
		_server.console.execute("hungry_burst nobody").ok,
		"hungry_burst runs and reports a missing target"
	)


	_done()


# --- Statistics --------------------------------------------------------------

## What the module counts, and who it counts it for.
##
## The wiring is the part worth testing rather than dot-stats itself, which has
## its own suite: that the world's signals reach a tracker, that a player is
## keyed by their SCOPED id, and — the one that matters — that an account id can
## never be what a stat is filed under. This server has no dot-platform module,
## so nothing here has a scoped key and nothing is counted, which is exactly the
## case a LAN server is in and the one a wiring bug would hide behind.
func _test_stats() -> void:
	_section("statistics")

	var module := _module()

	_check(module.stats != null, "the module built a tracker")

	if module.stats == null:
		_done()
		return

	var schema := module.stats.schema

	_check(schema != null and schema.validate().ok, "its schema validates")
	_check(
		schema.find(&"top_mass") != null
			and schema.find(&"top_mass").kind == DotStatsDef.Kind.BEST,
		"a biggest-ever is a BEST, so shrinking does not lose the record"
	)
	_check(
		schema.find(&"mass_eaten") != null
			and schema.find(&"mass_eaten").kind == DotStatsDef.Kind.COUNTER,
		"and mass eaten is a counter"
	)
	_check(
		schema.published().size() == schema.size(),
		"every stat is published; this game counts nothing privately"
	)

	# No integration token in a test, so nothing reports — and the tracker still
	# counts, because the session figures are the game's own.
	_check(
		not module.stats.report_to_backbone,
		"reporting is off without a backbone to report through"
	)

	# The bots from the previous section are eating right now. None of them has a
	# scoped key, so none of them is counted: a bot is not a player, and a stat
	# filed for one would be filed under nothing.
	_check(
		module.stats.players().is_empty(),
		"bots are counted for nobody (%d)" % module.stats.players().size()
	)

	# The wiring, driven directly. A world signal has to reach the tracker for a
	# player it knows, and the merge has to be the stat's own.
	# Ids well past any real player, and POSITIVE: the same signals drive
	# replication, and dot-net's varint writer refuses a negative id outright.
	const ME := 900001
	const THEM := 900002

	var key := &"AAAAAAAAAAAAAAAAAAAAAA"
	module.stats.begin(key, "Test")
	module._stat_keys[ME] = key

	module.world.food_eaten.emit(ME, 0, 4.0)
	module.world.food_eaten.emit(ME, 1, 6.0)
	module.world.piece_eaten.emit(ME, THEM, 10.0)
	module.world.player_died.emit(THEM, ME)
	module.world.monster_burst.emit(THEM, ME, 3)

	var values := module.stats.session_values(key)

	_check(values.get_value(&"food") == 2.0, "eating food counts it")
	_check(
		values.get_value(&"mass_eaten") == 20.0,
		"and its mass adds across food and pieces (%.1f)" % values.get_value(&"mass_eaten")
	)
	_check(values.get_value(&"pieces_eaten") == 1.0, "eating a piece counts it")
	_check(values.get_value(&"kills") == 1.0, "a kill is credited to the killer")
	_check(values.get_value(&"bursts") == 1.0, "and a burst to whoever caused it")

	# A player who kills themselves is not credited with a kill.
	module.world.player_died.emit(ME, ME)
	_check(
		values.get_value(&"kills") == 1.0 and values.get_value(&"deaths") == 1.0,
		"but a self-kill is only a death"
	)

	# THE check. `_begin_stats` asks dot-platform for a SCOPED key and files
	# nothing without one; the account id the identity carries must never be what
	# a figure is filed under, and the reporter refuses one as a second line.
	_check(
		not DotStatsReporter.is_player_id("backbone:clx8f2k0000"),
		"an account id is refused as a player key"
	)
	_check(
		DotStatsReporter.is_player_id(String(key)),
		"and a scoped key is not"
	)

	module.stats.end(key)
	module._stat_keys.erase(ME)

	_check(
		not module.stats.has_player(key),
		"a player who leaves is forgotten"
	)

	_done()


# --- Bots ------------------------------------------------------------------

func _test_bots() -> void:
	_section("bots")

	var module := _module()
	var world := _world()

	_check(module.bot_count() == 0, "there are none to start with")

	var set_result := _server.console.execute("hungry_bots 4")
	_check(set_result.ok, "hungry_bots 4 is accepted")

	# The module fills the population from `_physics_process`, so this needs real frames.
	var filled := await _until(func() -> bool: return module.bot_count() == 4)

	_check(filled, "four appear (%d)" % module.bot_count())
	_check(
		world.monsters().size() >= 4,
		"and they are in the world (%d)" % world.monsters().size()
	)

	var alive := 0

	for monster in world.monsters():
		if monster.alive:
			alive += 1

	_check(alive == 4, "and alive (%d)" % alive)

	# A bot with no peer must not be registered as one. A peer id of zero is the broadcast
	# address, so a bot registered as a peer would make the server build a snapshot
	# against the bot's interest rectangle and send it to every real client.
	_check(
		not module.bridge.net.peers().has(0),
		"and none of them is registered as a peer"
	)

	var before := 0.0

	for monster in world.monsters():
		before = maxf(before, monster.mass())

	var grown := await _until(func() -> bool:
		for monster in world.monsters():
			if monster.mass() > before:
				return true

		return false
	, 12.0)

	_check(grown, "they play the game and grow")

	# Lowered at the end of the loadout section instead, so that section runs with several
	# bots in the world and can see that they do not all bring the same thing.
	_check(module.bot_count() == 4, "and the population holds (%d)" % module.bot_count())


## What players may bring in, and who decides.
##
## The store is memory-backed, which is the right default for a dedicated server: a
## loadout that outlives a session is a profile, and a profile is dot-user's. What is
## being checked here is the trust boundary rather than the storage — that a server with
## nothing wired grants nothing, and that the schema's own defaults are still takeable,
## because a schema whose defaults are not legal is a player who cannot spawn.
	_done()
func _test_loadouts() -> void:
	_section("loadouts")

	var module := _module()

	_check(module.loadouts != null, "the module runs a loadout manager")

	if module.loadouts == null:
		_done()
		return

	_check(
		module.loadouts.schema != null and module.loadouts.schema.validate().ok,
		"with a legal schema"
	)
	_check(
		DotRegistry.get_service(DotLoadoutManager.SERVICE) == module.loadouts,
		"registered where a loadout screen would look for it"
	)

	# Nothing, and deliberately. A server that granted everything by default would work
	# perfectly in every test, ship, and quietly be a game where every unlock is free —
	# and nobody reports that as a bug.
	var owned := module.loadouts.entitlements_for(HungryContent.loadout_key(1))
	_check(owned.count() == 0, "and grants nothing until something says otherwise")

	var default_loadout := module.loadouts.schema.default_loadout()
	_check(
		DotLoadoutValidator.validate(default_loadout, module.loadouts.schema, owned).ok,
		"while its own default is still takeable"
	)

	# The bots are in the world with a loadout, which is the only reason `hungry_loadouts`
	# has anything to print.
	var with_traits := 0

	for monster in _world().monsters():
		if monster.trait_id != &"":
			with_traits += 1

	_check(
		with_traits == _world().monsters().size(),
		"and everybody in the world has a trait (%d of %d)"
			% [with_traits, _world().monsters().size()]
	)

	# The bots take turns through the traits and the throwables, so that a server nobody
	# has joined still exercises the paths a human's choice takes — and so an operator
	# watching one can see the loadout doing something.
	var traits := {}
	var starters := {}

	for monster in _world().monsters():
		traits[monster.trait_id] = true
		starters[monster.starter_item()] = true

	_check(
		traits.size() > 1 or _world().monsters().size() < 2,
		"the bots do not all bring the same one (%d traits)" % traits.size()
	)
	_check(
		not traits.has(HungryContent.TRAIT_GREEDY),
		"and none of them takes the trait nobody has unlocked"
	)
	_check(
		starters.size() > 1 or _world().monsters().size() < 2,
		"nor the same throwable (%d)" % starters.size()
	)

	_check(
		_server.console.execute("hungry_bots 1").ok, "the population can be lowered"
	)

	var lowered := await _until(func() -> bool: return _module().bot_count() == 1)
	_check(lowered, "and it is (%d)" % _module().bot_count())
	_done()


## What this server tells its site listing.
##
## [b]Nothing is sent from here and nothing can be.[/b] Reporting needs an integration
## token, the token comes from a config file that does not exist in a test, and there is
## no backbone in this repository to send to — so what is checked is the shape of the
## report and the fact that an unconfigured server stays silent. The transport is
## dot-auth's and is covered there; the numbers are this game's and are covered here.
func _test_reporting() -> void:
	_section("what the listing is told")

	var module := _module()

	_check(
		module.backbone == null,
		"a server with no integration token is not listed"
	)
	_check(
		_server.console.find_cvar("hungry_backbone_config") != null,
		"and the token comes from a config file, never a cvar"
	)

	var report := module.stats_report()

	_check(bool(report.get("online", false)), "the report says the server is up")
	_check(
		int(report.get("maxUsers", 0)) > 0,
		"with a slot count (%d)" % int(report.get("maxUsers", 0))
	)

	# dot-server's own report says bots: 0 unconditionally, because dot-server has no bots
	# and no way to know a game has any. A listing that shows eight players on a server
	# holding one human is a listing that stops being trusted.
	_check(
		int(report.get("bots", -1)) == module.bot_count(),
		"and the bots this game actually has (%d)" % int(report.get("bots", -1))
	)
	_check(
		int(report.get("curUsers", -1)) == 0,
		"counted apart from the humans (%d)" % int(report.get("curUsers", -1))
	)

	# The mode rather than the content id: `hungry_frenzy` means something to somebody
	# reading a server browser.
	_check(
		String(report.get("map", "")) == String(_world().preset.id),
		"and the mode as the map (%s)" % str(report.get("map", ""))
	)

	_check(module.roster_report().is_empty(), "the roster is empty with nobody on")

	_done()


func _test_netcode() -> void:
	_section("the netcode")

	var module := _module()

	_check(module.net != null and module.net.is_running(), "a manager is running")
	_check(module.net.is_server, "as the server")
	_check(module.bridge != null, "with a bridge")

	# The RPC node has to sit where a client's will look for it. Godot addresses an RPC by
	# the receiver's path relative to its MultiplayerAPI root, so the name and the parent
	# are the routing.
	var link := _server.get_node_or_null(NodePath(String(HungryNetLink.NODE_NAME)))
	_check(link != null, "and its link is a child of the server node")
	_check(
		link is HungryNetLink,
		"named %s, which is what a client's link is named" % HungryNetLink.NODE_NAME
	)

	_check(
		module.net.interest is HungryInterest,
		"and this game's interest rule is in place"
	)
	_check(
		module.net.messages.count() >= 2,
		"and both message types are registered (%d)" % module.net.messages.count()
	)


# --- Changing the game -----------------------------------------------------
	_done()

func _test_game_change() -> void:
	_section("changing the game")

	var before := _world()
	var changed: DotResult = await _server.games.change_game(
		HungryModule.GAME_FRENZY, "test"
	)

	_check(changed.ok, "the server changes to frenzy", str(changed.error))

	await _until(func() -> bool: return _world() != before)

	var after := _world()

	_check(after != null and after != before, "a new world is registered")
	_check(
		after != null and String(after.preset.id) == "frenzy",
		"under the frenzy preset"
	)
	_check(
		_module().world == after,
		"and the module rebound onto it"
	)
	_check(
		_module().bridge.world == after,
		"and so did the bridge"
	)

	# The manager survives on purpose: rebuilding it would reset the message ids, the peer
	# records and the clock, which is a disconnect for everybody — precisely what changing
	# the map is supposed to avoid.
	_check(
		_module().net != null and _module().net.is_running(),
		"and the netcode manager survived the change"
	)

	await _until(func() -> bool:
		return after != null and after.field.food_count() > 0
	)

	_check(
		after != null and after.field.food_count() > 0,
		"the new world has its own field (%d)"
			% (after.field.food_count() if after != null else 0)
	)


# --- The browser -----------------------------------------------------------

## A browser client needs a WebSocket listener, and dot-core has to be able to make one on
## this build.
##
## Checked through [DotTransportWebSocket] rather than by booting a second server: what
## can go wrong is that the engine build has no WebSocket peer, and that is a property of
## the binary rather than of the configuration.
	_done()
## Chat, voice and the join between them.
func _test_services() -> void:
	_section("chat and voice")

	var module := _module()
	var services := module.services

	_check(services != null, "the services are up")
	_check(
		services.chat != null and services.chat.channel_ids().size() == 4,
		"with four chat channels (%d)"
			% (services.chat.channel_ids().size() if services.chat != null else -1)
	)
	_check(
		services.chat.channel(HungryServices.CHANNEL_NEAR).scope
			== DotChatChannel.Scope.RADIUS,
		"one of which is a radius, because an arena is bigger than a screen"
	)

	# [b]THE join.[/b] dot-chat consults a `dot_mute_source` and dot-moderation publishes
	# one, and neither imports the other — so the only thing that makes a gag work is that
	# something is registered under that name.
	_check(
		DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"a mute source is registered, which is the only thing that makes a gag work"
	)
	_check(
		DotRegistry.has(DotModerationManager.BAN_SERVICE),
		"and a ban source, which dot-server's admission check consults"
	)

	# [b]Proximity voice, which is where this game and the lobby part company.[/b] Hearing
	# somebody creeping up on you is information in an arena and noise in a room.
	_check(
		services.voice != null
			and services.voice.default_channel == DotVoiceRouter.Channel.PROXIMITY,
		"voice is proximity here rather than the whole server"
	)
	_check(
		services.voice.config.format_fingerprint()
			== HungryServices.voice_config().format_fingerprint(),
		"and its format is the one a client builds from the same file"
	)

	# dot-server's own chat is cancelled rather than run beside the router.
	var legacy := _server.events.fire("player_chat", {
		"userid": 1, "name": "Nobody", "text": "hello", "team_only": false,
	})
	_check(
		legacy.cancelled,
		"dot-server's own chat broadcast is cancelled, so there is exactly one path"
	)
	_done()


## A gag, written and read back.
func _test_moderation() -> void:
	_section("moderation")

	var services := _module().services
	var subject := DotPunishmentSubject.for_uid("uid-hungry-test")

	var gagged: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "console", 60
	)
	_check(gagged.ok, "a gag is issued and stored", str(gagged.error))

	# [b]Round-tripped through the store, because the two ends of a serialisation are
	# exactly as capable of never meeting as the two ends of a wire.[/b] dot-moderation
	# shipped a voice mute that loaded back as a WARN, which enforces nothing — and the
	# one thing the addon exists for is a punishment surviving a reconnect.
	var reloaded := DotModerationManager.new()
	reloaded.store = DotPunishmentStoreFile.new(services.punishments_path)
	reloaded.register_mute_source = false
	reloaded.register_ban_source = false
	add_child(reloaded)
	reloaded.load_all()

	var found := reloaded.active_of_kind(subject, DotPunishment.Kind.GAG)
	_check(
		found != null and found.kind == DotPunishment.Kind.GAG,
		"and comes back off disk as a GAG rather than as a WARN"
	)

	var muted: DotResult = await services.moderation.issue(
		DotPunishment.Kind.VOICE_MUTE, subject, "testing", "console", 60
	)
	_check(muted.ok, "a voice mute is issued", str(muted.error))
	_check(
		services.moderation.is_voice_muted_key(subject),
		"and reads back as a voice mute rather than as a warning"
	)
	reloaded.queue_free()
	_done()


## What a throwable does, through dot-combat rather than through a constant.
func _test_combat() -> void:
	_section("combat")

	var combat := _module().combat

	_check(combat != null, "the combat rules are up")
	_check(
		_module().world.damage_gate.is_valid(),
		"and the world asks them before a throwable does anything"
	)

	# Point blank against maximum range. [b]The whole reason falloff is worth having[/b]:
	# a pepper thrown across the arena has to be worth less than one thrown in somebody's
	# face, or throwing is a button rather than a decision.
	var close := combat.resolve_throw(1, 2, HungryContent.ITEM_PEPPER, 10.0)
	var far := combat.resolve_throw(1, 2, HungryContent.ITEM_PEPPER, 5000.0)

	_check(close != null and not close.refused, "a point-blank hit lands")
	_check(
		close != null and far != null and far.amount < close.amount,
		"and one from across the arena does less (%.0f against %.0f)"
			% [far.amount if far != null else -1.0, close.amount if close != null else -1.0]
	)
	_check(
		combat.pieces_for(close) > combat.pieces_for(far),
		"which is fewer pieces (%d against %d)"
			% [combat.pieces_for(close), combat.pieces_for(far)]
	)

	# [b]Self damage is off, and a monster bursting itself is the world's own eject.[/b] A
	# scaled self hit would be a second, worse way to do a thing this game already has.
	var own := combat.resolve_throw(1, 1, HungryContent.ITEM_PEPPER, 10.0)
	_check(own != null and own.refused, "throwing at yourself is refused, not scaled")

	# An item the combat layer has no type for passes through untouched. Refusing it would
	# silently disable a throwable by installing an addon.
	var lure := combat.gate(1, 2, HungryContent.ITEM_LURE, 100.0)
	_check(
		bool(lure.get("allowed", false)),
		"a lure is not combat and is left alone"
	)
	_done()


## The NPC monsters, and the director that decides when they arrive.
func _test_hunters() -> void:
	_section("hunters")

	var hunters := _module().hunters

	_check(hunters != null, "the hunter layer is up")
	_check(
		hunters.spawner != null and hunters.spawner.two_dimensional,
		"and its spawner knows the world is 2D"
	)
	_check(
		not hunters.is_enabled(),
		"with the director off by default",
		"a mode about eating food and a mode about being hunted are different games"
	)

	# The wire order has to be stable and has to be sorted as String — `Array.sort()` on a
	# StringName compares interned pointers, and dot-net shipped exactly that bug.
	var ids := HungryHunters.wire_ids()
	var sorted := ids.duplicate()
	sorted.sort()
	_check(
		Array(ids) == Array(sorted),
		"the wire order is lexicographic, not interned-pointer order"
	)
	_check(
		HungryHunters.id_at(HungryHunters.index_of(&"stalker")) == &"stalker",
		"and an id round-trips through its index"
	)

	# [b]The plane, which is the whole of the 2D mapping.[/b] Get it wrong and a sight
	# range of 1400 is a sight range of nothing, silently.
	_check(
		DotNpcInstance.from_plane(DotNpcInstance.to_plane(Vector2(3.0, -7.0)))
			== Vector2(3.0, -7.0),
		"a 2D point round-trips through dot-npc's plane"
	)

	_server.console.execute("hungry_hunters on")
	_check(hunters.is_enabled(), "the console turns them on")

	# The director needs somebody to be stressed about before it releases anything.
	var world := _module().world
	world.add_player(4242, "Bait")
	world.spawn(4242)

	for _step in range(240):
		hunters.tick(1.0 / 60.0)

	_check(
		hunters.count() > 0,
		"and the director releases some (%d)" % hunters.count()
	)

	var kinds: Dictionary = {}

	for state in hunters.hunters().values():
		kinds[(state as Dictionary)["kind"]] = true

	_check(
		kinds.size() >= 1,
		"of the kinds in its population list (%s)" % str(kinds.keys())
	)

	# The candidate has to be a monster rather than a piece: a hunter chasing one fragment
	# of a split player walks past the other seven.
	_check(
		hunters.position_of(&"p4242") != Vector3.INF,
		"a player resolves as a candidate"
	)
	_check(
		hunters.position_of(&"p999999") == Vector3.INF,
		"and somebody who has gone resolves as INF rather than as the origin",
		"zero is the middle of the arena, so a hunter whose target left would sprint "
		+ "to the centre and mill about — which reads as a pathfinding bug"
	)

	_server.console.execute("hungry_hunters off")
	_check(hunters.count() == 0, "turning them off clears the arena")

	world.remove_player(4242)
	_done()


## Rocks, spikes and lures.
func _test_hazards() -> void:
	_section("hazards")

	var hazards := _module().hazards

	_check(hazards != null, "the hazard layer is up")

	var placed := hazards.place(0, &"rock", Vector2(200.0, 200.0))
	_check(placed.ok, "a rock goes down", str(placed.error))
	_check(hazards.count() == 1, "and the arena has one thing in it")
	_check(
		hazards.obstacles().size() == 1,
		"which is an obstacle both ends resolve against"
	)

	# A lure is a prop and is not an obstacle. The field is read rather than assumed:
	# dot-props' own sweep found two documented limits that limited nothing.
	var lure := hazards.place(0, &"lure", Vector2(-200.0, 0.0))
	_check(lure.ok, "a lure goes down too", str(lure.error))
	_check(
		hazards.obstacles().size() == 1,
		"and is NOT an obstacle (%d solid of %d placed)"
			% [hazards.obstacles().size(), hazards.count()]
	)
	_check(hazards.lures().size() == 1, "but it is a lure")

	# [b]Deterministic, because a round has to be reproducible.[/b] `randf()` here would
	# make two runs of the same seed lay out two different arenas, and the whole reason
	# `headless_round` can assert anything is that it does not.
	hazards.clear_all()
	var first := hazards.scatter(&"rock", 6, 4242)
	var layout: Array = []

	for entry in hazards.placements().values():
		layout.append((entry as Dictionary)["at"])

	hazards.clear_all()
	hazards.scatter(&"rock", 6, 4242)
	var again: Array = []

	for entry in hazards.placements().values():
		again.append((entry as Dictionary)["at"])

	layout.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	again.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	_check(first == 6, "a scatter places what it was asked for (%d)" % first)
	_check(
		layout == again,
		"and the same seed lays out the same arena twice"
	)

	hazards.clear_all()
	_check(hazards.count() == 0, "a clear empties it")
	_done()


## Boards and achievements over the numbers this game already counts.
func _test_progress() -> void:
	_section("boards and achievements")

	var progress := _module().progress

	_check(progress != null, "the progress layer is up")
	_check(
		progress.boards != null and progress.boards.definitions().size() == 3,
		"with three boards (%d)"
			% (progress.boards.definitions().size() if progress.boards != null else -1)
	)
	_check(
		progress.achievements != null and progress.achievements.catalogue.size() >= 8,
		"and a catalogue of achievements (%d)"
			% (progress.achievements.catalogue.size() if progress.achievements != null else -1)
	)

	# [b]Every stat an achievement watches has to be one the game reports.[/b] An
	# achievement watching a stat nothing records never unlocks, nothing errors, and the
	# only symptom is a player who did the thing and was not told — this family's most
	# repeated bug wearing a rosette.
	var schema := HungryModule.stats_schema()
	var missing := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not schema.has(stat) and stat != &"hunted":
			missing.append(String(stat))

	_check(
		missing.is_empty(),
		"every watched stat is one the game declares",
		"missing: %s" % str(missing)
	)

	var problems := progress.achievements.catalogue.validate()
	_check(problems.ok, "the catalogue validates", str(problems.error))

	# The link is the whole integration and it is a signal connection.
	_check(progress.link != null, "the stats link is wired")

	progress.begin("test-player")

	for _bite in range(120):
		progress.achievements.record("test-player", &"food", 1.0)

	_check(
		progress.achievements.is_unlocked("test-player", &"eat_100"),
		"a hundred bites unlocks the first tier"
	)
	_check(
		not progress.achievements.is_unlocked("test-player", &"eat_1000"),
		"and not the second"
	)

	# A board, and the PENALTY ordering — the half of `beats()` a SCORE board never runs.
	var monster := HungryMonster.new()
	monster.id = 7
	monster.display_name = "Tester"
	monster.best_mass = 4200.0
	monster.players_eaten = 3

	progress.file_round("test-player", monster, 2)
	progress.file_round("test-player", monster, 5)

	var deaths := progress.page(&"fewest_deaths", 5)
	_check(deaths.size() == 1, "a board holds one entry per player (%d)" % deaths.size())
	_check(
		deaths.size() == 1 and is_equal_approx((deaths[0] as DotLeaderboardEntry).value, 2.0),
		"and keeps the BETTER of two rounds, which on a penalty board is the lower",
		"%.0f" % ((deaths[0] as DotLeaderboardEntry).value if deaths.size() == 1 else -1.0)
	)

	var progressed: DotResult = await progress.achievements.flush()
	_check(progressed.ok, "progress writes to disk", str(progressed.error))
	_done()


## What plays next, and who decides.
func _test_vote() -> void:
	_section("the vote")

	var maps := _module().maps

	_check(maps != null, "the map rotation is up")
	_check(
		maps.catalogue != null and maps.catalogue.size() == 3,
		"with three modes in the catalogue (%d)"
			% (maps.catalogue.size() if maps.catalogue != null else -1)
	)
	_check(
		maps.director != null and maps.director.source != null
			and maps.director.source.is_usable(),
		"and a vote source over dot-server's own games",
		"what a vote applies has to be the thing that actually changes the game"
	)

	# [b]`gauntlet` is off the ballot below three players, and that is what a catalogue
	# buys over a hard-coded list.[/b] A corridor with two people in it is a chase; with
	# nobody in it, it is not a mode worth voting for.
	_check(
		not maps.available(&"hungry_gauntlet"),
		"a corridor is unavailable at this head count"
	)
	_check(maps.available(&"hungry_classic"), "and a square is not")

	var next := maps.next_in_rotation()
	_check(next != &"", "something is next in the rotation (%s)" % String(next))
	_check(
		next != StringName(_module().world.preset.id),
		"and it is not what is playing now",
		"a cooldown of one over three modes is what stops the same one twice running"
	)

	# Rocking the vote with one player. The threshold is a fraction of the head count and
	# `rtv_min_players` is 2, so this is refused — which is the check: a refusal that
	# arrives is a rule that ran, and dot-vote shipped a version where rocking the vote was
	# refused for ever on the deployment that depends on it.
	var rocked := maps.director.rock_the_vote(&"1")
	_check(
		rocked != null,
		"rocking the vote answers rather than doing nothing",
		str(rocked.error) if not rocked.ok else "accepted"
	)

	_check(
		not maps.director.begin_on_apply,
		"the director does not announce its own change",
		"the host announces it through `game_loaded`, which also fires for an operator "
		+ "typing `changegame` — both firing halves every cooldown"
	)
	_done()


func _test_transport() -> void:
	_section("browser clients")

	var transport := DotTransportWebSocket.new()
	_check(transport != null, "dot-core can build a WebSocket transport")
	_check(
		transport.supports_web_clients(),
		"which is the one browser clients can reach"
	)

	var available := transport._is_available()
	_check(
		available.ok,
		"and this engine build has the peer it needs",
		"a build without it cannot serve browser clients at all: %s"
			% str(available.error)
	)

	# The constraint that shapes the whole deployment: a browser cannot listen, so the web
	# build is a client and the server is somewhere else.
	_check(
		not DotPlatform.is_web(),
		"and this process can listen, because it is not a browser"
	)
	_done()


func _test_unload() -> void:
	_section("unloading")

	_check(_server.modules.unload_module("hungry").ok, "the module unloads")
	_check(
		_server.console.find_command("hungry_status") == null,
		"and takes its commands with it"
	)

	var world := _world()
	_check(
		world != null and world.monsters().is_empty(),
		"and its players, so the world is not left holding sessions that are gone"
	)

	_check(
		_server.modules.load_module("res://game/hungry_module.gd").ok,
		"and loads again cleanly"
	)
	_done()
