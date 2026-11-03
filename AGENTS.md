# AGENTS.md — rules for this repository

`gitignore` is the shared `.gitignore` (wildmatch) matcher and walk, with JavaScript, Java and Zig ports. It is a
**library**: pattern parsing, matching, the directory chain and a synchronous traversal. It is not a tool, watcher,
daemon or server.

## 1. No daemon here — the Zig fs-meta engine is the only daemon

**The only daemon/watcher in the ecosystem is fs-meta's Zig engine** (`fsmeta daemon`, `fsmeta serve`). It owns the
scan, the hash, the `.fs-meta` trio, the batch archive and the per-root Unix socket.

Every port in this repository — JavaScript, Java and Zig — is a **library/client**:

- it may implement the matcher, the chain and the walk;
- it may be used by a tool that reads a trio or connects to the Zig daemon's socket;
- it **must not** implement a watcher, event loop, scheduler, debounce/grace window, scan-on-change loop, socket
  server, control plane, publish service or second daemon, not even behind a flag.

If a consumer wants live updates, it subscribes to the Zig daemon (`SUBSCRIBE` / `CHANGE_ENTRY` in fs-meta's
`FORMAT.socket.md`) or polls the trio. `walk` is a traversal utility, not a watcher; do not grow an event source
around it here.

## 2. One matcher, one set of vectors

The conformance vectors under `conformance/` and the bench contract are what make three ports one behaviour. A
change to pattern semantics goes through the vectors first, then every port, and is a format change — not a local
convenience. Do not add a second wildcard dialect, brace expansion, extglob or a bespoke glob mode.

## 3. Ports consume, they do not copy

Each language consumes the published artifact or shares this repository's vectors; a port does not vendor another
port's implementation. If a port needs a new API (for example the `./walk` entry point or an option), add it here and
release it so consumers depend on the release rather than a copy.

## 4. Verification

```bash
bun test
bun js/conformance.mjs
bun scripts/check-verdicts.mjs   # the three implementations agree, byte for byte
```

See the README for the Zig/Java commands, the vectors and the benchmark. The daemon and its architecture are
documented in `fs-meta/AGENTS.md` § 1 and `fs-meta/FORMAT.daemon.md`.
