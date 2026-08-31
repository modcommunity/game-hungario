class_name HungryNetBridge
extends Node

## Joins a [HungryWorld] to a [DotNetManager]. The netcode seam, and the only file in
## this project that names both.
##
## [b]Every other join here is a few lines because the addons refuse to know about each
## other; this one is a file because the ordering is the hard part.[/b] dot-net drives
## simulation per entity, and this game's tick order is a whole-world property —
## everybody moves, then eating is resolved against the world as it is afterwards, then
## merges, then projectiles, then the match. Reconciling those two facts is what
## [method ensure_world_ticked] is.
##
## [codeblock]
## # server
## bridge.attach(world, net, server)          # `server` is the node the link mirrors
## bridge.add_player(peer_id, session_id, "Ada", avatar)
## bridge.server_tick(tick)                   # instead of world.tick()
##
## # client
## bridge.attach(world, net, client_link)
## bridge.ask_for_world()
## bridge.client_tick(tick, command)
## [/codeblock]

const CHANNEL := "hungry.net"

## Bytes [method DotNetManager.encode_ack] produces, and the prefix of every input
## packet. Fixed width, so the command that follows starts at a known offset.
const ACK_BYTES := 4

## Ticks between two leaderboard broadcasts. Twice a second: it is a list of numbers that
## change slowly and nobody reads it at 20 Hz.
const BOARD_INTERVAL_TICKS := 30

## The client has been told who it is and what the world is.
signal hello_received(player_id: int)

## A player joined or left, or their avatar changed.
signal roster_changed(player_id: int)

## Something worth a line in the feed or a noise. [param kind] is a
## [enum HungryEvents.Kind].
signal cue(kind: int, data: Dictionary)

var world: HungryWorld = null
var net: DotNetManager = null
var link: HungryNetLink = null

## The schema both ends dress a rider from. Content, delivered like the meshes are.
var avatar_schema: DotAvatarSchema = null

## What a player may bring in. The same schema on both ends, and the whole of what a
## server checks a loadout against.
var loadout_schema: DotLoadoutSchema = null

## `func(player_id: int, loadout: DotLoadout) -> DotResult`. Where a published loadout
## goes. Server side.
##
## A [Callable] rather than a [DotLoadoutManager] reference, because a manager needs a
## store and a store is a deployment decision — a LAN server keeps loadouts in memory, a
## community server puts them behind its own service, and this file has no business
## knowing which. Unset, a published loadout is validated against the schema and applied
## for the session without being saved anywhere, which is what a server with no store
## should do.
var loadout_sink: Callable = Callable()

## What each player is entitled to. Server side.
##
## `func(player_id: int) -> DotLoadoutEntitlements`. Unset, nobody owns anything and only
## items marked free are permitted — which is the safe default and the one that is wrong
## within thirty seconds rather than shipping a game where every unlock is free.
var entitlement_source: Callable = Callable()

## Where this server's cosmetics live, as a manifest URL. Empty for "whatever you
## shipped with", which is every deployment that has not published a pack.
##
## Set on the server by [HungryModule] from a cvar and sent in the hello; set on a client
## from the hello it received. A client with no dot-cloud installed ignores it entirely.
var avatar_pack_url: String = ""

## Which player this process is. Zero on a server.
var local_player_id: int = 0

## The leaderboard as the authority last described it. Client side; rows are
## `{id, mass}`.
var board: Array = []

## Where the replicated entities live. One node, so a scene tree inspector shows the
## netcode's footprint in one place.
var _entities: Node = null

var _match_behaviour: HungryMatchNet = null
var _match_identity: DotNetIdentity = null

## peer id -> player id, and back.
var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}

## Peers that have asked for the world, and can therefore receive it.
##
## [b]Nothing is sent to a peer before it asks.[/b] dot-server's signon finishes and
## [i]then[/i] the client builds its scene, so between those two moments the client has no
## node for an RPC to land on — Godot answers every one of them with "Node not found",
## once per call, and the events themselves are simply lost. Waiting for
## [constant HungryEvents.Ask.READY] is the client saying it has somewhere to put them.
var _ready_peers: Dictionary = {}

## piece id -> [HungryPieceNet].
var _behaviours: Dictionary = {}

## net id -> piece id.
var _piece_of_net: Dictionary = {}

## player id -> the [Dot2DCommand] their last input carried. Server side.
var _commands: Dictionary = {}

var _tick: int = 0
var _world_ticked_for: int = -1
var _client_ticked_for: int = -1
var _board_countdown: int = 0
var _field_dirty: bool = false


# --- Wiring ----------------------------------------------------------------

## Binds a world and a manager to each other and puts the link where RPCs will find it.
##
## [param link_parent] is [DotServer] on a server and [DotClientLink] on a client, and
## both of them are named [code]Server[/code] — see [HungryNetLink] for why that is the
## whole of the routing.
func attach(
	p_world: HungryWorld,
	p_net: DotNetManager,
	link_parent: Node
) -> DotResult:
	if p_world == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_world.is_authority != p_net.is_server:
		# A world that thinks it is authoritative behind a client manager would resolve
		# its own eating; a server whose world is not authoritative would resolve
		# nobody's. Both are silent, and both are unplayable.
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world.is_authority=%s, net.is_server=%s"
				% [p_world.is_authority, p_net.is_server]
		)

	world = p_world
	net = p_net
	avatar_schema = HungryContent.avatar_schema()

	var schema_valid := avatar_schema.validate_schema()

	if not schema_valid.ok:
		return schema_valid.wrap("The rider schema is not usable")

	loadout_schema = HungryContent.loadout_schema()

	var loadout_valid := loadout_schema.validate()

	if not loadout_valid.ok:
		return loadout_valid.wrap("The loadout schema is not usable")

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	var interest := HungryInterest.new()
	interest.bridge = self
	net.interest = interest

	# Snapshots and messages both leave through `send_fn`, and the only thing that
	# distinguishes them there is the delivery: dot-net sends state unreliably and
	# nothing else, and every message this game defines is reliable. Routing on that is
	# exact rather than a heuristic, and it is why neither message type may ever be
	# declared unreliable.
	net.send_fn = _send

	var registered := _register_messages()

	if not registered.ok:
		return registered

	if net.is_server:
		_connect_world()

	link = HungryNetLink.attached_to(link_parent, self, net.is_server)

	if net.is_server:
		var built := _build_match_entity()

		if not built.ok:
			return built

	return DotResult.success(self)


## Moves this bridge onto a new world, keeping every connection. Server side.
##
## [b]What a game change is, from the netcode's point of view.[/b] The world is a scene
## that [DotGameManager] frees and replaces; the manager, its peers, its message ids and
## its clock are not, because rebuilding those would disconnect everybody — which is
## precisely what changing the map is supposed to avoid.
##
## So every replicated piece is despawned, the new world is populated with the same
## players, and everyone is resynchronised. The [i]match entity survives[/i]: its net id is
## already known to every client and re-spawning it would make each of them mirror a
## second one.
func rebind(new_world: HungryWorld) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server rebinds.")

	if new_world == null or not new_world.is_authority:
		return DotResult.fail(
			DotError.CODE_INVALID, "A bridge rebinds onto an authoritative world."
		)

	# Who is here, before the old world goes. The peer map survives a game change; the
	# monsters do not, and their names and avatars are the only thing in them worth
	# carrying across.
	var carried: Array[Dictionary] = []

	for peer_key in _player_of_peer.keys():
		var peer_id := int(peer_key)
		var player_id := int(_player_of_peer[peer_key])
		var monster := world.monster_for(player_id) if world != null else null

		carried.append({
			"peer": peer_id,
			"player": player_id,
			"name": monster.display_name if monster != null else "Player %d" % player_id,
			"avatar": monster.avatar if monster != null else null,
		})

	for piece_id in _behaviours.keys():
		_release_piece_entity(int(piece_id), true)

	_behaviours.clear()
	_commands.clear()

	if world != null:
		_disconnect_world()

	world = new_world
	_connect_world()

	if _match_behaviour != null:
		_match_behaviour.world = world

	for row in carried:
		var added := world.add_player(int(row["player"]), String(row["name"]))

		if not added.ok:
			continue

		var monster: HungryMonster = added.value
		var avatar: Variant = row["avatar"]

		if avatar is DotAvatar:
			monster.avatar = avatar

		var peer_id := int(row["peer"])

		if _ready_peers.has(peer_id):
			_send_hello(peer_id, int(row["player"]))
			_send_roster(peer_id)
			_send_full_field(peer_id)

		world.spawn(int(row["player"]))

	_world_ticked_for = -1
	return DotResult.success(world)


func _connect_world() -> void:
	world.piece_created.connect(_on_piece_created)
	world.piece_destroyed.connect(_on_piece_destroyed)
	world.field_changed.connect(_on_field_changed)
	world.projectile_thrown.connect(_on_projectile_thrown)
	world.projectile_impact.connect(_on_projectile_impact)
	world.monster_burst.connect(_on_monster_burst)
	world.player_died.connect(_on_player_died)
	world.item_taken.connect(_on_item_taken)
	world.match_state_changed.connect(_on_match_state_changed)


func _disconnect_world() -> void:
	for pair in [
		[world.piece_created, _on_piece_created],
		[world.piece_destroyed, _on_piece_destroyed],
		[world.field_changed, _on_field_changed],
		[world.projectile_thrown, _on_projectile_thrown],
		[world.projectile_impact, _on_projectile_impact],
		[world.monster_burst, _on_monster_burst],
		[world.player_died, _on_player_died],
		[world.item_taken, _on_item_taken],
		[world.match_state_changed, _on_match_state_changed],
	]:
		var source: Signal = pair[0]
		var handler: Callable = pair[1]

		if source.is_connected(handler):
			source.disconnect(handler)


## Unregisters and frees one piece's entity. Returns its net id, or zero.
func _release_piece_entity(piece_id: int, announce: bool) -> int:
	var behaviour: HungryPieceNet = _behaviours.get(piece_id)

	if behaviour == null or behaviour.identity == null:
		return 0

	var net_id := behaviour.identity.net_id
	_piece_of_net.erase(net_id)

	if announce:
		_broadcast(HungryEvents.Kind.DESPAWN, HungryEvents.write_despawn(net_id))

	net.registry.unregister(net_id)

	var node := behaviour.identity.entity

	if node != null and is_instance_valid(node):
		node.queue_free()

	return net_id


func _register_messages() -> DotResult:
	var event := net.messages.register(
		HungryEvent.NAME,
		HungryEvent,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		HungryRequest.NAME,
		HungryRequest,
		DotNetMessage.Delivery.RELIABLE,
		DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(HungryEvent.NAME, _on_event)
	net.messages.on(HungryRequest.NAME, _on_request)
	return DotResult.success(true)


## The always-relevant entity that carries the match clock.
##
## Also the thing that keeps an empty server ticking: with no players there are no piece
## entities, no behaviour runs, and the warmup of a freshly booted server would never end.
func _build_match_entity() -> DotResult:
	var root := Node2D.new()
	root.name = "Match"
	_entities.add_child(root)

	_match_behaviour = HungryMatchNet.new()
	_match_behaviour.name = "Net"
	_match_behaviour.world = world
	_match_behaviour.bridge = self
	root.add_child(_match_behaviour)

	# After the behaviour: [DotNetIdentity] collects behaviours in `_ready` by walking the
	# entity's subtree, and one added afterwards would never be found — the entity would
	# register with nothing to replicate and simply never update on any other machine.
	_match_identity = DotNetIdentity.new()
	_match_identity.name = "Identity"
	_match_identity.owner_peer_id = net.local_peer_id
	_match_identity.always_relevant = true
	_match_identity.priority = 10.0
	root.add_child(_match_identity)

	return net.registry.register(_match_identity, 0, net.clock.tick, net.config)


## Mirrors the match entity on a client. Called once, from the first HELLO.
func _mirror_match_entity(net_id: int) -> DotResult:
	if _match_identity != null:
		return DotResult.success(_match_identity)

	var root := Node2D.new()
	root.name = "Match"
	_entities.add_child(root)

	_match_behaviour = HungryMatchNet.new()
	_match_behaviour.name = "Net"
	_match_behaviour.world = world
	_match_behaviour.bridge = self
	root.add_child(_match_behaviour)

	_match_identity = DotNetIdentity.new()
	_match_identity.name = "Identity"
	_match_identity.owner_peer_id = 1
	_match_identity.always_relevant = true
	root.add_child(_match_identity)

	return net.registry.register(_match_identity, net_id, net.clock.tick, net.config)


func mass_rules() -> Dot2DMassRules:
	var live := _live_world()
	return live.tunables.mass_rules if live != null and live.tunables != null else null


func match_behaviour() -> HungryMatchNet:
	return _match_behaviour


# --- Transport -------------------------------------------------------------

func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


## Sends an event to everybody who can receive one.
##
## Peer by peer rather than [method DotNetManager.send]'s broadcast, because a broadcast
## goes to every connected peer including the ones that have not built their scene yet —
## and every one of those is a "Node not found" in the log and an event nobody got. The
## cost is encoding the body once per peer, which for a reliable event at this scale is
## nothing next to knowing it arrived.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server:
		return

	for peer_id in _ready_peers.keys():
		net.send(HungryEvent.of(kind, body), int(peer_id))


## Sends an event to one peer.
##
## [b]A peer id of zero means "nobody", not "everybody".[/b] Bots are players with no
## connection and this game gives them peer 0, so a `_tell` that fell through to
## [method DotNetManager.send]'s broadcast would send every bot's private carry list, and
## every bot's hello, to every real client. Broadcasting is [method _broadcast]'s job and
## it says so.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or peer_id <= 0:
		return

	net.send(HungryEvent.of(kind, body), peer_id)


## Marks a peer able to receive, and gives it everything it has missed.
##
## Also where the peer joins the manager: a peer registered before it can receive is a
## peer the server builds and sends a snapshot to every tick, into a node that does not
## exist yet.
func _admit(peer_id: int, player_id: int) -> void:
	if peer_id <= 0:
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	_send_hello(peer_id, player_id)
	_send_roster(peer_id)
	_send_full_field(peer_id)
	send_carry(player_id)


# --- Membership ------------------------------------------------------------

## Adds a player and makes their pieces replicated entities. Server side.
##
## [param session_id] is the id everything downstream uses — the scoreboard key, the
## monster's identity, the colour seed. [b]It is not the peer id.[/b] A peer id is
## reassigned the moment somebody reconnects, and everything keyed by one would be handed
## to the next player to join.
func add_player(
	peer_id: int,
	session_id: int,
	display_name: String,
	avatar: DotAvatar = null
) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var added := world.add_player(session_id, display_name)

	if not added.ok:
		return added

	var monster: HungryMonster = added.value

	if avatar != null:
		monster.avatar = avatar

	# Before anything is registered to it, not after: the manager only builds snapshots
	# for peers it knows about and only holds an input buffer for those, so an entity
	# registered to an unknown peer is one nothing is ever sent about and nothing can
	# drive. It is silent — the server simulates it perfectly and alone.
	#
	# A bot has no connection and arrives with peer 0. Registering that as a peer would
	# give the manager a peer whose snapshots go to the broadcast address, so every real
	# client would receive a second snapshot built against the bot's interest rectangle
	# — a client's own view then arrives interleaved with somebody else's, and the
	# symptom is a monster that jumps between two positions.
	if peer_id > 0:
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	_announce(monster)
	world.spawn(session_id)
	roster_changed.emit(session_id)

	return DotResult.success(monster)


## Drops a peer's player from the world and from replication. Server side.
func remove_peer(peer_id: int) -> void:
	if not _player_of_peer.has(peer_id):
		return

	var session_id := int(_player_of_peer[peer_id])
	var was_ready := _ready_peers.has(peer_id)
	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)
	_commands.erase(session_id)

	# Before the world removes their pieces, so `piece_destroyed` still finds the
	# behaviours and every client is told each entity is gone.
	#
	# [b]Guarded, because the world may already be gone.[/b] A game change frees the scene
	# the world lives in and THEN the module that owned it is unloaded — and unloading is
	# what takes everybody out. So on the way out of hungry this ran against a freed
	# HungryWorld: "Invalid call. Nonexistent function 'remove_player' in base 'previously
	# freed'", and with a real client attached and different timing, a segfault.
	#
	# The rest of the teardown still has to happen: the peer's entities, its input buffer
	# and its acknowledgement record are the netcode's and outlive the scene. Returning
	# early here would leak all three into the next game.
	var live := _live_world()

	if live != null:
		live.remove_player(session_id)

	if net != null:
		if was_ready:
			# Releases the peer's remaining entities, its input buffer and its
			# acknowledgement record in one place, so nothing is left keyed by a peer id
			# the next player to connect will be given.
			net.remove_peer(peer_id)

		net.interest.forget_peer(peer_id)

	_broadcast(HungryEvents.Kind.LEAVE, HungryEvents.write_player(session_id))
	roster_changed.emit(session_id)


## The world, or null when there isn't one any more.
##
## [b]`world == null` is not the check.[/b] A game change frees the scene the world lives
## in, and a freed [Object] is not null — it is a reference that answers `is_instance_valid`
## with false and throws "Nonexistent function ... in base 'previously freed'" on the next
## call. Every read below can run while a change is in flight: interest management asks for
## a monster while building a snapshot, and the module asks for one while being unloaded.
func _live_world() -> HungryWorld:
	return world if world != null and is_instance_valid(world) else null


func monster_for_peer(peer_id: int) -> HungryMonster:
	var live := _live_world()

	if live == null or not _player_of_peer.has(peer_id):
		return null

	return live.monster_for(int(_player_of_peer[peer_id]))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func peer_for_player(player_id: int) -> int:
	return int(_peer_of_player.get(player_id, 0))


func local_monster() -> HungryMonster:
	var live := _live_world()
	return live.monster_for(local_player_id) if live != null else null


# --- Replicated pieces -----------------------------------------------------

func _on_piece_created(piece: HungryPiece) -> void:
	var identity := _build_piece_entity(piece, peer_for_player(piece.owner_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.error(CHANNEL, "could not register a piece", {
			"piece": piece.id, "error": str(registered.error)
		})
		return

	_piece_of_net[identity.net_id] = piece.id

	# Immediately, and reliably. A client that meets an entity it has not been told to
	# spawn abandons the rest of that snapshot — it cannot skip a variable-length body
	# without the declarations — so a spawn that arrived late would cost every other
	# entity in that packet as well.
	_broadcast(
		HungryEvents.Kind.SPAWN,
		HungryEvents.write_spawn(
			identity.net_id,
			identity.owner_peer_id,
			piece.owner_id,
			piece.id,
			piece.position(),
			piece.mass()
		)
	)


func _on_piece_destroyed(piece: HungryPiece) -> void:
	_release_piece_entity(piece.id, true)
	_behaviours.erase(piece.id)


## Builds the node, behaviour and identity that make a piece replicate.
func _build_piece_entity(piece: HungryPiece, peer_id: int) -> DotNetIdentity:
	var root := Node2D.new()
	root.name = "Piece%d" % piece.id
	root.position = piece.position()
	_entities.add_child(root)

	var behaviour := HungryPieceNet.new()
	behaviour.name = "Net"
	behaviour.piece = piece
	behaviour.bridge = self
	root.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED, not SERVER: the server stays authoritative and corrects, and the owning
	# client predicts. `DotNetIdentity.is_predicted()` is false for any other authority,
	# so SERVER would mean a player seeing their own monster a full round trip late —
	# noticeable at 80 ms and unplayable at 150.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.interest_tags = PackedStringArray(["piece"])
	root.add_child(identity)

	piece.net = behaviour
	_behaviours[piece.id] = behaviour

	return identity


func behaviour_for(piece_id: int) -> HungryPieceNet:
	return _behaviours.get(piece_id)


func piece_count() -> int:
	return _behaviours.size()


# --- The authoritative tick ------------------------------------------------

## One authoritative tick. Server side, and it replaces [method HungryWorld.tick].
##
## [method DotNetManager.server_tick] hands each peer's input to the entities it owns,
## simulates every behaviour, records history and sends snapshots — in that order, and
## the world tick has to happen between the first two. It does, from
## [method HungryPieceNet._net_simulate] and [method HungryMatchNet._net_simulate],
## through [method ensure_world_ticked].
##
## The call afterwards is not redundant. It is what covers the tick on which the match
## entity has not yet been registered, and it costs one integer comparison when the
## world has already run.
func server_tick(tick: int) -> void:
	_tick = tick
	_world_ticked_for = -1

	if net != null:
		net.server_tick(tick)

	ensure_world_ticked(tick)
	_flush_field()
	_flush_board(tick)


## Runs the whole world for a tick, at most once.
##
## Called from every replicated behaviour's [code]_net_simulate[/code]; the first one
## through does the work and the rest find it done.
func ensure_world_ticked(tick: int) -> void:
	var live := _live_world()

	if _world_ticked_for == tick or live == null:
		return

	_world_ticked_for = tick
	live.tick(_commands)


## Takes one tick of a player's intent, on its way from an input packet to the world.
##
## Kept per player rather than per piece: a monster's command belongs to the monster, and
## sixteen pieces each holding their own copy of it is fifteen chances for them to
## disagree.
func note_command(player_id: int, command: Dot2DCommand) -> void:
	if command != null:
		_commands[player_id] = command


# --- The client tick -------------------------------------------------------

## One client tick: record the local command, predict, separate.
##
## The command is recorded into the manager's input history [i]before[/i] predicting,
## because reconciliation replays that history — an input the buffer never saw is a tick
## the replay cannot reproduce, and the correction is then measured against a state the
## server never computed.
func client_tick(tick: int, command: Dot2DCommand) -> void:
	if net == null or net.is_server or world == null:
		return

	_tick = tick

	if _client_ticked_for != tick:
		_client_ticked_for = tick
		world.client_tick(tick)

	var monster := local_monster()

	if monster != null and command != null:
		monster.last_command = command.duplicate_command()

	var packet := HungryNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.command = command if command != null else Dot2DCommand.new()

	net.local_inputs().push(packet)

	if link != null:
		# The acknowledgement goes in front because it is fixed width. A bit-packed
		# command is not, so a reader that had to skip it would have to decode it first.
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		packet.write(writer)
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	for identity in net.registry.predicted():
		for behaviour in identity.behaviours:
			behaviour._net_simulate(tick, net.clock.tick_duration())

	world.separate_local(monster, net.clock.tick_duration())


## Advances one predicted piece. Called from [method HungryPieceNet._net_simulate].
func predict_piece(piece: HungryPiece, tick: int, delta: float) -> void:
	if _live_world() == null or piece == null:
		return

	var monster := world.monster_for(piece.owner_id)
	world.simulate_piece(
		piece,
		monster,
		monster.last_command if monster != null else null,
		delta,
		tick
	)


# --- Receiving -------------------------------------------------------------

## Applies a snapshot. Client side.
##
## [b]Reconciliation is [DotNetManager]'s, not this file's.[/b]
## [method DotNetManager.receive_snapshot] already routes a predicted entity's state to
## [method DotNetPredictor.reconcile] instead of applying it — applying it directly would
## undo everything predicted since — and acknowledges the inputs it covers. A second pass
## here would reconcile against values that had already been reconciled and replay the
## same inputs twice, turning one correction into two.
func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	return net.receive_snapshot(payload)


## Takes one input packet. Server side.
##
## The acknowledgement is applied even when the command is refused: they are independent
## claims, and a duplicate or late input says nothing about which snapshots arrived.
func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	var packet := HungryNetCommand.new()
	packet.read(DotNetReader.new(payload.slice(ACK_BYTES)))

	return net.input_buffer_for(peer_id).push(packet)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


# --- Events, outbound ------------------------------------------------------

func _send_hello(peer_id: int, player_id: int) -> void:
	_tell(
		peer_id,
		HungryEvents.Kind.HELLO,
		HungryEvents.write_hello(
			world.field.seed_value(),
			world.tick_rate,
			player_id,
			peer_id,
			net.clock.tick,
			world.world_size,
			avatar_pack_url
		)
	)

	# The match entity's id travels in its own spawn, so a joining client can mirror it
	# before the first snapshot mentions it.
	if _match_identity != null:
		_tell(
			peer_id,
			HungryEvents.Kind.SPAWN,
			HungryEvents.write_spawn(
				_match_identity.net_id, 1, 0, 0, Vector2.ZERO, 0.0
			)
		)


## Everybody already here, and every piece already in the world.
func _send_roster(peer_id: int) -> void:
	for monster in world.monsters():
		_tell(peer_id, HungryEvents.Kind.JOIN, _join_body(monster))

	for piece in world.pieces():
		var behaviour: HungryPieceNet = _behaviours.get(piece.id)

		if behaviour == null or behaviour.identity == null:
			continue

		_tell(
			peer_id,
			HungryEvents.Kind.SPAWN,
			HungryEvents.write_spawn(
				behaviour.identity.net_id,
				behaviour.identity.owner_peer_id,
				piece.owner_id,
				piece.id,
				piece.position(),
				piece.mass()
			)
		)


## The whole field, in chunks.
##
## [b]Chunked, and that is not premature.[/b] A full field is eleven hundred food slots
## plus fruit and drops, and one reliable packet of that size fragments on a UDP transport
## and blocks the head of the line on a WebSocket one — which is the transport a browser
## client is on, always.
func _send_full_field(peer_id: int) -> void:
	_tell(
		peer_id,
		HungryEvents.Kind.FIELD_RESET,
		HungryEvents.write_field_reset(world.field.seed_value())
	)

	var alive := world.field.alive_ids()
	var index := 0

	while index < alive.size():
		var chunk := alive.slice(index, index + HungryEvents.FIELD_CHUNK)
		index += HungryEvents.FIELD_CHUNK

		_tell(
			peer_id,
			HungryEvents.Kind.FIELD,
			HungryEvents.write_field(chunk, [], world.field.planted_rows(chunk))
		)


## One player, as everybody else needs to know them.
func _join_body(monster: HungryMonster) -> PackedByteArray:
	return HungryEvents.write_join(
		monster.id,
		peer_for_player(monster.id),
		monster.display_name,
		monster.avatar,
		avatar_schema,
		monster.loadout
	)


## Tells everybody about a player whose name, avatar or loadout has changed.
func _announce(monster: HungryMonster) -> void:
	if monster != null:
		_broadcast(HungryEvents.Kind.JOIN, _join_body(monster))


func _on_field_changed() -> void:
	_field_dirty = true


## Sends a tick's worth of field change, once, after the world has run.
func _flush_field() -> void:
	if not _field_dirty:
		return

	_field_dirty = false

	if not world.field.has_delta():
		return

	var delta := world.field.drain_delta()
	var added: Array = delta["added"]
	var removed: Array = delta["removed"]
	var planted := world.field.planted_rows(added)

	var index := 0

	while index < added.size() or index == 0:
		var chunk: Array = added.slice(index, index + HungryEvents.FIELD_CHUNK)
		var gone: Array = removed if index == 0 else []
		index += HungryEvents.FIELD_CHUNK

		_broadcast(
			HungryEvents.Kind.FIELD, HungryEvents.write_field(chunk, gone, planted)
		)

		if index >= added.size():
			break


func _flush_board(tick: int) -> void:
	_board_countdown -= 1

	if _board_countdown > 0:
		return

	_board_countdown = BOARD_INTERVAL_TICKS
	_tick = tick

	var rows: Array = []

	for monster in world.leaderboard(10):
		rows.append({"id": monster.id, "mass": int(monster.mass())})

	_broadcast(HungryEvents.Kind.BOARD, HungryEvents.write_board(rows))


func _on_projectile_thrown(shot: HungryProjectile) -> void:
	_broadcast(HungryEvents.Kind.THROW, HungryEvents.write_throw(shot))
	send_carry(shot.thrower_id)


func _on_projectile_impact(
	shot: HungryProjectile,
	at: Vector2,
	hit_player: int
) -> void:
	_broadcast(
		HungryEvents.Kind.IMPACT, HungryEvents.write_impact(shot.id, at, hit_player)
	)


func _on_monster_burst(player_id: int, by_player: int, count: int) -> void:
	_broadcast(
		HungryEvents.Kind.BURST, HungryEvents.write_pair(player_id, by_player, count)
	)


func _on_player_died(player_id: int, killer_id: int) -> void:
	_broadcast(
		HungryEvents.Kind.DIED, HungryEvents.write_pair(player_id, killer_id)
	)


## What a player is carrying, sent only to that player.
##
## Owner-only because it is information an opponent should not have: knowing that the
## monster bearing down on you is out of peppers is worth a great deal, and data never
## sent cannot be read out of a modified client.
func _on_item_taken(player_id: int, _grid_id: int, _item: StringName) -> void:
	send_carry(player_id)


func send_carry(player_id: int) -> void:
	var monster := world.monster_for(player_id)
	var peer_id := peer_for_player(player_id)

	if monster == null or peer_id == 0:
		return

	_tell(peer_id, HungryEvents.Kind.CARRY, HungryEvents.write_carry(monster.carried))


func _on_match_state_changed(_from: DotMatch.State, to: DotMatch.State) -> void:
	if to != DotMatch.State.LIVE:
		return

	# A new round has replaced the field wholesale. Nobody can derive that from a delta,
	# so everybody is resynchronised.
	for peer_id in _ready_peers.keys():
		_send_full_field(int(peer_id))

	# And the delta the reset produced is superseded by what was just sent. Left pending
	# it would go out again a tick later as a second copy of the same field, which costs
	# a few kilobytes to every client and tells them nothing.
	world.field.drain_delta()
	_field_dirty = false


# --- Events, inbound -------------------------------------------------------

func _on_event(message: DotNetMessage) -> void:
	var event := message as HungryEvent

	if event == null or world == null:
		return

	var reader := event.reader()

	match event.kind:
		HungryEvents.Kind.HELLO:
			_apply_hello(reader)

		HungryEvents.Kind.JOIN:
			_apply_join(reader)

		HungryEvents.Kind.LEAVE:
			var player_id := HungryEvents.read_player(reader)
			world.remove_player(player_id)
			roster_changed.emit(player_id)

		HungryEvents.Kind.SPAWN:
			_apply_spawn(reader)

		HungryEvents.Kind.DESPAWN:
			_apply_despawn(reader)

		HungryEvents.Kind.FIELD:
			var delta := HungryEvents.read_field(reader)
			if bool(delta["ok"]):
				world.apply_field_delta(
					delta["added"], delta["removed"], delta["planted"]
				)

		HungryEvents.Kind.FIELD_RESET:
			world.adopt_field_seed(reader.read_varint())

		HungryEvents.Kind.THROW:
			_apply_throw(reader)

		HungryEvents.Kind.IMPACT:
			_apply_impact(reader)

		HungryEvents.Kind.BURST, HungryEvents.Kind.DIED:
			var pair := HungryEvents.read_pair(reader)
			if bool(pair["ok"]):
				cue.emit(event.kind, pair)

		HungryEvents.Kind.BOARD:
			board = HungryEvents.read_board(reader)
			cue.emit(event.kind, {"rows": board})

		HungryEvents.Kind.CARRY:
			var monster := local_monster()
			var carried := HungryEvents.read_carry(reader)
			if monster != null:
				monster.carried.clear()
				for item in carried:
					monster.carried.append(item)
			cue.emit(event.kind, {"carried": carried})


func _apply_hello(reader: DotNetReader) -> void:
	var hello := HungryEvents.read_hello(reader)

	if not bool(hello["ok"]):
		DotLog.warn(CHANNEL, "a truncated hello")
		return

	local_player_id = int(hello["player_id"])
	avatar_pack_url = String(hello["pack_url"])
	world.tick_rate = int(hello["tick_rate"])
	world.set_tick(int(hello["tick"]))
	# Size before seed. The field is hashed into the arena rectangle, so a seed adopted
	# against the wrong one lays every crumb out somewhere else.
	world.adopt_world_size(hello["world_size"])
	world.adopt_field_seed(int(hello["seed"]))

	hello_received.emit(local_player_id)


func _apply_join(reader: DotNetReader) -> void:
	var join := HungryEvents.read_join(reader, avatar_schema)

	if not bool(join["ok"]):
		return

	var player_id := int(join["player_id"])
	var monster := _ensure_monster(player_id, String(join["name"]))

	if monster == null:
		return

	monster.display_name = String(join["name"])

	var avatar: Variant = join["avatar"]

	if avatar is DotAvatar:
		monster.avatar = avatar

	var carried: Variant = join["loadout"]

	if carried is DotLoadout:
		# Adopted without validating: this came from the authority, which validated it,
		# and a client that second-guessed it would disagree with the server about how
		# fast its own monster moves.
		monster.wear_loadout(carried)

	roster_changed.emit(player_id)


func _apply_spawn(reader: DotNetReader) -> void:
	var spawn := HungryEvents.read_spawn(reader)

	if not bool(spawn["ok"]):
		return

	var net_id := int(spawn["net_id"])

	if net.registry.has(net_id):
		return

	# A piece id of zero is the match entity, which has no piece and no owner.
	if int(spawn["piece_id"]) == 0:
		_mirror_match_entity(net_id)
		return

	var monster := _ensure_monster(int(spawn["owner_id"]), "")

	if monster == null:
		return

	var piece := world.attach_piece(
		monster, spawn["position"], float(spawn["mass"]), int(spawn["piece_id"])
	)

	var identity := _build_piece_entity(piece, int(spawn["peer_id"]))
	var registered := net.registry.register(
		identity, net_id, net.clock.tick, net.config
	)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a piece", {
			"net_id": net_id, "error": str(registered.error)
		})
		world.forget_piece(piece.id)
		return

	_piece_of_net[net_id] = piece.id


func _apply_despawn(reader: DotNetReader) -> void:
	var net_id := reader.read_varint()

	if not reader.ok() or not _piece_of_net.has(net_id):
		return

	var piece_id := int(_piece_of_net[net_id])
	_piece_of_net.erase(net_id)

	var behaviour: HungryPieceNet = _behaviours.get(piece_id)
	_behaviours.erase(piece_id)

	net.registry.unregister(net_id)

	if behaviour != null and behaviour.identity != null:
		var node := behaviour.identity.entity

		if node != null and is_instance_valid(node):
			node.queue_free()

	world.forget_piece(piece_id)


func _apply_throw(reader: DotNetReader) -> void:
	var row := HungryEvents.read_throw(reader)

	if not bool(row["ok"]):
		return

	var shot := HungryProjectile.make(
		int(row["id"]),
		int(row["thrower"]),
		HungryContent.ITEM_IDS[int(row["item_index"])],
		row["origin"],
		row["direction"],
		int(row["tick"])
	)

	world.adopt_projectile(shot)
	cue.emit(HungryEvents.Kind.THROW, {"shot": shot})


func _apply_impact(reader: DotNetReader) -> void:
	var row := HungryEvents.read_impact(reader)

	if not bool(row["ok"]):
		return

	world.drop_projectile(int(row["id"]))
	cue.emit(HungryEvents.Kind.IMPACT, row)


## A monster a client has been told about but does not have yet.
##
## Joins and spawns are independent messages on a reliable channel, and the ordering
## between "this player exists" and "this piece belongs to them" is guaranteed here but
## would not be after a reconnect or a mid-round join. Creating a placeholder is cheaper
## than dropping the piece: the next JOIN fills the name and the avatar in.
func _ensure_monster(player_id: int, display_name: String) -> HungryMonster:
	if player_id <= 0:
		return null

	var monster := world.monster_for(player_id)

	if monster != null:
		return monster

	var added := world.add_player(
		player_id, display_name if display_name != "" else "Player %d" % player_id
	)

	return added.value if added.ok else null


# --- Requests --------------------------------------------------------------

## Tells the authority this client has loaded and wants the world. Client side.
func ask_for_world() -> void:
	if net == null or net.is_server:
		return

	net.send(HungryRequest.of(HungryEvents.Ask.READY, PackedByteArray()), 0)


## Publishes this client's chosen loadout. Client side.
##
## It takes effect on the next spawn rather than immediately, which is dot-loadout's own
## rule and the right one: a player who could change their trait mid-fight would change it
## the moment they were losing.
func publish_loadout(loadout: DotLoadout) -> void:
	if net == null or net.is_server or loadout == null:
		return

	net.send(
		HungryRequest.of(
			HungryEvents.Ask.LOADOUT, HungryEvents.write_loadout(loadout)
		),
		0
	)


## Publishes this client's avatar. Client side.
func publish_avatar(avatar: DotAvatar) -> void:
	if net == null or net.is_server or avatar == null:
		return

	net.send(
		HungryRequest.of(
			HungryEvents.Ask.AVATAR,
			HungryEvents.write_avatar(avatar, avatar_schema)
		),
		0
	)


func _on_request(message: DotNetMessage) -> void:
	var ask := message as HungryRequest

	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id

	if not _player_of_peer.has(peer_id):
		return

	var player_id := int(_player_of_peer[peer_id])

	match ask.kind:
		HungryEvents.Ask.READY:
			_admit(peer_id, player_id)

		HungryEvents.Ask.AVATAR:
			_apply_avatar(player_id, ask.reader())

		HungryEvents.Ask.LOADOUT:
			# Not awaited, and it suspends: the store write is the suspension, and
			# everything after it — applying the loadout and telling everybody — resumes
			# when the write returns. Nothing in this handler depends on it having
			# finished, which is the only reason dropping the await here is safe.
			_apply_loadout(player_id, ask.reader())


## Takes a client's avatar, through the schema.
##
## [b]The schema is the whole check, and it loads nothing.[/b] Every index is validated
## against the slot and part tables on the way in, so a document naming a part that does
## not exist is refused rather than clamped to whatever sits at the boundary — and a
## dedicated server holding none of the art can still say no.
func _apply_avatar(player_id: int, reader: DotNetReader) -> void:
	var monster := world.monster_for(player_id)

	if monster == null:
		return

	var decoded := HungryEvents.read_avatar(reader, avatar_schema)

	if not decoded.ok:
		DotLog.info(CHANNEL, "refused an avatar", {
			"player": player_id, "error": str(decoded.error)
		})
		return

	var avatar: DotAvatar = decoded.value
	var conformed := avatar_schema.conform(avatar, DotAvatarEntitlements.everything())

	if not conformed.ok:
		return

	monster.avatar = avatar

	_announce(monster)
	roster_changed.emit(player_id)


## Takes a client's loadout, through the schema.
##
## [b]Validated, never conformed.[/b] Conforming is right on the way out of a store, where
## the alternative is a player who cannot spawn. It is wrong here: a client that can make
## the server repair its way to a legal loadout can put anything in any slot and have the
## server pick the nearest legal thing for it, which is a different feature from the one
## being offered.
##
## Suspends on the store write. See the caller.
func _apply_loadout(player_id: int, reader: DotNetReader) -> void:
	var monster := world.monster_for(player_id)

	if monster == null:
		return

	var decoded := HungryEvents.read_loadout(reader)

	if not decoded.ok:
		DotLog.info(CHANNEL, "refused a malformed loadout", {
			"player": player_id, "error": str(decoded.error)
		})
		return

	var loadout: DotLoadout = decoded.value
	var owns := _entitlements_for(player_id)
	var valid := DotLoadoutValidator.validate(loadout, loadout_schema, owns)

	if not valid.ok:
		DotLog.info(CHANNEL, "refused a loadout", {
			"player": player_id, "error": str(valid.error)
		})
		return

	# The store, if there is one. A refused write must not leave the session wearing
	# something the store does not have: a player who sees their change, plays with it and
	# loses it at the next load with no explanation is worse than a refusal.
	if loadout_sink.is_valid():
		# Awaited, because a store may be slow. The sink is a Callable, so nothing here
		# knows statically whether it suspends — and a sink that writes to a database and
		# was called without `await` would have its result read before it had one.
		var stored: Variant = await loadout_sink.call(player_id, loadout)

		if stored is DotResult and not (stored as DotResult).ok:
			DotLog.info(CHANNEL, "a loadout was refused by the store", {
				"player": player_id, "error": str((stored as DotResult).error)
			})
			return

	monster.wear_loadout(loadout)
	_announce(monster)
	roster_changed.emit(player_id)


func _entitlements_for(player_id: int) -> DotLoadoutEntitlements:
	if not entitlement_source.is_valid():
		return DotLoadoutEntitlements.none()

	var owned: Variant = entitlement_source.call(player_id)

	return owned as DotLoadoutEntitlements if owned is DotLoadoutEntitlements \
		else DotLoadoutEntitlements.none()


func describe() -> Dictionary:
	return {
		"server": net.is_server if net != null else false,
		"local_player": local_player_id,
		"peers": _player_of_peer.size(),
		"ready": _ready_peers.size(),
		"pieces": _behaviours.size(),
		"tick": _tick,
		"ticked_for": _world_ticked_for,
		"link": link.describe() if link != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("net      %s, %d peers (%d ready), %d replicated pieces" % [
		"server" if net != null and net.is_server else "client",
		_player_of_peer.size(),
		_ready_peers.size(),
		_behaviours.size(),
	])

	if net != null:
		out.append_array(net.describe_lines())

	return out
