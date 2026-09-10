class_name HungryProgress
extends Node

## Boards and achievements over the numbers this game already counts.
##
## [b]Neither addon is given a new source of truth, and that is the whole design.[/b]
## [HungryModule] already declares a [DotStatsSchema] and records against it —
## `food`, `fruit`, `kills`, `deaths`, `mass_eaten`, `top_mass`. dot-achievements takes
## those readings through [DotAchievementStatsLink], which is a signal connection and
## nothing else; dot-leaderboard takes the ones worth ordering people by. A second count of
## how much food somebody ate would be a second number that can disagree with the first,
## and the one that is wrong is always the one nobody is looking at.
##
## [b]The merge rule is deliberately the same four kinds in both places.[/b]
## `DotAchievementRule.Merge` is dot-stats' set again — dot-achievements' own CLAUDE.md
## says so and says why: the two would otherwise disagree about what a new reading does to
## an old one, and that disagreement is a wrong number with nothing failing.
##
## [b]The player key is the scoped pseudonymous one, never an account id.[/b] That is
## dot-user's whole design and dot-stats refuses an account id as a player key before it
## leaves the server. A board is exactly the same kind of record.

const CHANNEL := "hungry.progress"

## Where progress is written. A directory per player, which is
## [DotAchievementStoreFile]'s shape.
const PROGRESS_DIR := "user://hungry_achievements"


## Somebody earned something. Server side; the module tells everybody.
signal earned(player_key: String, id: StringName, title: String, points: int)


var boards: DotLeaderboardManager = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## The stats tracker to take readings from. Set before [method setup].
var stats: DotStatsTracker = null

## The backbone, when an operator has configured one. Null on a LAN server.
var backbone: Object = null

## Where achievement progress is written. Overridable so a test does not touch a real one.
var progress_dir: String = PROGRESS_DIR

## What mode is being played, so a board is scoped to it.
##
## [b]Scoped, because a top mass in Frenzy and a top mass in Classic are not the same
## number.[/b] Frenzy's arena is smaller and its food denser; one board over both would be
## a board of who played Frenzy. [method DotLeaderboardDef.scoped] is the call, and it
## round-trips through a dictionary — which is where dot-leaderboard found that
## `to_dictionary()` handed out its own dictionary and every scoped board on a server ended
## up sharing one object.
var mode_id: StringName = &"classic"


# --- The boards ------------------------------------------------------------

## The three orderings worth keeping, as definitions rather than as code.
static func board_defs() -> Array[DotLeaderboardDef]:
	var out: Array[DotLeaderboardDef] = []

	var biggest := DotLeaderboardDef.make(&"top_mass", DotLeaderboardDef.Kind.SCORE)
	biggest.display_name = "Biggest monster"
	biggest.description = "The most mass anybody has ever held in one round."
	biggest.decimals = 0
	biggest.unit = " mass"
	# [b]`publish` is off, and that is not an oversight.[/b] Nothing in this family has
	# ever sent a leaderboard to the backbone, and a board that quietly queued submissions
	# nobody had configured a token for would be a queue that fills up. An operator turns
	# it on with the rest of the reporting.
	biggest.publish = false
	out.append(biggest)

	var devoured := DotLeaderboardDef.make(&"pieces_eaten", DotLeaderboardDef.Kind.SCORE)
	devoured.display_name = "Most devoured"
	devoured.description = "Pieces swallowed, all time."
	devoured.decimals = 0
	devoured.publish = false
	out.append(devoured)

	# A PENALTY board, so the "lower is better" half of `beats()` is exercised rather than
	# only described. Deaths in a round is the only figure here where less is better, and
	# a board that only ever sorted one way would have half of the comparison unrun.
	var survivor := DotLeaderboardDef.make(
		&"fewest_deaths", DotLeaderboardDef.Kind.PENALTY
	)
	survivor.display_name = "Hardest to eat"
	survivor.description = "Deaths in a round. Fewer is better."
	survivor.decimals = 0
	survivor.publish = false
	out.append(survivor)

	return out


# --- The achievements ------------------------------------------------------

## What a player can earn, as a document rather than as code.
##
## [b]Rules over per-player numbers, and every stat named here is one the game already
## records.[/b] An achievement watching a stat nothing reports is the family's most
## repeated bug wearing a rosette: it never unlocks, nothing errors, and the only symptom
## is a player who did the thing and was not told.
static func catalogue() -> DotAchievementCatalogue:
	var out := DotAchievementCatalogue.new()
	var made: Array[DotAchievement] = []

	# A tier series. The same stat at three thresholds, which is what `series` and `tier`
	# are for — three separate achievements would each have to be kept in step by hand.
	made.append(_counter(
		&"eat_100", "Peckish", "Eat 100 pieces of food.", &"food", 100.0, 10, &"appetite", 1
	))
	made.append(_counter(
		&"eat_1000", "Ravenous", "Eat 1000 pieces of food.", &"food", 1000.0, 25,
		&"appetite", 2
	))
	made.append(_counter(
		&"eat_10000", "Insatiable", "Eat 10000 pieces of food.", &"food", 10000.0, 50,
		&"appetite", 3
	))

	made.append(_counter(
		&"first_kill", "First bite", "Devour somebody.", &"kills", 1.0, 10, &"", 0
	))
	made.append(_counter(
		&"kill_50", "Apex", "Devour fifty players.", &"kills", 50.0, 30, &"", 0
	))
	made.append(_counter(
		&"fruit_25", "Orchard", "Eat twenty-five rare fruit.", &"fruit", 25.0, 20, &"", 0
	))

	# A BEST rather than a COUNTER. `top_mass` is the biggest reading ever seen rather
	# than a running total, and an achievement that summed it would unlock for somebody
	# who was medium-sized often.
	var titan := DotAchievement.make(
		&"mass_5000", "Titan",
		[_rule(&"top_mass", 5000.0, DotAchievementRule.Merge.HIGHEST)]
	)
	titan.description = "Hold five thousand mass at once."
	titan.points = 40
	made.append(titan)

	# Secret: earned by being eaten by a hunter, which is a thing a player will do before
	# they know hunters exist. Secret rather than hidden, because the difference is
	# whether the *name* is shown before it is earned and this one is a joke that only
	# works afterwards.
	var snack := DotAchievement.make(
		&"hunted", "Snack", [_rule(&"hunted", 1.0, DotAchievementRule.Merge.SUM)]
	)
	snack.description = "The arena eats back."
	snack.points = 15
	snack.secret = true
	made.append(snack)

	out.achievements = made
	return out


static func _counter(
	id: StringName,
	name: String,
	description: String,
	stat: StringName,
	target: float,
	points: int,
	series: StringName,
	tier: int
) -> DotAchievement:
	var out := DotAchievement.make(
		id, name, [_rule(stat, target, DotAchievementRule.Merge.SUM)]
	)
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


static func _rule(
	stat: StringName, target: float, merge: DotAchievementRule.Merge
) -> DotAchievementRule:
	return DotAchievementRule.make(
		stat, target, DotAchievementRule.Op.AT_LEAST, merge
	)


# --- Lifecycle -------------------------------------------------------------

func setup() -> DotResult:
	if stats == null:
		return DotResult.fail(
			DotError.CODE_STATE, "Progress needs a stats tracker to take readings from."
		)

	var boarded := _build_boards()

	if not boarded.ok:
		return boarded

	return _build_achievements()


func _build_boards() -> DotResult:
	boards = DotLeaderboardManager.new()
	boards.name = "Boards"
	boards.report_to_backbone = backbone != null
	add_child(boards)

	if backbone != null:
		boards.reporter.client = backbone

	for board in board_defs():
		var defined := boards.define(board)

		if not defined.ok:
			return defined.wrap("A board was refused")

	return DotResult.success(null)


func _build_achievements() -> DotResult:
	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.catalogue_file = ""
	achievements.store = DotAchievementStoreFile.new(progress_dir)
	achievements.report_to_backbone = backbone != null
	add_child(achievements)

	var started := achievements.start()

	if not started.ok:
		return started.wrap("The achievement tracker could not start")

	achievements.unlocked.connect(_on_unlocked)

	# [b]The link is the whole integration and it is a signal connection.[/b]
	# dot-achievements' own CLAUDE.md says the numbers should come from somewhere that
	# already has them, and dot-stats already does. A tracker fed by hand from twenty call
	# sites is twenty places to forget one.
	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	return link.start().wrap("The achievement stats link could not start")


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	earned.emit(player, achievement.id, achievement.display_name, achievement.points)


# --- Filing ----------------------------------------------------------------

## Starts counting for somebody. Called when they are admitted.
func begin(player_key: String) -> void:
	if achievements != null and player_key != "":
		achievements.begin(player_key)


## Stops, and writes. Called when they leave.
func end(player_key: String) -> void:
	if achievements != null and player_key != "":
		achievements.end(player_key)


## Files what a round was worth, on all three boards.
##
## [b]Submitted per round rather than per event.[/b] A board is an ordering over one number
## per player, and submitting on every bite would be a write per bite for a value that only
## matters at the end. `beats()` is what decides whether it replaces the incumbent, which
## is why a worse round does not overwrite a better one.
func file_round(player_key: String, monster: HungryMonster, deaths: int) -> void:
	if boards == null or player_key == "" or monster == null:
		return

	var key := StringName(player_key)

	_submit(&"top_mass", key, monster.best_mass, monster.display_name)
	_submit(&"pieces_eaten", key, float(monster.players_eaten), monster.display_name)
	_submit(&"fewest_deaths", key, float(deaths), monster.display_name)


func _submit(board_id: StringName, key: StringName, value: float, name: String) -> void:
	boards.submit(board_id, {"mode": String(mode_id)}, key, name, value)


## Everything on one board, best first.
func page(board_id: StringName, count: int = 10) -> Array:
	if boards == null:
		return []

	var got := boards.page(board_id, {"mode": String(mode_id)}, 0, count)
	return got.value if got.ok else []


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if boards != null:
		out.append_array(boards.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
