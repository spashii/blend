# Blend Mic

Blend Mic is a macOS menu bar app that mixes a microphone with any app's audio or all system audio into virtual microphones. An audio server plug-in (`driver/`) adds one microphone per mix, a C++ engine (`engine/`) captures and mixes the sources, and a SwiftUI app (`app/`) owns the mixes. [docs/internals/overview.md](docs/internals/overview.md) has the architecture and its constraints; [docs/operations/development.md](docs/operations/development.md) has build, test and release steps.

## Documentation

Most code changes do not need an internal documentation change. Agents can read the code.

- `docs/internals/` is for architectural decisions and their reasons, constraints that span components, implementation traps that are hard to discover from the source, and measurements. Before adding a paragraph, ask what a maintainer would get wrong without it. If reading the relevant code answers the question, leave it out.
- Do not document every feature, enumerate fields or methods, narrate control flow, maintain file catalogs, or append PR summaries. Types, tests, and code already record the implementation. Do not tell the story of how a decision was reached; state the decision and the reason.
- A local reason the code can't show goes in a short nearby code comment. Use an internal doc when the reasoning crosses the driver, engine and app, or needs context the code cannot carry well. Link to the relevant source instead of copying it.
- When a documented decision or constraint changes, rewrite or remove the affected text. Do not append another account of the new behavior. A new internal page needs a distinct, durable reason to exist.
- A new measurement or test result goes in [docs/internals/measurements.md](docs/internals/measurements.md). If it changes what users can rely on (an app passing, a macOS version, the delay), update [docs/user/tested-with.md](docs/user/tested-with.md) too, and say plainly what is still untested.
- `docs/user/` helps users accomplish tasks. Give each task a concise page explaining what it does, how to start, and anything unintuitive. A settings path is useful; descriptions of visible buttons, icons, layouts, or every UI state are not. Before adding text, ask what task or decision it helps the user with.
- Keep user docs in the shipped product's voice, without implementation details or contributor tooling. Update the relevant page when how to use a feature changes. A UI tweak does not need a documentation entry, and a new control does not need its own page.
- `docs/operations/` holds maintainer setup, release, and debugging procedures.
- Write plain technical English in short sentences, with no marketing. Claim only what the code and the measurements support. Say "online calls" for calls in apps such as Zoom, Meet or Discord.

## Code comments

Default to no comment. Write one only for what the code can't show: why it is done this way, the impact, and what comes next. Never how we got here: no history, no account of what was tried first, no story of the fix. The commit carries that.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`, with the scope optional. Types: `feat`, `fix`, `perf`, `docs`, `build`, `test`, and `chore(release)` for releases.
- The subject is imperative and under 72 characters: `fix: start echo cancellation off for virtual mics`.
- The body says why, not what. Leave it out when the subject says enough.
- No `Co-authored-by` trailers.
