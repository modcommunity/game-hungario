extends Node

const HungryWorld := preload("hungry_world.gd")

## Where a dead monster's owner looks.
##
## [b]Until this existed the camera stayed exactly where the monster died.[/b]
## `HungryCamera` follows an anchor at the mass-weighted centroid and, when there is
## nothing to follow, leaves the camera where it is — so the seconds between being eaten
## and coming back are spent looking at the patch of arena that ate you, while the game
## happens somewhere else.
##
## [b]A 2D world is the XZ plane, which is what makes this four lines rather than a
## second addon.[/b] dot-npc settled that convention and everything downstream inherited
## it; `DotSpectatorManager.camera_2d_of` gives a position and a facing back, so nothing
## here needs a 3D camera or a second code path.
##
## [b]The policy is the whole point, and this game's is its own.[/b] Hungario is a
## free-for-all, so "your own team only" would restrict the camera to a team of one and
## mean nothing — it is 0. But a living player may **not** watch, and that one is not a
## formality: this is a game where knowing where the biggest monster is standing is the
## entire skill, and a second monitor showing it would be worth more than playing well.

const CHANNEL := "hungry.spectate"

var world: HungryWorld = null

var manager: DotSpectatorManager = null


func setup(p_world: HungryWorld) -> DotResult:
	world = p_world

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = world.is_authority
	manager.rules = _rules()
	manager.participants_fn = _participants
	# The side they are actually on, not a constant.
	#
	# dot-spectate keys teams by [code]int[/code] and treats 0 as "no team". A hardcoded
	# 1 made everybody — including somebody on the spectator side — a team-mate of
	# everybody, which is what `force_camera` reads as permission to watch. The stack is
	# built before anything can spectate, and 0 is the honest answer while it is not.
	manager.team_fn = func(key: String) -> int:
		return world.player_stack.team_index_of(key) if world.player_stack != null else 0
	manager.alive_fn = _alive
	manager.pose_fn = _pose_of
	add_child(manager)

	var res := manager.setup()
	if not res.ok:
		return res.wrap("hungario spectate")

	if not world.player_died.is_connected(_on_died):
		world.player_died.connect(_on_died)
	if not world.player_spawned.is_connected(_on_spawned):
		world.player_spawned.connect(_on_spawned)

	return DotResult.success(null)


func _rules() -> DotSpectatorRules:
	var rules := DotSpectatorRules.new()

	# A free-for-all has no sides, so restricting the camera to one restricts it to a
	# team of one. What matters here is the OTHER setting.
	rules.force_camera = 0

	# Off, and it is the important line in this file. Knowing where the biggest monster
	# is standing is the whole skill of this game, and a living player with a camera on
	# somebody else has it for free.
	rules.allow_while_alive = false

	# No roaming for the same reason: a free camera over a 2D arena is the entire map.
	rules.allow_roaming = false

	# Dead monsters are gone rather than lying about, so there is nothing to cycle to.
	rules.cycle_includes_dead = false

	rules.death_cam_ticks = int(1.0 * float(world.tick_rate))
	rules.freeze_cam_ticks = 0
	rules.history_ticks = 4 * world.tick_rate
	return rules


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Array = world.player_ids()
	ids.sort()
	for id: Variant in ids:
		out.append(str(id))
	return out


func _alive(key: String) -> bool:
	var monster := world.monster_for(key.to_int())
	return monster != null and monster.alive


## A monster's centroid, as a transform on the XZ plane.
##
## The centroid rather than a piece: after a burst the pieces are most of a screen
## apart, and a camera on the biggest of them shows a player half of somebody's monster
## — which is the same reason `HungryCamera` frames the spread.
func _pose_of(key: String) -> Transform3D:
	var monster := world.monster_for(key.to_int())
	if monster == null or not monster.alive:
		return Transform3D.IDENTITY
	var at := monster.centre()
	return Transform3D(Basis.IDENTITY, Vector3(at.x, 0.0, at.y))


func tick(_delta: float) -> void:
	if manager != null:
		manager.advance(world.current_tick())


## Where a viewer's camera should be, in world units. Null when they are not watching.
##
## Returns a [Variant] deliberately: "not spectating" and "spectating a point at the
## origin" are different answers, and a [Vector2] alone cannot tell them apart — which
## in a game whose arena is centred on the origin is the difference between a working
## camera and one pinned to the middle of the map.
func camera_position(viewer: int) -> Variant:
	if manager == null or not manager.is_spectating(str(viewer)):
		return null
	var flat := manager.camera_2d_of(str(viewer))
	return flat[0] as Vector2


func is_spectating(viewer: int) -> bool:
	return manager != null and manager.is_spectating(str(viewer))


func watching(viewer: int) -> int:
	if manager == null:
		return 0
	var target := manager.view(str(viewer)).target
	return target.to_int() if target != "" else 0


func next_target(viewer: int) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.next_target(str(viewer))


func _on_died(player_id: int, killer_id: int) -> void:
	if manager == null:
		return
	var monster := world.monster_for(player_id)
	var at := monster.centre() if monster != null else Vector2.ZERO
	manager.on_death(
		str(player_id),
		Vector3(at.x, 0.0, at.y),
		str(killer_id) if killer_id != 0 else "",
		world.current_tick()
	)


func _on_spawned(player_id: int) -> void:
	if manager != null:
		manager.on_spawn(str(player_id))


func forget(player_id: int) -> void:
	if manager != null:
		manager.on_leave(str(player_id))


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])
	return manager.describe_lines()
