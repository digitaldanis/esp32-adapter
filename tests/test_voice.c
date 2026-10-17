#include <assert.h>
#include <string.h>
#include "hci_compat.h"
int main(void) {
 uint8_t p[25]={1,0x28,4,17};p[16]=3;
 assert(airbridge_fix_voice(p,21));assert(p[16]==0x43 && p[17]==0);
 p[16]=0x63;assert(airbridge_fix_voice(p,21));assert(p[16]==0x43);
 p[16]=0x60;assert(!airbridge_fix_voice(p,21));assert(p[16]==0x60);
 p[1]=0x29;p[3]=21;p[20]=3;assert(airbridge_fix_voice(p,25));assert(p[20]==0x43);
 for(unsigned n=0;n<25;n++) assert(!airbridge_fix_voice(p,n));
 p[0]=2;assert(!airbridge_fix_voice(p,25));
 return 0;
}
