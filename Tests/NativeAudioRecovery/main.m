#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mpv/client.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSLock *captureLock;
static IMP originalRendererInit;
static AVSampleBufferAudioRenderer *latestRenderer;
static NSUInteger rendererCreations;
static int recoveryRequests;
static int positionRefreshes;
static NSUInteger fileStartGeneration;
static NSUInteger fileLoadedGeneration;
static NSUInteger validatedVideoGeneration;

static id captureRendererInit(id object, SEL selector)
{
    id renderer = ((id (*)(id, SEL))originalRendererInit)(object, selector);
    if (renderer) {
        [captureLock lock];
        AVSampleBufferAudioRenderer *previous = latestRenderer;
        latestRenderer = [renderer retain];
        rendererCreations++;
        [captureLock unlock];
        [previous release];
    }
    return renderer;
}

static AVSampleBufferAudioRenderer *copyRenderer(NSUInteger *creations)
{
    [captureLock lock];
    AVSampleBufferAudioRenderer *renderer = [latestRenderer retain];
    *creations = rendererCreations;
    [captureLock unlock];
    return renderer;
}

static void expire(int signalNumber)
{
    const char message[] = "FAIL: native audio recovery exceeded 45 seconds\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void drainEvents(mpv_handle *mpv)
{
    for (int index = 0; index < 128; index++) {
        mpv_event *event = mpv_wait_event(mpv, 0);
        if (event->event_id == MPV_EVENT_NONE)
            return;
        if (event->event_id == MPV_EVENT_START_FILE)
            fileStartGeneration++;
        if (event->event_id == MPV_EVENT_FILE_LOADED)
            fileLoadedGeneration = fileStartGeneration;
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            if (strstr(log->text, "requesting synchronized audio output recovery"))
                recoveryRequests++;
            if (strstr(log->text, "preserving playback position during AVFoundation recovery"))
                positionRefreshes++;
            if (strstr(log->prefix, "avfoundation"))
                fprintf(stderr, "mpv[%s] %s", log->prefix, log->text);
        }
    }
}

static void pump(mpv_handle *mpv, double duration)
{
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + duration;
    do {
        drainEvents(mpv);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        usleep(1000);
    } while (CFAbsoluteTimeGetCurrent() < deadline);
}

static double position(mpv_handle *mpv)
{
    double value = NAN;
    mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &value);
    return value;
}

static double numberProperty(mpv_handle *mpv, const char *name)
{
    double value = NAN;
    mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value);
    return value;
}

static int paused(mpv_handle *mpv)
{
    int value = -1;
    mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &value);
    return value;
}

static void require(BOOL condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void requireFixturePlayback(mpv_handle *mpv, const char *path,
                                   NSUInteger expectedGeneration, BOOL hasVideo)
{
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 8;
    while ((fileLoadedGeneration != expectedGeneration
            || !isfinite(position(mpv)) || position(mpv) < 0.75
            || !isfinite(numberProperty(mpv, "audio-pts"))
            || (hasVideo && !isfinite(numberProperty(mpv, "avsync"))))
           && CFAbsoluteTimeGetCurrent() < deadline) {
        pump(mpv, 0.05);
        require(fileStartGeneration <= expectedGeneration, "a different file superseded the requested fixture");
    }
    require(fileStartGeneration == expectedGeneration && fileLoadedGeneration == expectedGeneration,
            "requested fixture did not finish its own load generation");
    char *loadedPath = mpv_get_property_string(mpv, "path");
    require(loadedPath && strcmp(loadedPath, path) == 0,
            "playback properties did not belong to the requested fixture");
    mpv_free(loadedPath);
    require(paused(mpv) == 0 && isfinite(position(mpv)) && position(mpv) >= 0.75
            && isfinite(numberProperty(mpv, "audio-pts"))
            && (!hasVideo || isfinite(numberProperty(mpv, "avsync"))),
            "requested fixture did not begin active playback after FILE_LOADED");
}

static void requireFixtureTrackSamples(AVAsset *asset, AVAssetTrack *track,
                                       double duration, BOOL video)
{
    double trackStart = CMTimeGetSeconds(track.timeRange.start);
    double trackDuration = CMTimeGetSeconds(track.timeRange.duration);
    require(isfinite(trackStart) && fabs(trackStart) <= 0.05
            && isfinite(trackDuration) && trackDuration >= 15
            && fabs(trackDuration - duration) <= 0.05,
            "restricted A/V fixture tracks must start together and span the full duration");
    double cadence = video ? 1.0 / track.nominalFrameRate : 0;
    require(!video || (isfinite(cadence) && cadence > 0 && cadence <= 0.05),
            "restricted video fixture must have a constant cadence of at least 20 fps");
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    require(reader != nil, "could not create a reader for the restricted A/V fixture");
    NSDictionary *settings = video ? @{(NSString *)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)} : @{AVFormatIDKey: @(kAudioFormatLinearPCM)};
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    require([reader canAddOutput:output], "restricted A/V fixture track could not be read");
    [reader addOutput:output];
    require([reader startReading], "restricted A/V fixture reader did not start");
    double firstPTS = NAN;
    double previousPTS = NAN;
    double endPTS = NAN;
    NSUInteger sampleCount = 0;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        double sampleDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample));
        require(isfinite(pts), "restricted A/V fixture contains an invalid sample timestamp");
        if (sampleCount == 0) {
            firstPTS = pts;
            require(fabs(firstPTS) <= 0.05, "restricted A/V fixture samples do not start near zero");
        } else {
            double step = pts - previousPTS;
            require(step > 0, "restricted A/V fixture timestamps must advance");
            require(!video || fabs(step - cadence) <= fmax(0.0005, cadence * 0.01),
                    "restricted video fixture has sparse samples or a variable cadence");
            require(video || pts <= endPTS + 0.05,
                    "restricted audio fixture contains a timeline gap");
        }
        if (video && (!isfinite(sampleDuration) || sampleDuration <= 0))
            sampleDuration = cadence;
        require(isfinite(sampleDuration) && sampleDuration > 0,
                "restricted A/V fixture contains an invalid sample duration");
        previousPTS = pts;
        endPTS = pts + sampleDuration;
        sampleCount++;
        CFRelease(sample);
    }
    require(reader.status == AVAssetReaderStatusCompleted && sampleCount > 1,
            "restricted A/V fixture did not decode completely");
    require(isfinite(endPTS) && endPTS - firstPTS >= 15
            && fabs(endPTS - duration) <= 0.05,
            "restricted A/V fixture samples do not cover the full duration");
    fprintf(stderr, "validated %s fixture: samples=%lu start=%.6f end=%.6f cadence=%.6f\n",
            video ? "video" : "audio", (unsigned long)sampleCount, firstPTS, endPTS, cadence);
    [output release];
    [reader release];
}

static void requireRestrictedVideoFixture(const char *path)
{
    NSString *fixturePath = [NSString stringWithUTF8String:path];
    require(fixturePath != nil, "restricted A/V fixture path is invalid");
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:fixturePath] options:nil];
    double duration = CMTimeGetSeconds(asset.duration);
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    require(asset.playable && isfinite(duration) && duration >= 15
            && videoTracks.count == 1 && audioTracks.count == 1,
            "restricted A/V fixture requires one audio and one video track lasting at least 15 seconds");
    requireFixtureTrackSamples(asset, videoTracks.firstObject, duration, YES);
    requireFixtureTrackSamples(asset, audioTracks.firstObject, duration, NO);
    [asset release];
}

static void requireActiveVideoFixture(mpv_handle *mpv)
{
    require(fileStartGeneration == validatedVideoGeneration
            && fileLoadedGeneration == validatedVideoGeneration,
            "video-backed playback position belongs to a different load generation");
    double playbackPosition = position(mpv);
    require(isfinite(playbackPosition) && playbackPosition < 14,
            "restricted video clock checks must remain within the validated first 15 seconds");
    int64_t trackCount = 0;
    require(mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &trackCount) >= 0,
            "video fixture track list is unavailable");
    BOOL selectedVideo = NO;
    for (int64_t index = 0; index < trackCount; index++) {
        char property[80];
        snprintf(property, sizeof(property), "track-list/%lld/type", (long long)index);
        char *type = mpv_get_property_string(mpv, property);
        BOOL video = type && strcmp(type, "video") == 0;
        mpv_free(type);
        if (!video)
            continue;
        int selected = 0;
        int image = 1;
        int albumArt = 1;
        snprintf(property, sizeof(property), "track-list/%lld/selected", (long long)index);
        require(mpv_get_property(mpv, property, MPV_FORMAT_FLAG, &selected) >= 0,
                "video fixture selection is unavailable");
        if (!selected)
            continue;
        snprintf(property, sizeof(property), "track-list/%lld/image", (long long)index);
        require(mpv_get_property(mpv, property, MPV_FORMAT_FLAG, &image) >= 0,
                "video fixture image classification is unavailable");
        snprintf(property, sizeof(property), "track-list/%lld/albumart", (long long)index);
        require(mpv_get_property(mpv, property, MPV_FORMAT_FLAG, &albumArt) >= 0,
                "video fixture cover-art classification is unavailable");
        require(!image && !albumArt, "video-backed playback position cannot use a sparse image track");
        selectedVideo = YES;
    }
    require(selectedVideo, "restricted fixture lost its selected continuous video track");
}

static void requireVideoSynchronization(mpv_handle *mpv, const char *stage)
{
    requireActiveVideoFixture(mpv);
    double firstVideoBackedPosition = position(mpv);
    double firstAudioPosition = numberProperty(mpv, "audio-pts");
    double maximumDifference = 0;
    double maximumReportedDifference = 0;
    require(isfinite(firstVideoBackedPosition) && isfinite(firstAudioPosition),
            "video fixture did not expose both playback clocks");
    for (int sample = 0; sample < 12; sample++) {
        pump(mpv, 0.08);
        requireActiveVideoFixture(mpv);
        double videoBackedPosition = position(mpv);
        double audioPosition = numberProperty(mpv, "audio-pts");
        double reportedDifference = numberProperty(mpv, "avsync");
        require(paused(mpv) == 0, "video recovery changed playing intent");
        require(isfinite(videoBackedPosition) && isfinite(audioPosition) && isfinite(reportedDifference),
                "video recovery lost a playback clock or A/V synchronization state");
        maximumDifference = fmax(maximumDifference, fabs(videoBackedPosition - audioPosition));
        maximumReportedDifference = fmax(maximumReportedDifference, fabs(reportedDifference));
        require(maximumDifference < 0.16, "audio and video playback clocks diverged after recovery");
        require(maximumReportedDifference < 0.12, "mpv reported persistent A/V desynchronization after recovery");
    }
    require(position(mpv) >= firstVideoBackedPosition + 0.5
            && numberProperty(mpv, "audio-pts") >= firstAudioPosition + 0.5,
            "synchronized playback clocks did not both advance after recovery");
    fprintf(stderr, "%s: videoBackedPlaybackPosition=%.6f audioPosition=%.6f maxDifferenceMs=%.3f maxReportedAvsyncMs=%.3f\n",
            stage, position(mpv), numberProperty(mpv, "audio-pts"),
            maximumDifference * 1000, maximumReportedDifference * 1000);
}

static void requirePlayingRecovery(mpv_handle *mpv, NSString *notificationName,
                                   BOOL flushRenderer, BOOL hasVideo)
{
    pump(mpv, 0.15);
    double initialPosition = position(mpv);
    double initialAudioPosition = numberProperty(mpv, "audio-pts");
    require(paused(mpv) == 0 && isfinite(initialPosition) && isfinite(initialAudioPosition),
            "playing recovery did not begin with active audio playback");
    NSUInteger initialCreations = 0;
    AVSampleBufferAudioRenderer *renderer = copyRenderer(&initialCreations);
    require(renderer != nil, "could not capture playing AVFoundation renderer");
    int initialRecoveries = recoveryRequests;
    int initialRefreshes = positionRefreshes;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    if (flushRenderer)
        [renderer flush];
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:renderer];
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:renderer];

    CFAbsoluteTime deadline = started + 5;
    NSUInteger updatedCreations = initialCreations;
    do {
        pump(mpv, 0.05);
        AVSampleBufferAudioRenderer *current = copyRenderer(&updatedCreations);
        [current release];
        require(paused(mpv) == 0, "playing audio recovery changed pause intent");
    } while (updatedCreations == initialCreations && CFAbsoluteTimeGetCurrent() < deadline);
    require(updatedCreations > initialCreations, "playing recovery did not rebuild audio output");
    pump(mpv, 0.35);
    require(recoveryRequests == initialRecoveries + 1, "playing duplicate notifications were not coalesced");
    require(positionRefreshes == initialRefreshes + 1, "playing recovery did not refresh the synchronized position");
    double recoveredPosition = position(mpv);
    double recoveredAudioPosition = numberProperty(mpv, "audio-pts");
    double elapsed = CFAbsoluteTimeGetCurrent() - started;
    require(paused(mpv) == 0 && isfinite(recoveredPosition) && isfinite(recoveredAudioPosition),
            "playing recovery did not restore active playback clocks");
    require(recoveredPosition >= initialPosition - 0.25
            && recoveredPosition <= initialPosition + elapsed + 0.5,
            "playing recovery displaced the playback position");
    require(recoveredAudioPosition >= initialAudioPosition - 0.25
            && recoveredAudioPosition <= initialAudioPosition + elapsed + 0.5,
            "playing recovery displaced the audio playback clock");

    [[NSNotificationCenter defaultCenter]
        postNotificationName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:renderer];
    if (@available(iOS 15.0, tvOS 15.0, macOS 12.0, *)) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification object:renderer];
    }
    [renderer release];
    pump(mpv, 0.15);
    AVSampleBufferAudioRenderer *current = copyRenderer(&updatedCreations);
    [current release];
    require(updatedCreations == initialCreations + 1
            && recoveryRequests == initialRecoveries + 1
            && positionRefreshes == initialRefreshes + 1,
            "retired playing output accepted a stale notification");
    require(paused(mpv) == 0, "stale notification changed playing intent");

    deadline = CFAbsoluteTimeGetCurrent() + 3;
    while ((!isfinite(position(mpv)) || position(mpv) < recoveredPosition + 0.75)
           && CFAbsoluteTimeGetCurrent() < deadline) {
        pump(mpv, 0.05);
        require(paused(mpv) == 0, "recovered playback stopped playing");
    }
    require(isfinite(position(mpv)) && position(mpv) >= recoveredPosition + 0.75
            && numberProperty(mpv, "audio-pts") >= recoveredAudioPosition + 0.5,
            "playing recovery did not resume audio and timeline advancement");
    fprintf(stderr, "playing recovery %s: before=%.6f recovered=%.6f advanced=%.6f audio=%.6f pause=%d rendererCreations=%lu->%lu\n",
            notificationName.UTF8String, initialPosition, recoveredPosition, position(mpv),
            numberProperty(mpv, "audio-pts"), paused(mpv),
            (unsigned long)initialCreations, (unsigned long)updatedCreations);
    if (hasVideo)
        requireVideoSynchronization(mpv, notificationName.UTF8String);
}

int main(int argc, char **argv)
{
    signal(SIGALRM, expire);
    alarm(45);
    @autoreleasepool {
        require(argc == 2 || argc == 3, "expected a local audio fixture and optional video fixture path");
        captureLock = [[NSLock alloc] init];
        Class rendererClass = AVSampleBufferAudioRenderer.class;
        Method initMethod = class_getInstanceMethod(rendererClass, @selector(init));
        require(initMethod != NULL, "audio renderer initializer is unavailable");
        originalRendererInit = method_getImplementation(initMethod);
        class_replaceMethod(rendererClass, @selector(init), (IMP)captureRendererInit,
                            method_getTypeEncoding(initMethod));

        mpv_handle *mpv = mpv_create();
        require(mpv != NULL, "mpv_create failed");
        const char *options[][2] = {
            {"terminal", "no"}, {"vo", "null"}, {"vid", "no"},
            {"ao", "avfoundation"}, {"audio-display", "no"},
            {"idle", "yes"}, {"keep-open", "yes"}, {"volume", "0"}
        };
        for (size_t index = 0; index < sizeof(options) / sizeof(options[0]); index++)
            require(mpv_set_option_string(mpv, options[index][0], options[index][1]) >= 0,
                    "mpv rejected a harness option");
        require(mpv_initialize(mpv) >= 0, "mpv initialization failed");
        mpv_request_log_messages(mpv, "v");
        drainEvents(mpv);
        NSUInteger audioGeneration = fileStartGeneration + 1;
        const char *load[] = {"loadfile", argv[1], NULL};
        require(mpv_command(mpv, load) >= 0, "mpv rejected local fixture");
        requireFixturePlayback(mpv, argv[1], audioGeneration, NO);
        char *audioOutput = mpv_get_property_string(mpv, "current-ao");
        require(audioOutput && strcmp(audioOutput, "avfoundation") == 0,
                "fixture did not use real AVFoundation audio output");
        mpv_free(audioOutput);

        int pauseFlag = 1;
        require(mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag) >= 0,
                "could not pause playback");
        pump(mpv, 0.25);
        double pausedPosition = position(mpv);
        require(paused(mpv) == 1 && isfinite(pausedPosition), "pause did not settle");
        NSUInteger initialCreations = 0;
        AVSampleBufferAudioRenderer *renderer = copyRenderer(&initialCreations);
        require(renderer != nil, "could not capture actual AVFoundation renderer");
        int initialRecoveries = recoveryRequests;
        int initialRefreshes = positionRefreshes;
        [renderer flush];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
            object:renderer];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
            object:renderer];

        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5;
        NSUInteger updatedCreations = initialCreations;
        do {
            pump(mpv, 0.05);
            AVSampleBufferAudioRenderer *current = copyRenderer(&updatedCreations);
            [current release];
            require(paused(mpv) == 1, "audio recovery changed pause intent");
        } while (updatedCreations == initialCreations && CFAbsoluteTimeGetCurrent() < deadline);
        pump(mpv, 0.5);
        require(updatedCreations > initialCreations, "mpv core did not rebuild audio output");
        require(recoveryRequests == initialRecoveries + 1, "duplicate notifications were not coalesced");
        require(positionRefreshes == initialRefreshes + 1, "seekable recovery did not preserve the original position");
        double recoveredPosition = position(mpv);
        BOOL pausedPositionRestored = paused(mpv) == 1 && isfinite(recoveredPosition)
            && fabs(recoveredPosition - pausedPosition) < 0.25;
        fprintf(stderr, "paused recovery: before=%.6f after=%.6f pause=%d rendererCreations=%lu->%lu recoveryRequests=%d->%d\n",
                pausedPosition, recoveredPosition, paused(mpv), (unsigned long)initialCreations,
                (unsigned long)updatedCreations, initialRecoveries, recoveryRequests);

        [[NSNotificationCenter defaultCenter]
            postNotificationName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
            object:renderer];
        [renderer release];
        pump(mpv, 0.1);
        require(recoveryRequests == initialRecoveries + 1, "retired output accepted a stale notification");

        pauseFlag = 0;
        require(mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag) >= 0,
                "could not resume playback");
        deadline = CFAbsoluteTimeGetCurrent() + 5;
        while ((!isfinite(position(mpv)) || position(mpv) < pausedPosition + 0.75)
               && CFAbsoluteTimeGetCurrent() < deadline)
            pump(mpv, 0.05);
        fprintf(stderr, "resumed recovery: position=%.6f pause=%d\n", position(mpv), paused(mpv));
        require(paused(mpv) == 0 && isfinite(position(mpv))
                && position(mpv) >= pausedPosition + 0.75,
                "audio playback did not advance after recovery and resume");
        require(pausedPositionRestored, "paused recovery advanced or displaced playback");
        requirePlayingRecovery(mpv, AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification, YES, NO);
        if (@available(iOS 15.0, tvOS 15.0, macOS 12.0, *)) {
            requirePlayingRecovery(mpv, AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification, NO, NO);
        } else {
            require(NO, "output-configuration recovery coverage requires iOS/tvOS 15 or macOS 12");
        }
        if (argc == 3) {
            requireRestrictedVideoFixture(argv[2]);
            require(mpv_set_property_string(mpv, "vid", "auto") >= 0
                    && mpv_set_property_string(mpv, "hwdec", "no") >= 0,
                    "could not enable deterministic video decoding for the optional fixture");
            drainEvents(mpv);
            validatedVideoGeneration = fileStartGeneration + 1;
            const char *videoLoad[] = {"loadfile", argv[2], NULL};
            require(mpv_command(mpv, videoLoad) >= 0, "mpv rejected the optional video fixture");
            requireFixturePlayback(mpv, argv[2], validatedVideoGeneration, YES);
            char *videoFormat = mpv_get_property_string(mpv, "video-format");
            require(videoFormat && videoFormat[0], "optional video fixture did not decode a video track");
            mpv_free(videoFormat);
            requireVideoSynchronization(mpv, "video baseline");
            requirePlayingRecovery(mpv, AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification, YES, YES);
            if (@available(iOS 15.0, tvOS 15.0, macOS 12.0, *)) {
                requirePlayingRecovery(mpv, AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification, NO, YES);
            }
        }
        printf("PASS: real libmpv AVFoundation output rebuilt while paused and playing; automatic flush and output-configuration recovery preserved playback, coalesced duplicates and rejected stale notifications%s.\n",
               argc == 3 ? "; restricted continuous A/V fixture audio and video-backed playback position advanced in sync" : "");
        mpv_terminate_destroy(mpv);
        class_replaceMethod(rendererClass, @selector(init), originalRendererInit,
                            method_getTypeEncoding(initMethod));
        [latestRenderer release];
        latestRenderer = nil;
        [captureLock release];
        alarm(0);
    }
    return 0;
}
