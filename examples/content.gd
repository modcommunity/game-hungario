extends Node

## Publishes this game's avatar parts, downloads them back, mounts them, and dresses a
## rider out of them.
##
## [codeblock]
## godot --headless --path . res://examples/content.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]This is the "through the cloud" half of the avatar.[/b] Everywhere else in this
## project a rider's parts come out of the build, which is the fallback; here they are
## signed, hashed, fetched, verified and mounted at a version-namespaced path, and the
## same [DotAvatarCatalogue] the renderer uses prefers them over what shipped.
##
## The negative checks are the point of the file. A signature routine that always returned
## true, or a client that mounted whatever it was sent, would pass every positive check
## here — and a Godot pack can contain scripts, so that is not a content bug, it is remote
## code execution. This pack does contain one: `content/avatars/part.gd`.

const WORK := "user://hungry_content_test"
const VERSION := "1.0.0"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _client: DotCloudClient = null
var _keys: Dictionary = {}
var _manifest: DotCloudManifest = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario: avatar content, through the cloud")
	print("")

	DotPaths.remove_tree(WORK)

	if await _test_publish():
		_test_signature()

		if await _test_acquire():
			_test_mount()
			_test_resolution()
			_test_rider()

		_test_refusals()

	_teardown()
	DotPaths.remove_tree(WORK)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section aborts that
## function and nothing says so: the checks that already ran still print ok, the ones
## after it never happen, and the total at the bottom cannot reveal a check that never
## ran. dot-net's demo carries the same pair, reached from the other direction — there it
## was a suspending section called without `await`.
var _entered := 0
var _completed := 0


## Opens a section. Pair with [method _done] on every path out of it.
func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s - %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _teardown() -> void:
	if _client != null and is_instance_valid(_client):
		remove_child(_client)
		_client.queue_free()


func _publish_dir() -> String:
	return WORK.path_join("published").path_join(HungryContentSource.PACK_ID)


# --- Publishing ------------------------------------------------------------

func _test_publish() -> bool:
	_section("publishing")

	var pair := DotCloudSignature.generate_keypair(2048)

	if not _check(pair.ok, "a signing keypair is generated", str(pair.error)):
		_done()
		return false

	_keys = pair.value

	var published := HungryContentSource.publish(
		_publish_dir(), str(_keys["private"]), VERSION
	)

	if not _check(published.ok, "the parts publish", str(published.error)):
		_done()
		return false

	var result: Dictionary = published.value

	# Seven scenes and nothing else. The script that draws them stays in the build: a
	# .tscn names its script by an absolute path and a pack's path carries its version, so
	# a scene inside a pack cannot reference a script inside the same pack.
	_check(
		int(result["files"]) == 7,
		"seven parts went in, and no code (%d files)" % int(result["files"])
	)
	_check(bool(result["signed"]), "and the manifest is signed anyway")

	# Signing is about the manifest, not about what happens to be in this pack. Its hashes
	# decide what counts as a valid download and its paths decide what gets mounted, and a
	# Godot pack *can* contain scripts — so a client that mounted content from an unsigned
	# manifest would run whatever it was sent.

	var bytes := DotPaths.read_bytes(str(result["manifest_path"]))

	if not _check(bytes.ok, "the manifest is on disk", str(bytes.error)):
		_done()
		return false

	var parsed := DotCloudManifest.from_json_bytes(bytes.value)

	if not _check(parsed.ok, "and parses", str(parsed.error)):
		_done()
		return false

	_manifest = parsed.value

	var scripts := 0

	for file in _manifest.files:
		if String(file.path).ends_with(".gd"):
			scripts += 1

	_check(scripts == 0, "the pack carries no code (%d scripts)" % scripts)

	_check(
		_manifest.content_id == HungryContentSource.PACK_ID,
		"naming the pack this game looks for (%s)" % _manifest.content_id
	)
	_check(
		_manifest.mount_prefix().trim_suffix("/") == "res://dot_cloud/%s/%s" % [
			HungryContentSource.PACK_ID, VERSION
		],
		"and mounting where the version puts it (%s)" % _manifest.mount_prefix()
	)

	# The version is in the path, which is the whole reason a game change is safe: a
	# mounted pack can never be unmounted, so two versions must not overlap.
	_check(
		_manifest.mount_prefix().contains(VERSION),
		"with the version in the path, so a second one cannot shadow it"
	)

	_done()
	return true


func _test_signature() -> void:
	_section("the signature")

	var good := DotCloudSignature.verify(
		_manifest.raw_bytes, _manifest.signature, str(_keys["public"])
	)
	_check(good.ok, "verifies against the public key", str(good.error))

	# Without this, a routine that always returned true would pass everything else here.
	var tampered := _manifest.raw_bytes.duplicate()
	tampered[tampered.size() - 2] = 0x20

	_check(
		not DotCloudSignature.verify(
			tampered, _manifest.signature, str(_keys["public"])
		).ok,
		"and a tampered manifest is refused"
	)

	# A different key is the realistic attack: somebody else's perfectly valid signature.
	var other := DotCloudSignature.generate_keypair(2048)

	if other.ok:
		_check(
			not DotCloudSignature.verify(
				_manifest.raw_bytes, _manifest.signature, str((other.value)["public"])
			).ok,
			"and so is a valid signature from the wrong key"
		)

	# The signature is over the bytes as received, never a re-serialisation. dot-cloud
	# signed a canonical re-serialisation once and wrote a pretty-printed file, so every
	# signature it produced failed to verify.
	_check(
		_manifest.raw_bytes.size() > 0,
		"and the manifest kept the bytes it was verified as (%d)"
			% _manifest.raw_bytes.size()
	)


# --- Acquiring -------------------------------------------------------------
	_done()

func _test_acquire() -> bool:
	_section("acquiring")

	var config := DotCloudConfig.new()
	config.cache_dir = WORK.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = {"default": str(_keys["public"])}
	config.verify_before_mount = true

	_client = DotCloudClient.new()
	_client.name = "Cloud"
	_client.config = config
	# Empty, or start() layers a stale file over the settings above.
	_client.config_file = ""
	# On disk rather than over HTTP: what is being tested is the pack, not the transport,
	# and dot-cloud's own suite covers HTTP and the in-band channel.
	_client.local_search_dirs = PackedStringArray([_publish_dir()])
	_client.allow_netchan_fallback = false
	add_child(_client)

	var started: DotResult = await _client.start()

	if not _check(started.ok, "the client starts", str(started.error)):
		_done()
		return false

	_check(
		DotRegistry.get_service(HungryContentSource.CLOUD_SERVICE) != null,
		"and registers itself where this game looks for it"
	)

	var verified := _client.verify_manifest(_manifest)
	_check(verified.ok, "the manifest passes the client's own check", str(verified.error))

	var plan := _client.plan_for(_manifest)
	_check(
		int(plan["missing_files"]) == 7,
		"nothing is cached yet (%d missing)" % int(plan["missing_files"])
	)

	var acquired: DotResult = await _client.acquire_manifest(_manifest)

	if not _check(acquired.ok, "and it acquires", str(acquired.error)):
		_done()
		return false

	_check(
		_client.is_ready(_manifest.key()),
		"the pack is ready (%s)" % _manifest.key()
	)

	# Second time round it must be free. A client that re-downloaded on every acquire
	# would work perfectly and cost a player their data allowance.
	var again: DotResult = await _client.acquire_manifest(_manifest)
	_check(again.ok, "and acquiring it again is idempotent")

	_done()
	return true


func _test_mount() -> void:
	_section("mounting")

	var prefix := _manifest.mount_prefix()

	for part in ["rider_pip", "rider_blob", "hat_cap", "trail_ember"]:
		_check(
			ResourceLoader.exists(prefix.path_join("%s.tscn" % part)),
			"%s is mounted" % part
		)

	# And the script is not, because it was never published. The mounted scenes reference
	# the build's copy by its absolute path, which is the only path that is stable across
	# versions of the pack.
	_check(
		ResourceLoader.exists("res://content/avatars/part.gd"),
		"the script they reference is the build's, which is where it has to be"
	)

	# The pack must instantiate, not merely exist. A scene whose script did not come
	# across resolves as a path and fails on load, which is a content bug that looks like
	# a rendering one.
	var packed: Variant = load(prefix.path_join("rider_blob.tscn"))
	_check(packed is PackedScene, "a mounted part loads as a scene")

	if packed is PackedScene:
		var instance: Variant = (packed as PackedScene).instantiate()
		_check(instance is Node2D, "instantiates as a Node2D")
		_check(
			instance is Node and (instance as Node).has_method(&"hungry_dress"),
			"and answers the dressing contract"
		)

		if instance is Node:
			(instance as Node).queue_free()
	_done()


func _test_resolution() -> void:
	_section("resolving through the catalogue")

	var schema := HungryContent.avatar_schema()
	var catalogue := DotAvatarCatalogue.new()
	var source := HungryContentSource.new()
	source.install(catalogue)

	# Before anything is adopted, the build's copies answer. That is the fallback, and it
	# has to keep working — most players will never download this pack.
	var body := schema.part(&"rider_blob")
	var from_build := source.resolve_part(body)

	_check(
		from_build.begins_with(HungryContentSource.BUILTIN_PREFIX),
		"a part resolves out of the build first (%s)" % from_build
	)
	_check(not source.is_mounted(body), "and is not from a pack")

	source.adopt_mount(_manifest.mount_prefix())
	catalogue.invalidate()

	var from_pack := source.resolve_part(body)

	_check(
		from_pack.begins_with(_manifest.mount_prefix()),
		"and out of the pack once it is mounted (%s)" % from_pack
	)
	_check(source.is_mounted(body), "which it now says it is")
	_check(from_pack != from_build, "and they are different files")

	# A part id is a name, not a path. The avatar schema bounds ids to base64url characters
	# so one cannot contain a separator, but this builds a path out of it and the check is
	# where the path is built.
	var hostile := DotAvatarPart.make(&"x", &"body", true)
	hostile.id = StringName("../../../addons/dot_core/dot_core_plugin")
	_check(
		source.resolve_part(hostile) == "",
		"and a part id that is a path is refused"
	)
	_done()


func _test_rider() -> void:
	_section("a rider dressed from the pack")

	var schema := HungryContent.avatar_schema()
	var catalogue := DotAvatarCatalogue.new()
	var source := HungryContentSource.new()
	source.install(catalogue)
	source.adopt_mount(_manifest.mount_prefix())

	var avatar := DotAvatar.make(schema.id)
	avatar.set_part(&"body", &"rider_spike")
	avatar.set_part(&"hat", &"hat_crown")
	avatar.set_part(&"trail", &"trail_ember")
	avatar.set_colour(&"body", 0, Color(0.2, 0.9, 0.5))

	var rider := HungryRider.make(schema, catalogue)
	add_child(rider)
	rider.wear(avatar)

	_check(
		rider.built_slots() == 3,
		"every slot is built from real content (%d built, %d drawn)"
			% [rider.built_slots(), rider.drawn_slots()]
	)

	var built: Node2D = rider._built.get(&"body")
	_check(built != null, "the body is a node from the pack")

	if built != null:
		# The scene came from the pack; the script it runs came from the build. That split
		# is the design and not an accident — see HungryContentSource.publish.
		_check(
			built.get_script() != null
				and String(built.get_script().resource_path)
					== "res://content/avatars/part.gd",
			"running the build's script, because a pack cannot name its own (%s)" % (
				String(built.get_script().resource_path) if built.get_script() != null
				else "<none>"
			)
		)
		_check(
			(built.get("tint_a") as Color).is_equal_approx(
				DotAvatar.quantise(Color(0.2, 0.9, 0.5))
			),
			"tinted from the document"
		)

	rider.resize(48.0)
	_check(
		built != null and is_equal_approx(float(built.get("unit")), 48.0),
		"and sized from the monster"
	)

	remove_child(rider)
	rider.free()


# --- Refusals --------------------------------------------------------------
	_done()

func _test_refusals() -> void:
	_section("what a client refuses")

	# A manifest signed by a key the client does not trust. This is the whole trust
	# boundary: everything downstream believes the hashes and the paths in it.
	var stranger := DotCloudSignature.generate_keypair(2048)

	if stranger.ok:
		var config := DotCloudConfig.new()
		config.cache_dir = WORK.path_join("cache2")
		config.require_signed_manifests = true
		config.trusted_keys = {"default": str((stranger.value)["public"])}

		var wary := DotCloudClient.new()
		wary.name = "Wary"
		wary.config = config
		wary.config_file = ""
		wary.local_search_dirs = PackedStringArray([_publish_dir()])
		add_child(wary)

		var refused := wary.verify_manifest(_manifest)
		_check(
			not refused.ok,
			"a manifest signed by an untrusted key is refused",
			"accepted it" if refused.ok else str(refused.error.code)
		)

		remove_child(wary)
		wary.queue_free()

	# An unsigned pack. Legitimate for LAN play and development, and refused by a
	# default-configured client — which is the point.
	var unsigned_dir := WORK.path_join("unsigned")
	var unsigned := HungryContentSource.publish(unsigned_dir, "", "9.9.9")

	if _check(unsigned.ok, "an unsigned pack publishes", str(unsigned.error)):
		var bytes := DotPaths.read_bytes(
			str((unsigned.value as Dictionary)["manifest_path"])
		)
		var parsed := DotCloudManifest.from_json_bytes(bytes.value)

		if parsed.ok:
			var refused_unsigned := _client.verify_manifest(parsed.value)
			_check(
				not refused_unsigned.ok,
				"and a client that requires signatures refuses it",
				"accepted it" if refused_unsigned.ok else str(refused_unsigned.error.code)
			)

	# A version that is a path rather than a component. slugify("../evil") is "evil",
	# non-empty, and the mount prefix interpolates the raw string — so a manifest
	# declaring one used to validate cleanly and mount at res://, which is exactly the
	# shadowing the namespace exists to prevent.
	var escaped := DotCloudManifest.new()
	escaped.content_id = HungryContentSource.PACK_ID
	escaped.version = "../.."
	escaped.mount_root = "dot_cloud"

	_check(
		not escaped.validate().ok,
		"and a version that climbs out of the mount is refused"
	)
	_done()
