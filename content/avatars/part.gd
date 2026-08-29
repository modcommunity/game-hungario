@tool
extends Node2D

## One avatar part, drawn rather than modelled.
##
## [b]This file is content, not code.[/b] It ships inside `content/avatars/` in the build
## and it is also what [DotCloudPublisher] packages into the avatar pack, so at runtime
## there may be two copies of it on disk at different paths — one under `res://content/`
## and one under `res://dot_cloud/hungry_avatars/<version>/`. That is exactly what
## dot-cloud's version-namespaced mounting is for, and it is why this script has no
## `class_name`: a global identifier registered twice from two packs is a collision the
## engine resolves arbitrarily.
##
## It is deliberately a `_draw` call rather than a sprite. dot-2d-hungry ships no art, the
## same way dot-ui ships none, and a part that is a few polygons is a part that can be
## versioned, signed, downloaded and mounted at a realistic size without anybody having to
## produce a texture first. Swapping these for real ones changes nothing anywhere else:
## the contract is the scene root being a `Node2D` that answers `hungry_dress`.

## What to draw. A string rather than an enum because it crosses a pack boundary and an
## enum's numbering is a thing two versions of a file can disagree about.
@export var shape: String = "pip"

## Filled in from the avatar document's colour channels by [method hungry_dress].
@export var tint_a: Color = Color(0.90, 0.92, 0.96)
@export var tint_b: Color = Color(0.14, 0.15, 0.19)

## Radius the part is drawn at, in world units. The monster sets it as it grows.
@export_range(2.0, 400.0, 0.5) var unit: float = 18.0


## The whole contract between a game and its avatar content.
##
## [param colours] is the avatar document's channels for this slot, already quantised to
## eight bits; [param size] is how big to draw. Duck-typed on purpose: a part that does
## not implement it is still shown, just not tinted or resized, which is a content
## mistake that should look wrong rather than crash.
func hungry_dress(colours: Array, size: float) -> void:
	if colours.size() > 0 and colours[0] is Color:
		tint_a = colours[0]

	if colours.size() > 1 and colours[1] is Color:
		tint_b = colours[1]

	unit = maxf(2.0, size)
	queue_redraw()


func _draw() -> void:
	match shape:
		"blob":
			draw_circle(Vector2.ZERO, unit * 0.62, tint_a)
			_eyes()

		"spike":
			var points := PackedVector2Array()
			for i in range(10):
				var angle := TAU * float(i) / 10.0
				var reach := unit * (0.72 if (i % 2) == 0 else 0.36)
				points.append(Vector2.from_angle(angle) * reach)
			draw_colored_polygon(points, tint_a)
			_eyes()

		"cap":
			_brim()
			draw_rect(
				Rect2(
					Vector2(-unit * 0.37, -unit * 0.95),
					Vector2(unit * 0.74, unit * 0.36)
				),
				tint_a
			)

		"crown":
			_brim()
			draw_colored_polygon(PackedVector2Array([
				Vector2(-unit * 0.62, -unit * 0.62),
				Vector2(-unit * 0.31, -unit * 1.05),
				Vector2(0.0, -unit * 0.72),
				Vector2(unit * 0.31, -unit * 1.05),
				Vector2(unit * 0.62, -unit * 0.62),
			]), tint_a)

		"dust", "ember":
			# Behind everything, and only a hint: a trail that read clearly at this size
			# would cover the monster it is riding.
			var hot := shape == "ember"
			for i in range(3):
				var back := Vector2(-unit * (0.7 + 0.45 * float(i)), 0.0)
				var alpha := (0.42 if hot else 0.30) - 0.08 * float(i)
				draw_circle(back, unit * (0.34 - 0.08 * float(i)), Color(
					tint_a.r, tint_a.g, tint_a.b, maxf(0.05, alpha)
				))

		_:
			draw_circle(Vector2.ZERO, unit * 0.52, tint_a)
			_eyes()


## A face, because a monster with one is instantly readable as somebody's monster rather
## than as a coloured circle.
func _eyes() -> void:
	var eye := unit * 0.15
	draw_circle(Vector2(-unit * 0.20, -unit * 0.12), eye, tint_b)
	draw_circle(Vector2(unit * 0.20, -unit * 0.12), eye, tint_b)


func _brim() -> void:
	var brim := unit * 0.62
	draw_rect(
		Rect2(Vector2(-brim, -unit * 0.62), Vector2(brim * 2.0, unit * 0.12)), tint_a
	)
