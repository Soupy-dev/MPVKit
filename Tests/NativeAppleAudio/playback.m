#import <Foundation/Foundation.h>
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
static AVSampleBufferAudioRenderer *latestRenderer;
static NSLock *rendererLock;
static AVSampleBufferAudioRenderer *forcedFailureRenderer;
@interface AVSampleBufferAudioRenderer (AudioTestCapture)
- (id)audioTestInit;
- (AVQueuedSampleBufferRenderingStatus)audioTestStatus;
@end
@implementation AVSampleBufferAudioRenderer (AudioTestCapture)
- (AVQueuedSampleBufferRenderingStatus)audioTestStatus {
    [rendererLock lock];
    BOOL failed = self == forcedFailureRenderer;
    [rendererLock unlock];
    return failed ? AVQueuedSampleBufferRenderingStatusFailed : [self audioTestStatus];
}
- (id)audioTestInit {
    id result = [self audioTestInit];
    [rendererLock lock];
    [latestRenderer release];
    latestRenderer = [result retain];
    [rendererLock unlock];
    return result;
}
@end
static void routeChange(NSString *name) {
    [rendererLock lock];
    id renderer = [latestRenderer retain];
    [rendererLock unlock];
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:renderer];
    [renderer release];
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void fail(const char *name,int code) { fprintf(stderr,"FAIL %s %d\n",name,code); exit(1); }
static void opt(mpv_handle *m,const char *k,const char *v) { int e=mpv_set_option_string(m,k,v); if(e<0)fail(k,e); }
static void set(mpv_handle *m,const char *k,const char *v) { int e=mpv_set_property_string(m,k,v); if(e<0)fail(k,e); }
static void cmd(mpv_handle *m,const char **v) { int e=mpv_command(m,v); if(e<0)fail(v[0],e); }
static void pump(mpv_handle *m,double duration) { double end=now()+duration; do { mpv_event *e=mpv_wait_event(m,0.02); if(e->event_id==MPV_EVENT_LOG_MESSAGE) { mpv_event_log_message *l=e->data; printf("[%s:%s] %s",l->prefix,l->level,l->text); } if(e->event_id==MPV_EVENT_END_FILE)printf("end-file %d\n",((mpv_event_end_file*)e->data)->reason); }while(now()<end); }
static double pos(mpv_handle*m) { double t=-1; mpv_get_property(m,"time-pos",MPV_FORMAT_DOUBLE,&t); return t; }
static void state(mpv_handle*m,const char*label) { const char *names[]={"current-ao","audio-codec-name","audio-params/format","audio-out-params/format","audio-out-params/channels","audio-out-params/samplerate","pause","speed",NULL}; printf("STATE %s t=%.3f",label,pos(m)); for(int i=0;names[i];i++) { char*s=mpv_get_property_string(m,names[i]);printf(" %s=%s",names[i],s?s:"NULL");mpv_free(s); } puts("");fflush(stdout); }
static void format(mpv_handle*m,int compressed) { char*s=mpv_get_property_string(m,"audio-out-params/format"); int ok=s && ((strstr(s,"spdif")!=NULL)==compressed); if(!ok){fprintf(stderr,"format expected=%d actual=%s\n",compressed,s?s:"NULL");fail("format",0);} mpv_free(s); }
int main(int argc,char**argv) { @autoreleasepool { if(argc<2)return 2;int compressed=argc==2;rendererLock=[NSLock new];Method originalInit=class_getInstanceMethod(AVSampleBufferAudioRenderer.class,@selector(init));class_addMethod(AVSampleBufferAudioRenderer.class,@selector(init),method_getImplementation(originalInit),method_getTypeEncoding(originalInit));method_exchangeImplementations(class_getInstanceMethod(AVSampleBufferAudioRenderer.class,@selector(init)),class_getInstanceMethod(AVSampleBufferAudioRenderer.class,@selector(audioTestInit)));Method originalStatus=class_getInstanceMethod(AVSampleBufferAudioRenderer.class,@selector(status));class_addMethod(AVSampleBufferAudioRenderer.class,@selector(status),method_getImplementation(originalStatus),method_getTypeEncoding(originalStatus));method_exchangeImplementations(class_getInstanceMethod(AVSampleBufferAudioRenderer.class,@selector(status)),class_getInstanceMethod(AVSampleBufferAudioRenderer.class,@selector(audioTestStatus)));printf("bundle=%s\n",NSBundle.mainBundle.bundleIdentifier.UTF8String);mpv_handle*m=mpv_create();if(!m)return 3;opt(m,"config","no");opt(m,"idle","yes");opt(m,"keep-open","yes");opt(m,"vo","null");opt(m,"vid","no");opt(m,"ao","avfoundation,coreaudio");opt(m,"apple-compressed-audio","yes");opt(m,"audio-spdif","eac3");opt(m,"audio-channels","auto");opt(m,"mute","yes");opt(m,"pause","yes");opt(m,"terminal","no"); if(mpv_initialize(m)<0)return 4;mpv_request_log_messages(m,"v");const char*load[]={"loadfile",argv[1],NULL};cmd(m,load);pump(m,2);state(m,"loaded");format(m,compressed);double start=pos(m);set(m,"pause","no");pump(m,1.5);state(m,"playing");double p=pos(m);if(p<start+0.8)fail("clock",0);if(compressed){[rendererLock lock];forcedFailureRenderer=[latestRenderer retain];[rendererLock unlock];const char*refresh[]={"seek","0","relative+exact",NULL};cmd(m,refresh);pump(m,1);state(m,"forced-renderer-failure");format(m,0);[rendererLock lock];[forcedFailureRenderer release];forcedFailureRenderer=nil;[rendererLock unlock];set(m,"speed","1.5");pump(m,.2);set(m,"speed","1");pump(m,.5);format(m,1);}set(m,"pause","yes");pump(m,0.2);p=pos(m);pump(m,0.5);if(fabs(pos(m)-p)>.08)fail("pause",0);char seekTarget[40];snprintf(seekTarget,sizeof(seekTarget),"%.6f",start+4);const char*seek[]={"seek",seekTarget,"absolute+exact",NULL};cmd(m,seek);pump(m,1);state(m,"seek-paused");routeChange(AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification);pump(m,0.5);state(m,"flush-paused");if(fabs(pos(m)-start-4)>.08)fail("seek",0);set(m,"pause","no");set(m,"speed","1.5");pump(m,1);state(m,"speed");format(m,0);set(m,"speed","1");pump(m,0.7);state(m,"speed-reset");format(m,compressed);set(m,"af","lavfi=[volume=0.5]");pump(m,0.7);state(m,"filter");format(m,0);set(m,"af","");pump(m,0.7);state(m,"filter-reset");format(m,compressed);set(m,"audio-channels","stereo");pump(m,0.7);state(m,"stereo");format(m,0);set(m,"audio-channels","auto");pump(m,0.7);state(m,"surround-reset");format(m,compressed);double beforeRoute=pos(m);routeChange(AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification);pump(m,0.7);state(m,"route-recovery");format(m,compressed);if(pos(m)<beforeRoute-.08)fail("route-clock",0);const char*stop[]={"stop",NULL};cmd(m,stop);pump(m,0.3);set(m,"pause","yes");cmd(m,load);pump(m,1);state(m,"reload");format(m,compressed);snprintf(seekTarget,sizeof(seekTarget),"%.6f",start+10.5);cmd(m,seek);set(m,"pause","no");pump(m,3);int eof=0;mpv_get_property(m,"eof-reached",MPV_FORMAT_FLAG,&eof);if(!eof)fail("eof",0);mpv_terminate_destroy(m);[latestRenderer release];latestRenderer=nil;[rendererLock release];puts("PASS native Apple audio playback, clock, pause, seek, speed, filter, stereo, route recovery, flush, reload and EOF");return 0;}}
