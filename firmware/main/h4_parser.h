#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define H4_MAX_PACKET 2048
/* Host -> controller: Command (1), ACL (2), SCO (3). Never scan payload for types. */
typedef bool (*h4_packet_fn)(const uint8_t *, size_t, void *);
typedef struct {
    uint8_t data[H4_MAX_PACKET];
    size_t used, header_size, expected;
    uint32_t ignored_bytes;
} h4_parser_t;
void h4_reset(h4_parser_t *p);
/* False means a transport error: reset the link rather than silently lose bytes. */
bool h4_feed(h4_parser_t *p, const uint8_t *data, size_t size, h4_packet_fn emit, void *ctx);
