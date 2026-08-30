extends Node

## Runs a server and a client in one process and checks the netcode works.
##
## [codeblock]
## godot --headless --path . res://examples/headless_net.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]Everything here is offline and reproducible.[/b] The two halves are wired to each
## other through a loopback that can delay and drop packets, which is the only way to test
## interpolation, loss recovery and reconciliation at all — a real socket does not
## reproduce the same conditions twice. The socket itself is what
## [code]examples/sandbox.tscn[/code] is for.

const TICK_RATE := 60
const SNAPSHOT_RATE := 20
const SEED := 20260828
const CLIENT_PEER := 2

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server_world: HungryWorld = null
var _client_world: HungryWorld = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: HungryNetBridge = null
var _client_bridge: HungryNetBridge = null

## Payloads in flight, so loss and delay can be simulated.
var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []

## Drop one snapshot in this many. Zero drops nothing.
var _drop_every: int = 0
var _snapshot_count: int = 0

var _tick: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-2d-hungry: netcode")
	print("")

	_test_command_wire()
	_test_event_wire()
	_test_field_wire()

	if _build():
		_test_handshake()
		_test_replication()
		_test_prediction()
		_test_field_replication()
		_test_splitting_replicates()
		_test_throw_replicates()
		_test_interest()
		_test_avatar()
		_test_interpolation()
		_test_loadout()
		_test_direction_enforced()
		_test_loss()
		_test_game_change()

	_teardown()

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


# --- The wire, on its own --------------------------------------------------

func _test_command_wire() -> void:
	_section("commands on the wire")

	var original := HungryNetCommand.new()
	original.tick = 41
	original.delta = 1.0 / 60.0
	original.command.aim = Vector2(0.6, -0.8)
	original.command.reach = 640.0
	original.command.set_button(Dot2DCommand.BUTTON_SPLIT, true)

	var writer := DotNetWriter.new()
	original.write(writer)

	var back := HungryNetCommand.new()
	back.read(writer.to_reader())

	_check(back.tick == original.tick, "the tick survives")
	_check(
		back.command.aim.distance_to(original.command.aim) < 0.01,
		"the aim survives (%.4f off)"
			% back.command.aim.distance_to(original.command.aim)
	)
	_check(
		absf(back.command.reach - original.command.reach) < 2.0,
		"the reach survives (%.2f off)"
			% absf(back.command.reach - original.command.reach)
	)
	_check(
		back.command.is_pressed(Dot2DCommand.BUTTON_SPLIT), "and so do the buttons"
	)

	# Sanitising is not optional and it is not redundant with quantisation: quantisation
	# bounds each field on its own and cannot bound the relationship between them.
	var hostile := HungryNetCommand.new()
	hostile.command.aim = Vector2(40.0, 40.0)
	hostile.command.reach = 99999.0
	hostile.command.buttons = -1
	hostile.sanitise(TICK_RATE)

	_check(
		absf(hostile.command.aim.length() - 1.0) < 0.001,
		"a forty-times-too-long aim is normalised"
	)
	_check(
		hostile.command.reach <= HungryNetCommand.MAX_REACH,
		"an out-of-range reach is clamped (%.0f)" % hostile.command.reach
	)
	_check(
		hostile.command.buttons < (1 << Dot2DCommand.BUTTON_BITS),
		"and unknown buttons are masked off"
	)
	_done()


func _test_event_wire() -> void:
	_section("events on the wire")

	var schema := HungryContent.avatar_schema()

	var hello := HungryEvents.read_hello(
		DotNetReader.new(
			HungryEvents.write_hello(
				12345, 60, 7, 2, 900, Vector2(5200.0, 5200.0),
				"https://cdn.example/hungry/manifest.json"
			)
		)
	)
	_check(bool(hello["ok"]), "hello round-trips")
	_check(int(hello["seed"]) == 12345, "with the seed")
	_check(int(hello["player_id"]) == 7, "and who you are")
	_check(int(hello["tick"]) == 900, "and the tick")
	_check(
		String(hello["pack_url"]) == "https://cdn.example/hungry/manifest.json",
		"and where this server's rider content lives"
	)

	var avatar := HungryContent.default_avatar(3)
	avatar.set_part(&"hat", &"hat_cap")
	avatar.set_colour(&"hat", 0, Color(0.2, 0.4, 0.9))

	var join := HungryEvents.read_join(
		DotNetReader.new(HungryEvents.write_join(7, 2, "Ada", avatar, schema)), schema
	)
	_check(bool(join["ok"]), "a join round-trips")
	_check(String(join["name"]) == "Ada", "with the name")

	var carried: Variant = join["avatar"]
	_check(carried is DotAvatar, "and the avatar")
	_check(
		carried is DotAvatar and (carried as DotAvatar).digest() == avatar.digest(),
		"which is the same document",
		"%s vs %s" % [
			(carried as DotAvatar).digest() if carried is DotAvatar else "-",
			avatar.digest(),
		]
	)

	var spawn := HungryEvents.read_spawn(
		DotNetReader.new(
			HungryEvents.write_spawn(31, 2, 7, 4, Vector2(-1234.5, 678.9), 412.0)
		)
	)
	_check(bool(spawn["ok"]), "a spawn round-trips")
	_check(int(spawn["net_id"]) == 31 and int(spawn["piece_id"]) == 4, "with both ids")
	_check(
		(spawn["position"] as Vector2).distance_to(Vector2(-1234.5, 678.9)) < 0.1,
		"and the position"
	)
	_check(is_equal_approx(float(spawn["mass"]), 412.0), "and the mass")

	var shot := HungryProjectile.make(
		9, 7, HungryContent.ITEM_FROST, Vector2(100.0, -50.0), Vector2(0.6, 0.8), 512
	)
	var thrown := HungryEvents.read_throw(
		DotNetReader.new(HungryEvents.write_throw(shot))
	)
	_check(bool(thrown["ok"]), "a throw round-trips")
	_check(
		HungryContent.ITEM_IDS[int(thrown["item_index"])] == HungryContent.ITEM_FROST,
		"with the item"
	)
	_check(int(thrown["tick"]) == 512, "and the tick it left on")

	var carry := HungryEvents.read_carry(
		DotNetReader.new(
			HungryEvents.write_carry(
				[HungryContent.ITEM_PEPPER, HungryContent.ITEM_LURE]
			)
		)
	)
	_check(
		carry.size() == 2 and carry[0] == HungryContent.ITEM_PEPPER,
		"and a carry list round-trips"
	)

	# A body claiming a kind that does not exist has to be refused rather than
	# dispatched, because the handler's `match` would silently fall through.
	var bogus := HungryEvent.of(31, PackedByteArray())
	_check(not bogus.validate().ok, "an unknown event kind is refused")
	_done()


func _test_field_wire() -> void:
	_section("the field on the wire")

	var added: Array = [
		HungryField.FOOD_ID_BASE + 4,
		HungryField.FRUIT_ID_BASE + 1,
		HungryField.PLANTED_ID_BASE + 9,
	]
	var removed: Array = [HungryField.FOOD_ID_BASE + 5, HungryField.ITEM_ID_BASE + 2]
	var planted := {
		HungryField.PLANTED_ID_BASE + 9: {
			"position": Vector2(321.0, -654.0), "tier": 1
		}
	}

	var back := HungryEvents.read_field(
		DotNetReader.new(HungryEvents.write_field(added, removed, planted))
	)

	_check(bool(back["ok"]), "a field delta round-trips")
	_check((back["added"] as Array).size() == 3, "with everything added")
	_check((back["removed"] as Array).size() == 2, "and everything taken")

	var rows: Dictionary = back["planted"]
	var row: Dictionary = rows.get(HungryField.PLANTED_ID_BASE + 9, {})
	_check(
		row.has("position")
			and (row["position"] as Vector2).distance_to(Vector2(321.0, -654.0)) < 0.1,
		"and a planted crumb keeps the position it was put at"
	)

	# A hostile count must be refused before it is looped over. Four billion is one
	# varint and would otherwise be four billion iterations.
	var hostile := DotNetWriter.new()
	hostile.write_varint(4_000_000_000)
	var refused := HungryEvents.read_field(hostile.to_reader())
	_check(not bool(refused["ok"]), "an absurd count is refused, not iterated")


# --- Both halves -----------------------------------------------------------
	_done()

func _make_world(authority: bool, scope: StringName) -> HungryWorld:
	var world := HungryWorld.new()
	world.name = "World" if authority else "ClientWorld"
	world.preset = HungryPreset.classic()
	world.tick_rate = TICK_RATE
	world.world_seed = SEED
	world.is_authority = authority
	world.register_service = true
	world.service_scope = scope
	add_child(world)
	world.setup()

	if authority:
		world.start(0)

	return world


func _make_manager(server: bool, scope: StringName, peer_id: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = TICK_RATE
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 120
	config.world_extent = Dot2DNetSync.WORLD_EXTENT
	manager.config = config

	add_child(manager)
	manager.setup()
	return manager


func _build() -> bool:
	print("")
	print("bringing both halves up")

	# Two subtrees so the two link nodes are not siblings with the same name. Nothing here
	# touches the multiplayer API — the loopback stands in for it — but the tree still has
	# to be legal.
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_world = _make_world(true, &"server")
	_client_world = _make_world(false, &"client")

	_server_net = _make_manager(true, &"server", 1)
	_client_net = _make_manager(false, &"client", CLIENT_PEER)

	_server_bridge = HungryNetBridge.new()
	_server_bridge.name = "ServerBridge"
	add_child(_server_bridge)

	_client_bridge = HungryNetBridge.new()
	_client_bridge.name = "ClientBridge"
	add_child(_client_bridge)

	var server_attached := _server_bridge.attach(_server_world, _server_net, server_side)
	var client_attached := _client_bridge.attach(_client_world, _client_net, client_side)

	if not _check(server_attached.ok, "the server bridge attaches", str(server_attached.error)):
		return false

	if not _check(client_attached.ok, "the client bridge attaches", str(client_attached.error)):
		return false

	# A world and a manager that disagree about who is authoritative would resolve
	# everybody's eating or nobody's, silently. The bridge refuses instead.
	var wrong := HungryNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_world, _server_net, server_side)
	_check(not refused.ok, "and a mismatched pair is refused")
	remove_child(wrong)
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()

	_check(
		_server_net.messages.schema_hash() == _client_net.messages.schema_hash(),
		"the two ends agree on the message schema",
		"%s vs %s" % [
			_server_net.messages.schema_hash(), _client_net.messages.schema_hash()
		]
	)

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send

	_server_net.start()
	_client_net.start()

	return true


func _teardown() -> void:
	for node in [
		_server_bridge, _client_bridge, _server_net, _client_net,
		_server_world, _client_world,
	]:
		if node != null and is_instance_valid(node):
			remove_child(node)
			node.queue_free()


# --- The loopback ----------------------------------------------------------

func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if method == &"snapshot":
		_snapshot_count += 1

		# Dropped rather than delayed: a lost snapshot is the case the acked baselines
		# exist for, and the only way to know they work is to lose some.
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return

	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


## Delivers everything in flight, in order.
func _flush() -> void:
	# Copied and cleared first: delivering an event can cause a reply, and appending to
	# the array being walked would deliver it inside the same flush.
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## How far ahead of the server the client stamps its inputs.
##
## [b]Not a fudge factor.[/b] A command for tick N has to be in the server's hands
## [i]before[/i] it simulates N, so a client running level with the server has every input
## arrive one tick late — for ever, silently, with the only symptom a player who cannot
## move. [DotNetClock] is what does this in a real deployment; here the harness does it by
## hand because there is no clock to synchronise against.
const INPUT_LEAD := 2

## One tick of both halves, with the wire drained in between.
func _step(command: Dot2DCommand = null) -> void:
	_tick += 1
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(
		_tick + INPUT_LEAD, command if command != null else Dot2DCommand.new()
	)
	_flush()


func _steps(count: int, command: Dot2DCommand = null) -> void:
	for _i in range(count):
		_step(command)


# --- The tests -------------------------------------------------------------

func _test_handshake() -> void:
	_section("a client joins")

	var added := _server_bridge.add_player(CLIENT_PEER, 7, "Ada")
	_check(added.ok, "the server adds them", str(added.error))

	_check(
		not _server_net.peers().has(CLIENT_PEER),
		"and sends them nothing until they ask"
	)

	# The client asking is what admits it. Between dot-server's signon finishing and the
	# client building its scene there is a window in which it has no node for an RPC to
	# land on, so everything sent in it is lost and logged as a missing node.
	_client_bridge.ask_for_world()
	_flush()
	_flush()

	_check(_server_net.peers().has(CLIENT_PEER), "asking admits them")

	_check(
		_client_bridge.local_player_id == 7,
		"and the client learns who it is (%d)" % _client_bridge.local_player_id
	)
	_check(
		_client_world.monster_for(7) != null,
		"and has a monster for itself"
	)
	_check(
		_client_world.field.seed_value() == _server_world.field.seed_value(),
		"and the same field seed"
	)
	_check(
		_client_bridge.avatar_pack_url == _server_bridge.avatar_pack_url,
		"and the same rider content, if there is any (%s)"
			% ("none" if _client_bridge.avatar_pack_url == ""
				else _client_bridge.avatar_pack_url)
	)
	_check(
		_client_world.field.alive_count() == _server_world.field.alive_count(),
		"and the same food (%d vs %d)" % [
			_client_world.field.alive_count(), _server_world.field.alive_count()
		]
	)

	# The whole point of a seed: a client that received eleven hundred positions would
	# have paid about 5 kB for what an integer bought.
	var mismatched := 0

	for grid_id in _server_world.field.alive_ids():
		if _client_world.field.position_of(grid_id).distance_to(
			_server_world.field.position_of(grid_id)
		) > 0.001:
			mismatched += 1

	_check(
		mismatched == 0,
		"and every crumb is in the same place without a position being sent"
	)

	_steps(4)

	_check(
		_client_bridge.piece_count() == _server_bridge.piece_count(),
		"the piece is mirrored (%d vs %d)" % [
			_client_bridge.piece_count(), _server_bridge.piece_count()
		]
	)

	var mine := _client_world.monster_for(7)
	_check(mine != null and mine.alive, "and the client's monster is alive")

	var predicted := _client_net.registry.predicted()
	_check(
		predicted.size() == mine.piece_count(),
		"and the client predicts every piece it owns (%d)" % predicted.size()
	)
	_done()


func _test_replication() -> void:
	_section("state")

	var command := Dot2DCommand.new()
	command.aim = Vector2.RIGHT
	command.reach = 800.0

	var before := _server_world.monster_for(7).centre()
	_steps(90, command)

	var server_at := _server_world.monster_for(7).centre()
	var client_at := _client_world.monster_for(7).centre()

	_check(
		server_at.distance_to(before) > 100.0,
		"the server simulated movement (%.0f units)" % server_at.distance_to(before)
	)
	_check(
		client_at.distance_to(server_at) < 6.0,
		"and the client agrees within six units (%.2f)"
			% client_at.distance_to(server_at)
	)

	# The radius is derived from the received mass, never replicated: two copies of one
	# number eventually disagree by a rounding error, and then a monster's eat radius and
	# its drawn radius are in different places.
	var server_piece := _server_world.monster_for(7).rider_piece()
	var client_piece := _client_world.monster_for(7).rider_piece()

	_check(
		client_piece != null
			and absf(client_piece.radius() - server_piece.radius()) < 0.5,
		"and the radius follows the mass on both ends"
	)
	_check(
		client_piece != null
			and (client_piece.state.flags & HungryContent.FLAG_RIDER) != 0,
		"and the rider flag arrived"
	)
	_done()


func _test_prediction() -> void:
	_section("prediction")

	# [b]Not near zero in this game, and that is correct.[/b] A client predicts where its
	# monster went; it does not predict what its monster ate, because eating is the
	# authority's and a client that resolved its own would be a client that decides what
	# it weighs. So every crumb swallowed is a mass the client did not have, a speed it
	# did not use, and a small correction on the next snapshot. What matters is that the
	# corrections stay small — the distance checks below — rather than that they stop.
	# [b]It is not zero in this game, and that is correct.[/b] A client predicts where its
	# monster went; it does not predict what its monster ate, because eating is the
	# authority's and a client that resolved its own would be a client that decides what
	# it weighs. Every crumb swallowed is therefore a mass the client did not have, a
	# speed it did not use, and a small correction on the next snapshot.
	#
	# What it must not be is [i]most[/i] snapshots. This read 0.500 while the bridge was
	# reconciling a second time on top of the reconciliation
	# [method DotNetManager.receive_snapshot] had already done — replaying the same inputs
	# twice against values that had already been rewound. Removing that pass took it to
	# 0.03, and neither number produced an error or a failed check anywhere else.
	var rate := _client_net.predictor.correction_rate()
	_check(
		rate < 0.25,
		"corrections stay rare (%.3f of snapshots)" % rate,
		"consistently high means the two simulations disagree, and no smoothing fixes that"
	)

	# The client's own monster must respond on the tick the input is given, not a round
	# trip later. Measured against the client's own previous position, because that is
	# what the player sees.
	var command := Dot2DCommand.new()
	command.aim = Vector2.UP
	command.reach = 900.0

	var before := _client_world.monster_for(7).centre()
	_client_bridge.client_tick(_tick + INPUT_LEAD + 1, command)
	var after := _client_world.monster_for(7).centre()

	_check(
		after.distance_to(before) > 0.5,
		"the client moves on the tick it presses (%.2f units)"
			% after.distance_to(before)
	)

	_steps(30, command)
	_check(
		_client_world.monster_for(7).centre().distance_to(
			_server_world.monster_for(7).centre()
		) < 8.0,
		"and stays with the server afterwards"
	)
	_done()


func _test_field_replication() -> void:
	_section("food")

	# Put the monster on a crumb and let it eat. What has to arrive is not the crumb but
	# the fact that it is gone.
	var target := 0

	for grid_id in _server_world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.FOOD:
			target = grid_id
			break

	_server_world.spawn(7, _server_world.field.position_of(target))
	_steps(4)

	_check(
		not _server_world.field.food.is_alive(HungryField.index_of(target)),
		"the server ate a crumb"
	)
	_check(
		not _client_world.field.food.is_alive(HungryField.index_of(target)),
		"and the client was told"
	)
	_check(
		absi(_client_world.field.alive_count() - _server_world.field.alive_count()) <= 8,
		"and the two fields stay in step (%d vs %d)" % [
			_client_world.field.alive_count(), _server_world.field.alive_count()
		]
	)

	# The refill also has to travel, or a client's world empties over a long round while
	# the server's stays full.
	var before := _client_world.field.alive_count()
	_steps(30)
	_check(
		_client_world.field.alive_count() >= before,
		"and the refill arrives too"
	)
	_done()


func _test_splitting_replicates() -> void:
	_section("splitting, over the wire")

	var monster := _server_world.monster_for(7)
	monster.rider_piece().set_mass(500.0, _server_world.tunables.mass_rules)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var before := _client_bridge.piece_count()

	var split := Dot2DCommand.new()
	split.aim = Vector2.RIGHT
	split.reach = 700.0
	split.set_button(Dot2DCommand.BUTTON_SPLIT, true)

	_step(split)

	var release := Dot2DCommand.new()
	release.aim = Vector2.RIGHT
	release.reach = 700.0
	_steps(10, release)

	_check(
		_server_world.monster_for(7).piece_count() > 1,
		"the server split them (%d pieces)"
			% _server_world.monster_for(7).piece_count()
	)
	_check(
		_client_bridge.piece_count() > before,
		"and the client mirrored the new piece (%d -> %d)" % [
			before, _client_bridge.piece_count()
		]
	)
	_check(
		_client_world.monster_for(7).piece_count()
			== _server_world.monster_for(7).piece_count(),
		"and holds the same number of them"
	)

	# Both ends must agree which piece the rider is on, or the avatar is drawn on a
	# different fragment on every machine.
	var server_rider := _server_world.monster_for(7).rider_piece()
	var client_rider := _client_world.monster_for(7).rider_piece()
	_check(
		server_rider != null and client_rider != null
			and server_rider.id == client_rider.id,
		"and on the same piece the rider is on"
	)

	# And a merge has to take the entity away again, or a client accumulates ghosts.
	var pieces_before := _client_bridge.piece_count()
	_server_world.forget_piece(server_rider.id)
	_flush()
	_check(
		_client_bridge.piece_count() < pieces_before,
		"a piece that goes away is despawned everywhere"
	)
	_done()


func _test_throw_replicates() -> void:
	_section("throwing, over the wire")

	var monster := _server_world.monster_for(7)
	_server_world.spawn(7, Vector2.ZERO)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)
	monster.carried.clear()
	monster.take_item(HungryContent.ITEM_PEPPER)
	monster.throw_ready_tick = _server_world.current_tick()

	var thrown: Array[int] = []
	_client_bridge.cue.connect(func(kind: int, _data: Dictionary) -> void:
		thrown.append(kind)
	)

	var throw_command := Dot2DCommand.new()
	throw_command.aim = Vector2.RIGHT
	throw_command.reach = 600.0
	throw_command.set_button(Dot2DCommand.BUTTON_ACTION, true)

	# Inputs are stamped ahead of the server, so the press lands a couple of ticks later.
	_steps(INPUT_LEAD + 2, throw_command)

	_check(
		_client_world.projectiles().size() == 1,
		"the client sees the pepper in flight (%d)"
			% _client_world.projectiles().size()
	)

	# The flight is a straight line from a start tick, so both ends draw it in the same
	# place without another byte.
	if _client_world.projectiles().size() == 1 \
			and _server_world.projectiles().size() == 1:
		var here := _client_world.projectiles()[0].position_at(_tick + 20, TICK_RATE)
		var there := _server_world.projectiles()[0].position_at(_tick + 20, TICK_RATE)
		_check(
			here.distance_to(there) < 2.0,
			"and in the same place twenty ticks on (%.2f apart)" % here.distance_to(there)
		)

	var release := Dot2DCommand.new()
	_steps(120, release)

	_check(
		_server_world.projectiles().is_empty(),
		"the server resolves it"
	)
	_check(
		_client_world.projectiles().is_empty(),
		"and the client stops drawing it"
	)
	_check(
		thrown.has(HungryEvents.Kind.THROW) and thrown.has(HungryEvents.Kind.IMPACT),
		"and both cues arrived"
	)

	# Owner-only: what you are carrying is not something an opponent should be told.
	_check(
		_client_world.monster_for(7).carried.size()
			== _server_world.monster_for(7).carried.size(),
		"and the carry list reached its owner"
	)
	_done()


func _test_interest() -> void:
	_section("interest")

	var interest := _server_net.interest as HungryInterest
	_check(interest != null, "the server uses this game's interest rule")

	if interest == null:
		_done()
		return

	var rect := interest.view_rect(CLIENT_PEER)
	_check(rect.size.x > 0.0, "which knows where the observer is")

	# A monster wide enough to fill the screen has to see further, or it can never find
	# anything worth eating.
	var small := interest.view_rect(CLIENT_PEER).size
	_server_world.monster_for(7).rider_piece().set_mass(
		9000.0, _server_world.tunables.mass_rules
	)
	var large := interest.view_rect(CLIENT_PEER).size

	_check(
		large.x > small.x,
		"and grows with the monster (%.0f -> %.0f)" % [small.x, large.x]
	)

	_server_world.monster_for(7).rider_piece().set_mass(
		HungryContent.START_MASS, _server_world.tunables.mass_rules
	)

	# Somebody on the far side of the world must not be in the snapshot at all. This is
	# the anti-cheat that works: data never sent cannot be drawn on a wallhack.
	_server_bridge.add_player(0, 99, "Far Away")
	_server_world.spawn(99, _server_world.arena.bounds.position + Vector2(60.0, 60.0))
	_server_world.spawn(7, _server_world.arena.bounds.end - Vector2(60.0, 60.0))
	_steps(20)

	var far_identity: DotNetIdentity = null

	for identity in _server_net.registry.all():
		for behaviour in identity.behaviours:
			var piece := behaviour as HungryPieceNet

			if piece != null and piece.piece != null and piece.piece.owner_id == 99:
				far_identity = identity

	_check(far_identity != null, "there is somebody on the far side of the world")

	if far_identity != null:
		_check(
			not interest._is_relevant(
				_server_net._observer_for(CLIENT_PEER), far_identity, {}
			),
			"and they are not relevant to a player at the other end"
		)
	_done()


func _test_avatar() -> void:
	_section("avatars")

	var schema := _client_bridge.avatar_schema
	_check(schema != null and schema.validate_schema().ok, "the rider schema is legal")

	var mine := DotAvatar.make(schema.id)
	mine.set_part(&"body", &"rider_blob")
	mine.set_part(&"hat", &"hat_cap")
	mine.set_colour(&"body", 0, Color(0.9, 0.2, 0.3))

	_client_bridge.publish_avatar(mine)
	_flush()
	_flush()

	var stored := _server_world.monster_for(7).avatar
	_check(
		stored != null and stored.part_in(&"body") == &"rider_blob",
		"a client's avatar reaches the server"
	)
	_check(
		stored != null and stored.digest() == mine.digest(),
		"unchanged",
		"%s vs %s" % [stored.digest() if stored != null else "-", mine.digest()]
	)

	# The server validates against the schema and loads nothing to do it. A part that is
	# not in the schema is refused rather than clamped to whatever is at the boundary.
	var forged := DotAvatar.make(schema.id)
	forged.set_part(&"body", &"rider_pip")
	forged.parts[&"cheat"] = &"nonexistent"

	var refused := schema.validate(forged, DotAvatarEntitlements.everything())
	_check(not refused.ok, "and a slot the schema does not have is refused")
	_done()


## A monster somebody else is steering has to move smoothly.
##
## [b]The interpolated value has to reach the simulation, not just the property.[/b]
## Snapshots arrive 20 times a second; frames render far more often. dot-net computes the
## smoothed position every frame and writes it into `net_position` — and if the only thing
## that copies `net_position` into the piece is the snapshot handler, every remote monster
## moves in 50 ms steps while the smooth value sits in a property nothing reads. It looks
## exactly like an interpolator that does not work.
func _test_interpolation() -> void:
	_section("watching somebody else move")

	# A player with no peer: a bot, from the client's point of view an entity it does not
	# own and therefore does not predict — which is the only kind interpolation applies to.
	_server_bridge.add_player(0, 42, "Someone Else")

	# Both near the middle, with room to move. An earlier section parked the client's
	# monster against a wall, and a monster pushed into a wall does not move — which
	# produces a track of identical samples and an interpolation check that passes for
	# the wrong reason.
	_server_world.spawn(7, Vector2.ZERO)
	_server_world.spawn(42, Vector2(220.0, 0.0))

	var drift := Dot2DCommand.new()
	drift.aim = Vector2.RIGHT
	drift.reach = 900.0

	for _i in range(40):
		_server_bridge.note_command(42, drift)
		_step()

	var mirrored := _client_world.monster_for(42)

	if not _check(
		mirrored != null and mirrored.piece_count() > 0,
		"the client mirrors a monster it does not own"
	):
		_done()
		return

	var behaviour: HungryPieceNet = mirrored.pieces[0].net

	_check(
		behaviour != null and behaviour.identity != null
			and not behaviour.identity.is_predicted(),
		"and does not predict it"
	)

	# The value the last snapshot carried, before any interpolation runs.
	var snapshotted := behaviour.net_position

	_client_net.interpolate_frame()
	var first := mirrored.pieces[0].position()

	# [b]Behind the snapshot, not equal to it.[/b] Rendering happens in the past by one
	# buffer length so that both bracketing samples have arrived, so an interpolated
	# position that exactly equalled the newest snapshot would mean nothing had
	# interpolated at all — which is what a value written only by the snapshot handler
	# looks like.
	_check(
		first != snapshotted,
		"interpolation renders behind the newest snapshot (%.2f units)"
			% first.distance_to(snapshotted)
	)
	_check(
		first.distance_to(behaviour.net_position) < 0.01,
		"and reaches the piece, not just the property (%.3f apart)"
			% first.distance_to(behaviour.net_position)
	)

	# Advance the client's own clock without delivering anything, and the drawn position
	# has to keep moving. This is the whole difference between rendering at the snapshot
	# rate and rendering at the frame rate: `render_tick` is derived from the client's
	# estimate of the server tick, and an estimate that only moved when a packet arrived
	# would give the same answer on every frame in between.
	for _i in range(6):
		_client_net.clock.advance(1.0 / float(TICK_RATE))

	_client_net.interpolate_frame()
	var second := mirrored.pieces[0].position()

	_check(
		second != first,
		"and keeps moving between snapshots (%.2f units)" % second.distance_to(first)
	)
	_check(
		second.distance_to(first) < 60.0,
		"by a plausible amount rather than extrapolating away (%.2f)"
			% second.distance_to(first)
	)

	_server_bridge.remove_peer(0)
	_server_world.remove_player(42)
	_flush()
	_done()


func _test_loadout() -> void:
	_section("loadouts")

	var schema := _server_bridge.loadout_schema
	_check(schema != null and schema.validate().ok, "both ends hold the same schema")

	var mine := DotLoadout.empty(schema.id)
	mine.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_LURE)
	mine.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_STURDY)

	_client_bridge.publish_loadout(mine)
	_flush()
	_flush()

	var server_monster := _server_world.monster_for(7)
	_check(
		server_monster.trait_id == HungryContent.TRAIT_STURDY,
		"a published loadout reaches the server (%s)" % server_monster.trait_id
	)
	_check(
		server_monster.starter_item() == HungryContent.ITEM_LURE,
		"with both slots (%s)" % server_monster.starter_item()
	)

	# It comes back in the join, because the trait changes how fast a monster moves and
	# the owning client predicts that movement. Two ends computing speed from different
	# loadouts is a permanent mispredict, not a rounding error.
	var client_monster := _client_world.monster_for(7)
	_check(
		client_monster.trait_id == HungryContent.TRAIT_STURDY,
		"and comes back to every client (%s)" % client_monster.trait_id
	)
	_check(
		is_equal_approx(
			client_monster.speed_multiplier(), server_monster.speed_multiplier()
		),
		"so both ends agree how fast they move (%.3f vs %.3f)" % [
			client_monster.speed_multiplier(), server_monster.speed_multiplier()
		]
	)

	# And the trade is real, on the next spawn rather than immediately: a player who could
	# change their trait mid-fight would change it the moment they were losing.
	_server_world.spawn(7)
	_check(
		_server_world.monster_for(7).mass()
			> HungryContent.START_MASS * HungryContent.trait_mass(
				HungryContent.TRAIT_NIMBLE
			),
		"and sturdy spawns bigger (%.1f)" % _server_world.monster_for(7).mass()
	)
	_check(
		_server_world.monster_for(7).carried.has(HungryContent.ITEM_LURE),
		"holding what they asked for"
	)

	# Nobody owns the greedy trait, so the server must refuse it — a client that could
	# make the server repair its way to a legal loadout can put anything in any slot.
	var cheating := DotLoadout.empty(schema.id)
	cheating.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_PEPPER)
	cheating.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_GREEDY)

	_client_bridge.publish_loadout(cheating)
	_flush()
	_flush()

	_check(
		_server_world.monster_for(7).trait_id == HungryContent.TRAIT_STURDY,
		"an unowned trait is refused rather than repaired (%s)"
			% _server_world.monster_for(7).trait_id
	)

	# A trait in the throwable slot is a different refusal for a different reason, and a
	# loadout screen shows them differently.
	var muddled := DotLoadout.empty(schema.id)
	muddled.set_item(HungryContent.SLOT_STARTER, HungryContent.TRAIT_NIMBLE)
	muddled.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_NIMBLE)

	_client_bridge.publish_loadout(muddled)
	_flush()
	_flush()

	_check(
		_server_world.monster_for(7).starter_item() == HungryContent.ITEM_LURE,
		"and so is an item in the wrong slot"
	)
	_done()


func _test_direction_enforced() -> void:
	_section("direction")

	# Without this any client could send every other client a spawn, a death or a
	# leaderboard. It is checked against the transport's view of the sender, never
	# against a peer id inside the payload.
	var writer := DotNetWriter.new()
	var event := HungryEvent.of(HungryEvents.Kind.DIED, HungryEvents.write_pair(7, 7))
	_server_net.messages.encode(event, writer)

	var before := _server_net.stats.direction_violations
	var refused := _server_net.receive(writer.to_bytes(), CLIENT_PEER)

	_check(not refused.ok, "a client may not send a server-to-client event")
	_check(
		_server_net.stats.direction_violations > before,
		"and it is counted as a violation"
	)
	_done()


func _test_loss() -> void:
	_section("packet loss")

	_server_world.spawn(7, Vector2.ZERO)
	_steps(10)

	# One snapshot in four on the floor. Position recovers on its own — a newer one
	# supersedes it — but anything that changes rarely would be stranded at a stale value
	# for ever without the acknowledgements the input packets carry.
	_drop_every = 4

	var command := Dot2DCommand.new()
	command.aim = Vector2(0.7, 0.7).normalized()
	command.reach = 900.0

	_steps(150, command)
	_drop_every = 0

	# Stopped, and standing on bare ground. Mass is authoritative and interpolated, so a
	# monster that is still eating is a monster whose two copies are always one crumb
	# apart — which says nothing about whether the loss was recovered from. Clearing the
	# ground under it is what makes the comparison mean "the value converged" rather than
	# "the value is moving".
	var head := _server_world.monster_for(7).rider_piece()

	for grid_id in _server_world.arena.grid.query_circle(
		head.position(), head.radius() * 6.0
	):
		if HungryField.is_edible(grid_id) and _server_world.field.take(grid_id):
			_server_world.arena.grid.remove(grid_id)

	_steps(40, Dot2DCommand.new())

	var apart := _client_world.monster_for(7).centre().distance_to(
		_server_world.monster_for(7).centre()
	)

	_check(
		_client_net.stats.snapshots_lost > 0,
		"loss was detected (%d snapshots)" % _client_net.stats.snapshots_lost
	)

	# Recovery above depends entirely on the ack header the input packets carry, and
	# the server degrades to a conservative view rather than failing when it never
	# arrives — so a bridge whose ACK_BYTES and encode_ack() disagree would still get
	# most of this section right. Ask the server whether the wiring took.
	_check(
		_server_net.peer_acks_wired(CLIENT_PEER),
		"because the client's acknowledgements are reaching the server",
		"without them the server keeps the conservative view and never re-sends"
	)
	_check(
		apart < 12.0,
		"and the client still tracks the server (%.2f units apart)" % apart
	)
	_check(
		_client_net.stats.decode_failures == 0,
		"with no decode failures"
	)

	var server_mass := _server_world.monster_for(7).mass()
	var client_mass := _client_world.monster_for(7).mass()

	_check(
		absf(server_mass - client_mass) < 1.0,
		"and the mass converged exactly once it stopped (%.1f vs %.1f)"
			% [server_mass, client_mass]
	)
	_done()


func _test_game_change() -> void:
	_section("changing the game underneath them")

	var before_pieces := _client_bridge.piece_count()
	_check(before_pieces > 0, "there is something to lose (%d pieces)" % before_pieces)

	var next := HungryWorld.new()
	next.name = "NextWorld"
	next.preset = HungryPreset.frenzy()
	next.tick_rate = TICK_RATE
	next.world_seed = SEED + 1
	next.is_authority = true
	next.register_service = false
	add_child(next)
	next.setup()
	next.start(_tick)

	var rebound := _server_bridge.rebind(next)
	_check(rebound.ok, "the bridge rebinds onto a new world", str(rebound.error))

	_flush()
	_steps(30)

	_check(
		_server_bridge.player_for_peer(CLIENT_PEER) == 7,
		"the peer is still here"
	)
	_check(
		next.monster_for(7) != null and next.monster_for(7).alive,
		"and has a monster in the new world"
	)
	_check(
		_client_world.field.seed_value() == next.field.seed_value(),
		"the client took the new field seed"
	)
	_check(
		absi(_client_world.field.alive_count() - next.field.alive_count()) <= 30,
		"and the new field (%d vs %d)" % [
			_client_world.field.alive_count(), next.field.alive_count()
		]
	)
	_check(
		_client_bridge.piece_count() == _server_bridge.piece_count(),
		"and the same pieces (%d vs %d)" % [
			_client_bridge.piece_count(), _server_bridge.piece_count()
		]
	)

	# The match entity survives a change on purpose: its net id is already known to every
	# client, and re-spawning it would make each of them mirror a second one.
	_check(
		_client_bridge.match_behaviour() != null,
		"and the match entity was not duplicated"
	)

	remove_child(next)
	next.queue_free()
	_done()
