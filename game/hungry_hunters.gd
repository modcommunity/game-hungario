class_name HungryHunters
extends Node

## NPC monsters that roam the arena, eat what they can and run from what they cannot.
##
## [b]Three addons, and each is here for the half this game would otherwise get wrong.[/b]
##
## - **dot-npc** is the catalogue, the population budget, the per-kind cap and — the part
##   that matters — the *perception*. A hunter that called "who is nearest" every tick is
##   the classic broken NPC, and both of its failures are reachable in ten seconds: two
##   players a hundred units apart make it turn back and forth for ever, and one who moves
##   out of range makes it forget instantly and wander off mid-chase. [DotNpcSenses]
##   acquires at one threshold, drops at a weaker one, and keeps chasing for a grace period
##   measured from the **last sighting**.
## - **dot-npc-ai** is the decision: a state machine, a wander that wanders rather than
##   re-rolling, separation so a pack at one player does not become a tower, and Quake III's
##   characteristics — a reaction time, so a hunter cannot commit on the tick it first sees
##   you. There is no difficulty setting; the character is the difficulty, per hunter.
## - **dot-npc-ai-director** decides *when*. Hunters do not arrive on a timer: the director
##   builds up, sustains, fades and relaxes against an estimate of what the players are
##   experiencing, which in this game is being chased rather than being shot.
##
## [b]What this game supplies is what none of the three can know.[/b] A hunter's mass and
## the eat ratio are [HungryRules]'; the candidate list is the monsters; the stress is
## whether somebody is being hunted. Everything else is the addons'.
##
## [b]Hunters are not dot-net entities, and that is deliberate.[/b] A monster's piece is:
## it is predicted, reconciled and interest-managed, all of which a player's own input
## needs. A hunter is server-authoritative and unpredicted — dot-props' argument about a
## rigid body, reached from the other side — and there are at most a handful, so one
## reliable event a few times a second is cheaper than an entity's declarations and does
## not put a second id space beside the piece ids.

const CHANNEL := "hungry.hunters"

## The scene every hunter is. Bare: a hunter has no art and is drawn by the client from
## its kind and its radius, exactly as a piece of food is.
## The scene every hunter is. Bare: a hunter has no art and is drawn by the client from
## its kind and its radius, exactly as a piece of food is.
##
## [b]In `game/` and `hungry_`-prefixed, and that is a deployment constraint.[/b]
## dot-server-setup-test vendors each built-in game's `game/` and `scenes/` into ONE
## directory — a `.tscn` names its scripts by absolute `res://` path and there is no
## relative form — and `content/` is not among the directories it copies. A scene under
## `content/` therefore mounts in a developer checkout and is missing in the deployment,
## where the only symptom is dot-npc refusing every spawn with "that NPC's content is not
## loaded on this server", which is a correct answer to a question nobody meant to ask.
const HUNTER_SCENE := "res://game/hungry_hunter_body.tscn"

## The brain, named by PATH. See the note at the top of `hunter_brain.gd`.
const HUNTER_BRAIN := "res://game/hungry_hunter_brain.gd"

## Candidate id prefix for a player, so a hunter's target id can be turned back into one.
##
## [b]A prefix rather than a bare number, because a candidate id is a [StringName] and
## this game has two id spaces in it.[/b] A hunter's target is a player today and could be
## another hunter tomorrow; an id that said only "7" would be ambiguous the moment it was.
const PLAYER_PREFIX := "p"

## How often a hunter's state goes out, in ticks.
##
## [b]Not every tick.[/b] Six hunters at 60 Hz is 360 reliable events a second for
## something that moves slowly and is drawn interpolated. Five a second is enough to draw
## smoothly from and is two orders of magnitude less traffic than a piece.
const BROADCAST_EVERY := 12


## A hunter appeared, moved, or is gone. Both ends.
signal hunter_changed(hunter_id: int)

## A hunter ate somebody's piece. Server side.
signal piece_hunted(player_id: int, mass: float)


var spawner: DotNpcSpawner = null
var director: DotNpcDirector = null

## The world this hunts in. Set before [method setup].
var world: HungryWorld = null

## Whether this end actually runs hunters. A client mirrors and never spawns.
var authoritative: bool = false

## hunter id -> {"kind": StringName, "at": Vector2, "radius": float, "alive": bool}
##
## [b]Both ends have this and only the authority has a spawner.[/b] What a client holds is
## a drawing, and every property that makes a hunter what it is comes out of
## [method catalogue] — which both ends build from this file. Nothing about a stalker
## travels except that it is a stalker and where it is.
var _hunters: Dictionary = {}

## instance id -> wire id, and back. Authority only.
##
## The wire id is this class's own, because `Object.get_instance_id()` means nothing on the
## receiving machine — the same reason [RoomProps] keeps a place id.
var _wire_of_instance: Dictionary = {}
var _instance_of_wire: Dictionary = {}
var _next_wire_id: int = 1

var _tick: int = 0
var _static_catalogue: DotNpcCatalogue = null


# --- The catalogue ---------------------------------------------------------

## What a hunter can be. Three kinds, and each is a different problem for a player.
##
## Built in code rather than loaded from JSON, for [RoomProps]' reason: both ends need to
## agree exactly, and a file one end could have a different version of is the same silent
## mismatch as a different arena size.
static func catalogue() -> DotNpcCatalogue:
	var out := DotNpcCatalogue.new()

	# Small, fast, and only a threat to somebody who has just spawned or just split. The
	# thing that makes splitting a commitment rather than a free move.
	_add(out, &"swarmling", "Swarmling", 45.0, 320.0, 900.0, 1, 30.0)

	# The middle one. Fast enough to catch a careless player and small enough to be worth
	# eating, which is what makes hunting them a strategy rather than a hazard.
	_add(out, &"stalker", "Stalker", 220.0, 240.0, 1400.0, 3, 90.0)

	# Slow and enormous. Nothing about outrunning it is hard; the problem is that it is
	# sitting on the food.
	_add(out, &"lurker", "Lurker", 900.0, 120.0, 1100.0, 8, 220.0)

	return out


static func _add(
	into: DotNpcCatalogue,
	id: StringName,
	display: String,
	mass: float,
	speed: float,
	sight: float,
	cost: int,
	health: float
) -> void:
	var def := DotNpcDef.make(id, HUNTER_SCENE)
	def.display_name = display
	def.brain_script_path = HUNTER_BRAIN
	def.category = &"hunter"
	def.faction = &"hunter"
	def.cost = cost
	def.max_health = health
	def.sight_range = sight
	# Hearing is deliberately shorter than sight in an arena where nothing is opaque: it
	# is what lets a hunter notice somebody who split behind it.
	def.hearing_range = sight * 0.4
	# [b]Off, and it has to be for a 2D NPC.[/b] There is no 3D physics world to cast
	# through; dot-npc answers "clear" rather than blinding it, and saying so here makes
	# that a decision rather than a fallback nobody noticed. This arena has no walls, so
	# there is nothing to be occluded by in any case.
	def.require_line_of_sight = false
	def.meta = {"mass": mass, "speed": speed}
	into.add(def)


static func shared_catalogue() -> DotNpcCatalogue:
	return _shared if _shared != null else _make_shared()


static var _shared: DotNpcCatalogue = null

static func _make_shared() -> DotNpcCatalogue:
	_shared = catalogue()
	return _shared


## The catalogue's ids, sorted as [String], so an index can travel instead of a name.
##
## Sorted as String and not as StringName: `Array.sort()` on a StringName compares interned
## pointers, and dot-net shipped exactly that bug — two peers gave one message type two
## different ids and hashed two different schemas.
static func wire_ids() -> PackedStringArray:
	var out := PackedStringArray()

	for def in shared_catalogue().npcs:
		out.append(String(def.id))

	out.sort()
	return out


static func index_of(id: StringName) -> int:
	return wire_ids().find(String(id))


static func id_at(index: int) -> StringName:
	var ids := wire_ids()
	return StringName(ids[index]) if index >= 0 and index < ids.size() else &""


static func mass_of(id: StringName) -> float:
	var def := shared_catalogue().get_npc(id)
	return float(def.meta.get("mass", 0.0)) if def != null else 0.0


static func radius_of(id: StringName) -> float:
	# Drawn from the mass, exactly as a monster's piece is — so a hunter that is half the
	# mass of your monster looks half the area of it, which is the one comparison a player
	# makes constantly and the whole reason the rings exist.
	return sqrt(maxf(mass_of(id), 1.0) / PI) * 4.0


# --- Lifecycle -------------------------------------------------------------

## Builds the spawner and the director on the authority, and nothing on a client.
func setup(p_authoritative: bool, p_world: HungryWorld) -> DotResult:
	authoritative = p_authoritative
	world = p_world

	if not authoritative:
		return DotResult.success(null)

	var limits := DotNpcLimits.new()
	limits.world_budget = 40
	limits.per_kind_cap = 12
	limits.spawn_interval = 0.0
	# [b]No navigable-spawn requirement: this arena has no navigation graph and does not
	# need one.[/b] dot-npc is explicit that "no navigation" is not the same as "off the
	# navigation" — a flat arena where every point is reachable is exactly the case the
	# flag exists to allow, and requiring a graph would refuse every spawn on a game that
	# has no walls.
	limits.require_navigable_spawn = false
	# Longer than the addon's default, because being chased across an arena is the
	# experience and a hunter reclaimed after six seconds of it is a hunter that gives up.
	limits.reclaim_grace = 25.0

	var problem := limits.validate()

	if not problem.ok:
		return problem.wrap("The hunter limits are not usable")

	spawner = DotNpcSpawner.new()
	spawner.name = "Spawner"
	spawner.catalogue = shared_catalogue()
	spawner.limits = limits
	spawner.authoritative = true
	# One flag says this spawner serves a 2D world; `spawn_group` and the director both
	# read it, so neither needs a 2D twin.
	spawner.two_dimensional = true
	add_child(spawner)

	spawner.spawned.connect(_on_spawned)
	spawner.removed.connect(_on_removed)

	return _build_director()


## The director, and the one number in it that is this game rather than Left 4 Dead.
func _build_director() -> DotResult:
	var rules := DotNpcDirectorRules.new()
	# An arena is not a corridor: there is no critical path to spawn ahead along, and
	# "behind the party" means nothing when the party is scattered. So the distances are
	# the arena's and `spawn_ahead` is zero, which turns the placement into "far enough
	# away not to be a jump scare, near enough to arrive".
	rules.spawn_min_distance = 600.0
	rules.spawn_max_distance = 2200.0
	rules.spawn_ahead = 0.0
	rules.spawn_out_of_sight = false
	rules.behind_fraction = 0.0
	rules.peak_per_player = 6.0
	rules.build_up_per_player = 3.0
	rules.relax_per_player = 1.0
	rules.absolute_cap = 30
	rules.spawn_burst = 2
	rules.spawn_interval = 1.5
	rules.reclaim_interval = 4.0
	# [b]Zero would mean "never" here and "every tick" for `spawn_interval`.[/b] Two
	# settings named the same way meaning opposite things at zero is the kind of
	# difference nobody reads twice, and dot-npc-ai-director documents it — so this is
	# set explicitly rather than left.
	rules.relax_distance = 1200.0
	rules.stress_decay = 0.10
	rules.stress_per_damage = 0.9
	rules.stress_per_threat = 0.05
	rules.stress_threat_radius = 500.0

	var problem := rules.validate()

	if not problem.ok:
		return problem.wrap("The director rules are not usable")

	director = DotNpcDirector.new()
	director.name = "Director"
	director.rules = rules
	director.spawner_ref = DotNodeRef.of_path(^"../Spawner")
	# Round-robin through this list, so the mix is exact rather than approached — a random
	# pick from three gives three lurkers in a row often enough for a player to notice and
	# conclude the director is broken.
	director.population = [&"swarmling", &"stalker", &"swarmling", &"lurker"]
	director.enabled = false
	add_child(director)

	# Somewhere to put them. A ring rather than a grid: an arena is a square and its
	# corners are where nobody goes, so a grid spends most of its points on places a
	# player never is — and `spawn_min_distance` would reject them anyway.
	_seed_spawn_points()

	return DotResult.success(null)


func _seed_spawn_points() -> void:
	if world == null or world.arena == null:
		return

	var bounds := world.arena.bounds
	var centre := bounds.get_center()
	var points := PackedVector3Array()

	for ring in [0.35, 0.6, 0.85]:
		for step in range(12):
			var angle := TAU * float(step) / 12.0
			var at := centre + Vector2(cos(angle), sin(angle)) \
				* bounds.size * 0.5 * float(ring)
			points.append(DotNpcInstance.to_plane(at))

	director.spawn_points = points


## Whether the director is releasing hunters.
##
## Off by default, and an operator's decision. A mode that is about eating food and a mode
## that is about being hunted are different games, and turning one into the other silently
## because an addon was installed is exactly what a `cvar` exists to prevent.
func set_enabled(on: bool) -> void:
	if director != null:
		director.enabled = on

	if not on and spawner != null:
		spawner.clear_all()


func is_enabled() -> bool:
	return director != null and director.enabled


# --- The tick --------------------------------------------------------------

## One authoritative step. Called from the module's tick, inside the netcode's.
func tick(delta: float) -> void:
	if not authoritative or spawner == null or world == null:
		return

	_tick += 1

	# [b]The candidate list is built once per tick, before the hunters run.[/b] Once per
	# tick and not once per hunter, because thirty hunters each building their own list of
	# eight players is two hundred and forty allocations a tick for a list that does not
	# differ between them. Before rather than after, because a list built at the end of a
	# tick is a list of where everybody *was*, which is the one-tick lag the ordering
	# exists to avoid. game-playground reached the same two sentences from the other side.
	spawner.set_candidates(_candidates())
	_report_stress()

	spawner.tick(delta)
	director.tick(delta)

	_resolve_eating()

	if _tick % BROADCAST_EVERY == 0:
		_broadcast_all()


## Everybody a hunter might notice, as dot-npc's candidates.
##
## A **monster**, not a piece. A hunter chasing one fragment of a split player walks past
## the other seven, and the mass that decides whether it may eat at all is the set's.
func _candidates() -> Array:
	var out: Array = []

	for monster in world.monsters():
		if not monster.alive or monster.piece_count() == 0:
			continue

		out.append(DotNpcSenses.Candidate.new(
			StringName("%s%d" % [PLAYER_PREFIX, monster.id]),
			DotNpcInstance.to_plane(monster.centre()),
			&"player",
			# Loudness: a bigger monster is harder to miss. It is what makes a hunter
			# notice the leader from across the arena and a newly spawned player not at
			# all, which is the pacing this game wants and costs one number.
			clampf(monster.mass() / 4000.0, 0.0, 1.0)
		))

	return out


## What the director measures its phases against.
##
## [b]The stress is being hunted, not being shot.[/b] The director's own model is damage
## and proximity to a threat; this game has neither in the sense it means, so what is
## reported is the thing a player here actually experiences — how close the nearest hunter
## that could eat them is, expressed as the "health" the director understands. A player
## with nothing near them is at full health and the director relaxes.
func _report_stress() -> void:
	for monster in world.monsters():
		if not monster.alive or monster.piece_count() == 0:
			director.forget_player(StringName("%s%d" % [PLAYER_PREFIX, monster.id]))
			continue

		director.report_player(
			StringName("%s%d" % [PLAYER_PREFIX, monster.id]),
			DotNpcInstance.to_plane(monster.centre()),
			_pressure_on(monster)
		)


## One minus how hunted somebody is, in the range the director calls health.
func _pressure_on(monster: HungryMonster) -> float:
	var worst := 0.0
	var here := monster.centre()
	var ratio := eat_ratio()

	for entry in _hunters.values():
		var state: Dictionary = entry

		if not bool(state["alive"]):
			continue

		var kind: StringName = state["kind"]

		# Only something that could actually eat them. A lurker that a player is about to
		# swallow is not pressure, and counting it would make the director back off
		# exactly when the player is winning.
		if mass_of(kind) < monster.mass() * ratio:
			continue

		var distance: float = here.distance_to(state["at"])
		worst = maxf(worst, clampf(1.0 - distance / 1800.0, 0.0, 1.0))

	return 1.0 - worst


# --- Eating ----------------------------------------------------------------

## A hunter and a monster meeting. The same ratio everything else in this game uses.
##
## [b]Resolved here rather than in [HungryWorld], and that is the one seam worth
## defending.[/b] The world's eat check is a spatial-hash query over eleven hundred things
## and runs on every piece every tick; hunters are a handful and are not in that grid.
## Putting them in it would make every food lookup pay for a feature most servers have
## turned off.
func _resolve_eating() -> void:
	var ratio := eat_ratio()

	for wire_id in _hunters.keys():
		var state: Dictionary = _hunters[wire_id]

		if not bool(state["alive"]):
			continue

		var kind: StringName = state["kind"]
		var hunter_mass := mass_of(kind)
		var at: Vector2 = state["at"]
		var reach: float = state["radius"]

		for monster in world.monsters():
			if not monster.alive:
				continue

			for piece in monster.pieces:
				if at.distance_to(piece.position()) > reach + piece.radius():
					continue

				if hunter_mass >= piece.mass() * ratio:
					# The hunter eats the piece. Reported rather than done here: what
					# "lose a piece" means — dying, splitting, respawning — is the
					# world's, exactly as [DotTimer] never moves a player.
					piece_hunted.emit(monster.id, piece.mass())
					world.devour_piece(piece.id)
					break
				elif piece.mass() >= hunter_mass * ratio:
					# The player eats the hunter. Through the spawner's own death path,
					# so the population budget, the director's count and the removal
					# event all agree — a hunter deleted by hand would be one the
					# director never replaced.
					var instance_id := int(_instance_of_wire.get(wire_id, 0))
					spawner.report_death(instance_id, StringName(str(monster.id)))
					world.feed_player(monster.id, hunter_mass)
					break


# --- The books -------------------------------------------------------------

func _on_spawned(npc: DotNpcInstance) -> void:
	var wire_id := _next_wire_id
	_next_wire_id += 1

	# The brain reaches this object through `meta`, which is dot-npc's documented hook for
	# "anything the game keeps with an NPC". A brain that named [HungryHunters] directly
	# would be a brain that cannot be delivered in a pack.
	npc.meta["hunters"] = self

	_wire_of_instance[npc.instance_id] = wire_id
	_instance_of_wire[wire_id] = npc.instance_id
	_hunters[wire_id] = {
		"kind": npc.def.id,
		"at": npc.position_2d(),
		"radius": radius_of(npc.def.id),
		"alive": true,
	}

	hunter_changed.emit(wire_id)


func _on_removed(npc: DotNpcInstance, _reason: StringName) -> void:
	var wire_id := int(_wire_of_instance.get(npc.instance_id, 0))

	if wire_id == 0:
		return

	_wire_of_instance.erase(npc.instance_id)
	_instance_of_wire.erase(wire_id)

	# Marked dead and kept for one broadcast rather than erased, so every client is told
	# it is gone. Erasing it here would simply stop mentioning it, and a client would draw
	# a hunter that no longer exists until something else happened to it.
	if _hunters.has(wire_id):
		(_hunters[wire_id] as Dictionary)["alive"] = false

	hunter_changed.emit(wire_id)


func _broadcast_all() -> void:
	for wire_id in _hunters.keys():
		var state: Dictionary = _hunters[wire_id]
		var instance_id := int(_instance_of_wire.get(wire_id, 0))
		var npc := spawner.get_npc(instance_id)

		if npc != null and npc.is_alive():
			state["at"] = npc.position_2d()

		hunter_changed.emit(int(wire_id))

	# The dead ones, once each. They have been announced now.
	for wire_id in _hunters.keys():
		if not bool((_hunters[wire_id] as Dictionary)["alive"]):
			_hunters.erase(wire_id)


# --- A client's mirror -----------------------------------------------------

## Takes a hunter's state the authority announced. Client side.
##
## [b]The id is adopted, never allocated.[/b] A receiving peer that numbered things itself
## gives the same hunter two names on two machines, and every count still matches — the bug
## dot-2d had to gain `Dot2DScatter.adopt` to fix.
func adopt(wire_id: int, kind: StringName, at: Vector2, radius: float, alive: bool) -> void:
	if not alive:
		_hunters.erase(wire_id)
		hunter_changed.emit(wire_id)
		return

	_hunters[wire_id] = {
		"kind": kind, "at": at, "radius": radius, "alive": true,
	}
	hunter_changed.emit(wire_id)


func forget_all() -> void:
	_hunters.clear()


# --- Reading ---------------------------------------------------------------

func hunters() -> Dictionary:
	return _hunters.duplicate()


## How many are actually in the arena.
##
## [b]Alive ones only, and the difference is not pedantry.[/b] A removed hunter is kept for
## exactly one broadcast so every client is told it has gone — erasing it here would simply
## stop mentioning it, and a client would draw a hunter that no longer exists for ever. So
## the dictionary briefly holds things that are not there, and everything that asks "how
## many" means the ones that are.
func count() -> int:
	var alive := 0

	for entry in _hunters.values():
		if bool((entry as Dictionary)["alive"]):
			alive += 1

	return alive


func state_of(wire_id: int) -> Dictionary:
	return (_hunters.get(wire_id, {}) as Dictionary).duplicate()


## Everything the authority holds, as `[wire_id, kind_index, at, radius, alive]` rows.
func wire_rows() -> Array:
	var out: Array = []

	for wire_id in _hunters.keys():
		var state: Dictionary = _hunters[wire_id]
		out.append([
			int(wire_id),
			index_of(state["kind"]),
			state["at"],
			float(state["radius"]),
			bool(state["alive"]),
		])

	return out


# --- What the brain asks ---------------------------------------------------

## The world's eat ratio. Asked for rather than copied into the brain.
func eat_ratio() -> float:
	if world == null or world.tunables == null or world.tunables.mass_rules == null:
		return 1.25

	return world.tunables.mass_rules.eat_ratio


## Where a candidate is, in dot-npc's plane. `Vector3.INF` when it has gone.
##
## [b]Infinity rather than zero for "gone".[/b] Zero is the middle of the arena, so a
## hunter whose target disconnected would sprint to the centre and mill about — which
## reads as a pathfinding bug and is a missing null check. game-playground's chaser
## learned the same lesson with a target's last position.
func position_of(candidate_id: StringName) -> Vector3:
	var monster := _monster_for(candidate_id)

	if monster == null or not monster.alive:
		return Vector3.INF

	return DotNpcInstance.to_plane(monster.centre())


## What a candidate weighs, for the ratio. Zero when it has gone.
func mass_of_candidate(candidate_id: StringName) -> float:
	var monster := _monster_for(candidate_id)
	return monster.mass() if monster != null and monster.alive else 0.0


## Whether a point is close enough to the wall that a wanderer should turn round.
func is_near_edge(at: Vector2) -> bool:
	if world == null or world.arena == null:
		return false

	var bounds := world.arena.bounds
	var margin := 300.0

	return at.x < bounds.position.x + margin or at.x > bounds.end.x - margin \
		or at.y < bounds.position.y + margin or at.y > bounds.end.y - margin


func _monster_for(candidate_id: StringName) -> HungryMonster:
	var text := String(candidate_id)

	if not text.begins_with(PLAYER_PREFIX) or world == null:
		return null

	var id := text.substr(PLAYER_PREFIX.length())
	return world.monster_for(id.to_int()) if id.is_valid_int() else null


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("hunters      %d (%s)" % [
		_hunters.size(), "on" if is_enabled() else "off"
	])

	if authoritative and director != null:
		out.append_array(director.describe_lines())

	return out
