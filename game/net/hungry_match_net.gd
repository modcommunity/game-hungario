class_name HungryMatchNet
extends DotNetBehaviour

## The match clock, replicated. Four numbers on one always-relevant entity.
##
## [b]Why an entity of its own.[/b] Every client needs the round state and the clock
## whether or not it can see anybody, and there is no piece that is always in view — a
## dead player has none at all. [member DotNetIdentity.always_relevant] is exactly the
## exemption this wants, and it costs about fifty bits a snapshot.
##
## It is also the thing that keeps an empty server's match running: it is the only entity
## on a server with no players, so it is what calls
## [method HungryNetBridge.ensure_world_ticked]. Without that the warmup of an empty
## server never ends and the first player to join arrives into a match frozen since boot.

## Set by [HungryNetBridge] before registration.
var world: HungryWorld = null
var bridge: HungryNetBridge = null

# --- From DotMatchNetSync.specs() ---
var net_state: int = 0
var net_round: int = 0
var net_ends_at: int = 0
var net_winner: int = 0

## Newest tick this behaviour has adopted. Client side.
var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotMatchNetSync.specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

	# Above a piece: a client that missed the round ending draws a live HUD over a world
	# that has already reset, and every other number on the screen is then wrong.
	for declaration in net_vars:
		declaration.with_priority(8.0)


func _net_simulate(tick: int, _delta: float) -> void:
	if identity == null or not identity.is_authoritative:
		return

	if bridge != null:
		bridge.ensure_world_ticked(tick)

	if world != null:
		DotMatchNetSync.pull(world.match_node, self, tick)


func _net_state_applied(tick: int) -> void:
	last_state_tick = tick


## Seconds left on the clock, from the replicated end tick and this client's own tick.
##
## Returns -1 when there is no clock, matching [method DotMatch.seconds_remaining], so a
## HUD has one branch rather than two.
func seconds_remaining(current_tick: int, tick_rate: int) -> float:
	return DotMatchNetSync.seconds_remaining(self, current_tick, tick_rate)


func state_name() -> String:
	var names := DotMatch.State.keys()
	return String(names[net_state]) if net_state < names.size() else "?"


func describe() -> Dictionary:
	return {
		"state": state_name(),
		"round": net_round,
		"ends_at": net_ends_at,
		"winner": net_winner,
	}
