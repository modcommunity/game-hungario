@tool
class_name HungryRules
extends DotMatchRules

## A round ends when someone gets big enough, or when the clock runs out.
##
## [b]dot-match's own score limit counts kills, and this game is not scored in
## kills.[/b] A player who eats six hundred crumbs and never touches anybody is winning;
## a player with four kills and no mass is not. Overriding [method _round_outcome] is the
## documented seam for exactly this, and it is four lines.
##
## The mass itself comes from a [Callable] rather than from a lookup, because dot-match
## does not know what a monster is and must not have to.

## Mass that ends the round.
@export_range(10.0, 1000000.0, 10.0) var mass_to_win: float = HungryContent.WIN_MASS

## `func(key: String) -> float`. How much mass that player controls, across every piece.
##
## Left unset the ruleset falls back to its parent's kills-and-clock rule, which is
## wrong for this game but is at least a round that ends — and the warning says so on
## the first round played rather than never.
var mass_fn: Callable = Callable()


func _round_outcome(
	scoreboard: DotScoreboard,
	teams: DotTeamManager,
	elapsed_sec: float
) -> Outcome:
	if time_limit_sec > 0.0 and elapsed_sec >= time_limit_sec:
		return Outcome.TIME

	if not mass_fn.is_valid():
		DotLog.warn(
			"hungry.rules",
			"no mass_fn; falling back to kills and the clock, which is not this game"
		)
		return super._round_outcome(scoreboard, teams, elapsed_sec)

	for record in scoreboard.present_players():
		if float(mass_fn.call(record.key)) >= mass_to_win:
			return Outcome.SCORE

	return Outcome.NONE


func validate() -> DotResult:
	if mass_to_win <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "A mass target of zero ends the round instantly."
		)

	return super.validate()
