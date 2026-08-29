class_name HungryProjectile
extends RefCounted

## A thrown item in flight.
##
## [b]It is a straight line and a start tick, not a simulated body.[/b] Everything about
## where it is at any moment follows from (origin, direction, spawn tick), so a client
## that has been told a throw happened can draw the whole flight without another byte —
## which is the same trick the food field uses, applied to something that moves.
##
## The authority still owns the outcome. A client flies the projectile and never decides
## that it hit anybody: it removes one when an impact arrives, or when the flight has run
## past [constant HungryContent.THROW_RANGE] and no impact ever will.

## Unique within the world. Goes on the wire.
var id: int = 0

## Which player threw it, for attribution and so it cannot hit them.
var thrower_id: int = 0

## Which throwable this is. An id from [method HungryContent.item_catalogue].
var item: StringName = &""

var origin: Vector2 = Vector2.ZERO

## Unit length.
var direction: Vector2 = Vector2.RIGHT

var spawn_tick: int = 0

## Set on the authority when it lands, so the same projectile is not resolved twice.
var resolved: bool = false


static func make(
	p_id: int,
	p_thrower: int,
	p_item: StringName,
	p_origin: Vector2,
	p_direction: Vector2,
	tick: int
) -> HungryProjectile:
	var shot := HungryProjectile.new()
	shot.id = p_id
	shot.thrower_id = p_thrower
	shot.item = p_item
	shot.origin = p_origin
	# A zero direction is a projectile that sits on the thrower for ever. It cannot
	# arrive here — Dot2DCommand.sanitise normalises or zeroes the aim, and the throw is
	# refused on a zero aim — but the fallback costs nothing and the failure would be
	# very confusing.
	shot.direction = p_direction.normalized() if p_direction.length_squared() > 0.000001 \
		else Vector2.RIGHT
	shot.spawn_tick = tick
	return shot


## How far it has travelled by [param tick].
func distance_at(tick: int, tick_rate: int) -> float:
	var elapsed := maxi(0, tick - spawn_tick)
	return HungryContent.THROW_SPEED * float(elapsed) / float(maxi(1, tick_rate))


func position_at(tick: int, tick_rate: int) -> Vector2:
	return origin + direction * distance_at(tick, tick_rate)


func expired(tick: int, tick_rate: int) -> bool:
	return distance_at(tick, tick_rate) >= HungryContent.THROW_RANGE


func describe() -> Dictionary:
	return {
		"id": id,
		"thrower": thrower_id,
		"item": String(item),
		"origin": origin,
		"direction": direction,
		"spawn_tick": spawn_tick,
	}


func _to_string() -> String:
	return "HungryProjectile(#%d %s from %d)" % [id, item, thrower_id]
