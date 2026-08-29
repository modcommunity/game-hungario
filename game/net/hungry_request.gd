class_name HungryRequest
extends DotNetMessage

## Everything a client asks the authority for that is not an input.
##
## Two kinds today: "I have loaded, tell me about the world" and "here is my avatar".
## Both are rare, both are reliable, and both are refused if they arrive from the wrong
## direction — [constant DotNetMessage.Direction.TO_SERVER] is checked against the
## transport's view of the sender rather than against anything inside the payload.
##
## [b]The body is bounded before it is allocated.[/b] An avatar document is the one thing
## in this protocol a client composes freely, and a length prefix claiming four billion
## bytes is the obvious thing to send.

const NAME := &"hungry.request"

const KIND_BITS := 4

## An avatar is a couple of dozen bytes. This is two orders of magnitude of headroom and
## still far below anything worth worrying about.
const MAX_BODY := 1024

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray) -> HungryRequest:
	var ask := HungryRequest.new()
	ask.kind = p_kind
	ask.body = p_body
	return ask


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= HungryEvents.Ask.size():
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown request kind %d." % kind
		)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "HungryRequest(%d, %d bytes)" % [kind, body.size()]
