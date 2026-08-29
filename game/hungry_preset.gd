@tool
class_name HungryPreset
extends Resource

## The handful of numbers that make one mode of this game different from another.
##
## [b]A resource rather than a subclass, because a mode is a tuning and not a
## behaviour.[/b] Everything here is something an operator might reasonably want to change
## between two servers, and none of it changes what the code does — which is the line that
## decides whether something belongs in [HungryContent] (where the relationships live) or
## here (where the dials are).
##
## It is also what makes [DotGameManager]'s game change worth demonstrating: two scenes,
## two presets, and a server that swaps between them while everybody stays connected.

@export var id: StringName = &"classic"

@export var display_name: String = "Classic"

@export_group("World")

@export var world_size: Vector2 = HungryContent.WORLD_SIZE

@export_range(0, 20000, 50) var food_target: int = HungryContent.FOOD_TARGET
@export_range(0, 200, 1) var fruit_target: int = HungryContent.FRUIT_TARGET
@export_range(0, 200, 1) var item_target: int = HungryContent.ITEM_TARGET

@export_group("Growing")

@export_range(10.0, 1000000.0, 10.0) var win_mass: float = HungryContent.WIN_MASS

@export_range(1.0, 5000.0, 5.0) var max_speed: float = 415.0

## Seconds before two pieces of the same monster merge back.
##
## The single most consequential number in the game: it decides how long a split costs
## you, and therefore whether splitting to catch somebody is ever worth it.
@export_range(0.0, 300.0, 0.5) var merge_delay_sec: float = 16.0

@export_group("Round")

@export_range(0.0, 7200.0, 10.0) var time_limit_sec: float = 900.0


static func classic() -> HungryPreset:
	return HungryPreset.new()


## Small, fast, and over quickly. What a server switches to when six people are waiting.
static func frenzy() -> HungryPreset:
	var preset := HungryPreset.new()
	preset.id = &"frenzy"
	preset.display_name = "Frenzy"
	preset.world_size = Vector2(3000.0, 3000.0)
	preset.food_target = 700
	preset.fruit_target = 18
	preset.item_target = 26
	preset.win_mass = 900.0
	preset.max_speed = 520.0
	# Four seconds rather than sixteen. Splitting stops being a commitment and starts
	# being a move, which is the whole character of the mode.
	preset.merge_delay_sec = 4.0
	preset.time_limit_sec = 300.0
	return preset


static func for_id(preset_id: StringName) -> HungryPreset:
	return frenzy() if preset_id == &"frenzy" else classic()


func validate() -> DotResult:
	if world_size.x < 400.0 or world_size.y < 400.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A world smaller than 400 units is smaller than a grown monster."
		)

	if win_mass <= HungryContent.START_MASS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A win mass of %.0f is at or below the starting mass, so the first player "
				% win_mass
			+ "to spawn has already won."
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"world": world_size,
		"food": food_target,
		"win": win_mass,
		"speed": max_speed,
		"merge": merge_delay_sec,
	}


func _to_string() -> String:
	return "HungryPreset(%s)" % id
