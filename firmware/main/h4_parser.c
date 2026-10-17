#include "h4_parser.h"
#include <string.h>
void h4_reset(h4_parser_t *p) { memset(p, 0, sizeof(*p)); }
bool h4_feed(h4_parser_t *p, const uint8_t *data, size_t size, h4_packet_fn emit, void *ctx) {
    for (size_t i = 0; i < size; i++) {
        uint8_t byte = data[i];
        if (p->used == 0) {
            if (byte == 1 || byte == 3) p->header_size = 4;
            else if (byte == 2) p->header_size = 5;
            else { p->ignored_bytes++; continue; }
            p->data[p->used++] = byte;
            p->expected = 0;
            continue;
        }
        if (p->used >= sizeof(p->data)) return false;
        p->data[p->used++] = byte;
        if (p->used == p->header_size) {
            size_t payload = p->data[p->header_size - 1];
            if (p->data[0] == 2) payload = p->data[3] | ((size_t)p->data[4] << 8);
            p->expected = p->header_size + payload;
            if (p->expected > sizeof(p->data)) return false;
        }
        if (p->expected && p->used == p->expected) {
            if (!emit(p->data, p->used, ctx)) return false;
            p->used = 0; p->expected = 0; p->header_size = 0;
        }
    }
    return true;
}
