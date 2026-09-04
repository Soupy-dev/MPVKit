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
    const char message[] = "FAIL: native audio recovery exceeded 25 seconds\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void drainEvents(mpv_handle *mpv)
{
    for (int index = 0; index < 128; index++) {
        mpv_event *event = mpv_wait_event(mpv, 0);
        if (event->event_id == MPV_EVENT_NONE)
            return;
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

int main(int argc, char **argv)
{
    signal(SIGALRM, expire);
    alarm(25);
    @autoreleasepool {
        require(argc == 2, "expected a local audio fixture path");
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
        const char *load[] = {"loadfile", argv[1], NULL};
        require(mpv_command(mpv, load) >= 0, "mpv rejected local fixture");

        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 8;
        while ((!isfinite(position(mpv)) || position(mpv) < 0.75)
               && CFAbsoluteTimeGetCurrent() < deadline)
            pump(mpv, 0.05);
        require(isfinite(position(mpv)) && position(mpv) >= 0.75,
                "actual audio playback did not advance");
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

        deadline = CFAbsoluteTimeGetCurrent() + 5;
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
        printf("PASS: real libmpv AVFoundation output rebuilt while paused; position %.3f -> %.3f after resume; duplicate and stale notifications ignored.\n",
               pausedPosition, position(mpv));
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
