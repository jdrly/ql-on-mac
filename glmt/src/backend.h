/* The line between glmt's front end and a backend.
 *
 * The front end (portable C) turns OpenGL calls into two things:
 *   - synchronous calls for what is rare: surfaces, textures, reading pixels back, presenting;
 *   - a stream of command packets for what is hot: clears and draws.
 *
 * A packet is plain data and carries no pointer: vertices, indices and uniforms are in the frame
 * arena (memory the backend owns, such as a Metal buffer's contents), and the packet holds their
 * offsets. A draw packet carries the complete state of its draw, so a backend needs no OpenGL state
 * of its own and skips what did not change by comparing with the packet before.
 *
 * Because packets are self-contained, they can be recorded and compared (the tests), counted and
 * dropped (the null backend, to measure what everything before Metal costs), saved and replayed
 * without Wine, or encoded on another thread. */
#ifndef GLMT_BACKEND_H
#define GLMT_BACKEND_H

#include <stdint.h>

#define GLMT_MAX_TEX_UNITS 2
#define GLMT_NO_OFFSET 0xffffffffu

/* ---- pipeline key: what makes a Metal render pipeline state ---- */
#define GLMT_PIPE_ALPHA_TEST 0x00000001u /* the fragment function may discard */
#define GLMT_PIPE_CLIP_PLANE 0x00000002u /* the vertex function writes a clip distance */
#define GLMT_PIPE_HAS_COLOR 0x00000004u  /* a color stream; without it, the uniform color */
#define GLMT_PIPE_HAS_TC0 0x00000008u
#define GLMT_PIPE_HAS_TC1 0x00000010u
#define GLMT_PIPE_BLEND 0x00000020u
#define GLMT_PIPE_SRC_SHIFT 6 /* 4 bits, a GLMT_BLEND_* */
#define GLMT_PIPE_DST_SHIFT 10
#define GLMT_PIPE_MASK_SHIFT 14 /* 4 bits: red 1, green 2, blue 4, alpha 8 */

enum glmt_blend_factor
{
    GLMT_BLEND_ZERO,
    GLMT_BLEND_ONE,
    GLMT_BLEND_SRC_COLOR,
    GLMT_BLEND_ONE_MINUS_SRC_COLOR,
    GLMT_BLEND_SRC_ALPHA,
    GLMT_BLEND_ONE_MINUS_SRC_ALPHA,
    GLMT_BLEND_DST_ALPHA,
    GLMT_BLEND_ONE_MINUS_DST_ALPHA,
    GLMT_BLEND_DST_COLOR,
    GLMT_BLEND_ONE_MINUS_DST_COLOR,
    GLMT_BLEND_SRC_ALPHA_SATURATE,
};

/* ---- depth key, stencil key: what makes a Metal depth stencil state ----
 * A comparison function is its OpenGL value minus GL_NEVER: 0 never, 1 less, 2 equal, 3 lequal,
 * 4 greater, 5 notequal, 6 gequal, 7 always. */
#define GLMT_DEPTH_TEST 0x01u /* off: every fragment passes and none writes depth */
#define GLMT_DEPTH_FUNC_SHIFT 1
#define GLMT_DEPTH_WRITE 0x10u

#define GLMT_STENCIL_TEST 0x01u
#define GLMT_STENCIL_FUNC_SHIFT 1
#define GLMT_STENCIL_SFAIL_SHIFT 4 /* 3 bits each, a GLMT_STENCIL_OP_* */
#define GLMT_STENCIL_ZFAIL_SHIFT 7
#define GLMT_STENCIL_ZPASS_SHIFT 10
#define GLMT_STENCIL_READ_MASK_SHIFT 13  /* 8 bits */
#define GLMT_STENCIL_WRITE_MASK_SHIFT 21 /* 8 bits */

enum glmt_stencil_op
{
    GLMT_STENCIL_OP_KEEP,
    GLMT_STENCIL_OP_ZERO,
    GLMT_STENCIL_OP_REPLACE,
    GLMT_STENCIL_OP_INCR,
    GLMT_STENCIL_OP_DECR,
    GLMT_STENCIL_OP_INVERT,
    GLMT_STENCIL_OP_INCR_WRAP,
    GLMT_STENCIL_OP_DECR_WRAP,
};

/* ---- raster state: set on the render encoder, no state object ---- */
#define GLMT_RASTER_CULL_FRONT 0x01u
#define GLMT_RASTER_CULL_BACK 0x02u /* both: no polygon is drawn */
#define GLMT_RASTER_FRONT_CW 0x04u
#define GLMT_RASTER_DEPTH_BIAS 0x08u
#define GLMT_RASTER_LINES 0x10u /* glPolygonMode GL_LINE */
#define GLMT_RASTER_SCISSOR 0x20u

/* ---- sampler key: what makes a Metal sampler state ---- */
#define GLMT_SAMPLER_MIN_LINEAR 0x01u
#define GLMT_SAMPLER_MIP_NEAREST 0x02u /* neither MIP bit: the base level only */
#define GLMT_SAMPLER_MIP_LINEAR 0x04u
#define GLMT_SAMPLER_MAG_LINEAR 0x08u
#define GLMT_SAMPLER_WRAP_S_SHIFT 4 /* 2 bits each, a GLMT_WRAP_* */
#define GLMT_SAMPLER_WRAP_T_SHIFT 6
#define GLMT_SAMPLER_ANISO_SHIFT 8 /* 5 bits, 1 to 16 */

enum glmt_wrap
{
    GLMT_WRAP_REPEAT,
    GLMT_WRAP_CLAMP, /* to the edge; GL_CLAMP too, as every driver since 2000 */
    GLMT_WRAP_MIRROR,
};

enum glmt_primitive
{
    GLMT_PRIM_TRIANGLES,
    GLMT_PRIM_TRIANGLE_STRIP,
    GLMT_PRIM_LINES,
    GLMT_PRIM_LINE_STRIP,
    GLMT_PRIM_POINTS,
};

/* ---- texture environment, per unit, in the uniforms ---- */
enum glmt_tex_env
{
    GLMT_ENV_OFF, /* texturing is off on the unit */
    GLMT_ENV_MODULATE,
    GLMT_ENV_REPLACE,
    GLMT_ENV_DECAL,
    GLMT_ENV_ADD,
};
#define GLMT_TEX_NO_ALPHA 0x1u /* the texture has no alpha of its own (RGB, luminance) */
#define GLMT_TEX_NO_COLOR 0x2u /* the texture has no color of its own (alpha) */

#define GLMT_UNIFORM_COLOR_ARRAY 0x1u /* color comes from the color stream */

/* The uniforms of a draw, in the arena, 16-byte aligned. shaders.metal mirrors this struct: change
 * both together. */
struct glmt_uniforms
{
    float mvp[16];       /* projection times modelview, column-major, OpenGL clip space (z -w to w) */
    float color[4];      /* the current color, for a draw without a color stream */
    float clip_plane[4]; /* clip plane 0 in object space: a vertex is kept where dot >= 0 */
    float alpha_ref;
    uint32_t alpha_func; /* comparison function, see above */
    uint32_t tex_env[GLMT_MAX_TEX_UNITS];
    uint32_t tex_flags[GLMT_MAX_TEX_UNITS];
    uint32_t flags;
    uint32_t pad;
};

/* ---- vertex streams, in the arena ----
 * position: float x, y, z and 4 bytes that are not read, 16 bytes a vertex (id Tech 3's own layout,
 *           so its array is copied as one block)
 * color:    4 unsigned normalized bytes, red first
 * texcoord: float s, t, 8 bytes a vertex
 * indices:  uint32 */
#define GLMT_POSITION_STRIDE 16
#define GLMT_COLOR_STRIDE 4
#define GLMT_TEXCOORD_STRIDE 8

enum glmt_cmd_op
{
    GLMT_CMD_CLEAR = 1,
    GLMT_CMD_DRAW = 2,
};

struct glmt_cmd
{
    uint16_t op;
    uint16_t size; /* of the whole packet, a multiple of 4 */
};

#define GLMT_CLEAR_COLOR 0x1u
#define GLMT_CLEAR_DEPTH 0x2u
#define GLMT_CLEAR_STENCIL 0x4u

/* Rectangles are OpenGL's: x, y, width, height with the origin at the bottom left. The backend
 * knows the surface's height and flips them. */
struct glmt_cmd_clear
{
    struct glmt_cmd hdr;
    uint32_t mask;         /* GLMT_CLEAR_* */
    float color[4];
    float depth;
    uint32_t stencil;
    uint32_t color_mask;   /* as GLMT_PIPE_MASK: the channels the clear writes */
    uint32_t stencil_mask; /* the stencil bits the clear writes */
    uint32_t scissor_on;   /* the clear is limited to scissor */
    int32_t scissor[4];
};

struct glmt_cmd_draw
{
    struct glmt_cmd hdr;
    uint32_t pipeline; /* GLMT_PIPE_* */
    uint32_t depth;    /* GLMT_DEPTH_* */
    uint32_t stencil;  /* GLMT_STENCIL_* */
    uint32_t stencil_ref;
    uint32_t raster;   /* GLMT_RASTER_* */
    float depth_bias_factor;
    float depth_bias_units;
    int32_t viewport[4];
    float depth_range[2];
    int32_t scissor[4];
    uint32_t texture[GLMT_MAX_TEX_UNITS]; /* a backend texture, 0: none */
    uint32_t sampler[GLMT_MAX_TEX_UNITS]; /* GLMT_SAMPLER_* */
    uint32_t uniforms;                    /* arena offset of a struct glmt_uniforms */
    uint32_t primitive;                   /* enum glmt_primitive */
    uint32_t position;                    /* arena offsets of the streams, vertex 0 of this draw */
    uint32_t color;                       /* GLMT_NO_OFFSET without the stream */
    uint32_t texcoord[GLMT_MAX_TEX_UNITS];
    uint32_t vertex_count;
    uint32_t index_offset; /* arena offset of uint32 indices; GLMT_NO_OFFSET: not indexed */
    uint32_t index_count;
    int32_t base_vertex;   /* added to each index */
};

struct glmt_backend
{
    const char *name;
    void (*destroy)(struct glmt_backend *be);

    /* layer: a CAMetalLayer or NULL. Returns the backend's surface, or NULL. */
    void *(*surface_create)(struct glmt_backend *be, void *layer, int width, int height,
                            int depth_bits, int stencil_bits);
    void (*surface_destroy)(struct glmt_backend *be, void *surface);
    void (*surface_resize)(struct glmt_backend *be, void *surface, int width, int height);

    /* An RGBA 8888 texture with levels mip levels. Returns its id, 0 on failure. */
    uint32_t (*texture_create)(struct glmt_backend *be, int width, int height, int levels);
    /* rgba: width * height * 4 bytes, rows tightly packed, the first row at t = 0. */
    void (*texture_upload)(struct glmt_backend *be, uint32_t texture, int level, int x, int y,
                           int width, int height, const uint8_t *rgba);
    void (*texture_destroy)(struct glmt_backend *be, uint32_t texture);

    /* size bytes of the frame arena, aligned to align (a power of two), and their offset. The
     * memory is valid, and the offset means the same, until present or arena_next. NULL: the arena
     * is full; the front end submits what it has and calls arena_next. */
    void *(*arena_alloc)(struct glmt_backend *be, uint32_t size, uint32_t align, uint32_t *offset);
    /* A fresh arena for the packets that follow. Earlier offsets are void. */
    void (*arena_next)(struct glmt_backend *be);

    /* Executes packets in order on the surface. The front end may reuse the memory afterwards. */
    void (*submit)(struct glmt_backend *be, void *surface, const void *packets, uint32_t bytes);

    /* The surface's pixels as RGBA 8888, the rectangle in OpenGL's coordinates, bottom row first.
     * Everything submitted before is in the result. */
    void (*read_pixels)(struct glmt_backend *be, void *surface, int x, int y, int width, int height,
                        uint8_t *rgba);

    void (*present)(struct glmt_backend *be, void *surface, int interval);

    /* Optional: text to end the statistics' frame-time line with (how many frames went to the
     * display), for the frames since the last call. Writes nothing if it has nothing to say. */
    void (*frame_note)(struct glmt_backend *be, void *surface, char *note, size_t size);
};

/* Counts packets and throws them away. */
struct glmt_backend *glmt_backend_null_create(void);
/* Metal. NULL where this build has none (anything but macOS). */
struct glmt_backend *glmt_backend_metal_create(void);

#endif
