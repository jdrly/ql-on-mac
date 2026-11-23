/* glmt's front end: the OpenGL state of a context, and what its files share. */
#ifndef GLMT_INTERNAL_H
#define GLMT_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "backend.h"
#include "gl.h"
#include "glmt.h"

#define GLMT_MODELVIEW_STACK 32
#define GLMT_PROJECTION_STACK 4
#define GLMT_TEXTURE_STACK 4
#define GLMT_MAX_TEXTURE_SIZE 16384
#define GLMT_MAX_LEVELS 15 /* 16384 down to 1 */
#define GLMT_MAX_ANISOTROPY 16
#define GLMT_PACKET_BYTES (64 * 1024)
#define GLMT_ATTRIB_STACK 16
#define GLMT_STATS_FRAMES 1024
#define GLMT_GAP_STEP_NS 25
#define GLMT_GAP_STEPS 161 /* 0 to 4 microseconds in steps, and one for the rest */
#define GLMT_GAP_LONG_NS 2000
#define GLMT_IMMEDIATE_VERTICES 4096

struct glmt_matrix_stack
{
    float (*m)[16]; /* the stack's storage */
    int depth;      /* index of the top */
    int max;
};

/* One client array (glVertexPointer and the like). */
struct glmt_array
{
    bool enabled;
    GLint size;
    GLenum type;
    GLsizei stride; /* as given: 0 means tightly packed */
    const void *pointer;
    /* glLockArraysEXT found the array enabled, and its pointer was not set since: its contents
     * do not change until the unlock, so one copy serves every draw of the lock. */
    bool compiled;
    uint32_t copy_serial; /* the copy is the current one if this equals the context's copy_serial */
    uint32_t copy_offset;
};

struct glmt_tex_level
{
    int width, height;
    uint8_t *rgba; /* waits here until the texture is first drawn with */
};

struct glmt_texture
{
    GLuint name;
    uint32_t flags; /* GLMT_TEX_NO_ALPHA, GLMT_TEX_NO_COLOR */
    GLenum min_filter, mag_filter, wrap_s, wrap_t;
    float anisotropy;
    uint32_t sampler; /* GLMT_SAMPLER_*, from the five above */

    /* What the application uploaded and the backend does not have yet. */
    struct glmt_tex_level pending[GLMT_MAX_LEVELS];
    bool dirty;

    /* The backend's texture. */
    uint32_t be_texture;
    int be_width, be_height, be_levels;
};

/* Textures by name. Contexts that share (wglShareLists) use one table. */
struct glmt_share
{
    int refs;
    struct glmt_texture **slots; /* open addressing, a power of two */
    uint32_t capacity, count;
    GLuint next_name;
};

struct glmt_tex_unit
{
    bool enabled; /* GL_TEXTURE_2D */
    GLuint bound;
    struct glmt_texture *texture; /* the object bound, NULL for name 0 */
    GLenum env_mode;
    float texcoord[2]; /* the current texture coordinate (glTexCoord, glMultiTexCoord) */
    struct glmt_array array;
};

/* What glPushAttrib saves: the context's fields of that name, and per unit what GL_TEXTURE_BIT,
 * GL_ENABLE_BIT and GL_CURRENT_BIT cover. Which of it glPopAttrib puts back depends on mask. */
struct glmt_saved_attribs
{
    GLbitfield mask;
    bool alpha_test, blend, depth_test, stencil_test, cull_face, scissor_test, polygon_offset_fill, clip_plane0;
    GLenum alpha_func;
    float alpha_ref;
    GLenum blend_src, blend_dst;
    GLenum depth_func;
    bool depth_mask;
    double depth_near, depth_far;
    bool color_mask[4];
    GLenum cull_mode, front_face, polygon_mode;
    float polygon_offset_factor, polygon_offset_units;
    GLenum shade_model;
    GLenum stencil_func, stencil_sfail, stencil_zfail, stencil_zpass;
    GLint stencil_ref;
    GLuint stencil_value_mask, stencil_write_mask;
    float clip_plane_eye[4];
    GLint viewport[4], scissor[4];
    float clear_color[4];
    double clear_depth;
    GLint clear_stencil;
    GLenum draw_buffer, read_buffer;
    float line_width, point_size;
    GLenum matrix_mode;
    float color[4];
    int active_unit;
    bool unit_enabled[GLMT_MAX_TEX_UNITS];
    GLuint unit_bound[GLMT_MAX_TEX_UNITS];
    GLenum unit_env_mode[GLMT_MAX_TEX_UNITS];
    float unit_texcoord[GLMT_MAX_TEX_UNITS][2];
};

/* What glPushClientAttrib saves. */
struct glmt_saved_client
{
    GLbitfield mask;
    GLint unpack_alignment, unpack_row_length, unpack_skip_rows, unpack_skip_pixels;
    GLint pack_alignment, pack_row_length, pack_skip_rows, pack_skip_pixels;
    int client_unit;
    struct glmt_array vertex_array, color_array, texcoord_array[GLMT_MAX_TEX_UNITS];
};

struct glmt_stats
{
    uint64_t frames;
    uint64_t calls;    /* OpenGL calls since the last report */
    uint64_t draws;
    uint64_t vertices;
    uint64_t indices;
    uint64_t clears;
    uint64_t arena_bytes;
    uint64_t texture_uploads;
    uint64_t report_frames; /* frames since the last report */
    double report_time;
    /* Frame times since the last report, to tell an even frame rate from one with hitches, and how
     * long glmt's backend took at its worst: an average hides both. */
    double last_swap;
    float frame_ms[GLMT_STATS_FRAMES];
    uint32_t frame_count;
    double worst_submit_ms, worst_present_ms;
    /* GLMT_PROFILE (glmt_profile_call): where a frame's time goes, seen from the entry points.
     *   gl_ms       per frame, alongside frame_ms: from the frame's first OpenGL call to its swap
     *   gap         the time from one entry into glmt to the next, counted in steps of
     *               GLMT_GAP_STEP_NS; the last step takes everything longer
     *   gap_short_s, gap_long_s   the sum of the gaps under and over GLMT_GAP_LONG_NS */
    double first_call, last_call; /* of the frame being drawn; first_call 0: none yet */
    float gl_ms[GLMT_STATS_FRAMES];
    uint32_t gap[GLMT_GAP_STEPS];
    uint64_t gap_count;
    double gap_short_s, gap_long_s;
};

struct glmt_surface
{
    void *be_surface;
    int width, height;
    struct glmt_pixel_format format;
};

struct glmt_context
{
    struct glmt_backend *be;
    struct glmt_surface *surface;
    struct glmt_share *share;
    GLenum error;

    /* matrices */
    GLenum matrix_mode;
    float modelview_store[GLMT_MODELVIEW_STACK][16];
    float projection_store[GLMT_PROJECTION_STACK][16];
    float texture_store[GLMT_MAX_TEX_UNITS][GLMT_TEXTURE_STACK][16];
    struct glmt_matrix_stack modelview, projection, texture_matrix[GLMT_MAX_TEX_UNITS];
    /* GL_COLOR: kept so that code which resets every matrix finds it, applied to nothing */
    float color_store[2][16];
    struct glmt_matrix_stack color_matrix;

    /* fragment and raster state */
    bool alpha_test, blend, depth_test, stencil_test, cull_face, scissor_test, polygon_offset_fill,
        clip_plane0;
    GLenum alpha_func;
    float alpha_ref;
    GLenum blend_src, blend_dst;
    GLenum depth_func;
    bool depth_mask;
    double depth_near, depth_far;
    bool color_mask[4];
    GLenum cull_mode, front_face, polygon_mode;
    float polygon_offset_factor, polygon_offset_units;
    GLenum shade_model;
    GLenum stencil_func, stencil_sfail, stencil_zfail, stencil_zpass;
    GLint stencil_ref;
    GLuint stencil_value_mask, stencil_write_mask;
    float clip_plane_eye[4];
    GLint viewport[4], scissor[4];
    bool viewport_set; /* the first make current sets viewport and scissor to the surface */
    float clear_color[4];
    double clear_depth;
    GLint clear_stencil;
    GLenum draw_buffer, read_buffer;
    float line_width, point_size;
    GLint unpack_alignment, unpack_row_length, unpack_skip_rows, unpack_skip_pixels;
    GLint pack_alignment, pack_row_length, pack_skip_rows, pack_skip_pixels;

    /* current vertex attributes, textures and arrays */
    float color[4];
    int active_unit, client_unit;
    struct glmt_tex_unit unit[GLMT_MAX_TEX_UNITS];
    struct glmt_array vertex_array, color_array;
    bool locked; /* glLockArraysEXT */
    GLint lock_first;
    GLsizei lock_count;
    uint32_t copy_serial; /* changes at every lock, unlock and new arena: older copies are stale */
    uint32_t arena_epoch; /* changes at every new arena */

    /* glBegin to glEnd */
    bool in_begin;
    GLenum begin_mode;
    uint32_t imm_count;
    float (*imm_position)[4];
    uint8_t (*imm_color)[4];
    float (*imm_texcoord[GLMT_MAX_TEX_UNITS])[2];

    /* what the draw before this one sent, to send it again only when it changed */
    bool uniforms_valid;
    struct glmt_uniforms uniforms;
    uint32_t uniforms_offset;

    /* packets not submitted yet */
    uint8_t *packets;
    uint32_t packet_bytes;

    /* glPushAttrib, glPushClientAttrib */
    struct glmt_saved_attribs *attrib_stack;
    struct glmt_saved_client *client_stack;
    int attrib_depth, client_depth;
    int swap_interval; /* the last one a swap came with, -1 before the first */

    struct glmt_stats stats;
};

/* The context current on this thread. */
extern _Thread_local struct glmt_context *glmt_current;

/* GLMT_TRACE names frames: while one of them is drawn, every entry point logs its name. */
extern bool glmt_trace;
/* GLMT_PROFILE=1: every entry point reads the clock (context.c, glmt_profile_call), and the
 * statistics get a line that says where a frame's time goes. */
extern bool glmt_profile;
struct glmt_context;
void glmt_profile_call(struct glmt_context *c);

/* Every OpenGL entry point starts with this. */
#define GLMT_CONTEXT(...) \
    struct glmt_context *c = glmt_current; \
    if (!c) return __VA_ARGS__; \
    c->stats.calls++; \
    if (glmt_profile) glmt_profile_call(c); \
    if (glmt_trace) glmt_log("glmt: > %s", __func__ + 5)
/* The arguments worth seeing in a traced frame, after GLMT_CONTEXT. */
#define GLMT_TRACE_ARGS(...) \
    do \
    { \
        if (glmt_trace) glmt_log("glmt:     " __VA_ARGS__); \
    } while (0)

/* context.c */
void glmt_log(const char *format, ...) __attribute__((format(printf, 1, 2)));
/* Logs once per call site. */
#define GLMT_LOG_ONCE(...) \
    do \
    { \
        static bool logged_; \
        if (!logged_) \
        { \
            logged_ = true; \
            glmt_log(__VA_ARGS__); \
        } \
    } while (0)
/* GLMT_DEBUG is set: errors, contexts, surfaces and textures are logged. */
extern bool glmt_debug;
/* Records an OpenGL error for glGetError. In debug mode the log names the entry point. */
void glmt_set_error_at(struct glmt_context *c, GLenum error, const char *function);
#define glmt_set_error(c, error) glmt_set_error_at(c, error, __func__)
/* A line of log in debug mode only. */
#define GLMT_DEBUG(...) \
    do \
    { \
        if (glmt_debug) glmt_log(__VA_ARGS__); \
    } while (0)
/* Room for a packet of size bytes (a multiple of 4), submitting first if the buffer is full. */
void *glmt_packet(struct glmt_context *c, uint16_t op, uint16_t size);
/* Submits the packets not submitted yet. */
void glmt_flush_packets(struct glmt_context *c);
/* Arena memory, after a flush and a fresh arena if the current one is full. NULL if the size can
 * not be had at all. */
void *glmt_arena(struct glmt_context *c, uint32_t size, uint32_t align, uint32_t *offset);
/* Use a backend other than the one GLMT_BACKEND names. For tests: before the first context. */
void glmt_set_backend(struct glmt_backend *be);
double glmt_now(void);

/* matrix.c */
void glmt_matrix_init(struct glmt_context *c);
void glmt_matrix_identity(float m[16]);
void glmt_matrix_multiply(float out[16], const float a[16], const float b[16]);
bool glmt_matrix_invert(float out[16], const float m[16]);
static inline const float *glmt_top(const struct glmt_matrix_stack *s) { return s->m[s->depth]; }

/* texture.c */
struct glmt_texture *glmt_texture_lookup(struct glmt_share *share, GLuint name);
struct glmt_share *glmt_share_create(void);
void glmt_share_release(struct glmt_share *share, struct glmt_backend *be);
void glmt_texture_init(struct glmt_context *c);
/* Brings the backend's texture up to date. False: the texture has nothing to draw with. */
bool glmt_texture_realize(struct glmt_context *c, struct glmt_texture *t);

/* draw.c */
void glmt_draw_init(struct glmt_context *c);
void glmt_draw_destroy(struct glmt_context *c);
/* Every copy made under a lock, and the last uniforms, are in an arena that is gone. */
void glmt_draw_invalidate(struct glmt_context *c);

#endif
