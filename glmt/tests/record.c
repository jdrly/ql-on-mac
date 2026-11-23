#include <stdlib.h>
#include <string.h>

#include "record.h"

static void rec_destroy(struct glmt_backend *be) { (void)be; }

static void *rec_surface_create(struct glmt_backend *be, void *layer, int width, int height, int depth_bits,
                                int stencil_bits)
{
    struct rec *rec = (struct rec *)be;
    rec->width = width;
    rec->height = height;
    return rec;
}

static void rec_surface_destroy(struct glmt_backend *be, void *surface) {}

static void rec_surface_resize(struct glmt_backend *be, void *surface, int width, int height)
{
    struct rec *rec = (struct rec *)be;
    rec->width = width;
    rec->height = height;
}

static uint32_t rec_texture_create(struct glmt_backend *be, int width, int height, int levels)
{
    struct rec *rec = (struct rec *)be;
    struct rec_texture *t;

    if (rec->texture_count + 1 >= REC_MAX) return 0;
    t = &rec->textures[++rec->texture_count];
    t->width = width;
    t->height = height;
    t->levels = levels;
    return (uint32_t)rec->texture_count;
}

static void rec_texture_upload(struct glmt_backend *be, uint32_t texture, int level, int x, int y, int width,
                               int height, const uint8_t *rgba)
{
    struct rec_texture *t = &((struct rec *)be)->textures[texture];
    t->uploads++;
    t->level = level;
    t->x = x;
    t->y = y;
    t->upload_width = width;
    t->upload_height = height;
    memcpy(t->first_pixel, rgba, 4);
}

static void rec_texture_destroy(struct glmt_backend *be, uint32_t texture)
{
    ((struct rec *)be)->textures[texture].destroyed = 1;
}

static void new_arena(struct rec *rec)
{
    /* The old one stays allocated: recorded packets point into it. */
    rec->arena = calloc(1, rec->arena_bytes);
    rec->arena_used = 0;
    rec->arenas++;
}

static void *rec_arena_alloc(struct glmt_backend *be, uint32_t size, uint32_t align, uint32_t *offset)
{
    struct rec *rec = (struct rec *)be;
    uint32_t start = (rec->arena_used + align - 1) & ~(align - 1);

    if (start > rec->arena_bytes || size > rec->arena_bytes - start) return NULL;
    rec->arena_used = start + size;
    *offset = start;
    return rec->arena + start;
}

static void rec_arena_next(struct glmt_backend *be) { new_arena((struct rec *)be); }

static void rec_submit(struct glmt_backend *be, void *surface, const void *packets, uint32_t bytes)
{
    struct rec *rec = (struct rec *)be;
    const uint8_t *p = packets, *end = p + bytes;

    rec->submits++;
    while (p < end)
    {
        const struct glmt_cmd *cmd = (const struct glmt_cmd *)p;
        if (cmd->op == GLMT_CMD_DRAW && rec->draw_count < REC_MAX)
        {
            memcpy(&rec->draws[rec->draw_count].d, cmd, sizeof(struct glmt_cmd_draw));
            rec->draws[rec->draw_count++].arena = rec->arena;
        }
        else if (cmd->op == GLMT_CMD_CLEAR && rec->clear_count < REC_MAX)
            memcpy(&rec->clears[rec->clear_count++], cmd, sizeof(struct glmt_cmd_clear));
        p += cmd->size;
    }
}

/* Pixel (x, y) reads as red x, green y, blue 7, alpha 255. */
static void rec_read_pixels(struct glmt_backend *be, void *surface, int x, int y, int width, int height,
                            uint8_t *rgba)
{
    for (int row = 0; row < height; row++)
        for (int col = 0; col < width; col++, rgba += 4)
            rgba[0] = (uint8_t)(x + col), rgba[1] = (uint8_t)(y + row), rgba[2] = 7, rgba[3] = 255;
}

static void rec_present(struct glmt_backend *be, void *surface, int interval)
{
    struct rec *rec = (struct rec *)be;
    rec->presents++;
    rec->last_interval = interval;
    new_arena(rec);
}

struct rec *rec_create(uint32_t arena_bytes)
{
    struct rec *rec = calloc(1, sizeof(*rec));

    rec->arena_bytes = arena_bytes;
    new_arena(rec);
    rec->base.name = "record";
    rec->base.destroy = rec_destroy;
    rec->base.surface_create = rec_surface_create;
    rec->base.surface_destroy = rec_surface_destroy;
    rec->base.surface_resize = rec_surface_resize;
    rec->base.texture_create = rec_texture_create;
    rec->base.texture_upload = rec_texture_upload;
    rec->base.texture_destroy = rec_texture_destroy;
    rec->base.arena_alloc = rec_arena_alloc;
    rec->base.arena_next = rec_arena_next;
    rec->base.submit = rec_submit;
    rec->base.read_pixels = rec_read_pixels;
    rec->base.present = rec_present;
    return rec;
}

void rec_reset(struct rec *rec)
{
    rec->draw_count = rec->clear_count = 0;
    rec->submits = 0;
}
