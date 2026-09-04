# dot-2d-hungry

An agar.io-shaped 2D game where the thing you steer is a monster and the thing riding it
is your avatar. Read `../../CLAUDE.md` first for the family-wide rules; this file is what
is specific to this game.

*(`dot-2d-hungry` is a working name. Nothing in the code depends on it — the class prefix
is `Hungry`, the module is `hungry`, and the two game ids are `hungry_classic` and
`hungry_frenzy`.)*

## Why this project exists

Three reasons, and the third is the one that shaped it.

**It is the first thing in the family that is actually played.** game-arena and game-blob
each run their addons together and prove the seams; neither has a client a person can sit
down at. This one has a launcher, a camera, a renderer, a HUD, chat, menus, sound and a
touch path, and the whole of it runs against a real `DotServer` over a real socket.

**It joins the two halves of the platform.** dot-fps-controller, dot-combat, dot-loadout
and dot-match are the gameplay half; dot-auth, dot-user, dot-user-avatar and dot-platform
are the identity half. Before this they were exercised separately. Here a guest signs on
through dot-platform, gets a profile and an avatar, chooses a loadout the server validates
against an entitlement set, and that avatar is drawn on top of the monster they steer —
from a signed pack dot-cloud fetched, or from the build if there is no pack.

**It is where the netcode became a game rather than a demonstration.** game-arena's bridge
proved dot-net works; this one has to survive an entity count that changes every second —
a monster splits into sixteen and merges back — a field of eleven hundred things that is
never replicated, and a game change with players still connected. Four of the bugs below
are in other projects and none of them was reachable from that project's own suite.

## A player is a set, and the pointer is a point

`HungryMonster` owns an array of `HungryPiece`. Almost every question about a player is a
property of the set: mass is the sum, position is the **mass-weighted** centroid, the
camera frames the spread, the rider sits on the biggest piece, and you are dead when the
last one is eaten. That much is game-blob's design and it is right.

What game-blob did not have, and what a multi-piece game cannot work without:

> **Every piece steers toward the cursor's *point*, not along one shared direction.**

`Dot2DCommand` carries `aim` (a unit vector) and `reach` (a distance) because a *screen*
position is meaningless on a server. A *world* position is not, and it is recoverable: the
sampler measures the pointer from the monster's centroid, so the server adds the same
offset to the same centroid and gets it back — `HungryWorld.pointer_of`. Every piece then
computes its own direction to that point.

Steering every piece along one shared direction instead makes a split monster a rigid
formation. The pieces move in parallel, at the same speed, for ever; they never come back
within merging distance; splitting is permanent and merging is unreachable. **Nothing
errors** — each piece did exactly what it was told — and it is invisible until you try to
merge. It cost a failing check in `headless_round` to find, and the fix is four lines and
a method name. game-blob had it too and now has both the fix and the check.

The pleasant consequence: releasing the mouse puts the pointer at your own centroid, so
your pieces gather. That is not a special case, it is the same rule.

## Four fields, one id space, and only membership travels

`HungryField` owns four things in one object because a monster's eat check has to consider
all of them on the same tick against the same `Dot2DGrid`:

| | |
| --- | --- |
| **food** | Four sizes. Which size is a hash of the slot index, so it is never sent. |
| **fruit** | Rare, worth a lot, and each of the three does something for eight seconds. |
| **item drops** | A charge of a throwable. |
| **planted** | What a lure leaves behind, and what ejecting spits out. |

The ids are one space split by constants (`FOOD_ID_BASE`, `FRUIT_ID_BASE`, …) rather than
four grids, for game-blob's reason: two grids means two queries and a merge of the
results, per piece, per tick, and four means four.

**Three of the four are positionless on the wire.** `Dot2DScatter` places a slot from a
hash of (seed, index), so a client that knows the seed knows where every crumb is, how big
it is, and which fruit it is, from an integer. What actually travels is which slots
*exist*: a list of indices added and a list taken, which at a steady state is a few dozen
varints a snapshot and on a join is about 3 kB once.

**The fourth is the exception that shows why.** A lure drops food where a player chose, and
a chosen position cannot be derived from anything. Planted slots carry their position, and
they are a separate field precisely so that the cheap case stays cheap. Ejecting reuses it:
a spat-out blob is ordinary planted food, so it replicates, indexes and is eaten through
paths that already existed rather than being a fifth kind of thing.

Two things follow that are easy to get wrong:

- **The bounds are part of the position.** A slot is hashed *into the arena rectangle*, so
  a client holding a different rectangle derives every crumb somewhere else — from the
  right seed, which is what makes the failure confusing: the ids match, the counts match,
  and nothing is where anybody says it is. `adopt_world_size` runs before
  `adopt_field_seed` for that reason, and the hello carries the size.
- **A slot index is never reused**, which is `Dot2DScatter`'s rule and this class
  inherits it. A new round's ids therefore sit *beside* the old round's rather than
  overwriting them, and whatever indexed the old field into a grid must remove it first.
  game-blob found that the hard way; here it is three fields wide.

## Effects are replicated as flags, and that is what makes them predictable

A monster's effects (`rush`, `maw`, `rind`, `frosted`, spawn protection) live on the
authority as expiry ticks. Speed depends on two of them.

If the client had to know the expiry ticks to compute its own speed, every fruit would be
an eight-second mispredict. So the effects are written into the *replicated piece flags*
once a tick, and `HungryMonster.speed_multiplier` reads the flags rather than the effects
— both ends compute speed from the same number, one tick apart. `HungryMonster.flags` is
that number; `adopt_flags` is where a receiving peer takes it off any of a monster's
pieces.

The trait from a player's loadout does the same thing for the same reason, by a different
route: it changes speed too, so it travels in the join and both ends read it off
`HungryMonster.trait_id`.

## What a player brings in

Two slots, one decision each, and every option is a trade rather than an upgrade:

| | |
| --- | --- |
| **starter** | Which throwable you spawn holding. |
| **trait** | `nimble` (+8% speed, −10% mass), `sturdy` (−5% speed, +15% mass), `greedy` (+15% from food, −10% mass). |

**Everything about it is ids.** `HungryContent.loadout_schema()` is a `DotLoadoutSchema`
over a `DotItemCatalogue`, and a dedicated server decides whether a published loadout is
legal from the schema and an entitlement set without touching an asset. If a change here
ever needs a `load()`, that is the thing to push back on.

`greedy` is the one item that is not `free`, so that an unwired server has a working
example of something nobody may take. **Entitlements default to nothing**, and that
default is the important one: a server that granted everything would work perfectly in
every test, ship, and quietly be a game where every unlock is free — and nobody reports
that as a bug.

Three separations worth keeping:

- **Validate on the way in, conform on the way out.** `HungryNetBridge._apply_loadout`
  validates a published document and refuses it. A client that can make the server repair
  its way to a legal loadout can put anything in any slot and have the server pick the
  nearest legal thing. `DotLoadoutConfig.conform_on_load` is on for the other direction,
  where refusing means a player who has not played for a month cannot spawn.
- **The screen never decides what is legal.** It offers `choices_for(slot, entitlements)`
  and the server validates the result anyway. A screen that filtered on its own would
  drift the first time an unlock changed; one the server trusted would be a client
  choosing its own stats.
- **The store is a `Callable`, not a manager reference.** `HungryNetBridge.loadout_sink`
  takes a published loadout somewhere, and where is a deployment decision. `HungryModule`
  points it at a memory-backed `DotLoadoutManager`; a community server points it at its
  own service. The sink is awaited, because a store may be slow and the cache must not be
  updated before the write succeeds.

A loadout takes effect on the **next spawn**. A player who could change their trait
mid-fight would change it the moment they were losing.

## The rider comes from the cloud, and from the build when it does not

`DotAvatarBuilder.plan` works out which part goes in which slot, in what order, with which
colours, and which have fallen back — pure logic over ids, no scene touched, the same
answer on a headless server as in a browser. `DotAvatarBuilder.apply` builds a `Node3D`
rig, so a 2D game cannot use it: `HungryRider` uses the plan and does its own attaching.

`HungryContentSource` is `DotAvatarCatalogue.resolver`, and the order is the design:

```
1. a mounted dot-cloud pack   <- signed, hash-verified, version-namespaced
2. res://content/avatars/     <- what shipped in the build
3. ""                         <- drawn by HungryRider instead
```

That order is what makes downloadable cosmetics an **upgrade rather than a requirement**.
A player you cannot see is a competitive advantage, so step 3 is not optional.

**The pack is data. The code that draws it ships in the build.** A `.tscn` names its script
by an *absolute* `res://` path and a pack's own path carries its version
(`res://dot_cloud/hungry_avatars/1.0.0/`), so a scene inside a pack cannot reference a
script inside the same pack without being re-authored per version. So the parts are scenes
with exported properties and `part.gd` stays in the build — which also means a pack
published against a newer game degrades rather than breaks: an unknown `shape` falls
through to the default one. The whole contract is a `Node2D` that answers `hungry_dress`.

Signing is still not optional. Not because this pack contains code — it deliberately does
not — but because the manifest is the entire trust boundary: its hashes decide what counts
as a valid download and its paths decide what gets mounted, and a Godot pack *can* contain
scripts.

The server names the pack in the hello (`hungry_avatar_pack`), so one client build works
against a server that ships its own cosmetics and one that ships none. Nothing waits for
it: the rider is drawn until the parts land.

`examples/content.tscn` runs the whole path — publish, sign, fetch, verify, mount, dress —
and four refusals: a tampered manifest, a valid signature from the wrong key, an unsigned
pack, and a version that climbs out of the mount.

## Sound is arithmetic

`HungrySound` bakes ten voices at startup: a sine sweep with a hash-derived noise
component under an attack-decay envelope. It ships no audio files, the same way dot-ui
ships no art and dot-2d draws nothing.

Two consequences worth keeping:

- **Deterministic, so it is testable.** The noise comes from `Dot2DScatter._hash` rather
  than `randf()`, so the bank is byte-identical everywhere and `headless_round` can assert
  that a voice is the right length, is not silence, and ends at zero rather than clicking.
  A generator pushing buffers could only be judged by listening to it.
- **Eating is *watched*, not listened for.** `HungryWorld.food_eaten` fires on the
  authority, which on a netted client is somewhere else — a client that hooked it would be
  silent all game and perfectly noisy offline, which is the kind of difference nothing
  catches. What a player perceives is their own mass going up, and that arrives either
  way, so `HungryClient._watch_mass` turns the difference into a blip pitched by its size.

## Settings are a `DotConfig`, and that is why the screen has no layout code

`HungryConfig` is nine `@export`s. `DotSettingsPanel` reads the annotations — type, range,
group, hint — and builds the editors, so adding a setting adds a row and nothing else
changes, and the screen cannot drift from the settings it is meant to show because it
never restates one.

Two rules the wiring follows:

- **Applied, then announced.** The panel holds edits until Apply because a config is
  legitimately invalid on its way to being valid, and `validate()` runs on the whole
  thing. `SettingsScreen.applied` fires only after `apply()` succeeded, so nothing ever
  reads a config that failed.
- **Pushed, not polled.** The camera, the sound and the renderer hold the value they were
  given. Asking a config every frame would put a dictionary lookup in the draw path for
  something that changes when somebody opens a menu.

A missing settings file is a first run, which is not an error. A *malformed* one is, and
it falls back to the defaults with a warning rather than refusing to start — losing what
a player set is bad, and not starting is worse.

## Being eaten means having nothing at all

No pieces, no position, nowhere for a camera to be. So a dead player watches whoever ate
them, and if that player has since been eaten too, the leader — `HungryClient._watched`,
which is what both the camera and the *input* are measured from. The input matters: a dead
player's pointer measured from a monster that does not exist means the mouse is silently
pointing at nothing when they respawn.

The HUD says whose eyes they are behind, because a player staring at somebody else's
monster with no explanation reasonably concludes the game has broken.

## The rings are the rule, drawn

Eating needs a **ratio** — a quarter more mass — and a quarter more area is about twelve
percent more width. Nobody judges that by eye, and certainly not while being chased. So
every monster is ringed green if you could eat it and red if it could eat you, and
**neither when the two are inside the ratio of each other** — that gap is the interesting
case and the one a colour would lie about. A piece that is merely smaller is not food.

## Touch

`HungryTouch` is two buttons and nothing else, because this game is nearly playable on a
phone by accident: there is nothing to aim and nothing to select, a drag is the pointer,
and near is slow. What a touchscreen cannot express is the two edge-triggered actions.

They are `Control`s rather than `TouchScreenButton`s on purpose — a `Control` consumes the
touch before `_unhandled_input` sees it, so pressing one does not also drag the monster
across the screen, which is exactly what a `Node2D` button would let through.
`--touch` forces them on so the layout can be looked at on a desktop and so a headless run
can drive them.

## The netcode

### Ordering: the first behaviour through drives the world

dot-net simulates per entity. This game's tick order is a whole-world property: everybody
moves, then eating is resolved against the world as it is *afterwards*, then merges, then
projectiles, then the match. Those two facts meet in `HungryNetBridge.ensure_world_ticked`
— the first `_net_simulate` on a given tick runs the entire world and the rest find it
done. That is game-arena's pattern and it is the right one.

`HungryModule.server_tick` calls it again afterwards, which is not redundant: it covers the
tick before the match entity is registered, and it costs one integer comparison.

### One entity per piece, and one always-relevant entity for the match

A player is not one entity. After a burst their pieces can be a screen apart, and an
entity per *player* would have to be relevant everywhere any of its pieces was. So each
piece is a `DotNetIdentity` + `HungryPieceNet`, replicating exactly what `Dot2DNetSync`
describes.

The match clock is its own entity, `always_relevant`, because every client needs the round
state whether or not it can see anybody — a dead player has no pieces at all. It is also
what keeps an empty server ticking: with no players it is the only entity, so it is what
calls `ensure_world_ticked`, and without it a freshly booted server's warmup would never
end.

### Nothing is sent to a peer before it asks

dot-server's signon finishes and *then* the client builds its scene. Between those two
moments the client has no node for an RPC to land on: Godot answers each one with "Node
not found", once per call, and the events are simply lost. So `HungryEvents.Ask.READY` is
the client saying it has somewhere to put them, and `_admit` is where a peer joins the
manager, gets the hello, the roster and the field.

For the same reason `_broadcast` sends peer by peer rather than through dot-net's
broadcast: a broadcast reaches every connected peer, including the ones that cannot
receive yet.

### A bot has no peer, and peer 0 is not "everybody"

Bots are players with no connection, and this game gives them peer 0. Two things follow,
and both were found by a failing check rather than by reading:

- **`net.add_peer(0)` makes the server build a snapshot against the bot's interest
  rectangle and send it to the broadcast address**, so every real client receives a second
  snapshot computed for somebody else. The symptom is a monster that jumps between two
  positions.
- **`net.send(msg, 0)` is a broadcast**, so a `_tell` that fell through to it would send
  every bot's private carry list to every client.

Both are guarded on `peer_id > 0`, and `_tell` says so.

### Prediction is the motor, and deliberately not the set

`_net_simulate` on a predicted piece runs the motor for that piece and nothing else, so it
is a pure function of (state, command, delta) — the only shape a reconciliation replay
converges for. `DotNetPredictor` reconciles one entity at a time, so anything a replay does
that couples two entities is computed against whatever the other one happened to be
holding.

What that costs is `_separate`. It is applied live on both ends and not replayed, so for
the second or so after a split — while the pieces still overlap — the shown positions and
the replayed ones differ by a fraction of the overlap, and the correction is eased out.
Once the pieces are apart, separation does nothing at all and the two agree exactly, which
is every other moment of the game.

**`receive_snapshot` must not reconcile.** `DotNetManager.receive_snapshot` already routes
a predicted entity's state to the predictor and acknowledges the inputs it covers; a
second pass replays the same inputs against values that were already rewound.
`correction_rate()` read **0.500** with the extra pass and **0.032** without.

### Interest is measured from the centroid

`DotNetManager._observer_for` hands a strategy the first entity a peer owns, which after a
burst is an arbitrary fragment. `HungryInterest` measures from the monster's centroid
instead, grows the rectangle linearly in *radius* (a monster wide enough to fill the screen
cannot otherwise see anything it might eat), and scores big-and-near above small-and-far.

## Game switching: the world is the scene, the manager is not

`changegame frenzy` frees the running mode scene and instantiates the next one, with the
players still connected. So the world lives *inside* the scene (`HungryMode`), and the
`DotNetManager`, the bridge and the loadout manager do not — rebuilding a manager resets
the message ids, the peer records and the clock, which is a disconnect for everybody and
precisely what changing the map is supposed to avoid. `HungryNetBridge.rebind` moves the
bridge onto the new world, keeping every connection, and the match entity survives because
its net id is already known to every client.

dot-server's own `votemap`, `vote` and `vote_status` work against both descriptors with no
code here: registering them is all a game has to do.

A game shipped inside its build cannot be handed a client scene by the server — see the
dot-server note below — so `HungryClient` is loaded by the application (`examples/play.gd`)
and the signon takes the no-scene path.

## A check count is not coverage

Every suite here counts **sections entered against sections that ran to their last line**,
and fails when they differ.

That is not defensive programming. A runtime error inside a section — asking a dead
monster where it is — aborts that function and nothing says so: the checks that already
ran still print ok, the ones after it never happen, and the total at the bottom cannot
reveal a check that never ran. It happened here: `_test_devouring` lost eight checks and
the reported total went *up*, because other sections had been added in the same change.
dot-net's demo carries the same pair, reached from the other direction — there it was a
suspending section called without `await`.

Anything that returns early has to call `_done()` before returning.

**The leak report at exit is not a leak in this code.** `dedicated` and `sandbox` print
"ObjectDB instances leaked" with a list of `GDScriptNativeClass` and `GDScript` entries.
Those are the engine's script cache with several hundred scripts loaded, and dot-platform's
sandbox prints the same. A real cycle would name a node or a `RefCounted` of this project's
own; one was chased in dot-net once and turned out to be a suspended coroutine's locals.

## Bugs this project found

Every one of these parsed cleanly and none produced an error.

**In this project:**

- **Split pieces could never rejoin.** One shared aim direction moves every piece in
  parallel. Described above; it is the biggest one, and it is a design bug rather than a
  coding one.
- **`reset_world` cleared the piece dictionary instead of destroying the pieces**, so
  `piece_destroyed` never fired, the netcode's entities stayed registered, and every
  client kept the previous round's pieces on screen for ever.
- **The round announced itself before it reset.** Every client was sent the field that was
  about to be thrown away and then the new one as a delta on top of it, ending a round
  holding exactly twice as much food as existed, half of it phantoms.
- **A part that was its own fallback** made the whole rider schema invalid, which
  `headless_round` never noticed because it never validated a schema.
- **A bot registered as peer 0.** Two separate failure modes from one line.
- **A section that aborted took eight checks with it.** See above.

**In other projects, none of them reachable from that project's own suite:**

- **`ArenaNetBridge` reconciled twice** — correction rate 0.500 against 0.032. Fixed in
  game-arena.
- **`client_spawn` carries `userid`, not `peer_id`.** A module looking a session up by
  `peer_id` gets null every time and adds nobody, silently. game-blob's module had the
  same line and had never connected a client. Fixed in game-blob.
- **`Dot2DScatter` could not be mirrored.** A receiving peer has to adopt the index it was
  given; allocating its own gives the same crumb two names on two machines. Added as
  `adopt`, in dot-2d.
- **dot-server could not serve a game that ships inside its own build.**
  `client_scene_or_scene()` fell back to the server's absolute path, which `DotClientLink`
  refuses — correctly — so the client failed signon and timed out. Fixed in dot-server.
- **`DotCloudClient` never registered itself.** Four call sites across dot-server and
  dot-user-avatar look for it in `DotRegistry` and all four found null, so content
  delivery could not work end to end and a cloud-delivered cosmetic was unreachable — and
  none of them errored, because every one treats an absent cloud as a legitimate
  configuration. Fixed in dot-cloud.
- **A cached interest answer dropped what the observer owned.** `relevant_for` caches per
  peer, and an entity spawned since is in nobody's cached set — so a client did not receive
  its own newly spawned entity until the cache expired, and on a host ticking faster than
  the wall clock it never received it at all. The position looked right the whole time,
  because the owner was predicting it; the mass was frozen at the value the spawn message
  carried. Fixed in dot-net.

## Validating changes

```bash
cd godot/dot-2d-hungry
for pair in dot_core:dot-core dot_2d:dot-2d dot_net:dot-net dot_server:dot-server \
            dot_match:dot-match dot_ui:dot-ui dot_user:dot-user \
            dot_user_avatar:dot-user-avatar dot_auth:dot-auth \
            dot_platform:dot-platform dot_cloud:dot-cloud dot_loadout:dot-loadout \
            dot_stats:dot-stats; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done

godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

godot --headless --path . res://examples/headless_round.tscn   # 186 — the game
godot --headless --path . res://examples/headless_net.tscn     # 107 — the netcode
godot --headless --path . res://examples/dedicated.tscn        #  97 — a real DotServer
godot --headless --path . res://examples/sandbox.tscn          #  68 — two real clients
godot --headless --path . res://examples/content.tscn          #  45 — the cloud path
```

487 checks. Add `-- --verbose` to `dedicated`, `sandbox` or `content` when one fails and
the reason is in a log line rather than in the assertion.

**Run `headless_round` after any change to dot-2d** and **`headless_net` after any change
to dot-net.** Between them they cover the two properties nothing else can see: that two
worlds replaying the same commands are bit-identical, and that a client and a server
running the same motor stay within a few units of each other under 25% packet loss.

**Re-run `--import` after adding any script with a new `class_name`.** Without it the
identifier does not resolve, the scene fails to load, and the process *hangs* rather than
exiting.

**`sandbox` is the one that matters most and the slowest to write.** It is the only place
the RPC node paths, dot-platform's admission, dot-server's chat and a game change with a
player attached all run at once, and three of the bugs above were found by it alone.

It runs **two** clients, each in its own subtree with its own `MultiplayerAPI`, because
everything that decides what one player is told about another — interest, the roster, the
join broadcast, the spawn events — is per-observer, and every one of them is trivially
correct with one observer. Two people seeing each other is the thing a multiplayer game
must do and the thing nothing in this family had ever checked.

## Playing it

```bash
godot --path .                                       # the launcher
godot --path . -- --offline                          # bots, no server
godot --path . -- --connect 127.0.0.1:27081          # straight in
godot --path . -- --offline --touch                  # the phone layout, on a desktop

godot --headless --path . res://examples/dedicated.tscn -- --serve
godot --headless --path . res://tools/publish_avatars.tscn
```

Mouse steers — near is slow, far is full speed. Space splits, W ejects, Q throws, Tab is
the board, Enter is chat, Escape is the menu and the loadout. In the server console,
`hungry_bots 6` fills it.

## Things deliberately not here

- **Teams.** dot-match does teams properly and `HungryRules` would need about ten lines.
  Free-for-all is what the genre is.
- **dot-combat.** Health and damage are the wrong model here: being eaten is a mass ratio,
  not a hit point total, and forcing it through `DotDamageResolver` would be a worse
  version of both. game-arena is where that addon runs.
- **A game delivered through dot-cloud.** The *cosmetics* are, end to end, including the
  refusals. The game itself ships in the build, so `changegame` never exercises
  dot-server's content sync and no client has ever downloaded a map.
- **A real backbone.** `HungryModule` builds the report — with the bot count dot-server
  cannot know, and the mode as the map — and wires it into `DotBackboneClient` when an
  operator has configured a token. Nothing here has ever sent one: there is no backbone in
  this repository, and the checks cover the shape of the report and the fact that an
  unconfigured server stays silent.
- **Lag compensation.** `DotNetConfig.enable_lag_compensation` is off. Nothing in this game
  is a hitscan shot: a thrown item is a moving body both ends already agree about, and
  eating is a proximity test resolved a tick after everyone has moved. Rewinding the world
  would change an outcome nobody disputes.
- **Persistence.** Mass is per round and loadouts are per session — the store is memory,
  because a loadout that outlives a session is a profile and a profile is dot-user's. The
  profile is already resolved; nothing writes to it yet.
- **A server browser.** The launcher takes one address. Picking from a list is
  website-city's, and the reporting side of it is wired above.
