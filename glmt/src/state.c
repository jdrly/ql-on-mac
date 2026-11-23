/* Fixed-function state that is only stored until a draw reads it, and the queries. */
#include <string.h>

#include "api.h"
#include "internal.h"

/* What Quake Live's renderer gets. GL_EXT_compiled_vertex_array is what puts id Tech 3 on
 * glDrawElements (r_primitives 2) instead of a glArrayElement call per index; the multitexture pair
 * gives lightmapped surfaces one pass instead of two. Nothing here promises shaders, framebuffer
 * objects or buffer objects, so the game stays on its fixed-function path. */
static const char extensions[] =
    "GL_ARB_multitexture "
    "GL_EXT_compiled_vertex_array "
    "GL_EXT_texture_env_add "
    "GL_ARB_texture_env_add "
    "GL_EXT_texture_filter_anisotropic "
    "GL_EXT_texture_edge_clamp "
    "GL_SGIS_texture_edge_clamp "
    "GL_EXT_bgra";

const char *glmt_extensions(void) { return extensions; }

void glmt_set_error_at(struct glmt_context *c, GLenum error, const char *function)
{
    static unsigned int logged;

    if (c->error == GL_NO_ERROR) c->error = error;
    /* (function is glmt_glName, or a helper's name where a helper raised it) */
    if (glmt_debug && logged < 200)
    {
        logged++;
        glmt_log("glmt: OpenGL error 0x%04x in %s%s", error, function, logged == 200 ? " (further errors are not logged)" : "");
    }
}

static bool is_compare(GLenum func) { return func >= GL_NEVER && func <= GL_ALWAYS; }

/* The capability's flag, or NULL for one glmt has no state for. */
static bool *capability(struct glmt_context *c, GLenum cap)
{
    switch (cap)
    {
    case GL_ALPHA_TEST: return &c->alpha_test;
    case GL_BLEND: return &c->blend;
    case GL_DEPTH_TEST: return &c->depth_test;
    case GL_STENCIL_TEST: return &c->stencil_test;
    case GL_CULL_FACE: return &c->cull_face;
    case GL_SCISSOR_TEST: return &c->scissor_test;
    case GL_POLYGON_OFFSET_FILL: return &c->polygon_offset_fill;
    case GL_CLIP_PLANE0: return &c->clip_plane0;
    case GL_TEXTURE_2D: return &c->unit[c->active_unit].enabled;
    default: return NULL;
    }
}

static void set_capability(struct glmt_context *c, GLenum cap, bool on)
{
    bool *flag = capability(c, cap);

    if (flag)
    {
        *flag = on;
        return;
    }
    switch (cap)
    {
    /* Accepted, with no effect on what glmt draws. */
    case GL_DITHER:
    case GL_MULTISAMPLE:
    case GL_NORMALIZE:
    case GL_RESCALE_NORMAL:
    case GL_LINE_SMOOTH:
    case GL_POINT_SMOOTH:
    case GL_POLYGON_SMOOTH:
    case GL_POLYGON_OFFSET_LINE:
    case GL_POLYGON_OFFSET_POINT:
        return;
    /* Fixed-function features glmt does not draw: fine while they stay off. */
    case GL_FOG:
    case GL_LIGHTING:
    case GL_COLOR_MATERIAL:
    case GL_LINE_STIPPLE:
    case GL_TEXTURE_1D:
    case GL_TEXTURE_CUBE_MAP:
    case GL_TEXTURE_GEN_S:
    case GL_TEXTURE_GEN_T:
    case GL_TEXTURE_GEN_R:
    case GL_TEXTURE_GEN_Q:
        if (on) glmt_log("glmt: glEnable(0x%04x) asks for a feature glmt does not draw", cap);
        return;
    default:
        if (cap > GL_CLIP_PLANE0 && cap < GL_CLIP_PLANE0 + 6)
        {
            if (on) glmt_log("glmt: clip plane %u is enabled, and glmt has only plane 0", cap - GL_CLIP_PLANE0);
            return;
        }
        /* Anything else is a capability glmt does not have, and so one that is off. Turning it off
         * again is what code does that resets all state before it draws (Steam's overlay: logic
         * op, color sum, 3D and rectangle textures, vertex and fragment programs), and is no
         * error. Turning it on is worth one line per capability. */
        if (on)
        {
            static GLenum seen[32];
            static int seen_count;
            int i;

            for (i = 0; i < seen_count && seen[i] != cap; i++) {}
            if (i == seen_count && seen_count < 32)
            {
                seen[seen_count++] = cap;
                glmt_log("glmt: glEnable(0x%04x): glmt does not have this capability", cap);
            }
            glmt_set_error(c, GL_INVALID_ENUM);
        }
    }
}

void glmt_glEnable(GLenum cap)
{
    GLMT_CONTEXT();
    GLMT_TRACE_ARGS("cap 0x%04x", cap);
    set_capability(c, cap, true);
}

void glmt_glDisable(GLenum cap)
{
    GLMT_CONTEXT();
    GLMT_TRACE_ARGS("cap 0x%04x", cap);
    set_capability(c, cap, false);
}

GLboolean glmt_glIsEnabled(GLenum cap)
{
    GLMT_CONTEXT(GL_FALSE);
    bool *flag = capability(c, cap);
    return flag && *flag;
}

void glmt_glAlphaFunc(GLenum func, GLclampf ref)
{
    GLMT_CONTEXT();
    if (!is_compare(func))
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->alpha_func = func;
    c->alpha_ref = ref < 0.0f ? 0.0f : ref > 1.0f ? 1.0f : ref;
}

void glmt_glBlendFunc(GLenum sfactor, GLenum dfactor)
{
    GLMT_CONTEXT();
    c->blend_src = sfactor;
    c->blend_dst = dfactor;
}

void glmt_glDepthFunc(GLenum func)
{
    GLMT_CONTEXT();
    if (!is_compare(func))
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->depth_func = func;
}

void glmt_glDepthMask(GLboolean flag)
{
    GLMT_CONTEXT();
    c->depth_mask = flag != GL_FALSE;
}

void glmt_glDepthRange(GLclampd n, GLclampd f)
{
    GLMT_CONTEXT();
    c->depth_near = n < 0.0 ? 0.0 : n > 1.0 ? 1.0 : n;
    c->depth_far = f < 0.0 ? 0.0 : f > 1.0 ? 1.0 : f;
}

void glmt_glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha)
{
    GLMT_CONTEXT();
    c->color_mask[0] = red != GL_FALSE;
    c->color_mask[1] = green != GL_FALSE;
    c->color_mask[2] = blue != GL_FALSE;
    c->color_mask[3] = alpha != GL_FALSE;
}

void glmt_glCullFace(GLenum mode)
{
    GLMT_CONTEXT();
    if (mode != GL_FRONT && mode != GL_BACK && mode != GL_FRONT_AND_BACK)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->cull_mode = mode;
}

void glmt_glFrontFace(GLenum mode)
{
    GLMT_CONTEXT();
    if (mode != GL_CW && mode != GL_CCW)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->front_face = mode;
}

void glmt_glPolygonMode(GLenum face, GLenum mode)
{
    GLMT_CONTEXT();
    if (mode != GL_POINT && mode != GL_LINE && mode != GL_FILL)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    /* id Tech 3 sets both faces at once (r_showtris, r_shownormals). */
    if (face != GL_FRONT_AND_BACK) GLMT_LOG_ONCE("glmt: glPolygonMode for one face only is applied to both");
    c->polygon_mode = mode;
}

void glmt_glPolygonOffset(GLfloat factor, GLfloat units)
{
    GLMT_CONTEXT();
    c->polygon_offset_factor = factor;
    c->polygon_offset_units = units;
}

void glmt_glShadeModel(GLenum mode)
{
    GLMT_CONTEXT();
    if (mode == GL_FLAT) GLMT_LOG_ONCE("glmt: glShadeModel(GL_FLAT) is drawn smooth");
    c->shade_model = mode;
}

void glmt_glScissor(GLint x, GLint y, GLsizei width, GLsizei height)
{
    GLMT_CONTEXT();
    if (width < 0 || height < 0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    c->scissor[0] = x;
    c->scissor[1] = y;
    c->scissor[2] = width;
    c->scissor[3] = height;
}

void glmt_glViewport(GLint x, GLint y, GLsizei width, GLsizei height)
{
    GLMT_CONTEXT();
    GLMT_TRACE_ARGS("%d, %d, %d x %d", x, y, width, height);
    if (width < 0 || height < 0)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    c->viewport[0] = x;
    c->viewport[1] = y;
    c->viewport[2] = width;
    c->viewport[3] = height;
    c->viewport_set = true;
}

static float clamp01(float v) { return v < 0.0f ? 0.0f : v > 1.0f ? 1.0f : v; }

void glmt_glClearColor(GLclampf red, GLclampf green, GLclampf blue, GLclampf alpha)
{
    GLMT_CONTEXT();
    c->clear_color[0] = clamp01(red);
    c->clear_color[1] = clamp01(green);
    c->clear_color[2] = clamp01(blue);
    c->clear_color[3] = clamp01(alpha);
}

void glmt_glClearDepth(GLclampd depth)
{
    GLMT_CONTEXT();
    c->clear_depth = depth < 0.0 ? 0.0 : depth > 1.0 ? 1.0 : depth;
}

void glmt_glClearStencil(GLint s)
{
    GLMT_CONTEXT();
    c->clear_stencil = s;
}

void glmt_glStencilFunc(GLenum func, GLint ref, GLuint mask)
{
    GLMT_CONTEXT();
    if (!is_compare(func))
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->stencil_func = func;
    c->stencil_ref = ref;
    c->stencil_value_mask = mask;
}

void glmt_glStencilOp(GLenum fail, GLenum zfail, GLenum zpass)
{
    GLMT_CONTEXT();
    c->stencil_sfail = fail;
    c->stencil_zfail = zfail;
    c->stencil_zpass = zpass;
}

void glmt_glStencilMask(GLuint mask)
{
    GLMT_CONTEXT();
    c->stencil_write_mask = mask;
}

void glmt_glClipPlane(GLenum plane, const GLdouble *equation)
{
    GLMT_CONTEXT();
    float inverse[16], eq[4];

    if (plane != GL_CLIP_PLANE0)
    {
        GLMT_LOG_ONCE("glmt: glClipPlane for a plane other than 0 is ignored");
        return;
    }
    /* The plane is kept in eye space: the equation times the inverse of the modelview matrix of
     * this moment. */
    if (!glmt_matrix_invert(inverse, glmt_top(&c->modelview))) glmt_matrix_identity(inverse);
    for (int i = 0; i < 4; i++) eq[i] = (float)equation[i];
    for (int j = 0; j < 4; j++)
        c->clip_plane_eye[j] = eq[0] * inverse[j * 4 + 0] + eq[1] * inverse[j * 4 + 1] +
                               eq[2] * inverse[j * 4 + 2] + eq[3] * inverse[j * 4 + 3];
}

void glmt_glLineWidth(GLfloat width)
{
    GLMT_CONTEXT();
    c->line_width = width;
}

void glmt_glPointSize(GLfloat size)
{
    GLMT_CONTEXT();
    c->point_size = size;
}

void glmt_glHint(GLenum target, GLenum mode)
{
    GLMT_CONTEXT();
    (void)target;
    (void)mode;
}

void glmt_glDrawBuffer(GLenum buf)
{
    GLMT_CONTEXT();
    /* A window has a back buffer only: what is drawn shows at the next swap. */
    if (buf != GL_BACK && buf != GL_BACK_LEFT && buf != GL_NONE)
        GLMT_LOG_ONCE("glmt: glDrawBuffer(0x%04x): glmt draws to the back buffer", buf);
    c->draw_buffer = buf;
}

void glmt_glReadBuffer(GLenum src)
{
    GLMT_CONTEXT();
    c->read_buffer = src;
}

void glmt_glPixelStorei(GLenum pname, GLint param)
{
    GLMT_CONTEXT();
    switch (pname)
    {
    case GL_UNPACK_ALIGNMENT: c->unpack_alignment = param; break;
    case GL_UNPACK_ROW_LENGTH: c->unpack_row_length = param; break;
    case GL_UNPACK_SKIP_ROWS: c->unpack_skip_rows = param; break;
    case GL_UNPACK_SKIP_PIXELS: c->unpack_skip_pixels = param; break;
    case GL_PACK_ALIGNMENT: c->pack_alignment = param; break;
    case GL_PACK_ROW_LENGTH: c->pack_row_length = param; break;
    case GL_PACK_SKIP_ROWS: c->pack_skip_rows = param; break;
    case GL_PACK_SKIP_PIXELS: c->pack_skip_pixels = param; break;
    case GL_UNPACK_SWAP_BYTES:
    case GL_UNPACK_LSB_FIRST:
    case GL_PACK_SWAP_BYTES:
    case GL_PACK_LSB_FIRST:
        if (param) glmt_log("glmt: glPixelStore(0x%04x, %d) is not supported", pname, param);
        break;
    default: glmt_set_error(c, GL_INVALID_ENUM);
    }
}

void glmt_glPixelStoref(GLenum pname, GLfloat param) { glmt_glPixelStorei(pname, (GLint)param); }

GLenum glmt_glGetError(void)
{
    GLMT_CONTEXT(GL_INVALID_OPERATION);
    GLenum error = c->error;
    c->error = GL_NO_ERROR;
    return error;
}

const GLubyte *glmt_glGetString(GLenum name)
{
    GLMT_CONTEXT(NULL);
    switch (name)
    {
    case GL_VENDOR: return (const GLubyte *)"glmt";
    case GL_RENDERER: return (const GLubyte *)"glmt (OpenGL on Metal)";
    /* 1.3 is what glmt has all of: multitexture and the add environment are core there. */
    case GL_VERSION: return (const GLubyte *)"1.3 glmt";
    case GL_EXTENSIONS: return (const GLubyte *)extensions;
    default:
        glmt_set_error(c, GL_INVALID_ENUM);
        return NULL;
    }
}

/* Up to 16 values of a query as doubles. Returns their count, 0 for a name glmt does not know. */
static int get_values(struct glmt_context *c, GLenum pname, double v[16])
{
    const struct glmt_pixel_format *format = c->surface ? &c->surface->format : NULL;

    switch (pname)
    {
    case GL_MAX_TEXTURE_SIZE: v[0] = GLMT_MAX_TEXTURE_SIZE; return 1;
    case GL_MAX_TEXTURE_UNITS: v[0] = GLMT_MAX_TEX_UNITS; return 1;
    case GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT: v[0] = GLMT_MAX_ANISOTROPY; return 1;
    case GL_MAX_VIEWPORT_DIMS: v[0] = v[1] = GLMT_MAX_TEXTURE_SIZE; return 2;
    case GL_MAX_MODELVIEW_STACK_DEPTH: v[0] = GLMT_MODELVIEW_STACK; return 1;
    case GL_MAX_PROJECTION_STACK_DEPTH: v[0] = GLMT_PROJECTION_STACK; return 1;
    case GL_MAX_TEXTURE_STACK_DEPTH: v[0] = GLMT_TEXTURE_STACK; return 1;
    case GL_MAX_CLIP_PLANES: v[0] = 1; return 1;
    case GL_MAX_LIGHTS: v[0] = 8; return 1;
    case GL_MAX_ELEMENTS_VERTICES: v[0] = 1 << 20; return 1;
    case GL_MAX_ELEMENTS_INDICES: v[0] = 1 << 20; return 1;
    case GL_SUBPIXEL_BITS: v[0] = 8; return 1;
    case GL_RED_BITS:
    case GL_GREEN_BITS:
    case GL_BLUE_BITS: v[0] = 8; return 1;
    case GL_ALPHA_BITS: v[0] = format ? format->alpha_bits : 8; return 1;
    case GL_DEPTH_BITS: v[0] = format ? format->depth_bits : 24; return 1;
    case GL_STENCIL_BITS: v[0] = format ? format->stencil_bits : 8; return 1;
    case GL_DOUBLEBUFFER: v[0] = 1; return 1;
    case GL_STEREO:
    case GL_AUX_BUFFERS:
    case GL_SAMPLE_BUFFERS:
    case GL_SAMPLES:
    case GL_NUM_EXTENSIONS: /* glGetStringi is OpenGL 3: glmt lists extensions as one string */
    case GL_CONTEXT_FLAGS:
    case GL_CONTEXT_PROFILE_MASK:
    case GL_DRAW_FRAMEBUFFER_BINDING:
    case GL_READ_FRAMEBUFFER_BINDING: v[0] = 0; return 1;
    case GL_MAJOR_VERSION: v[0] = 1; return 1;
    case GL_MINOR_VERSION: v[0] = 3; return 1;
    case GL_VIEWPORT:
        for (int i = 0; i < 4; i++) v[i] = c->viewport[i];
        return 4;
    case GL_SCISSOR_BOX:
        for (int i = 0; i < 4; i++) v[i] = c->scissor[i];
        return 4;
    case GL_MATRIX_MODE: v[0] = c->matrix_mode; return 1;
    case GL_MODELVIEW_STACK_DEPTH: v[0] = c->modelview.depth + 1; return 1;
    case GL_PROJECTION_STACK_DEPTH: v[0] = c->projection.depth + 1; return 1;
    case GL_TEXTURE_STACK_DEPTH: v[0] = c->texture_matrix[c->active_unit].depth + 1; return 1;
    case GL_MODELVIEW_MATRIX:
        for (int i = 0; i < 16; i++) v[i] = glmt_top(&c->modelview)[i];
        return 16;
    case GL_PROJECTION_MATRIX:
        for (int i = 0; i < 16; i++) v[i] = glmt_top(&c->projection)[i];
        return 16;
    case GL_TEXTURE_MATRIX:
        for (int i = 0; i < 16; i++) v[i] = glmt_top(&c->texture_matrix[c->active_unit])[i];
        return 16;
    /* (Steam's overlay reads it before it resets it) */
    case GL_COLOR_MATRIX:
        for (int i = 0; i < 16; i++) v[i] = glmt_top(&c->color_matrix)[i];
        return 16;
    case GL_COLOR_MATRIX_STACK_DEPTH: v[0] = c->color_matrix.depth + 1; return 1;
    case GL_CURRENT_COLOR:
        for (int i = 0; i < 4; i++) v[i] = c->color[i];
        return 4;
    case GL_COLOR_CLEAR_VALUE:
        for (int i = 0; i < 4; i++) v[i] = c->clear_color[i];
        return 4;
    case GL_COLOR_WRITEMASK:
        for (int i = 0; i < 4; i++) v[i] = c->color_mask[i];
        return 4;
    case GL_DEPTH_RANGE: v[0] = c->depth_near; v[1] = c->depth_far; return 2;
    case GL_DEPTH_CLEAR_VALUE: v[0] = c->clear_depth; return 1;
    case GL_DEPTH_FUNC: v[0] = c->depth_func; return 1;
    case GL_DEPTH_WRITEMASK: v[0] = c->depth_mask; return 1;
    case GL_ALPHA_TEST_FUNC: v[0] = c->alpha_func; return 1;
    case GL_ALPHA_TEST_REF: v[0] = c->alpha_ref; return 1;
    case GL_BLEND_SRC: v[0] = c->blend_src; return 1;
    case GL_BLEND_DST: v[0] = c->blend_dst; return 1;
    case GL_CULL_FACE_MODE: v[0] = c->cull_mode; return 1;
    case GL_FRONT_FACE: v[0] = c->front_face; return 1;
    case GL_SHADE_MODEL: v[0] = c->shade_model; return 1;
    case GL_POLYGON_OFFSET_FACTOR: v[0] = c->polygon_offset_factor; return 1;
    case GL_POLYGON_OFFSET_UNITS: v[0] = c->polygon_offset_units; return 1;
    case GL_LINE_WIDTH: v[0] = c->line_width; return 1;
    case GL_POINT_SIZE: v[0] = c->point_size; return 1;
    case GL_DRAW_BUFFER: v[0] = c->draw_buffer; return 1;
    case GL_READ_BUFFER: v[0] = c->read_buffer; return 1;
    case GL_ACTIVE_TEXTURE: v[0] = GL_TEXTURE0 + c->active_unit; return 1;
    case GL_CLIENT_ACTIVE_TEXTURE: v[0] = GL_TEXTURE0 + c->client_unit; return 1;
    case GL_TEXTURE_BINDING_2D: v[0] = c->unit[c->active_unit].bound; return 1;
    case GL_UNPACK_ALIGNMENT: v[0] = c->unpack_alignment; return 1;
    case GL_UNPACK_ROW_LENGTH: v[0] = c->unpack_row_length; return 1;
    case GL_UNPACK_SKIP_ROWS: v[0] = c->unpack_skip_rows; return 1;
    case GL_UNPACK_SKIP_PIXELS: v[0] = c->unpack_skip_pixels; return 1;
    case GL_PACK_ALIGNMENT: v[0] = c->pack_alignment; return 1;
    case GL_PACK_ROW_LENGTH: v[0] = c->pack_row_length; return 1;
    case GL_PACK_SKIP_ROWS: v[0] = c->pack_skip_rows; return 1;
    case GL_PACK_SKIP_PIXELS: v[0] = c->pack_skip_pixels; return 1;
    case GL_ARRAY_ELEMENT_LOCK_FIRST_EXT: v[0] = c->lock_first; return 1;
    case GL_ARRAY_ELEMENT_LOCK_COUNT_EXT: v[0] = c->locked ? c->lock_count : 0; return 1;
    default:
    {
        bool *flag = capability(c, pname);
        if (flag)
        {
            v[0] = *flag;
            return 1;
        }
        {
            /* one line per name, however often it is asked for */
            static GLenum seen[32];
            static int seen_count;
            int i;

            for (i = 0; i < seen_count && seen[i] != pname; i++) {}
            if (i == seen_count && seen_count < 32)
            {
                seen[seen_count++] = pname;
                glmt_log("glmt: glGet(0x%04x) is not known", pname);
            }
        }
        glmt_set_error(c, GL_INVALID_ENUM);
        return 0;
    }
    }
}

/* Colors and depths read as integers map 1.0 to the largest integer. */
static bool get_is_normalized(GLenum pname)
{
    return pname == GL_CURRENT_COLOR || pname == GL_COLOR_CLEAR_VALUE || pname == GL_DEPTH_RANGE ||
           pname == GL_DEPTH_CLEAR_VALUE || pname == GL_ALPHA_TEST_REF;
}

void glmt_glGetIntegerv(GLenum pname, GLint *data)
{
    GLMT_CONTEXT();
    double v[16];
    int n = get_values(c, pname, v);
    for (int i = 0; i < n; i++)
    {
        if (get_is_normalized(pname)) data[i] = (GLint)(v[i] * 2147483647.0);
        else data[i] = (GLint)(v[i] < 0.0 ? v[i] - 0.5 : v[i] + 0.5);
    }
}

void glmt_glGetFloatv(GLenum pname, GLfloat *data)
{
    GLMT_CONTEXT();
    double v[16];
    int n = get_values(c, pname, v);
    for (int i = 0; i < n; i++) data[i] = (GLfloat)v[i];
}

void glmt_glGetDoublev(GLenum pname, GLdouble *data)
{
    GLMT_CONTEXT();
    double v[16];
    int n = get_values(c, pname, v);
    for (int i = 0; i < n; i++) data[i] = v[i];
}

void glmt_glGetBooleanv(GLenum pname, GLboolean *data)
{
    GLMT_CONTEXT();
    double v[16];
    int n = get_values(c, pname, v);
    for (int i = 0; i < n; i++) data[i] = v[i] != 0.0;
}

void glmt_glFinish(void)
{
    GLMT_CONTEXT();
    glmt_flush_packets(c);
}

void glmt_glFlush(void)
{
    GLMT_CONTEXT();
    /* Nothing: packets go to the backend at the swap, or when something needs them there. */
    (void)c;
}

/* Wine's opengl32 binds framebuffer 0 for drawing and for reading at every wglMakeCurrent and every
 * SwapBuffers, through its function table and without a check (unix_wgl.c, pop_default_fbo_buffers).
 * So the name has to exist, although glmt has no framebuffer objects: 0 is the window, which is what
 * glmt draws to anyway. The game never sees the function: Wine hands it out from OpenGL 3.0 or with
 * GL_ARB_framebuffer_object, and glmt reports neither. */
void glmt_glBindFramebuffer(GLenum target, GLuint framebuffer)
{
    GLMT_CONTEXT();
    (void)target;
    if (framebuffer) GLMT_LOG_ONCE("glmt: glBindFramebuffer(%u): glmt has no framebuffer objects", framebuffer);
}
