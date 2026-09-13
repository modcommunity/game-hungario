extends Node

const HungryContent := preload("hungry_content.gd")
const HungryField := preload("hungry_field.gd")
const HungryPiece := preload("hungry_piece.gd")
const HungryWorld := preload("hungry_world.gd")

## The player-facing addons, stood up once and bound to the 2D arena.
##
## [b]Hungario is the 2D game, and that is what makes it the useful test of this
## layer.[/b] Everything else in the family is a first-person shooter of some shape;
## if a roster, a side, a class and a spawn only work when there is a capsule and a
## camera, they are not a platform layer, they are a shooter's plumbing.
##
## [codeblock]
## dot-physics   the top-down 2D LAYOUT — named layers, not a retune. See below.
## dot-player    the roster, which a growing-blob game needs as much as a shooter
## dot-team      one playing side and a spectator side; hungry is free-for-all
## dot-player-class  the traits, as a catalogue a server can check
## dot-player-char   2D body metrics, in pixels, and a home for the avatar rider
## dot-spawn     where a monster appears, with distance from bigger monsters scored
## [/codeblock]
##
## [b]What it does not do is move anything.[/b] The monster is dot-2d's, the field is
## `HungryField`'s, and the round is dot-match's. This keeps records in step with them.

const CHANNEL := "hungry.stack"

const SERVICE := &"hungry_player_stack"

@export var register_service: bool = true

@export var apply_physics: bool = true

var world: HungryWorld = null

var physics: DotPhysicsWorld = null
var roster: DotPlayerRoster = null
var teams: DotTeamRoster = null
var classes: DotPlayerClassManager = null
var characters: DotPlayerCharCatalogue = null
var spawns: DotSpawnDirector = null

var _registered: bool = false


func setup(p_world: HungryWorld) -> DotResult:
	if p_world == null:
		return DotResult.fail(DotError.CODE_INVALID, "No world to bind to.")

	if p_world.match_node == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"HungryWorld is not set up yet.",
			"Call setup() on it first; this reads its match and its field."
		)

	world = p_world

	var built := _build_physics()

	if not built.ok:
		return built

	_build_roster()
	_build_teams()
	_build_characters()
	_build_classes()
	_build_spawns()

	world.player_spawned.connect(_on_player_spawned)
	world.player_died.connect(_on_player_died)

	if register_service:
		DotRegistry.register(SERVICE, self)
		_registered = true

	DotLog.info(CHANNEL, "player stack up", {"tick_rate": world.tick_rate})
	return DotResult.success(null)


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## Builds the physics node, and applies the engine half of it only where that is wanted.
##
## [b]The LAYOUT is built on every instance, including a client that applies nothing.[/b]
## This used to return before creating the node at all when `apply_physics` was off, which
## left a client with no layout — and a collision layout is not a local preference, it is
## the numbers written into `collision_layer` on nodes both ends build. A server that put
## props on the prop bit while its clients left them on bit 0 would be two worlds with
## different collision matrices, agreeing only because nothing had ever read the layout.
##
## What `apply_physics` still gates is `setup()`, which writes ProjectSettings: the tick
## rate, gravity and damping. Those are the server's to decide.
func _build_physics() -> DotResult:
	physics = DotPhysicsWorld.new()
	physics.name = "Physics"

	# [b]The project's own numbers and only the tick rate changed.[/b] Hungario does
	# not use Godot's physics for anything that matters — the monster is dot-2d's own
	# integration over a spatial hash, and the field is arithmetic — so a preset here
	# would be a set of decisions about a solver nothing in this game consults, applied
	# on the chance that something later does.
	physics.profile = DotPhysicsProfile.from_project()
	physics.profile.tick_rate = world.tick_rate

	# The layout is the part worth having. It is inert until a body is classified, and
	# what it buys is that `pickup`, `hazard` and `projectile` stop being bit arithmetic
	# at the call site the day this game grows a `CollisionObject2D`.
	physics.layout = DotPhysicsLayout.top_down_2d()
	physics.register_service = false
	physics.write_layer_names = false
	add_child(physics)

	# The layout alone, so `classify` answers on a client too.
	var built := physics.layout.build()

	if not built.ok:
		return built.wrap("The collision layout")

	if not apply_physics:
		return DotResult.success(null)

	return physics.setup().wrap("hungario's physics profile")


func _build_roster() -> void:
	roster = DotPlayerRoster.new()
	roster.name = "Roster"
	roster.authoritative = world.is_authority
	roster.register_service = false

	var config := DotPlayerConfig.new()
	config.tick_rate = world.tick_rate
	config.max_players = 32
	# A round is minutes and a dropped player's mass is the whole game. Holding the seat
	# for two of them is the difference between a reconnect and starting over as a dot.
	config.reconnect_window_sec = 120.0
	roster.config = config
	add_child(roster)


func _build_teams() -> void:
	teams = DotTeamRoster.new()
	teams.name = "Teams"
	teams.authoritative = world.is_authority
	teams.register_service = false
	# Free-for-all is ONE playing side, not none. Modelled as none, every consumer has
	# to branch on whether teams exist, and the branch nobody writes is the one that
	# matters — here it would be "can I eat this", which is the entire game.
	teams.teams = DotTeamSet.free_for_all()
	teams.policy = DotTeamPolicy.free_for_all()
	teams.policy.tick_rate = world.tick_rate
	teams.alive_fn = _alive_of_key
	add_child(teams)

	var res := teams.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team roster", {"why": res.error.message})


func _build_characters() -> void:
	# [b]In pixels, not metres.[/b] dot-player-char's metrics are unit-agnostic on
	# purpose and this is the case that proves it: a hungario monster's "height" is a
	# radius on a screen, and the same document that describes a 1.8 m shooter describes
	# it without a second class or a conversion anybody has to remember.
	characters = DotPlayerCharCatalogue.sprite_2d(HungryContent.CELL_SIZE)
	var res := characters.build()

	if not res.ok:
		DotLog.error(CHANNEL, "character catalogue", {"why": res.error.message})


func _build_classes() -> void:
	classes = DotPlayerClassManager.new()
	classes.name = "Classes"
	classes.authoritative = world.is_authority
	classes.register_service = false
	classes.catalogue = _trait_catalogue()
	# Traits are picked before a round and change what a monster is; changing one
	# mid-life would change its mass rules under it, which is the exploit `apply_on
	# _respawn` exists for. A hungario life ends when you are eaten, so the next spawn
	# is the natural boundary.
	classes.rules = DotPlayerClassRules.standard()
	classes.team_fn = func(key: String) -> StringName: return teams.team_of(key)
	classes.alive_fn = _alive_of_key
	add_child(classes)

	var res := classes.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "class manager", {"why": res.error.message})


## Hungario's traits, as a class catalogue a server can check.
##
## [b]The ids are the game's own.[/b] `HungryContent.TRAIT_*` is what a monster already
## carries and what its mass rules read; this is the same list expressed as something
## dot-player-class can enforce a limit and an entitlement against, without the game's
## trait system having to move.
func _trait_catalogue() -> DotPlayerClassCatalogue:
	var cat := DotPlayerClassCatalogue.new()
	cat.id = &"hungry_traits"

	# Read off HungryContent.TRAIT_IDS rather than listed here. A trait added to the
	# game and forgotten in this file would be a trait a player can hold and the class
	# manager refuses, which presents as "my perk does nothing" on one server only.
	#
	# [b]And the NUMBERS come from there too, which they did not.[/b] This carried its own
	# `{nimble: 1.15, sturdy: 0.9}` while `HungryContent.TRAIT_SPEED` is `[1.08, 0.95, …]`
	# and `HungryMonster.speed_multiplier` reads the latter — so the class document a
	# server validates, a class screen draws and the wire carries advertised a nimble
	# monster as 15% faster while the simulation ran it at 8%. Two copies of one table,
	# already disagreeing, and nothing could report it: both numbers are valid speeds and
	# only one of them is ever simulated.
	for trait_id in HungryContent.TRAIT_IDS:
		var def := DotPlayerClassDef.make(
			trait_id, 100.0, HungryContent.trait_speed(trait_id)
		)
		def.description = "A hungario trait."
		# The mass ratio the trait actually carries, so the document is the whole trait
		# rather than the half of it that happened to fit `make`.
		def.mass = HungryContent.trait_mass(trait_id) * 100.0
		def.attributes = {"food_scale": HungryContent.trait_food(trait_id)}
		cat.classes.append(def)

	cat.default_class = HungryContent.TRAIT_NIMBLE

	var res := cat.build()

	if not res.ok:
		# Falls back rather than leaving the manager with nothing: a catalogue that
		# fails to build is a content mistake, and a session where nobody can be any
		# class at all is a worse answer than one class for everybody.
		DotLog.error(CHANNEL, "trait catalogue", {"why": res.error.message})
		return DotPlayerClassCatalogue.single(100.0)

	return cat


func _build_spawns() -> void:
	spawns = DotSpawnDirector.new()
	spawns.name = "Spawns"
	spawns.tick_rate = world.tick_rate
	spawns.register_service = false
	spawns.rules = DotSpawnRules.deathmatch()
	spawns.rules.seed_value = 0x4E55
	# [b]Distance from EVERY other monster, because in hungario everybody is dangerous
	# to somebody.[/b] There are no sides, so the enemy list is the whole field — which
	# is the honest answer here and is why the selector is asked for distance at all.
	spawns.enemies_fn = _other_positions
	# [b]The rule `_safe_spawn` was applying by hand.[/b] Distance alone is the wrong
	# question here: what kills a new monster is not somebody near, it is somebody near
	# and BIGGER, and a small player standing on the best cell is no danger at all. The
	# scoring cannot express that — it is a mass ratio, not a metre — so it is a
	# condition, which is a veto rather than a penalty and is what dot-spawn's own
	# documentation says a distance that is death rather than a bad choice should be.
	var safety := SiteIsNotDeadly.new()
	safety.danger_fn = _bigger_monster_near
	spawns.conditions = [safety]
	spawns.rules.protection_sec = 0.0
	add_child(spawns)

	refresh_spawn_rules()
	refresh_spawns()


## Lays a grid of sites over the field.
##
## [b]Hungario has no spawn markers and cannot have any.[/b] Its world is a bounded
## rectangle with food scattered across it and no level geometry, so there is nothing
## for a mapper to place. A grid is the honest substitute: it gives the selector real
## alternatives to score, and the scoring — distance from the nearest other monster — is
## what actually decides, which is what matters in a game where spawning beside somebody
## twice your size is instant death.
func refresh_spawns() -> void:
	if spawns == null or world == null:
		return

	spawns.clear_sites()

	var half := world.world_size * 0.5
	var steps := 5

	for x in range(steps):
		for y in range(steps):
			# Inset by half a cell so no site sits exactly on the boundary, where a
			# monster with any size at all would be spawned half outside the arena.
			var at := Vector2(
				lerpf(-half.x, half.x, (float(x) + 0.5) / float(steps)),
				lerpf(-half.y, half.y, (float(y) + 0.5) / float(steps))
			)
			var site := DotSpawnSite.point(
				StringName("cell_%d_%d" % [x, y]), Vector3(at.x, at.y, 0.0)
			)
			site.is_2d = true
			spawns.add_site(site)

	DotLog.debug(CHANNEL, "spawn sites", {"count": spawns.sites().size()})


# --- Keeping in step --------------------------------------------------------

## Adds somebody to every record. Call from `HungryWorld.add_player`.
func add_player(id: int, display_name: String) -> void:
	if not roster.authoritative:
		return

	var key := str(id)
	var res := roster.join(key, display_name, id, world.current_tick())

	if not res.ok:
		DotLog.warn(CHANNEL, "player not added to the roster", {
			"key": key, "why": res.error.message
		})
		return

	var _team := teams.add(key, world.current_tick())
	var _class := classes.add(key)
	var _char := roster.set_char(key, &"sprite")


## Drops somebody. Call from `HungryWorld.remove_player`.
func drop_player(id: int) -> void:
	if not roster.authoritative:
		return

	var key := str(id)
	spawns.cancel_respawn(key)
	classes.remove(key)
	var _left := teams.remove(key)
	var _held := roster.note_disconnected(key, world.current_tick())


func _on_player_spawned(id: int) -> void:
	if not roster.authoritative:
		return

	var key := str(id)
	# Before the alive flag, so anything reading the class in an `alive_changed`
	# handler reads the one this life is being started with.
	var _landed := classes.apply_pending(key)
	var _alive := roster.set_alive(key, true)


func _on_player_died(id: int, _killer: int) -> void:
	if not roster.authoritative:
		return

	var _dead := roster.set_alive(str(id), false)


## One tick of what this node runs on its own.
func tick(current_tick: int) -> void:
	if not roster.authoritative:
		return

	var _dropped := roster.advance(current_tick)

	if spawns.protection != null:
		spawns.protection.advance(current_tick)


# --- Reading ----------------------------------------------------------------

## Opens the protection window to the match's own number.
##
## [b]One duration, two records.[/b] `HungryWorld._spawn_monster` applies
## `FLAG_PROTECTED` until `match_node.spawn_protection_ticks()`, and the ledger is granted
## for `protection_sec` inside [method DotSpawnDirector.choose]. Reading the same number
## rather than writing a second one is what stops the flag and the ledger disagreeing
## about when somebody stopped being safe.
func refresh_spawn_rules() -> void:
	if spawns == null or world == null or world.match_node == null:
		return

	spawns.rules.protection_sec = world.match_node.rules.spawn_protection_sec
	# Off for game-arena's reason: only one of the two records can be revoked, and a
	# protection that ended for one gate and not the other is worse than either answer.
	spawns.rules.protection_breaks_on_attack = false


## Whether spawn protection should stop [param attacker] eating [param victim].
##
## Hungario does not route bites through dot-combat, so this is asked by
## `HungryWorld.can_eat` rather than by a damage resolver — but it is the same question
## and the same ledger, which is the point of it being on the stack rather than inline.
func blocks_damage(
	attacker_key: String, victim_key: String, tick: int, world_damage: bool = false
) -> bool:
	if spawns == null or spawns.protection == null:
		return false

	return spawns.protection.blocks(attacker_key, victim_key, tick, world_damage)


## Where a monster should appear, scored by how far it is from everybody else.
func choose_spawn(id: int) -> DotResult:
	var key := str(id)
	return spawns.choose(
		DotSpawnRequest.make(
			key, teams.team_of(key), classes.class_of(key), world.current_tick()
		)
	)


## The body metrics for a monster, in pixels.
func character() -> DotPlayerCharDef:
	return characters.fallback_for() if characters != null else null



## The dot-spectate team number for [param key], derived from the side they are on.
##
## [b]An index, not a hash, and zero means "no side".[/b] dot-spectate keys teams by
## [code]int[/code] and treats 0 as no team at all — two entities with no team are never
## team-mates, so a free-for-all cannot accidentally become a truce. The playing sides
## are numbered from 1 in the order the set declares them, which is the same rule
## `DotTeamRoster._match_team_id` uses to push an assignment down into dot-match.
##
## Somebody unassigned, spectating, or not in the roster at all gets 0. That is the part
## a hardcoded `return 1` got wrong: a spectator read as a team-mate of everybody.
func team_index_of(key: String) -> int:
	if teams == null:
		return 0

	var side := teams.team_of(key)

	if side == &"" or not teams.teams.is_playing(side):
		return 0

	return teams.teams.playing_ids().find(side) + 1



## Puts [param node] on the layout's [param layer_id] layer, with that layer's mask.
##
## [b]The half of dot-physics that was never used.[/b] The layout was assigned and its
## layer names were written into ProjectSettings for the inspector to show — and every
## body in this game stayed on Godot's default layer 1 with mask 1, so the inspector
## labelled layers nothing followed. Naming a layer is only half of a layout.
func classify(node: Node, layer_id: StringName) -> DotResult:
	if physics == null or physics.layout == null:
		return DotResult.fail(DotError.CODE_STATE, "No collision layout.")

	return physics.classify(node, layer_id)


## Puts every collision object under [param root] on [param layer_id]. Returns how many.
##
## One call rather than a call per body: the geometry is built by a class that describes
## boxes, and a physics decision belongs here rather than inside that description. Nodes
## that are not collision objects are skipped, so a whole scene can be handed in.
func classify_tree(root: Node, layer_id: StringName) -> int:
	if root == null or physics == null or physics.layout == null:
		return 0

	var done := 0

	if root is CollisionObject3D or root is CollisionObject2D:
		if classify(root, layer_id).ok:
			done += 1

	for child in root.get_children():
		done += classify_tree(child, layer_id)

	return done


## The mask a player's movement sweeps against, out of the layout.
##
## [b]`DotFpsTunables.collision_mask` defaults to 1 and no game here had ever set it.[/b]
## One is correct only while everything is on bit 0, which is the state a layout exists to
## end — so the moment props moved to their own layer, a mask of 1 was a player who walks
## through every crate in the map, and nothing would have said so: a sweep that hits
## nothing is a sweep, not an error.
func player_collision_mask() -> int:
	if physics == null or physics.layout == null:
		return 1

	return physics.layout.collision_mask(&"player")


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("--- player stack")

	if physics != null:
		out.append_array(physics.describe_lines())

	out.append_array(roster.describe_lines())
	out.append_array(teams.describe_lines())
	out.append_array(classes.describe_lines())
	out.append_array(spawns.describe_lines())
	return out


func describe() -> Dictionary:
	return {
		"players": roster.count(),
		"alive": roster.alive_count(),
		"spawn_sites": spawns.sites().size(),
		"traits": classes.catalogue.ids().size(),
	}


# --- The callables the addons are given -------------------------------------

func _alive_of_key(key: String) -> bool:
	var monster := world.monster_for(int(key))
	return monster != null and not monster.pieces.is_empty()


## Whether anything big enough to eat a fresh monster is standing near [param at].
##
## The mass rule out of [method HungryWorld._safe_spawn], moved to where the director can
## ask it. `START_MASS` is what a monster spawns at, so anything above it is a threat, and
## seven start-radii is the reach the hand-written version used.
func _bigger_monster_near(at: Vector2) -> bool:
	if world == null or world.arena == null:
		return false

	var start_radius := world.tunables.mass_rules.radius_for(HungryContent.START_MASS)

	for other_id in world.arena.overlapping(at, start_radius * 7.0):
		if other_id >= HungryField.PIECE_ID_LIMIT:
			continue

		var piece: HungryPiece = world.piece_for(other_id)

		if piece != null and piece.mass() > HungryContent.START_MASS:
			return true

	return false


## Refuses a site with something big enough to eat you standing on it.
##
## [b]A condition rather than a score, because this is not a trade.[/b] There is a mass
## at which a cell is not a worse spawn but a death, and no amount of distance scoring
## anywhere else should be able to buy it back — which is `MinimumEnemyDistance`'s own
## reasoning, in the units this game actually measures danger in.
class SiteIsNotDeadly extends DotSpawnCondition:
	## `func(at: Vector2) -> bool`. Left unset, nothing is deadly and every site passes.
	var danger_fn: Callable = Callable()

	func _init() -> void:
		id = &"site_is_not_deadly"

	func allows(site: DotSpawnSite, _context: Dictionary) -> bool:
		if not danger_fn.is_valid():
			return true

		return not bool(danger_fn.call(site.position_2d()))

	func reason() -> String:
		return "something big enough to eat you is standing on it"


func _other_positions(_team: StringName) -> Array:
	var out: Array = []

	for monster in world.monsters():
		if monster.pieces.is_empty():
			continue

		var at := monster.centre()
		out.append(Vector3(at.x, at.y, 0.0))

	return out
