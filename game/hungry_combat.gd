extends Node

const HungryContent := preload("hungry_content.gd")

## What a thrown item does to somebody, through dot-combat's rules rather than a constant.
##
## [b]Eating is deliberately NOT here, and that has not changed.[/b] This project's own
## notes say health and damage are the wrong model for being devoured — it is a mass ratio,
## not a hit-point total — and forcing it through [DotDamageResolver] would be a worse
## version of both. What *is* damage is a **throwable**: somebody aimed something at
## somebody else from a distance, and every question that raises is one dot-combat already
## answers.
##
## - **Self damage.** A pepper thrown at your own feet. Off by default here, because a
##   monster bursting itself is a legitimate move in this genre and a *scaled* self hit is
##   the wrong shape for it — so the rules say no and the world's own eject is how you
##   split on purpose.
## - **Falloff.** A pepper thrown from across the arena scatters somebody less than one
##   thrown at point blank. That is [member DotDamageType.falloff_start] and `falloff_end`,
##   and it turns a throwable from a hitscan into something with a range worth judging.
## - **Clamping**, and a floor. Below the minimum a hit is refused outright rather than
##   applied as nothing, so "it hit and did nothing" and "it missed" are one outcome
##   instead of two that look the same.
## - **A hook.** `DotDamageResolver.adjust` is where the rind fruit could live if a server
##   wanted it to reduce a burst rather than eat one, without touching the world.
##
## [b]The amount becomes a piece count, and that is the whole bridge.[/b] dot-combat's
## output is a number of hit points and this game has none; what it has is "how far this
## scatters you". `pieces_for` is the one function that maps the first onto the second, and
## it is here rather than in [HungryWorld] because it is a combat decision rather than a
## simulation one.

const CHANNEL := "hungry.combat"

## Damage a pepper does at point blank, in dot-combat's units.
##
## An arbitrary scale — there is no health in this game — chosen so the falloff curve has
## somewhere to fall to and `pieces_for` has a range to quantise. What matters is that it
## is one number in one place rather than a ratio hidden in an `if`.
const PEPPER_DAMAGE := 100.0

## The reach beyond which a throwable is doing its least.
const FALLOFF_START := 400.0
const FALLOFF_END := 2200.0


## Something landed on somebody. Server side; carries what the resolver decided.
signal landed(damage: DotDamage, pieces: int)


var resolver: DotDamageResolver = null
var rules: DotDamageRules = null

## item id -> [DotDamageType].
var _types: Dictionary = {}


## The damage types, one per throwable that does something to a person.
##
## [b]A resource per item rather than a `match`.[/b] An operator changing how far a pepper
## reaches edits a number; a `match` on an item id would make the same change a code
## change, and the two throwables that behave differently would drift apart.
static func damage_types() -> Dictionary:
	var out: Dictionary = {}

	var pepper := DotDamageType.make(&"pepper", "Pepper")
	pepper.falloff_start = FALLOFF_START
	pepper.falloff_end = FALLOFF_END
	# A third at maximum range rather than nothing: a throwable that did nothing at range
	# would be one nobody ever throws far, which removes the decision it exists for.
	pepper.falloff_floor = 0.34
	pepper.uses_hit_groups = false
	# There are no teams in this game, so `friendly_scale` is never reached — set
	# explicitly anyway, because a mode that adds teams should get the value somebody
	# chose rather than the one that happened to be the default.
	pepper.friendly_scale = 1.0
	pepper.self_scale = 0.0
	out[HungryContent.ITEM_PEPPER] = pepper

	# Frost does not scatter anybody; what it has is a range. Its damage is used only for
	# the falloff, and the world turns "did it land at all" into an effect.
	var frost := DotDamageType.make(&"frost", "Frost")
	frost.falloff_start = FALLOFF_START
	frost.falloff_end = FALLOFF_END
	frost.falloff_floor = 0.5
	frost.uses_hit_groups = false
	frost.self_scale = 0.0
	out[HungryContent.ITEM_FROST] = frost

	return out


## The server's policy on who may hurt whom.
static func damage_rules() -> DotDamageRules:
	var out := DotDamageRules.new()
	# Free-for-all: everybody is fair game and there are no teams for the resolver to
	# compare. Said explicitly rather than left, because a mode that adds teams changes
	# exactly this line.
	out.friendly_fire = true
	out.friendly_scale = 1.0
	# [b]Off.[/b] A monster bursting itself is a legitimate move and the world's own eject
	# is how you do it on purpose; a scaled self hit would be a second, worse way.
	out.self_damage = false
	out.hit_groups = false
	out.falloff = true
	# Below this, refused rather than applied as nothing — so "it hit and did nothing" and
	# "it missed" are one outcome instead of two that look identical to a player.
	out.minimum = PEPPER_DAMAGE * 0.3
	out.maximum = PEPPER_DAMAGE
	return out


func setup() -> DotResult:
	rules = damage_rules()
	_types = damage_types()

	resolver = DotDamageResolver.with_rules(rules)
	# No hit groups: a monster is a circle and has no head. Left null deliberately rather
	# than given an empty table, because an empty table would multiply by whatever its
	# default is and this way the resolver skips the stage.
	resolver.hit_groups = null

	return DotResult.success(null)


## What a throwable does to somebody, or a refusal.
##
## [b]Returns the [DotDamage] rather than acting.[/b] What "scattered" means is the
## world's, exactly as dot-timer never moves a player — and the same object carries why it
## was scaled, which is what makes a console able to explain a hit that did less than a
## player expected.
func resolve_throw(
	thrower_id: int, victim_id: int, item: StringName, distance: float
) -> DotDamage:
	var type: DotDamageType = _types.get(item)

	if type == null:
		return null

	var damage := DotDamage.make(thrower_id, victim_id, PEPPER_DAMAGE, type)
	damage.distance = distance
	damage.context["item"] = String(item)

	return resolver.resolve(damage)


## How many pieces a resolved amount scatters somebody into.
##
## [b]The one place hit points become a piece count.[/b] Linear between the refusal floor
## and the maximum, so a hit at the edge of usefulness still does something and a point
## blank one does the full amount — and it is clamped to at least two, because "burst into
## one piece" is not a burst and the world would refuse it anyway.
func pieces_for(damage: DotDamage) -> int:
	if damage == null or damage.refused:
		return 0

	var span := maxf(rules.maximum - rules.minimum, 0.001)
	var share := clampf((damage.amount - rules.minimum) / span, 0.0, 1.0)

	return maxi(2, int(round(2.0 + share * float(HungryContent.PEPPER_PIECES - 2))))


## The gate [HungryWorld] consults before a throwable does anything.
##
## Returns `{"allowed": bool, "pieces": int}`. A dictionary rather than two callables,
## because the two answers come out of one resolve and asking twice would resolve twice —
## which with a `scale_by` trace on the damage is not merely wasteful, it is two different
## objects with two different histories.
func gate(
	thrower_id: int, victim_id: int, item: StringName, distance: float
) -> Dictionary:
	var damage := resolve_throw(thrower_id, victim_id, item, distance)

	if damage == null:
		# An item this layer has no type for — the lure — is not combat and passes
		# through untouched. Refusing it here would silently disable a throwable by
		# installing an addon.
		return {"allowed": true, "pieces": 0}

	var pieces := pieces_for(damage)
	landed.emit(damage, pieces)

	return {"allowed": not damage.refused, "pieces": pieces}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("combat       %d damage types, %s" % [
		_types.size(), rules.describe() if rules != null else "no rules"
	])
	return out
