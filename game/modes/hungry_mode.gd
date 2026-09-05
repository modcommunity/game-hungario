@tool
class_name HungryMode
extends Node

## One mode of the game, as a scene a [DotGameManager] can load and unload.
##
## [b]This is the unit dot-server switches between.[/b] `changegame frenzy` fires a
## cancellable event, tells every client to fetch the new content, waits for them, frees
## this scene and instantiates the next one — with the players still connected the whole
## time. For that to work the world has to live [i]inside[/i] the scene rather than beside
## it, so that freeing the scene is what ends the old game.
##
## What deliberately does not live in here is the netcode. A [DotNetManager] holds its
## message ids and its peer records for the length of a connection, and rebuilding one on
## every map change would drop everybody. [HungryModule] keeps the manager and the bridge,
## and rebinds the bridge to whatever world this scene brought with it.

const CHANNEL := "hungry.mode"

## Which preset to build. Set on the scene, so two scenes differ only in this.
@export var preset_id: StringName = &"classic"

@export_range(1, 240, 1) var tick_rate: int = HungryContent.TICK_RATE

## Zero picks one from the clock, so two rounds on the same server are not the same map.
##
## A fixed seed is what a test wants and a varying one is what a server wants, which is
## exactly why this is exported rather than decided in code.
@export var world_seed: int = 0

@export var register_service: bool = true

@export var service_scope: StringName = &""

## Whether to start the match as soon as the scene is ready.
##
## Off when a host drives ticks itself — which is every netted deployment, because the
## world's tick has to happen inside dot-net's.
@export var auto_start: bool = false

var world: HungryWorld = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var built := build()

	if not built.ok:
		DotLog.error(CHANNEL, "the mode could not be built", {
			"preset": String(preset_id), "error": str(built.error)
		})


func build() -> DotResult:
	if world != null:
		return DotResult.success(world)

	var preset := HungryPreset.for_id(preset_id)

	world = HungryWorld.new()
	world.name = "World"
	world.preset = preset
	world.tick_rate = tick_rate
	world.is_authority = true
	world.register_service = register_service
	world.service_scope = service_scope
	world.world_seed = world_seed if world_seed > 0 else _seed_from_clock()
	add_child(world)

	var ready_result := world.setup()

	if not ready_result.ok:
		return ready_result

	if auto_start:
		world.start(0)

	DotLog.info(CHANNEL, "mode ready", {
		"preset": String(preset.id),
		"world": preset.world_size,
		"food": preset.food_target,
	})

	return DotResult.success(world)


static func _seed_from_clock() -> int:
	# Masked into a positive 31-bit range: the seed goes on the wire as a varint and a
	# negative one costs ten bytes rather than four.
	return int(Time.get_unix_time_from_system()) & 0x7FFFFFFF


func describe() -> Dictionary:
	return {
		"preset": String(preset_id),
		"world": world.describe() if world != null else {},
	}
