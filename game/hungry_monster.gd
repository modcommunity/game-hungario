class_name HungryMonster
extends RefCounted

## One player: the pieces they control, what they are carrying, and what is currently
## happening to them.
##
## [b]Almost everything interesting about this game is a property of the set rather than
## of a piece.[/b] Your mass is the sum, your position is the mass-weighted centroid,
## your rider sits on the biggest piece, and you are dead when the last one is eaten.
##
## The avatar is here rather than on the piece for the same reason: a player has one
## avatar however many pieces they are in, and a burst that scattered five copies of
## somebody's hat across the map would be a different game.

## Stable id. The scoreboard key, the interest key, the colour seed.
##
## [b]The session id, never the peer id.[/b] A peer id is reassigned on reconnect and
## the next player to join would inherit this monster.
var id: int = 0

var display_name: String = "Monster"

var colour: Color = Color.WHITE

## What the rider looks like. Never null after [method make] — an unresolved player is
## given a deterministic guest rather than nothing, because "no avatar" is a player
## nobody can see.
var avatar: DotAvatar = null

## The pieces, in creation order. Never empty while alive.
var pieces: Array[HungryPiece] = []

## Throwable ids being carried, oldest first. Bounded by
## [constant HungryContent.MAX_CARRIED].
var carried: Array[StringName] = []

## What this player brought in: a starting throwable and a trait.
##
## Validated on the authority against [method HungryContent.loadout_schema] and an
## entitlement set, and then replicated as two ids in the join — not because a client
## could not be trusted with the document, but because a client [i]predicts[/i] its own
## movement and the trait changes how fast it moves. Two ends computing speed from
## different loadouts is a permanent mispredict.
var loadout: DotLoadout = null


## Which trait is in force. Read on both ends; see [member loadout].
var trait_id: StringName = HungryContent.TRAIT_NIMBLE


## What this player spawns holding.
func starter_item() -> StringName:
	if loadout == null:
		return HungryContent.ITEM_PEPPER

	var chosen := loadout.item_in(HungryContent.SLOT_STARTER)
	return chosen if chosen != &"" else HungryContent.ITEM_PEPPER


## Adopts a validated loadout. Authority side, and on a client from the join.
func wear_loadout(document: DotLoadout) -> void:
	loadout = document

	if document == null:
		trait_id = HungryContent.TRAIT_NIMBLE
		return

	var chosen := document.item_in(HungryContent.SLOT_TRAIT)
	trait_id = chosen if chosen != &"" else HungryContent.TRAIT_NIMBLE

## Tick this player may split again on.
var split_ready_tick: int = 0

## Tick this player may throw again on.
var throw_ready_tick: int = 0

## Tick this player may eject again on.
var eject_ready_tick: int = 0

## Blobs ejected this life, for the scoreboard and for `hungry_status`.
var ejected: int = 0

## flag bit -> tick the effect expires on. See [constant HungryContent.FLAG_RUSH].
##
## [b]Authority-only.[/b] An expiry tick is never sent: a client is told which effects are
## in force through the replicated piece flags and nothing about when they end, because
## when they end is not something a client needs and is one more thing that can disagree.
var effects: Dictionary = {}

## The effect bits currently in force, as replicated.
##
## Written on the authority from [member effects] once a tick, and on a receiving peer
## from the flags that arrived with a piece. [b]It is the single source both ends compute
## speed from[/b], which is what keeps a rushing or frosted monster predictable — see
## [method HungryWorld._sync_flags].
var flags: int = 0

## Peak mass this life, for the scoreboard.
var best_mass: float = 0.0

## Whether they are in the world at all.
var alive: bool = false

## Their last command, repeated when none arrives.
##
## A dropped input packet should read as "still holding the mouse there", which is what
## actually happened — not as "let go", which stops the monster dead and is unplayable
## at any latency.
var last_command: Dot2DCommand = null

## Lifetime counters, for the scoreboard and for `hungry_status`.
var food_eaten: int = 0
var fruit_eaten: int = 0
var players_eaten: int = 0
var times_burst: int = 0


static func make(p_id: int, p_name: String) -> HungryMonster:
	var monster := HungryMonster.new()
	monster.id = p_id
	monster.display_name = p_name
	monster.colour = HungryContent.colour_for(p_id)
	monster.avatar = HungryContent.default_avatar(p_id)
	return monster


# --- The set ---------------------------------------------------------------

## Total mass across every piece. The score, and the win condition.
func mass() -> float:
	var total := 0.0

	for piece in pieces:
		total += piece.mass()

	return total


## The centroid, weighted by mass.
##
## Weighted, not the plain average: an unweighted centre puts the camera midway between
## a huge piece and a speck, which is nowhere the player is looking. What they are
## thinking about is where their mass is.
func centre() -> Vector2:
	var total := 0.0
	var sum := Vector2.ZERO

	for piece in pieces:
		sum += piece.position() * piece.mass()
		total += piece.mass()

	if total <= 0.0:
		return Vector2.ZERO

	return sum / total


## The radius of a circle containing every piece. What the camera frames.
func spread_radius() -> float:
	if pieces.is_empty():
		return 0.0

	var origin := centre()
	var furthest := 0.0

	for piece in pieces:
		furthest = maxf(furthest, origin.distance_to(piece.position()) + piece.radius())

	return furthest


## The piece the rider sits on. The biggest one, ties broken by id.
##
## Ties broken deterministically because the rider is drawn, and two machines that
## disagreed about which piece carries it would draw the avatar in different places.
func rider_piece() -> HungryPiece:
	var best: HungryPiece = null

	for piece in pieces:
		if best == null or piece.mass() > best.mass() \
				or (is_equal_approx(piece.mass(), best.mass()) and piece.id < best.id):
			best = piece

	return best


func piece_count() -> int:
	return pieces.size()


func find_piece(piece_id: int) -> HungryPiece:
	for piece in pieces:
		if piece.id == piece_id:
			return piece

	return null


func add_piece(piece: HungryPiece) -> void:
	pieces.append(piece)
	alive = true
	best_mass = maxf(best_mass, mass())


## Removes a piece. The player dies when the last one goes.
func remove_piece(piece_id: int) -> bool:
	for index in range(pieces.size()):
		if pieces[index].id != piece_id:
			continue

		pieces.remove_at(index)

		if pieces.is_empty():
			alive = false
			return true

		return false

	return false


func clear_pieces() -> void:
	pieces.clear()
	alive = false


# --- Carrying --------------------------------------------------------------

## Picks a throwable up. False when already carrying the maximum.
func take_item(item: StringName) -> bool:
	if carried.size() >= HungryContent.MAX_CARRIED:
		return false

	carried.append(item)
	return true


## Spends the oldest charge. Empty when carrying nothing.
##
## Oldest first rather than newest: a player who picks up a frost while holding two
## peppers expects the peppers to go first, and a stack that fired the newest would make
## picking anything up feel like losing what you had.
func spend_item() -> StringName:
	if carried.is_empty():
		return &""

	return carried.pop_front()


func next_item() -> StringName:
	return carried[0] if not carried.is_empty() else &""


## The carried ids as text. For a HUD, a console command and [method describe].
func carried_names() -> PackedStringArray:
	var out := PackedStringArray()

	for item in carried:
		out.append(String(item))

	return out


# --- Effects ---------------------------------------------------------------

## Applies an effect until [param until_tick]. Refreshing extends, never shortens.
func apply_effect(flag: int, until_tick: int) -> void:
	effects[flag] = maxi(int(effects.get(flag, 0)), until_tick)


func has_effect(flag: int, tick: int) -> bool:
	return int(effects.get(flag, 0)) > tick


func clear_effect(flag: int) -> void:
	effects.erase(flag)


## Drops effects that have run out. Called once a tick, before anything reads them.
func expire_effects(tick: int) -> void:
	for flag in effects.keys():
		if int(effects[flag]) <= tick:
			effects.erase(flag)


## What this monster's speed is multiplied by right now.
##
## From [member flags], not from [member effects]: both ends have the flags and only the
## authority has the effects. See the note on [member flags].
func speed_multiplier(_tick: int = 0) -> float:
	var scale := HungryContent.trait_speed(trait_id)

	if (flags & HungryContent.FLAG_RUSH) != 0:
		scale *= HungryContent.RUSH_SPEED_MULTIPLIER

	if (flags & HungryContent.FLAG_FROSTED) != 0:
		scale *= HungryContent.FROST_SPEED_MULTIPLIER

	return scale


## What this monster's eat ratio is multiplied by right now. Below 1 is easier.
func eat_ratio_multiplier(tick: int) -> float:
	return HungryContent.MAW_RATIO_MULTIPLIER \
		if has_effect(HungryContent.FLAG_MAW, tick) else 1.0


## Adopts the effect bits that arrived with a piece. Receiving side.
func adopt_flags(piece_flags: int) -> void:
	flags = piece_flags & HungryContent.EFFECT_MASK


## The effect bits, for [member Dot2DState.flags].
func effect_flags(tick: int) -> int:
	var bits := 0

	for flag in [
		HungryContent.FLAG_RUSH,
		HungryContent.FLAG_MAW,
		HungryContent.FLAG_RIND,
		HungryContent.FLAG_FROSTED,
		HungryContent.FLAG_PROTECTED,
	]:
		if has_effect(int(flag), tick):
			bits |= int(flag)

	return bits


func describe() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"alive": alive,
		"pieces": pieces.size(),
		"mass": mass(),
		"best": best_mass,
		"centre": centre(),
		"carried": carried_names(),
		"effects": effects.size(),
		"flags": flags,
		"trait": String(trait_id),
		"starter": String(starter_item()),
		"food": food_eaten,
		"fruit": fruit_eaten,
		"kills": players_eaten,
		"burst": times_burst,
		"avatar": avatar.digest() if avatar != null else "",
	}


func _to_string() -> String:
	return "HungryMonster(%s, %.0f in %d)" % [display_name, mass(), pieces.size()]
