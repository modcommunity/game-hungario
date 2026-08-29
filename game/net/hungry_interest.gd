class_name HungryInterest
extends DotNetInterest

## Who is told about which pieces.
##
## [b]The single biggest lever on bandwidth, and the only anti-cheat that works.[/b] Data
## never sent cannot be drawn on a wallhack, and in this game the thing a cheat most wants
## is a map of everybody's mass.
##
## dot-net's built-in distance strategy would nearly do, and does not, for two reasons
## that are both about a monster being a set:
##
## - [b]The observer is not one entity.[/b] [method DotNetManager._observer_for] hands a
##   strategy the first entity a peer owns, which after a burst is an arbitrary fragment
##   possibly a screen away from where the player is looking. What a player sees is
##   framed on their [i]centroid[/i], so that is what this measures from.
## - [b]The view grows with the player.[/b] A monster wide enough to fill the screen
##   cannot see anything it might eat unless the rectangle grows with it. Linear in
##   radius, not in mass: radius is what fills a screen and mass grows as its square.

## Half-width and half-height of what a player of unremarkable size is told about.
##
## Generous rather than exact: a client told only what is on screen sees pieces pop in at
## the edge, and the margin is what buys the interpolation buffer something to
## interpolate from.
@export var base_extent: Vector2 = Vector2(1180.0, 760.0)

## Radius at which the rectangle is exactly [member base_extent].
@export_range(1.0, 1000.0, 1.0) var reference_radius: float = 95.0

## The world, for the centroid. Set by [HungryNetBridge].
var bridge: HungryNetBridge = null


func _init() -> void:
	strategy_name = "hungry"

	# [b]No cache.[/b] dot-net's default is to hold an answer for a quarter of a second,
	# which is right for a world whose membership changes slowly — and this one's changes
	# every time anybody splits, bursts, merges, dies or respawns, which at eight players
	# is several times a second.
	#
	# A cached answer pins what the observer owns and anything always-relevant, so a
	# player never loses sight of their own monster; what it cannot pin is somebody
	# *else's* new piece, and a quarter of a second of an opponent's split being invisible
	# is a quarter of a second of being eaten by something that was not drawn.
	#
	# The cost is a rectangle test per entity per peer per snapshot: at the entity cap and
	# sixteen players that is about forty thousand `Rect2.has_point` calls a second, which
	# is nothing next to the eating checks the same world already does every tick.
	evaluation_interval_sec = 0.0


func _is_relevant(
	observer: DotNetIdentity,
	entity: DotNetIdentity,
	_context: Dictionary
) -> bool:
	if observer == null or bridge == null:
		return true

	var rect := view_rect(observer.owner_peer_id)

	if rect.size == Vector2.ZERO:
		# The observer has no monster yet: joining, dead, or between rounds. Everything is
		# relevant, which is correct rather than merely convenient — a player watching a
		# respawn timer is watching the fight that killed them.
		return true

	var at := entity.world_position()
	return rect.has_point(Vector2(at.x, at.y))


## The rectangle a peer is told about. Public, because the self-test asserts on it.
func view_rect(peer_id: int) -> Rect2:
	var monster := bridge.monster_for_peer(peer_id)

	if monster == null or not monster.alive:
		return Rect2()

	var extent := base_extent * maxf(
		1.0, monster.spread_radius() / maxf(1.0, reference_radius)
	)
	var origin := monster.centre()

	return Rect2(origin - extent, extent * 2.0)


## Relative importance, for when the budget cannot carry everything relevant.
##
## Near beats far, as in the default, and [b]big beats small[/b] — a huge monster
## drifting toward you is the single most important thing on your screen and a crumb-sized
## fragment on the far edge is the least. The mass comes off the replicating behaviour
## rather than out of the world, so this stays correct on a peer that only has the
## replicated view.
func _score(
	observer: DotNetIdentity,
	entity: DotNetIdentity,
	_context: Dictionary
) -> float:
	if observer == null or entity == null:
		return 1.0

	var distance := observer.world_position().distance_to(entity.world_position())
	var weight := entity.priority

	for behaviour in entity.behaviours:
		var piece := behaviour as HungryPieceNet

		if piece != null:
			# Square root, so a thousand-mass monster is thirty times a crumb rather than
			# a thousand times it — enough to win a tie, not enough to starve everything
			# else on the screen.
			weight *= 1.0 + sqrt(maxf(0.0, float(piece.net_mass))) * 0.05
			break

	return weight / (1.0 + distance * 0.01)


func describe() -> Dictionary:
	var out := super.describe()
	out["base_extent"] = base_extent
	out["reference_radius"] = reference_radius
	return out
