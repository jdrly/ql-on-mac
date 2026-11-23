/* The null backend: takes every packet and draws nothing.
 *
 * Its use is a measurement. Quake Live on it runs everything except Metal: the game's own x86 code
 * under FEX, the crossing of every OpenGL call from the 32-bit side into Wine's arm64 side, and
 * glmt's front end with its vertex copies. The frame rate of a timedemo on it is the ceiling the
 * Metal backend can come close to and never exceed. */
#include <stdlib.h>
#include <string.h>

#include "backend.h"

#define NULL_ARENA_BYTES (32u * 1024 * 1024)

struct null_backend
{
    struct glmt_backend base;
    uint8_t *arena;
    uint32_t arena_used;
    uint32_t next_texture;
};

static void null_destroy(struct glmt_backend *be)
{
    struct null_backend *nb = (struct null_backend *)be;
    free(nb->arena);
    free(nb);
}

static void *null_surface_create(struct glmt_backend *be, void *layer, int width, int height, int depth_bits,
                                 int stencil_bits)
{
    (void)layer;
    (void)width;
    (void)height;
    (void)depth_bits;
    (void)stencil_bits;
    return be; /* any address that is not NULL */
}

static void null_surface_destroy(struct glmt_backend *be, void *surface)
{
    (void)be;
    (void)surface;
}

static void null_surface_resize(struct glmt_backend *be, void *surface, int width, int height)
{
    (void)be;
    (void)surface;
    (void)width;
    (void)height;
}

static uint32_t null_texture_create(struct glmt_backend *be, int width, int height, int levels)
{
    struct null_backend *nb = (struct null_backend *)be;
    (void)width;
    (void)height;
    (void)levels;
    return ++nb->next_texture;
}

static void null_texture_upload(struct glmt_backend *be, uint32_t texture, int level, int x, int y, int width,
                                int height, const uint8_t *rgba)
{
    (void)be;
    (void)texture;
    (void)level;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)rgba;
}

static void null_texture_destroy(struct glmt_backend *be, uint32_t texture)
{
    (void)be;
    (void)texture;
}

static void *null_arena_alloc(struct glmt_backend *be, uint32_t size, uint32_t align, uint32_t *offset)
{
    struct null_backend *nb = (struct null_backend *)be;
    uint32_t start = (nb->arena_used + align - 1) & ~(align - 1);

    if (start > NULL_ARENA_BYTES || size > NULL_ARENA_BYTES - start) return NULL;
    nb->arena_used = start + size;
    *offset = start;
    return nb->arena + start;
}

static void null_arena_next(struct glmt_backend *be) { ((struct null_backend *)be)->arena_used = 0; }

static void null_submit(struct glmt_backend *be, void *surface, const void *packets, uint32_t bytes)
{
    (void)be;
    (void)surface;
    (void)packets;
    (void)bytes;
}

static void null_read_pixels(struct glmt_backend *be, void *surface, int x, int y, int width, int height,
                             uint8_t *rgba)
{
    (void)be;
    (void)surface;
    (void)x;
    (void)y;
    memset(rgba, 0, (size_t)width * height * 4);
}

static void null_present(struct glmt_backend *be, void *surface, int interval)
{
    (void)surface;
    (void)interval;
    ((struct null_backend *)be)->arena_used = 0;
}

struct glmt_backend *glmt_backend_null_create(void)
{
    struct null_backend *nb = calloc(1, sizeof(*nb));

    if (!nb || !(nb->arena = malloc(NULL_ARENA_BYTES)))
    {
        free(nb);
        return NULL;
    }
    nb->base.name = "null";
    nb->base.destroy = null_destroy;
    nb->base.surface_create = null_surface_create;
    nb->base.surface_destroy = null_surface_destroy;
    nb->base.surface_resize = null_surface_resize;
    nb->base.texture_create = null_texture_create;
    nb->base.texture_upload = null_texture_upload;
    nb->base.texture_destroy = null_texture_destroy;
    nb->base.arena_alloc = null_arena_alloc;
    nb->base.arena_next = null_arena_next;
    nb->base.submit = null_submit;
    nb->base.read_pixels = null_read_pixels;
    nb->base.present = null_present;
    return &nb->base;
}

/* The tests link no Metal backend, on a Mac neither. */
#if !defined(__APPLE__) || defined(GLMT_TEST)
struct glmt_backend *glmt_backend_metal_create(void) { return NULL; }
#endif
