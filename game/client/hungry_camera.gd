@tool
class_name HungryCamera
extends Dot2DCameraRig

## Frames a monster: the whole set of it, not one piece.
##
## [Dot2DCameraRig] follows a [Node2D] and zooms with a [Dot2DController]'s radius, which
## is exactly right for a game where a player is one entity. Here a player is a set, so
## two things change and nothing else does:
##
## - [b]It follows the mass-weighted centroid.[/b] The plain average of a huge piece and a
##   speck is nowhere the player is looking; the weighted one is where their mass is.
## - [b]It frames the spread, not a radius.[/b] After a burst the pieces can be most of a
##   screen apart, and a camera zoomed for the biggest of them shows a player half of
##   their own monster.
##
## Both come off [HungryMonster], and both are supplied through a [Callable] rather than a
## reference, so this file names nothing that has to exist for a camera to work.


## `func() -> HungryMonster`. What to frame. Returning null leaves the camera where it is.
var monster_source: Callable = Callable()

## The node the rig follows, moved to the centroid every frame.
##
## A node rather than a position because [Dot2DCameraRig] follows a [Node2D] and smooths
## toward it; feeding it a position directly would mean reimplementing the smoothing.
var _anchor: Node2D = null


static func framing(source: Callable, arena: Dot2DArena) -> HungryCamera:
	var camera := HungryCamera.new()
	camera.name = "Camera"
	camera.monster_source = source
	camera.follow_sec = 0.10
	camera.zoom_with_size = true
	# Framing the spread rather than a body means the reference is bigger than a rig
	# following one entity would use, or a lone monster starts fully zoomed in.
	camera.reference_radius = 120.0
	camera.base_zoom = 1.0
	camera.zoom_exponent = 0.5
	camera.min_zoom = 0.16
	camera.max_zoom = 1.6
	camera.zoom_sec = 0.45
	camera.clamp_to_arena = true
	camera.bind_arena(arena)
	return camera


func _ready() -> void:
	super._ready()

	if Engine.is_editor_hint():
		return

	_anchor = Node2D.new()
	_anchor.name = "Anchor"
	add_sibling.call_deferred(_anchor)
	follow(_anchor)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	var monster := _monster()

	if monster != null and monster.alive and _anchor != null \
			and is_instance_valid(_anchor):
		_anchor.global_position = monster.centre()

	super._process(delta)


func _monster() -> HungryMonster:
	if not monster_source.is_valid():
		return null

	var value: Variant = monster_source.call()
	return value as HungryMonster if value is HungryMonster else null


## The radius the zoom is derived from: the whole set's spread.
func _target_radius() -> float:
	var monster := _monster()

	if monster == null or not monster.alive:
		return 0.0

	return monster.spread_radius()
