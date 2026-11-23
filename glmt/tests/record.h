/* A backend for the tests: keeps every packet, texture call and arena, so a test can read what the
 * front end made of a sequence of OpenGL calls. */
#ifndef GLMT_TEST_RECORD_H
#define GLMT_TEST_RECORD_H

#include "backend.h"

#define REC_MAX 256

struct rec_draw
{
    struct glmt_cmd_draw d;
    const uint8_t *arena; /* the arena the packet's offsets are in */
};

struct rec_texture
{
    int width, height, levels;
    int uploads;
    int destroyed;
    /* the last upload */
    int level, x, y, upload_width, upload_height;
    uint8_t first_pixel[4];
};

struct rec
{
    struct glmt_backend base;
    uint32_t arena_bytes; /* the size of each arena */
    uint8_t *arena;
    uint32_t arena_used;
    int arenas; /* arenas opened so far */

    struct rec_draw draws[REC_MAX];
    int draw_count;
    struct glmt_cmd_clear clears[REC_MAX];
    int clear_count;
    struct rec_texture textures[REC_MAX]; /* by id */
    int texture_count;
    int submits, presents, last_interval;
    int width, height;
};

/* A fresh recording backend whose arenas hold arena_bytes each. */
struct rec *rec_create(uint32_t arena_bytes);
/* Forgets the packets recorded so far (textures stay). */
void rec_reset(struct rec *rec);

#endif
