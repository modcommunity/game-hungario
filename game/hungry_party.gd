class_name HungryParty
extends Node

## A private arena among friends, with the host able to leave.
##
## [b]hungario's peer-to-peer decision is the opposite of game-arena's on one axis and the
## same on the other, and both halves follow from what kind of game it is.[/b]
##
## **Migration is on, where the arena turns it off.** A deathmatch is rounds: the host
## holds the match clock, the score and every hitbox, and handing that over mid-round
## produces a round nobody can agree about, so an arena party whose host leaves has ended.
## hungario is a *continuous* arena — people join, grow, burst and come back, and there is
## no round boundary to be in the middle of — so a host leaving should cost a moment and
## not the session.
##
## **Reporting is refused, exactly as the arena refuses it.** This game files to dot-stats
## and unlocks dot-achievements, and a peer-to-peer host is a player's own machine that can
## lie about how much they ate. A host who can cheat and a persistent number are one
## exploit rather than two features.

const CHANNEL := "hungry.party"

signal open(code: String)
signal closed(res: DotResult)

var session: DotP2PSession = null

@export var signalling_url: String = ""

var _http: DotHttp = null


func setup() -> DotResult:
	session = DotP2PSession.new()
	session.name = "P2P"
	session.config = _config()
	add_child(session)

	var res := session.setup()
	if not res.ok:
		return res.wrap("hungario's party session")

	session.signaller = _make_signaller()
	session.ended.connect(func(r: DotResult) -> void: closed.emit(r))
	return DotResult.success(null)


func _config() -> DotP2PConfig:
	var c := DotP2PConfig.new()
	# Sixteen. The arena is big and this game is cheap on the wire -- a monster is a
	# position, a mass and a bitmask -- so the limit here is the host's uplink rather than
	# the simulation, and sixteen is what a domestic one carries at this rate.
	c.max_peers = 16
	c.trust = DotP2PConfig.Trust.SANDBOXED
	# On, and this is the axis where this game disagrees with the arena. There is no round
	# to be in the middle of.
	c.migrate_host = true
	c.signalling_url = signalling_url
	return c


func _make_signaller() -> DotP2PSignaller:
	if signalling_url.is_empty():
		return DotP2PSignallerLoopback.new(session.local_id)
	_http = DotHttp.new()
	_http.name = "PartyHttp"
	add_child(_http)
	return DotP2PSignallerHttp.new(signalling_url, session.local_id, _http)


func host(display_name: String) -> DotResult:
	if not DotP2PSession.available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"this build cannot host a private arena",
			DotP2PSession.unavailable_reason()
		)
	var res := session.host(display_name)
	if res.ok:
		open.emit(str(res.value))
		DotLog.info(
			CHANNEL,
			"a private arena is open; nothing from it is filed anywhere",
			{"code": str(res.value)}
		)
	return res


func join(code: String, display_name: String) -> DotResult:
	return session.join(code, display_name)


func leave() -> void:
	session.leave()


func active() -> bool:
	return session != null and session.state() != &"idle"


## Whether statistics and achievements may leave this session. Asked in one place.
func reporting_allowed() -> bool:
	if not active():
		return true
	return session.config.trust != DotP2PConfig.Trust.SANDBOXED


func describe_lines() -> PackedStringArray:
	if session == null:
		return PackedStringArray(["no party"])
	var out := session.describe_lines()
	out.append(
		"  reporting %s" % ("allowed" if reporting_allowed() else "refused: this arena is sandboxed")
	)
	return out
