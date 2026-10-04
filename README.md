# PinterestNoAdsDylib

A focused runtime filter for Pinterest on iOS 14.38. It removes promoted and
sponsored models before they enter the app's feed collection.

The repository includes the filter source, a small Mach-O injector, a local
packaging script, and the full host-side test suite. Build the dylib locally and
package it with your own decrypted app bundle.

## What it does

The dylib hooks this Pinterest model-loading boundary:

```text
-[PINRemoteModelCollection
  requestManager:didLoadObjects:withAction:andCompletion:]
```

For each incoming batch, it:

- removes models where `isPromoted` or `isSponsored` is true;
- preserves the order and identity of every remaining model;
- forwards the original request manager, action, and completion object;
- keeps pagination enabled after removing items; and
- calls Pinterest's original collection handler exactly once.

The filter works at the model layer. It does not rely on advertiser names,
visible labels, DNS rules, or renderer-specific hiding.

## Supported build

| Property | Required value |
| --- | --- |
| App | Pinterest for iOS |
| Version | 14.38 |
| Build | 2 |
| Bundle identifier | `pinterest` |
| Architecture | arm64; compatibility dylibs may also include arm64e |
| Main UUID | `8DDF19C3-6AEC-33DF-ADDF-3BF468B29451` |
| Mach-O components | 29, all `cryptid=0` |

The packager checks these values before it creates any output. A different app
version needs a fresh method/ABI check rather than bypassing the guards.

## Requirements

- Apple-silicon Mac
- Xcode command-line tools and an iOS SDK
- A decrypted Pinterest 14.38 `.app`
- An entitlement-reference `.app` from the same version and environment
- A test device or virtualized iOS environment that accepts the resulting
  signature

## Run the tests

```sh
zsh build.sh test
```

The suite covers:

- exact Objective-C getter and callback ABIs;
- promoted, sponsored, organic-only, all-ad, empty, and `nil` batches;
- argument forwarding, ordering, and pagination behavior;
- repeated, concurrent, and conflicting hook installation;
- filter-only release behavior;
- idempotent load-command injection with unchanged `__text`;
- malformed, universal, encrypted, wrong-architecture, and no-padding Mach-O
  rejection; and
- package and public-tree preflight checks.

## Build the dylib

```sh
zsh build.sh ios
```

Output:

```text
build/libPinterestProbe.dylib
```

The release build automatically installs only the ad filter. The optional
`PIBProbeWriteInventory` export remains available for manual runtime inspection.

## Package a local app

Keep the input bundles outside this repository, then run:

```sh
zsh package_noads.sh \
  /absolute/path/to/decrypted/Pinterest.app \
  /absolute/path/to/entitlement-reference/Pinterest.app \
  /absolute/path/to/output-directory
```

The script validates the target, copies it, embeds the dylib, inserts one load
command, signs every nested component in order, verifies the final app, and
creates:

```text
Pinterest-14.38-noads.ipa
```

## Release gate

A signed package is a **candidate**, not a verified release. Before publishing
or calling it fixed, validate the exact IPA on the intended target:

1. install it through the same route users will use;
2. launch it and confirm the process remains alive for at least 15 seconds;
3. capture launch syslog/dyld output, any crash report, and the
   `[PinterestProbe] ad filter installed` log;
4. load multiple feed pages and confirm organic content and pagination remain
   intact; and
5. verify promoted and sponsored models are actually removed.

Host tests, `codesign`, load-command inspection, and ZIP integrity do not
replace this runtime gate.

## Runtime validation

The corrected 14.38 build was installed through an authenticated local vPhone
route on October 4, 2026. Pinterest became the verified foreground app, its
first process survived the 15-second launch gate, a post-respring launch also
rendered successfully, and the guest contained zero Pinterest crash reports.

![Pinterest 14.38 running in the vPhone](docs/r4-pinterest-working-final.png)

This proves installation, launch stability, and UI rendering for the tested
package. It does not yet prove end-to-end promoted-content removal: no account
credentials were entered, no logged-in feed or pagination was exercised, and
the filter-installed log was not captured. Those checks remain part of the
release gate above.

## Project layout

```text
src/PinterestProbe.m             runtime filter and optional probe
tools/macho_inject.c             thin-arm64 load-command injector
tools/validate_macho.sh          per-slice architecture/decryption validator
package_noads.sh                 local app packaging and signing
tests/                           host, ABI, injector, and safety tests
scripts/check_public_tree.sh     source-tree audit
docs/                            non-sensitive runtime evidence
```

## Public-tree audit

```sh
zsh scripts/check_public_tree.sh
```

The audit keeps generated apps, IPAs, binaries, local paths, credentials, and
signing material out of Git history.

## License

MIT. Independent project; not affiliated with Pinterest. Pinterest binaries are
not included.
