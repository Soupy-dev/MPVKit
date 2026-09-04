#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_source="${1:-$repository_root/dist/libmpv-v0.41.0}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-audio-recovery.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

python3 - "$native_source/audio/out/ao_avfoundation.m" "$temporary_root/recovery.m" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
interface = re.search(r'@interface AVObserver\b.*?@end', source, re.S).group()
implementation = re.search(r'@implementation AVObserver\b.*?@end', source, re.S).group()
prefix = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdlib.h>

struct ao {
    atomic_int reloads;
    atomic_bool paused;
};
#define MP_WARN(...) ((void)0)
#define MP_VERBOSE(...) ((void)0)
static void ao_request_reload(struct ao *ao) {
    atomic_fetch_add(&ao->reloads, 1);
}
'''
suffix = r'''
int main(void) {
    @autoreleasepool {
        struct ao playing = {0};
        atomic_init(&playing.reloads, 0);
        atomic_init(&playing.paused, false);
        AVObserver *observer = [[AVObserver alloc] initWithAO:&playing];
        NSNotification *notification = [NSNotification notificationWithName:@"flush" object:nil];
        dispatch_queue_t feedQueue = dispatch_queue_create("test.audio.feed", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(feedQueue, ^{
            [observer handleRestartNotification:notification];
        });
        dispatch_apply(256, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            [observer handleRestartNotification:notification];
        });
        assert(atomic_load(&playing.reloads) == 1);
        assert(!atomic_load(&playing.paused));
        [observer invalidate];
        [observer release];
        dispatch_release(feedQueue);

        struct ao paused = {0};
        atomic_init(&paused.reloads, 0);
        atomic_init(&paused.paused, true);
        observer = [[AVObserver alloc] initWithAO:&paused];
        [observer handleRestartNotification:notification];
        assert(atomic_load(&paused.reloads) == 1);
        assert(atomic_load(&paused.paused));
        [observer invalidate];
        [observer release];

        struct ao *retired = calloc(1, sizeof(*retired));
        assert(retired);
        atomic_init(&retired->reloads, 0);
        atomic_init(&retired->paused, true);
        observer = [[AVObserver alloc] initWithAO:retired];
        dispatch_apply(256, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            if (index % 3 == 0)
                [observer invalidate];
            else
                [observer handleRestartNotification:notification];
        });
        [observer invalidate];
        assert(atomic_load(&retired->reloads) <= 1);
        free(retired);
        dispatch_apply(256, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            [observer handleRestartNotification:notification];
        });
        [observer release];
        puts("AVFoundation recovery: notification queue, duplicate coalescing, paused playback, concurrent retirement and stale notifications passed.");
    }
    return 0;
}
'''
pathlib.Path(sys.argv[2]).write_text(prefix + interface + '\n' + implementation + '\n' + suffix)
PY

xcrun --sdk macosx clang -fno-objc-arc -fblocks -fsanitize=address \
    -framework Foundation "$temporary_root/recovery.m" -o "$temporary_root/recovery"
"$temporary_root/recovery"
