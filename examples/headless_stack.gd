extends Node

const HungryContent := preload("../game/hungry_content.gd")
const HungryPlayerStack := preload("../game/hungry_player_stack.gd")
const HungryPreset := preload("../game/hungry_preset.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## The player stack, run against a real 2D arena rather than against a stub.
##
## [codeblock]
## godot --headless --path . res://examples/headless_stack.tscn
## [/codeblock]
##
## [b]A three-hundred-line player layer with no suite that named it.[/b] game-arena got
## one; this game did not, so the roster, the traits, the collision layout and the spawn
## director ran only as far as `setup()` inside somebody else's test.
##
## Two of the sections are about things this game was getting wrong quietly:
##
## - **The trait numbers were written twice.** The class catalogue carried its own
##   `{nimble: 1.15, sturdy: 0.9}` while `HungryContent.TRAIT_SPEED` is `[1.08, 0.95, …]`
##   and the simulation reads the latter — so the document a server validates, a class
##   screen draws and the wire carries said a nimble monster was 15% faster while it
##   actually ran at 8%. Both numbers are valid speeds; only one is ever simulated.
## - **The spawn director chose nothing.** A grid of twenty-five sites was laid over the
##   field, the distance scoring was configured, and `_safe_spawn` did the same job by
##   hand beside it.

const TICK_RATE := 60
const CHECKS := 24
const SECTIONS := 4

var _passed := 0
var _failed := 0
var _section_count := 0

var _world: HungryWorld = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("hungario player stack")
	print("")

	if not _build():
		get_tree().quit(1)
		return

	_test_physics_layout()
	_test_roster_and_traits()
	_test_traits_agree_with_the_simulation()
	_test_spawn_director()

	print("")
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		print("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _build() -> bool:
	_world = HungryWorld.new()
	_world.name = "World"
	_world.preset = HungryPreset.classic()
	_world.tick_rate = TICK_RATE
	_world.register_service = false
	add_child(_world)

	var res := _world.setup()

	if not res.ok:
		print("  FAIL  the world did not set up: %s" % res.error.message)
		return false

	if _world.player_stack == null:
		print("  FAIL  the world set up without a player stack")
		return false

	return true


func _stack() -> HungryPlayerStack:
	return _world.player_stack


# --- 1 ----------------------------------------------------------------------

func _test_physics_layout() -> void:
	_section("the collision layout is worn, not just named")

	var physics := _stack().physics
	_check(physics != null, "the stack built a physics world")

	if physics == null:
		return

	_check(physics.layout != null, "with a top-down 2D layout on it")
	_check(
		physics.layout.has_layer(&"hazard") and physics.layout.has_layer(&"enemy"),
		"that has the two layers this game has bodies for — a hazard volume and a hunter"
	)

	# [b]Most of this game is analytic and that is the honest reason there is little to
	# classify.[/b] `Dot2DArena` is not a physics space: monsters, food and pieces are
	# positions in a grid rather than collision objects. What IS a body is a hazard and a
	# hunter, and both were on Godot's default layer 1 — the bit the layout calls `world`
	# — which made a hazard, as far as the collision matrix went, a piece of floor.
	_check(
		physics.layout.layer_mask(&"hazard") != physics.layout.layer_mask(&"world"),
		"and a hazard is not on the same layer as the level, which is what it was"
	)
	_check(
		physics.layout.collision_mask(&"hazard") == physics.layout.layer_mask(&"player"),
		"a hazard collides with players and nothing else, which is what a spike is"
	)


# --- 2 ----------------------------------------------------------------------

func _test_roster_and_traits() -> void:
	_section("a player reaches the roster, a side and a trait")

	_stack().add_player(1, "Ada")

	_check(_stack().roster.has_player("1"), "a player lands in the session roster")
	_check(_stack().teams.has_player("1"), "and on a side")
	_check(
		_stack().team_index_of("1") > 0,
		"with a real team number — a free-for-all is ONE playing side, not none"
	)
	_check(
		_stack().team_index_of("999") == 0,
		"and 0 for a stranger, which dot-spectate reads as 'no team'"
	)

	var def := _stack().classes.def_of("1")
	_check(def != null, "and a trait")


# --- 3 ----------------------------------------------------------------------

func _test_traits_agree_with_the_simulation() -> void:
	_section("the trait document says what the simulation does")

	var catalogue := _stack().classes.catalogue
	_check(catalogue != null, "there is a trait catalogue")

	if catalogue == null:
		return

	var checked := 0

	for trait_id in HungryContent.TRAIT_IDS:
		var def := catalogue.get_class_def(trait_id)

		if def == null:
			continue

		checked += 1
		_check(
			is_equal_approx(def.move_speed_scale, HungryContent.trait_speed(trait_id)),
			"'%s' is the speed HungryMonster actually runs at (%.2f)" % [
				String(trait_id), HungryContent.trait_speed(trait_id)
			]
		)
		_check(
			is_equal_approx(def.mass, HungryContent.trait_mass(trait_id) * 100.0),
			"and carries '%s'`s mass ratio too, so the document is the whole trait"
				% String(trait_id)
		)

	_check(
		checked == HungryContent.TRAIT_IDS.size(),
		"every trait the game has is in the catalogue, read off TRAIT_IDS rather than "
		+ "listed — a trait added and forgotten here is one the manager refuses"
	)


# --- 4 ----------------------------------------------------------------------

func _test_spawn_director() -> void:
	_section("the director chooses where a monster appears")

	var spawns := _stack().spawns
	_check(spawns.sites().size() > 0, "a grid of sites is laid over the field")
	_check(
		spawns.sites()[0].is_2d,
		"and they are 2D sites, because this arena is"
	)

	var res := _stack().choose_spawn(1)
	_check(res.ok, "the director answers")

	if not res.ok:
		return

	var choice := res.value as DotSpawnChoice
	var half := _world.world_size * 0.5
	var at := Vector2(choice.transform.origin.x, choice.transform.origin.y)

	_check(
		absf(at.x) <= half.x and absf(at.y) <= half.y,
		"inside the arena — a site on the boundary spawns a monster half outside it"
	)

	# The condition that replaced the hand-written loop.
	var names := PackedStringArray()

	for condition in spawns.conditions:
		names.append(String(condition.id))

	_check(
		"site_is_not_deadly" in names,
		"with the mass rule as a CONDITION rather than as a loop beside it — distance "
		+ "is the wrong question here, because what kills a new monster is somebody "
		+ "near AND bigger"
	)

	# And that the world's own spawn goes through it.
	var protection := spawns.protection
	_check(
		protection != null or is_equal_approx(spawns.rules.protection_sec, 0.0),
		"a protection ledger exists once the rules open a window"
	)

	_world.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	print("")
	print("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
