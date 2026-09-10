extends "res://addons/dot_npc_ai/runtime/dot_npc_ai_brain.gd"

## What a hunter does: wander, chase what it can eat, run from what can eat it.
##
## [b]Extended by PATH, not by `class_name`, and that is not a style choice.[/b] A brain is
## named by [member DotNpcDef.brain_script_path], and a script inside a mounted dot-cloud
## pack cannot resolve a `class_name` — measured, and in the family's own CLAUDE.md. A
## brain that named a class could therefore only ever ship inside a build. This game's
## hunters do ship inside its build; they are written the way a delivered one would have to
## be, because a path that stopped working would stop working here first.
##
## [b]A state machine rather than a tree.[/b] dot-npc-ai ships both and says which is
## which: a tree is for an NPC whose decision is a priority list with reactive conditions,
## and a machine is for the many NPCs a tree is overkill for. A hunter has three states and
## the transitions between them are the whole design — WANDER when there is nobody,
## CHASE when there is somebody smaller, FLEE when there is somebody bigger — so the
## machine is the honest shape and the tree would be three leaves under a selector
## pretending to be a hierarchy.
##
## [b]The eat ratio is the transition, and it is the world's rather than a constant
## here.[/b] `HungryRules.eat_ratio` decides who eats whom and an operator can change it; a
## hunter with its own copy would chase things it cannot eat the moment somebody did, which
## reads as broken pathfinding rather than as a number that drifted. It is asked for
## through [HungryHunters], which is the one thing here that knows what a world is.

const STATE_WANDER := &"wander"
const STATE_CHASE := &"chase"
const STATE_FLEE := &"flee"

## What this hunter is worth, as mass. Read off the definition's `meta`.
var mass: float = 40.0

## How fast it moves, in units a second.
var speed: float = 160.0

## Where it is heading when it has nobody. An angle, wandered rather than re-rolled.
var _wander_angle: float = 0.0

## The world, so a hunter can ask what is near it. Set by [HungryHunters] through `meta`.
var _hunters: Object = null


func _build() -> void:
	if npc != null and npc.def != null:
		mass = float(npc.def.meta.get("mass", mass))
		speed = float(npc.def.meta.get("speed", speed))

	_hunters = npc.meta.get("hunters") if npc != null else null

	# Deterministic from the instance rather than `randf()`: two servers replaying the
	# same director decisions place and steer a wave identically, which is what makes a
	# horde reproducible in a suite. It is also the only reason a hunter that spawned in
	# the same place twice does not walk the same way twice.
	_wander_angle = float(npc.instance_id % 628) / 100.0 if npc != null else 0.0

	machine = DotNpcAiMachine.new()

	machine.add(
		DotNpcAiState.make(STATE_WANDER, _wander)
			.when(_sees_prey, STATE_CHASE)
			.when(_sees_predator, STATE_FLEE)
	)
	machine.add(
		DotNpcAiState.make(STATE_CHASE, _chase)
			.when(_sees_predator, STATE_FLEE)
			.when(func(_c: DotNpcAiContext) -> bool: return not _sees_prey(_c), STATE_WANDER)
	)
	machine.add(
		# [b]Fleeing has a floor as well as a condition.[/b] `after` is what stops a
		# hunter that is exactly on the ratio boundary flickering between CHASE and FLEE
		# every tick — which looks like a hunter having a fit and is the classic broken
		# NPC this family already documented in game-playground's chaser.
		DotNpcAiState.make(STATE_FLEE, _flee)
			.after(1.5, STATE_WANDER)
	)

	initial_state = STATE_WANDER


# --- States ----------------------------------------------------------------

func _wander(ctx: DotNpcAiContext) -> void:
	if npc == null or not npc.is_alive():
		return

	# Wandered, not re-rolled. A direction chosen fresh every tick is Brownian motion: it
	# averages to standing still, and a hunter that never goes anywhere is one players
	# never meet.
	_wander_angle = DotNpcAiSteering.wander(
		_wander_angle, 0.5, npc.instance_id + int(ctx.now * 4.0)
	)

	var heading := DotNpcAiSteering.angle_to_direction(_wander_angle)
	var here := npc.position()

	# Turned back at the wall rather than clamped there. A hunter pressed against an edge
	# with a heading into it is a hunter that never leaves the edge, and the arena's
	# corners would collect every hunter on the server.
	if _hunters != null and _hunters.has_method(&"is_near_edge"):
		if bool(_hunters.call(&"is_near_edge", DotNpcInstance.from_plane(here))):
			heading = DotNpcAiSteering.seek(here, Vector3.ZERO)
			_wander_angle = atan2(heading.z, heading.x)

	# Slower than a chase, because a hunter that patrols at full speed is one nobody can
	# outrun and one nobody can sneak up on either.
	steer_toward(here + heading * 200.0, speed * 0.45, ctx.delta)


func _chase(ctx: DotNpcAiContext) -> void:
	var goal := _target_position()

	if goal == Vector3.INF:
		return

	# `steer_with_spacing` rather than `steer_toward`: twelve hunters converging on one
	# player climb each other, and the one on top has a horizontal offset of nothing from
	# the one below — so it chases perfectly at a dead stop with every number about it
	# correct. dot-npc-ai found that and the separation is why this call exists.
	steer_with_spacing(goal, speed, ctx.delta, 90.0)


func _flee(ctx: DotNpcAiContext) -> void:
	var threat := _target_position()

	if threat == Vector3.INF:
		return

	var here := npc.position()
	steer_toward(here + DotNpcAiSteering.flee(here, threat) * 200.0, speed * 1.1, ctx.delta)


# --- Conditions ------------------------------------------------------------

## Whether what it is looking at is something it could eat.
##
## [b]Behind [method has_reacted], which is the gate every "act on what you see" branch
## belongs behind.[/b] An NPC that turns and commits on the tick it first perceives
## somebody is one no player can ever surprise, and Quake III's characteristics table
## exists because that is the difference between a bot and an opponent.
func _sees_prey(_ctx: DotNpcAiContext) -> bool:
	if not npc.has_target() or not has_reacted():
		return false

	var other := _target_mass()
	return other > 0.0 and mass >= other * _eat_ratio()


func _sees_predator(_ctx: DotNpcAiContext) -> bool:
	if not npc.has_target():
		return false

	# [b]No reaction gate on fleeing, deliberately.[/b] Reaction time is how long it takes
	# to decide to attack; running away from something that is eating you is a reflex, and
	# a hunter that stood still for a third of a second while being swallowed would read
	# as one that had not noticed.
	var other := _target_mass()
	return other > 0.0 and other >= mass * _eat_ratio()


func _target_position() -> Vector3:
	if _hunters == null or not _hunters.has_method(&"position_of"):
		return Vector3.INF

	return _hunters.call(&"position_of", npc.target_id)


## The world's ratio, asked for rather than kept.
func _eat_ratio() -> float:
	if _hunters == null or not _hunters.has_method(&"eat_ratio"):
		return 1.25

	return float(_hunters.call(&"eat_ratio"))


func _target_mass() -> float:
	# `mass_of_candidate`, not `mass_of`. The latter is a static that answers what a KIND
	# of hunter weighs; this asks what the thing it is looking at weighs. Two questions
	# one letter apart is exactly the sort of collision a duck-typed call cannot catch,
	# so the names are different rather than overloaded.
	if _hunters == null or not _hunters.has_method(&"mass_of_candidate"):
		return 0.0

	return float(_hunters.call(&"mass_of_candidate", npc.target_id))
