class_name HungryEvents
extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in one place, in pairs, because they have to be exact inverses
## and nothing can check that for you — the self-test round-trips every one of them for
## that reason.
##
## [b]Most of this is indices, not positions.[/b] Food, fruit and item drops are placed
## by a hash of (seed, index), so a client that knows the seed can lay eleven hundred of
## them out from a list of integers. The exception is planted food, which a player put
## where they chose; those carry a position and are the reason [method write_field] has
## two shapes in it.

## What the authority sends.
enum Kind {
	## Seed, tick rate, who you are. The first thing a client is told.
	HELLO,
	## A player joined, with their name and their avatar.
	JOIN,
	## A player left.
	LEAVE,
	## A piece came into existence and should be mirrored.
	SPAWN,
	## A piece is gone.
	DESPAWN,
	## Food appeared or was eaten.
	FIELD,
	## A new round: forget the field and expect a full one.
	FIELD_RESET,
	## Somebody threw something.
	THROW,
	## Something landed.
	IMPACT,
	## Somebody was burst.
	BURST,
	## Somebody was devoured.
	DIED,
	## The leaderboard.
	BOARD,
	## What you are carrying. Sent only to the player it is about.
	CARRY,
	## One chat line, already routed, sanitised and addressed by [DotChatRouter].
	##
	## The server decides who gets one; a client that receives it draws it. There is no
	## audience field on the wire for that reason — a client told who *else* could hear a
	## whisper would be a client that could report it.
	CHAT,
	## A hunter came into existence, or moved, or is gone. See [HungryHunters].
	HUNTER,
	## A hazard was placed in the arena, or cleared.
	HAZARD,
	## A board, a rank or an achievement somebody just earned.
	PROGRESS,
}

## What a client asks for.
enum Ask {
	## I have loaded. Tell me about the world.
	READY,
	## Here is my avatar.
	AVATAR,
	## Here is what I want to bring in.
	LOADOUT,
	## I typed a line. The server decides what channel it lands on and who hears it.
	##
	## [b]The channel is a request, not an instruction.[/b] It is what the player had
	## selected; [DotChatRouter] validates it against the channel's own permission rules,
	## so asking for the admin channel is refused rather than obeyed.
	SAY,
	## Rock the vote, nominate, or cast one. The body is a token the vote source resolves.
	VOTE,
}

## Position range for everything in this file, matching [Dot2DNetSync] so that a
## position sent as an event and the same position sent in a snapshot quantise
## identically. Two grids for one coordinate is a piece of food that is a pixel away
## from where the server thinks it is.
const POSITION_BITS := Dot2DNetSync.POSITION_BITS
const WORLD_EXTENT := Dot2DNetSync.WORLD_EXTENT

## Ids per field chunk. A full resynchronisation is eleven hundred and something ids, and
## one reliable packet of that size is both a fragmentation and a
## head-of-line-blocking problem on a browser socket.
const FIELD_CHUNK := 300

const NAME_BYTES := 32


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func _writer() -> DotNetWriter:
	return DotNetWriter.new()


static func _write_position(writer: DotNetWriter, at: Vector2) -> void:
	writer.write_vector2_range(at, -WORLD_EXTENT, WORLD_EXTENT, POSITION_BITS)


static func _read_position(reader: DotNetReader) -> Vector2:
	return reader.read_vector2_range(-WORLD_EXTENT, WORLD_EXTENT, POSITION_BITS)


# --- HELLO -----------------------------------------------------------------

## Largest cosmetics manifest URL a server may name.
##
## Bounded because it is a string a server chooses and a client hands to an HTTP
## client — and because a length prefix is the cheapest thing in this protocol to lie
## about.
const PACK_URL_BYTES := 256

static func write_hello(
	world_seed: int,
	tick_rate: int,
	player_id: int,
	peer_id: int,
	server_tick: int,
	world_size: Vector2,
	pack_url: String = ""
) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(world_seed)
	writer.write_uint(tick_rate, 8)
	writer.write_varint(player_id)
	writer.write_varint(peer_id)
	writer.write_uint(server_tick, 32)
	writer.write_float32(world_size.x)
	writer.write_float32(world_size.y)
	# Where this server's cosmetics live, or "" for "whatever you shipped with". Sent
	# rather than configured on the client because a community server may ship its own
	# parts, and because a client that had to be told out of band is a client that will
	# not be.
	writer.write_string(pack_url, PACK_URL_BYTES)
	return writer.to_bytes()


static func read_hello(reader: DotNetReader) -> Dictionary:
	var out := {
		"seed": reader.read_varint(),
		"tick_rate": reader.read_uint(8),
		"player_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"tick": reader.read_uint(32),
		"world_size": Vector2(reader.read_float32(), reader.read_float32()),
		"pack_url": reader.read_string(PACK_URL_BYTES),
	}
	out["ok"] = reader.ok()
	return out


# --- JOIN / LEAVE ----------------------------------------------------------

static func write_join(
	player_id: int,
	peer_id: int,
	display_name: String,
	avatar: DotAvatar,
	schema: DotAvatarSchema,
	loadout: DotLoadout = null
) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(player_id)
	writer.write_varint(peer_id)
	writer.write_string(display_name, NAME_BYTES)

	# An avatar is optional on the wire, because a player can be in the world before the
	# store has answered. A client that received no avatar draws the deterministic guest
	# rather than nothing, and a later JOIN for the same id replaces it.
	var has_avatar := avatar != null and schema != null
	writer.write_bool(has_avatar)

	if has_avatar:
		DotAvatarSync.write(avatar, schema, writer)

	# The loadout travels for one reason that is not cosmetic: the trait changes how fast
	# a monster moves, and a client predicts its own movement. Two ends computing speed
	# from different loadouts is a permanent mispredict, not a rounding error.
	var has_loadout := loadout != null
	writer.write_bool(has_loadout)

	if has_loadout:
		loadout.write(writer)

	return writer.to_bytes()


static func read_join(reader: DotNetReader, schema: DotAvatarSchema) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"name": reader.read_string(NAME_BYTES),
		"avatar": null,
		"loadout": null,
	}

	if reader.read_bool():
		var decoded := DotAvatarSync.read(schema, reader)

		if decoded.ok:
			out["avatar"] = decoded.value

	if reader.read_bool():
		var carried := DotLoadout.read(reader)

		if carried.ok:
			out["loadout"] = carried.value

	out["ok"] = reader.ok()
	return out


static func write_loadout(loadout: DotLoadout) -> PackedByteArray:
	var writer := _writer()
	loadout.write(writer)
	return writer.to_bytes()


static func read_loadout(reader: DotNetReader) -> DotResult:
	return DotLoadout.read(reader)


static func write_player(player_id: int) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(player_id)
	return writer.to_bytes()


static func read_player(reader: DotNetReader) -> int:
	return reader.read_varint()


# --- SPAWN / DESPAWN -------------------------------------------------------

static func write_spawn(
	net_id: int,
	peer_id: int,
	owner_id: int,
	piece_id: int,
	at: Vector2,
	mass: float
) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(net_id)
	writer.write_varint(peer_id)
	writer.write_varint(owner_id)
	writer.write_varint(piece_id)
	_write_position(writer, at)
	writer.write_uint(
		clampi(int(round(mass)), 0, (1 << Dot2DNetSync.MASS_BITS) - 1),
		Dot2DNetSync.MASS_BITS
	)
	return writer.to_bytes()


static func read_spawn(reader: DotNetReader) -> Dictionary:
	var out := {
		"net_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"owner_id": reader.read_varint(),
		"piece_id": reader.read_varint(),
		"position": _read_position(reader),
		"mass": float(reader.read_uint(Dot2DNetSync.MASS_BITS)),
	}
	out["ok"] = reader.ok()
	return out


static func write_despawn(net_id: int) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(net_id)
	return writer.to_bytes()


# --- FIELD -----------------------------------------------------------------

## One chunk of field change: ids that appeared, ids that went.
##
## A planted id carries its position; the other three carry nothing but the id, because
## the position follows from the seed. That asymmetry is the whole reason planted food is
## a separate field rather than a flag on the ordinary one.
static func write_field(
	added: Array,
	removed: Array,
	planted: Dictionary
) -> PackedByteArray:
	var writer := _writer()

	writer.write_varint(added.size())

	for entry in added:
		var grid_id := int(entry)
		writer.write_varint(grid_id)

		if HungryField.kind_of(grid_id) == HungryField.Kind.PLANTED:
			var row: Dictionary = planted.get(grid_id, {})
			_write_position(writer, row.get("position", Vector2.ZERO))
			writer.write_uint(int(row.get("tier", HungryContent.LURE_FOOD_TIER)), 3)

	writer.write_varint(removed.size())

	for entry in removed:
		writer.write_varint(int(entry))

	return writer.to_bytes()


static func read_field(reader: DotNetReader) -> Dictionary:
	var added: Array = []
	var removed: Array = []
	var planted: Dictionary = {}

	var added_count := reader.read_varint()

	# Bounded before the loop rather than trusted: a count of four billion is one varint
	# and would otherwise be four billion iterations.
	if added_count < 0 or added_count > FIELD_CHUNK * 8:
		return {"ok": false, "added": added, "removed": removed, "planted": planted}

	for _i in range(added_count):
		var grid_id := reader.read_varint()
		added.append(grid_id)

		if HungryField.kind_of(grid_id) == HungryField.Kind.PLANTED:
			planted[grid_id] = {
				"position": _read_position(reader),
				"tier": reader.read_uint(3),
			}

		if not reader.ok():
			return {"ok": false, "added": added, "removed": removed, "planted": planted}

	var removed_count := reader.read_varint()

	if removed_count < 0 or removed_count > FIELD_CHUNK * 8:
		return {"ok": false, "added": added, "removed": removed, "planted": planted}

	for _i in range(removed_count):
		removed.append(reader.read_varint())

	return {
		"ok": reader.ok(),
		"added": added,
		"removed": removed,
		"planted": planted,
	}


static func write_field_reset(world_seed: int) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(world_seed)
	return writer.to_bytes()


# --- Projectiles -----------------------------------------------------------

static func write_throw(shot: HungryProjectile) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(shot.id)
	writer.write_varint(shot.thrower_id)
	writer.write_uint(maxi(0, HungryContent.item_index(shot.item)), 4)
	_write_position(writer, shot.origin)
	# The direction is unit length by construction, so two ten-bit components is under a
	# quarter of a degree — far below what anybody can see over a 1150-unit flight.
	writer.write_vector2_range(shot.direction, -1.0, 1.0, 10)
	writer.write_uint(shot.spawn_tick, 32)
	return writer.to_bytes()


static func read_throw(reader: DotNetReader) -> Dictionary:
	var out := {
		"id": reader.read_varint(),
		"thrower": reader.read_varint(),
		"item_index": reader.read_uint(4),
		"origin": _read_position(reader),
		"direction": reader.read_vector2_range(-1.0, 1.0, 10),
		"tick": reader.read_uint(32),
	}
	out["ok"] = reader.ok() \
		and out["item_index"] < HungryContent.ITEM_IDS.size()
	return out


static func write_impact(
	shot_id: int,
	at: Vector2,
	hit_player: int
) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(shot_id)
	_write_position(writer, at)
	writer.write_varint(hit_player)
	return writer.to_bytes()


static func read_impact(reader: DotNetReader) -> Dictionary:
	var out := {
		"id": reader.read_varint(),
		"position": _read_position(reader),
		"hit": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


# --- Cues ------------------------------------------------------------------

static func write_pair(first: int, second: int, extra: int = 0) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(first)
	writer.write_varint(second)
	writer.write_varint(extra)
	return writer.to_bytes()


static func read_pair(reader: DotNetReader) -> Dictionary:
	var out := {
		"first": reader.read_varint(),
		"second": reader.read_varint(),
		"extra": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


# --- Leaderboard -----------------------------------------------------------

static func write_board(rows: Array) -> PackedByteArray:
	var writer := _writer()
	writer.write_uint(mini(rows.size(), 16), 5)

	for index in range(mini(rows.size(), 16)):
		var row: Dictionary = rows[index]
		writer.write_varint(int(row.get("id", 0)))
		writer.write_uint(
			clampi(int(row.get("mass", 0)), 0, (1 << Dot2DNetSync.MASS_BITS) - 1),
			Dot2DNetSync.MASS_BITS
		)

	return writer.to_bytes()


static func read_board(reader: DotNetReader) -> Array:
	var out: Array = []
	var count := reader.read_uint(5)

	for _i in range(count):
		var id := reader.read_varint()
		var mass := reader.read_uint(Dot2DNetSync.MASS_BITS)

		if not reader.ok():
			break

		out.append({"id": id, "mass": mass})

	return out


# --- Carrying --------------------------------------------------------------

static func write_carry(items: Array) -> PackedByteArray:
	var writer := _writer()
	var count := mini(items.size(), HungryContent.MAX_CARRIED)
	writer.write_uint(count, 3)

	for index in range(count):
		writer.write_uint(maxi(0, HungryContent.item_index(items[index])), 4)

	return writer.to_bytes()


static func read_carry(reader: DotNetReader) -> Array:
	var out: Array = []
	var count := reader.read_uint(3)

	for _i in range(mini(count, HungryContent.MAX_CARRIED)):
		var index := reader.read_uint(4)

		if not reader.ok() or index >= HungryContent.ITEM_IDS.size():
			break

		out.append(HungryContent.ITEM_IDS[index])

	return out


# --- Requests --------------------------------------------------------------

static func write_avatar(
	avatar: DotAvatar,
	schema: DotAvatarSchema
) -> PackedByteArray:
	var writer := _writer()
	DotAvatarSync.write(avatar, schema, writer)
	return writer.to_bytes()


static func read_avatar(
	reader: DotNetReader,
	schema: DotAvatarSchema
) -> DotResult:
	return DotAvatarSync.read(schema, reader)


# --- CHAT ------------------------------------------------------------------

const CHAT_BYTES := 160
const CHAT_CHANNEL_BYTES := 24
const CHAT_KEY_BYTES := 48
const CHAT_KIND_BITS := 4


## One chat line, from [method DotChatMessage.to_dictionary], plus who said it.
##
## [b]Encoded field by field rather than as JSON.[/b] A JSON body is a variable-length blob
## a reader cannot bound and a hostile server could make enormous, and it costs about three
## times the bytes for a message whose whole point is that it is small and frequent.
##
## The `x` (meta) field is not carried as a dictionary. What this game needs out of it is
## one number — the player the line belongs to — so that is a field, bounded like every
## other, and the reader puts it back under `x` where
## [method DotChatMessage.from_dictionary] finds it. An arbitrary dictionary on the wire is
## an arbitrary dictionary a server can put anything in.
##
## The kind travels as an **index into [constant DotChatMessage.KIND_NAMES]**, not as the
## name — one table used in both directions, which is the lesson dot-moderation paid for
## when a stored voice mute loaded back as a warning.
static func write_chat(wire: Dictionary) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(int(wire.get("n", 0)))
	writer.write_uint(int(wire.get("t", 0)), 32)
	writer.write_string(str(wire.get("c", "")), CHAT_CHANNEL_BYTES)
	writer.write_uint(
		maxi(0, DotChatMessage.kind_from_name(str(wire.get("k", "say")))), CHAT_KIND_BITS
	)
	writer.write_string(str(wire.get("s", "")), CHAT_KEY_BYTES)
	writer.write_string(str(wire.get("d", "")), NAME_BYTES)
	writer.write_string(str(wire.get("w", "")), CHAT_KEY_BYTES)
	writer.write_string(str(wire.get("m", "")), CHAT_BYTES)

	var meta: Variant = wire.get("x")
	var player_id: int = 0

	if typeof(meta) == TYPE_DICTIONARY:
		player_id = int((meta as Dictionary).get("p", 0))

	writer.write_varint(maxi(0, player_id))
	return writer.to_bytes()


## The inverse. Returns the dictionary [method DotChatClient.receive] takes.
##
## An unknown kind index comes back as `"say"` rather than as an empty string, because
## [method DotChatMessage.from_dictionary] refuses a name it does not know — and refusing a
## whole line for a field nobody can see loses the text as well.
static func read_chat(reader: DotNetReader) -> Dictionary:
	var out := {
		"n": reader.read_varint(),
		"t": reader.read_uint(32),
		"c": reader.read_string(CHAT_CHANNEL_BYTES),
	}

	var kind := reader.read_uint(CHAT_KIND_BITS)
	out["k"] = DotChatMessage.KIND_NAMES[kind] \
		if kind >= 0 and kind < DotChatMessage.KIND_NAMES.size() else "say"

	out["s"] = reader.read_string(CHAT_KEY_BYTES)
	out["d"] = reader.read_string(NAME_BYTES)
	out["w"] = reader.read_string(CHAT_KEY_BYTES)
	out["m"] = reader.read_string(CHAT_BYTES)

	var player_id := reader.read_varint()

	if player_id > 0:
		out["x"] = {"p": player_id}

	out["ok"] = reader.ok()
	return out


static func write_say(channel_id: StringName, text: String) -> PackedByteArray:
	var writer := _writer()
	writer.write_string(String(channel_id), CHAT_CHANNEL_BYTES)
	writer.write_string(text, CHAT_BYTES)
	return writer.to_bytes()


static func read_say(reader: DotNetReader) -> Dictionary:
	var out := {
		"channel": reader.read_string(CHAT_CHANNEL_BYTES),
		"text": reader.read_string(CHAT_BYTES),
	}
	out["ok"] = reader.ok()
	return out


# --- HUNTERS ---------------------------------------------------------------

## Bits for a hunter's id and its kind index. See [HungryHunters].
const HUNTER_ID_BITS := 16
const HUNTER_KIND_BITS := 6

## Radius quantisation. A hunter is drawn as a circle and nothing needs a tenth of a unit.
const HUNTER_RADIUS_BITS := 10
const HUNTER_RADIUS_MAX := 400.0


## A hunter's whole state, in one message.
##
## [b]Hunters are not dot-net entities and that is deliberate.[/b] A monster's piece is:
## it is predicted, reconciled and interest-managed, all of which a player's own input
## needs. A hunter is server-authoritative, unpredicted, and there are at most a handful —
## the same division dot-props makes for a rigid body, reached from the other side. One
## reliable event a few times a second is cheaper than an entity's declarations and does
## not put a new id space beside the piece ids.
static func write_hunter(
	hunter_id: int, kind_index: int, at: Vector2, radius: float, alive: bool
) -> PackedByteArray:
	var writer := _writer()
	writer.write_uint(hunter_id, HUNTER_ID_BITS)
	writer.write_uint(kind_index, HUNTER_KIND_BITS)
	writer.write_bool(alive)
	_write_position(writer, at)
	writer.write_float_range(radius, 0.0, HUNTER_RADIUS_MAX, HUNTER_RADIUS_BITS)
	return writer.to_bytes()


static func read_hunter(reader: DotNetReader) -> Dictionary:
	var out := {
		"hunter_id": reader.read_uint(HUNTER_ID_BITS),
		"kind_index": reader.read_uint(HUNTER_KIND_BITS),
		"alive": reader.read_bool(),
		"position": _read_position(reader),
		"radius": reader.read_float_range(0.0, HUNTER_RADIUS_MAX, HUNTER_RADIUS_BITS),
	}
	out["ok"] = reader.ok()
	return out


# --- HAZARDS ---------------------------------------------------------------

const HAZARD_ID_BITS := 16
const HAZARD_KIND_BITS := 6


static func write_hazard(
	place_id: int, kind_index: int, at: Vector2, present: bool
) -> PackedByteArray:
	var writer := _writer()
	writer.write_uint(place_id, HAZARD_ID_BITS)
	writer.write_uint(kind_index, HAZARD_KIND_BITS)
	writer.write_bool(present)
	_write_position(writer, at)
	return writer.to_bytes()


static func read_hazard(reader: DotNetReader) -> Dictionary:
	var out := {
		"place_id": reader.read_uint(HAZARD_ID_BITS),
		"kind_index": reader.read_uint(HAZARD_KIND_BITS),
		"present": reader.read_bool(),
		"position": _read_position(reader),
	}
	out["ok"] = reader.ok()
	return out


# --- PROGRESS --------------------------------------------------------------

const PROGRESS_ID_BYTES := 40
const PROGRESS_TEXT_BYTES := 96


## Something a player earned: an achievement, a rank, a personal best.
##
## [b]Text, not a rule.[/b] The rules are [DotAchievementCatalogue]'s and stay on the
## server: a client that held them could tell a player they had earned something the
## server disagreed about, and the server is the one filing it.
static func write_progress(
	player_id: int, id: StringName, title: String, value: int
) -> PackedByteArray:
	var writer := _writer()
	writer.write_varint(player_id)
	writer.write_string(String(id), PROGRESS_ID_BYTES)
	writer.write_string(title, PROGRESS_TEXT_BYTES)
	writer.write_varint(maxi(0, value))
	return writer.to_bytes()


static func read_progress(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"id": reader.read_string(PROGRESS_ID_BYTES),
		"title": reader.read_string(PROGRESS_TEXT_BYTES),
		"value": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


# --- VOTES -----------------------------------------------------------------

const VOTE_TOKEN_BYTES := 40


## What a client asks the vote for: `rtv`, `nominate <id>`, `vote <n>`, `extend`.
##
## [b]A token rather than an enum, because the thing voted for is an id and what an id
## means is a [DotVoteSource]'s business.[/b] That is what lets one engine drive
## dot-server's games and dot-map's maps without this file naming either.
static func write_vote(token: String) -> PackedByteArray:
	var writer := _writer()
	writer.write_string(token, VOTE_TOKEN_BYTES)
	return writer.to_bytes()


static func read_vote(reader: DotNetReader) -> String:
	return reader.read_string(VOTE_TOKEN_BYTES)
