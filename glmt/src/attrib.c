/* glPushAttrib and glPushClientAttrib.
 *
 * id Tech 3 never calls them. Steam's overlay does, around everything it draws into the game's
 * frame: it saves all state, sets its own, draws, and puts the game's back. Without a working pop
 * the overlay's state would leak into the game's next draw. */
#include <stdlib.h>
#include <string.h>

#include "api.h"
#include "internal.h"

/* The fields of the context that glPushAttrib covers, each with the mask bits that restore it. */
#define ATTRIB_FIELDS(X) \
    X(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT, alpha_test) \
    X(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT, blend) \
    X(GL_ENABLE_BIT | GL_DEPTH_BUFFER_BIT, depth_test) \
    X(GL_ENABLE_BIT | GL_STENCIL_BUFFER_BIT, stencil_test) \
    X(GL_ENABLE_BIT | GL_POLYGON_BIT, cull_face) \
    X(GL_ENABLE_BIT | GL_SCISSOR_BIT, scissor_test) \
    X(GL_ENABLE_BIT | GL_POLYGON_BIT, polygon_offset_fill) \
    X(GL_ENABLE_BIT | GL_TRANSFORM_BIT, clip_plane0) \
    X(GL_COLOR_BUFFER_BIT, alpha_func) \
    X(GL_COLOR_BUFFER_BIT, alpha_ref) \
    X(GL_COLOR_BUFFER_BIT, blend_src) \
    X(GL_COLOR_BUFFER_BIT, blend_dst) \
    X(GL_COLOR_BUFFER_BIT, color_mask) \
    X(GL_COLOR_BUFFER_BIT, clear_color) \
    X(GL_COLOR_BUFFER_BIT, draw_buffer) \
    X(GL_DEPTH_BUFFER_BIT, depth_func) \
    X(GL_DEPTH_BUFFER_BIT, depth_mask) \
    X(GL_DEPTH_BUFFER_BIT, clear_depth) \
    X(GL_STENCIL_BUFFER_BIT, stencil_func) \
    X(GL_STENCIL_BUFFER_BIT, stencil_ref) \
    X(GL_STENCIL_BUFFER_BIT, stencil_value_mask) \
    X(GL_STENCIL_BUFFER_BIT, stencil_sfail) \
    X(GL_STENCIL_BUFFER_BIT, stencil_zfail) \
    X(GL_STENCIL_BUFFER_BIT, stencil_zpass) \
    X(GL_STENCIL_BUFFER_BIT, stencil_write_mask) \
    X(GL_STENCIL_BUFFER_BIT, clear_stencil) \
    X(GL_POLYGON_BIT, cull_mode) \
    X(GL_POLYGON_BIT, front_face) \
    X(GL_POLYGON_BIT, polygon_mode) \
    X(GL_POLYGON_BIT, polygon_offset_factor) \
    X(GL_POLYGON_BIT, polygon_offset_units) \
    X(GL_LIGHTING_BIT, shade_model) \
    X(GL_SCISSOR_BIT, scissor) \
    X(GL_VIEWPORT_BIT, viewport) \
    X(GL_VIEWPORT_BIT, depth_near) \
    X(GL_VIEWPORT_BIT, depth_far) \
    X(GL_TRANSFORM_BIT, matrix_mode) \
    X(GL_TRANSFORM_BIT, clip_plane_eye) \
    X(GL_LINE_BIT, line_width) \
    X(GL_POINT_BIT, point_size) \
    X(GL_CURRENT_BIT, color)

void glmt_glPushAttrib(GLbitfield mask)
{
    GLMT_CONTEXT();
    struct glmt_saved_attribs *save;

    if (c->attrib_depth >= GLMT_ATTRIB_STACK)
    {
        glmt_set_error(c, GL_STACK_OVERFLOW);
        return;
    }
    if (!c->attrib_stack && !(c->attrib_stack = calloc(GLMT_ATTRIB_STACK, sizeof(*c->attrib_stack))))
    {
        glmt_set_error(c, GL_OUT_OF_MEMORY);
        return;
    }
    save = &c->attrib_stack[c->attrib_depth++];
    save->mask = mask;
#define X(bits, field) memcpy(&save->field, &c->field, sizeof(save->field));
    ATTRIB_FIELDS(X)
#undef X
    save->active_unit = c->active_unit;
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
    {
        save->unit_enabled[u] = c->unit[u].enabled;
        save->unit_bound[u] = c->unit[u].bound;
        save->unit_env_mode[u] = c->unit[u].env_mode;
        memcpy(save->unit_texcoord[u], c->unit[u].texcoord, sizeof(save->unit_texcoord[u]));
    }
}

void glmt_glPopAttrib(void)
{
    GLMT_CONTEXT();
    const struct glmt_saved_attribs *save;

    if (!c->attrib_depth)
    {
        glmt_set_error(c, GL_STACK_UNDERFLOW);
        return;
    }
    save = &c->attrib_stack[--c->attrib_depth];
#define X(bits, field) \
    if (save->mask & (bits)) memcpy(&c->field, &save->field, sizeof(save->field));
    ATTRIB_FIELDS(X)
#undef X
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
    {
        if (save->mask & (GL_ENABLE_BIT | GL_TEXTURE_BIT)) c->unit[u].enabled = save->unit_enabled[u];
        if (save->mask & GL_CURRENT_BIT) memcpy(c->unit[u].texcoord, save->unit_texcoord[u], sizeof(save->unit_texcoord[u]));
        if (save->mask & GL_TEXTURE_BIT)
        {
            c->unit[u].env_mode = save->unit_env_mode[u];
            /* (the texture may have been deleted since: the unit then has none, as in OpenGL the
             * binding of a deleted name goes back to 0) */
            c->unit[u].texture = glmt_texture_lookup(c->share, save->unit_bound[u]);
            c->unit[u].bound = c->unit[u].texture ? save->unit_bound[u] : 0;
        }
    }
    if (save->mask & GL_TEXTURE_BIT) c->active_unit = save->active_unit;
}

void glmt_glPushClientAttrib(GLbitfield mask)
{
    GLMT_CONTEXT();
    struct glmt_saved_client *save;

    if (c->client_depth >= GLMT_ATTRIB_STACK)
    {
        glmt_set_error(c, GL_STACK_OVERFLOW);
        return;
    }
    if (!c->client_stack && !(c->client_stack = calloc(GLMT_ATTRIB_STACK, sizeof(*c->client_stack))))
    {
        glmt_set_error(c, GL_OUT_OF_MEMORY);
        return;
    }
    save = &c->client_stack[c->client_depth++];
    save->mask = mask;
    save->unpack_alignment = c->unpack_alignment;
    save->unpack_row_length = c->unpack_row_length;
    save->unpack_skip_rows = c->unpack_skip_rows;
    save->unpack_skip_pixels = c->unpack_skip_pixels;
    save->pack_alignment = c->pack_alignment;
    save->pack_row_length = c->pack_row_length;
    save->pack_skip_rows = c->pack_skip_rows;
    save->pack_skip_pixels = c->pack_skip_pixels;
    save->client_unit = c->client_unit;
    save->vertex_array = c->vertex_array;
    save->color_array = c->color_array;
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++) save->texcoord_array[u] = c->unit[u].array;
}

void glmt_glPopClientAttrib(void)
{
    GLMT_CONTEXT();
    const struct glmt_saved_client *save;

    if (!c->client_depth)
    {
        glmt_set_error(c, GL_STACK_UNDERFLOW);
        return;
    }
    save = &c->client_stack[--c->client_depth];
    if (save->mask & GL_CLIENT_PIXEL_STORE_BIT)
    {
        c->unpack_alignment = save->unpack_alignment;
        c->unpack_row_length = save->unpack_row_length;
        c->unpack_skip_rows = save->unpack_skip_rows;
        c->unpack_skip_pixels = save->unpack_skip_pixels;
        c->pack_alignment = save->pack_alignment;
        c->pack_row_length = save->pack_row_length;
        c->pack_skip_rows = save->pack_skip_rows;
        c->pack_skip_pixels = save->pack_skip_pixels;
    }
    if (save->mask & GL_CLIENT_VERTEX_ARRAY_BIT)
    {
        c->client_unit = save->client_unit;
        c->vertex_array = save->vertex_array;
        c->color_array = save->color_array;
        for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++) c->unit[u].array = save->texcoord_array[u];
        /* What was copied under a lock before the push may be gone: copy again. */
        c->copy_serial++;
    }
}

/* Selection and feedback do not exist in glmt; rendering is the only mode. The value returned for
 * a switch away from GL_RENDER is 0: no hits, nothing fed back. */
GLint glmt_glRenderMode(GLenum mode)
{
    GLMT_CONTEXT(0);
    if (mode != GL_RENDER) GLMT_LOG_ONCE("glmt: glRenderMode(0x%04x): glmt only renders", mode);
    return 0;
}

/* It scales glDrawPixels and glCopyPixels, which glmt does not have. */
void glmt_glPixelZoom(GLfloat xfactor, GLfloat yfactor)
{
    GLMT_CONTEXT();
    (void)xfactor;
    (void)yfactor;
}
