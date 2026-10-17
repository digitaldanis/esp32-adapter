#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
/* ESP-IDF's BTM_VOICE_SETTING_TRANS is linear, 2s-complement, 8-bit,
 * transparent = 0x0043. Preserve air mode and all unrelated commands. */
static inline bool airbridge_fix_voice(uint8_t *p, size_t n) {
    if (n < 4 || p[0] != 1 || n != (size_t)p[3] + 4) return false;
    unsigned op = p[1] | (p[2] << 8), offset;
    if (op == 0x0428 && n == 21) offset = 16;
    else if (op == 0x0429 && n == 25) offset = 20;
    else return false;
    if ((p[offset] & 3) != 3) return false;
    p[offset] = 0x43; p[offset+1] = 0;
    return true;
}
