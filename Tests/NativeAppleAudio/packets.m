#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include "audio/out/ao_avfoundation_eac3.h"
static void invalidInputs(const uint8_t *original) {
 struct mpv_apple_eac3_packet output;
 uint8_t changed[MPV_APPLE_EAC3_BURST_BYTES];
 assert(!mpv_apple_eac3_unpack(NULL,sizeof(changed),&output));
 for(size_t n=0;n<sizeof(changed);n+=31)assert(!mpv_apple_eac3_unpack(original,n,&output));
 for(int i=0;i<6;i++){memcpy(changed,original,sizeof(changed));changed[i]^=255;assert(!mpv_apple_eac3_unpack(changed,sizeof(changed),&output));}
 memcpy(changed,original,sizeof(changed));AV_WL16(changed+6,65534);assert(!mpv_apple_eac3_unpack(changed,sizeof(changed),&output));
 memcpy(changed,original,sizeof(changed));AV_WL16(changed+6,7);assert(!mpv_apple_eac3_unpack(changed,sizeof(changed),&output));
 memcpy(changed,original,sizeof(changed));changed[13]|=0xc0;assert(!mpv_apple_eac3_unpack(changed,sizeof(changed),&output));
 uint8_t malformed[]={0,0,0,8,'m','o','o','v'};size_t size=0;
 assert(!mpv_apple_eac3_cookie(malformed,sizeof(malformed),0,&size));
 malformed[3]=255;assert(!mpv_apple_eac3_cookie(malformed,sizeof(malformed),0,&size));
 uint32_t random=42;
 for(int n=0;n<10000;n++){for(size_t i=0;i<sizeof(changed);i++){random=random*1664525+1013904223;changed[i]=random>>24;}mpv_apple_eac3_unpack(changed,sizeof(changed),&output);mpv_apple_eac3_cookie(changed,sizeof(changed),0,&size);}
}
static void variablePackets(CMAudioFormatDescriptionRef format) {
 const int blockCounts[]={1,2,3};
 for(int n=0;n<3;n++) {
  int blockCount=blockCounts[n],packetCount=6/blockCount;
  uint8_t burst[24576]={0};
  AV_WL16(burst,0xf872);AV_WL16(burst+2,0x4e1f);AV_WL16(burst+4,0x15);AV_WL16(burst+6,packetCount*8);
  for(int packet=0;packet<packetCount;packet++) {
   uint8_t frame[]={0x0b,0x77,0,3,(uint8_t)((n<<4)|15),0x80,0,0};
   for(int b=0;b<8;b+=2){burst[8+packet*8+b]=frame[b+1];burst[9+packet*8+b]=frame[b];}
  }
  struct mpv_apple_eac3_packet output;
  assert(mpv_apple_eac3_unpack(burst,sizeof(burst),&output));
  assert(output.packet_count==packetCount);
  CMBlockBufferRef block=NULL;CMSampleBufferRef sample=NULL;
  assert(CMBlockBufferCreateWithMemoryBlock(NULL,NULL,output.size,NULL,NULL,0,output.size,0,&block)==0);
  assert(CMBlockBufferReplaceDataBytes(output.data,block,0,output.size)==0);
  assert(CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL,block,format,output.packet_count,CMTimeMake(123,48000),output.packets,&sample)==0);
  assert(fabs(CMTimeGetSeconds(CMSampleBufferGetDuration(sample))-.032)<1e-9);
  CFRelease(sample);CFRelease(block);
 }
}
int main(int argc, char **argv) {
 @autoreleasepool {
  AVFormatContext *input=NULL,*mux=NULL;
  assert(argc==2 && avformat_open_input(&input,argv[1],NULL,NULL)==0);
  assert(avformat_find_stream_info(input,NULL)>=0);
  AVPacket *packet=av_packet_alloc();assert(packet);
  int count=0;size_t consumed=0;
  while(av_read_frame(input,packet)>=0 && count<8) {
   uint8_t bytes[24576]={0};
   assert(packet->size<=24568 && (packet->size&1)==0);
   AV_WL16(bytes,0xf872);AV_WL16(bytes+2,0x4e1f);AV_WL16(bytes+4,0x15);AV_WL16(bytes+6,packet->size);
   for(int i=0;i<packet->size;i+=2){bytes[8+i]=packet->data[i+1];bytes[9+i]=packet->data[i];}
   {
    if(count==0)invalidInputs(bytes);
    struct mpv_apple_eac3_packet unpacked;
    assert(mpv_apple_eac3_unpack(bytes,sizeof(bytes),&unpacked));
    assert(unpacked.size==(size_t)packet->size && memcmp(unpacked.data,packet->data,packet->size)==0);
    CMAudioFormatDescriptionRef format=mpv_apple_eac3_format(&unpacked);assert(format);if(count==0)variablePackets(format);
    if(count==0) {size_t formatSize=0;const AudioFormatListItem *formats=CMAudioFormatDescriptionGetFormatList(format,&formatSize);bool atmos=false;for(size_t i=0;i<formatSize/sizeof(*formats);i++)if(formats[i].mChannelLayoutTag==kAudioChannelLayoutTag_Atmos_9_1_6)atmos=true;assert(atmos);CFShow(format);size_t size=0;const uint8_t *cookie=CMAudioFormatDescriptionGetMagicCookie(format,&size);printf("COOKIE ");for(size_t i=0;i<size;i++)printf("%02x",cookie[i]);puts("");}
    CMBlockBufferRef block=NULL;CMSampleBufferRef sample=NULL;
    assert(CMBlockBufferCreateWithMemoryBlock(NULL,NULL,unpacked.size,NULL,NULL,0,unpacked.size,0,&block)==0);
    assert(CMBlockBufferReplaceDataBytes(unpacked.data,block,0,unpacked.size)==0);
    assert(CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL,block,format,unpacked.packet_count,CMTimeMake(count*1536,48000),unpacked.packets,&sample)==0);
    assert(fabs(CMTimeGetSeconds(CMSampleBufferGetDuration(sample))-0.032)<1e-9);
    assert(fabs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))-count*.032)<1e-9);
    CFRelease(sample);CFRelease(block);CFRelease(format);count++;
   }
   av_packet_unref(packet);
  }
  av_packet_free(&packet);avformat_close_input(&input);
  assert(count==8);
  printf("PASS malformed/fuzz inputs and %d preserved EAC3-JOC packets, Apple Atmos format list, exact timestamps and durations\n",count);
 }
}
