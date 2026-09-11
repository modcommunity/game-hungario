class_name HungryServices
extends Node

## Chat, moderation and voice, wired to this arena's people and this game's wire.
##
## [b]The same three addons game-simple-lobby joins, and the proximity answers differ.[/b]
## A lobby is a room you can see all of, so its voice is the whole room and only its text
## has a "near" channel. An arena is not: a monster wide enough to fill the screen cannot
## see the far side, and being able to hear somebody creeping up on you is information.
## So voice here is **proximity by default** and the range is the same number
## [HungryInterest] grows a view rectangle by, because hearing somebody you cannot possibly
## see is the same bug as seeing somebody you cannot hear.
##
## [b]dot-server's own chat is cancelled, not run beside this.[/b] [DotChatRouter] takes
## over the rules — channels, a radius, a backlog, a `/me`, and a gag that survives a
## reconnect — and [HungryModule] cancels `player_chat` so there is exactly one path. Two
## would be two sets of rules to keep in step, and the one that skipped the filter would be
## the one that leaked admin chat.

const CHANNEL := "hungry.services"

const CHANNEL_ALL := &"all"
const CHANNEL_NEAR := &"near"
const CHANNEL_ADMIN := &"admin"
const CHANNEL_WHISPER := &"whisper"

## How far "near" reaches, in world units.
##
## The same number [HungryInterest] uses as its base view, so what you can hear is what
## you could see. A player being audible from outside their own screen is a player being
## heard by somebody they cannot possibly be talking to.
const NEAR_RANGE := 900.0

const PUNISHMENTS_PATH := "user://hungry_punishments.json"


signal command_entered(peer_id: int, command: String, args: PackedStringArray)


var chat: DotChatRouter = null
var moderation: DotModerationManager = null
var voice: DotVoiceRouter = null
## The website chat relay, when one is configured. See [method _build_relay].
var relay: DotChatRelay = null

## The relay's configuration. Left null, a default is built and the relay stays OFF.
##
## Off by default for the same reason every other power in this family is: a relay
## carries what your players type to a web page and back, and that is an operator's
## decision rather than a consequence of installing an addon.
@export var relay_config: DotChatRelayConfig = null

## The backbone client the relay posts through, assigned by the host BEFORE setup.
##
## [b]An [Object], not a [DotBackboneClient].[/b] The relay holds it duck-typed so that
## dot-chat need not depend on dot-auth, and keeping one spelling across the seam means
## the duck-typed contract is the only contract.
var backbone: Object = null


var bridge: HungryNetBridge = null
var world: HungryWorld = null
var server: DotServer = null

var service_scope: StringName = &""
var punishments_path: String = PUNISHMENTS_PATH
var punishments_loaded: bool = false


## Builds all three.
##
## [b]Not a coroutine.[/b] [method DotModuleHost.load_module] calls `_module_load()` with a
## bare call and reads `result.ok` on the next line, so a module whose load suspends
## returns null there and the host crashes on a module that was working.
func setup() -> DotResult:
	if bridge == null or world == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The services need a bridge and a world."
		)

	# Moderation first, because it is what registers `dot_mute_source` and
	# [method DotChatRouter.start] warns once — and then never again — when there is
	# nothing under that name.
	var punished := _build_moderation()

	if not punished.ok:
		return punished

	var talking := _build_chat()

	if not talking.ok:
		return talking

	# After chat, because it needs the router; not fatal, because a relay that cannot
	# start is a server that still runs a perfectly good match.
	var relayed := _build_relay()
	DotLog.result(CHANNEL, "the website chat relay", relayed)

	return _build_voice()


func _build_moderation() -> DotResult:
	moderation = DotModerationManager.new()
	moderation.name = "Moderation"
	moderation.store = DotPunishmentStoreFile.new(punishments_path)
	# No scope: the unconfigured case is the only case a single-server community is ever
	# in, and it is the one dot-moderation shipped a bug about — a server with no scope
	# saw no scoped punishments and silently enforced nothing.
	moderation.server_scope = ""
	moderation.register_mute_source = true
	moderation.register_ban_source = true
	# Zero means "no immunity to respect", not "the highest rank there is".
	moderation.equal_immunity_may_act = true
	moderation.key_for_peer = _subject_for_peer
	add_child(moderation)

	# A bare statement call: [method DotModerationManager.load_all] is a coroutine because
	# a store MAY be an HTTP one, and [DotPunishmentStoreFile] is not — so this runs to
	# completion without suspending and the records are in force by the next line. It
	# cannot be awaited from a module load; see [method setup].
	moderation.load_all()
	punishments_loaded = true

	return DotResult.success(null)


## Who a peer is, for a punishment: the durable account uid.
##
## [b]Deliberately not the same answer [method _key_of] gives dot-chat.[/b] A punishment is
## against a person who will come back, so it is keyed by something that survives a
## reconnect — otherwise a gag lasts until the gagged player presses reconnect, which is
## the first thing anybody who has been gagged tries. A chat line is attributed to somebody
## in this arena right now, which is a player id.
func _subject_for_peer(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session != null:
		return DotPunishmentSubject.for_uid(session.uid())

	var player_id := _player_for(peer_id)
	return DotPunishmentSubject.for_uid("local:%d" % player_id) if player_id != 0 else ""


func _build_chat() -> DotResult:
	chat = DotChatRouter.new()
	chat.name = "Chat"
	chat.rules = chat_rules()
	chat.rules_file = ""
	chat.install_default_channels = false
	chat.handle_me_command = true
	chat.register_as = _scoped(DotChatRouter.SERVICE)
	chat.mute_service = DotModerationManager.MUTE_SERVICE

	chat.send_fn = _send_chat
	chat.peers_fn = _chat_peers
	chat.name_fn = _name_of
	chat.key_fn = _key_of
	chat.position_fn = _position_of
	chat.is_admin_fn = _is_admin

	add_child(chat)

	var started := chat.start()

	if not started.ok:
		return started.wrap("The chat router could not start")

	for channel in chat_channels():
		var added := chat.add_channel(channel)

		if not added.ok:
			return added.wrap("A chat channel was refused")

	chat.command_entered.connect(func(
		peer: int, command: String, args: PackedStringArray, _raw: String
	) -> void:
		command_entered.emit(peer, command, args)
	)

	return DotResult.success(null)


## The four channels. Shared with the client, which builds the same list from this file.
static func chat_channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.make(CHANNEL_ALL, "All", DotChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	everyone.backlog = 12
	everyone.history_limit = 200
	out.append(everyone)

	var near := DotChatChannel.make(CHANNEL_NEAR, "Near", DotChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.68, 0.83, 0.62)
	near.radius = NEAR_RANGE
	# [b]No backlog on a proximity channel.[/b] A backlog is handed to whoever joins, and
	# a line somebody said quietly in a corner is exactly the line that must not be
	# replayed to a stranger who was not there.
	near.backlog = 0
	near.history_limit = 100
	out.append(near)

	var admin := DotChatChannel.make(CHANNEL_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := DotChatChannel.make(
		CHANNEL_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT
	)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## What a line may be.
##
## Shorter and slower than the lobby's, because this is a game people are playing rather
## than a room they are standing in: a long line is a long time not steering, and the rate
## that matters is the one that stops a burst rather than the one that allows conversation.
static func chat_rules() -> DotChatRules:
	var rules := DotChatRules.new()
	rules.max_length = 140
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 20
	rules.burst = 4.0
	rules.flood_penalty_sec = 8.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if bridge == null:
		return

	# The player id, lifted into the one meta field this game's wire carries, so a client
	# can colour a line by whose it is and put it over the right monster. The key IS the
	# player id — see [method _key_of].
	var addressed := wire.duplicate()
	var player_id := str(wire.get("s", ""))

	if player_id.is_valid_int() and player_id.to_int() > 0:
		addressed["x"] = {"p": player_id.to_int()}

	for peer_id in recipients:
		bridge.send_chat(int(peer_id), addressed)



# --- The website relay -----------------------------------------------------

## Joins this server's chat to its room on the website.
##
## [b]Every seam points at something that already existed.[/b] The backbone client is
## dot-auth's. The permission answer is dot-server's admin manager, through
## `uid_has_permission` — the method written for exactly this, deciding what somebody may
## do when they are not connected. The command runner is `DotServer.run_command_as_uid`,
## which builds a context with that uid's OWN flags rather than RCON's root.
##
## Nothing here is a new policy. A relayed command is checked against the same file, by
## the same flags, as the same person typing it in game.
func _build_relay() -> DotResult:
	if relay_config == null:
		relay_config = DotChatRelayConfig.new()

	if not relay_config.enabled:
		return DotResult.success(null)

	if backbone == null:
		# **Found, not handed over.** A backbone client is built by whatever owns the
		# server's credential — dot-server-deploy's `TmcReport`, or this game's own
		# identity layer — and a relay built during module load exists before any host
		# could assign one. `DotBackboneClient` publishes itself under this name for
		# exactly that reason; the ordering trap is the one that left dot-server's audit
		# log unopened in every default configuration.
		backbone = DotRegistry.get_service(&"dot_backbone_client")

	if backbone == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The chat relay is on but no backbone client was handed to services."
		)

	relay = DotChatRelay.new()
	relay.name = "ChatRelay"
	relay.router = chat
	relay.config = relay_config
	relay.client = backbone
	relay.permission_fn = _uid_has_permission
	relay.command_fn = _run_relayed_command

	add_child(relay)

	var started := relay.start()

	if not started.ok:
		remove_child(relay)
		relay.queue_free()
		relay = null
		return started

	relay.site_command.connect(_on_site_command)

	return DotResult.success(relay)


func _uid_has_permission(uid: String, flag: String) -> bool:
	if server == null or server.admins == null:
		return false
	return server.admins.uid_has_permission(uid, flag)


func _run_relayed_command(
	uid: String, command: String, args: PackedStringArray, source: int
) -> void:
	if server == null:
		return

	for reply in server.run_command_as_uid(uid, command, args, source):
		DotLog.info(CHANNEL, "relayed command reply", {"uid": uid, "line": reply})


func _on_site_command(uid: String, command: String, allowed: bool) -> void:
	# Audited either way. A refusal is the half worth having a record of: it is somebody
	# trying to drive the server from a web page without the rights to.
	if server != null and server.audit != null:
		server.audit.record(
			"relay_command", "web:%s" % uid, command, {"allowed": allowed}
		)


# --- Voice -----------------------------------------------------------------

func _build_voice() -> DotResult:
	var config := voice_config()
	var problem := config.validate()

	if not problem.ok:
		return problem.wrap("The voice configuration is not usable")

	voice = DotVoiceRouter.new()
	voice.name = "Voice"
	voice.config = config
	# [b]Proximity, and this is where this game and the lobby part company.[/b] An arena
	# is bigger than a screen; hearing somebody creeping up on you is information, and
	# hearing the whole server is noise. The lobby chose the opposite and both are right
	# for what they are.
	voice.default_channel = DotVoiceRouter.Channel.PROXIMITY
	voice.proximity_range = config.proximity_range
	voice.max_bytes_per_second = config.max_bytes_per_second
	voice.send_fn = _send_voice
	voice.position_fn = _position_of

	add_child(voice)

	return DotResult.success(null)


## The voice format, which both ends must agree on exactly.
##
## Static, and read by the client too: [method DotVoiceConfig.format_fingerprint] exists
## because a sample rate or a frame length that differs between two peers is a stream of
## packets the router refuses for being the wrong length, counted and said to nobody.
static func voice_config() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = NEAR_RANGE
	config.max_bytes_per_second = 6144
	return config


func _send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if bridge != null and bridge.link != null:
		bridge.link.send_voice(peer_id, payload)


# --- Peers -----------------------------------------------------------------

func add_peer(peer_id: int) -> void:
	if voice != null:
		voice.add_peer(peer_id)


func remove_peer(peer_id: int) -> void:
	if voice != null:
		voice.remove_peer(peer_id)

	if chat != null:
		# The rate limiter's and the repeat detector's memory of this peer. Without this a
		# reconnecting player inherits whatever the last holder of that peer id had been
		# saying, and is told they are repeating themselves on their first line.
		chat.forget(peer_id)


func _chat_peers() -> PackedInt32Array:
	return bridge.ready_peers() if bridge != null else PackedInt32Array()


func _session_for(peer_id: int) -> DotClientSession:
	return server.session_of(peer_id) if server != null else null


func _player_for(peer_id: int) -> int:
	return bridge.player_for_peer(peer_id) if bridge != null else 0


func _name_of(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session != null:
		return session.display_name

	var monster := world.monster_for(_player_for(peer_id)) if world != null else null
	return monster.display_name if monster != null else "player %d" % peer_id


## The key a chat line is attributed to: the speaker's player id.
##
## [b]Not the account uid.[/b] "Who said this" is a question about the arena — the colour
## in the log and the monster it belongs to — and a client resolving it has a roster and
## nothing else. Two guests behind one device id share a uid, so keying by that puts the
## second person's words under the first person's name with every count still matching;
## game-simple-lobby found that with two clients in one process.
func _key_of(peer_id: int) -> String:
	var player_id := _player_for(peer_id)
	return str(player_id) if player_id != 0 else ""


## Where somebody is, as dot-chat and dot-voice both ask for it.
##
## The monster's **mass-weighted centroid**, which is the same point [HungryInterest]
## measures from — a split player is several places at once, and any single piece is an
## arbitrary fragment that makes a burst monster inaudible from where it actually is. Zero for a dead player, who is a spectator
## and has no position: they can hear the room channel and nothing else, which is right.
func _position_of(peer_id: int) -> Vector3:
	if world == null:
		return Vector3.ZERO

	var monster := world.monster_for(_player_for(peer_id))

	# `alive` rather than a piece count: being eaten means having nothing at all, and a
	# dead player is a spectator with no position. They can still hear the room channel,
	# which is right — what they must not do is be heard from wherever their monster
	# happened to die.
	if monster == null or not monster.alive:
		return Vector3.ZERO

	var at := monster.centre()
	return Vector3(at.x, at.y, 0.0)


func _is_admin(peer_id: int) -> bool:
	var session := _session_for(peer_id)
	return session != null and session.is_admin()


func _scoped(base: StringName) -> StringName:
	return base if service_scope == &"" else StringName("%s:%s" % [base, service_scope])


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if chat != null:
		out.append_array(chat.describe_lines())

	if voice != null:
		out.append_array(voice.describe_lines())

	if moderation != null:
		out.append_array(moderation.describe_lines())
		out.append("punishments  %s" % (
			"loaded" if punishments_loaded else "STILL LOADING — nothing is enforced"
		))

	return out
