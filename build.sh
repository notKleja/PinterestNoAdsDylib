#!/bin/zsh
set -euo pipefail
cd "${0:a:h}"
mkdir -p build
xcrun clang -Wall -Wextra -Werror tools/macho_inject.c -o build/macho-inject
xcrun clang -Wall -Wextra -Werror tests/InjectorFixtureMutator.c \
  -o build/injector-fixture-mutator
case "${1:-ios}" in
  test)
    xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -dynamiclib \
      -DPIB_PROBE_NO_AUTOSTART -framework Foundation src/PinterestProbe.m \
      -o build/libPinterestProbe-host.dylib
    xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -dynamiclib \
      -framework Foundation src/PinterestProbe.m \
      -o build/libPinterestRelease-host.dylib
    xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -dynamiclib \
      -DPIB_PROBE_NO_AUTOSTART -DPIB_FILTER_AUTOSTART_TEST \
      -framework Foundation src/PinterestProbe.m \
      -o build/libPinterestFilter-host.dylib
    sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun clang -isysroot "$sdk" -target arm64-apple-ios16.0 \
      -fobjc-arc -fblocks -Wall -Wextra -Werror -dynamiclib -framework Foundation \
      -Wl,-install_name,@rpath/libPinterestValidationFixture.dylib \
      src/PinterestProbe.m -o build/libPinterestValidationFixture.dylib
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
      tests/ProbeTests.m -o build/probe-tests
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
      tests/FilterTests.m -o build/filter-tests
    build/probe-tests "$PWD/build/libPinterestProbe-host.dylib"
    build/filter-tests "$PWD/build/libPinterestFilter-host.dylib"
    zsh tests/ReleasePolicyTests.sh "$PWD/build/libPinterestRelease-host.dylib"
    zsh tests/InjectorTests.sh
    zsh tests/PackagePreflightTests.sh
    zsh tests/PublicTreeAuditTests.sh
    zsh tests/MachOPreflightTests.sh
    ;;
  ios)
    sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun clang -isysroot "$sdk" -target arm64-apple-ios16.0 \
      -fobjc-arc -fblocks -Wall -Wextra -Werror -dynamiclib -framework Foundation \
      -Wl,-install_name,@rpath/libPinterestProbe.dylib \
      src/PinterestProbe.m -o build/libPinterestProbe.dylib
    codesign --force --sign - build/libPinterestProbe.dylib
    codesign --verify --strict build/libPinterestProbe.dylib
    ;;
  *) print -u2 'usage: zsh build.sh [ios|test]'; exit 2 ;;
esac
