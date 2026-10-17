#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "h4_parser.h"
static unsigned emitted;
static unsigned char last[H4_MAX_PACKET];
static size_t last_len;
static bool accept(const uint8_t *p, size_t n, void *ctx) {
    (void)ctx; emitted++; last_len=n; memcpy(last,p,n); return true;
}
static bool reject(const uint8_t *p, size_t n, void *ctx) {
    (void)p; (void)n; (void)ctx; return false;
}
int main(void) {
 h4_parser_t p;
 const uint8_t reset[]={1,3,12,0};
 for(size_t split=0;split<=sizeof(reset);split++){
  h4_reset(&p); emitted=0;
  assert(h4_feed(&p,reset,split,accept,NULL));
  assert(h4_feed(&p,reset+split,sizeof(reset)-split,accept,NULL));
  assert(emitted==1 && last_len==4 && !memcmp(last,reset,4));
 }
 const uint8_t combined[]={1,3,12,0,2,1,0,4,0,1,2,3,4,3,1,0,2,0xaa,0xbb};
 h4_reset(&p);emitted=0;
 for(size_t i=0;i<sizeof(combined);i++) assert(h4_feed(&p,combined+i,1,accept,NULL));
 assert(emitted==3 && last_len==6 && last[5]==0xbb);
 uint8_t huge[H4_MAX_PACKET]={2,1,0,0xfb,0x07}; /* exactly 2048 including header */
 for(size_t i=5;i<sizeof(huge);i++) huge[i]=(uint8_t)i;
 h4_reset(&p);emitted=0;
 assert(h4_feed(&p,huge,sizeof(huge),accept,NULL));
 assert(emitted==1 && last_len==sizeof(huge) && !memcmp(last,huge,sizeof(huge)));
 const uint8_t oversize[]={2,1,0,0xfc,0x07};
 h4_reset(&p);emitted=0;
 assert(!h4_feed(&p,oversize,sizeof(oversize),accept,NULL));assert(emitted==0);
 h4_reset(&p);assert(!h4_feed(&p,reset,sizeof(reset),reject,NULL));
 const uint8_t garbage[]={0xff,0,0x55,1,3,12,0};
 h4_reset(&p);emitted=0;assert(h4_feed(&p,garbage,sizeof(garbage),accept,NULL));
 assert(emitted==1 && p.ignored_bytes==3);
 puts("PASS: fragmented commands, ACL/SCO multiplexing, bounds, consumer failure, garbage prefix");
}
