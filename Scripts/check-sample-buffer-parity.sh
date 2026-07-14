#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plain="$repository_root/Sources/MPVKitSampleBuffer"
gpl="$repository_root/Sources/MPVKitSampleBufferGPL"

for source in MPVGPUPlayerRenderer.swift MPVMetalSampleBufferRenderer.swift; do
    if ! cmp -s "$plain/$source" "$gpl/$source"; then
        echo "$source drifted between the GPL and non-GPL wrappers." >&2
        diff -u "$plain/$source" "$gpl/$source" || true
        exit 1
    fi
done


for source in dummy.c include/dummy.h; do
    if ! cmp -s "$repository_root/Sources/_MPVKit/$source" \
        "$repository_root/Sources/_MPVKit-GPL/$source"; then
        echo "$source drifted between the GPL and non-GPL native bridges." >&2
        diff -u "$repository_root/Sources/_MPVKit/$source" \
            "$repository_root/Sources/_MPVKit-GPL/$source" || true
        exit 1
    fi
done

echo "GPL and non-GPL sample-buffer wrappers/native bridges are byte-identical."
