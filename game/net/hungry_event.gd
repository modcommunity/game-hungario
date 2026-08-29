class_name HungryEvent
extends DotNetMessage

## Everything the authority tells a client that is not a snapshot.
##
## [b]One message type with a kind byte, rather than thirteen registered types.[/b]
## [DotNetMessageRegistry] fixes ids from the sorted names and hashes the set, so two
## builds that disagree about the schema are refused rather than misread — and that
## guarantee is exactly as strong with one type as with thirteen, while the failure mode
## of "a type registered on one side only" disappears entirely. The kind is validated
## against [enum HungryEvents.Kind] on receipt, which is the same check the registry
## would have done.
##
## The direction is [constant DotNetMessage.Direction.TO_CLIENT], enforced on receipt
## against the [i]transport's[/i] view of the sender. Without it any client could send
## every other client a spawn, a death or a leaderboard.

const NAME := &"hungry.event"

## Bits the kind occupies. Thirty-two kinds is well past what this game will ever have,
## and the spare bits cost nothing next to the body.
const KIND_BITS := 5

## Largest body accepted. A full field resynchronisation is the biggest thing that
## travels and it is chunked to stay well under this; anything larger is a bug or a
## hostile server, and neither should be allocated for.
const MAX_BODY := 8192

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray) -> HungryEvent:
	var event := HungryEvent.new()
	event.kind = p_kind
	event.body = p_body
	return event


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= HungryEvents.Kind.size():
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown event kind %d." % kind
		)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "HungryEvent(%s, %d bytes)" % [
		HungryEvents.kind_name(kind), body.size()
	]
