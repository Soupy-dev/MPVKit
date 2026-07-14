#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
canonical="$repository_root/Sources/MPVKitSampleBufferGPL"
generated="$repository_root/Sources/MPVKitSampleBuffer"

# The GPL wrapper is canonical because it is the flavor exercised by Eclipse. These Swift files
# do not contain license-specific code; only their Package.swift binary dependencies differ.
for source in MPVGPUPlayerRenderer.swift MPVMetalSampleBufferRenderer.swift; do
    cp "$canonical/$source" "$generated/$source"
done

# The optional native-symbol bridge is flavor-neutral too. Its weak references keep new local
# artifacts usable after App Store stripping while remaining nil against older remote artifacts.
cp "$repository_root/Sources/_MPVKit-GPL/dummy.c" \
    "$repository_root/Sources/_MPVKit/dummy.c"
cp "$repository_root/Sources/_MPVKit-GPL/include/dummy.h" \
    "$repository_root/Sources/_MPVKit/include/dummy.h"

echo "Synchronized non-GPL sample-buffer wrappers from the canonical GPL sources."
