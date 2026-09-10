class_name HungryMaps
extends Node

## What plays next, and who decides.
##
## [b]The three modes are the maps.[/b] `classic`, `frenzy` and `gauntlet` are already
## `DotGameDescriptor`s that dot-server switches between with `changegame`; dot-map's
## catalogue says what they *are* — a kind, a player range, a description a ballot can show
## — and its rotation says which one comes round next with a cooldown so the same one does
## not play twice in a row. dot-vote is what lets the players override it.
##
## [b]The swap itself stays dot-server's, and this file does not do it.[/b] That is the
## same refusal game-simple-lobby makes about chat and for exactly the same reason: dot-map
## ships `DotMapSyncHost`, which announces a change, waits for every peer to have the
## content and then swaps — and dot-server's `change_game` already announces, waits and
## swaps, with a content sync this family spent nine bugs getting right. Running both would
## be two protocols doing one job, and the one that was wrong would be the one nobody was
## watching. `DotVoteGameSource` applies through the game manager, which is the path that
## already works.
##
## [b]What is genuinely new here is the time limit and rock-the-vote.[/b] Neither existed
## in this game: a round ended on a mass target or a clock inside `DotMatch`, and there was
## no way at all for the players to say "we have had enough of this one".

const CHANNEL := "hungry.maps"


## The vote picked something and the server should change to it.
signal change_due(game_id: StringName)

## Something a player should be told: the ballot, the tally, a warning.
signal announced(line: String)


var catalogue: DotMapCatalogue = null
var rotation: DotMapRotation = null
var director: DotVoteDirector = null
var limit: DotMapTimeLimit = null

## dot-server's game manager, which is what a vote actually applies through.
var games: Object = null

## How many people are playing. Set by [HungryModule]; a vote's every threshold needs it.
var player_count_fn: Callable = Callable()

## Whether a voter is an admin.
var is_admin_fn: Callable = Callable()


# --- The catalogue ---------------------------------------------------------

## The three modes, as maps.
##
## [b]`min_players` is the field that matters and it is the one a ballot uses.[/b]
## `gauntlet` is a corridor: two people in it is a chase and eight is a scrum, so it is off
## the ballot below three — which is `available_for`, and is why a catalogue is worth
## having over a hard-coded list.
static func map_catalogue() -> DotMapCatalogue:
	var out := DotMapCatalogue.new()

	# [b]Built FROM the game descriptors rather than beside them.[/b] The scene path, the
	# display name and the id are already declared once, in
	# [method HungryModule.game_descriptors] — which is what dot-server instantiates. A map
	# catalogue that restated them would be a second copy, and the copy that goes stale is
	# always the one nothing reads: this tree's most repeated bug is two copies of one
	# list, and it has now happened to `setup.sh`, `tools/check.sh`,
	# `tools/package_check.sh` and `bootstrap`.
	#
	# What is genuinely new here is `min_players`, which nothing else records — a
	# `DotGameDescriptor` has a maximum and not a minimum, and "this mode needs three
	# people" is exactly what a ballot has to know.
	for descriptor in HungryModule.game_descriptors():
		var added := out.add(_map(descriptor, int(MINIMUMS.get(descriptor.game_id, 1))))

		if not added.ok:
			# [b]Loud, because a catalogue that silently holds nothing is the exact shape
			# this family keeps finding.[/b] `DotMapCatalogue.add` validates and refuses,
			# and the first version of this function produced an empty catalogue with no
			# error anywhere — every map refused for having no scene path, and a vote with
			# nothing on the ballot that looked like a vote nobody wanted to use.
			DotLog.error(CHANNEL, "a mode was refused by the map catalogue", {
				"game": descriptor.game_id, "why": added.error.message,
			})

	return out


## How many people a mode needs before it is worth offering.
##
## [b]`gauntlet` is a corridor and two people in it is a chase.[/b] It is off the ballot
## below three, which is `available_for`, and is the one thing this catalogue knows that
## dot-server's descriptors do not.
const MINIMUMS := {
	"hungry_gauntlet": 3,
}


static func _map(descriptor: DotGameDescriptor, min_players: int) -> DotMapDef:
	var out := DotMapDef.new()
	out.id = StringName(descriptor.game_id)
	out.display_name = descriptor.display_name
	# [b]A semantic version or a default, because `validate()` refuses anything else.[/b]
	# A `DotGameDescriptor`'s version is a free string — dot-server never parses it — and
	# handing an unparseable one straight through is a map refused for a field nobody
	# meant to fill in.
	out.version = descriptor.version if DotSemVer.parse(descriptor.version).valid \
		else "1.0.0"
	out.kind = DotMapDef.KIND_ARENA
	out.min_players = min_players
	out.max_players = descriptor.max_players
	# The same scene dot-server loads, read from the same declaration.
	#
	# [b]Nothing here ever loads it, and it is set anyway.[/b] `DotMapDef.validate()`
	# refuses a map with no scene — correctly, because a map nothing can load is not a map
	# — and a catalogue whose entries are all refused is a catalogue that silently holds
	# nothing. That is precisely the shape this family keeps finding: a list that is empty
	# for a good reason, and nothing saying so.
	out.scene_path = descriptor.scene
	out.meta = {"vote": {"display": descriptor.display_name}}
	return out


## The vote's policy. Fifty-five settings and these are the ones this game changes.
static func vote_rules() -> DotVoteRules:
	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	# A mode is fifteen minutes rather than half an hour. A round here is a few minutes;
	# a map limit that outlasted five of them would be a limit nobody ever saw fire.
	rules.duration_sec = 900.0
	rules.vote_lead_sec = 90.0
	rules.vote_cooldown_sec = 60.0
	rules.vote_duration_sec = 25.0
	# Three modes, so a ballot of six would be a ballot of three and three blanks.
	rules.max_options = 4
	rules.include_extend = true
	rules.include_current = false
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.BALLOT_ORDER
	# [b]Off, and this is the setting dot-vote found a bug in.[/b] With it on, "extend" is
	# erased from a tie and the tie goes to the new thing; with it off the ordinary
	# tie-break runs — and every pseudo-option sorts last in ballot order, so
	# `BALLOT_ORDER` hands the tie to the new thing as well. Two documented policies, one
	# behaviour. It is set explicitly here so somebody changing it is changing something.
	rules.extend_needs_majority = false
	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 2
	# [b]Measured against elapsed time, which is the other bug dot-vote found.[/b]
	# `DotVoteClock.running` used to mean "has a limit" rather than "has started", so a
	# server with no time limit never accumulated elapsed time and rocking the vote was
	# refused for ever — on exactly the deployment whose only way to change anything is
	# the vote. Two minutes here is short enough that a mode nobody likes can be left.
	rules.rtv_delay_sec = 120.0
	rules.nominations_enabled = true
	rules.nominations_per_player = 1
	# [b]On, and it is the setting that makes `MOST_NOMINATED` mean anything.[/b] dot-vote
	# refused a second player nominating what somebody had already nominated, so every
	# count was exactly 1 and there was nothing to sort by. It is allowed now and is
	# itself a setting; with three modes it is also the only way a ballot can show which
	# one people actually want.
	rules.nomination_seconding = true
	rules.cooldown = 1
	rules.cooldown_mode = DotVoteRules.Cooldown.PLAYS
	rules.apply = DotVoteRules.Apply.END_OF_ROUND
	rules.apply_delay_sec = 5.0
	return rules


# --- Lifecycle -------------------------------------------------------------

func setup(p_games: Object) -> DotResult:
	games = p_games

	catalogue = map_catalogue()
	rotation = DotMapRotation.of(catalogue)
	rotation.mode = DotMapRotation.Mode.SEQUENTIAL
	# One play of cooldown over three maps: enough that the same mode never plays twice in
	# a row, and not so much that a two-mode server runs out of things to pick.
	rotation.cooldown = 1

	var rules := vote_rules()
	var problem := rules.validate()

	if not problem.ok:
		return problem.wrap("The vote rules are not usable")

	director = DotVoteDirector.new()
	director.name = "Vote"
	director.rules = rules
	# [b]The source is dot-server's games, not dot-map's catalogue.[/b] What a vote applies
	# has to be the thing that actually changes the game, and `DotVoteGameSource.apply`
	# calls `change_game`. The map catalogue is what says a mode needs three players; the
	# game source is what makes a decision happen.
	director.source = DotVoteGameSource.of(games)
	director.auto_apply = true
	# [b]Off, and this is dot-vote's fifth bug.[/b] With it on the director announces the
	# change it just made *and* the host announces the same change through its own
	# `game_loaded` — which fires for an operator typing `changegame` too, and is therefore
	# the signal that has to be connected. Both firing is two entries in the play history
	# for one play, and a "played in the last N" cooldown that is quietly half what it says.
	director.begin_on_apply = false
	director.self_advance = true
	director.register_service = false
	director.player_count_fn = _player_count
	director.is_admin_fn = _is_admin
	director.announce_fn = func(line: String) -> void: announced.emit(line)
	add_child(director)

	director.change_due.connect(func(id: StringName, _choice: DotVoteChoice) -> void:
		change_due.emit(id)
	)

	# The time limit is dot-map's, and it is the half dot-vote does not have: dot-vote
	# knows when a vote is due and dot-map knows how long a map has left, which is what a
	# `timeleft` command answers and what a warning counts down.
	limit = DotMapTimeLimit.of(rules.duration_sec)
	# [b]One warning mark, not dot-vote's list.[/b] `DotVoteRules.warn_marks()` is what
	# the vote announces at; `DotMapTimeLimit.warn_at` is a single number, and giving it
	# the first of the vote's marks is the honest mapping rather than pretending the two
	# agree about a shape they do not share.
	var marks := rules.warn_marks()
	limit.warn_at = marks[0] if not marks.is_empty() else 120.0
	limit.rtv_fraction = rules.rtv_fraction
	limit.rtv_min_players = rules.rtv_min_players
	limit.extend_seconds = rules.extend_seconds
	limit.max_extends = rules.max_extends

	return DotResult.success(null)


## Somebody is playing something. Both the rotation and the vote are told.
##
## [b]One call, from the one signal that fires for every change however it happened.[/b]
## An operator typing `changegame`, a vote applying and a rotation advancing all end here,
## which is what stops the play history counting one play twice — dot-vote's own fifth bug.
func note_playing(game_id: StringName) -> void:
	if rotation != null:
		rotation.note_played(game_id)

	if director != null:
		director.begin(game_id)

	if limit != null:
		limit.start()


func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)

	if limit != null:
		limit.advance(delta)


## What would play next with nobody voting.
func next_in_rotation() -> StringName:
	if director != null:
		var voted := director.next_in_rotation()

		if voted != &"":
			return voted

	var chosen := rotation.choose(_player_count()) if rotation != null else null
	return chosen.id if chosen != null else &""


## Whether a mode may be offered at the current head count.
func available(game_id: StringName) -> bool:
	var map := catalogue.get_map(game_id) if catalogue != null else null
	return map == null or map.available_for(_player_count())


func _player_count() -> int:
	return int(player_count_fn.call()) if player_count_fn.is_valid() else 0


func _is_admin(voter: StringName) -> bool:
	return bool(is_admin_fn.call(voter)) if is_admin_fn.is_valid() else false


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if limit != null:
		out.append("map time     %s" % limit.formatted_remaining())

	if director != null:
		out.append_array(director.describe_lines())

	return out
