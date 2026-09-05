@tool
class_name HungryConfig
extends DotConfig

## What a player can change, and where it is kept.
##
## [b]A `DotConfig`, which is the whole reason the settings screen has no layout code.[/b]
## [DotSettingsPanel] reads the `@export` annotations below — the type, the range, the
## group, the hint — and builds the editors from them. Adding a setting here adds a row
## there and nothing else changes, and the screen cannot drift from the settings it is
## supposed to show because it never restates one.
##
## It layers the same way everything in this family does:
## [code]exported defaults < JSON file < environment < command line[/code]. Nothing here
## is a secret, so nothing is refused from the environment — see
## [method DotConfig.sensitive_keys] for the rule and [DotAuthConfig] for a config that
## has one.

## Where a player's own settings live.
const PATH := "user://cfg/hungry.json"

@export_group("Sound")

## Volume of every generated voice, in decibels.
##
## A game whose sound cannot be turned down is a game people play muted, and a game they
## play muted is one whose audio work was wasted.
@export_range(-60.0, 6.0, 1.0) var volume_db: float = -8.0

@export var muted: bool = false

@export_group("Camera")

## Seconds the camera takes to catch up with the monster. Zero snaps.
##
## Worth exposing rather than fixing: a player who finds the lag nauseating and a player
## who finds a snapped camera jarring are both right, and neither can be argued out of it.
@export_range(0.0, 0.5, 0.01) var follow_sec: float = 0.10

## Zoom out as the monster grows.
##
## Off is a legitimate preference and a legitimate advantage — a fixed zoom sees less and
## reacts faster — which is why it is a setting rather than a debug flag.
@export var zoom_with_size: bool = true

@export_group("Interface")

@export var show_minimap: bool = true

## Draw everybody's name above their monster.
##
## Off is quieter and, in a crowd, considerably more readable.
@export var show_names: bool = true

## Ring every monster by whether you could eat it, or it you.
##
## The one readability affordance this genre cannot do without: eating needs a *ratio*,
## not merely being bigger, and judging a quarter of a difference in area by eye is
## something nobody does reliably under pressure. Off for anybody who would rather learn
## to.
@export var show_threat: bool = true

## Lines the feed keeps on screen at once. Zero turns it off.
@export_range(0, 20, 1) var feed_lines: int = 8


func env_prefix() -> String:
	return "HUNGRY_"


func cli_prefix() -> String:
	return "--hungry-"


func validate() -> DotResult:
	if follow_sec < 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "A camera cannot catch up in negative time."
		)

	return DotResult.success(null)


## Loads a player's settings, falling back to the defaults above.
##
## A missing file is the normal case — it is what a first run looks like — so it is not an
## error. A malformed one is: silently starting from defaults would throw away everything
## a player had set with nothing on screen to say so.
static func load_saved(path: String = PATH) -> HungryConfig:
	var config := HungryConfig.new()

	if not FileAccess.file_exists(path):
		return config

	var loaded := config.load_layered(path)

	if not loaded.ok:
		DotLog.warn("hungry.config", "could not read the settings; using defaults", {
			"path": path, "error": str(loaded.error)
		})
		return HungryConfig.new()

	return config


## Writes a player's settings back.
##
## On the web this goes through `user://`, which is an IndexedDB mirror that needs an
## explicit flush — [method DotPaths.write_text] does it, which is why this goes through
## [method DotConfig.save_json_file] rather than a [FileAccess] of its own.
func save(path: String = PATH) -> DotResult:
	return save_json_file(path)


func describe_summary() -> String:
	return "%s, camera %.2fs%s" % [
		"muted" if muted else "%.0f dB" % volume_db,
		follow_sec,
		"" if zoom_with_size else ", fixed zoom",
	]
