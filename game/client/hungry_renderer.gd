@tool
class_name HungryRenderer
extends Node2D

## Draws the world. The only file in this project that knows what anything looks like.
##
## [b]Drawn, not composed.[/b] A world with eleven hundred pieces of food in it is eleven
## hundred nodes if each one is a sprite, created and freed as the field refills — and on
## a browser client that is most of a frame. A `_draw` call per visible thing is one node
## and no allocation, which is the same choice game-blob's minimap made for the same
## reason.
##
## [b]Everything is culled to the camera.[/b] The rectangle comes from the camera rig, and
## the food inside it comes out of the same [Dot2DGrid] the eat checks use — which is what
## that grid is for. Drawing the whole field and letting the renderer clip it would draw a
## thousand circles to show fifty.
##
## No art. dot-2d ships none, dot-ui ships none, and neither does this: shapes, colours
## and a font. What a real deployment adds is content, through dot-cloud, and the seam for
## that is [HungryRider].

const CHANNEL := "hungry.render"

## Extra world units drawn beyond the camera rectangle, so nothing pops in at the edge.
const CULL_MARGIN := 120.0

@export var world: HungryWorld = null

## Whose monster this is, for the highlight and the name.
@export var local_player_id: int = 0

## The camera, for the cull rectangle. Any [Camera2D] will do.
@export var camera: Camera2D = null

## Draw everybody's name above their monster. A player's setting; off is quieter and, in
## a crowd, considerably more readable.
@export var show_names: bool = true

## Ring every monster by whether you could eat it, or it you.
##
## [b]The affordance this genre cannot do without.[/b] Eating needs a ratio — a quarter
## bigger — and a quarter of a difference in area is about 12% of a difference in width,
## which nobody judges reliably by eye and certainly not while being chased. The ring says
## what the rule says.
@export var show_threat: bool = true

var prey_colour := Color(0.45, 0.95, 0.55, 0.85)
var threat_colour := Color(1.0, 0.35, 0.32, 0.85)

## Riders, one per player. Nodes rather than drawings, because an avatar may resolve to
## real content and content is a scene.
var _riders: Dictionary = {}

## The arena floor. Space, one shade off the void so the boundary reads without the wall
## having to do all the work.
var background := Color(0.046, 0.052, 0.088)

## Outside the walls. Darker, and the only thing that says "you cannot go there".
var void_colour := Color(0.020, 0.023, 0.042)

var grid_line := Color(0.17, 0.28, 0.46, 0.30)
var wall := Color(0.36, 0.68, 1.0)

## Food, by tier. Cool and dim through to hot and bright, so size reads at a glance — the
## same ordering as before, moved onto a palette that belongs in a sky.
var food_colours: Array[Color] = [
	Color(0.60, 0.70, 0.92),
	Color(0.42, 0.88, 0.80),
	Color(0.98, 0.84, 0.46),
	Color(1.00, 0.58, 0.34),
]

var planted_colour := Color(0.80, 0.52, 1.0)

var _font: Font = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	_font = ThemeDB.fallback_font
	z_index = -1


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		queue_redraw()


func bind(p_world: HungryWorld, p_camera: Camera2D, p_player_id: int) -> void:
	world = p_world
	camera = p_camera
	local_player_id = p_player_id


## The world rectangle worth drawing.
func _view() -> Rect2:
	if camera == null:
		return world.arena.bounds if world != null else Rect2()

	var half := get_viewport_rect().size * 0.5 * camera.zoom
	var rect := Rect2(camera.global_position - half, half * 2.0)
	return rect.grow(CULL_MARGIN)


func _draw() -> void:
	if world == null or world.arena == null:
		return

	var view := _view()

	_draw_ground(view)
	_draw_field(view)
	_draw_projectiles()
	_draw_monsters(view)


func _draw_ground(view: Rect2) -> void:
	var bounds := world.arena.bounds

	# THE WHOLE VIEW, not just the arena. Only the arena used to be painted, which left the
	# window's clear colour showing past the boundary — unnoticeable as a flat grey and
	# glaring once there is a sky, because space that stops at the wall makes the wall look
	# like a rendering fault.
	draw_rect(view, void_colour)
	draw_rect(bounds, background)

	# The sky, parallaxed against the camera — see [DotStarfield] for why it is hashed rather
	# than stored. Drawn under the grid and everything else: it is scenery, and nothing in
	# it may be mistaken for something edible.
	var anchor := camera.global_position if camera != null else Vector2.ZERO
	var seconds := float(Time.get_ticks_msec()) * 0.001

	DotStarfield.draw_nebula(self, view, anchor)
	DotStarfield.draw_into(self, view, anchor, seconds)

	# A grid, because a featureless plane gives no sense of speed at all — a monster
	# moving across an empty background looks stationary, which is exactly wrong for a
	# game whose whole tension is how fast you are.
	var step := 260.0
	var from_x := floorf(view.position.x / step) * step
	var to_x := view.end.x
	var from_y := floorf(view.position.y / step) * step
	var to_y := view.end.y

	var x := from_x

	while x <= to_x:
		if x >= bounds.position.x and x <= bounds.end.x:
			draw_line(
				Vector2(x, maxf(view.position.y, bounds.position.y)),
				Vector2(x, minf(to_y, bounds.end.y)),
				grid_line,
				1.0
			)
		x += step

	var y := from_y

	while y <= to_y:
		if y >= bounds.position.y and y <= bounds.end.y:
			draw_line(
				Vector2(maxf(view.position.x, bounds.position.x), y),
				Vector2(minf(to_x, bounds.end.x), y),
				grid_line,
				1.0
			)
		y += step

	_draw_wall(bounds)


## The boundary, drawn as a glow rather than a line.
##
## Three passes, widest and faintest first. A 3px hairline is nearly invisible against a
## starfield, and the wall is the one thing in this scene a player cannot afford to miss:
## being cornered against it is how most of them are eaten.
func _draw_wall(bounds: Rect2) -> void:
	draw_rect(bounds, Color(wall.r, wall.g, wall.b, 0.09), false, 16.0)
	draw_rect(bounds, Color(wall.r, wall.g, wall.b, 0.20), false, 7.0)
	draw_rect(bounds, Color(wall.r, wall.g, wall.b, 0.85), false, 2.0)


func _draw_field(view: Rect2) -> void:
	for grid_id in world.arena.grid.query_rect(view):
		if grid_id < HungryField.PIECE_ID_LIMIT:
			continue

		var at := world.field.position_of(grid_id)
		var radius := world.field.radius_of(grid_id)

		match HungryField.kind_of(grid_id):
			HungryField.Kind.FOOD:
				var tier := world.field.tier_of(grid_id)
				var food := food_colours[tier]

				# A halo on the top two tiers ONLY. Every crumb glowing is a thousand extra
				# circles a frame and a screen with no contrast left in it; the pieces worth
				# crossing the arena for are the ones that should carry light.
				if tier >= 2:
					draw_circle(at, radius * 2.1, Color(food.r, food.g, food.b, 0.13))

				draw_circle(at, radius, food)

			HungryField.Kind.PLANTED:
				draw_circle(at, radius, planted_colour)

			HungryField.Kind.FRUIT:
				var kind := int(world.field.fruit_kind_of(grid_id))
				var colour := HungryContent.FRUIT_COLOURS[kind]
				draw_circle(at, radius * 2.6, Color(colour.r, colour.g, colour.b, 0.16))
				draw_circle(at, radius, colour)
				# A ring, so a fruit is never mistaken for a large piece of food. Being
				# able to tell them apart at a glance is the whole value of a rare thing.
				draw_arc(at, radius + 5.0, 0.0, TAU, 24, colour, 2.0)

			HungryField.Kind.ITEM:
				var item := world.field.item_id_of(grid_id)
				var tint := HungryContent.item_colour(item)
				draw_rect(
					Rect2(at - Vector2(radius, radius) * 0.7, Vector2(radius, radius) * 1.4),
					tint
				)
				draw_arc(at, radius, 0.0, TAU, 20, tint.lightened(0.3), 2.0)


func _draw_projectiles() -> void:
	var tick := world.current_tick()

	for shot in world.projectiles():
		var at := shot.position_at(tick, world.tick_rate)
		var tint := HungryContent.item_colour(shot.item)

		# A short tail rather than a dot: a projectile crossing the screen in a second is
		# hard to see coming, and which way it is going is the only thing that matters.
		draw_line(at - shot.direction * 26.0, at, Color(tint.r, tint.g, tint.b, 0.6), 4.0)
		draw_circle(at, HungryContent.THROW_RADIUS, tint)


func _draw_monsters(view: Rect2) -> void:
	# What the local monster's biggest piece weighs, which is what every eat check against
	# it is measured from. Read once rather than per piece: it does not change inside a
	# frame and this loop runs over everything on screen.
	var me := world.monster_for(local_player_id)
	var my_biggest := 0.0

	if me != null and me.alive:
		for piece in me.pieces:
			my_biggest = maxf(my_biggest, piece.mass())

	for monster in world.monsters():
		if not monster.alive:
			continue

		var rider_piece := monster.rider_piece()
		var mine := monster.id == local_player_id

		for piece in monster.pieces:
			# Grown by the piece's own radius, because a monster wide enough to fill the
			# screen has its centre well outside the view rectangle while most of it is
			# inside — culling on the centre alone makes the biggest player invisible.
			if not view.grow(piece.radius()).has_point(piece.position()):
				continue

			_draw_piece(monster, piece, mine, rider_piece)

			if show_threat and not mine and my_biggest > 0.0:
				_draw_threat(piece, my_biggest)

		_place_rider(monster, rider_piece)
		_draw_name(monster, rider_piece, mine)


func _draw_piece(
	monster: HungryMonster,
	piece: HungryPiece,
	mine: bool,
	rider_piece: HungryPiece
) -> void:
	var body := monster.colour
	var flags := piece.state.flags

	if (flags & HungryContent.FLAG_FROSTED) != 0:
		body = body.lerp(Color(0.55, 0.80, 1.0), 0.45)

	if (flags & HungryContent.FLAG_PROTECTED) != 0:
		body.a = 0.65

	# A corona, so a monster reads as a body of light in a sky rather than a flat disc laid
	# on top of one. One extra circle per piece, and pieces are counted in dozens.
	draw_circle(
		piece.position(), piece.radius() * 1.15, Color(body.r, body.g, body.b, 0.13)
	)
	draw_circle(piece.position(), piece.radius(), body)
	draw_arc(
		piece.position(),
		piece.radius(),
		0.0,
		TAU,
		48,
		body.darkened(0.45) if not mine else Color.WHITE,
		3.0 if mine else 2.0
	)

	if (flags & HungryContent.FLAG_RUSH) != 0:
		draw_arc(
			piece.position(), piece.radius() + 6.0, 0.0, TAU, 48,
			HungryContent.FRUIT_COLOURS[int(HungryContent.Fruit.RUSH)], 2.0
		)

	if (flags & HungryContent.FLAG_RIND) != 0:
		draw_arc(
			piece.position(), piece.radius() + 11.0, 0.0, TAU, 48,
			HungryContent.FRUIT_COLOURS[int(HungryContent.Fruit.RIND)], 2.0
		)

	# A piece that may merge is drawn open, so a player can see at a glance whether
	# gathering will actually put them back together. Waiting sixteen seconds without
	# being told how long is the least readable part of this genre.
	if piece != rider_piece and (flags & HungryContent.FLAG_MERGE_READY) != 0:
		draw_arc(
			piece.position(), piece.radius() * 0.72, 0.0, TAU, 32,
			Color(1.0, 1.0, 1.0, 0.35), 1.5
		)


## Rings a piece by whether it can be eaten, or eaten by.
##
## Neither, when the two are within the ratio of each other — which is the interesting
## case and the one a colour would lie about. A piece that is merely *smaller* is not
## food; it has to be smaller by a quarter, and the gap between those two is exactly where
## players get eaten.
func _draw_threat(piece: HungryPiece, my_biggest: float) -> void:
	var rules := world.tunables.mass_rules
	var mass := piece.mass()

	if my_biggest >= mass * rules.eat_ratio:
		draw_arc(
			piece.position(), piece.radius() + 4.0, 0.0, TAU, 40, prey_colour, 2.0
		)
	elif mass >= my_biggest * rules.eat_ratio:
		draw_arc(
			piece.position(), piece.radius() + 4.0, 0.0, TAU, 40, threat_colour, 2.0
		)


## Keeps one rider node per player, on the piece the flags say carries it.
func _place_rider(monster: HungryMonster, piece: HungryPiece) -> void:
	if piece == null:
		return

	var rider: HungryRider = _riders.get(monster.id)

	if rider == null:
		rider = HungryRider.make(_schema(), _catalogue())
		_riders[monster.id] = rider
		add_child(rider)

	rider.wear(monster.avatar)
	rider.position = piece.position()
	rider.resize(clampf(piece.radius() * 0.55, 10.0, 90.0))
	rider.queue_redraw()


func _draw_name(monster: HungryMonster, piece: HungryPiece, mine: bool) -> void:
	if not show_names or _font == null or piece == null:
		return

	var size := clampi(int(piece.radius() * 0.34), 11, 34)
	var text := monster.display_name
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := piece.position() + Vector2(-width * 0.5, piece.radius() + float(size) + 4.0)

	draw_string(
		_font, at + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
		Color(0.0, 0.0, 0.0, 0.6)
	)
	draw_string(
		_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
		Color.WHITE if mine else Color(0.88, 0.90, 0.94)
	)


## The rider schema and catalogue, shared across every rider.
var _shared_schema: DotAvatarSchema = null
var _shared_catalogue: DotAvatarCatalogue = null

## Where part scenes come from. Public so a host can hand it a pack it acquired itself.
var content: HungryContentSource = null


func _schema() -> DotAvatarSchema:
	if _shared_schema == null:
		_shared_schema = HungryContent.avatar_schema()

	return _shared_schema


## One catalogue for everybody, because it caches resolutions.
##
## A catalogue per rider would ask dot-cloud for the same hat once per player wearing it,
## and `ResourceLoader.exists` on a path that is not there is not free.
##
## Its resolver is [HungryContentSource], which prefers a mounted pack over the build and
## falls back to nothing so the rider draws itself. That order is what makes downloadable
## cosmetics an upgrade rather than a requirement.
func _catalogue() -> DotAvatarCatalogue:
	if _shared_catalogue == null:
		_shared_catalogue = DotAvatarCatalogue.new()
		_shared_catalogue.builtin_prefix = HungryContentSource.BUILTIN_PREFIX
		content = HungryContentSource.new()
		content.install(_shared_catalogue)

	return _shared_catalogue


## Drops the rider of a player who has left.
func forget(player_id: int) -> void:
	var rider: HungryRider = _riders.get(player_id)

	if rider != null and is_instance_valid(rider):
		rider.queue_free()

	_riders.erase(player_id)


func describe() -> Dictionary:
	return {
		"riders": _riders.size(),
		"view": _view(),
		"player": local_player_id,
		"content": content.describe() if content != null else null,
	}
