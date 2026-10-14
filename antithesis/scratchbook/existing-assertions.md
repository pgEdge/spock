---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Existing Antithesis Assertions

## Summary

The codebase has **no existing Antithesis instrumentation**. Every SUT-side
assertion suggested in a property evidence file is therefore **missing** and
would be new work.

## Scan Method

Case-insensitive search across `*.c`, `*.h`, `*.sql`, `*.pl`, `*.pm`, `*.sh`,
`*.py` and `Makefile` files in the repo (excluding `antithesis/`) for:

- `antithesis` (SDK includes such as `antithesis_sdk.h`, link flags, comments)
- `assert_always`, `assert_sometimes`, `assert_reachable`, `assert_unreachable`
- The C SDK macro forms `ALWAYS(`, `SOMETIMES(`

No matches.

## Related In-Tree Mechanisms (not Antithesis assertions)

These are not SDK assertions, but later work may reuse or sit next to them:

- PostgreSQL `Assert()` calls throughout `src/`. They are active only in
  `--enable-cassert` builds and abort the backend when they fail. They are not
  reported to Antithesis as properties.
- `src/spock_injection.c` / `include/spock_injection.h`: Spock's wrappers around
  PostgreSQL injection points, used by TAP tests to force specific timings.
  These mark timing-sensitive code locations, which makes them good places to
  put `Reachable`/`Sometimes` assertions.

## Assumptions

- There is no Antithesis C SDK. SUT-side assertions for this C extension go
  through a small C++ SDK shim compiled into `spock.so` with `extern "C"`
  wrappers, or a fallback JSONL writer (see `property-catalog.md` Summary and
  `evaluation/synthesis.md`).

## Open Questions

- None.
