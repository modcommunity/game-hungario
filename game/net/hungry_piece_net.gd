class_name HungryPieceNet
extends DotNetBehaviour

## The thirty lines [Dot2DNetSync] says belong in the game.
##
## [b]dot-2d may not name a dot-net class.[/b] A script that so much as mentions a
## missing [code]class_name[/code] fails to parse and takes every script that references
## it down with it, so dot-2d has to compile with dot-core alone. What it ships instead is
## a description of what to replicate as [i]data[/i] — property names, and type names as
## strings. Resolving those strings against [enum DotNetVar.Type] is this file's job.
##
## One behaviour per piece, and one entity per piece. A monster is a set, and the set is
## what makes interest management work here at all: a player's pieces can be a screen
## apart after a burst, and an entity per player would have to be relevant everywhere any
## of its pieces was.

## The piece this replicates. Set by [HungryNetBridge] before registration.
var piece: HungryPiece = null

## The bridge, so the authority can drive the whole world exactly once per tick.
var bridge: HungryNetBridge = null

# --- From Dot2DNetSync.specs() ---
var net_position: Vector2 = Vector2.ZERO
var net_velocity: Vector2 = Vector2.ZERO
var net_mass: int = 0
var net_flags: int = 0

## Newest tick whose state this behaviour has adopted. Client side, for reconciliation.
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in Dot2DNetSync.specs():
		var property: StringName = spec["property"]
		var declaration: DotNetVar = null

		if bool(spec["custom"]):
			# Position and velocity are two components, not three. dot-net's quantised
			# vector types are Vector3, and a 2D game paying for a Z that is always zero
			# wastes 40% of its position bandwidth — which on a world with a hundred
			# visible pieces is the difference between fitting in a packet and not.
			if property == &"net_position":
				declaration = replicate_custom(
					property,
					Dot2DNetSync.write_position,
					Dot2DNetSync.read_position
				)
			else:
				declaration = replicate_custom(
					property,
					Dot2DNetSync.write_velocity,
					Dot2DNetSync.read_velocity
				)
		else:
			declaration = replicate(property, DotNetVar.Type[spec["type"]])

			if int(spec["bits"]) > 0:
				declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

	# Position is what everything else is judged against: a stale mass looks like a
	# slightly wrong number, a stale position looks like a teleport.
	var position_var := find_var(&"net_position")

	if position_var != null:
		position_var.with_priority(4.0)


# --- Input -----------------------------------------------------------------

## Takes one tick of a peer's intent.
##
## Already sanitised: [method DotNetManager._apply_input] calls
## [method DotNetInput.sanitise] before this runs, on the server, because everything in
## it came from a client. It is handed to the bridge rather than kept here, because a
## monster's command belongs to the monster and not to each of its sixteen pieces.
func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as HungryNetCommand

	if command == null or bridge == null or piece == null:
		return

	bridge.note_command(piece.owner_id, command.command)


# --- Simulation ------------------------------------------------------------

## Advances this piece by one tick, on whichever machine is entitled to.
##
## [b]The two sides do not take the same route, and they must not.[/b]
##
## On the authority the whole world has to tick as one: everybody moves, then eating is
## resolved against the world as it is [i]afterwards[/i], then merges, then projectiles.
## Resolving one piece's eating before the next piece has moved would decide a
## half-tick-stale collision, and at these speeds that is several units. So the first
## behaviour to reach this on a given tick drives the entire world through
## [method HungryNetBridge.ensure_world_ticked], and the rest find it already done and
## only copy their own state out.
##
## On a predicting client this runs the motor for this piece and nothing else. That is
## deliberate and it is the one place this game's prediction is knowingly incomplete —
## see [method HungryNetBridge.client_tick].
func _net_simulate(tick: int, delta: float) -> void:
	if piece == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_world_ticked(tick)
	elif bridge != null:
		bridge.predict_piece(piece, tick, delta)

	pull()


## Copies the simulation into the replicated properties, and onto the node.
##
## The node's position is not decoration: [method DotNetIdentity.world_position] reads it
## and that is what interest management and prioritisation are computed from. A piece
## whose node never moved would be judged relevant from wherever it spawned.
func pull() -> void:
	if piece == null:
		return

	Dot2DNetSync.pull(piece.state, self)

	var node := identity.entity as Node2D if identity != null else null

	if node != null:
		node.position = piece.state.position


## Copies received state back into the simulation. Receiving side.
##
## Runs for a remote piece, where it is the only thing that moves it, and for the owning
## client, where it is the rewind half of reconciliation — the server's answer is adopted
## wholesale and [DotNetPredictor] replays every unacknowledged command on top of it.
##
## The radius is [i]derived[/i] from the received mass rather than replicated. Sending
## both would let them disagree by a rounding error and put a monster's eat radius and
## its drawn radius in different places.
func _net_state_applied(tick: int) -> void:
	if piece == null:
		return

	last_state_tick = tick

	var rules: Dot2DMassRules = bridge.mass_rules() if bridge != null else null
	Dot2DNetSync.push(self, piece.state, rules)

	# The effect bits belong to the monster, not to this piece: speed is a property of the
	# whole set, every piece of one monster carries the same set, and reading it off the
	# replicated flags is what lets a client predict a rushing or frosted monster at the
	# right speed. See [member HungryMonster.flags].
	if bridge != null and bridge.world != null:
		var monster := bridge.world.monster_for(piece.owner_id)

		if monster != null:
			monster.adopt_flags(net_flags)

	var node := identity.entity as Node2D if identity != null else null

	if node != null:
		node.position = piece.state.position


## Copies the interpolated position into the simulation, every frame, on a remote piece.
##
## [b]Without this the interpolator's work is thrown away.[/b]
## [method _net_state_applied] runs when a snapshot arrives — a few times a second — and
## it is the only other place `net_position` is read. A remote monster driven only by that
## moves in 20 Hz steps, in a game whose whole feel is smooth continuous motion, while the
## smoothed value sits in a property nothing reads. It looks like the interpolator is
## broken; it is not, it is unread.
##
## Deliberately not the bookkeeping half. [member last_state_tick] is what reconciliation
## rewinds to and the tick here is a *render* tick, behind the server's — recording it
## would rewind a prediction to a tick the server never sent. dot-net does not call this
## on a predicted entity for the same reason.
func _net_interpolated(_tick: int) -> void:
	if piece == null:
		return

	var rules: Dot2DMassRules = bridge.mass_rules() if bridge != null else null
	Dot2DNetSync.push(self, piece.state, rules)

	var node := identity.entity as Node2D if identity != null else null

	if node != null:
		node.position = piece.state.position


func describe() -> Dictionary:
	return {
		"piece": piece.id if piece != null else 0,
		"owner": piece.owner_id if piece != null else 0,
		"position": net_position,
		"mass": net_mass,
		"flags": net_flags,
		"state_tick": last_state_tick,
	}
