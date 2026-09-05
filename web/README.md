# Playing it in a browser

The whole reason this game is 2D and this small: **a link is the lowest-friction way to
get somebody into a game**, and everything in the dot-* family that is awkward is awkward
because of the browser.

This directory is what stands between "the headless suites pass" and "a stranger clicks a
link and is playing".

## What the browser costs you

Every one of these is already encoded somewhere in dot-core; they are collected here
because they are what a deployment has to answer for.

| Constraint | What it means here |
| --- | --- |
| **No UDP.** `ENetMultiplayerPeer` is not in the web template at all | The server listens on **WebSocket**, and then *all* its clients do — `DotTransportAuto.require_web_clients` defaults to true for this reason |
| **A tab cannot listen** | The web build is a client. The server is somewhere else, always. `examples/play.tscn` says so on screen rather than offering a Host button that fails |
| **No threads** unless the template was built for them | `DotScheduler` slices on the main thread inside a frame budget. Do not assume a worker |
| **`user://` is an IndexedDB mirror** needing explicit flushes | Every write path calls `DotWeb.sync_filesystem()`. Settings and key bindings go through `DotPaths`, which does it |
| **Storage quota the user can refuse** | Nothing here caches anything large. The field is a seed, not a download |
| **CORS, with `fetch()` refusing to say why it failed** | Serve the export and its assets from one origin, or set the headers below exactly |
| **A mounted resource pack can never be unmounted** | dot-cloud namespaces content by `id/version`. The rider pack uses it: `res://dot_cloud/hungry_avatars/1.0.0/`, and a second version cannot shadow the first. The game itself still ships in the build |
| **An HTTPS page may not open a `ws://` socket** | `embed.html` checks for it and says so, because the browser's own error does not mention mixed content |

## Exporting

```bash
godot --headless --path . --export-release "Web" web/build/index.html
```

The preset is not committed (`export_presets.cfg` is gitignored, because it carries
absolute paths and sometimes signing material). Create it in the editor with:

- **Main scene:** `res://examples/play.tscn`. It is the launcher, and in a browser it
  takes the server from the query string.
- **Renderer:** Compatibility. `gl_compatibility` is already the project default —
  Forward+ does not run in a browser.
- **Extensions Support:** off unless you have measured that you need threads. Turning it
  on requires the two isolation headers below on *every* response, including the WASM and
  the PCK, and a single missing one takes the whole page down with a message that does not
  mention headers.
- **Thread Support:** off. `DotPlatform.has_threads()` is the check every dot-* class
  makes, and the whole family works without them.

Then drop `embed.html` beside the exported `index.js`, `index.wasm` and `index.pck`, and
serve the directory. `embed.html` replaces Godot's generated `index.html`: it is smaller,
it handles the device-pixel-ratio and touch-action problems, and it takes the server from
`?server=wss://host:port`.

## Headers

Serve everything from one origin if you possibly can — then none of this matters. If you
cannot:

```
Access-Control-Allow-Origin: https://your-page-origin
Cross-Origin-Resource-Policy: cross-origin
Content-Type: application/wasm          # for index.wasm, or the browser refuses to stream it
Content-Encoding: gzip                  # if you pre-compress; the .pck is the big one
```

With **Extensions Support on**, and only then, every response also needs:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Missing either one is a blank page, not a warning.

## The server

```bash
godot --headless --path . res://examples/dedicated.tscn -- --serve
```

That listens on **WebSocket**, which is what a browser can reach. Put a TLS terminator in
front of it and give the page `?server=wss://your-host:27081`; a page on HTTPS cannot
reach `ws://` and browsers report that as a generic failure.

`dotserve` from [dot-serve](../../dot-serve) does the same thing with a `server.cfg`, a
refusal to run on a guessable RCON password, and an address you can paste to a friend.

## Phones

The touch path is real, not a claim. `HungryInput` treats a drag as the pointer, which is
exactly the control this game wants — there is nothing to aim and nothing to select — and
`HungryTouch` puts the two edge-triggered actions, split and throw, in the bottom corners
inside the display's safe area. They are `Control`s rather than `TouchScreenButton`s so
that pressing one does not also drag the monster across the screen.

Look at the layout on a desktop with `-- --touch`, which is also how the headless suite
drives them: a control nothing exercises is a control that breaks quietly.

`embed.html` sets `touch-action: none` on the canvas. Without it a drag scrolls the page
and the game cannot be played at all.

Audio in a browser needs a user gesture before it will start. Tapping either button or the
canvas is one, so in practice the first sound a player hears is the one after they touch
the screen — which is also the first tick they are steering.

## What is not here

- **A server browser.** The page takes one address. Picking from a list is website-city's,
  and the reporting side of that already exists — `DotBackboneClient` posts a server's
  player count, map and roster to its site listing.
- **A real TLS setup.** Certificates, a reverse proxy and a domain are deployment, not
  code.
- **A downloadable *game*.** The rider cosmetics are published, signed, fetched, verified
  and mounted for real — `examples/content.tscn` runs the whole path — but the game itself
  ships inside the build, so `changegame` never exercises dot-server's content sync and no
  client has ever downloaded a map. Serving the pack from the same origin as the export is
  the easy case and needs none of the CORS headers above.
