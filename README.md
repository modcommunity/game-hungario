This is a **game** built on TMC's **Dot** collection, rather than a piece of it. It was written to run the whole family end to end, and it is the first thing here a person can actually sit down and play.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This project is built out of them, so it doubles as a worked example of what they look like in a real game rather than in a demo.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## An Arena Game Built Out of `dot-*`
An agar.io-shaped game where the thing you steer is a monster and the thing riding it is
your avatar. Built out of the [dot-*](../NOTES.md) family, and meant to be played from a
link.

```bash
godot --path .                                       # the launcher
godot --path . -- --offline                          # bots, no server needed
godot --headless --path . res://examples/dedicated.tscn -- --serve
```

Mouse steers — near is slow, far is full speed. **Space** splits, **W** ejects, **Q**
throws, **Tab** is the board, **Enter** is chat, **Escape** is the menu and your loadout.
On a phone, a drag steers and there are two buttons.

## What it is made of

| | |
| --- | --- |
| [dot-core](../dot-core) | Everything shared. |
| [dot-2d](../dot-2d) | Movement, mass rules, the spatial hash, the deterministic food fields. |
| [dot-net](../dot-net) | Tick sync, snapshots, interpolation, prediction, interest management. |
| [dot-server](../dot-server) | The dedicated server, chat, votes, and switching modes under live players. |
| [dot-match](../dot-match) | Rounds, the scoreboard, respawning. |
| [dot-ui](../dot-ui) | Mass readout, leaderboard, feed, minimap, menus, key bindings. |
| [dot-user-avatar](../dot-user-avatar) | The rider: an avatar as a document a server checks without loading art. |
| [dot-loadout](../dot-loadout) | Throwables and traits, as data a server validates without loading any of it. |
| [dot-platform](../dot-platform) | Identity, profile and avatar joined into one admission. |
| [dot-cloud](../dot-cloud) | Signed, versioned delivery of the rider's parts. |
| [dot-auth](../dot-auth) · [dot-user](../dot-user) | Underneath dot-platform: who you are, and the profile that follows you. |
| [dot-serve](../dot-serve) | Starting a server. |

## The rules

Your mass is your size, your speed and your score, and they trade against each other:
twice the mass is **√2** the width and about **26% less** speed. That single relationship
is the whole balance — it is what makes two small monsters worth the same area as one big
one, and why being biggest is not simply winning.

**Eating needs a ratio and an overlap.** You have to be a quarter bigger *and* properly on
top of them.

**Food comes in four sizes** — crumb, morsel, chunk, haunch — and the big ones are rare.
The win target is roughly seven hundred average pieces, which nobody reaches by grazing.
Getting there means eating players.

**Fruit is rare and does something for eight seconds.** *Rush* makes you faster, *maw*
lowers the ratio you need to eat somebody, *rind* absorbs one burst.

**Throwables are picked up off the ground.** A *pepper* bursts whoever it hits into five
pieces — which is how a small monster turns an unwinnable fight into several winnable
ones. A *frostberry* slows them. A *lure* plants a ring of food where it lands, which is
worth a lot to whoever gets there first and is a very visible advertisement of where you
are.

**Splitting throws half of you forward.** It is how a big monster catches a small one, and
it is a risk: the pieces cannot merge for sixteen seconds and each of them is individually
smaller than you were. Bursting is the same thing done to you against your will.

**Every monster is ringed by what it means to you** — green if you could eat it, red if it
could eat you, nothing if neither. Eating needs a *quarter* more mass, which is about 12%
more width, and nobody judges that by eye while being chased.

**Let go of the mouse to gather.** Every piece steers toward the cursor's point, so putting
the cursor on yourself pulls your pieces back together.

**Eject to get smaller on purpose.** W spits a blob of mass out in front of you, worth
slightly less than it cost. Being smaller is being faster, harder to corner, and able to
fit through a gap between two things that could eat you — and the blob is ordinary food
that anybody can take, including whoever is chasing you.

**Pick a loadout before you spawn.** A starting throwable, and one of three traits:
*nimble* (faster, smaller start), *sturdy* (bigger start, slower) or *greedy* (more from
every piece of food, smaller start). Every one is a trade, and the server checks the
choice against what you have unlocked.

Mass above 260 decays at a fifth of a percent a second. A player who is still eating never
notices; a player who has parked in a corner does.

## Your avatar rides the monster

The rider on top of your monster is a **dot-user-avatar document**: a handful of ids and
colours the server validates against a schema and an entitlement set **without loading any
art at all**. That is what makes it possible for a dedicated server to say no to a cosmetic
it has never seen.

The parts themselves come from a **signed dot-cloud pack** when a server has published one,
from the build when it has not, and are drawn from their id and colours when there is
neither. That order is deliberate: downloadable cosmetics are an upgrade, not a
requirement, and a player you cannot see is a competitive advantage.

```bash
godot --headless --path . res://tools/publish_avatars.tscn      # sign and package
godot --headless --path . res://examples/content.tscn           # publish, fetch, mount, wear
```

## Where dot-2d stops and this starts

dot-2d ships the motor, the mass relationships, the spatial hash and the deterministic
scatter field, and **deliberately stops short of splitting and merging** — split pieces are
several entities owned by one player, which needs an ownership model and a merge rule that
are a game's design rather than a library's.

`HungryMonster` is that ownership model: a player is a *set* of pieces. Your mass is the
sum, your position is the mass-weighted centroid, your rider sits on the biggest piece, and
you are dead when the last one is eaten. `HungryWorld` is the rest — eating, splitting,
bursting, merging, throwables, and the bookkeeping that keeps the spatial hash agreeing
with the world.

The one thing that had to change in the *shape* of dot-2d's command to make a multi-piece
game work is described under "A player is a set, and the pointer is a point" in
[CLAUDE.md](CLAUDE.md). Short version: every piece steers toward the cursor's point rather
than along one shared direction, or a split monster can never rejoin.

## When you are eaten

You watch whoever ate you until you respawn — and if they have been eaten too, the leader.
A camera left where you died is a black rectangle while the fight that killed you carries
on somewhere else.

## Settings

Volume, camera smoothing, zoom-with-size, the minimap, names, the feed and the threat
rings, from the pause menu. They are written to `user://cfg/hungry.json` and survive a
restart.

The screen has no layout code: `DotSettingsPanel` builds the editors from the config's own
`@export` annotations, so a setting added to `HungryConfig` appears there and nothing else
changes.

## Multiplayer

Everything here is server-authoritative. Clients send inputs, never state.

- **Eleven hundred pieces of food are never replicated.** They are placed by a hash of
  (seed, index), so a client lays the whole field out from one integer; what travels is
  which slots have been eaten.
- **Each piece is a replicated entity**, interest-managed from the monster's centroid, so a
  client is told about what is on its screen and nothing else. Data never sent cannot be
  drawn on a wallhack.
- **Your own monster is predicted** and reconciled against the server, so it moves on the
  tick you press rather than a round trip later.
- **No audio files either.** The ten sounds are generated at startup — a sweep, a noise
  component and an envelope — so the game makes noise without anybody producing a WAV.
- **The server can change mode with everybody still connected.** `changegame frenzy`.

## Playing it in a browser

See [web/README.md](web/README.md). Short version: the server listens on **WebSocket**
because a browser has no UDP and Godot's web template does not ship ENet at all; the web
build is a **client** because a tab cannot listen; and the page needs `wss://` because an
HTTPS page may not open an insecure socket.

`web/embed.html` takes the server from the query string, so one export serves every server.

## Server console

| | |
| --- | --- |
| `hungry_bots <n>` | Keep this many bots in the world. |
| `hungry_loadouts` | What everybody brought in. |
| `hungry_avatar_pack <url>` | Where this server's rider content lives. |
| `hungry_status` | The world, the field and the netcode. |
| `hungry_top` | The leaderboard. Usable from chat. |
| `hungry_net` | Snapshot rates, bandwidth, clock, link counters. |
| `hungry_restart` | Restart the round. |
| `hungry_give <player> <pepper\|frost\|lure>` | Hand somebody a throwable. Cheat-flagged. |
| `hungry_burst <player>` | Blow somebody apart. Cheat-flagged. |
| `changegame hungry_frenzy` | Switch mode without dropping anybody. |
| `votemap hungry_frenzy` | Let the players decide. dot-server's own, no code here. |

## Validating changes

```bash
godot --headless --path . res://examples/headless_round.tscn   # 186 — the game
godot --headless --path . res://examples/headless_net.tscn     # 107 — the netcode
godot --headless --path . res://examples/dedicated.tscn        #  81 — a real DotServer
godot --headless --path . res://examples/sandbox.tscn          #  68 — two real clients
godot --headless --path . res://examples/content.tscn          #  45 — the cloud path
```

Each exits non-zero on failure. See [CLAUDE.md](CLAUDE.md) for the setup and for what each
one is actually checking.
