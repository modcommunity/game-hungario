@tool
class_name HungryRider
extends Node2D

## The avatar sitting on top of a monster.
##
## [b]This is the join between dot-user-avatar and dot-cloud, and it is the whole reason
## an avatar is a document of ids.[/b] The server validated this player's rider without
## holding any art; the client turns the same ids into something to look at, through
## [DotAvatarCatalogue], which asks dot-cloud when there is a dot-cloud and falls back to
## the build when there is not.
##
## [b]Two paths, and both are real.[/b] [method DotAvatarBuilder.plan] works out which
## part goes in which slot, in what order, with which colours and which have fallen back —
## pure logic over ids, no scene touched, so it is the same answer on a headless server as
## in a browser. Where that plan names a scene this instantiates it. Where it does not,
## the part is [i]drawn[/i] from its id and its colours: this project ships no art, the
## same way dot-ui ships none, and a dev-textured rider that always appears beats a real
## one that appears only once a CDN is configured.
##
## A player you cannot see is a competitive advantage, so the placeholder is not optional.

const CHANNEL := "hungry.rider"

## The document being worn. Set through [method wear].
var avatar: DotAvatar = null

var schema: DotAvatarSchema = null

## How content ids become scenes. Shared, because it caches.
var catalogue: DotAvatarCatalogue = null

## What [method DotAvatarBuilder.plan] worked out. Kept so [method _draw] can use it.
var _steps: Array[DotAvatarBuilder.Step] = []

## slot -> the [Node2D] built for it, for the slots whose content resolved.
##
## Kept rather than re-derived from the children, because [method resize] runs for every
## player on screen and walking the children to work out which one is the hat is a search
## for something already known.
var _built: Dictionary = {}

## slot -> the [DotAvatarBuilder.Step] it came from, so a resize can re-dress it.
var _step_of: Dictionary = {}

## Radius the rider is drawn at. The monster sets this as it grows.
var scale_radius: float = 18.0


static func make(p_schema: DotAvatarSchema, p_catalogue: DotAvatarCatalogue) -> HungryRider:
	var rider := HungryRider.new()
	rider.name = "Rider"
	rider.schema = p_schema
	rider.catalogue = p_catalogue
	return rider


## Dresses the rider. Safe to call repeatedly with the same document.
func wear(document: DotAvatar) -> void:
	if document == null or schema == null:
		return

	# The digest is sixteen characters over the sorted slots, parts and quantised
	# colours, which is exactly the question being asked here: is this the same avatar?
	# Comparing documents field by field would be the same check written out longer.
	if avatar != null and avatar.digest() == document.digest():
		return

	avatar = document
	_rebuild()


func _rebuild() -> void:
	for child in get_children():
		child.queue_free()

	_built.clear()
	_step_of.clear()
	_steps = DotAvatarBuilder.plan(avatar, schema, catalogue)

	for step in _steps:
		if step.scene_path == "":
			continue

		var packed: Variant = load(step.scene_path)

		if not (packed is PackedScene):
			continue

		var instance: Variant = (packed as PackedScene).instantiate()

		# A 2D game takes 2D content. [method DotAvatarBuilder.apply] builds a Node3D rig
		# and is not usable here — which is why only the *plan* is shared, and why this
		# checks rather than casting: a 3D part in a 2D catalogue is a content mistake and
		# should be a missing hat, not a crash.
		if not (instance is Node2D):
			(instance as Node).queue_free()
			continue

		var node := instance as Node2D
		node.z_index = clampi(step.layer - 50, -20, 20)
		add_child(node)
		_built[step.slot] = node
		_step_of[step.slot] = step
		_dress(node, step)

	queue_redraw()


## Hands a built part its colours and its size.
##
## [b]The whole contract between this game and its avatar content[/b], and it is
## duck-typed: a part that does not answer `hungry_dress` is still shown, just untinted
## and at whatever size it was authored. That is a content mistake that should look wrong
## rather than crash, because content is authored by people who are not looking at this
## code — and because the same pack has to keep working when this method grows an
## argument.
func _dress(node: Node2D, step: DotAvatarBuilder.Step) -> void:
	if node.has_method(&"hungry_dress"):
		node.call(&"hungry_dress", step.colours, scale_radius)


## Slots being built from real content rather than drawn.
func built_slots() -> int:
	return _built.size()


## Slots being drawn rather than instantiated. For a diagnostic, and for the self-test.
func drawn_slots() -> int:
	var count := 0

	for step in _steps:
		if not _built.has(step.slot):
			count += 1

	return count


func _draw() -> void:
	if _steps.is_empty():
		return

	var unit := maxf(4.0, scale_radius)

	for step in _steps:
		if _built.has(step.slot):
			continue

		_draw_part(step, unit)


## Re-sizes the rider. Called by the renderer as the monster grows.
##
## Guarded on a real change rather than done unconditionally: the renderer writes this
## every frame for every player on screen, and a monster's radius changes by a fraction of
## a pixel between most frames. Below a pixel there is nothing to redraw.
func resize(radius: float) -> void:
	if absf(radius - scale_radius) < 0.5:
		return

	scale_radius = radius

	for slot in _built.keys():
		var node: Node2D = _built[slot]
		var step: DotAvatarBuilder.Step = _step_of.get(slot)

		if node != null and is_instance_valid(node) and step != null:
			_dress(node, step)

	queue_redraw()


## Draws one part from its id and its colours.
##
## Deliberately crude and deliberately deterministic: the shape comes from the slot and
## the id, so two clients drawing the same document draw the same rider, and a part whose
## content has not downloaded still reads as that part rather than as a grey blob.
func _draw_part(step: DotAvatarBuilder.Step, unit: float) -> void:
	var primary := _colour(step, 0, Color(0.95, 0.95, 0.98))
	var secondary := _colour(step, 1, Color(0.15, 0.16, 0.20))
	var shown := step.resolved.id if step.resolved != null else &"?"

	match step.slot:
		&"trail":
			# Behind everything, and only a hint: a trail that reads clearly at this size
			# would cover the monster it is riding.
			for i in range(3):
				var back := Vector2(-unit * (0.7 + 0.45 * float(i)), 0.0)
				draw_circle(back, unit * (0.34 - 0.08 * float(i)), Color(
					primary.r, primary.g, primary.b, 0.30 - 0.08 * float(i)
				))

		&"body":
			if shown == &"rider_blob":
				draw_circle(Vector2.ZERO, unit * 0.62, primary)
			elif shown == &"rider_spike":
				var points := PackedVector2Array()
				for i in range(10):
					var angle := TAU * float(i) / 10.0
					var reach := unit * (0.72 if (i % 2) == 0 else 0.36)
					points.append(Vector2.from_angle(angle) * reach)
				draw_colored_polygon(points, primary)
			else:
				draw_circle(Vector2.ZERO, unit * 0.52, primary)

			# Eyes, because a monster with a face on it is instantly readable as
			# somebody's monster rather than as a coloured circle.
			var eye := unit * 0.15
			draw_circle(Vector2(-unit * 0.20, -unit * 0.12), eye, secondary)
			draw_circle(Vector2(unit * 0.20, -unit * 0.12), eye, secondary)

		&"hat":
			var brim := unit * 0.62
			draw_rect(
				Rect2(Vector2(-brim, -unit * 0.62), Vector2(brim * 2.0, unit * 0.12)),
				primary
			)

			if shown == &"hat_crown":
				var spikes := PackedVector2Array([
					Vector2(-brim, -unit * 0.62),
					Vector2(-brim * 0.5, -unit * 1.05),
					Vector2(0.0, -unit * 0.72),
					Vector2(brim * 0.5, -unit * 1.05),
					Vector2(brim, -unit * 0.62),
				])
				draw_colored_polygon(spikes, primary)
			else:
				draw_rect(
					Rect2(
						Vector2(-brim * 0.6, -unit * 0.95),
						Vector2(brim * 1.2, unit * 0.36)
					),
					primary
				)


func _colour(step: DotAvatarBuilder.Step, channel: int, fallback: Color) -> Color:
	if channel >= step.colours.size():
		return fallback

	var value: Variant = step.colours[channel]
	return value if value is Color else fallback


func describe() -> Dictionary:
	return {
		"avatar": avatar.digest() if avatar != null else "",
		"steps": _steps.size(),
		"built": _built.size(),
		"drawn": drawn_slots(),
	}
