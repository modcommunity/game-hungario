class_name HungryNetCommand
extends DotNetInput

## One tick of a player's intent, on the wire.
##
## [b]This is the only thing a client is allowed to send about itself.[/b] Clients send
## inputs, never state — a client that could send a position could send any position, and
## dot-net's whole security model rests on the distinction.
##
## It is a thin wrapper around [Dot2DCommand] rather than a set of fields, because
## [Dot2DCommand] already knows how to quantise itself through a duck-typed
## [code]Variant[/code] writer. dot-2d cannot name a dot-net class — a script that
## mentions a missing [code]class_name[/code] fails to parse — so the composition happens
## here, and the quantisation decisions stay in the addon that owns them.
##
## [b]The pointer is a direction and a distance, not a screen position.[/b] A screen
## position depends on a window size and a camera zoom the server does not have, so the
## sampler resolves it before it goes anywhere. That is the whole reason an agar.io-like
## game is predictable at all.

## Largest pointer distance accepted, in world units. Also the wire's range, so both
## ends must agree — it is a constant rather than a field for that reason.
const MAX_REACH := 1200.0

var command: Dot2DCommand = Dot2DCommand.new()


func _write(writer: DotNetWriter) -> void:
	command.write(writer, MAX_REACH)


func _read(reader: DotNetReader) -> void:
	command = Dot2DCommand.new()
	command.read(reader, MAX_REACH)


## Clamps what a client could exaggerate.
##
## [b]Not optional, and not redundant with quantisation.[/b] Quantisation bounds each
## field on its own; it cannot bound the relationship between them. A move vector of
## (1, 1) is two legal components and a length of 1.41, and [member Dot2DCommand.reach]
## doubles as the speed multiplier in pointer mode — which makes it the single most
## attractive field in this whole protocol to inflate.
func _sanitise() -> void:
	command.sanitise(MAX_REACH)


## Whether two inputs are identical, so a player holding still costs less.
func _equals(other: DotNetInput) -> bool:
	var them := other as HungryNetCommand
	return them != null and command.equals(them.command)


## Bits one command costs, before dot-net's own framing.
static func estimated_bits() -> int:
	return Dot2DCommand.estimated_bits()


func describe() -> Dictionary:
	return {"tick": tick, "command": command.describe()}
