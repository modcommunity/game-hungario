@tool
class_name HungryWorld
extends Node

## The game: an arena, four fields of food, a set of monsters, and the rules that
## connect them.
##
## [b]This is where dot-2d's deliberate gaps get filled.[/b] That addon ships the motor,
## the mass relationships, the spatial hash and the scatter field, and stops short of
## splitting and merging — because split pieces are [i]several entities owned by one
## player[/i], which needs an ownership model and a merge rule that are a game's design.
## They are here, and so are the three things this game adds on top of them: food that
## comes in sizes, fruit that does something, and throwables that take the decision to
## split away from the player being split.
##
## [b]No autoload.[/b] It registers itself in [DotRegistry] under [constant SERVICE], so
## [HungryModule] can find it without being handed it, and a process running a server and
## a client at once gives each one a [member service_scope].

const CHANNEL := "hungry"
const SERVICE := &"hungry_world"

## A monster ate a piece of food or a planted crumb.
signal food_eaten(player_id: int, grid_id: int, mass: float)

## A monster ate a fruit.
signal fruit_eaten(player_id: int, grid_id: int, kind: HungryContent.Fruit)

## A monster picked a throwable up.
signal item_taken(player_id: int, grid_id: int, item: StringName)

## A piece ate another player's piece.
signal piece_eaten(eater_id: int, victim_player: int, mass: float)

## A player lost their last piece.
signal player_died(player_id: int, killer_id: int)

signal player_spawned(player_id: int)

## A piece came into or went out of existence. What the netcode bridge replicates.
signal piece_created(piece: HungryPiece)
signal piece_destroyed(piece: HungryPiece)

signal projectile_thrown(shot: HungryProjectile)
signal projectile_impact(shot: HungryProjectile, at: Vector2, hit_player: int)

## Somebody was burst by a pepper.
signal monster_burst(player_id: int, by_player: int, pieces: int)

signal match_state_changed(from: DotMatch.State, to: DotMatch.State)

## The food field changed and a delta is waiting in [member field].
signal field_changed()

@export_group("Simulation")

@export_range(1, 240, 1) var tick_rate: int = HungryContent.TICK_RATE

## Whether this instance decides who eats whom.
##
## A client runs the same world with this off: it simulates the pieces it owns so its own
## monster is smooth, and never resolves an absorption. A client that resolved its own
## eating would be a client that decides what it weighs.
@export var is_authority: bool = true

@export_group("World")

## Which mode this is. Null means [method HungryPreset.classic].
##
## Read once, in [method setup]. Changing it afterwards does nothing, which is deliberate:
## a mode that could change mid-round would have to resize the arena under everybody.
@export var preset: HungryPreset = null

@export var world_size: Vector2 = HungryContent.WORLD_SIZE

## Two peers with the same seed lay the same fields out, so a client can place eleven
## hundred pieces of food from one integer rather than receiving eleven hundred
## positions.
@export_range(1, 2147483647, 1) var world_seed: int = 20260828

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

var arena: Dot2DArena = null
var field: HungryField = null
var match_node: DotMatch = null
var tunables: Dot2DTunables = null
var motor: Dot2DMotor = null

## The throwables a monster may carry. dot-loadout's, so the server can check one
## without loading anything.
var items: DotItemCatalogue = null

## player id -> [HungryMonster].
var _monsters: Dictionary = {}

## piece id -> [HungryPiece]. Every live piece in the world.
var _pieces: Dictionary = {}

## projectile id -> [HungryProjectile].
var _shots: Dictionary = {}

var _next_piece_id: int = 1
var _next_shot_id: int = 1
var _tick: int = 0
var _registered_name: StringName = &""

## Tunables with a monster's current speed multiplier folded in. One instance, reused:
## see [method _tunables_for].
var _scaled: Dot2DTunables = null

## One piece's view of its monster's command. One instance, reused: see
## [method command_for_piece].
var _piece_command: Dot2DCommand = Dot2DCommand.new()


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


func setup() -> DotResult:
	if preset == null:
		preset = HungryPreset.classic()

	var preset_valid := preset.validate()

	if not preset_valid.ok:
		return preset_valid

	world_size = preset.world_size

	tunables = HungryContent.tunables()
	tunables.max_speed = preset.max_speed
	tunables.mass_rules.merge_delay_sec = preset.merge_delay_sec

	var valid := tunables.validate()

	if not valid.ok:
		return valid

	items = HungryContent.item_catalogue()

	var catalogue_valid := items.validate()

	if not catalogue_valid.ok:
		return catalogue_valid

	arena = Dot2DArena.new()
	arena.name = "Arena"
	arena.register_service = false
	arena.bounds = Rect2(-world_size * 0.5, world_size)
	arena.cell_size = HungryContent.CELL_SIZE
	arena.interest_extent = Vector2(1180.0, 760.0)
	arena.interest_scales_with_size = true
	add_child(arena)
	arena.setup()

	motor = Dot2DMotor.with_tunables(tunables)
	motor.body = arena.body

	_scaled = tunables.duplicate() as Dot2DTunables
	# The same rules object, not a copy of it: the eat ratio and the radius curve are
	# global, and two copies that drifted apart would put a monster's drawn radius and
	# its eat radius in different places.
	_scaled.mass_rules = tunables.mass_rules

	field = HungryField.over(arena.bounds, world_seed)
	field.food.target_count = preset.food_target
	field.fruit.target_count = preset.fruit_target
	field.items.target_count = preset.item_target
	field.fill_all()
	field.populate(arena.grid)

	var match_result := _build_match()

	if not match_result.ok:
		return match_result

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &""
			else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	return DotResult.success(null)


func _build_match() -> DotResult:
	var rules := HungryContent.rules(tick_rate)
	rules.mass_to_win = preset.win_mass
	rules.time_limit_sec = preset.time_limit_sec
	# The win condition is mass, and dot-match cannot know what mass is. This is the
	# whole of that bridge.
	rules.mass_fn = func(key: String) -> float:
		var monster := monster_for(int(key))
		return monster.mass() if monster != null else 0.0

	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.rules = rules
	match_node.register_service = false

	var config := DotMatchConfig.new()
	config.tick_rate = tick_rate
	config.auto_start = false
	config.balance_between_rounds = false
	config.idle_seconds = 0.0
	match_node.config = config

	# Before the match node enters the tree: [method DotMatch.refresh_spawns] runs from
	# `_ready` and warns when it finds nothing, so a point added afterwards silences every
	# respawn but not the one at startup.
	_add_spawn_point()
	add_child(match_node)

	match_node.respawn_due.connect(_on_respawn_due)
	match_node.state_changed.connect(
		func(from: DotMatch.State, to: DotMatch.State) -> void:
			# Reset first, announce afterwards. A listener told the round had started
			# while the old field was still in place — which is what announcing first
			# does — sends every client the field that is about to be thrown away, and
			# the new one then arrives as a delta on top of it. The symptom is a client
			# holding exactly twice as much food as exists, half of it phantoms.
			if to == DotMatch.State.LIVE:
				reset_world()

			match_state_changed.emit(from, to)
	)

	return DotResult.success(null)


## Gives dot-match one spawn point, which this game then ignores.
##
## [b]It is never read.[/b] Where a monster appears is decided by [method _safe_spawn],
## which asks the arena for a deterministic position and rejects the ones with something
## big enough to eat you standing on them — a 2D question that [DotSpawnSelector] cannot
## answer, because a spawn point is a [Node3D] and danger here is a mass ratio rather than
## a sight line.
##
## But dot-match's respawn path asks its selector for a point every time somebody comes
## back, and warns once per respawn when there is none. On a busy server that is a warning
## a second, all of them about a decision this game is deliberately making itself, and a
## log full of those is a log nobody reads. One point at the origin costs nothing and
## keeps the warnings about real problems.
func _add_spawn_point() -> void:
	var point := DotSpawnPoint.new()
	point.name = "Nominal"
	# No cooldown: with one point, a cooldown would make it unavailable for two seconds
	# after every respawn and put the warning straight back.
	point.cooldown_ticks = 0
	match_node.add_child(point)


func start(tick: int = 0) -> void:
	_tick = tick
	match_node.start(tick)


## Puts the world back to its starting state. What a new round does.
func reset_world() -> void:
	# Through `_destroy_piece`, not by clearing the dictionary. Clearing it forgets the
	# pieces without ever emitting [signal piece_destroyed], and the netcode bridge is
	# listening to exactly that signal: the entities would stay registered, every client
	# would keep the old round's pieces on screen for ever, and the piece count would
	# double every round. Nothing errors, because from the world's own point of view the
	# pieces really are gone.
	for piece_id in _sorted_piece_ids():
		var piece: HungryPiece = _pieces.get(piece_id)

		if piece != null:
			_destroy_piece(piece)

	_pieces.clear()
	_shots.clear()

	for monster in monsters():
		monster.clear_pieces()
		monster.carried.clear()
		monster.effects.clear()

	# The old field leaves the grid before the new one enters it.
	#
	# Slot indices are never reused, so the new field's grid ids sit *beside* the old
	# field's rather than overwriting them. Without this the grid ends a round holding
	# twice as much food as exists, half of it phantoms at stale positions that `take()`
	# then refuses — and eating quietly stops working. This is the bug game-blob found
	# the hard way and it is the same one here, three fields wide.
	for grid_id in field.alive_ids():
		arena.grid.remove(grid_id)

	# A fresh seed per round, so a server that has been up all night is not laying the
	# same field out for the hundredth time and the regulars have not learnt it.
	field.reseed(world_seed + match_node.round_number)
	field.fill_all()
	field.populate(arena.grid)
	field_changed.emit()


## Adopts the authority's world size. Client side, from the hello.
##
## Called before the seed, and it has to be: the field's positions are hashed into the
## arena rectangle, so adopting a seed against the wrong rectangle lays the whole field
## out somewhere else. See [method HungryField.set_bounds].
func adopt_world_size(size: Vector2) -> void:
	if size.x <= 1.0 or size.y <= 1.0 or size.is_equal_approx(world_size):
		return

	world_size = size
	arena.bounds = Rect2(-size * 0.5, size)

	if arena.body != null:
		arena.body.bounds = arena.bounds

	field.set_bounds(arena.bounds)

	DotLog.debug(CHANNEL, "adopted the authority's world size", {"size": size})


## Adopts the authority's field seed and empties the field. Client side.
##
## The client is told what is alive rather than laying a field out itself, even though it
## could: a client that filled from the seed would be right at the start of a round and
## wrong for ever afterwards, because which slots have been eaten is not derivable from
## anything. The seed is what saves the [i]positions[/i]; the membership still travels.
func adopt_field_seed(new_seed: int) -> void:
	for grid_id in field.alive_ids():
		arena.grid.remove(grid_id)

	field.reseed(new_seed)
	field_changed.emit()


## Applies a field delta. Client side.
func apply_field_delta(
	added: Array,
	removed: Array,
	planted: Dictionary = {}
) -> void:
	for entry in removed:
		arena.grid.remove(int(entry))

	field.apply_delta(added, removed, planted)

	for entry in added:
		var grid_id := int(entry)
		arena.grid.place(grid_id, field.position_of(grid_id), field.radius_of(grid_id))

	# Drained rather than left to accumulate: a client has nobody to send it to, and a
	# delta nothing consumes is a dictionary that grows for the length of the session.
	field.drain_delta()
	field_changed.emit()


# --- Players ---------------------------------------------------------------

func add_player(id: int, display_name: String) -> DotResult:
	if _monsters.has(id):
		return DotResult.fail(DotError.CODE_STATE, "Player %d is already here." % id)

	var monster := HungryMonster.make(id, display_name)
	_monsters[id] = monster

	var added := match_node.add_player(str(id), display_name, _tick)

	if not added.ok:
		_monsters.erase(id)
		return added

	return DotResult.success(monster)


func remove_player(id: int) -> void:
	var monster := monster_for(id)

	if monster == null:
		return

	for piece in monster.pieces.duplicate():
		_destroy_piece(piece)

	match_node.remove_player(str(id))
	_monsters.erase(id)


func monster_for(id: int) -> HungryMonster:
	return _monsters.get(id)


func monsters() -> Array[HungryMonster]:
	var out: Array[HungryMonster] = []
	for key in _monsters.keys():
		out.append(_monsters[key])
	return out


func player_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _monsters.keys():
		out.append(int(key))
	out.sort()
	return out


func piece_for(piece_id: int) -> HungryPiece:
	return _pieces.get(piece_id)


func pieces() -> Array[HungryPiece]:
	var out: Array[HungryPiece] = []
	for key in _sorted_piece_ids():
		out.append(_pieces[key])
	return out


func piece_count() -> int:
	return _pieces.size()


func projectiles() -> Array[HungryProjectile]:
	var out: Array[HungryProjectile] = []
	var keys := _shots.keys()
	keys.sort()
	for key in keys:
		out.append(_shots[key])
	return out


## Puts a player in the world with one piece.
func spawn(id: int, at: Vector2 = Vector2.INF) -> void:
	var monster := monster_for(id)

	if monster == null:
		return

	for piece in monster.pieces.duplicate():
		_destroy_piece(piece)

	monster.clear_pieces()
	monster.effects.clear()

	var position := at if at != Vector2.INF else _safe_spawn(id)
	# The trait trades starting mass against speed, so it is applied here rather than
	# folded into the constant: two players spawn at different sizes and the number a
	# reader looks up is still the one in HungryContent.
	var start := HungryContent.START_MASS * HungryContent.trait_mass(monster.trait_id)
	attach_piece(monster, position, start)

	monster.carried.clear()

	# Everybody spawns holding one of whatever they chose. It is the only mechanical thing
	# the loadout does on the way in, and it is what makes the choice visible in the first
	# ten seconds rather than the first ten minutes.
	monster.take_item(monster.starter_item())

	monster.best_mass = start
	monster.split_ready_tick = _tick
	monster.throw_ready_tick = _tick
	monster.eject_ready_tick = _tick
	monster.apply_effect(
		HungryContent.FLAG_PROTECTED,
		_tick + match_node.spawn_protection_ticks()
	)

	player_spawned.emit(id)


## A spawn position with nobody big enough to eat you standing on it.
##
## Deterministic candidates from the arena, filtered by what is actually there. A random
## spawn that happened to land inside the leader is a player who dies before they have
## moved, and on a busy server it happens often enough to be the first thing anyone
## complains about.
func _safe_spawn(id: int) -> Vector2:
	var start_radius := tunables.mass_rules.radius_for(HungryContent.START_MASS)

	for attempt in range(14):
		var candidate := arena.spawn_position(id * 977 + attempt + _tick, 240.0)
		var threats := arena.overlapping(candidate, start_radius * 7.0)
		var dangerous := false

		for other_id in threats:
			if other_id >= HungryField.PIECE_ID_LIMIT:
				continue

			var piece: HungryPiece = _pieces.get(other_id)

			if piece != null and piece.mass() > HungryContent.START_MASS:
				dangerous = true
				break

		if not dangerous:
			return candidate

	# Every candidate was dangerous, which on a very full server is possible. Spawning
	# somewhere bad beats not spawning: the alternative is a player who watches.
	return arena.spawn_position(id, 240.0)


# --- Pieces ----------------------------------------------------------------

## Creates a piece and registers it with the arena.
##
## [param forced_id] is how a client mirrors a piece the authority has announced: the
## piece id goes on the wire and the two sides have to agree on it, because it is what
## the eaten and burst events name.
func attach_piece(
	monster: HungryMonster,
	at: Vector2,
	mass: float,
	forced_id: int = 0
) -> HungryPiece:
	var piece_id := forced_id

	if piece_id <= 0:
		piece_id = _next_piece_id
		_next_piece_id += 1
	else:
		_next_piece_id = maxi(_next_piece_id, piece_id + 1)

	var piece := HungryPiece.make(
		piece_id, monster.id, at, mass, tunables.mass_rules, _tick
	)

	monster.add_piece(piece)
	_pieces[piece.id] = piece
	arena.register(piece.id, piece.state)

	if is_authority:
		monster.flags = monster.effect_flags(_tick)

	_apply_flags(monster, piece)

	piece_created.emit(piece)
	return piece


func _destroy_piece(piece: HungryPiece) -> void:
	arena.forget(piece.id)
	_pieces.erase(piece.id)

	var monster := monster_for(piece.owner_id)

	if monster != null:
		monster.remove_piece(piece.id)

	piece_destroyed.emit(piece)


## Changes a piece's mass and puts it back inside the world.
##
## [b]Growing is a move.[/b] A piece hugging a wall that eats a crumb gets wider, and its
## edge is then outside the arena — the motor only clamps a piece that is moving, and one
## sitting still against a wall stays out. game-blob found this by running eight bots for
## two minutes and measuring the furthest edge, which came out 2.8 units past it. Nothing
## errored then either.
func _grow(piece: HungryPiece, mass: float) -> void:
	piece.set_mass(mass, tunables.mass_rules)
	piece.state.position = arena.clamp_position(piece.state.position, piece.radius())


# --- Simulation ------------------------------------------------------------

## Advances the whole world one tick. The authority's entry point.
##
## [b]The order is the design.[/b] Effects expire, then everything moves, then the grid
## is synced, then eating, then merging, then the projectiles, then the refill, then the
## scores, then the match. Each edge matters:
##
## - Eating before the grid sync would test last tick's positions.
## - Merging before eating would let two of your own pieces merge [i]through[/i] an
##   opponent that was about to eat one of them.
## - Projectiles after eating, so a pepper cannot burst somebody who has already been
##   swallowed this tick and no longer exists.
## - The match last, so a mass target reached this tick ends the round this tick.
##
## [param commands] is `{player id: Dot2DCommand}`. A player with no entry repeats their
## last command, because a dropped input packet means "still holding the mouse there".
func tick(commands: Dictionary = {}) -> void:
	_tick += 1

	var delta := 1.0 / float(tick_rate)

	_expire_effects()
	_simulate_monsters(commands, delta)
	arena.sync_grid()

	if not is_authority:
		return

	_resolve_field()
	_resolve_pieces()
	_resolve_merges()
	_resolve_projectiles()
	_refill_field()

	_sync_flags()
	_sync_scores()
	match_node.tick(_tick)


## Advances the parts of the world a client owns. Called once a tick on a client.
##
## [b]Everything a client is allowed to do on its own, and nothing else.[/b] Effects run
## out so the HUD stops showing one that has ended; the grid is re-synced so the minimap
## and the local range hints are not a tick stale; projectiles whose impact never arrived
## are dropped. What it deliberately does not do is tick the match, resolve eating, or
## move anybody — the match arrives replicated, eating is the authority's, and remote
## pieces are moved by the interpolator.
func client_tick(tick_value: int) -> void:
	_tick = tick_value

	_expire_effects()
	arena.sync_grid()

	for shot in projectiles():
		# A defensive prune only. Every projectile the authority resolves produces an
		# impact event on a reliable channel, so this should never fire — but a client
		# that lost one would otherwise draw a pepper flying to the edge of the world for
		# ever, and the margin is the difference between "late" and "never".
		if shot.distance_at(tick_value, tick_rate) > HungryContent.THROW_RANGE * 1.3:
			_shots.erase(shot.id)


## Advances one piece by one tick. The unit of client-side prediction.
##
## [b]One piece, and deliberately not the set.[/b] [DotNetPredictor] reconciles one
## entity at a time — it rewinds that entity to the server's answer and replays its
## unacknowledged inputs — so anything a replay does that couples two entities is
## computed against whatever the other one happened to be holding at the time. Keeping
## the predicted step to the motor makes it a pure function of (state, command, delta),
## which is the only shape a replay converges for.
##
## What that costs is [method _separate]: see [method separate_local].
func simulate_piece(
	piece: HungryPiece,
	monster: HungryMonster,
	command: Dot2DCommand,
	delta: float,
	tick_value: int
) -> void:
	if piece == null:
		return

	var used := command if command != null else Dot2DCommand.new()

	motor.tunables = _tunables_for(monster, tick_value) if monster != null else tunables
	motor.simulate(
		piece.state,
		command_for_piece(used, piece, pointer_of(monster, used)) if monster != null
			else used,
		delta,
		tick_value
	)
	motor.tunables = tunables


## Pushes one monster's own pieces apart. Client side, once per tick after predicting.
##
## [b]Applied live and not replayed.[/b] The authority separates every tick, and so does
## a client — but a reconciliation replay does not, because it runs per entity and
## separation is a property of the set. The consequence is bounded and worth writing
## down: for the second or so after a split, while the pieces are still overlapping, the
## client's shown positions and the replayed ones differ by a fraction of the overlap and
## the correction is eased out. Once the pieces are apart, separation does nothing at all
## and the two agree exactly — which is every other moment of the game.
func separate_local(monster: HungryMonster, delta: float) -> void:
	if monster != null:
		_separate(monster, delta)


func _expire_effects() -> void:
	for monster in monsters():
		monster.expire_effects(_tick)


## Tunables with this monster's current speed multiplier folded in.
##
## One reused instance rather than one per monster: it is read inside the same call it is
## written in, nothing holds a reference to it afterwards, and allocating a [Resource]
## per player per tick at 60 Hz is a lot of garbage for a number.
##
## The multiplier is applied to [member Dot2DTunables.max_speed] rather than to the mass
## curve, because the mass curve is what every other machine derives a radius from and
## a rushing monster is not a bigger one.
func _tunables_for(monster: HungryMonster, tick_value: int) -> Dot2DTunables:
	var multiplier := monster.speed_multiplier(tick_value)

	if is_equal_approx(multiplier, 1.0):
		return tunables

	_scaled.max_speed = tunables.max_speed * multiplier
	return _scaled


## Where the player is pointing, in world units.
##
## [Dot2DCommand] carries a direction and a distance rather than a position, because a
## [i]screen[/i] position depends on a window size and a camera zoom the server does not
## have. A [i]world[/i] position is perfectly meaningful, and it is recoverable: the
## sampler measures the pointer from the monster's centroid, so adding the same offset to
## the same centroid gets it back without another byte on the wire.
##
## [b]This matters far more than it sounds.[/b] Steering every piece along one shared
## direction makes a split monster travel as a rigid formation: the pieces move in
## parallel, at the same speed, for ever, and they never come back within merging
## distance of each other. Splitting would be permanent and merging unreachable — and
## nothing would error, because each piece individually did exactly what it was told.
##
## In agar.io every cell steers toward the cursor's [i]point[/i], which is what makes a
## split converge, what makes "let go to regroup" work, and what makes the trailing half
## of a split catch up.
static func pointer_of(monster: HungryMonster, command: Dot2DCommand) -> Vector2:
	if monster == null or command == null:
		return Vector2.ZERO

	return monster.centre() + command.aim * command.reach


## One piece's command: the monster's, re-aimed at the pointer from where this piece is.
##
## The returned object is reused between calls and is not retained by anything —
## [method Dot2DMotor.simulate] reads it and keeps nothing — because allocating a command
## per piece per tick at 60 Hz is a lot of garbage for four fields.
func command_for_piece(
	command: Dot2DCommand,
	piece: HungryPiece,
	pointer: Vector2
) -> Dot2DCommand:
	_piece_command.move = command.move
	_piece_command.buttons = command.buttons

	var offset := pointer - piece.position()

	if offset.length_squared() <= 0.000001:
		_piece_command.aim = Vector2.ZERO
		_piece_command.reach = 0.0
	else:
		_piece_command.aim = offset.normalized()
		_piece_command.reach = minf(offset.length(), HungryNetCommand.MAX_REACH)

	return _piece_command


func _simulate_monsters(commands: Dictionary, delta: float) -> void:
	for id in player_ids():
		var monster: HungryMonster = _monsters[id]

		if not monster.alive:
			continue

		var command: Dot2DCommand = commands.get(id)

		if command == null:
			command = (
				monster.last_command if monster.last_command != null
				else Dot2DCommand.new()
			)
		else:
			# Everything in here came from a client. A move vector of length 40 is not a
			# crash, it is a player who moves forty times as fast as everyone else.
			command.sanitise(1200.0)

		if is_authority:
			if command.just_pressed(Dot2DCommand.BUTTON_SPLIT, monster.last_command):
				_split(monster, command)

			if command.just_pressed(Dot2DCommand.BUTTON_ACTION, monster.last_command):
				_throw(monster, command)

			if command.just_pressed(Dot2DCommand.BUTTON_EJECT, monster.last_command):
				_eject(monster, command)

		monster.last_command = command.duplicate_command()

		motor.tunables = _tunables_for(monster, _tick)

		var pointer := pointer_of(monster, command)

		for piece in monster.pieces:
			motor.simulate(
				piece.state, command_for_piece(command, piece, pointer), delta, _tick
			)

		_separate(monster, delta)

	motor.tunables = tunables


## Keeps a monster's own pieces from sitting inside each other before they may merge.
##
## Without this a split immediately collapses back into a pile: the pieces all chase the
## same pointer at the same speed, so they arrive at the same place and stay there, and
## splitting stops meaning anything. Pushing them apart is what makes the pieces cover
## ground — and it is what makes a burst frightening rather than cosmetic.
func _separate(monster: HungryMonster, delta: float) -> void:
	if monster.pieces.size() < 2:
		return

	for a in range(monster.pieces.size()):
		for b in range(a + 1, monster.pieces.size()):
			var first := monster.pieces[a]
			var second := monster.pieces[b]

			if first.can_merge(_tick) and second.can_merge(_tick):
				continue

			var offset := second.position() - first.position()
			var distance := offset.length()
			var wanted := first.radius() + second.radius()

			if distance >= wanted:
				continue

			# A dead-centre overlap has no direction to push along, and normalising a
			# zero vector gives zero — which leaves two pieces fused for ever. The
			# fallback is arbitrary and deterministic, which is all it has to be.
			var away := (
				offset / distance if distance > 0.0001
				else Vector2.from_angle(float(first.id) * 0.7)
			)

			var push := (wanted - distance) * 0.5 * minf(1.0, delta * 12.0)
			first.state.position -= away * push
			second.state.position += away * push

			first.state.position = arena.clamp_position(
				first.state.position, first.radius()
			)
			second.state.position = arena.clamp_position(
				second.state.position, second.radius()
			)


# --- Eating ----------------------------------------------------------------

## Food, fruit and item drops. One query per piece over one grid.
func _resolve_field() -> void:
	var rules := tunables.mass_rules
	var touched := false

	for piece_id in _sorted_piece_ids():
		var piece: HungryPiece = _pieces.get(piece_id)

		if piece == null:
			continue

		var monster := monster_for(piece.owner_id)

		if monster == null:
			continue

		# Centres, not circles: a crumb is eaten when the piece covers it, and a circle
		# test would let a monster eat everything its edge merely brushes.
		for grid_id in arena.grid.query_circle(
			piece.position(), piece.radius() * rules.eat_overlap, piece.id
		):
			if not HungryField.is_edible(grid_id):
				continue

			match HungryField.kind_of(grid_id):
				HungryField.Kind.FOOD, HungryField.Kind.PLANTED:
					if _eat_food(monster, piece, grid_id):
						touched = true

				HungryField.Kind.FRUIT:
					if _eat_fruit(monster, piece, grid_id):
						touched = true

				HungryField.Kind.ITEM:
					if _take_item(monster, grid_id):
						touched = true

	if touched:
		field_changed.emit()


func _eat_food(monster: HungryMonster, piece: HungryPiece, grid_id: int) -> bool:
	# The greedy trait is worth more food rather than more mass outright, so it compounds
	# with how much you are already eating instead of being a flat head start.
	var gained := field.mass_of(grid_id) * HungryContent.trait_food(monster.trait_id)

	# take() returning false is food another piece got first on this same tick. Normal,
	# and the reason it returns a bool at all.
	if not field.take(grid_id):
		return false

	arena.grid.remove(grid_id)
	_grow(piece, piece.mass() + gained)

	monster.food_eaten += 1
	monster.best_mass = maxf(monster.best_mass, monster.mass())

	food_eaten.emit(monster.id, grid_id, gained)
	return true


func _eat_fruit(monster: HungryMonster, piece: HungryPiece, grid_id: int) -> bool:
	var kind := field.fruit_kind_of(grid_id)

	if not field.take(grid_id):
		return false

	arena.grid.remove(grid_id)
	_grow(piece, piece.mass() + HungryContent.FRUIT_MASS)

	var until := _tick + int(HungryContent.FRUIT_EFFECT_SEC * float(tick_rate))

	match kind:
		HungryContent.Fruit.RUSH:
			monster.apply_effect(HungryContent.FLAG_RUSH, until)
		HungryContent.Fruit.MAW:
			monster.apply_effect(HungryContent.FLAG_MAW, until)
		HungryContent.Fruit.RIND:
			monster.apply_effect(HungryContent.FLAG_RIND, until)

	monster.fruit_eaten += 1
	monster.best_mass = maxf(monster.best_mass, monster.mass())

	fruit_eaten.emit(monster.id, grid_id, kind)
	return true


## Picks a throwable up. Refused, and left where it is, when the monster is full.
##
## Leaving it rather than consuming it is the difference between "you are carrying three
## already" and "that pepper vanished". The second one reads as a bug every time.
func _take_item(monster: HungryMonster, grid_id: int) -> bool:
	if monster.carried.size() >= HungryContent.MAX_CARRIED:
		return false

	var item := field.item_id_of(grid_id)

	# The catalogue is the authority on what an id means. An unknown one is a content
	# mismatch rather than a legal pickup, and swallowing it silently would hand the
	# player a charge of nothing.
	if items.find(item) == null:
		DotLog.warn(CHANNEL, "item drop names an id the catalogue does not have", {
			"item": String(item)
		})
		return false

	if not field.take(grid_id):
		return false

	arena.grid.remove(grid_id)
	monster.take_item(item)

	item_taken.emit(monster.id, grid_id, item)
	return true


## Monsters eating monsters.
func _resolve_pieces() -> void:
	var rules := tunables.mass_rules
	var eaten := {}

	# Sorted, so two machines resolve the same collisions in the same order. Dictionary
	# iteration order is not a guarantee, and with three pieces in a pile the order
	# decides which two of the three survive. The `eaten` set because one piece can be
	# in range of two eaters on the same tick.
	for piece_id in _sorted_piece_ids():
		if eaten.has(piece_id):
			continue

		var piece: HungryPiece = _pieces.get(piece_id)

		if piece == null:
			continue

		var eater := monster_for(piece.owner_id)

		if eater == null or eater.has_effect(HungryContent.FLAG_PROTECTED, _tick):
			continue

		# The maw fruit lowers the ratio rather than raising the eater's mass: raising
		# the mass would also make them slower and wider, which is not what eating a
		# fruit called "maw" should do.
		var ratio := rules.eat_ratio * eater.eat_ratio_multiplier(_tick)

		for other_id in arena.grid.query_circle(
			piece.position(), piece.radius() * rules.eat_overlap, piece.id
		):
			if other_id >= HungryField.PIECE_ID_LIMIT or eaten.has(other_id):
				continue

			var victim: HungryPiece = _pieces.get(other_id)

			if victim == null or victim.owner_id == piece.owner_id:
				continue

			var prey := monster_for(victim.owner_id)

			if prey == null or prey.has_effect(HungryContent.FLAG_PROTECTED, _tick):
				continue

			if piece.mass() < victim.mass() * ratio:
				continue

			if piece.position().distance_to(victim.position()) \
					> piece.radius() * rules.eat_overlap:
				continue

			eaten[other_id] = true
			_absorb(piece, victim, rules)


func _absorb(eater: HungryPiece, victim: HungryPiece, rules: Dot2DMassRules) -> void:
	var gained := victim.mass()

	_grow(eater, rules.absorb(eater.mass(), gained))

	var eater_monster := monster_for(eater.owner_id)
	var victim_monster := monster_for(victim.owner_id)

	if eater_monster != null:
		eater_monster.best_mass = maxf(eater_monster.best_mass, eater_monster.mass())

	piece_eaten.emit(eater.owner_id, victim.owner_id, gained)

	_destroy_piece(victim)

	if victim_monster != null and not victim_monster.alive:
		if eater_monster != null:
			eater_monster.players_eaten += 1

		# The victim's last piece. dot-match records the kill, the death and the respawn
		# timer; the world only says it happened.
		match_node.report_kill(
			str(eater.owner_id), str(victim.owner_id), &"devoured", _tick
		)
		player_died.emit(victim.owner_id, eater.owner_id)


## Removes a piece the authority says is gone. Client side.
func forget_piece(piece_id: int) -> void:
	var piece := piece_for(piece_id)

	if piece != null:
		_destroy_piece(piece)


func _sorted_piece_ids() -> Array[int]:
	var out: Array[int] = []

	for key in _pieces.keys():
		out.append(int(key))

	out.sort()
	return out


# --- Splitting, bursting and merging ---------------------------------------

## Halves every eligible piece and throws one half along the aim.
##
## Bounded by [member Dot2DMassRules.max_pieces] and by a cooldown. Without the cooldown
## a held key splits every tick and the piece limit is reached in a fifth of a second,
## which is not a decision — it is a stutter.
func _split(monster: HungryMonster, command: Dot2DCommand) -> int:
	var rules := tunables.mass_rules

	if _tick < monster.split_ready_tick or command.aim == Vector2.ZERO:
		return 0

	var made := 0
	# A copy: the loop adds pieces, and iterating the live array would split the pieces
	# it has just created — which halves everything twice in one press.
	#
	# Typed, because `Array.duplicate()` returns an *untyped* array, so the loop variable
	# would be a Variant and every `:=` derived from it a parse error. The family's
	# CLAUDE.md calls this out and it is still the easiest one to walk into.
	var existing: Array[HungryPiece] = monster.pieces.duplicate()

	for piece in existing:
		if monster.piece_count() >= rules.max_pieces:
			break

		if not rules.can_split(piece.mass(), monster.piece_count()):
			continue

		var half := piece.mass() * 0.5
		piece.set_mass(half, rules)

		var offset := command.aim.normalized() * (piece.radius() + 2.0)
		var child := attach_piece(
			monster,
			arena.clamp_position(piece.position() + offset, rules.radius_for(half)),
			half
		)

		motor.impulse(child.state, command.aim, rules.split_impulse)
		_delay_merge(piece, child)

		made += 1

	if made > 0:
		monster.split_ready_tick = _tick + HungryContent.SPLIT_COOLDOWN_TICKS

	return made


## Blows a monster apart. What a pepper does.
##
## [b]Not the same operation as a split, and it must not be.[/b] A split is a decision
## made along an aim; a burst is done to you, so it is radial, it ignores the cooldown,
## and it applies to every eligible piece at once. Returns how many new pieces it made.
func burst(monster: HungryMonster, by_player: int) -> int:
	if monster == null or not monster.alive:
		return 0

	# The rind fruit is spent stopping one burst rather than reducing it. A fruit that
	# made a burst smaller would be invisible; one that eats it outright is a thing a
	# player can feel they got value from.
	if monster.has_effect(HungryContent.FLAG_RIND, _tick):
		monster.clear_effect(HungryContent.FLAG_RIND)
		return 0

	var rules := tunables.mass_rules
	var made := 0
	var existing: Array[HungryPiece] = monster.pieces.duplicate()

	for piece in existing:
		if monster.piece_count() >= rules.max_pieces:
			break

		if piece.mass() < HungryContent.MIN_BURST_MASS:
			continue

		var room := rules.max_pieces - monster.piece_count() + 1
		var into := mini(HungryContent.PEPPER_PIECES, room)

		if into < 2:
			continue

		var share := piece.mass() / float(into)
		var origin := piece.position()
		piece.set_mass(share, rules)

		for step in range(1, into):
			# Radial, and seeded from the piece id so two machines that replay this tick
			# scatter the pieces the same way.
			var angle := TAU * float(step) / float(into) + float(piece.id) * 0.37
			var direction := Vector2.from_angle(angle)
			var at := arena.clamp_position(
				origin + direction * (piece.radius() + 3.0), rules.radius_for(share)
			)

			var child := attach_piece(monster, at, share)
			child.state.set_flag(HungryContent.FLAG_BURST, true)

			motor.impulse(child.state, direction, rules.split_impulse * 0.85)
			_delay_merge(piece, child)

			made += 1

	if made > 0:
		monster.times_burst += 1
		monster_burst.emit(monster.id, by_player, made)

	return made


## Both halves get the merge delay, not just the new one.
##
## A parent that could re-absorb its child immediately makes splitting free, and
## splitting is supposed to be a risk. It is also what stops a burst from healing itself
## in the same second it happened.
func _delay_merge(parent: HungryPiece, child: HungryPiece) -> void:
	var delay := int(tunables.mass_rules.merge_delay_sec * float(tick_rate))
	parent.merge_tick = _tick + delay
	child.merge_tick = _tick + delay


## Merges a monster's own pieces back together once their delay has passed.
func _resolve_merges() -> void:
	for monster in monsters():
		if monster.piece_count() < 2:
			continue

		var merged := true

		# Repeated until nothing changes: three pieces in a pile merge two at a time, and
		# a single pass would leave the third for the next tick — which looks like a
		# merge that stutters.
		while merged:
			merged = false

			for a in range(monster.pieces.size()):
				for b in range(a + 1, monster.pieces.size()):
					var first := monster.pieces[a]
					var second := monster.pieces[b]

					if not first.can_merge(_tick) or not second.can_merge(_tick):
						continue

					var distance := first.position().distance_to(second.position())

					if distance > maxf(first.radius(), second.radius()):
						continue

					var keeper := first if first.mass() >= second.mass() else second
					var absorbed := second if keeper == first else first

					_grow(keeper, keeper.mass() + absorbed.mass())
					keeper.state.set_flag(HungryContent.FLAG_BURST, false)
					_destroy_piece(absorbed)

					merged = true
					break

				if merged:
					break


# --- Throwing --------------------------------------------------------------

## Throws the oldest carried item along the aim.
##
## Thrown from the rider's piece rather than from the centroid: the centroid of a burst
## monster is empty space, and a projectile that came out of nowhere is unreadable.
func _throw(monster: HungryMonster, command: Dot2DCommand) -> HungryProjectile:
	if _tick < monster.throw_ready_tick or command.aim == Vector2.ZERO:
		return null

	if monster.carried.is_empty():
		return null

	var rider := monster.rider_piece()

	if rider == null:
		return null

	var item := monster.spend_item()
	monster.throw_ready_tick = _tick + HungryContent.THROW_COOLDOWN_TICKS

	# Aimed from the rider at the pointer, not along the monster's own aim: the aim is
	# measured from the centroid, and after a burst the centroid is empty space several
	# hundred units from the piece the throw actually comes out of.
	var pointer := pointer_of(monster, command)
	var offset := pointer - rider.position()
	var direction := offset.normalized() if offset.length_squared() > 0.000001 \
		else command.aim.normalized()
	var origin := rider.position() + direction * (rider.radius() + HungryContent.THROW_RADIUS)

	var shot := HungryProjectile.make(
		_next_shot_id, monster.id, item, origin, direction, _tick
	)
	_next_shot_id += 1
	_shots[shot.id] = shot

	projectile_thrown.emit(shot)
	return shot


## Spits a blob of mass out along the aim.
##
## [b]From the rider's piece only, and that is a design choice rather than a
## simplification.[/b] agar.io ejects from every cell at once, which is how you feed a
## virus in a second — and which, at sixteen pieces, is a spray of blobs nobody can read.
## One blob per press comes out of the piece the player is looking at, and a player who
## wants to shed a lot of mass presses it a lot.
##
## What it leaves is ordinary planted food: anybody can eat it, it goes on the wire the
## way a lure's ring does, and it is in the same grid as everything else. There is no
## ejected-blob entity because there does not need to be one.
func _eject(monster: HungryMonster, command: Dot2DCommand) -> int:
	if _tick < monster.eject_ready_tick or command.aim == Vector2.ZERO:
		return 0

	var rider := monster.rider_piece()

	if rider == null or rider.mass() < HungryContent.EJECT_MIN_MASS:
		return 0

	var pointer := pointer_of(monster, command)
	var offset := pointer - rider.position()
	var direction := offset.normalized() if offset.length_squared() > 0.000001 \
		else command.aim.normalized()

	if direction == Vector2.ZERO:
		return 0

	_grow(rider, rider.mass() - HungryContent.EJECT_MASS)
	monster.eject_ready_tick = _tick + HungryContent.EJECT_COOLDOWN_TICKS
	monster.ejected += 1

	var at := rider.position() + direction * (rider.radius() + HungryContent.EJECT_REACH)
	var placed := field.plant(
		arena.clamp_position(at, HungryContent.FOOD_TIER_RADIUS[HungryContent.EJECT_TIER]),
		1,
		HungryContent.EJECT_TIER,
		arena.bounds
	)

	for grid_id in placed:
		arena.grid.place(grid_id, field.position_of(grid_id), field.radius_of(grid_id))

	field_changed.emit()
	return placed.size()


## Mirrors a throw the authority has announced. Client side.
func adopt_projectile(shot: HungryProjectile) -> void:
	if shot == null or shot.id <= 0:
		return

	_shots[shot.id] = shot
	_next_shot_id = maxi(_next_shot_id, shot.id + 1)


## Removes a projectile the authority says has landed. Client side.
func drop_projectile(shot_id: int) -> void:
	_shots.erase(shot_id)


func _resolve_projectiles() -> void:
	for shot in projectiles():
		if shot.resolved:
			continue

		var at := shot.position_at(_tick, tick_rate)

		if not arena.bounds.has_point(at) or shot.expired(_tick, tick_rate):
			_land(shot, arena.clamp_position(at, HungryContent.THROW_RADIUS), 0)
			continue

		# A lure is not aimed at a person and passes through everybody. Resolving it on
		# contact would make it a worse pepper rather than a different item.
		if shot.item == HungryContent.ITEM_LURE:
			continue

		var hit := 0

		for grid_id in arena.grid.query_overlapping(at, HungryContent.THROW_RADIUS):
			if grid_id >= HungryField.PIECE_ID_LIMIT:
				continue

			var piece: HungryPiece = _pieces.get(grid_id)

			if piece == null or piece.owner_id == shot.thrower_id:
				continue

			var victim := monster_for(piece.owner_id)

			if victim == null or victim.has_effect(HungryContent.FLAG_PROTECTED, _tick):
				continue

			hit = piece.owner_id
			break

		if hit != 0:
			_land(shot, at, hit)


func _land(shot: HungryProjectile, at: Vector2, hit_player: int) -> void:
	shot.resolved = true
	_shots.erase(shot.id)

	match shot.item:
		HungryContent.ITEM_PEPPER:
			if hit_player != 0:
				burst(monster_for(hit_player), shot.thrower_id)

		HungryContent.ITEM_FROST:
			if hit_player != 0:
				var victim := monster_for(hit_player)
				if victim != null:
					victim.apply_effect(
						HungryContent.FLAG_FROSTED,
						_tick + int(HungryContent.FROST_SEC * float(tick_rate))
					)

		HungryContent.ITEM_LURE:
			for grid_id in field.plant(
				at,
				HungryContent.LURE_FOOD_COUNT,
				HungryContent.LURE_FOOD_TIER,
				arena.bounds
			):
				arena.grid.place(
					grid_id, field.position_of(grid_id), field.radius_of(grid_id)
				)
			field_changed.emit()

	projectile_impact.emit(shot, at, hit_player)


# --- Housekeeping ----------------------------------------------------------

func _refill_field() -> void:
	var placed := field.refill()

	for grid_id in placed:
		arena.grid.place(grid_id, field.position_of(grid_id), field.radius_of(grid_id))

	if not placed.is_empty():
		field_changed.emit()


## Copies each monster's effect bits onto its pieces, and marks the rider.
##
## The flags are what a client draws from — a rushing monster, a frosted one, who is
## carrying the avatar — and they are replicated, so they have to be written on the
## authority every tick rather than derived on receipt from state a client does not have.
##
## [b]It is also where a monster's own [member HungryMonster.flags] is written[/b], and
## that is what makes prediction work. Speed depends on whether you are rushing or
## frosted; the effects themselves live only on the authority, with expiry ticks nobody
## else is sent. Reading the speed off the replicated bits instead means a client and a
## server compute it from the same number, one tick apart, rather than one of them
## computing it from state the other does not have — which would be a permanent
## mispredict for the whole eight seconds of a fruit.
func _sync_flags() -> void:
	for monster in monsters():
		monster.flags = monster.effect_flags(_tick)

		var rider := monster.rider_piece()

		for piece in monster.pieces:
			_apply_flags(monster, piece, rider)


func _apply_flags(
	monster: HungryMonster,
	piece: HungryPiece,
	rider: HungryPiece = null
) -> void:
	var carrier := rider if rider != null else monster.rider_piece()
	var bits := monster.flags

	if carrier != null and carrier.id == piece.id:
		bits |= HungryContent.FLAG_RIDER

	if piece.can_merge(_tick):
		bits |= HungryContent.FLAG_MERGE_READY

	if piece.state.has_flag(HungryContent.FLAG_BURST):
		bits |= HungryContent.FLAG_BURST

	piece.state.flags = bits


## Keeps the scoreboard's score in step with mass.
##
## The scoreboard is dot-match's and it counts whatever it is told to. This game's score
## [i]is[/i] mass, so it is written here rather than accumulated from events — a running
## total would drift from the real mass every time decay ran.
func _sync_scores() -> void:
	for monster in monsters():
		var record := match_node.scoreboard.find(str(monster.id))

		if record != null:
			record.score = int(monster.mass())


func _on_respawn_due(key: String, _spawn: DotSpawnPoint, _tick_value: int) -> void:
	spawn(int(key))


# --- Queries ---------------------------------------------------------------

## Everything a player should be told about: pieces and food in their view.
##
## Bounded, because a player in the middle of a crowded world is otherwise in interest
## range of everything at once — and on a browser client that is the difference between
## playable and not.
##
## Over the cap, [b]pieces come before food[/b]: losing sight of a crumb is a crumb you
## do not eat, and losing sight of a piece is being eaten by something invisible. Pieces
## are trimmed too rather than exempted — eight players at the piece limit is a hundred
## and twenty-eight pieces, and a cap that only bounded food would not bound anything.
func interest_for(player_id: int, limit: int = 420) -> Array[int]:
	var monster := monster_for(player_id)

	if monster == null or not monster.alive:
		return []

	var origin := monster.centre()
	var extent := arena.interest_extent * maxf(1.0, monster.spread_radius() / 95.0)

	var found := arena.grid.query_rect(Rect2(origin - extent, extent * 2.0))

	if found.size() <= limit:
		return found

	var near: Array[int] = []
	var far: Array[int] = []

	for grid_id in found:
		if grid_id < HungryField.PIECE_ID_LIMIT:
			near.append(grid_id)
		else:
			far.append(grid_id)

	if near.size() >= limit:
		return near.slice(0, limit)

	var out := near
	out.append_array(far.slice(0, limit - near.size()))
	return out


func leaderboard(count: int = 10) -> Array[HungryMonster]:
	var ranked := monsters()

	ranked.sort_custom(func(a: HungryMonster, b: HungryMonster) -> bool:
		if not is_equal_approx(a.mass(), b.mass()):
			return a.mass() > b.mass()
		# Ties on the id, so two machines produce the same order. A leaderboard whose
		# rows swap for no reason is the classic symptom of an unstable sort.
		return a.id < b.id
	)

	return ranked.slice(0, count)


func current_tick() -> int:
	return _tick


func set_tick(value: int) -> void:
	_tick = value


func describe() -> Dictionary:
	return {
		"tick": _tick,
		"authority": is_authority,
		"players": _monsters.size(),
		"pieces": _pieces.size(),
		"shots": _shots.size(),
		"field": field.describe() if field != null else {},
		"arena": arena.describe() if arena != null else {},
		"match": match_node.describe() if match_node != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("hungry   tick %d, %d pieces, %d in flight" % [
		_tick, _pieces.size(), _shots.size()
	])

	if field != null:
		out.append("field    %d food (%d planted), %d fruit, %d drops" % [
			field.food_count(), field.planted_count(),
			field.fruit_count(), field.item_count(),
		])

	for monster in leaderboard(8):
		out.append("  %-16s %8.0f  %d pieces  %-14s%s" % [
			monster.display_name.substr(0, 16),
			monster.mass(),
			monster.piece_count(),
			"+".join(monster.carried_names()),
			"" if monster.alive else "  (dead)",
		])

	return out
