class_name HungryField
extends RefCounted

## Everything edible in the world, and the one id space it shares with the monsters.
##
## Four fields in one object because a monster's eat check has to consider all of them
## on the same tick and against the same [Dot2DGrid]. Two grids would mean two queries
## and a merge of the results, per piece, per tick; four would mean four.
##
## [b]Three of the four are positionless on the wire.[/b] [Dot2DScatter] places a slot
## from a hash of (seed, index), so a client that knows the seed knows where every crumb,
## fruit and item drop is — and how big it is, and which fruit it is — from an integer.
## What actually travels is which slots exist: a list of indices added and a list taken,
## which at a steady state is a few dozen varints a snapshot.
##
## [b]The fourth is planted, and it is the exception that shows why.[/b] A lure drops
## food where a player chose, and a chosen position cannot be derived from anything. Its
## slots carry their position on the wire, and they are a separate field precisely so
## that the cheap case stays cheap.

# --- The id space ----------------------------------------------------------

## Ids below this are monster pieces. Everything at or above is in this class.
##
## One id space split by constants, rather than several grids. The consequence is that
## anything touching the grid has to respect the split — see [method kind_of].
const PIECE_ID_LIMIT := 1000000

const FOOD_ID_BASE := 1000000
const FRUIT_ID_BASE := 2000000
const ITEM_ID_BASE := 3000000
const PLANTED_ID_BASE := 4000000
const KIND_SPAN := 1000000

enum Kind { PIECE, FOOD, FRUIT, ITEM, PLANTED }

var food: Dot2DScatter = null
var fruit: Dot2DScatter = null
var items: Dot2DScatter = null

## Planted slot index -> [code]{position: Vector2, tier: int}[/code].
var _planted: Dictionary = {}
var _next_planted: int = 0

## Grid ids added and removed since [method drain_delta] was last called.
##
## Accumulated rather than signalled per event: a snapshot goes out every few ticks and
## batching a tick's worth of eating into one list is the difference between one small
## message and forty tiny ones.
var _added: Dictionary = {}
var _removed: Dictionary = {}

var _bounds: Rect2 = Rect2()
var _seed: int = 1


static func over(bounds: Rect2, world_seed: int) -> HungryField:
	var field := HungryField.new()
	field._bounds = bounds
	field._seed = world_seed

	field.food = Dot2DScatter.over(bounds, HungryContent.FOOD_TARGET, world_seed)
	field.food.refill_budget = HungryContent.FOOD_REFILL_PER_TICK
	field.food.margin = 30.0

	# Different seeds per field, or the fruit sits exactly on top of the crumb with the
	# same index: `position_of` is a hash of (seed, index) and the same pair gives the
	# same point.
	field.fruit = Dot2DScatter.over(bounds, HungryContent.FRUIT_TARGET, world_seed ^ 0x5F1E)
	field.fruit.refill_budget = HungryContent.FRUIT_REFILL_PER_TICK
	field.fruit.margin = 80.0

	field.items = Dot2DScatter.over(bounds, HungryContent.ITEM_TARGET, world_seed ^ 0x17E3)
	field.items.refill_budget = HungryContent.ITEM_REFILL_PER_TICK
	field.items.margin = 80.0

	return field


## Moves every field into a new rectangle. Client side, from the hello.
##
## [b]The bounds are part of the position, not decoration.[/b] [Dot2DScatter] places a
## slot by hashing (seed, index) [i]into these bounds[/i], so a peer holding a different
## rectangle derives every crumb in the wrong place — from the right seed, which is what
## makes the failure so confusing: the ids all match, the counts all match, and nothing is
## where anybody says it is.
func set_bounds(rect: Rect2) -> void:
	_bounds = rect
	food.bounds = rect
	fruit.bounds = rect
	items.bounds = rect


func bounds() -> Rect2:
	return _bounds


# --- Classifying a grid id -------------------------------------------------

static func kind_of(grid_id: int) -> Kind:
	if grid_id < PIECE_ID_LIMIT:
		return Kind.PIECE
	if grid_id < FRUIT_ID_BASE:
		return Kind.FOOD
	if grid_id < ITEM_ID_BASE:
		return Kind.FRUIT
	if grid_id < PLANTED_ID_BASE:
		return Kind.ITEM
	return Kind.PLANTED


static func index_of(grid_id: int) -> int:
	return grid_id % KIND_SPAN


static func is_edible(grid_id: int) -> bool:
	return grid_id >= FOOD_ID_BASE


# --- Queries ---------------------------------------------------------------

## Where a slot is. The three hashed fields derive it; planted food remembers it.
func position_of(grid_id: int) -> Vector2:
	var index := index_of(grid_id)

	match kind_of(grid_id):
		Kind.FOOD:
			return food.position_of(index)
		Kind.FRUIT:
			return fruit.position_of(index)
		Kind.ITEM:
			return items.position_of(index)
		Kind.PLANTED:
			var row: Dictionary = _planted.get(index, {})
			return row.get("position", Vector2.ZERO)
		_:
			return Vector2.ZERO


func radius_of(grid_id: int) -> float:
	match kind_of(grid_id):
		Kind.FOOD:
			return HungryContent.food_radius(food.variant_of(index_of(grid_id)))
		Kind.FRUIT:
			return HungryContent.FRUIT_RADIUS
		Kind.ITEM:
			return HungryContent.ITEM_RADIUS
		Kind.PLANTED:
			return HungryContent.FOOD_TIER_RADIUS[_planted_tier(index_of(grid_id))]
		_:
			return 0.0


## What eating this is worth, in mass. Item drops are worth nothing: they are a charge.
func mass_of(grid_id: int) -> float:
	match kind_of(grid_id):
		Kind.FOOD:
			return HungryContent.food_mass(food.variant_of(index_of(grid_id)))
		Kind.FRUIT:
			return HungryContent.FRUIT_MASS
		Kind.PLANTED:
			return HungryContent.FOOD_TIER_MASS[_planted_tier(index_of(grid_id))]
		_:
			return 0.0


func tier_of(grid_id: int) -> int:
	match kind_of(grid_id):
		Kind.FOOD:
			return HungryContent.food_tier(food.variant_of(index_of(grid_id)))
		Kind.PLANTED:
			return _planted_tier(index_of(grid_id))
		_:
			return 0


func fruit_kind_of(grid_id: int) -> HungryContent.Fruit:
	return HungryContent.fruit_kind(fruit.variant_of(index_of(grid_id)))


func item_id_of(grid_id: int) -> StringName:
	return HungryContent.item_id(items.variant_of(index_of(grid_id)))


func _planted_tier(index: int) -> int:
	var row: Dictionary = _planted.get(index, {})
	return int(row.get("tier", HungryContent.LURE_FOOD_TIER))


func alive_count() -> int:
	return food.alive_count() + fruit.alive_count() + items.alive_count() \
		+ _planted.size()


func food_count() -> int:
	return food.alive_count() + _planted.size()


func fruit_count() -> int:
	return fruit.alive_count()


func item_count() -> int:
	return items.alive_count()


func planted_count() -> int:
	return _planted.size()


## Every live grid id. What a full resynchronisation sends, and what a round reset
## has to remove from the grid before laying a new field out.
func alive_ids() -> Array[int]:
	var out: Array[int] = []

	for index in food.alive_indices():
		out.append(FOOD_ID_BASE + index)

	for index in fruit.alive_indices():
		out.append(FRUIT_ID_BASE + index)

	for index in items.alive_indices():
		out.append(ITEM_ID_BASE + index)

	var planted_indices := _planted.keys()
	planted_indices.sort()

	for index in planted_indices:
		out.append(PLANTED_ID_BASE + int(index))

	return out


# --- Mutating --------------------------------------------------------------

## Takes a slot. False when something else got it first on the same tick.
##
## Returning false rather than silently succeeding is what lets the authority tell a
## real pickup from a duplicate claim: two pieces overlapping the same crumb on the same
## tick is normal, and one of them has to lose.
func take(grid_id: int) -> bool:
	var index := index_of(grid_id)
	var took := false

	match kind_of(grid_id):
		Kind.FOOD:
			took = food.take(index)
		Kind.FRUIT:
			took = fruit.take(index)
		Kind.ITEM:
			took = items.take(index)
		Kind.PLANTED:
			took = _planted.erase(index)
		_:
			took = false

	if took:
		_note_removed(grid_id)

	return took


## Lays every field out completely. What a round start does.
func fill_all() -> Array[int]:
	var out: Array[int] = []

	for index in food.fill():
		out.append(FOOD_ID_BASE + index)

	for index in fruit.fill():
		out.append(FRUIT_ID_BASE + index)

	for index in items.fill():
		out.append(ITEM_ID_BASE + index)

	for grid_id in out:
		_note_added(grid_id)

	return out


## Replaces every field with a new one. What a new round does.
##
## [b]The index counters are deliberately not reset[/b] — that is [Dot2DScatter]'s rule
## and this class inherits it. An index is a slot's identity: it goes on the wire and it
## is how a client knows which crumb it just ate, so restarting the count would mean two
## different crumbs with the same name a round apart.
##
## The consequence for a caller is that the new field's grid ids sit [i]beside[/i] the
## old field's rather than overwriting them, so whatever indexed the old one into a grid
## must remove it first. [method alive_ids] is what to remove, and it has to be read
## before this is called.
func reseed(new_seed: int) -> void:
	_seed = new_seed
	food.reseed(new_seed)
	fruit.reseed(new_seed ^ 0x5F1E)
	items.reseed(new_seed ^ 0x17E3)
	_planted.clear()
	_added.clear()
	_removed.clear()


## Places up to each field's budget. Returns the grid ids placed.
func refill() -> Array[int]:
	var out: Array[int] = []

	for index in food.refill():
		out.append(FOOD_ID_BASE + index)

	for index in fruit.refill():
		out.append(FRUIT_ID_BASE + index)

	for index in items.refill():
		out.append(ITEM_ID_BASE + index)

	for grid_id in out:
		_note_added(grid_id)

	return out


## Plants a ring of food. What a lure does when it lands.
##
## A ring rather than a scatter, and derived from the impact point rather than hashed,
## because the shape is the point: a player has to be able to see at a glance that
## somebody baited this spot.
func plant(centre: Vector2, count: int, tier: int, bounds: Rect2) -> Array[int]:
	var out: Array[int] = []
	var radius := HungryContent.LURE_RADIUS
	var inset := HungryContent.FOOD_TIER_RADIUS[tier]

	for step in range(maxi(0, count)):
		# Two interleaved rings, so a cluster reads as a target rather than as a
		# suspiciously perfect circle, and the angle offset comes from the index so two
		# machines lay the same one out.
		var angle := TAU * float(step) / float(maxi(1, count))
		var ring := radius * (0.55 if (step % 2) == 0 else 1.0)
		var at := centre + Vector2.from_angle(angle) * ring

		at = Vector2(
			clampf(at.x, bounds.position.x + inset, bounds.end.x - inset),
			clampf(at.y, bounds.position.y + inset, bounds.end.y - inset)
		)

		var index := _next_planted
		_next_planted += 1
		_planted[index] = {"position": at, "tier": tier}

		var grid_id := PLANTED_ID_BASE + index
		out.append(grid_id)
		_note_added(grid_id)

	return out


## Registers every live slot into a [Dot2DGrid].
func populate(grid: Dot2DGrid) -> void:
	for grid_id in alive_ids():
		grid.place(grid_id, position_of(grid_id), radius_of(grid_id))


# --- The wire --------------------------------------------------------------

func _note_added(grid_id: int) -> void:
	# An id added and taken between two snapshots cancels out: sending both is two
	# messages describing a crumb no client ever saw.
	if _removed.erase(grid_id):
		return

	_added[grid_id] = true


func _note_removed(grid_id: int) -> void:
	if _added.erase(grid_id):
		return

	_removed[grid_id] = true


func has_delta() -> bool:
	return not _added.is_empty() or not _removed.is_empty()


## Takes the accumulated change and clears it. Authority side, once per snapshot.
func drain_delta() -> Dictionary:
	var added := _added.keys()
	var removed := _removed.keys()
	added.sort()
	removed.sort()

	_added.clear()
	_removed.clear()

	return {"added": added, "removed": removed}


## Applies a delta. Receiving side.
##
## Planted slots arrive with their position; the other three arrive as a bare index and
## are placed from the seed. A planted id whose position is missing is dropped rather
## than placed at the origin, because a crumb at (0,0) that nobody can eat is a bug that
## looks like a rendering glitch.
func apply_delta(added: Array, removed: Array, planted: Dictionary = {}) -> void:
	for entry in removed:
		var grid_id := int(entry)
		var index := index_of(grid_id)

		match kind_of(grid_id):
			Kind.FOOD:
				food.take(index)
			Kind.FRUIT:
				fruit.take(index)
			Kind.ITEM:
				items.take(index)
			Kind.PLANTED:
				_planted.erase(index)

	for entry in added:
		var grid_id := int(entry)
		var index := index_of(grid_id)

		match kind_of(grid_id):
			Kind.FOOD:
				food.adopt(index)
			Kind.FRUIT:
				fruit.adopt(index)
			Kind.ITEM:
				items.adopt(index)
			Kind.PLANTED:
				var row: Variant = planted.get(grid_id)
				if row is Dictionary:
					_planted[index] = row
					_next_planted = maxi(_next_planted, index + 1)


## The planted rows for a set of grid ids, so a delta can carry their positions.
func planted_rows(grid_ids: Array) -> Dictionary:
	var out: Dictionary = {}

	for entry in grid_ids:
		var grid_id := int(entry)

		if kind_of(grid_id) != Kind.PLANTED:
			continue

		var row: Variant = _planted.get(index_of(grid_id))

		if row is Dictionary:
			out[grid_id] = row

	return out


func seed_value() -> int:
	return _seed


func describe() -> Dictionary:
	return {
		"food": food.alive_count(),
		"fruit": fruit.alive_count(),
		"items": items.alive_count(),
		"planted": _planted.size(),
		"seed": _seed,
		"pending_added": _added.size(),
		"pending_removed": _removed.size(),
	}
