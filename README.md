# PinterestNoAdsDylib

An Objective-C runtime filter and reproducible Mach-O injection tool for
authorized, private research on Pinterest for iOS 14.38 (build 2).

This repository contains **only original filter/injector source, tests, and
build scripts**. It intentionally does not contain a prebuilt dylib, Pinterest
`.app`, `.ipa`, executable, framework, extension, resource, account material,
or decrypted analysis dump. You must build the dylib yourself and supply your
own lawfully obtained and decrypted app locally.

Pinterest is a trademark of Pinterest, Inc. This project is independent and
is not affiliated with, endorsed by, or distributed by Pinterest.

## How it works

The dylib hooks this Objective-C-visible Pinterest 14.38 boundary:

```text
-[PINRemoteModelCollection
  requestManager:didLoadObjects:withAction:andCompletion:]
```

Before Pinterest mutates its remote model collection, the hook removes any
incoming model whose `isPromoted` or `isSponsored` Boolean getter is true. It
preserves the surviving objects' identity and order, forwards the original
request manager, signed action value, and completion object, and enables
Pinterest's own `continuesPaginationAfterObjectsRemoved` setting after a
removal.

The filter does not depend on advertiser names or visible label text. It does
not falsify the ad flags, patch network responses, delete measurement SDKs, or
modify Pinterest's executable code section.

The distributed release does not automatically enumerate app metadata or
write diagnostic inventory files. The exported `PIBProbeWriteInventory`
function remains available for an explicit, user-initiated diagnostic build.
Defining `PIB_ENABLE_METADATA_AUTOSTART` at compile time enables the legacy
5-second and 30-second cache snapshots; the supplied build scripts do not set
that macro.

## Compatibility

The packager deliberately fails closed unless the local input matches:

- Bundle identifier: `pinterest`
- Version: `14.38`
- Build: `2`
- Main executable: thin arm64 `Pinterest`
- Main UUID: `8DDF19C3-6AEC-33DF-ADDF-3BF468B29451`
- Original Mach-O inventory: exactly 29 components, all `cryptid=0`
- No `SC_Info` directories

Other Pinterest releases need fresh static and runtime analysis. Do not remove
these guards merely to force another version through the packager.

## Requirements

- Apple-silicon Mac
- Xcode command-line tools with an iOS SDK
- A user-supplied, decrypted Pinterest 14.38 app bundle
- A user-supplied entitlement-reference app bundle from the same version and
  environment
- An authorized test environment that accepts the resulting signature

No Pinterest account credentials are read, stored, or transmitted by these
tools.

## Test

```sh
zsh build.sh test
```

The test suite exercises:

- exact Objective-C getter and callback ABIs;
- promoted and sponsored removal;
- mixed, organic-only, all-ad, empty, and `nil` pages;
- manager, action, completion, ordering, and pagination behavior;
- repeated and concurrent hook installation;
- metadata collection without invoking model getters;
- idempotent load-command injection with unchanged `__text`;
- rejection of unsafe, malformed, wrong-architecture, and no-padding Mach-O
  inputs; and
- package preflight before output creation.

## Build the iOS dylib

```sh
zsh build.sh ios
```

The result is `build/libPinterestProbe.dylib`. The repository intentionally
does not track this generated binary. Build and verify it locally from source.

## Build a local test app

Keep both app bundles outside this Git repository, then run:

```sh
zsh package_noads.sh \
  /absolute/path/to/decrypted/Pinterest.app \
  /absolute/path/to/your/entitlement-reference/Pinterest.app \
  /absolute/path/to/output-directory
```

The script:

1. validates identity, UUID, architecture, decryption state, and component
   count before creating output;
2. copies the input app;
3. embeds `libPinterestProbe.dylib`;
4. inserts exactly one
   `@executable_path/Frameworks/libPinterestProbe.dylib` load command;
5. signs nested components inside-out;
6. requires, reapplies, reads back, and compares app/extension entitlements;
7. verifies the complete app signature; and
8. creates a local `Pinterest-14.38-noads.ipa` outside the repository.

The generated app and IPA are intentionally ignored and blocked by the public
tree audit. Do not open a pull request containing either one.

## Verification boundary

Passing the host tests, signature check, and packaging checks does not prove:

- successful installation or launch on a particular device;
- coverage of server experiments or nested ad containers without either
  classification getter;
- pagination behavior against real production responses;
- login, push, keychain, associated-domain, or app-group compatibility; or
- suppression of measurement performed before the collection callback.

Validate those layers only on an environment you own or are authorized to
test, and report them separately from host-side results.

## Public-tree audit

Before committing or publishing:

```sh
zsh scripts/check_public_tree.sh
```

The audit rejects app packages, extracted bundles, all tracked Mach-O files,
large artifacts, local paths, signing material, and common credential formats.

## License

Original code in this repository is available under the MIT License. This
license does not grant rights to Pinterest software, trademarks, services, or
content.
