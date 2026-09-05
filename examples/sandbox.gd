extends Node

## A real server and a real client, one process, over a real socket, playing the game.
##
## [codeblock]
## godot --headless --path . res://examples/sandbox.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]What this proves that the other two cannot.[/b] `headless_round` plays the game with
## no network at all and `headless_net` plays it over a loopback that stands in for one.
## This one opens a socket, runs dot-server's whole signon — transport, challenge,
## credentials, authentication, content, load, spawn — with dot-platform resolving a
## profile and an avatar along the way, then plays over Godot's actual RPCs, sends a chat
## line through dot-server's chat manager, and changes the game underneath a connected
## player.
##
## [b]Two MultiplayerAPI instances in one process.[/b] A server and a client both want
## [member SceneTree.multiplayer] and there is one of those.
## [method SceneTree.set_multiplayer] scopes an API to a subtree, so each half gets its
## own and [code]multiplayer[/code] inside each resolves to the right one. dot-platform's
## sandbox is where that was worked out; this is the second place it is used, and the
## first place a game's own RPCs ride it.

const PORT := 27083
const PROFILE_DIR := "user://hungry_sandbox_profiles"
const AVATAR_DIR := "user://hungry_sandbox_avatars"
const SCOPE_KEY := "user://hungry_sandbox_scope.key"
const SERVER_DIR := "user://hungry_sandbox_server"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server: DotServer = null
var _link: DotClientLink = null
var _hub: DotPlatformHub = null
var _users: DotUserManager = null
var _avatars: DotAvatarManager = null
var _client: HungryClient = null
var _client_side: Node = null

## What the client's sampler hands the game each tick. The test drives it.
var _command := Dot2DCommand.new()

## Chat lines the client received.
var _heard: Array[Dictionary] = []

## The second player. Built later, in its own subtree with its own MultiplayerAPI.
var _other_side: Node = null
var _other_link: DotClientLink = null
var _other: HungryClient = null
var _other_command := Dot2DCommand.new()
var _other_heard: Array[Dictionary] = []


func _ready() -> void:
	# Quiet by default so the checks are readable; `-- --verbose` when one of them
	# fails and the reason is in a log line rather than in the assertion.
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario sandbox: a real socket")
	print("")

	_cleanup()

	var built := await _build()

	if built:
		var joined := await _test_join()

		if joined:
			await _test_client_scene()
			await _test_playing()
			await _test_chat()
			await _test_two_players()
			await _test_game_change()
			await _test_leaving()

	_teardown()
	_cleanup()

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
		_failures.append(what if detail == "" else "%s - %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _cleanup() -> void:
	DotPaths.remove_tree(PROFILE_DIR)
	DotPaths.remove_tree(AVATAR_DIR)
	DotPaths.remove_tree(SERVER_DIR)

	if FileAccess.file_exists(SCOPE_KEY):
		DirAccess.open("user://").remove(SCOPE_KEY.get_file())


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


## Waits for a condition, or gives up. Returns whether it happened.
##
## A deadline rather than a fixed number of frames: the point is to fail with a message
## rather than to hang, and a signon over loopback is several round trips plus a profile
## and an avatar read.
func _until(condition: Callable, seconds: float = 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return false


# --- Building both halves --------------------------------------------------

func _build() -> bool:
	print("bringing the sandbox up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), server_side.get_path()
	)
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _client_side.get_path()
	)

	_check(
		get_tree().get_multiplayer(server_side.get_path())
			!= get_tree().get_multiplayer(_client_side.get_path()),
		"the two halves have separate MultiplayerAPI instances"
	)

	if not await _build_platform():
		return false

	if not await _build_server(server_side):
		return false

	# Named "Server", which looks wrong and is not. Godot addresses an RPC by the
	# receiver's node path relative to its MultiplayerAPI root, so a call from the
	# server's node at ServerSide/Server arrives addressed to "Server" and is looked up
	# under the client's root. Give the client's node any other name and every RPC fails
	# with "Node not found: Server".
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Sandbox Visitor"
	_client_side.add_child(_link)

	return true


func _build_platform() -> bool:
	_users = DotUserManager.new()
	_users.register_service = true
	_users.load_layered_config = false
	_users.config_file = ""
	_users.server_id = "hungry-sandbox"

	var user_config := DotUserConfig.new()
	user_config.backend = "local"
	user_config.directory = PROFILE_DIR
	user_config.scope = "server:hungry-sandbox"
	user_config.scope_key_file = SCOPE_KEY
	user_config.allow_guest_profiles = true
	_users.config = user_config
	add_child(_users)

	var users_ready: DotResult = await _users.setup()

	if not _check(users_ready.ok, "profiles are up", str(users_ready.error)):
		return false

	_avatars = DotAvatarManager.new()
	# The same schema the game validates riders against. A server holding no art still
	# decides whether an avatar is legal, which is dot-user-avatar's one idea.
	_avatars.schema = HungryContent.avatar_schema()
	_avatars.register_service = true
	_avatars.load_layered_config = false
	_avatars.config_file = ""

	var avatar_config := DotAvatarConfig.new()
	avatar_config.backend = "local"
	avatar_config.directory = AVATAR_DIR
	_avatars.config = avatar_config
	add_child(_avatars)

	var avatars_ready: DotResult = await _avatars.setup()

	if not _check(avatars_ready.ok, "avatars are up", str(avatars_ready.error)):
		return false

	_hub = DotPlatformHub.new()
	_hub.register_service = true
	_hub.load_layered_config = false
	_hub.config_file = ""
	_hub.config = DotPlatformConfig.new()
	add_child(_hub)

	var hub_ready: DotResult = await _hub.setup()
	return _check(hub_ready.ok, "the platform is up", str(hub_ready.error))


func _build_server(server_side: Node) -> bool:
	# Guests, so no backbone is involved and this runs offline.
	var auth_config := DotAuthConfig.new()
	auth_config.strategy = DotAuthConfig.Strategy.ANONYMOUS
	auth_config.allow_guests = true

	var auth := DotAuthServer.new()
	auth.name = "Auth"
	auth.config = auth_config
	auth.config_file = ""
	auth.register_service = true
	server_side.add_child(auth)

	var config := DotServerConfig.new()
	config.hostname = "hungry sandbox"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens", str(booted.error)):
		return false

	for descriptor in HungryModule.game_descriptors():
		_server.games.add_game(descriptor)

	var loaded: DotResult = await _server.games.change_game(
		HungryModule.GAME_CLASSIC, "boot"
	)

	if not _check(loaded.ok, "the classic mode loads", str(loaded.error)):
		return false

	var platform := _server.modules.load_module(
		"res://addons/dot_platform/dot_platform_module.gd"
	)

	if not _check(platform.ok, "the platform module loads", str(platform.error)):
		return false

	var hungry := _server.modules.load_module("res://game/hungry_module.gd")
	return _check(hungry.ok, "and so does the game", str(hungry.error))


func _teardown() -> void:
	if _other_link != null and is_instance_valid(_other_link):
		_other_link.disconnect_from_server("shutdown")

	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("shutdown")

	if _server != null and is_instance_valid(_server):
		_server.shutdown("sandbox finished")


func _module() -> HungryModule:
	return _server.modules.get_module("hungry") as HungryModule


# --- Joining ---------------------------------------------------------------

func _test_join() -> bool:
	_section("a client connects")

	var spawned := [false]
	var refused := [""]

	_link.spawned.connect(func() -> void: spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: refused[0] = reason)
	_link.chat_received.connect(func(payload: Dictionary) -> void:
		_heard.append(payload)
	)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "the client starts connecting", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(func() -> bool:
		return spawned[0] or refused[0] != ""
	, 15.0)

	if not _check(
		admitted and spawned[0],
		"it completes signon and spawns",
		refused[0] if refused[0] != "" else "timed out at phase %s" % _link.phase
	):
		_done()
		return false

	_check(_server.sessions().size() == 1, "the server has one session")

	var on_platform := await _until(func() -> bool: return _hub.count() == 1, 8.0)
	_check(on_platform, "the platform admitted them")

	if on_platform:
		var player: DotPlatformPlayer = _hub.players()[0]
		_check(player.is_ready(), "and they reached READY", player.stage_name())
		_check(player.is_guest(), "as a guest, since this server has no accounts")
		_check(player.avatar != null, "with an avatar resolved for them")
		_check(
			player.avatar != null and player.avatar.has_slot(&"body"),
			"whose required slot is filled, so they can be seen"
		)

	# The game module puts them in the world off the same spawn event.
	var in_world := await _until(func() -> bool:
		var module := _module()
		return module != null and module.world != null \
			and module.world.monsters().size() > 0
	, 8.0)

	_check(in_world, "and the game put a monster in the world for them")
	_done()
	return in_world


func _test_client_scene() -> void:
	_section("the client scene")

	# The server does not name this. [DotClientLink] refuses an absolute scene path
	# outside dot-cloud's mount, because a server that could name one could ask a client
	# to load any scene in their build. A game shipped inside the build owns its own
	# client scene, and the signon takes the no-scene path.
	var packed: Variant = load("res://game/client/hungry_client.tscn")

	if not _check(packed is PackedScene, "the client scene loads"):
		_done()
		return

	_client = (packed as PackedScene).instantiate() as HungryClient
	_client_side.add_child(_client)

	await _frames(4)

	_check(_client != null, "and instantiates")
	_check(_client.world != null and not _client.world.is_authority, "with a world")
	_check(_client.net != null and _client.net.is_running(), "and a running manager")
	_check(_client.bridge != null and _client.bridge.link != null, "and a link")
	_check(
		_link.get_node_or_null(NodePath(String(HungryNetLink.NODE_NAME))) != null,
		"parented to the client link, where the server's RPCs will find it"
	)
	_check(_client.hud != null, "and a HUD")
	_check(
		_client.screens != null and _client.screens.registered_ids().size() >= 5,
		"and its screens (%d)" % (
			_client.screens.registered_ids().size() if _client.screens != null else 0
		)
	)

	# The pointer is what drives this game, and a headless run has none. The sampler's
	# command source is the documented seam for exactly that - the same one a bot in a
	# client's seat or a demo playback would use.
	_client.sampler.command_source = func() -> Dot2DCommand:
		return _command

	_done()


func _test_playing() -> void:
	_section("playing")

	var told := await _until(func() -> bool:
		return _client.bridge.local_player_id != 0
	, 8.0)

	if not _check(told, "the client is told who it is"):
		_done()
		return

	var mine := _client.bridge.local_player_id
	var module := _module()

	_check(
		module.world.monster_for(mine) != null,
		"and the server agrees that is a player (%d)" % mine
	)

	var has_field := await _until(func() -> bool:
		return _client.world.field.alive_count() > 100
	, 8.0)

	_check(
		has_field,
		"the field arrived (%d slots)" % _client.world.field.alive_count()
	)
	# Waited for rather than asserted: a round going live reseeds the whole field and
	# resends it, so a client admitted a moment before that legitimately holds the
	# previous seed for a few frames. What must not happen is that it keeps it.
	var seeded := await _until(func() -> bool:
		return _client.world.field.seed_value() == module.world.field.seed_value()
	, 8.0)

	_check(
		seeded,
		"from the same seed (%d vs %d)" % [
			_client.world.field.seed_value(), module.world.field.seed_value()
		]
	)
	_check(
		_client.world.arena.bounds.size.is_equal_approx(module.world.arena.bounds.size),
		"into the same arena (%s vs %s)" % [
			_client.world.arena.bounds.size, module.world.arena.bounds.size
		]
	)

	var mirrored := await _until(func() -> bool:
		return _client.bridge.piece_count() > 0
	, 8.0)

	_check(mirrored, "and the monster is mirrored")

	# Now actually play. Everything from here is over the socket: the command goes out as
	# an RPC, the server simulates it, and the state comes back in a snapshot.
	var before := module.world.monster_for(mine).centre()

	_command = Dot2DCommand.new()
	_command.aim = Vector2.RIGHT
	_command.reach = 900.0

	var moved := await _until(func() -> bool:
		var monster := module.world.monster_for(mine)
		return monster != null and monster.centre().distance_to(before) > 150.0
	, 10.0)

	_check(
		moved,
		"the server moves the monster from the client's input (%.0f units)"
			% module.world.monster_for(mine).centre().distance_to(before)
	)

	var client_monster := _client.world.monster_for(mine)
	var apart := client_monster.centre().distance_to(
		module.world.monster_for(mine).centre()
	)

	_check(
		apart < 60.0,
		"and the client agrees where it is (%.1f units apart)" % apart
	)

	_check(
		_client.net.clock.is_synced(),
		"the clock is synced (rtt %d ms)" % int(_client.net.clock.rtt_ms())
	)
	_check(
		_client.net.stats.snapshots_received > 0,
		"snapshots are arriving (%d)" % _client.net.stats.snapshots_received
	)
	_check(
		_client.net.stats.decode_failures == 0,
		"with no decode failures"
	)
	_check(
		module.bridge.link.inputs_received > 0,
		"and inputs are reaching the server (%d)" % module.bridge.link.inputs_received
	)

	# The avatar the client published is the one the server holds. This is the whole
	# dot-user-avatar path over a real connection: a document of ids, validated against a
	# schema by a server that loaded no art.
	var server_monster := module.world.monster_for(mine)
	_check(
		server_monster != null and server_monster.avatar != null,
		"the server holds an avatar for them"
	)
	_check(
		server_monster != null and server_monster.avatar != null
			and server_monster.avatar.schema_id == HungryContent.avatar_schema().id,
		"under the rider schema"
	)

	_command = Dot2DCommand.new()
	_done()


func _test_chat() -> void:
	_section("chat")

	var before := _heard.size()
	_link.send_chat("hello from the sandbox", false)

	var heard := await _until(func() -> bool: return _heard.size() > before, 6.0)

	if not _check(heard, "a line the client sends comes back to it"):
		_done()
		return

	var last: Dictionary = _heard[_heard.size() - 1]
	_check(
		String(last.get("text", "")).contains("hello from the sandbox"),
		"with the text intact",
		str(last)
	)

	# The HUD is what a player actually sees, and it takes the payload straight from
	# [signal DotClientLink.chat_received].
	var lines := _client.hud.feed.line_count()
	_client.hud.chat(last)
	_check(
		_client.hud.feed.line_count() > lines,
		"and the HUD shows it"
	)

	# Sanitising is dot-server's and happens before anything else sees the text. A
	# zero-width space is what somebody uses to slip a name past a filter or to break a
	# HUD's layout, and a client should never be handed one.
	var zero_width := String.chr(0x200B)
	var dirty := await _say_and_wait("bad%sline" % zero_width)
	_check(
		dirty != "" and not dirty.contains(zero_width),
		"and a zero-width space never reaches a client",
		dirty
	)
	_done()


func _say_and_wait(text: String) -> String:
	var before := _heard.size()
	_link.send_chat(text, false)

	var heard := await _until(func() -> bool: return _heard.size() > before, 6.0)

	if not heard:
		return ""

	return String((_heard[_heard.size() - 1] as Dictionary).get("text", ""))


## A second player, over a second socket, in a second MultiplayerAPI.
##
## [b]The thing a multiplayer game must do, and the thing nothing in this family had ever
## checked.[/b] Everything before this is one client: it proves the signon, the RPC paths
## and the netcode, and proves nothing at all about whether two people can see each other.
## Interest management, the roster, the join broadcast and the piece mirroring are all
## per-observer, and every one of them is trivially correct with one observer.
##
## A third MultiplayerAPI, rooted at its own subtree, for the reason the first two need
## one: there is a single `SceneTree.multiplayer` and three peers in this process want it.
func _test_two_players() -> void:
	_section("a second player")

	_other_side = Node.new()
	_other_side.name = "OtherSide"
	add_child(_other_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _other_side.get_path()
	)

	_other_link = DotClientLink.new()
	# "Server", the same as the first one and the same as DotServer. The name is the
	# routing, not a description.
	_other_link.name = "Server"
	_other_link.player_name = "Second Visitor"
	_other_side.add_child(_other_link)

	var spawned := [false]
	_other_link.spawned.connect(func() -> void: spawned[0] = true)
	_other_link.chat_received.connect(func(payload: Dictionary) -> void:
		_other_heard.append(payload)
	)

	var connecting: DotResult = await _other_link.connect_to_server(
		"127.0.0.1:%d" % PORT
	)

	if not _check(connecting.ok, "it connects", str(connecting.error)):
		_done()
		return

	var joined := await _until(func() -> bool: return spawned[0], 15.0)

	if not _check(joined, "and completes signon"):
		_done()
		return

	_check(_server.sessions().size() == 2, "the server has two sessions")

	var packed: Variant = load("res://game/client/hungry_client.tscn")
	_other = (packed as PackedScene).instantiate() as HungryClient
	_other_side.add_child(_other)
	_other.sampler.command_source = func() -> Dot2DCommand:
		return _other_command

	var told := await _until(func() -> bool:
		return _other.bridge.local_player_id != 0
	, 10.0)

	if not _check(told, "and is told who it is"):
		_done()
		return

	var mine := _client.bridge.local_player_id
	var theirs := _other.bridge.local_player_id

	_check(mine != theirs, "the two have different ids (%d and %d)" % [mine, theirs])

	# Each has to know the other exists, which is the join broadcast, and to have a piece
	# for them, which is interest plus the spawn events.
	var sees_them := await _until(func() -> bool:
		var monster := _client.world.monster_for(theirs)
		return monster != null and monster.piece_count() > 0
	, 10.0)

	var sees_us := await _until(func() -> bool:
		var monster := _other.world.monster_for(mine)
		return monster != null and monster.piece_count() > 0
	, 10.0)

	_check(sees_them, "the first client sees the second")
	_check(sees_us, "and the second sees the first")

	var module := _module()

	# And the positions agree. This is the whole of "two people are in the same world":
	# the server's idea of where somebody is, and every other client's, being the same
	# place.
	var server_at := module.world.monster_for(theirs).centre()
	var seen_at := _client.world.monster_for(theirs).centre()

	_check(
		seen_at.distance_to(server_at) < 80.0,
		"in the place the server says (%.1f units off)" % seen_at.distance_to(server_at)
	)

	# Move the second one and the first has to watch it move.
	var before := _client.world.monster_for(theirs).centre()
	_other_command = Dot2DCommand.new()
	_other_command.aim = Vector2.UP
	_other_command.reach = 900.0

	var moved := await _until(func() -> bool:
		var monster := _client.world.monster_for(theirs)
		return monster != null and monster.centre().distance_to(before) > 120.0
	, 10.0)

	_check(
		moved,
		"and watches it move (%.0f units)"
			% _client.world.monster_for(theirs).centre().distance_to(before)
	)

	_other_command = Dot2DCommand.new()

	# And still agrees about where it ended up. Moving is the easy half; a client whose
	# view of somebody else drifts while they move is a client that will be eaten by
	# something it was drawing somewhere else.
	var settled := await _until(func() -> bool:
		var here := _client.world.monster_for(theirs)
		var there := module.world.monster_for(theirs)
		return here != null and there != null \
			and here.centre().distance_to(there.centre()) < 40.0
	, 8.0)

	_check(
		settled,
		"and agrees where it stopped (%.1f units off)"
			% _client.world.monster_for(theirs).centre().distance_to(
				module.world.monster_for(theirs).centre()
			)
	)

	# Chat goes to everybody, not back to the sender only.
	var heard_before := _heard.size()
	_other_link.send_chat("second player here", false)

	var relayed := await _until(func() -> bool: return _heard.size() > heard_before, 6.0)
	_check(relayed, "a line from one reaches the other")

	# A loadout published by one is broadcast to all, because the trait changes how fast
	# that monster moves and every client predicts nothing about it but draws all of it.
	var schema := _other.bridge.loadout_schema
	var chosen := DotLoadout.empty(schema.id)
	chosen.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_FROST)
	chosen.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_STURDY)
	_other.bridge.publish_loadout(chosen)

	var shared := await _until(func() -> bool:
		var monster := _client.world.monster_for(theirs)
		return monster != null and monster.trait_id == HungryContent.TRAIT_STURDY
	, 8.0)

	_check(shared, "and so does a loadout they chose")

	# Leaving has to be visible too: a monster left behind by a player who is gone is one
	# everybody else can still be eaten by.
	_other_link.disconnect_from_server("done")

	var forgotten := await _until(func() -> bool:
		return _client.world.monster_for(theirs) == null
	, 10.0)

	_check(forgotten, "and when they leave, the other stops seeing them")
	_check(
		module.world.monster_for(theirs) == null,
		"and the server drops them too"
	)

	_other = null
	_other_link = null
	_done()


func _test_game_change() -> void:
	_section("changing the game with somebody in it")

	var module := _module()
	var mine := _client.bridge.local_player_id
	var before_world := module.world

	var changed: DotResult = await _server.games.change_game(
		HungryModule.GAME_FRENZY, "sandbox"
	)

	if not _check(changed.ok, "the server changes to frenzy", str(changed.error)):
		_done()
		return

	await _frames(10)

	_check(module.world != before_world, "onto a new world")
	_check(String(module.world.preset.id) == "frenzy", "under the new preset")
	_check(_link.is_connected_to_server(), "and the client is still connected")

	var followed := await _until(func() -> bool:
		return _client.world.arena.bounds.size.is_equal_approx(
			module.world.arena.bounds.size
		)
	, 10.0)

	_check(
		followed,
		"the client took the new arena (%s vs %s)" % [
			_client.world.arena.bounds.size, module.world.arena.bounds.size
		]
	)
	_check(
		_client.world.field.seed_value() == module.world.field.seed_value(),
		"and the new field seed"
	)

	var back_in := await _until(func() -> bool:
		var monster := module.world.monster_for(mine)
		return monster != null and monster.alive and _client.bridge.piece_count() > 0
	, 10.0)

	_check(back_in, "and is playing again without reconnecting")
	_done()


func _test_leaving() -> void:
	_section("leaving")

	var module := _module()
	_link.disconnect_from_server("done")

	var gone := await _until(func() -> bool:
		return _server.sessions().is_empty()
	, 8.0)

	_check(gone, "the session closes")

	var released := await _until(func() -> bool: return _hub.count() == 0, 8.0)
	_check(released, "the platform released them")

	var world_clear := await _until(func() -> bool:
		return module.world == null or module.world.monsters().is_empty()
	, 8.0)

	_check(
		world_clear,
		"and the world is not left holding a monster whose session is gone"
	)
	_done()
