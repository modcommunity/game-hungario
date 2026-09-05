class_name HungryBot
extends RefCounted

## A monster that plays itself.
##
## [b]It is a test fixture and a server that is never empty, not an opponent.[/b] It
## chases the best thing it can reach, runs from anything that can eat it, splits when
## that would win a chase, and throws what it is carrying at whoever is in front of it.
## That is enough to exercise every path in [HungryWorld] — eating, bursting, merging,
## dying, respawning — which is the job.
##
## [b]Everything here is deterministic.[/b] No [method @GlobalScope.randf], no clock: a
## bot's command is a pure function of the world, its own id and the tick, so a replay of
## a recorded round produces the same one. The little bit of variety that stops eight bots
## from moving as one body comes from hashing the id, which is the same trick
## [Dot2DScatter] uses to place a field.

## How far a bot looks, in world units. Roughly a screen, so it does not react to things
## a player could not see it react to.
const SIGHT := 900.0

## How much bigger something has to be before it is worth running from. Slightly under
## the eat ratio, so a bot starts moving before it is actually in danger.
const FEAR_RATIO := 1.15

## Split when the prey is within this many of the bot's own radii and the split would
## still leave each half big enough to eat them.
const SPLIT_REACH := 3.2

## Throw at anything inside this, roughly ahead.
const THROW_REACH := 700.0


## The command this bot wants this tick.
static func command_for(
	world: HungryWorld,
	monster: HungryMonster,
	tick: int
) -> Dot2DCommand:
	var command := Dot2DCommand.new()

	if world == null or monster == null or not monster.alive:
		return command

	var head := monster.rider_piece()

	if head == null:
		return command

	var origin := head.position()
	var rules := world.tunables.mass_rules

	var threat := Vector2.ZERO
	var threat_distance := INF

	var prey: HungryPiece = null
	var prey_distance := INF

	## The nearest piece belonging to anybody else, whatever its size.
	##
	## Separate from prey and from threat because a throwable is useful against both, and
	## a pepper is [i]most[/i] useful against something too big to eat: bursting it is how
	## a small monster turns an unwinnable fight into several winnable ones.
	var enemy: HungryPiece = null
	var enemy_distance := INF

	var snack := Vector2.ZERO
	var snack_score := -INF

	for grid_id in world.arena.grid.query_rect(
		Rect2(origin - Vector2(SIGHT, SIGHT), Vector2(SIGHT, SIGHT) * 2.0), head.id
	):
		var at := world.arena.grid.position_of(grid_id)
		var distance := origin.distance_to(at)

		if distance <= 0.001:
			continue

		if grid_id < HungryField.PIECE_ID_LIMIT:
			var other := world.piece_for(grid_id)

			if other == null or other.owner_id == monster.id:
				continue

			if distance < enemy_distance:
				enemy_distance = distance
				enemy = other

			if other.mass() >= head.mass() * FEAR_RATIO:
				if distance < threat_distance:
					threat_distance = distance
					threat = at
			elif head.mass() >= other.mass() * rules.eat_ratio:
				if distance < prey_distance:
					prey_distance = distance
					prey = other

			continue

		if HungryField.kind_of(grid_id) == HungryField.Kind.ITEM:
			# Item drops are worth a detour even though they are worth no mass: a bot
			# that never picked one up would never exercise throwing.
			var item_score := 220.0 / (distance + 40.0)

			if item_score > snack_score:
				snack_score = item_score
				snack = at

			continue

		# Mass over distance, so a haunch across the map loses to a crumb underfoot but
		# beats a crumb on the far side of one.
		var score := world.field.mass_of(grid_id) / (distance + 40.0)

		if score > snack_score:
			snack_score = score
			snack = at

	var target := origin
	var deciding := true

	if threat_distance < head.radius() * 6.0 + 180.0:
		# Away from the threat, and biased along the wall rather than into it, because a
		# bot that flees straight into a corner dies there every time.
		var away := (origin - threat).normalized()
		var bounds := world.arena.bounds
		var inward := (bounds.get_center() - origin).normalized()
		target = origin + (away * 2.0 + inward).normalized() * 400.0
		deciding = false

	if deciding and prey != null:
		target = prey.position()

		var reach := head.radius() * SPLIT_REACH
		var half := head.mass() * 0.5

		# Splitting halves you, so it is only correct if the half can still eat them.
		# Without that check a bot splits itself into a snack.
		if prey_distance < reach and rules.can_split(head.mass(), monster.piece_count()) \
				and half >= prey.mass() * rules.eat_ratio:
			command.set_button(Dot2DCommand.BUTTON_SPLIT, true)

		deciding = false

	if deciding and snack_score > -INF:
		target = snack
		deciding = false

	if deciding:
		# Nothing in sight. Walk a deterministic circuit rather than standing still, so a
		# bot on an empty map still moves and still finds a field that has refilled.
		var phase := float(tick) * 0.006 + _jitter(monster.id) * TAU
		target = world.arena.bounds.get_center() \
			+ Vector2.from_angle(phase) * world.arena.bounds.size.x * 0.3

	# Throwing overrides the steering aim for this one tick, because a throw leaves along
	# the pointer and the most valuable target is usually the thing being run away from.
	# One tick of turning toward it is the cost, and the cooldown bounds how often.
	if enemy != null and enemy_distance < THROW_REACH and not monster.carried.is_empty():
		target = enemy.position()
		command.set_button(Dot2DCommand.BUTTON_ACTION, true)

	target = _off_the_wall(target, world.arena.bounds, head.radius())

	var offset := target - origin
	command.aim = offset.normalized() if offset.length_squared() > 0.000001 else Vector2.ZERO
	command.reach = minf(offset.length(), HungryNetCommand.MAX_REACH)

	return command


## Pulls a target away from the arena edge.
##
## [b]A bot that steers into a wall stops, and a stopped bot is a bot that is eaten.[/b]
## The motor clamps a move at the boundary, so a target beyond it produces an aim that is
## fully engaged and a monster that does not move at all — which reads as a bot that has
## given up rather than one that has run out of room. This is also the state the
## interpolation check spent a while stuck in.
##
## The margin scales with the monster, because what matters is where its *edge* ends up.
static func _off_the_wall(target: Vector2, bounds: Rect2, radius: float) -> Vector2:
	var margin := radius + 40.0

	return Vector2(
		clampf(target.x, bounds.position.x + margin, bounds.end.x - margin),
		clampf(target.y, bounds.position.y + margin, bounds.end.y - margin)
	)


## A stable value in [0, 1) for a bot, so eight of them do not orbit in lockstep.
static func _jitter(id: int) -> float:
	return Dot2DScatter._unit(Dot2DScatter._hash(id, 0xB07))
