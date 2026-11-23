/* Draws and clears: OpenGL state and client arrays in, command packets out.
 *
 * How id Tech 3 draws a surface (RB_StageIteratorGeneric), which this file is shaped by:
 *
 *   glVertexPointer(3, GL_FLOAT, 16, xyz)
 *   glLockArraysEXT(0, numVertexes)       the arrays enabled now stay as they are until the unlock
 *   for each stage of the shader:
 *       glColorPointer, glTexCoordPointer new contents at the same addresses
 *       glBindTexture, glBlendFunc ...
 *       glDrawElements(GL_TRIANGLES, numIndexes, GL_UNSIGNED_INT, indexes)
 *   glUnlockArraysEXT()
 *
 * So positions are copied to the arena once per lock, colors and texture coordinates once per draw,
 * and indices always (the dynamic light pass reuses one address for different indices). */
#include <stdlib.h>
#include <string.h>

#include "api.h"
#include "internal.h"

#define ARENA_ALIGN 16

void glmt_draw_init(struct glmt_context *c)
{
    c->color[0] = c->color[1] = c->color[2] = c->color[3] = 1.0f;
    c->vertex_array.size = 4;
    c->vertex_array.type = GL_FLOAT;
    c->color_array.size = 4;
    c->color_array.type = GL_FLOAT;
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
    {
        c->unit[u].array.size = 4;
        c->unit[u].array.type = GL_FLOAT;
        c->imm_texcoord[u] = malloc(GLMT_IMMEDIATE_VERTICES * sizeof(*c->imm_texcoord[u]));
    }
    c->imm_position = malloc(GLMT_IMMEDIATE_VERTICES * sizeof(*c->imm_position));
    c->imm_color = malloc(GLMT_IMMEDIATE_VERTICES * sizeof(*c->imm_color));
    c->copy_serial = 1;
}

void glmt_draw_destroy(struct glmt_context *c)
{
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++) free(c->imm_texcoord[u]);
    free(c->imm_position);
    free(c->imm_color);
}

void glmt_draw_invalidate(struct glmt_context *c)
{
    c->copy_serial++;
    c->uniforms_valid = false;
}

/* ---- state to keys ---- */

static uint32_t blend_factor(GLenum factor)
{
    switch (factor)
    {
    case GL_ZERO: return GLMT_BLEND_ZERO;
    case GL_ONE: return GLMT_BLEND_ONE;
    case GL_SRC_COLOR: return GLMT_BLEND_SRC_COLOR;
    case GL_ONE_MINUS_SRC_COLOR: return GLMT_BLEND_ONE_MINUS_SRC_COLOR;
    case GL_SRC_ALPHA: return GLMT_BLEND_SRC_ALPHA;
    case GL_ONE_MINUS_SRC_ALPHA: return GLMT_BLEND_ONE_MINUS_SRC_ALPHA;
    case GL_DST_ALPHA: return GLMT_BLEND_DST_ALPHA;
    case GL_ONE_MINUS_DST_ALPHA: return GLMT_BLEND_ONE_MINUS_DST_ALPHA;
    case GL_DST_COLOR: return GLMT_BLEND_DST_COLOR;
    case GL_ONE_MINUS_DST_COLOR: return GLMT_BLEND_ONE_MINUS_DST_COLOR;
    case GL_SRC_ALPHA_SATURATE: return GLMT_BLEND_SRC_ALPHA_SATURATE;
    default: return GLMT_BLEND_ONE;
    }
}

static uint32_t color_mask_bits(const struct glmt_context *c)
{
    return (c->color_mask[0] ? 1u : 0) | (c->color_mask[1] ? 2u : 0) | (c->color_mask[2] ? 4u : 0) |
           (c->color_mask[3] ? 8u : 0);
}

static uint32_t stencil_op(GLenum op)
{
    switch (op)
    {
    case GL_ZERO: return GLMT_STENCIL_OP_ZERO;
    case GL_REPLACE: return GLMT_STENCIL_OP_REPLACE;
    case GL_INCR: return GLMT_STENCIL_OP_INCR;
    case GL_DECR: return GLMT_STENCIL_OP_DECR;
    case GL_INVERT: return GLMT_STENCIL_OP_INVERT;
    case GL_INCR_WRAP: return GLMT_STENCIL_OP_INCR_WRAP;
    case GL_DECR_WRAP: return GLMT_STENCIL_OP_DECR_WRAP;
    default: return GLMT_STENCIL_OP_KEEP;
    }
}

static uint32_t tex_env_key(GLenum mode)
{
    switch (mode)
    {
    case GL_REPLACE: return GLMT_ENV_REPLACE;
    case GL_DECAL: return GLMT_ENV_DECAL;
    case GL_ADD: return GLMT_ENV_ADD;
    default: return GLMT_ENV_MODULATE;
    }
}

struct streams
{
    uint32_t position, color, texcoord[GLMT_MAX_TEX_UNITS];
    uint32_t vertex_count;
    uint32_t index_offset, index_count;
    int32_t base_vertex;
};

/* Brings the uniforms in the arena up to the state of this moment, for a draw with or without a
 * color stream and with these textured units. May open a new arena. False: no room. */
static bool update_uniforms(struct glmt_context *c, bool has_color, uint32_t units)
{
    struct glmt_uniforms u;
    const float *modelview = glmt_top(&c->modelview);
    void *memory;

    memset(&u, 0, sizeof(u));
    glmt_matrix_multiply(u.mvp, glmt_top(&c->projection), modelview);
    memcpy(u.color, c->color, sizeof(u.color));
    if (c->clip_plane0)
        for (int j = 0; j < 4; j++)
            u.clip_plane[j] = c->clip_plane_eye[0] * modelview[j * 4 + 0] + c->clip_plane_eye[1] * modelview[j * 4 + 1] +
                              c->clip_plane_eye[2] * modelview[j * 4 + 2] + c->clip_plane_eye[3] * modelview[j * 4 + 3];
    if (c->alpha_test)
    {
        u.alpha_ref = c->alpha_ref;
        u.alpha_func = c->alpha_func - GL_NEVER;
    }
    for (int i = 0; i < GLMT_MAX_TEX_UNITS; i++)
        if (units & (1u << i))
        {
            u.tex_env[i] = tex_env_key(c->unit[i].env_mode);
            u.tex_flags[i] = c->unit[i].texture->flags;
        }
    if (has_color) u.flags |= GLMT_UNIFORM_COLOR_ARRAY;

    if (c->uniforms_valid && !memcmp(&u, &c->uniforms, sizeof(u))) return true;
    c->uniforms_valid = false;
    if (!(memory = glmt_arena(c, sizeof(u), ARENA_ALIGN, &c->uniforms_offset))) return false;
    memcpy(memory, &u, sizeof(u));
    c->uniforms = u;
    c->uniforms_valid = true;
    c->stats.arena_bytes += sizeof(u);
    return true;
}

/* The draw packet for the streams, with the state of this moment and the uniforms update_uniforms
 * left. units: bit u is set if unit u draws with a texture. */
static void emit_draw(struct glmt_context *c, enum glmt_primitive primitive, const struct streams *s, uint32_t units)
{
    struct glmt_cmd_draw *d;

    if (!(d = glmt_packet(c, GLMT_CMD_DRAW, sizeof(*d)))) return;

    d->pipeline = color_mask_bits(c) << GLMT_PIPE_MASK_SHIFT;
    if (c->alpha_test && c->alpha_func != GL_ALWAYS) d->pipeline |= GLMT_PIPE_ALPHA_TEST;
    if (c->clip_plane0) d->pipeline |= GLMT_PIPE_CLIP_PLANE;
    if (s->color != GLMT_NO_OFFSET) d->pipeline |= GLMT_PIPE_HAS_COLOR;
    if (units & 1u) d->pipeline |= GLMT_PIPE_HAS_TC0;
    if (units & 2u) d->pipeline |= GLMT_PIPE_HAS_TC1;
    if (c->blend)
        d->pipeline |= GLMT_PIPE_BLEND | blend_factor(c->blend_src) << GLMT_PIPE_SRC_SHIFT |
                       blend_factor(c->blend_dst) << GLMT_PIPE_DST_SHIFT;

    d->depth = 0;
    if (c->depth_test)
        d->depth = GLMT_DEPTH_TEST | (c->depth_func - GL_NEVER) << GLMT_DEPTH_FUNC_SHIFT |
                   (c->depth_mask ? GLMT_DEPTH_WRITE : 0);

    d->stencil = 0;
    d->stencil_ref = 0;
    if (c->stencil_test && c->surface && c->surface->format.stencil_bits)
    {
        d->stencil = GLMT_STENCIL_TEST | (c->stencil_func - GL_NEVER) << GLMT_STENCIL_FUNC_SHIFT |
                     stencil_op(c->stencil_sfail) << GLMT_STENCIL_SFAIL_SHIFT |
                     stencil_op(c->stencil_zfail) << GLMT_STENCIL_ZFAIL_SHIFT |
                     stencil_op(c->stencil_zpass) << GLMT_STENCIL_ZPASS_SHIFT |
                     (c->stencil_value_mask & 0xffu) << GLMT_STENCIL_READ_MASK_SHIFT |
                     (c->stencil_write_mask & 0xffu) << GLMT_STENCIL_WRITE_MASK_SHIFT;
        d->stencil_ref = (uint32_t)c->stencil_ref & 0xffu;
    }

    d->raster = 0;
    if (c->cull_face)
    {
        if (c->cull_mode != GL_BACK) d->raster |= GLMT_RASTER_CULL_FRONT;
        if (c->cull_mode != GL_FRONT) d->raster |= GLMT_RASTER_CULL_BACK;
    }
    if (c->front_face == GL_CW) d->raster |= GLMT_RASTER_FRONT_CW;
    if (c->polygon_mode == GL_LINE) d->raster |= GLMT_RASTER_LINES;
    if (c->scissor_test) d->raster |= GLMT_RASTER_SCISSOR;
    d->depth_bias_factor = d->depth_bias_units = 0.0f;
    if (c->polygon_offset_fill && (c->polygon_offset_factor != 0.0f || c->polygon_offset_units != 0.0f))
    {
        d->raster |= GLMT_RASTER_DEPTH_BIAS;
        d->depth_bias_factor = c->polygon_offset_factor;
        d->depth_bias_units = c->polygon_offset_units;
    }

    memcpy(d->viewport, c->viewport, sizeof(d->viewport));
    d->depth_range[0] = (float)c->depth_near;
    d->depth_range[1] = (float)c->depth_far;
    memcpy(d->scissor, c->scissor, sizeof(d->scissor));

    for (int i = 0; i < GLMT_MAX_TEX_UNITS; i++)
    {
        bool on = (units & (1u << i)) != 0;
        d->texture[i] = on ? c->unit[i].texture->be_texture : 0;
        d->sampler[i] = on ? c->unit[i].texture->sampler : 0;
        d->texcoord[i] = on ? s->texcoord[i] : GLMT_NO_OFFSET;
    }
    d->uniforms = c->uniforms_offset;
    d->primitive = primitive;
    d->position = s->position;
    d->color = s->color;
    d->vertex_count = s->vertex_count;
    d->index_offset = s->index_offset;
    d->index_count = s->index_count;
    d->base_vertex = s->base_vertex;

    c->stats.draws++;
    c->stats.vertices += s->vertex_count;
    c->stats.indices += s->index_count;
}

/* The units that draw with a texture: enabled, with a texture that has an image. As in OpenGL, a
 * unit whose texture is incomplete draws as if texturing were off. */
static uint32_t textured_units(struct glmt_context *c)
{
    uint32_t units = 0;
    for (int i = 0; i < GLMT_MAX_TEX_UNITS; i++)
    {
        struct glmt_tex_unit *unit = &c->unit[i];
        if (unit->enabled && unit->texture && glmt_texture_realize(c, unit->texture)) units |= 1u << i;
    }
    return units;
}

/* ---- client arrays to streams ---- */

static void copy_positions(float *out, const struct glmt_array *a, uint32_t first, uint32_t count)
{
    size_t stride = a->stride ? (size_t)a->stride : (size_t)a->size * sizeof(float);
    const uint8_t *in = (const uint8_t *)a->pointer + first * stride;

    if (a->size >= 3 && stride == GLMT_POSITION_STRIDE)
    {
        memcpy(out, in, (size_t)count * GLMT_POSITION_STRIDE);
        return;
    }
    for (uint32_t i = 0; i < count; i++, in += stride, out += 4)
    {
        const float *v = (const float *)in;
        out[0] = v[0];
        out[1] = v[1];
        out[2] = a->size >= 3 ? v[2] : 0.0f;
        out[3] = 1.0f;
    }
}

static uint8_t float_to_ubyte(float v) { return v <= 0.0f ? 0 : v >= 1.0f ? 255 : (uint8_t)(v * 255.0f + 0.5f); }

static void copy_colors(uint8_t *out, const struct glmt_array *a, uint32_t first, uint32_t count)
{
    if (a->type == GL_UNSIGNED_BYTE)
    {
        size_t stride = a->stride ? (size_t)a->stride : (size_t)a->size;
        const uint8_t *in = (const uint8_t *)a->pointer + first * stride;

        if (a->size == 4 && stride == GLMT_COLOR_STRIDE)
        {
            memcpy(out, in, (size_t)count * GLMT_COLOR_STRIDE);
            return;
        }
        for (uint32_t i = 0; i < count; i++, in += stride, out += 4)
        {
            out[0] = in[0];
            out[1] = in[1];
            out[2] = in[2];
            out[3] = a->size == 4 ? in[3] : 255;
        }
    }
    else
    {
        size_t stride = a->stride ? (size_t)a->stride : (size_t)a->size * sizeof(float);
        const uint8_t *in = (const uint8_t *)a->pointer + first * stride;

        for (uint32_t i = 0; i < count; i++, in += stride, out += 4)
        {
            const float *v = (const float *)in;
            out[0] = float_to_ubyte(v[0]);
            out[1] = float_to_ubyte(v[1]);
            out[2] = float_to_ubyte(v[2]);
            out[3] = a->size == 4 ? float_to_ubyte(v[3]) : 255;
        }
    }
}

static void copy_texcoords(float *out, const struct glmt_array *a, uint32_t first, uint32_t count)
{
    size_t stride = a->stride ? (size_t)a->stride : (size_t)a->size * sizeof(float);
    const uint8_t *in = (const uint8_t *)a->pointer + first * stride;

    if (a->size >= 2 && stride == GLMT_TEXCOORD_STRIDE)
    {
        memcpy(out, in, (size_t)count * GLMT_TEXCOORD_STRIDE);
        return;
    }
    for (uint32_t i = 0; i < count; i++, in += stride, out += 2)
    {
        const float *v = (const float *)in;
        out[0] = v[0];
        out[1] = a->size >= 2 ? v[1] : 0.0f;
    }
}

enum stream_kind { STREAM_POSITION, STREAM_COLOR, STREAM_TEXCOORD };

/* The arena copy of count vertices of an array from first: a new one, or the one made earlier under
 * this lock. GLMT_NO_OFFSET if the arena has no room. */
static uint32_t array_stream(struct glmt_context *c, struct glmt_array *a, enum stream_kind kind, uint32_t first,
                             uint32_t count)
{
    static const uint32_t strides[] = {GLMT_POSITION_STRIDE, GLMT_COLOR_STRIDE, GLMT_TEXCOORD_STRIDE};
    uint32_t offset;
    void *memory;

    if (a->compiled && a->copy_serial == c->copy_serial) return a->copy_offset;
    if (!(memory = glmt_arena(c, count * strides[kind], ARENA_ALIGN, &offset))) return GLMT_NO_OFFSET;
    switch (kind)
    {
    case STREAM_POSITION: copy_positions(memory, a, first, count); break;
    case STREAM_COLOR: copy_colors(memory, a, first, count); break;
    case STREAM_TEXCOORD: copy_texcoords(memory, a, first, count); break;
    }
    c->stats.arena_bytes += count * strides[kind];
    if (a->compiled)
    {
        /* glmt_arena may have opened a new arena, which changed the serial: read it now. */
        a->copy_serial = c->copy_serial;
        a->copy_offset = offset;
    }
    return offset;
}

/* A stream of count copies of the unit's current texture coordinate, for a textured unit without a
 * coordinate array. */
static uint32_t constant_texcoords(struct glmt_context *c, int unit, uint32_t count)
{
    uint32_t offset;
    float *out = glmt_arena(c, count * GLMT_TEXCOORD_STRIDE, ARENA_ALIGN, &offset);

    if (!out) return GLMT_NO_OFFSET;
    for (uint32_t i = 0; i < count; i++, out += 2) out[0] = c->unit[unit].texcoord[0], out[1] = c->unit[unit].texcoord[1];
    return offset;
}

static bool array_types_ok(struct glmt_context *c)
{
    if (c->vertex_array.type != GL_FLOAT)
    {
        GLMT_LOG_ONCE("glmt: a vertex array of type 0x%04x is not supported", c->vertex_array.type);
        return false;
    }
    if (c->vertex_array.size == 4) GLMT_LOG_ONCE("glmt: a vertex array with 4 components is drawn with w = 1");
    if (c->color_array.enabled && c->color_array.type != GL_UNSIGNED_BYTE && c->color_array.type != GL_FLOAT)
    {
        GLMT_LOG_ONCE("glmt: a color array of type 0x%04x is not supported", c->color_array.type);
        return false;
    }
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
        if (c->unit[u].array.enabled && c->unit[u].array.type != GL_FLOAT)
        {
            GLMT_LOG_ONCE("glmt: a texture coordinate array of type 0x%04x is not supported", c->unit[u].array.type);
            return false;
        }
    return true;
}

static bool native_primitive(GLenum mode, enum glmt_primitive *primitive)
{
    switch (mode)
    {
    case GL_TRIANGLES: *primitive = GLMT_PRIM_TRIANGLES; return true;
    case GL_TRIANGLE_STRIP:
    case GL_QUAD_STRIP: *primitive = GLMT_PRIM_TRIANGLE_STRIP; return true;
    case GL_LINES: *primitive = GLMT_PRIM_LINES; return true;
    case GL_LINE_STRIP: *primitive = GLMT_PRIM_LINE_STRIP; return true;
    case GL_POINTS: *primitive = GLMT_PRIM_POINTS; return true;
    default: return false;
    }
}

/* Indices that draw count vertices of a mode Metal does not have as triangles or a line strip.
 * Returns the index count, 0 if there is nothing to draw or no room. */
static uint32_t generated_indices(struct glmt_context *c, GLenum mode, uint32_t count, enum glmt_primitive *primitive,
                                  uint32_t *offset)
{
    uint32_t n = 0, *out;

    switch (mode)
    {
    case GL_QUADS: n = count / 4 * 6; break;
    case GL_TRIANGLE_FAN:
    case GL_POLYGON: n = count >= 3 ? (count - 2) * 3 : 0; break;
    case GL_LINE_LOOP: n = count >= 2 ? count + 1 : 0; break;
    default: break;
    }
    if (!n || !(out = glmt_arena(c, n * sizeof(uint32_t), ARENA_ALIGN, offset))) return 0;
    switch (mode)
    {
    case GL_QUADS:
        *primitive = GLMT_PRIM_TRIANGLES;
        for (uint32_t q = 0; q < count / 4; q++, out += 6)
        {
            out[0] = q * 4, out[1] = q * 4 + 1, out[2] = q * 4 + 2;
            out[3] = q * 4, out[4] = q * 4 + 2, out[5] = q * 4 + 3;
        }
        break;
    case GL_LINE_LOOP:
        *primitive = GLMT_PRIM_LINE_STRIP;
        for (uint32_t i = 0; i < count; i++) out[i] = i;
        out[count] = 0;
        break;
    default:
        *primitive = GLMT_PRIM_TRIANGLES;
        for (uint32_t i = 0; i + 2 < count; i++, out += 3) out[0] = 0, out[1] = i + 1, out[2] = i + 2;
        break;
    }
    return n;
}

/* Draws vertices [first, first + count) of the enabled arrays. indices: count index_count of
 * index_type, or NULL to draw the vertices in order. */
static void draw_arrays(struct glmt_context *c, GLenum mode, uint32_t first, uint32_t count, const void *indices,
                        GLenum index_type, uint32_t index_count)
{
    enum glmt_primitive primitive = GLMT_PRIM_TRIANGLES;
    bool native = native_primitive(mode, &primitive);
    uint32_t units;

    if (!count || !c->vertex_array.enabled || !c->vertex_array.pointer || !array_types_ok(c)) return;
    if (indices && !native)
    {
        GLMT_LOG_ONCE("glmt: glDrawElements with mode 0x%04x is not supported", mode);
        return;
    }
    units = textured_units(c);

    /* If the arena fills up halfway, the streams made so far are in the old one: start over once in
     * the new one. */
    for (int attempt = 0; attempt < 2; attempt++)
    {
        uint32_t epoch = c->arena_epoch;
        struct streams s = {.color = GLMT_NO_OFFSET, .index_offset = GLMT_NO_OFFSET, .vertex_count = count};
        bool has_color = c->color_array.enabled && c->color_array.pointer;
        bool ok = update_uniforms(c, has_color, units);

        if (ok)
        {
            s.position = array_stream(c, &c->vertex_array, STREAM_POSITION, first, count);
            ok = s.position != GLMT_NO_OFFSET;
        }
        if (ok && has_color)
        {
            s.color = array_stream(c, &c->color_array, STREAM_COLOR, first, count);
            ok = s.color != GLMT_NO_OFFSET;
        }
        for (int u = 0; ok && u < GLMT_MAX_TEX_UNITS; u++)
        {
            struct glmt_array *a = &c->unit[u].array;
            s.texcoord[u] = GLMT_NO_OFFSET;
            if (!(units & (1u << u))) continue;
            if (a->enabled && a->pointer) s.texcoord[u] = array_stream(c, a, STREAM_TEXCOORD, first, count);
            else s.texcoord[u] = constant_texcoords(c, u, count);
            ok = s.texcoord[u] != GLMT_NO_OFFSET;
        }
        if (ok && indices)
        {
            uint32_t *out = glmt_arena(c, index_count * sizeof(uint32_t), ARENA_ALIGN, &s.index_offset);
            if ((ok = out != NULL))
            {
                if (index_type == GL_UNSIGNED_INT) memcpy(out, indices, index_count * sizeof(uint32_t));
                else if (index_type == GL_UNSIGNED_SHORT)
                    for (uint32_t i = 0; i < index_count; i++) out[i] = ((const uint16_t *)indices)[i];
                else
                    for (uint32_t i = 0; i < index_count; i++) out[i] = ((const uint8_t *)indices)[i];
                s.index_count = index_count;
                /* Vertex first of the arrays is vertex 0 of the streams. */
                s.base_vertex = -(int32_t)first;
                c->stats.arena_bytes += index_count * sizeof(uint32_t);
            }
        }
        else if (ok && !native)
        {
            s.index_count = generated_indices(c, mode, count, &primitive, &s.index_offset);
            ok = s.index_count != 0;
        }
        if (epoch != c->arena_epoch) continue;
        if (ok) emit_draw(c, primitive, &s, units);
        else GLMT_LOG_ONCE("glmt: a draw of %u vertices does not fit the frame arena and is dropped", count);
        return;
    }
    GLMT_LOG_ONCE("glmt: a draw of %u vertices fills more than one frame arena and is dropped", count);
}

/* ---- current color and texture coordinate ---- */

static void set_color(float r, float g, float b, float a)
{
    GLMT_CONTEXT();
    c->color[0] = r;
    c->color[1] = g;
    c->color[2] = b;
    c->color[3] = a;
}

void glmt_glColor3f(GLfloat red, GLfloat green, GLfloat blue) { set_color(red, green, blue, 1.0f); }
void glmt_glColor3fv(const GLfloat *v) { set_color(v[0], v[1], v[2], 1.0f); }
void glmt_glColor3ub(GLubyte red, GLubyte green, GLubyte blue)
{
    set_color(red / 255.0f, green / 255.0f, blue / 255.0f, 1.0f);
}
void glmt_glColor3ubv(const GLubyte *v) { set_color(v[0] / 255.0f, v[1] / 255.0f, v[2] / 255.0f, 1.0f); }
void glmt_glColor4f(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) { set_color(red, green, blue, alpha); }
void glmt_glColor4fv(const GLfloat *v) { set_color(v[0], v[1], v[2], v[3]); }
void glmt_glColor4ub(GLubyte red, GLubyte green, GLubyte blue, GLubyte alpha)
{
    set_color(red / 255.0f, green / 255.0f, blue / 255.0f, alpha / 255.0f);
}
void glmt_glColor4ubv(const GLubyte *v)
{
    set_color(v[0] / 255.0f, v[1] / 255.0f, v[2] / 255.0f, v[3] / 255.0f);
}

static void set_texcoord(GLenum target, float s, float t)
{
    GLMT_CONTEXT();
    if (target < GL_TEXTURE0 || target >= GL_TEXTURE0 + GLMT_MAX_TEX_UNITS) return;
    c->unit[target - GL_TEXTURE0].texcoord[0] = s;
    c->unit[target - GL_TEXTURE0].texcoord[1] = t;
}

void glmt_glTexCoord2f(GLfloat s, GLfloat t) { set_texcoord(GL_TEXTURE0, s, t); }
void glmt_glTexCoord2fv(const GLfloat *v) { set_texcoord(GL_TEXTURE0, v[0], v[1]); }
void glmt_glMultiTexCoord2f(GLenum target, GLfloat s, GLfloat t) { set_texcoord(target, s, t); }
void glmt_glMultiTexCoord2fARB(GLenum target, GLfloat s, GLfloat t) { set_texcoord(target, s, t); }
void glmt_glMultiTexCoord2fv(GLenum target, const GLfloat *v) { set_texcoord(target, v[0], v[1]); }
void glmt_glMultiTexCoord2fvARB(GLenum target, const GLfloat *v) { set_texcoord(target, v[0], v[1]); }

/* Normals feed lighting, which glmt does not have. */
void glmt_glNormal3f(GLfloat nx, GLfloat ny, GLfloat nz)
{
    GLMT_CONTEXT();
    (void)nx;
    (void)ny;
    (void)nz;
}

void glmt_glNormal3fv(const GLfloat *v)
{
    GLMT_CONTEXT();
    (void)v;
}

/* ---- glBegin to glEnd ---- */

void glmt_glBegin(GLenum mode)
{
    GLMT_CONTEXT();
    GLMT_TRACE_ARGS("mode %u", mode);
    if (c->in_begin || mode > GL_POLYGON)
    {
        glmt_set_error(c, c->in_begin ? GL_INVALID_OPERATION : GL_INVALID_ENUM);
        return;
    }
    c->in_begin = true;
    c->begin_mode = mode;
    c->imm_count = 0;
}

static void imm_vertex(struct glmt_context *c, float x, float y, float z)
{
    uint32_t i = c->imm_count;

    if (!c->in_begin) return;
    if (i >= GLMT_IMMEDIATE_VERTICES)
    {
        GLMT_LOG_ONCE("glmt: more than %d vertices between glBegin and glEnd, the rest is dropped",
                      GLMT_IMMEDIATE_VERTICES);
        return;
    }
    c->imm_position[i][0] = x;
    c->imm_position[i][1] = y;
    c->imm_position[i][2] = z;
    c->imm_position[i][3] = 1.0f;
    for (int k = 0; k < 4; k++) c->imm_color[i][k] = float_to_ubyte(c->color[k]);
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
    {
        c->imm_texcoord[u][i][0] = c->unit[u].texcoord[0];
        c->imm_texcoord[u][i][1] = c->unit[u].texcoord[1];
    }
    c->imm_count = i + 1;
}

void glmt_glVertex2f(GLfloat x, GLfloat y)
{
    GLMT_CONTEXT();
    imm_vertex(c, x, y, 0.0f);
}

void glmt_glVertex2fv(const GLfloat *v)
{
    GLMT_CONTEXT();
    imm_vertex(c, v[0], v[1], 0.0f);
}

void glmt_glVertex2i(GLint x, GLint y)
{
    GLMT_CONTEXT();
    imm_vertex(c, (float)x, (float)y, 0.0f);
}

void glmt_glVertex3f(GLfloat x, GLfloat y, GLfloat z)
{
    GLMT_CONTEXT();
    imm_vertex(c, x, y, z);
}

void glmt_glVertex3fv(const GLfloat *v)
{
    GLMT_CONTEXT();
    imm_vertex(c, v[0], v[1], v[2]);
}

/* ---- the other spellings: one line each, onto the three functions above ---- */

void glmt_glColor3d(GLdouble red, GLdouble green, GLdouble blue) { set_color((float)red, (float)green, (float)blue, 1.0f); }
void glmt_glColor3dv(const GLdouble *v) { set_color((float)v[0], (float)v[1], (float)v[2], 1.0f); }
void glmt_glColor4d(GLdouble red, GLdouble green, GLdouble blue, GLdouble alpha)
{
    set_color((float)red, (float)green, (float)blue, (float)alpha);
}
void glmt_glColor4dv(const GLdouble *v) { set_color((float)v[0], (float)v[1], (float)v[2], (float)v[3]); }

/* (the r and q coordinates are for 3D textures and projective texturing: glmt has neither) */
void glmt_glTexCoord1f(GLfloat s) { set_texcoord(GL_TEXTURE0, s, 0.0f); }
void glmt_glTexCoord1d(GLdouble s) { set_texcoord(GL_TEXTURE0, (float)s, 0.0f); }
void glmt_glTexCoord2d(GLdouble s, GLdouble t) { set_texcoord(GL_TEXTURE0, (float)s, (float)t); }
void glmt_glTexCoord2dv(const GLdouble *v) { set_texcoord(GL_TEXTURE0, (float)v[0], (float)v[1]); }
void glmt_glTexCoord2i(GLint s, GLint t) { set_texcoord(GL_TEXTURE0, (float)s, (float)t); }
void glmt_glTexCoord2iv(const GLint *v) { set_texcoord(GL_TEXTURE0, (float)v[0], (float)v[1]); }
void glmt_glTexCoord2s(GLshort s, GLshort t) { set_texcoord(GL_TEXTURE0, (float)s, (float)t); }
void glmt_glTexCoord2sv(const GLshort *v) { set_texcoord(GL_TEXTURE0, (float)v[0], (float)v[1]); }
void glmt_glTexCoord3f(GLfloat s, GLfloat t, GLfloat r) { set_texcoord(GL_TEXTURE0, s, t); }
void glmt_glTexCoord3fv(const GLfloat *v) { set_texcoord(GL_TEXTURE0, v[0], v[1]); }
void glmt_glTexCoord3d(GLdouble s, GLdouble t, GLdouble r) { set_texcoord(GL_TEXTURE0, (float)s, (float)t); }
void glmt_glTexCoord3dv(const GLdouble *v) { set_texcoord(GL_TEXTURE0, (float)v[0], (float)v[1]); }
void glmt_glTexCoord4f(GLfloat s, GLfloat t, GLfloat r, GLfloat q) { set_texcoord(GL_TEXTURE0, s, t); }
void glmt_glTexCoord4fv(const GLfloat *v) { set_texcoord(GL_TEXTURE0, v[0], v[1]); }
void glmt_glTexCoord4d(GLdouble s, GLdouble t, GLdouble r, GLdouble q) { set_texcoord(GL_TEXTURE0, (float)s, (float)t); }
void glmt_glTexCoord4dv(const GLdouble *v) { set_texcoord(GL_TEXTURE0, (float)v[0], (float)v[1]); }

/* A vertex with a w of its own: glmt's position stream has none, so divide here. */
static void vertex4(float x, float y, float z, float w)
{
    GLMT_CONTEXT();
    if (w != 0.0f && w != 1.0f) x /= w, y /= w, z /= w;
    imm_vertex(c, x, y, z);
}

void glmt_glVertex2d(GLdouble x, GLdouble y) { vertex4((float)x, (float)y, 0.0f, 1.0f); }
void glmt_glVertex2dv(const GLdouble *v) { vertex4((float)v[0], (float)v[1], 0.0f, 1.0f); }
void glmt_glVertex2iv(const GLint *v) { vertex4((float)v[0], (float)v[1], 0.0f, 1.0f); }
void glmt_glVertex2s(GLshort x, GLshort y) { vertex4((float)x, (float)y, 0.0f, 1.0f); }
void glmt_glVertex2sv(const GLshort *v) { vertex4((float)v[0], (float)v[1], 0.0f, 1.0f); }
void glmt_glVertex3d(GLdouble x, GLdouble y, GLdouble z) { vertex4((float)x, (float)y, (float)z, 1.0f); }
void glmt_glVertex3dv(const GLdouble *v) { vertex4((float)v[0], (float)v[1], (float)v[2], 1.0f); }
void glmt_glVertex3i(GLint x, GLint y, GLint z) { vertex4((float)x, (float)y, (float)z, 1.0f); }
void glmt_glVertex3iv(const GLint *v) { vertex4((float)v[0], (float)v[1], (float)v[2], 1.0f); }
void glmt_glVertex3s(GLshort x, GLshort y, GLshort z) { vertex4((float)x, (float)y, (float)z, 1.0f); }
void glmt_glVertex3sv(const GLshort *v) { vertex4((float)v[0], (float)v[1], (float)v[2], 1.0f); }
void glmt_glVertex4f(GLfloat x, GLfloat y, GLfloat z, GLfloat w) { vertex4(x, y, z, w); }
void glmt_glVertex4fv(const GLfloat *v) { vertex4(v[0], v[1], v[2], v[3]); }
void glmt_glVertex4d(GLdouble x, GLdouble y, GLdouble z, GLdouble w) { vertex4((float)x, (float)y, (float)z, (float)w); }
void glmt_glVertex4dv(const GLdouble *v) { vertex4((float)v[0], (float)v[1], (float)v[2], (float)v[3]); }

/* glRect is a polygon with these four corners at z = 0. */
void glmt_glRectf(GLfloat x1, GLfloat y1, GLfloat x2, GLfloat y2)
{
    glmt_glBegin(GL_POLYGON);
    glmt_glVertex2f(x1, y1);
    glmt_glVertex2f(x2, y1);
    glmt_glVertex2f(x2, y2);
    glmt_glVertex2f(x1, y2);
    glmt_glEnd();
}

void glmt_glRectd(GLdouble x1, GLdouble y1, GLdouble x2, GLdouble y2)
{
    glmt_glRectf((float)x1, (float)y1, (float)x2, (float)y2);
}

void glmt_glRecti(GLint x1, GLint y1, GLint x2, GLint y2)
{
    glmt_glRectf((float)x1, (float)y1, (float)x2, (float)y2);
}

/* A vertex from the enabled arrays (id Tech 3 with r_primitives 1 or 3). */
void glmt_glArrayElement(GLint i)
{
    GLMT_CONTEXT();
    float position[4];

    if (!c->in_begin || !c->vertex_array.enabled || !c->vertex_array.pointer || i < 0 || !array_types_ok(c)) return;
    if (c->color_array.enabled && c->color_array.pointer)
    {
        uint8_t color[4];
        copy_colors(color, &c->color_array, (uint32_t)i, 1);
        for (int k = 0; k < 4; k++) c->color[k] = color[k] / 255.0f;
    }
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
        if (c->unit[u].array.enabled && c->unit[u].array.pointer)
            copy_texcoords(c->unit[u].texcoord, &c->unit[u].array, (uint32_t)i, 1);
    copy_positions(position, &c->vertex_array, (uint32_t)i, 1);
    imm_vertex(c, position[0], position[1], position[2]);
}

void glmt_glEnd(void)
{
    GLMT_CONTEXT();
    enum glmt_primitive primitive = GLMT_PRIM_TRIANGLES;
    bool native;
    uint32_t count, units;

    if (!c->in_begin)
    {
        glmt_set_error(c, GL_INVALID_OPERATION);
        return;
    }
    c->in_begin = false;
    count = c->imm_count;
    native = native_primitive(c->begin_mode, &primitive);
    GLMT_TRACE_ARGS("%u vertices", count);
    if (!count) return;
    units = textured_units(c);

    for (int attempt = 0; attempt < 2; attempt++)
    {
        uint32_t epoch = c->arena_epoch;
        struct streams s = {.index_offset = GLMT_NO_OFFSET, .vertex_count = count};
        void *memory;
        bool ok = update_uniforms(c, true, units);

        if (ok && (ok = (memory = glmt_arena(c, count * GLMT_POSITION_STRIDE, ARENA_ALIGN, &s.position)) != NULL))
            memcpy(memory, c->imm_position, (size_t)count * GLMT_POSITION_STRIDE);
        if (ok && (ok = (memory = glmt_arena(c, count * GLMT_COLOR_STRIDE, ARENA_ALIGN, &s.color)) != NULL))
            memcpy(memory, c->imm_color, (size_t)count * GLMT_COLOR_STRIDE);
        for (int u = 0; ok && u < GLMT_MAX_TEX_UNITS; u++)
        {
            s.texcoord[u] = GLMT_NO_OFFSET;
            if (!(units & (1u << u))) continue;
            if ((ok = (memory = glmt_arena(c, count * GLMT_TEXCOORD_STRIDE, ARENA_ALIGN, &s.texcoord[u])) != NULL))
                memcpy(memory, c->imm_texcoord[u], (size_t)count * GLMT_TEXCOORD_STRIDE);
        }
        if (ok && !native)
        {
            s.index_count = generated_indices(c, c->begin_mode, count, &primitive, &s.index_offset);
            ok = s.index_count != 0;
        }
        if (epoch != c->arena_epoch) continue;
        if (ok) emit_draw(c, primitive, &s, units);
        return;
    }
}

/* ---- client arrays ---- */

static struct glmt_array *client_array(struct glmt_context *c, GLenum array)
{
    switch (array)
    {
    case GL_VERTEX_ARRAY: return &c->vertex_array;
    case GL_COLOR_ARRAY: return &c->color_array;
    case GL_TEXTURE_COORD_ARRAY: return &c->unit[c->client_unit].array;
    default: return NULL;
    }
}

void glmt_glEnableClientState(GLenum array)
{
    GLMT_CONTEXT();
    struct glmt_array *a = client_array(c, array);
    /* Normals, indices and edge flags have nothing to feed in glmt. */
    if (a) a->enabled = true;
}

void glmt_glDisableClientState(GLenum array)
{
    GLMT_CONTEXT();
    struct glmt_array *a = client_array(c, array);
    if (!a) return;
    a->enabled = false;
    a->compiled = false;
}

void glmt_glClientActiveTexture(GLenum texture)
{
    GLMT_CONTEXT();
    if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + GLMT_MAX_TEX_UNITS)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->client_unit = (int)(texture - GL_TEXTURE0);
}

void glmt_glClientActiveTextureARB(GLenum texture) { glmt_glClientActiveTexture(texture); }

static void set_pointer(struct glmt_array *a, GLint size, GLenum type, GLsizei stride, const void *pointer)
{
    a->size = size;
    a->type = type;
    a->stride = stride;
    a->pointer = pointer;
    /* New contents, even at an address seen before: the copy made under the lock is not this. */
    a->compiled = false;
}

void glmt_glVertexPointer(GLint size, GLenum type, GLsizei stride, const void *pointer)
{
    GLMT_CONTEXT();
    if (size < 2 || size > 4 || stride < 0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    set_pointer(&c->vertex_array, size, type, stride, pointer);
}

void glmt_glColorPointer(GLint size, GLenum type, GLsizei stride, const void *pointer)
{
    GLMT_CONTEXT();
    if (size < 3 || size > 4 || stride < 0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    set_pointer(&c->color_array, size, type, stride, pointer);
}

void glmt_glTexCoordPointer(GLint size, GLenum type, GLsizei stride, const void *pointer)
{
    GLMT_CONTEXT();
    if (size < 1 || size > 4 || stride < 0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    set_pointer(&c->unit[c->client_unit].array, size, type, stride, pointer);
}

void glmt_glNormalPointer(GLenum type, GLsizei stride, const void *pointer)
{
    GLMT_CONTEXT();
    (void)type;
    (void)stride;
    (void)pointer;
}

void glmt_glLockArraysEXT(GLint first, GLsizei count)
{
    GLMT_CONTEXT();
    if (first < 0 || count <= 0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    c->locked = true;
    c->lock_first = first;
    c->lock_count = count;
    c->copy_serial++;
    c->vertex_array.compiled = c->vertex_array.enabled;
    c->color_array.compiled = c->color_array.enabled;
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++) c->unit[u].array.compiled = c->unit[u].array.enabled;
}

void glmt_glUnlockArraysEXT(void)
{
    GLMT_CONTEXT();
    c->locked = false;
    c->copy_serial++;
    c->vertex_array.compiled = c->color_array.compiled = false;
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++) c->unit[u].array.compiled = false;
}

void glmt_glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices)
{
    GLMT_CONTEXT();
    uint32_t first, last;

    GLMT_TRACE_ARGS("mode %u, %d indices, %s", mode, count, c->locked ? "locked" : "not locked");
    if (count <= 0 || !indices || c->in_begin) return;
    if (type != GL_UNSIGNED_INT && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_BYTE)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    if (c->locked)
    {
        /* The application promised that the indices stay inside the lock. */
        first = (uint32_t)c->lock_first;
        last = first + (uint32_t)c->lock_count - 1;
    }
    else
    {
        first = 0xffffffffu;
        last = 0;
        for (GLsizei i = 0; i < count; i++)
        {
            uint32_t index = type == GL_UNSIGNED_INT ? ((const uint32_t *)indices)[i]
                             : type == GL_UNSIGNED_SHORT ? ((const uint16_t *)indices)[i]
                                                         : ((const uint8_t *)indices)[i];
            if (index < first) first = index;
            if (index > last) last = index;
        }
    }
    draw_arrays(c, mode, first, last - first + 1, indices, type, (uint32_t)count);
}

void glmt_glDrawArrays(GLenum mode, GLint first, GLsizei count)
{
    GLMT_CONTEXT();
    GLMT_TRACE_ARGS("mode %u, first %d, count %d", mode, first, count);
    if (count <= 0 || first < 0 || c->in_begin) return;
    if (mode > GL_POLYGON)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    draw_arrays(c, mode, (uint32_t)first, (uint32_t)count, NULL, 0, 0);
}

/* ---- clear and read back ---- */

void glmt_glClear(GLbitfield mask)
{
    GLMT_CONTEXT();
    struct glmt_cmd_clear *clear;
    uint32_t bits = 0;

    GLMT_TRACE_ARGS("mask 0x%x", mask);
    /* A buffer nothing may write to is not cleared either. */
    if ((mask & GL_COLOR_BUFFER_BIT) && color_mask_bits(c)) bits |= GLMT_CLEAR_COLOR;
    if ((mask & GL_DEPTH_BUFFER_BIT) && c->depth_mask) bits |= GLMT_CLEAR_DEPTH;
    if ((mask & GL_STENCIL_BUFFER_BIT) && (c->stencil_write_mask & 0xffu) && c->surface &&
        c->surface->format.stencil_bits)
        bits |= GLMT_CLEAR_STENCIL;
    if (!bits || !(clear = glmt_packet(c, GLMT_CMD_CLEAR, sizeof(*clear)))) return;

    clear->mask = bits;
    memcpy(clear->color, c->clear_color, sizeof(clear->color));
    clear->depth = (float)c->clear_depth;
    clear->stencil = (uint32_t)c->clear_stencil & 0xffu;
    clear->color_mask = color_mask_bits(c);
    clear->stencil_mask = c->stencil_write_mask & 0xffu;
    clear->scissor_on = c->scissor_test;
    memcpy(clear->scissor, c->scissor, sizeof(clear->scissor));
    c->stats.clears++;
}

void glmt_glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void *pixels)
{
    GLMT_CONTEXT();
    int comps = format == GL_RGBA || format == GL_BGRA ? 4 : format == GL_RGB || format == GL_BGR ? 3 : 0;
    int row_pixels = c->pack_row_length > 0 ? c->pack_row_length : width;
    int align = c->pack_alignment > 0 ? c->pack_alignment : 1;
    size_t row_bytes;
    uint8_t *rgba, *base;

    if (width <= 0 || height <= 0 || !pixels || !c->surface) return;
    if (!comps || type != GL_UNSIGNED_BYTE)
    {
        /* Depth and stencil read-backs (id Tech 3's r_flares) would stall every frame they are in. */
        GLMT_LOG_ONCE("glmt: glReadPixels(format 0x%04x, type 0x%04x) is not supported", format, type);
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    if (!(rgba = malloc((size_t)width * height * 4)))
    {
        glmt_set_error(c, GL_OUT_OF_MEMORY);
        return;
    }
    glmt_flush_packets(c);
    c->be->read_pixels(c->be, c->surface->be_surface, x, y, width, height, rgba);

    row_bytes = ((size_t)row_pixels * comps + align - 1) / align * align;
    base = (uint8_t *)pixels + (size_t)c->pack_skip_rows * row_bytes + (size_t)c->pack_skip_pixels * comps;
    for (int row = 0; row < height; row++)
    {
        const uint8_t *in = rgba + (size_t)row * width * 4;
        uint8_t *out = base + (size_t)row * row_bytes;
        bool swap = format == GL_BGR || format == GL_BGRA;

        for (int i = 0; i < width; i++, in += 4, out += comps)
        {
            out[0] = in[swap ? 2 : 0];
            out[1] = in[1];
            out[2] = in[swap ? 0 : 2];
            if (comps == 4) out[3] = in[3];
        }
    }
    free(rgba);
}
