extends Node

const HungryPaths := preload("hungry_paths.gd")

const HungryMonster := preload("hungry_monster.gd")
const HungryPiece := preload("hungry_piece.gd")
const HungryWorld := preload("hungry_world.gd")

## Things standing in the arena that nobody placed by hand: rocks, spikes and lures.
##
## [b]dot-props is here for its book-keeping, which is the dimension-free half.[/b] A
## catalogue, a world budget, a spawn interval, an undo stack, ownership and a cleanup when
## an owner leaves — none of which is about a rigid body, and all of which this game would
## otherwise have written again.
##
## [b]Everything is frozen the moment it lands.[/b] Rigid-body simulation is not
## reproducible across machines — dot-props says so and every game here that networks props
## repeats it — so a hazard that drifted would be somewhere different on every client with
## nothing erroring. A frozen body is a fixed obstacle, and both ends derive its size from
## the same replicated position and the same catalogue radius.
##
## [b]What a hazard does is this game's, not the addon's.[/b] dot-props knows how to put a
## thing in the world and how much of it a player may have; whether a rock blocks a monster
## or a spike bursts one is [method resolve], which runs inside the world's tick where
## everything else that moves a piece runs.

const CHANNEL := "hungry.hazards"

static var HAZARD_SCENE := HungryPaths.rebase("res://game/hungry_hazard_body.tscn")

## Nobody may hold more than this. An admin and the director are the only owners today.
const PER_OWNER := 24
const WORLD_BUDGET := 64
## How often one owner may place something, in seconds.
##
## [b]Zero, and that is a decision rather than a default.[/b] dot-props' interval exists
## because a *player* can hold a spawn key; nothing here is placed by a player — the
## director, an admin command and a map's own layout are the only owners, and every one of
## them places a whole arena at once. What still matters is the per-owner budget and the
## world cap, which are what stop a scatter of ten thousand.
const PLACE_INTERVAL := 0.0


signal placed(place_id: int, def: DotPropDef, at: Vector2)
signal cleared(place_id: int)

## A hazard did something to somebody. Server side; the world acts on it.
signal struck(player_id: int, piece_id: int, effect: StringName)


var authoritative: bool = false
var spawner: DotPropSpawner = null
var world: HungryWorld = null

var _placements: Dictionary = {}
var _instance_of_place: Dictionary = {}
var _place_of_instance: Dictionary = {}
var _next_place_id: int = 1
var _obstacles: PackedVector3Array = PackedVector3Array()


# --- The catalogue ---------------------------------------------------------

## What can stand in the arena.
##
## Three fields of `meta` are the whole of what a hazard is: `radius`, `colour` and
## `effect` — and `effect` is the only one this game reads that dot-props does not.
static func catalogue() -> DotPropCatalogue:
	var out := DotPropCatalogue.new()

	# A rock. Solid, inert, and the reason an arena has geometry at all: something to
	# break line of sight with and something to corner somebody against.
	_add(out, &"rock", "Rock", 120.0, Color(0.44, 0.45, 0.50), &"block", 4)

	# A spike. Bursts whatever touches it, which makes a corridor of them a place you can
	# chase somebody into and not follow.
	_add(out, &"spike", "Spike", 60.0, Color(0.85, 0.35, 0.35), &"burst", 3)

	# A lure. Draws hunters and does nothing to a player, so a director's wave can be
	# steered rather than only endured.
	_add(out, &"lure", "Lure", 70.0, Color(0.45, 0.80, 0.55), &"lure", 2)

	return out


static func _add(
	into: DotPropCatalogue,
	id: StringName,
	display: String,
	radius: float,
	colour: Color,
	effect: StringName,
	cost: int
) -> void:
	var def := DotPropDef.make(id, HAZARD_SCENE)
	def.display_name = display
	def.category = &"hazard"
	def.cost = cost
	def.mass = radius * 4.0
	def.can_grab = false
	def.can_freeze = false
	def.meta = {
		"radius": radius, "colour": colour.to_html(false), "effect": String(effect),
	}
	into.add(def)


static var _shared: DotPropCatalogue = null

static func shared_catalogue() -> DotPropCatalogue:
	if _shared == null:
		_shared = catalogue()

	return _shared


static func radius_of(def: DotPropDef) -> float:
	return float(def.meta.get("radius", 0.0)) if def != null else 0.0


static func colour_of(def: DotPropDef) -> Color:
	if def == null:
		return Color(0.5, 0.5, 0.55)

	return Color.from_string(String(def.meta.get("colour", "808080")), Color(0.5, 0.5, 0.55))


static func effect_of(def: DotPropDef) -> StringName:
	return StringName(String(def.meta.get("effect", "block"))) if def != null else &"block"


## The catalogue's ids, sorted as [String] so an index can travel instead of a name.
static func wire_ids() -> PackedStringArray:
	var out := PackedStringArray()

	for def in shared_catalogue().props:
		out.append(String(def.id))

	out.sort()
	return out


static func index_of(id: StringName) -> int:
	return wire_ids().find(String(id))


static func id_at(index: int) -> StringName:
	var ids := wire_ids()
	return StringName(ids[index]) if index >= 0 and index < ids.size() else &""


# --- Lifecycle -------------------------------------------------------------

func setup(p_authoritative: bool, p_world: HungryWorld) -> DotResult:
	authoritative = p_authoritative
	world = p_world

	if not authoritative:
		return DotResult.success(null)

	var limits := DotPropLimits.new()
	limits.per_player_budget = PER_OWNER
	limits.world_budget = WORLD_BUDGET
	limits.spawn_interval = PLACE_INTERVAL
	limits.clean_up_on_leave = true
	limits.undo_depth = PER_OWNER

	var problem := limits.validate()

	if not problem.ok:
		return problem.wrap("The hazard limits are not usable")

	spawner = DotPropSpawner.new()
	spawner.name = "Spawner"
	spawner.catalogue = shared_catalogue()
	spawner.limits = limits
	spawner.authoritative = true
	# `world_ref` unset, so the bodies are parented here. They outlive a `changegame` the
	# same way the netcode manager does, and asking a scene for its path before it is in a
	# tree is the failure game-simple-lobby's screenshot found.
	add_child(spawner)

	spawner.removed.connect(_on_removed)

	# [b]On the layout's `hazard` layer.[/b] `top_down_2d` gives `hazard` the row
	# [player] and marks it query-only, which is exactly what a spike or a crusher is:
	# a volume a player is tested against and nothing else collides with. The body
	# arrives on layer 1 masking layer 1 — the layer the layout calls `world` — so
	# before this a hazard was, as far as the collision matrix went, a piece of floor.
	spawner.spawned.connect(
		func(prop: DotPropInstance) -> void:
			if world == null or world.player_stack == null or prop.node == null:
				return

			var put := world.player_stack.classify(prop.node, &"hazard")

			# [b]Reported, not discarded.[/b] `classify` fails for a layer the layout
			# does not have, and the body then keeps Godot's default layer 1 — which
			# this layout calls `world`, so the failure mode is a hazard that is a piece
			# of floor. Swallowing the result is how that goes unnoticed; this game's own
			# stack suite found it by asserting the layer exists.
			if not put.ok:
				DotLog.warn(CHANNEL, "a hazard was not classified", {
					"why": put.error.message
				})
	)

	return DotResult.success(null)


func _physics_process(delta: float) -> void:
	# Simulated seconds the host advances, never a wall clock: a wall clock lets a player
	# who lags the server place faster than one who does not.
	if authoritative and spawner != null:
		spawner.advance(delta)


# --- The authority --------------------------------------------------------

func place(owner_id: int, hazard_id: StringName, at: Vector2) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server places hazards.")

	var def := shared_catalogue().get_prop(hazard_id)

	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "There is no such hazard.")

	var bounded := at

	if world != null and world.arena != null:
		bounded = world.arena.clamp_position(at, radius_of(def))

	var instance := spawner.spawn_2d(hazard_id, StringName(str(owner_id)), bounded)

	if instance == null:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"That could not be placed.",
			"budget, cooldown or world cap; see the props channel"
		)

	# Frozen through the physics gun's own call rather than by assigning `freeze`, because
	# that is the one place in dot-props that also zeroes the velocities — and a body
	# frozen with a velocity applies it the instant anything thaws it.
	DotPhysGun.set_frozen(instance, true)

	var place_id := _next_place_id
	_next_place_id += 1

	_placements[place_id] = {"def": def, "at": bounded, "owner": owner_id}
	_instance_of_place[place_id] = instance.instance_id
	_place_of_instance[instance.instance_id] = place_id
	_rebuild_obstacles()

	placed.emit(place_id, def, bounded)
	return DotResult.success(place_id)


## Scatters a ring of hazards, deterministically from a seed.
##
## [b]Deterministic, because a round has to be reproducible.[/b] `randf()` here would make
## two runs of `headless_round` place a different arena, and the whole reason that suite
## can assert anything is that it does not.
func scatter(hazard_id: StringName, count: int, seed_value: int) -> int:
	if not authoritative or world == null or world.arena == null:
		return 0

	# [b]The same class the food is scattered with, rather than arithmetic here.[/b]
	# `Dot2DScatter.position_of` is a pure function of the seed and the index, so a hazard
	# field and a food field are laid out by one function rather than by two that can
	# disagree about what "a uniform point in this rectangle" means — and it already
	# keeps a margin off the walls, which is the thing a hand-written version forgets and
	# only notices when a rock is half outside the arena.
	var field := Dot2DScatter.over(world.arena.bounds, count, seed_value)
	field.margin = 400.0

	var made := 0

	for index in range(count):
		if place(0, hazard_id, field.position_of(index)).ok:
			made += 1

	return made


func clear_owner(owner_id: int) -> int:
	return spawner.clear_player(StringName(str(owner_id))) if authoritative else 0


func clear_all() -> int:
	return spawner.clear_all() if authoritative else 0


func _on_removed(instance: DotPropInstance, _reason: StringName) -> void:
	var place_id := int(_place_of_instance.get(instance.instance_id, 0))

	if place_id == 0:
		return

	_place_of_instance.erase(instance.instance_id)
	_instance_of_place.erase(place_id)
	_placements.erase(place_id)
	_rebuild_obstacles()

	cleared.emit(place_id)


# --- What a hazard does ----------------------------------------------------

## Applies every hazard to everybody. Called from the world's tick, on the authority.
##
## [b]After movement and before eating.[/b] A rock has to stop a piece before the eat
## check runs, or a monster pushes through it for one tick and eats somebody on the far
## side; and a spike has to burst before eating, or a piece is swallowed on the tick it was
## supposed to be scattered. That is the same ordering argument [HungryWorld.tick] already
## makes about merges and projectiles.
func resolve() -> void:
	if not authoritative or world == null or _placements.is_empty():
		return

	for monster in world.monsters():
		if not monster.alive:
			continue

		for piece in monster.pieces:
			_resolve_piece(monster, piece)


func _resolve_piece(monster: HungryMonster, piece: HungryPiece) -> void:
	for entry in _placements.values():
		var placement: Dictionary = entry
		var def: DotPropDef = placement["def"]
		var at: Vector2 = placement["at"]
		var radius := radius_of(def)
		var clearance := radius + piece.radius()
		var away := piece.position() - at
		var distance := away.length()

		if distance >= clearance:
			continue

		match effect_of(def):
			&"block":
				# Pushed out, and the velocity going in removed. Without the second half a
				# player holding a direction into a rock is pushed out by the resolve and
				# accelerated straight back in by the motor sixty times a second — the
				# position ends up correct and the movement reads as lag, which is the
				# worst way for a level to be wrong because it sends the next person to
				# the netcode. game-simple-lobby's furniture says the same thing.
				var normal := away / distance if distance > 0.001 else Vector2.RIGHT
				piece.state.position = at + normal * clearance

				var into := piece.state.velocity.dot(normal)

				if into < 0.0:
					piece.state.velocity -= normal * into
			&"burst":
				struck.emit(monster.id, piece.id, &"burst")
			&"lure":
				# Nothing to the player. A lure is for the hunters, and what it does to
				# them is [HungryHunters]' — this only says it is there.
				pass


# --- A client's mirror -----------------------------------------------------

func adopt(place_id: int, hazard_id: StringName, at: Vector2) -> void:
	var def := shared_catalogue().get_prop(hazard_id)

	if def == null:
		DotLog.warn(CHANNEL, "the server placed a hazard this build does not know", {
			"hazard": String(hazard_id), "place": place_id,
		})
		return

	_placements[place_id] = {"def": def, "at": at, "owner": 0}
	_rebuild_obstacles()
	placed.emit(place_id, def, at)


func drop(place_id: int) -> void:
	if not _placements.has(place_id):
		return

	_placements.erase(place_id)
	_rebuild_obstacles()
	cleared.emit(place_id)


func forget_all() -> void:
	_placements.clear()
	_rebuild_obstacles()


# --- Reading ---------------------------------------------------------------

func placements() -> Dictionary:
	return _placements.duplicate()


func count() -> int:
	return _placements.size()


func has(place_id: int) -> bool:
	return _placements.has(place_id)


## Everything solid, as `(x, y, radius)`.
func obstacles() -> PackedVector3Array:
	return _obstacles


## Where the lures are, for a hunter to be drawn toward.
func lures() -> PackedVector2Array:
	var out := PackedVector2Array()

	for entry in _placements.values():
		var placement: Dictionary = entry

		if effect_of(placement["def"]) == &"lure":
			out.append(placement["at"])

	return out


func _rebuild_obstacles() -> void:
	var out := PackedVector3Array()

	for entry in _placements.values():
		var placement: Dictionary = entry
		var def: DotPropDef = placement["def"]

		if effect_of(def) != &"block":
			continue

		var at: Vector2 = placement["at"]
		out.append(Vector3(at.x, at.y, radius_of(def)))

	_obstacles = out


## Everything the authority holds, as `[place_id, kind_index, at]` rows.
func wire_rows() -> Array:
	var out: Array = []

	for place_id in _placements.keys():
		var placement: Dictionary = _placements[place_id]
		out.append([
			int(place_id), index_of((placement["def"] as DotPropDef).id), placement["at"],
		])

	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("hazards      %d (%d solid)" % [_placements.size(), _obstacles.size()])

	if authoritative and spawner != null:
		out.append_array(spawner.describe_lines())

	return out
