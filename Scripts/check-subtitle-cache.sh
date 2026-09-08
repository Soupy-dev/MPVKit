#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_source="${1:-$repository_root/dist/libmpv-v0.41.0}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-subtitle-cache.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

python3 - "$native_source/demux/demux.c" "$temporary_root/cache.c" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
mkv_source = Path(sys.argv[1]).with_name('demux_mkv.c').read_text()
names = ['subtitle_cache_codec', 'subtitle_cache_packet_size', 'remove_subtitle_cache_head', 'clear_subtitle_cache',
         'cache_subtitle_packet', 'restore_cached_subtitles',
         'demux_stream_can_cache_subtitles', 'demux_stream_should_read',
         'seek_with_cues', 'subtitle_cache_seek_start', 'demux_subtitle_cache_generation',
         'demux_set_subtitle_cache_start']
functions = []
for name in names:
    function_source = mkv_source if name in ['seek_with_cues', 'subtitle_cache_seek_start'] else source
    match = re.search(r'(?:static )?(?:(?:bool|void|size_t|uint64_t|double) |struct mkv_index \*)' + name + r'\([^;]+?\n\{', function_source)
    if not match:
        raise RuntimeError('Missing production function: ' + name)
    end = match.end()
    depth = 1
    while depth:
        depth += (function_source[end] == '{') - (function_source[end] == '}')
        end += 1
    functions.append(function_source[match.start():end])
limits = '\n'.join(re.findall(r'^#define SUBTITLE_CACHE_MAX_.*$', source, re.M))
prefix = r'''
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MP_NOPTS_VALUE (-1e20)
#define MP_PTS_MAX(a, b) ((a) == MP_NOPTS_VALUE ? (b) : (b) == MP_NOPTS_VALUE ? (a) : fmax(a, b))
#define MP_PTS_MIN(a, b) ((a) == MP_NOPTS_VALUE ? (b) : (b) == MP_NOPTS_VALUE ? (a) : fmin(a, b))
#define MP_PTS_OR_DEF(a, b) ((a) == MP_NOPTS_VALUE ? (b) : (a))
#define MP_VERBOSE(...) ((void)0)
#define MPMAX(a, b) ((a) > (b) ? (a) : (b))
enum { STREAM_VIDEO, STREAM_AUDIO, STREAM_SUB };
enum { SEEK_FORWARD = 1, SEEK_FACTOR = 2, SEEK_HR = 4 };
struct demux_mkv_opts {
    int subtitle_preroll;
    double subtitle_preroll_secs, subtitle_preroll_secs_index;
};
struct mkv_index {
    int tnum;
    int64_t timecode, duration;
    uint64_t filepos;
};
struct mkv_demuxer {
    struct demux_mkv_opts *opts;
    bool index_has_durations, index_complete;
    uint64_t tc_scale, cluster_end;
    struct mkv_index *indexes;
    size_t num_indexes;
};
struct stream { uint64_t position; bool seek_succeeds; };
static bool stream_seek(struct stream *stream, uint64_t position) {
    if (!stream->seek_succeeds)
        return false;
    stream->position = position;
    return true;
}
struct AVBuffer { size_t size; };
struct AVPacket { struct AVBuffer *buf; };
struct demux_packet {
    struct demux_packet *next;
    int stream;
    double pts, dts, duration;
    bool segmented;
    size_t size, len;
    struct AVPacket *avpacket;
};
struct demux_queue { struct demux_packet *head, *tail; };
struct demux_stream;
struct sh_stream { struct demux_stream *ds; };
struct demux_internal {
    struct sh_stream **streams;
    int num_streams, lock;
    void *packet_pool;
    struct demux_packet *subtitle_cache_head, *subtitle_cache_tail;
    size_t subtitle_cache_bytes;
    int subtitle_cache_packets;
    uint64_t subtitle_cache_generation;
    double subtitle_cache_start, subtitle_cache_end;
    bool subtitle_cache_enabled, subtitle_cache_replaying, seeking, back_demuxing;
    double demux_ts;
    bool eof;
};
struct demuxer { struct demux_internal *in; void *priv; struct stream *stream; };
struct demux_stream {
    struct demux_internal *in;
    struct sh_stream *sh;
    struct demux_queue *queue;
    int index, type;
    bool selected, subtitle_cache_eligible, subtitle_cache_valid, refreshing;
    double subtitle_cache_pruned, base_ts;
};
static void mp_mutex_lock(int *lock) { assert(*lock == 0); *lock = 1; }
static void mp_mutex_unlock(int *lock) { assert(*lock == 1); *lock = 0; }
static int allocations;
static int copy_failure_countdown = -1;
static int queue_clears;
static size_t demux_packet_estimate_total_size(struct demux_packet *dp) { return dp->size; }
static struct demux_packet *demux_copy_packet(void *pool, struct demux_packet *dp) {
    if (copy_failure_countdown == 0)
        return NULL;
    if (copy_failure_countdown > 0)
        copy_failure_countdown--;
    struct demux_packet *copy = malloc(sizeof(*copy));
    assert(copy);
    *copy = *dp;
    copy->next = NULL;
    allocations++;
    return copy;
}
static void demux_packet_pool_push(void *pool, struct demux_packet *dp) {
    free(dp);
    allocations--;
}
static void demux_packet_pool_prepend(void *pool, struct demux_packet *head, struct demux_packet *tail) {
    while (head) {
        struct demux_packet *next = head->next;
        demux_packet_pool_push(pool, head);
        head = next;
    }
}
static void ds_clear_reader_queue_state(struct demux_stream *ds) {}
static void clear_queue(struct demux_queue *queue) {
    demux_packet_pool_prepend(NULL, queue->head, queue->tail);
    queue->head = queue->tail = NULL;
    queue_clears++;
}
static void add_packet_locked(struct sh_stream *stream, struct demux_packet *dp) {
    struct demux_queue *queue = stream->ds->queue;
    if (queue->tail)
        queue->tail->next = dp;
    else
        queue->head = dp;
    queue->tail = dp;
    stream->ds->in->demux_ts = dp->pts;
    stream->ds->in->eof = false;
}
'''
suffix = r'''
static void packet(struct demux_stream *ds, double pts, double duration, size_t size) {
    struct demux_packet dp = {.stream = ds->index, .pts = pts, .dts = pts,
                              .duration = duration, .size = size};
    cache_subtitle_packet(ds, &dp);
}
int main(void) {
    struct demux_internal in = {.subtitle_cache_enabled = true, .demux_ts = 200};
    struct demux_queue queues[3] = {0};
    struct sh_stream sh[3] = {0};
    struct sh_stream *streams[] = {sh, sh + 1, sh + 2};
    struct demux_stream ds[3] = {0};
    in.streams = streams;
    in.num_streams = 3;
    for (int n = 0; n < 3; n++) {
        ds[n] = (struct demux_stream){.in = &in, .sh = sh + n,
            .queue = queues + n, .index = n, .type = n ? STREAM_SUB : STREAM_VIDEO,
            .selected = n == 0, .subtitle_cache_eligible = n > 0, .base_ts = MP_NOPTS_VALUE};
        sh[n].ds = ds + n;
    }
    struct demux_mkv_opts opts = {.subtitle_preroll = 2,
        .subtitle_preroll_secs = 1.0, .subtitle_preroll_secs_index = 10.0};
    struct mkv_index indexes[] = {
        {.tnum = 1, .timecode = 0, .filepos = 100},
        {.tnum = 1, .timecode = 10000, .filepos = 200},
        {.tnum = 1, .timecode = 20000, .filepos = 300},
        {.tnum = 1, .timecode = 30000, .filepos = 400},
        {.tnum = 1, .timecode = 32000, .filepos = 420},
        {.tnum = 1, .timecode = 34000, .filepos = 440},
        {.tnum = 1, .timecode = 40000, .filepos = 500},
        {.tnum = 1, .timecode = 50000, .filepos = 600},
        {.tnum = 2, .timecode = 19000, .duration = 26000, .filepos = 290},
        {.tnum = 2, .timecode = 29000, .duration = 26000, .filepos = 390},
    };
    struct mkv_demuxer mkv = {.opts = &opts, .index_complete = true,
        .index_has_durations = true, .tc_scale = 1000000,
        .indexes = indexes, .num_indexes = sizeof(indexes) / sizeof(indexes[0])};
    struct stream stream = {.seek_succeeds = true};
    struct demuxer native_demuxer = {.priv = &mkv, .stream = &stream};
    bool seek_succeeded = false;
    for (int policy = 0; policy <= 2; policy++) {
        opts.subtitle_preroll = policy;
        struct mkv_index *index = seek_with_cues(&native_demuxer, 1,
            30000000000LL, 0, &seek_succeeded);
        assert(seek_succeeded && index == indexes + 3 && stream.position == 400);
        double floor = subtitle_cache_seek_start(&mkv, index, 1);
        assert(floor == 41.0 && opts.subtitle_preroll == policy);
        assert(opts.subtitle_preroll_secs == 1.0 && opts.subtitle_preroll_secs_index == 10.0);
        for (double reference = floor; reference <= 60; reference += 0.25) {
            seek_with_cues(&native_demuxer, 1,
                (int64_t)((reference - 1.0 + 0.005) * 1e9), SEEK_HR, &seek_succeeded);
            assert(seek_succeeded && stream.position >= 400);
        }
    }
    seek_with_cues(&native_demuxer, 1, 39005000000LL, SEEK_HR, &seek_succeeded);
    assert(seek_succeeded && stream.position < 400);
    mkv.index_has_durations = false;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == 33.0);
    mkv.index_has_durations = true;
    opts.subtitle_preroll_secs = 0.25;
    opts.subtitle_preroll_secs_index = 3.5;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == 35.0);
    assert(opts.subtitle_preroll_secs == 0.25 && opts.subtitle_preroll_secs_index == 3.5);
    opts.subtitle_preroll_secs = 0;
    opts.subtitle_preroll_secs_index = 0;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == 31.0);
    opts.subtitle_preroll_secs_index = DBL_MAX;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == MP_NOPTS_VALUE);
    opts.subtitle_preroll_secs = 1;
    opts.subtitle_preroll_secs_index = 10;
    assert(subtitle_cache_seek_start(&mkv, indexes + 7, 1) == MP_NOPTS_VALUE);
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 2) == MP_NOPTS_VALUE);
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, -1) == MP_NOPTS_VALUE);
    assert(subtitle_cache_seek_start(&mkv, NULL, 1) == MP_NOPTS_VALUE);
    struct mkv_index foreign_index = indexes[3];
    assert(subtitle_cache_seek_start(&mkv, &foreign_index, 1) == MP_NOPTS_VALUE);
    mkv.index_complete = false;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == MP_NOPTS_VALUE);
    mkv.index_complete = true;
    indexes[4].timecode = 29000;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == MP_NOPTS_VALUE);
    indexes[4].timecode = 32000;
    indexes[4].filepos = 399;
    assert(subtitle_cache_seek_start(&mkv, indexes + 3, 1) == MP_NOPTS_VALUE);
    indexes[4].filepos = 420;
    stream.seek_succeeds = false;
    seek_with_cues(&native_demuxer, 1, 30000000000LL, 0, &seek_succeeded);
    assert(!seek_succeeded);
    clear_subtitle_cache(&in, false);
    assert(demux_stream_can_cache_subtitles(sh + 1));
    assert(!demux_stream_can_cache_subtitles(sh));
    assert(!demux_stream_can_cache_subtitles(NULL));
    assert(!demux_stream_should_read(sh + 1));
    assert(demux_stream_should_read(sh));
    assert(!ds[1].selected);
    ds[1].subtitle_cache_valid = false;
    assert(!demux_stream_can_cache_subtitles(sh + 1));
    ds[1].subtitle_cache_valid = true;
    in.back_demuxing = true;
    assert(!demux_stream_can_cache_subtitles(sh + 1));
    in.back_demuxing = false;
    in.subtitle_cache_enabled = false;
    assert(!demux_stream_can_cache_subtitles(sh + 1));
    in.subtitle_cache_enabled = true;
    struct demuxer demuxer = {.in = &in};
    uint64_t generation = demux_subtitle_cache_generation(&demuxer);
    demux_set_subtitle_cache_start(&demuxer, 103, generation);
    assert(demux_stream_should_read(sh + 1));
    clear_subtitle_cache(&in, false);
    demux_set_subtitle_cache_start(&demuxer, 103, generation);
    assert(in.subtitle_cache_start == MP_NOPTS_VALUE);
    generation = demux_subtitle_cache_generation(&demuxer);
    in.subtitle_cache_generation++;
    demux_set_subtitle_cache_start(&demuxer, 103, generation);
    assert(in.subtitle_cache_start == MP_NOPTS_VALUE);
    generation = demux_subtitle_cache_generation(&demuxer);
    demux_set_subtitle_cache_start(&demuxer, 103, generation);
    assert(demux_stream_should_read(sh + 1));
    assert(!ds[1].selected && in.lock == 0);
    clear_subtitle_cache(&in, true);
    assert(subtitle_cache_codec("ass") && subtitle_cache_codec("subrip"));
    assert(!subtitle_cache_codec("hdmv_pgs_subtitle") && !subtitle_cache_codec("eia_608"));
    assert(!subtitle_cache_codec(NULL));
    struct AVBuffer buffer = {.size = SUBTITLE_CACHE_MAX_BYTES + 10};
    struct AVPacket avpacket = {.buf = &buffer};
    struct demux_packet slice = {.size = 100, .len = 10, .avpacket = &avpacket};
    assert(subtitle_cache_packet_size(&slice) > SUBTITLE_CACHE_MAX_BYTES);
    packet(ds, 200, 1, 16);
    packet(ds + 1, 0, 180, 100);
    packet(ds + 1, 45, 15, 100);
    in.eof = true;
    assert(restore_cached_subtitles(ds + 1, 50));
    assert(queues[1].head->pts == 0 && queues[1].head->next->pts == 45);
    assert(in.demux_ts == 200 && in.eof);
    assert(!queues[0].head);
    assert(restore_cached_subtitles(ds + 2, 50));
    assert(!queues[2].head);
    int before_clears = queue_clears;
    struct demux_packet *before = queues[1].head;
    copy_failure_countdown = 1;
    assert(!restore_cached_subtitles(ds + 1, 50));
    assert(queue_clears == before_clears && queues[1].head == before);
    copy_failure_countdown = -1;
    assert(restore_cached_subtitles(ds + 1, -10));
    in.seeking = true;
    assert(!restore_cached_subtitles(ds + 1, 50));
    in.seeking = false;
    in.back_demuxing = true;
    assert(!restore_cached_subtitles(ds + 1, 50));
    in.back_demuxing = false;
    assert(!restore_cached_subtitles(ds, 50));
    clear_subtitle_cache(&in, false);
    packet(ds + 1, 110, 20, 100);
    assert(!in.subtitle_cache_head);
    assert(!restore_cached_subtitles(ds + 1, 120));
    in.subtitle_cache_start = 103;
    packet(ds, 170, 1, 16);
    packet(ds + 1, 105, 55, 100);
    assert(!restore_cached_subtitles(ds + 1, 102));
    assert(restore_cached_subtitles(ds + 1, 131));
    assert(queues[1].head->pts == 105);
    ds[0].base_ts = 102;
    assert(!restore_cached_subtitles(ds + 1, 131));
    ds[0].base_ts = 135;
    ds[1].refreshing = true;
    assert(!restore_cached_subtitles(ds + 1, 131));
    ds[1].refreshing = false;
    assert(restore_cached_subtitles(ds + 1, 131));
    ds[0].base_ts = MP_NOPTS_VALUE;
    clear_subtitle_cache(&in, true);
    packet(ds, 10000, 1, 16);
    for (int n = 0; n < SUBTITLE_CACHE_MAX_PACKETS + 5; n++)
        packet(ds + 1, n, 1, 32);
    assert(in.subtitle_cache_packets == SUBTITLE_CACHE_MAX_PACKETS);
    assert(in.subtitle_cache_bytes <= SUBTITLE_CACHE_MAX_BYTES);
    assert(!restore_cached_subtitles(ds + 1, 5));
    assert(restore_cached_subtitles(ds + 1, 10));
    clear_subtitle_cache(&in, true);
    packet(ds, 200, 1, 16);
    for (int n = 0; n < 5; n++)
        packet(ds + 1, n, 180, SUBTITLE_CACHE_MAX_BYTES / 2);
    assert(in.subtitle_cache_packets == 2);
    assert(in.subtitle_cache_bytes == SUBTITLE_CACHE_MAX_BYTES);
    assert(!restore_cached_subtitles(ds + 1, 50));
    assert(restore_cached_subtitles(ds + 2, 50));
    packet(ds + 1, 40, 1, SUBTITLE_CACHE_MAX_BYTES + 1);
    assert(!restore_cached_subtitles(ds + 1, 190));
    clear_subtitle_cache(&in, true);
    packet(ds, 200, 1, 16);
    packet(ds + 1, NAN, 1, 100);
    assert(!restore_cached_subtitles(ds + 1, 50));
    clear_subtitle_cache(&in, true);
    packet(ds, 200, 1, 16);
    packet(ds + 1, 40, -1, 100);
    assert(!restore_cached_subtitles(ds + 1, 50));
    clear_subtitle_cache(&in, true);
    packet(ds + 1, 40, 20, 100);
    struct demux_packet segmented = {.stream = 0, .pts = 200, .segmented = true};
    cache_subtitle_packet(ds, &segmented);
    assert(!in.subtitle_cache_head && in.subtitle_cache_start == MP_NOPTS_VALUE);
    clear_subtitle_cache(&in, false);
    for (int n = 0; n < 3; n++)
        clear_queue(queues + n);
    assert(allocations == 0);
    puts("Subtitle cache: ordinary seek position preservation, actual cue/preroll equivalence with crossing long cues, settings/windows, incomplete/malformed index rejection, cold eligibility and stale seek authority, OFF selection preservation, overlapping and sparse cues, early playback, certified seek coverage, transactional replay failure, byte/entry eviction, long-cue eviction, malformed packets, backward/seek fallback and cleanup passed.");
    return 0;
}
'''
Path(sys.argv[2]).write_text(prefix + limits + '\n' + '\n'.join(functions) + suffix)
PY

xcrun --sdk macosx clang -fsanitize=address,undefined \
    "$temporary_root/cache.c" -o "$temporary_root/cache"
"$temporary_root/cache"
