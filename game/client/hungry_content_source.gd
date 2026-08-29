class_name HungryContentSource
extends RefCounted

## Where an avatar part's scene comes from: the cloud if there is one, the build if not.
##
## [b]This is the seam [DotAvatarCatalogue.resolver] exists for.[/b] The catalogue's two
## built-in answers are "a path under a fixed prefix" and "ask dot-cloud", and this game is
## neither: it ships its cosmetics inside its own build [i]and[/i] can be handed a signed
## pack of better ones at runtime, and the mounted pack has to win when it is there.
##
## The order is deliberate:
##
## [codeblock]
## 1. a mounted dot-cloud pack   <- signed, hash-verified, versioned
## 2. res://content/avatars/     <- what shipped in the build
## 3. ""                         <- drawn by HungryRider instead
## [/codeblock]
##
## [b]Nothing here imports dot-cloud.[/b] The client is found through [DotRegistry] and
## duck-typed, so a build without the addon takes step 2 and never notices — which is what
## a LAN server, a test and the browser export all do today.
##
## [b]A part is never resolved to a path a server chose.[/b] The pack's mount prefix comes
## from the manifest dot-cloud has already verified, and the file name comes from the part
## id, which the avatar schema bounds to base64url characters. A server cannot make this
## return an arbitrary path; that is why the id is checked and the content id is not
## interpolated.

const CHANNEL := "hungry.content"

## Registry name dot-cloud publishes itself under.
const CLOUD_SERVICE := &"dot_cloud_client"

## The content this game's cosmetics live in.
const PACK_ID := "hungry_avatars"

## Where the build's own copies are.
const BUILTIN_PREFIX := "res://content/avatars/"

const SUFFIX := ".tscn"

## Mount prefix of the acquired pack, or "" when there is none.
##
## Set from [signal DotCloudClient.content_ready], which is the only thing that knows a
## pack is mounted and where.
var mount_prefix: String = ""

## part id -> resolved path. Cleared when a pack arrives, because a pack arriving is the
## one event that changes an answer already given.
var _cache: Dictionary = {}

var _cloud: Object = null
var _looked: bool = false


## Binds this as a catalogue's resolver and starts watching for content.
func install(catalogue: DotAvatarCatalogue) -> void:
	catalogue.resolver = resolve_part
	_watch_cloud(catalogue)


func _watch_cloud(catalogue: DotAvatarCatalogue) -> void:
	var cloud := _cloud_client()

	if cloud == null or not cloud.has_signal("content_ready"):
		return

	cloud.connect("content_ready", func(manifest: Variant, prefix: String) -> void:
		if manifest == null or String(manifest.get("content_id")) != PACK_ID:
			return

		adopt_mount(prefix)
		# The catalogue caches a resolution per part and this changes the answer for
		# every one of them. Not invalidating it means a pack that arrives mid-game is
		# never used, which is the whole point of it arriving.
		catalogue.invalidate()
	)


func _cloud_client() -> Object:
	if _looked:
		return _cloud

	_looked = true
	_cloud = DotRegistry.get_service(CLOUD_SERVICE)

	if _cloud != null:
		DotLog.debug(CHANNEL, "avatar parts will be resolved through dot-cloud")

	return _cloud


## Takes the mount prefix of an acquired pack.
##
## Public because the acquisition may have happened before this object existed — a client
## that downloaded the pack during signon, for instance — and because the content example
## drives it directly.
func adopt_mount(prefix: String) -> void:
	if prefix == "" or prefix == mount_prefix:
		return

	mount_prefix = prefix if prefix.ends_with("/") else prefix + "/"
	_cache.clear()

	DotLog.info(CHANNEL, "avatar content mounted", {"prefix": mount_prefix})


## Resolves one part to a scene path, or "" when there is nothing to show.
func resolve_part(part: DotAvatarPart) -> String:
	if part == null:
		return ""

	if _cache.has(part.id):
		return _cache[part.id]

	var path := _lookup(part)
	_cache[part.id] = path
	return path


func _lookup(part: DotAvatarPart) -> String:
	var name := String(part.id)

	# The id is bounded to base64url characters plus '.' by DotAvatar.validate, so it
	# cannot contain a separator — but this builds a path out of it and a check at the
	# point of use costs nothing. A part id that got here unvalidated is a content bug,
	# not a legal request.
	if name == "" or name.contains("/") or name.contains("\\") or name.contains(".."):
		DotLog.warn(CHANNEL, "refusing a part id that is not a plain name", {
			"id": name
		})
		return ""

	if mount_prefix != "":
		var mounted := "%s%s%s" % [mount_prefix, name, SUFFIX]

		if ResourceLoader.exists(mounted):
			return mounted

	var builtin := "%s%s%s" % [BUILTIN_PREFIX, name, SUFFIX]
	return builtin if ResourceLoader.exists(builtin) else ""


## Whether a part is coming from a downloaded pack rather than from the build.
func is_mounted(part: DotAvatarPart) -> bool:
	return mount_prefix != "" and resolve_part(part).begins_with(mount_prefix)


# --- Publishing ------------------------------------------------------------

## Where this game's cosmetics live in the build, and what a pack is built from.
const SOURCE_DIR := "res://content/avatars"

## Packages the avatar parts into a signed, content-addressed pack.
##
## [b]Here rather than in the tool that calls it[/b], because the content id, the mount
## root and the version are the three things a publisher and a client have to agree about,
## and a second copy of them is a pack that mounts somewhere the game does not look.
##
## [b]The pack is data. The code that draws it ships in the build.[/b] `part.gd` is
## excluded, and that is a constraint rather than a preference: a `.tscn` references its
## script by an [i]absolute[/i] `res://` path, and a pack's own path contains its version
## — `res://dot_cloud/hungry_avatars/1.0.0/`. A scene inside the pack therefore cannot
## name a script inside the same pack without being re-authored per version. So the parts
## are scenes with exported properties and the drawing lives in the game, which also means
## a pack published against a newer game degrades rather than breaks: an unknown
## [code]shape[/code] falls through to the default one.
##
## [b]Signing is still not optional.[/b] Not because this pack contains code — it
## deliberately does not — but because the manifest is the whole trust boundary: its
## hashes decide what counts as a valid download and its paths decide what gets mounted,
## and a Godot pack [i]can[/i] contain scripts. Per-file hashes do not help; they prove a
## file matches what the manifest said, and the manifest is the thing under attack.
static func publish(
	out_dir: String,
	signing_key_pem: String,
	version: String = "1.0.0",
	mirrors: PackedStringArray = PackedStringArray()
) -> DotResult:
	var publisher := DotCloudPublisher.new()
	publisher.content_id = PACK_ID
	publisher.version = version
	publisher.display_name = "hungry riders"
	publisher.signing_key_pem = signing_key_pem
	publisher.mirrors = mirrors
	# No entry scene: this is a bag of parts resolved by id, not a game to load. A client
	# that tried to instantiate a "hungry_avatars" entry point would be doing something
	# nothing here asks for.
	publisher.entry_scene = ""
	publisher.metadata = {
		"kind": "avatar_parts",
		"schema": String(HungryContent.avatar_schema().id),
	}

	# Scenes and nothing else. See the note above: a pack cannot reference a script inside
	# itself, so shipping one is dead weight that also makes the pack look like it carries
	# code when it does not.
	publisher.exclude_suffixes = PackedStringArray([
		".gd", ".gd.uid", ".import", ".tmp", ".DS_Store", "Thumbs.db",
	])

	return publisher.publish(SOURCE_DIR, out_dir)


func describe() -> Dictionary:
	return {
		"mount": mount_prefix,
		"cloud": _cloud != null,
		"cached": _cache.size(),
	}
