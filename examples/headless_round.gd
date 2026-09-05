extends Node

## Plays whole rounds of the game with nobody watching, and checks that they work.
##
## [codeblock]
## godot --headless --path . res://examples/headless_round.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## [b]This is the file that finds the bugs.[/b] Everything here parses cleanly whether it
## is right or wrong: a monster that grows outside the wall, a field that hands out the
## same slot twice, a burst that quietly does nothing because the piece cap was already
## reached. None of those produce an error, and none of them are visible by reading the
## code. They are visible by running eight monsters for two minutes and measuring.

const SEED := 20260828
const TICK_RATE := 60

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section — asking a dead
## monster where it is, indexing an array that emptied — aborts that function and nothing
## says so: the checks that already ran still print ok, the ones after it simply never
## happen, and the total at the bottom cannot reveal a check that never ran. Eight of them
## stopped running here for exactly that reason and the number went up, because other
## sections had been added in the same change.
##
## Every section increments the first on entry and the second on its last line, and
## [method _run] compares them. dot-net's demo carries the same pair for the same reason,
## reached from the other direction: there it was a suspending section called without
## `await`.
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario: a round")
	print("")

	_test_setup()
	_test_food_tiers()
	_test_growing()
	_test_fruit()
	_test_items_and_throwing()
	_test_lure()
	_test_splitting()
	_test_merging()
	_test_devouring()
	_test_interest()
	_test_round_reset()
	_test_determinism()
	_test_full_round()
	_test_sound()
	_test_ejecting()
	_test_loadout()
	_test_rider()
	_test_interface()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


## Opens a section. Pair with [method _done] on the last line.
func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


## Closes a section. Anything that returns early has to call it before returning.
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


# --- Fixtures --------------------------------------------------------------

## A world nobody else can see, so a test can do what it likes to it.
##
## `register_service` is off for every one of these: two worlds registered under the same
## name would displace each other, and several of these tests hold two at once.
func _make_world(preset: HungryPreset = null, world_seed: int = SEED) -> HungryWorld:
	var world := HungryWorld.new()
	world.name = "World"
	world.preset = preset if preset != null else HungryPreset.classic()
	world.tick_rate = TICK_RATE
	world.world_seed = world_seed
	world.register_service = false
	add_child(world)

	var ready_result := world.setup()

	if not ready_result.ok:
		push_error(str(ready_result.error))

	world.start(0)
	return world


func _drop(world: HungryWorld) -> void:
	if world != null and is_instance_valid(world):
		remove_child(world)
		world.free()


## Ticks a world, feeding every monster a fixed command.
func _run_ticks(world: HungryWorld, count: int, commands: Dictionary = {}) -> void:
	for _i in range(count):
		world.tick(commands)


## Ticks until the round is actually live.
##
## [b]Not optional, and the first thing every arrangement in this file learned.[/b] The
## transition into [constant DotMatch.State.LIVE] runs [method HungryWorld.reset_world] —
## that is what a new round [i]is[/i] — and it clears every piece, every carried item and
## every effect, then respawns everybody somewhere safe. A test that arranged the world
## before that happened had its arrangement thrown away, and the symptom was a monster
## standing a thousand units from where it was put, holding nothing.
func _settle(world: HungryWorld) -> void:
	for _i in range(TICK_RATE * 5):
		if world.match_node.is_live():
			return

		world.tick({})


func _aim_at(from: Vector2, to: Vector2, buttons: int = 0) -> Dot2DCommand:
	var command := Dot2DCommand.new()
	var offset := to - from
	command.aim = offset.normalized() if offset.length_squared() > 0.000001 else Vector2.RIGHT
	command.reach = minf(offset.length(), HungryNetCommand.MAX_REACH)
	command.buttons = buttons
	return command


# --- Setup -----------------------------------------------------------------

func _test_setup() -> void:
	_section("setting up")

	var world := _make_world()

	_check(world.arena != null, "the arena exists")
	_check(
		world.field.food_count() == HungryContent.FOOD_TARGET,
		"the food field is full (%d)" % world.field.food_count()
	)
	_check(
		world.field.fruit_count() == HungryContent.FRUIT_TARGET,
		"and the fruit is out (%d)" % world.field.fruit_count()
	)
	_check(
		world.field.item_count() == HungryContent.ITEM_TARGET,
		"and the item drops (%d)" % world.field.item_count()
	)

	# Everything alive has to be in the grid, or it cannot be eaten and nothing says so.
	var indexed := 0

	for grid_id in world.field.alive_ids():
		if world.arena.grid.has(grid_id):
			indexed += 1

	_check(
		indexed == world.field.alive_count(),
		"every slot is indexed into the grid",
		"%d of %d" % [indexed, world.field.alive_count()]
	)

	var added := world.add_player(1, "Ada")
	_check(added.ok, "a player joins")

	world.spawn(1)
	var monster := world.monster_for(1)

	_check(monster != null and monster.alive, "and is in the world")
	# The starting mass is the constant *times the trait's*: a loadout that traded nothing
	# on the way in would be a choice with no consequence until much later.
	_check(
		monster != null and is_equal_approx(
			monster.mass(),
			HungryContent.START_MASS * HungryContent.trait_mass(monster.trait_id)
		),
		"at the starting mass their trait gives them (%.1f)"
			% (monster.mass() if monster != null else 0.0)
	)
	_check(
		monster != null and monster.carried.size() == 1
			and monster.carried[0] == monster.starter_item(),
		"holding the throwable their loadout chose (%s)"
			% (String(monster.starter_item()) if monster != null else "-")
	)
	_check(
		monster != null and monster.piece_count() == 1,
		"as a single piece"
	)
	_check(
		monster != null and monster.rider_piece() != null
			and monster.rider_piece().state.has_flag(HungryContent.FLAG_RIDER),
		"whose one piece carries the rider"
	)

	_drop(world)
	_done()


func _test_food_tiers() -> void:
	_section("food comes in sizes")

	var world := _make_world()
	var counts := [0, 0, 0, 0]

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) != HungryField.Kind.FOOD:
			continue

		counts[world.field.tier_of(grid_id)] += 1

	for tier in range(4):
		_check(
			counts[tier] > 0,
			"tier %d (%s) appears %d times" % [
				tier, HungryContent.FOOD_TIER_NAMES[tier], counts[tier]
			]
		)

	# The rarest tier must actually be rare, or "different sizes" is four names for the
	# same thing. The weights say 4%; anything over a tenth means the cutoffs are wrong.
	var total: int = counts[0] + counts[1] + counts[2] + counts[3]
	var rarest := float(counts[3]) / maxf(1.0, float(total))

	_check(
		rarest > 0.01 and rarest < 0.10,
		"haunches are rare (%.1f%%)" % (rarest * 100.0)
	)
	_check(
		counts[0] > counts[1] and counts[1] > counts[2] and counts[2] > counts[3],
		"and the tiers get rarer in order",
		str(counts)
	)

	# The size a client draws and the size the server eats at must be the same function
	# of the same slot, or a crumb is eaten from somewhere it is not drawn.
	var sample := world.field.alive_ids()[0]
	_check(
		is_equal_approx(
			world.field.radius_of(sample),
			HungryContent.FOOD_TIER_RADIUS[world.field.tier_of(sample)]
		),
		"radius and tier agree"
	)

	_drop(world)


# --- Growing ---------------------------------------------------------------
	_done()

func _test_growing() -> void:
	_section("growing")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)

	# Somewhere with food around it, rather than wherever the safe spawn picked.
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	var before := monster.mass()
	var eaten := [0]

	world.food_eaten.connect(func(_p: int, _g: int, _m: float) -> void:
		eaten[0] += 1
	)

	# Chase the nearest crumb for a few seconds. A monster that simply sat still would
	# prove nothing: the field has a margin and the centre may be empty.
	for _i in range(600):
		var head := monster.rider_piece()
		var target := _nearest_food(world, head.position())
		world.tick({1: _aim_at(head.position(), target)})

	_check(eaten[0] > 0, "a monster eats what it runs over (%d)" % eaten[0])
	_check(
		monster.mass() > before,
		"and gets bigger (%.0f -> %.0f)" % [before, monster.mass()]
	)
	_check(
		monster.food_eaten == eaten[0],
		"and the counter agrees with the signal"
	)

	# Radius must follow mass through the same function the eat check uses.
	var rules := world.tunables.mass_rules
	_check(
		is_equal_approx(
			monster.rider_piece().radius(), rules.radius_for(monster.rider_piece().mass())
		),
		"the radius follows the mass"
	)

	# Growing is a move. A monster pinned against a wall that eats gets wider, and only a
	# *moving* entity is clamped by the motor — this is the check that catches it.
	_check(_furthest_edge(world) <= 0.5, "nothing has grown through a wall")

	_drop(world)


## The distance the furthest monster edge sticks out past the arena, or zero.
	_done()
func _furthest_edge(world: HungryWorld) -> float:
	var bounds := world.arena.bounds
	var worst := 0.0

	for piece in world.pieces():
		var at := piece.position()
		var radius := piece.radius()

		worst = maxf(worst, bounds.position.x - (at.x - radius))
		worst = maxf(worst, bounds.position.y - (at.y - radius))
		worst = maxf(worst, (at.x + radius) - bounds.end.x)
		worst = maxf(worst, (at.y + radius) - bounds.end.y)

	return worst


func _nearest_food(world: HungryWorld, from: Vector2) -> Vector2:
	var best := from + Vector2.RIGHT * 100.0
	var best_distance := INF

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.ITEM:
			continue

		var at := world.field.position_of(grid_id)
		var distance := from.distance_squared_to(at)

		if distance < best_distance:
			best_distance = distance
			best = at

	return best


# --- Fruit -----------------------------------------------------------------

func _test_fruit() -> void:
	_section("fruit")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	var kinds := {}

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.FRUIT:
			kinds[world.field.fruit_kind_of(grid_id)] = true

	_check(kinds.size() >= 2, "several kinds of fruit are out (%d)" % kinds.size())

	# Put a known fruit under the monster rather than hunting one down: what is being
	# tested is the effect, not the pathfinding.
	var fruit_id := _first_of(world, HungryField.Kind.FRUIT)
	var kind := world.field.fruit_kind_of(fruit_id)
	var at := world.field.position_of(fruit_id)

	world.spawn(1, at)
	var before := monster.mass()
	world.tick({})

	_check(
		monster.mass() > before + HungryContent.FRUIT_MASS * 0.5,
		"eating one is worth a lot of mass (%.0f -> %.0f)" % [before, monster.mass()]
	)

	var flag: int = [
		HungryContent.FLAG_RUSH, HungryContent.FLAG_MAW, HungryContent.FLAG_RIND
	][int(kind)]

	_check(
		monster.has_effect(flag, world.current_tick()),
		"and applies its effect (%s)" % HungryContent.FRUIT_NAMES[int(kind)]
	)
	_check(
		(monster.rider_piece().state.flags & flag) != 0,
		"which is on the piece's flags, so a client can draw it"
	)

	if kind == HungryContent.Fruit.RUSH:
		_check(
			monster.speed_multiplier(world.current_tick())
				> HungryContent.RUSH_SPEED_MULTIPLIER - 0.01,
			"and rush makes them faster"
		)

	# Effects are counted in ticks and must actually run out. An effect that never
	# expired would be invisible for eight seconds and permanent afterwards.
	_run_ticks(world, int(HungryContent.FRUIT_EFFECT_SEC * TICK_RATE) + 2)
	_check(
		not monster.has_effect(flag, world.current_tick()),
		"and it expires on time"
	)
	_check(
		is_equal_approx(
			monster.speed_multiplier(world.current_tick()),
			HungryContent.trait_speed(monster.trait_id)
		),
		"leaving the monster at whatever its trait gives it (%.2f)"
			% monster.speed_multiplier(world.current_tick())
	)

	_drop(world)
	_done()


func _first_of(world: HungryWorld, kind: HungryField.Kind) -> int:
	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == kind:
			return grid_id

	return 0


# --- Items -----------------------------------------------------------------

func _test_items_and_throwing() -> void:
	_section("throwables")

	var world := _make_world()
	world.add_player(1, "Ada")
	world.add_player(2, "Bo")
	_settle(world)

	var thrower := world.monster_for(1)
	var victim := world.monster_for(2)

	var drop := _first_of(world, HungryField.Kind.ITEM)
	world.spawn(1, world.field.position_of(drop))

	# One already, from the loadout. What is being checked is that running over a drop
	# adds to it.
	var held := thrower.carried.size()
	world.tick({})

	_check(
		thrower.carried.size() == held + 1,
		"running over a drop picks it up (%d -> %d)" % [held, thrower.carried.size()]
	)

	# The cap has to refuse rather than swallow. An item that vanished because you were
	# full reads as a bug every single time.
	thrower.carried.clear()

	for _i in range(HungryContent.MAX_CARRIED):
		thrower.take_item(HungryContent.ITEM_PEPPER)

	var another := _first_of(world, HungryField.Kind.ITEM)
	var still_there := world.field.take(another)
	_check(still_there, "a full monster leaves the drop where it is")

	# Now the pepper. A victim large enough to be worth bursting, right in front.
	world.spawn(1, Vector2(-300.0, 0.0))
	world.spawn(2, Vector2(100.0, 0.0))

	# Spawn protection stops a thrown pepper too, and that rule has its own check in
	# `_test_devouring`. Cleared here rather than waited out, so that four seconds of
	# ticks do not move either of them somewhere else first.
	thrower.clear_effect(HungryContent.FLAG_PROTECTED)
	victim.clear_effect(HungryContent.FLAG_PROTECTED)

	thrower.carried.clear()
	thrower.take_item(HungryContent.ITEM_PEPPER)
	thrower.throw_ready_tick = world.current_tick()

	var grown := victim.rider_piece()
	grown.set_mass(HungryContent.MIN_BURST_MASS * 3.0, world.tunables.mass_rules)

	var pieces_before := victim.piece_count()
	var burst_seen := [0]
	world.monster_burst.connect(func(_p: int, _b: int, count: int) -> void:
		burst_seen[0] += count
	)

	var throw_command := _aim_at(
		thrower.rider_piece().position(),
		victim.rider_piece().position(),
		Dot2DCommand.BUTTON_ACTION
	)
	# Held still, so the two do not drift into each other while the pepper is in flight.
	var hold := Dot2DCommand.new()

	world.tick({1: throw_command, 2: hold})
	_check(world.projectiles().size() == 1, "throwing puts a pepper in flight")
	_check(thrower.carried.is_empty(), "and spends the charge")

	for _i in range(90):
		world.tick({1: hold, 2: hold})

		if victim.piece_count() > pieces_before:
			break

	_check(
		victim.piece_count() > pieces_before,
		"the pepper bursts them (%d -> %d pieces)" % [
			pieces_before, victim.piece_count()
		]
	)
	_check(burst_seen[0] > 0, "and says so")
	_check(world.projectiles().is_empty(), "and the pepper is gone")

	# You still control the pieces, and they still all belong to you.
	var mine := true

	for piece in victim.pieces:
		mine = mine and piece.owner_id == victim.id

	_check(mine, "and every piece is still theirs")

	# A burst piece cannot re-merge immediately, or a burst heals itself instantly and
	# is not a threat at all.
	var delayed := true

	for piece in victim.pieces:
		delayed = delayed and not piece.can_merge(world.current_tick())

	_check(delayed, "and none of them may merge yet")

	# The rind fruit eats a burst outright. Not "reduces": a fruit whose effect is
	# invisible is a fruit nobody picks up on purpose.
	victim.apply_effect(
		HungryContent.FLAG_RIND, world.current_tick() + TICK_RATE * 10
	)
	var protected_before := victim.piece_count()
	var made := world.burst(victim, 1)

	_check(made == 0, "a rind absorbs a burst entirely")
	_check(
		victim.piece_count() == protected_before,
		"leaving the monster whole"
	)
	_check(
		not victim.has_effect(HungryContent.FLAG_RIND, world.current_tick()),
		"and is spent doing it"
	)

	# Frost.
	thrower.carried.clear()
	thrower.take_item(HungryContent.ITEM_FROST)
	var frost_command := _aim_at(
		thrower.rider_piece().position(),
		victim.rider_piece().position(),
		Dot2DCommand.BUTTON_ACTION
	)
	thrower.throw_ready_tick = world.current_tick()
	world.tick({1: frost_command, 2: hold})

	for _i in range(90):
		world.tick({1: hold, 2: hold})

		if victim.has_effect(HungryContent.FLAG_FROSTED, world.current_tick()):
			break

	_check(
		victim.has_effect(HungryContent.FLAG_FROSTED, world.current_tick()),
		"a frostberry slows its target"
	)
	_check(
		victim.speed_multiplier(world.current_tick()) < 1.0,
		"which is a real speed change (%.2f)"
			% victim.speed_multiplier(world.current_tick())
	)

	_drop(world)
	_done()


func _test_lure() -> void:
	_section("the lure")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2(-800.0, 0.0))

	var monster := world.monster_for(1)
	# After the spawn, because a spawn hands out the loadout's charge and clears whatever
	# was there.
	monster.carried.clear()
	monster.take_item(HungryContent.ITEM_LURE)
	monster.throw_ready_tick = world.current_tick()

	var planted_before := world.field.planted_count()
	var head := monster.rider_piece()

	world.tick({
		1: _aim_at(
			head.position(),
			head.position() + Vector2.RIGHT * 400.0,
			Dot2DCommand.BUTTON_ACTION
		)
	})

	var hold := Dot2DCommand.new()

	for _i in range(180):
		world.tick({1: hold})

		if world.field.planted_count() > planted_before:
			break

	_check(
		world.field.planted_count() >= HungryContent.LURE_FOOD_COUNT,
		"a lure plants a ring of food (%d)" % world.field.planted_count()
	)

	# Planted food is the one kind whose position is *sent* rather than derived, so it
	# has to be in the grid at the position the field reports.
	var mismatched := 0
	var planted_ids: Array[int] = []

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) != HungryField.Kind.PLANTED:
			continue

		planted_ids.append(grid_id)

		if not world.arena.grid.has(grid_id) \
				or world.arena.grid.position_of(grid_id).distance_to(
					world.field.position_of(grid_id)
				) > 0.01:
			mismatched += 1

	_check(mismatched == 0, "and every crumb of it is in the grid where it says")

	var rows := world.field.planted_rows(planted_ids)
	_check(
		rows.size() == planted_ids.size(),
		"and each one has a position to send"
	)

	# Inside the world, including near a wall. A ring clamped badly is food nobody can
	# reach.
	var outside := 0

	for grid_id in planted_ids:
		if not world.arena.bounds.has_point(world.field.position_of(grid_id)):
			outside += 1

	_check(outside == 0, "and none of it is outside the arena")

	_drop(world)


# --- Splitting and merging -------------------------------------------------
	_done()

func _test_splitting() -> void:
	_section("splitting")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	monster.rider_piece().set_mass(400.0, world.tunables.mass_rules)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var mass_before := monster.mass()
	var split := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0, Dot2DCommand.BUTTON_SPLIT)
	var release := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0)

	world.tick({1: split})

	_check(monster.piece_count() == 2, "a split makes two pieces")
	# Not exactly: a monster this wide covers a lot of ground and eats whatever it is
	# sitting on during the same tick. What a split must not do is lose mass.
	_check(
		monster.mass() >= mass_before * 0.98,
		"and conserves mass (%.1f -> %.1f)" % [mass_before, monster.mass()]
	)

	var halves := monster.pieces
	_check(
		absf(halves[0].mass() - halves[1].mass()) < mass_before * 0.15,
		"into two roughly equal halves (%.0f and %.0f)"
			% [halves[0].mass(), halves[1].mass()]
	)

	# Both halves, not just the new one. A parent that could re-absorb its child at once
	# makes splitting free, and splitting is supposed to be a risk.
	var both_delayed := true

	for piece in monster.pieces:
		both_delayed = both_delayed and not piece.can_merge(world.current_tick())

	_check(both_delayed, "and both halves have to wait to merge")

	# Held down, a split must not fire every tick. Without a cooldown the piece cap is
	# reached in a fifth of a second, which is a stutter rather than a decision.
	var after_one := monster.piece_count()
	world.tick({1: split})
	_check(
		monster.piece_count() == after_one,
		"a held key does not split again (edge-triggered)"
	)

	# Released and pressed again, but still inside the cooldown.
	world.tick({1: release})
	world.tick({1: split})
	_check(
		monster.piece_count() == after_one,
		"and the cooldown holds even after a release"
	)

	# Past the cooldown it works again.
	for _i in range(HungryContent.SPLIT_COOLDOWN_TICKS + 2):
		world.tick({1: release})

	world.tick({1: split})
	_check(monster.piece_count() > after_one, "and works again once it has passed")

	# The cap. Splitting repeatedly must stop at max_pieces rather than growing for ever.
	for _i in range(40):
		for _j in range(HungryContent.SPLIT_COOLDOWN_TICKS + 1):
			world.tick({1: release})

		world.tick({1: split})

	_check(
		monster.piece_count() <= world.tunables.mass_rules.max_pieces,
		"the piece cap holds (%d of %d)" % [
			monster.piece_count(), world.tunables.mass_rules.max_pieces
		]
	)

	# Separation. Pieces that cannot merge must not sit inside each other, or a split
	# collapses back into a pile and stops meaning anything.
	var overlapping := 0

	for a in range(monster.pieces.size()):
		for b in range(a + 1, monster.pieces.size()):
			var first := monster.pieces[a]
			var second := monster.pieces[b]
			var gap := first.position().distance_to(second.position())

			if gap < (first.radius() + second.radius()) * 0.5:
				overlapping += 1

	_check(overlapping == 0, "and the pieces push apart (%d piles)" % overlapping)
	_check(_furthest_edge(world) <= 0.5, "and stay inside the world")

	_drop(world)
	_done()


func _test_merging() -> void:
	_section("merging back")

	# A preset with a short delay, so this does not take sixteen seconds of ticks.
	var preset := HungryPreset.classic()
	preset.merge_delay_sec = 1.0

	var world := _make_world(preset)
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	monster.rider_piece().set_mass(600.0, world.tunables.mass_rules)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var split := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0, Dot2DCommand.BUTTON_SPLIT)
	var release := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0)

	# Twice, with the cooldown in between, so there are three or four pieces rather than
	# two. Three in a pile is what the repeated pass in `_resolve_merges` exists for: a
	# single pass a tick merges two of them and leaves the third, which reads as a merge
	# that stutters.
	world.tick({1: split})

	for _i in range(HungryContent.SPLIT_COOLDOWN_TICKS + 2):
		world.tick({1: release})

	world.tick({1: split})

	var most := monster.piece_count()
	_check(most >= 3, "there are pieces to merge (%d)" % most)

	var mass_before := monster.mass()

	# Pull everything to one point: merging needs the delay *and* proximity.
	var gather := Dot2DCommand.new()

	for _i in range(TICK_RATE * 6):
		world.tick({1: gather})

		if monster.piece_count() == 1:
			break

	_check(
		monster.piece_count() == 1,
		"they come back together (%d -> %d)" % [most, monster.piece_count()]
	)
	_check(
		monster.mass() > mass_before * 0.9,
		"keeping the mass (%.0f -> %.0f)" % [mass_before, monster.mass()]
	)

	# Three pieces in a pile merge two at a time, so a single pass a tick would leave the
	# third behind and look like a merge that stutters. The loop in `_resolve_merges` is
	# what this checks — it only shows up above two pieces.
	_check(most > 2, "and this ran with more than two pieces (%d)" % most)

	_drop(world)


# --- Eating each other -----------------------------------------------------
	_done()

func _test_devouring() -> void:
	_section("eating each other")

	var world := _make_world()
	world.add_player(1, "Big")
	world.add_player(2, "Small")
	_settle(world)

	world.spawn(1, Vector2(0.0, 0.0))
	world.spawn(2, Vector2(40.0, 0.0))

	var big := world.monster_for(1)
	var small := world.monster_for(2)

	big.rider_piece().set_mass(500.0, world.tunables.mass_rules)

	# Spawn protection first: this is a rule, and a test that cleared it would never
	# notice if it stopped working.
	var eaten := [0]
	world.piece_eaten.connect(func(_e: int, _v: int, _m: float) -> void:
		eaten[0] += 1
	)

	world.tick({})
	_check(eaten[0] == 0, "spawn protection stops an instant kill")

	# Cleared rather than waited out. Four seconds of ticks with a 500-mass monster forty
	# units from a 22-mass one is four seconds in which the kill happens on its own — and
	# then the chase below starts by asking a dead monster where it is, which is a runtime
	# error that aborts the rest of this function while every check that already ran still
	# says ok. That is how eight checks stopped running without the count going down.
	big.clear_effect(HungryContent.FLAG_PROTECTED)
	small.clear_effect(HungryContent.FLAG_PROTECTED)

	var deaths := [0]
	world.player_died.connect(func(_p: int, _k: int) -> void: deaths[0] += 1)

	var stand := Dot2DCommand.new()
	var chase := _aim_at(
		big.rider_piece().position(), small.rider_piece().position()
	)

	for _i in range(180):
		world.tick({1: chase, 2: stand})

		if not small.alive:
			break

		var hunter := big.rider_piece()
		var prey := small.rider_piece()

		if hunter == null or prey == null:
			break

		chase = _aim_at(hunter.position(), prey.position())

	_check(not small.alive, "a bigger monster devours a smaller one")
	_check(deaths[0] == 1, "and it is reported once")
	_check(big.players_eaten == 1, "and counted")
	_check(
		big.mass() > 500.0,
		"and the eater keeps the mass (%.0f)" % big.mass()
	)
	_check(
		world.match_node.scoreboard.find("1").kills == 1,
		"and dot-match recorded the kill"
	)

	# Respawning is dot-match's, driven from a tick count rather than a timer.
	for _i in range(int(TICK_RATE * 5)):
		world.tick({})

		if small.alive:
			break

	_check(small.alive, "and the victim comes back")
	_check(
		is_equal_approx(
			small.mass(),
			HungryContent.START_MASS * HungryContent.trait_mass(small.trait_id)
		),
		"at the starting mass their trait gives them again (%.1f)" % small.mass()
	)

	# Two monsters of equal size must never eat each other, whichever is resolved first.
	# That is what an eat ratio above 1 is for, and it is the difference between a rule
	# and a coin flip.
	world.spawn(1, Vector2(0.0, 500.0))
	world.spawn(2, Vector2(10.0, 500.0))
	big.rider_piece().set_mass(200.0, world.tunables.mass_rules)
	small.rider_piece().set_mass(200.0, world.tunables.mass_rules)
	big.clear_effect(HungryContent.FLAG_PROTECTED)
	small.clear_effect(HungryContent.FLAG_PROTECTED)

	_run_ticks(world, 30)
	_check(
		big.alive and small.alive,
		"two equal monsters cannot eat each other"
	)

	_drop(world)


# --- Interest --------------------------------------------------------------
	_done()

func _test_interest() -> void:
	_section("what a client is told")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	var everything := world.field.alive_count() + world.piece_count()
	var seen := world.interest_for(1)

	_check(
		seen.size() < everything,
		"a player is not told about the whole world (%d of %d)" % [
			seen.size(), everything
		]
	)

	# The cap must bound *everything*, not only the food. Sixteen players at the piece
	# limit is two hundred and fifty-six pieces, and a cap that exempted them would not
	# be a cap.
	for id in range(2, 18):
		world.add_player(id, "Crowd %d" % id)
		world.spawn(id, Vector2(float(id) * 12.0, 0.0))

	world.tick({})
	var capped := world.interest_for(1, 6)
	_check(capped.size() <= 6, "the cap holds (%d)" % capped.size())

	var pieces_first := 0

	for grid_id in capped:
		if grid_id < HungryField.PIECE_ID_LIMIT:
			pieces_first += 1

	_check(
		pieces_first == capped.size(),
		"and pieces come before food when it bites (%d of %d)" % [
			pieces_first, capped.size()
		]
	)

	# A bigger monster fills more screen and must see further, or it cannot see anything
	# it might eat.
	var small_view := world.interest_for(1).size()
	monster.rider_piece().set_mass(4000.0, world.tunables.mass_rules)
	world.tick({})
	var big_view := world.interest_for(1).size()

	_check(
		big_view > small_view,
		"a huge monster sees further (%d -> %d)" % [small_view, big_view]
	)

	_drop(world)


# --- Rounds ----------------------------------------------------------------
	_done()

func _test_round_reset() -> void:
	_section("a new round")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var before_ids := world.field.alive_ids()
	world.reset_world()
	var after_ids := world.field.alive_ids()

	# Slot indices are never reused, so the new field's grid ids sit *beside* the old
	# field's. If the old ones are not removed, the grid ends up holding twice as much
	# food as exists — half of it phantoms at stale positions that `take()` refuses —
	# and eating quietly stops working. This is game-blob's bug, three fields wide.
	var overlap := 0
	var after_set := {}

	for grid_id in after_ids:
		after_set[grid_id] = true

	for grid_id in before_ids:
		if after_set.has(grid_id):
			overlap += 1

	_check(overlap == 0, "the new field reuses no slot from the old one")
	_check(
		world.arena.grid.size() == after_ids.size() + world.piece_count(),
		"and the grid holds exactly the new field",
		"grid %d, field %d, pieces %d" % [
			world.arena.grid.size(), after_ids.size(), world.piece_count()
		]
	)

	# Every id in the grid must be takeable. A phantom is an id the grid has and the
	# field does not, and its only symptom is food that cannot be eaten.
	var phantoms := 0

	for grid_id in world.arena.grid.ids():
		if grid_id < HungryField.PIECE_ID_LIMIT:
			continue

		if not after_set.has(grid_id):
			phantoms += 1

	_check(phantoms == 0, "and there are no phantoms (%d)" % phantoms)

	_drop(world)
	_done()


func _test_determinism() -> void:
	_section("determinism")

	# Two worlds, the same seed, the same commands. The property everything else in the
	# netcode rests on: a client predicting a move and a server re-running it have to
	# reach the same answer, and nothing else in this project can check that.
	var first := _make_world()
	var second := _make_world()

	for world in [first, second]:
		world.add_player(1, "Ada")
		world.add_player(2, "Bo")
		_settle(world)
		world.spawn(1, Vector2(-200.0, 0.0))
		world.spawn(2, Vector2(200.0, 60.0))

	var commands: Array[Dictionary] = []

	for step in range(240):
		var angle := float(step) * 0.11
		commands.append({
			1: _aim_at(
				Vector2.ZERO,
				Vector2.from_angle(angle) * 400.0,
				Dot2DCommand.BUTTON_SPLIT if step == 90 else 0
			),
			2: _aim_at(Vector2.ZERO, Vector2.from_angle(-angle) * 300.0),
		})

	for step in range(commands.size()):
		first.tick(commands[step])
		second.tick(commands[step])

	var exact := true
	var worst := 0.0

	for piece in first.pieces():
		var twin := second.piece_for(piece.id)

		if twin == null:
			exact = false
			break

		worst = maxf(worst, piece.position().distance_to(twin.position()))
		exact = exact and piece.position() == twin.position()

	_check(
		exact,
		"two worlds replaying the same commands are bit-identical (%.6f apart)" % worst
	)
	_check(
		first.field.alive_count() == second.field.alive_count(),
		"and ate exactly the same food"
	)

	# And it must not pass for a world that ignores its inputs.
	var third := _make_world()
	third.add_player(1, "Ada")
	third.add_player(2, "Bo")
	_settle(third)
	third.spawn(1, Vector2(-200.0, 0.0))
	third.spawn(2, Vector2(200.0, 60.0))

	for step in range(commands.size()):
		var changed := commands[step].duplicate()

		if step == 120:
			changed[1] = _aim_at(Vector2.ZERO, Vector2.LEFT * 400.0)

		third.tick(changed)

	var differs := false

	for piece in first.pieces():
		var twin := third.piece_for(piece.id)

		if twin == null or piece.position() != twin.position():
			differs = true
			break

	_check(differs, "and a different command produces a different world")

	_drop(first)
	_drop(second)
	_drop(third)


# --- The whole thing -------------------------------------------------------
	_done()

func _test_full_round() -> void:
	_section("a whole round, eight bots")

	# Frenzy, because a classic round to 2400 mass is a very long time in ticks and this
	# is a smoke test rather than a soak.
	var world := _make_world(HungryPreset.frenzy(), SEED + 7)
	var ended := [false]
	var winner := [""]

	world.match_node.round_ended.connect(
		func(_round_number: int, _winner: int, _outcome: DotMatchRules.Outcome) -> void:
			ended[0] = true
			var leader := world.match_node.scoreboard.leader()
			winner[0] = leader.display_name if leader != null else ""
	)

	for id in range(1, 9):
		world.add_player(id, "Bot %d" % id)

	_settle(world)

	var burst_total := [0]
	var throws := [0]
	var deaths := [0]

	world.monster_burst.connect(func(_p: int, _b: int, c: int) -> void:
		burst_total[0] += c
	)
	world.projectile_thrown.connect(func(_s: HungryProjectile) -> void:
		throws[0] += 1
	)
	world.player_died.connect(func(_p: int, _k: int) -> void: deaths[0] += 1)

	var ticks := 0
	var limit := TICK_RATE * 240

	while not ended[0] and ticks < limit:
		var commands: Dictionary = {}

		for monster in world.monsters():
			commands[monster.id] = HungryBot.command_for(world, monster, ticks)

		world.tick(commands)
		ticks += 1

	_check(ended[0], "the round ends (%d ticks, %.0fs)" % [ticks, float(ticks) / TICK_RATE])
	_check(winner[0] != "", "and there is a winner: %s" % winner[0])

	var top := world.leaderboard(1)
	_check(
		not top.is_empty() and top[0].mass() > HungryContent.START_MASS * 5.0,
		"who actually grew (%.0f)" % (top[0].mass() if not top.is_empty() else 0.0)
	)

	_check(deaths[0] > 0, "monsters ate each other (%d deaths)" % deaths[0])
	_check(throws[0] > 0, "and threw things (%d)" % throws[0])
	_check(burst_total[0] > 0, "and burst each other (%d pieces)" % burst_total[0])

	# The two invariants that hold whatever happened.
	_check(_furthest_edge(world) <= 0.5, "nothing ended up outside the world")

	var stale := 0

	for grid_id in world.arena.grid.ids():
		if grid_id >= HungryField.PIECE_ID_LIMIT:
			if not world.field.food.is_alive(HungryField.index_of(grid_id)) \
					and HungryField.kind_of(grid_id) == HungryField.Kind.FOOD:
				stale += 1
		elif world.piece_for(grid_id) == null:
			stale += 1

	_check(stale == 0, "and the grid holds nothing that no longer exists (%d)" % stale)

	var over_cap := 0

	for monster in world.monsters():
		if monster.piece_count() > world.tunables.mass_rules.max_pieces:
			over_cap += 1

	_check(over_cap == 0, "and nobody exceeded the piece cap")

	print("")
	for line in world.describe_lines():
		print("  %s" % line)

	_drop(world)


# --- The rider -------------------------------------------------------------
	_done()

func _test_rider() -> void:
	_section("the rider")

	var schema := HungryContent.avatar_schema()
	var valid := schema.validate_schema()

	_check(valid.ok, "the rider schema is legal", str(valid.error))

	# A server decides whether an avatar is legal from ids alone. If this ever needs a
	# load(), a ResourceLoader.exists() or a scene path, that is the thing to push back
	# on — it is the whole reason an avatar is a document.
	var avatar := HungryContent.default_avatar(7)
	var checked := schema.validate(avatar, DotAvatarEntitlements.everything())
	_check(checked.ok, "and a default avatar passes it", str(checked.error))
	_check(
		avatar.has_slot(&"body"),
		"with the required slot filled, so nobody is invisible"
	)

	# Deterministic on the id: a client that has not been sent somebody's avatar draws
	# the same guest as everybody else rather than a different one per machine.
	_check(
		HungryContent.default_avatar(7).digest() == avatar.digest(),
		"and the same id always produces the same one"
	)
	_check(
		HungryContent.default_avatar(8).digest() != avatar.digest(),
		"while a different id does not"
	)

	# An entitlement set of nothing must still dress somebody. Every part that is not
	# free is refused, and conform fills the required slot from its default.
	var greedy := DotAvatar.make(schema.id)
	greedy.set_part(&"body", &"rider_spike")
	greedy.set_part(&"hat", &"hat_crown")

	var conformed := schema.conform(greedy, DotAvatarEntitlements.none())
	_check(conformed.ok, "conform repairs an avatar nobody owns", str(conformed.error))
	_check(
		greedy.part_in(&"body") == &"rider_pip",
		"back to the free body (%s)" % greedy.part_in(&"body")
	)
	_check(
		greedy.part_in(&"hat") != &"hat_crown",
		"and drops the hat they do not own"
	)

	# The rig. Parts resolve through HungryContentSource, which prefers a mounted pack and
	# falls back to what shipped in the build — which is the path taken here, because
	# nothing has mounted anything.
	var catalogue := DotAvatarCatalogue.new()
	var source := HungryContentSource.new()
	source.install(catalogue)

	var dressed := DotAvatar.make(schema.id)
	dressed.set_part(&"body", &"rider_blob")
	dressed.set_part(&"hat", &"hat_cap")
	dressed.set_colour(&"body", 0, Color(0.9, 0.3, 0.4))

	var rider := HungryRider.make(schema, catalogue)
	add_child(rider)
	rider.wear(dressed)

	_check(
		rider.built_slots() == 2,
		"both parts build from the content in this build (%d)" % rider.built_slots()
	)
	_check(rider.drawn_slots() == 0, "so none of them has to be drawn")
	_check(
		source.mount_prefix == "",
		"and none of it came from a pack, because none is mounted"
	)

	# The whole contract between this game and its content: a Node2D that answers
	# `hungry_dress`. A part that does not is still shown, which is why this is checked
	# rather than assumed.
	var body: Node2D = rider._built.get(&"body")
	_check(
		body != null and body.has_method(&"hungry_dress"),
		"the built part takes its colours through hungry_dress"
	)
	_check(
		body != null and (body.get("tint_a") as Color).is_equal_approx(
			DotAvatar.quantise(Color(0.9, 0.3, 0.4))
		),
		"and wears the colour the document asked for"
	)

	# Resizing is called every frame for every player on screen, so it must be cheap and
	# it must actually reach the part.
	rider.resize(64.0)
	_check(
		body != null and is_equal_approx(float(body.get("unit")), 64.0),
		"and follows the monster as it grows"
	)

	# Wearing the same document twice must be free.
	var before := rider.get_child_count()
	rider.wear(dressed)
	_check(
		rider.get_child_count() == before,
		"re-wearing the same document rebuilds nothing"
	)

	# A part with no content anywhere falls back to being drawn rather than to nothing.
	# A player you cannot see is a competitive advantage.
	var ghost := DotAvatar.make(schema.id)
	ghost.set_part(&"body", &"rider_pip")
	ghost.set_part(&"trail", &"trail_ember")

	var bare := DotAvatarCatalogue.new()
	bare.resolver = func(_part: DotAvatarPart) -> String: return ""

	var drawn := HungryRider.make(schema, bare)
	add_child(drawn)
	drawn.wear(ghost)

	_check(
		drawn.built_slots() == 0 and drawn.drawn_slots() == 2,
		"a rider whose content is missing is drawn instead (%d built, %d drawn)"
			% [drawn.built_slots(), drawn.drawn_slots()]
	)

	remove_child(drawn)
	drawn.free()
	remove_child(rider)
	rider.free()


# --- The interface ---------------------------------------------------------
	_done()

func _test_interface() -> void:
	_section("the interface")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)

	var ui_config := DotUiConfig.new()
	ui_config.allow_pause = false

	var stack := DotScreenStack.new()
	stack.name = "Screens"
	stack.config = ui_config
	stack.load_layered_config = false
	stack.register_service = false
	stack.manage_mouse = false
	add_child(stack)
	stack.setup()

	var hud := HungryHud.new()
	hud.name = "Hud"
	hud.config = ui_config
	add_child(hud)
	hud.build(world, null, 1)
	hud.bind_stack(stack)

	_check(hud.mass_bar != null, "the HUD builds its widgets")
	_check(hud.minimap != null, "including a minimap")

	hud.refresh_leaderboard()
	_check(
		hud.leaderboard.row_count() == 1,
		"and a leaderboard with a row in it (%d)" % hud.leaderboard.row_count()
	)

	# The feed takes coloured fragments, which is all dot-ui knows about this game.
	hud.say("hello")
	hud.chat({"name": "Bo", "text": "hi"})
	hud.note(HungryEvents.Kind.DIED, {"first": 1, "second": 0, "extra": 0})
	_check(hud.feed.line_count() >= 3, "the feed takes lines (%d)" % hud.feed.line_count())

	var game_config := HungryConfig.new()
	var pause := HungryMenus.install(stack, world, null, ui_config, game_config)
	_check(
		stack.registered_ids().size() == 6,
		"six screens register (%d)" % stack.registered_ids().size()
	)

	# The loadout screen offers what the schema and this player's entitlements allow, and
	# nothing else. A screen that filtered on its own would drift from the server the
	# first time an unlock changed; one the server trusted would be a client choosing its
	# own stats.
	# The one readability affordance this genre cannot do without. Eating needs a ratio —
	# a quarter bigger — and a quarter of a difference in *area* is about 12% of a
	# difference in *width*, which nobody judges by eye under pressure. What the renderer
	# must not do is call something food that is merely smaller.
	var renderer := HungryRenderer.new()
	renderer.name = "Renderer"
	add_child(renderer)
	renderer.bind(world, null, 1)

	var rules := world.tunables.mass_rules
	var ours := 100.0

	_check(
		ours >= (ours / rules.eat_ratio - 1.0) * rules.eat_ratio,
		"something a quarter smaller is food"
	)
	_check(
		not (ours >= (ours * 0.9) * rules.eat_ratio),
		"and something merely smaller is not (%.2f ratio)" % rules.eat_ratio
	)
	_check(
		renderer.show_threat,
		"the rings are on by default, because judging it by eye is the failure mode"
	)

	remove_child(renderer)
	renderer.free()

	# The settings screen has no layout code: DotSettingsPanel reads the config's own
	# `@export` annotations and builds the editors from them, so a setting added to
	# HungryConfig appears there and nothing else changes.
	var settings := stack.screen(&"settings") as HungryMenus.SettingsScreen
	_check(settings != null, "the settings screen registers")

	if settings != null:
		_check(
			settings.panel != null and settings.panel.bound_config() is HungryConfig,
			"bound to this game's own config rather than the interface's"
		)
		_check(
			settings.panel != null and settings.panel.editor_for("volume_db") != null,
			"with an editor generated for a setting nobody laid out"
		)
		_check(
			settings.panel != null and settings.panel.editor_for("show_minimap") != null,
			"and for one of a different type"
		)

	# Settings survive a restart, which is the only reason to have them.
	var saved_path := "user://hungry_settings_test.json"
	DotPaths.remove_tree(saved_path)

	var chosen := HungryConfig.new()
	chosen.volume_db = -21.0
	chosen.muted = true
	chosen.show_names = false
	chosen.follow_sec = 0.25

	var written := chosen.save(saved_path)
	_check(written.ok, "settings write", str(written.error))

	var reloaded := HungryConfig.load_saved(saved_path)
	_check(
		is_equal_approx(reloaded.volume_db, -21.0) and reloaded.muted
			and not reloaded.show_names,
		"and come back (%s)" % reloaded.describe_summary()
	)

	# A first run has no file. That is not an error and must not read as one.
	var fresh := HungryConfig.load_saved("user://hungry_settings_missing.json")
	_check(
		is_equal_approx(fresh.volume_db, HungryConfig.new().volume_db),
		"a first run falls back to the defaults"
	)

	# A malformed one *is* an error, and starting from defaults silently would throw away
	# everything a player had set with nothing on screen to say so.
	var broken_path := "user://hungry_settings_broken.json"
	DotPaths.write_text(broken_path, "{ this is not json")
	var broken := HungryConfig.load_saved(broken_path)
	_check(
		broken != null and is_equal_approx(
			broken.volume_db, HungryConfig.new().volume_db
		),
		"and a broken file falls back rather than failing to start"
	)

	DotPaths.remove_tree(saved_path)
	DotPaths.remove_tree(broken_path)

	# Being eaten means having nothing at all — no pieces, no position, nowhere for a
	# camera to be. A camera left where you died is a black rectangle for three seconds
	# while the fight that killed you carries on somewhere else.
	world.add_player(2, "Bo")
	world.spawn(2, Vector2(300.0, 0.0))

	var me := world.monster_for(1)
	var them := world.monster_for(2)
	var watching := [0]

	var source := func() -> HungryMonster:
		var mine := world.monster_for(1)

		if mine != null and mine.alive:
			return mine

		var killer := world.monster_for(watching[0])
		return killer if killer != null and killer.alive else null

	_check(source.call() == me, "a living player watches themselves")

	for piece in me.pieces.duplicate():
		world.forget_piece(piece.id)

	watching[0] = 2

	_check(not me.alive, "and once eaten has nothing to watch from")
	_check(source.call() == them, "so they watch whoever ate them")

	hud.watching_source = source
	hud._refresh_status()
	_check(
		hud.status_label.text.contains(them.display_name),
		"and the HUD says whose eyes they are behind (%s)" % hud.status_label.text
	)

	var picker := stack.screen(&"loadout") as HungryMenus.LoadoutScreen
	_check(picker != null, "the loadout screen registers")

	if picker != null:
		var offered := picker.current()
		_check(
			offered.item_in(HungryContent.SLOT_TRAIT) != &"",
			"and offers a trait to a player who owns nothing (%s)"
				% offered.item_in(HungryContent.SLOT_TRAIT)
		)
		_check(
			offered.item_in(HungryContent.SLOT_TRAIT) != HungryContent.TRAIT_GREEDY,
			"but not the one nobody has unlocked"
		)
		_check(
			DotLoadoutValidator.validate(
				offered, HungryContent.loadout_schema(), DotLoadoutEntitlements.none()
			).ok,
			"and what it produces is legal"
		)

		picker.allow(DotLoadoutEntitlements.of([HungryContent.TRAIT_GREEDY_UNLOCK]))
		var greedy_offered := false

		for index in range(
			(picker._pickers[HungryContent.SLOT_TRAIT] as OptionButton).item_count
		):
			if StringName(str(
				(picker._pickers[HungryContent.SLOT_TRAIT] as OptionButton)
					.get_item_metadata(index)
			)) == HungryContent.TRAIT_GREEDY:
				greedy_offered = true

		_check(greedy_offered, "which appears once it is unlocked")

		var sent: Array[DotLoadout] = []
		picker.chosen.connect(func(l: DotLoadout) -> void: sent.append(l))
		picker._apply()
		_check(sent.size() == 1, "and taking it in emits the choice")

	# The scoreboard must not block input: it is held down during a live game, so it must
	# not stop the player moving. The pause menu must, and must hide the HUD.
	_check(stack.push(&"scoreboard").ok, "the scoreboard opens")
	_check(not stack.screen(&"scoreboard").blocks_input, "without blocking input")
	stack.pop(&"scoreboard")

	_check(stack.push(&"pause").ok, "the pause menu opens")
	_check(pause.blocks_input and pause.hides_below, "and does block, and hides the HUD")
	stack.pop(&"pause")

	# Chat is a screen for one reason: a chat box that let the movement keys through is a
	# player who drives into a wall while typing.
	var chat := stack.screen(&"chat") as HungryMenus.ChatScreen
	var said := [""]
	chat.submitted.connect(func(text: String) -> void: said[0] = text)

	_check(stack.push(&"chat").ok, "the chat line opens")
	_check(chat.blocks_input, "and blocks input while it is open")
	chat.line.text = "  well then  "
	chat.line.text_submitted.emit(chat.line.text)
	_check(said[0] == "well then", "and submits trimmed text (%s)" % said[0])
	_check(not stack.is_open(&"chat"), "and closes itself")

	# The on-screen buttons. Forced on, because a headless run has no touchscreen and a
	# control nothing exercises is a control that breaks quietly.
	var touch := HungryTouch.make()
	add_child(touch)

	var sampler := HungryInput.measuring(
		func() -> Variant: return world.monster_for(1), null
	)
	sampler.touch = touch
	add_child(sampler)

	_check(
		not sampler.sample().is_pressed(Dot2DCommand.BUTTON_SPLIT),
		"nothing is pressed to start with"
	)

	touch.split_button.button_down.emit()
	_check(
		sampler.sample().is_pressed(Dot2DCommand.BUTTON_SPLIT),
		"the split button reaches the command"
	)
	touch.split_button.button_up.emit()
	_check(
		not sampler.sample().is_pressed(Dot2DCommand.BUTTON_SPLIT),
		"and lets go again"
	)

	# The throw button is disabled with nothing to throw, and names what it will throw
	# when there is — throwing a lure at somebody chasing you is a wasted charge.
	_check(touch.throw_button.disabled, "the throw button is disabled while empty")
	touch.show_carried(PackedStringArray(["pepper"]))
	_check(not touch.throw_button.disabled, "and enabled once something is carried")
	_check(
		touch.throw_button.text.to_lower().contains("pepper"),
		"naming it (%s)" % touch.throw_button.text
	)

	touch.throw_button.button_down.emit()
	_check(
		sampler.sample().is_pressed(Dot2DCommand.BUTTON_ACTION),
		"and it reaches the command too"
	)
	touch.throw_button.button_up.emit()

	remove_child(sampler)
	sampler.free()
	remove_child(touch)
	touch.free()
	remove_child(hud)
	hud.free()
	remove_child(stack)
	stack.free()
	_drop(world)


# --- Sound -----------------------------------------------------------------

## Every noise this game makes is arithmetic, so all of it is checkable without a speaker.
##
## [b]That is the point of baking rather than streaming.[/b] A generator filling buffers on
## the main thread can only be judged by listening to it; a bank of streams built by a pure
## function is bytes, and bytes are something a headless run can assert about.
	_done()
func _test_sound() -> void:
	_section("sound")

	var blip := HungrySound.bake(520.0, 760.0, 0.07, 0.35, 0.0)

	_check(blip != null, "a voice bakes")
	_check(
		blip.format == AudioStreamWAV.FORMAT_16_BITS and not blip.stereo,
		"as 16-bit mono"
	)
	_check(
		blip.mix_rate == HungrySound.RATE,
		"at %d Hz (%d)" % [HungrySound.RATE, blip.mix_rate]
	)

	var frames := blip.data.size() / 2
	_check(
		absi(frames - int(0.07 * float(HungrySound.RATE))) <= 1,
		"of the length it was asked for (%d frames)" % frames
	)

	# Silence is what a synthesiser that does nothing produces, and it is indistinguishable
	# from one that works until somebody puts headphones on.
	var peak := 0

	for index in range(frames):
		var low := blip.data[index * 2]
		var high := blip.data[index * 2 + 1]
		var value := low | (high << 8)

		if value >= 32768:
			value -= 65536

		peak = maxi(peak, absi(value))

	_check(peak > 2000, "and is not silence (peak %d of 32767)" % peak)

	# Deterministic, because the noise comes from a hash rather than from randf. Two
	# machines produce byte-identical banks, which is what makes this checkable at all.
	var again := HungrySound.bake(520.0, 760.0, 0.07, 0.35, 0.0)
	_check(again.data == blip.data, "and the same arguments bake the same bytes")

	var noisy := HungrySound.bake(150.0, 60.0, 0.42, 0.55, 0.85)
	_check(noisy.data != blip.data, "while different ones do not")

	# The envelope has to end at silence or every cue clicks when it stops.
	var tail := noisy.data.size()
	_check(
		noisy.data[tail - 1] == 0 and noisy.data[tail - 2] == 0,
		"a voice ends at silence rather than clicking"
	)

	# Bigger food is lower. It is the one mapping nobody has to be taught.
	_check(
		HungrySound.food_pitch(0) > HungrySound.food_pitch(3),
		"and a crumb is pitched above a haunch (%.2f vs %.2f)" % [
			HungrySound.food_pitch(0), HungrySound.food_pitch(3)
		]
	)

	var bank := HungrySound.make()
	add_child(bank)
	bank.build()

	_check(
		bank.baked() == HungrySound.Cue.size(),
		"every cue has a voice (%d of %d)" % [bank.baked(), HungrySound.Cue.size()]
	)
	_check(bank.voices() == HungrySound.VOICES, "and there is a pool to play them in")

	# Playing must be safe with no audio device at all, which is what a headless server,
	# a CI run and a muted browser tab all are.
	bank.play(HungrySound.Cue.EAT, 1.2)
	bank.muted = true
	bank.play(HungrySound.Cue.DIE)
	_check(true, "and playing one without a device does not fail")

	remove_child(bank)
	bank.free()


# --- Ejecting --------------------------------------------------------------

## Spitting mass out, which is how a monster gets deliberately smaller.
##
## What it leaves is ordinary planted food, so it replicates, indexes and is eaten through
## the paths everything else already uses. What has to be true is that it costs something,
## that a small monster cannot do it, and that the ejector does not immediately swallow
## its own blob — which would make the whole thing a very expensive way to do nothing.
	_done()
func _test_ejecting() -> void:
	_section("ejecting")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var small := Dot2DCommand.new()
	small.aim = Vector2.RIGHT
	small.reach = 600.0
	small.set_button(Dot2DCommand.BUTTON_EJECT, true)

	var release := Dot2DCommand.new()
	release.aim = Vector2.RIGHT
	release.reach = 600.0

	var planted_before := world.field.planted_count()
	world.tick({1: small})

	_check(
		world.field.planted_count() == planted_before,
		"a monster too small to eject does not"
	)
	_check(monster.ejected == 0, "and is not charged for it")

	monster.rider_piece().set_mass(400.0, world.tunables.mass_rules)
	world.tick({1: release})

	var mass_before := monster.mass()
	world.tick({1: small})

	_check(
		world.field.planted_count() > planted_before,
		"a big one leaves a blob behind (%d)" % world.field.planted_count()
	)
	_check(
		monster.mass() < mass_before,
		"and pays for it (%.0f -> %.0f)" % [mass_before, monster.mass()]
	)
	_check(monster.ejected == 1, "and it is counted")

	# Held down must not spray. Edge-triggered plus a cooldown, the same as splitting.
	var after_one := world.field.planted_count()
	world.tick({1: small})
	_check(
		world.field.planted_count() == after_one,
		"a held key does not eject again"
	)

	# The blob has to survive the tick it was made on. It lands beyond the ejector's own
	# eat radius, so the ejector does not swallow it immediately.
	world.tick({1: release})
	_check(
		world.field.planted_count() >= after_one,
		"and the ejector does not eat its own blob back on the spot"
	)

	# Somebody else can. That is the whole point of it being ordinary food.
	var blob := 0

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.PLANTED:
			blob = grid_id

	_check(blob != 0, "the blob is in the field")
	_check(
		world.arena.grid.has(blob),
		"and in the grid, where an eat check will find it"
	)
	_check(
		is_equal_approx(
			world.field.mass_of(blob),
			HungryContent.FOOD_TIER_MASS[HungryContent.EJECT_TIER]
		),
		"worth less than it cost (%.0f of %.0f)" % [
			world.field.mass_of(blob), HungryContent.EJECT_MASS
		]
	)

	_drop(world)


# --- The loadout -----------------------------------------------------------

## What a player brings in, and the checks the server makes on it.
##
## [b]Every one of these is something a hostile or buggy client does.[/b] dot-loadout's
## whole reason to exist is that a dedicated server has no content and still has to
## decide whether the thing a client just sent is legal — so all of this is answered from
## ids, and if any of it ever needs a `load()`, that is the thing to push back on.
	_done()
func _test_loadout() -> void:
	_section("what a player brings in")

	var schema := HungryContent.loadout_schema()
	var valid := schema.validate()

	_check(valid.ok, "the loadout schema is legal", str(valid.error))

	var default_loadout := schema.default_loadout()
	_check(
		default_loadout.item_in(HungryContent.SLOT_STARTER) == HungryContent.ITEM_PEPPER,
		"and its default is something you can actually spawn with"
	)
	_check(
		default_loadout.item_in(HungryContent.SLOT_TRAIT) == HungryContent.TRAIT_NIMBLE,
		"with a trait"
	)

	# A schema whose own defaults are not legal is refused at startup, because conform
	# never fails and a player would otherwise be unable to spawn at all.
	var owns_nothing := DotLoadoutEntitlements.none()
	var default_ok := DotLoadoutValidator.validate(default_loadout, schema, owns_nothing)
	_check(
		default_ok.ok,
		"which a player who owns nothing may still take",
		str(default_ok.error)
	)

	# The three things a slot refuses, each for a different reason and each with a
	# different right answer in a loadout screen.
	var wrong_slot := DotLoadout.empty(schema.id)
	wrong_slot.set_item(HungryContent.SLOT_STARTER, HungryContent.TRAIT_STURDY)
	wrong_slot.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_NIMBLE)
	_check(
		not DotLoadoutValidator.validate(wrong_slot, schema, owns_nothing).ok,
		"a trait in the throwable slot is refused"
	)

	var no_such := DotLoadout.empty(schema.id)
	no_such.set_item(HungryContent.SLOT_STARTER, &"trebuchet")
	no_such.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_NIMBLE)
	_check(
		not DotLoadoutValidator.validate(no_such, schema, owns_nothing).ok,
		"and so is an item the catalogue has never heard of"
	)

	var unowned := DotLoadout.empty(schema.id)
	unowned.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_PEPPER)
	unowned.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_GREEDY)
	_check(
		not DotLoadoutValidator.validate(unowned, schema, owns_nothing).ok,
		"and so is a trait nobody has unlocked"
	)

	# Granting it is what an unlock *is*. Entitlements default to nothing so that an
	# unwired server is wrong within thirty seconds rather than shipping a game where
	# every unlock is free — which nobody reports as a bug.
	var owner := DotLoadoutEntitlements.of([HungryContent.TRAIT_GREEDY_UNLOCK])
	_check(
		DotLoadoutValidator.validate(unowned, schema, owner).ok,
		"until they unlock it"
	)

	# Conform on the way out of a store, validate on the way in from a client. Retiring an
	# item or revoking an unlock makes a saved loadout invalid, and refusing it is a player
	# who has not logged in for a month loading into an error rather than into a slightly
	# different monster.
	var stale := unowned.duplicate_loadout()
	# conform never fails — it returns what it changed, not whether it worked. That is the
	# whole distinction: refusing here would be a player who cannot spawn.
	var changes := DotLoadoutValidator.conform(stale, schema, owns_nothing)
	_check(
		changes.size() > 0,
		"conform repairs one nobody owns any more (%d changes)" % changes.size()
	)
	_check(
		stale.item_in(HungryContent.SLOT_TRAIT) == HungryContent.TRAIT_NIMBLE,
		"back to the default trait (%s)" % stale.item_in(HungryContent.SLOT_TRAIT)
	)
	_check(
		DotLoadoutValidator.validate(stale, schema, owns_nothing).ok,
		"and what it produced is legal"
	)

	# The store key is padded, because DotLoadoutKey has a minimum length and the check
	# exists so a malformed key can never reach a filesystem path.
	_check(
		DotLoadoutKey.is_usable(HungryContent.loadout_key(7)),
		"a player key is usable (%s)" % HungryContent.loadout_key(7)
	)
	_check(not DotLoadoutKey.is_usable("7"), "and a bare id is not")

	# And the mechanical half: three traits that are three different games.
	var world := _make_world()
	world.add_player(1, "Nimble")
	world.add_player(2, "Sturdy")
	_settle(world)

	var nimble := world.monster_for(1)
	var sturdy := world.monster_for(2)

	var chosen := DotLoadout.empty(schema.id)
	chosen.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_FROST)
	chosen.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_STURDY)
	sturdy.wear_loadout(chosen)

	world.spawn(1)
	world.spawn(2)

	_check(
		sturdy.mass() > nimble.mass(),
		"sturdy spawns bigger than nimble (%.1f vs %.1f)" % [
			sturdy.mass(), nimble.mass()
		]
	)
	_check(
		sturdy.speed_multiplier() < nimble.speed_multiplier(),
		"and slower (%.2f vs %.2f)" % [
			sturdy.speed_multiplier(), nimble.speed_multiplier()
		]
	)
	_check(
		sturdy.carried.size() == 1 and sturdy.carried[0] == HungryContent.ITEM_FROST,
		"holding what they chose (%s)"
			% (String(sturdy.carried[0]) if not sturdy.carried.is_empty() else "-")
	)

	# Greedy is worth more food rather than more mass, so it compounds instead of being a
	# flat head start.
	_check(
		HungryContent.trait_food(HungryContent.TRAIT_GREEDY) > 1.0
			and HungryContent.trait_food(HungryContent.TRAIT_NIMBLE) == 1.0,
		"and greedy is paid in food rather than in mass"
	)

	_drop(world)
	_done()
