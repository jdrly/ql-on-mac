/* Texture objects.
 *
 * id Tech 3 uploads every mip level itself with glTexImage2D, one call a level, and binds names it
 * never asked glGenTextures for. So a name becomes a texture when it is first bound, uploads wait
 * in memory, and the backend's texture is made at the first draw, when the number of levels is
 * known. Every format is stored as RGBA 8888. */
#include <stdlib.h>
#include <string.h>

#include "api.h"
#include "internal.h"

/* ---- names ---- */

static uint32_t hash_name(GLuint name) { return name * 2654435761u; }

struct glmt_share *glmt_share_create(void)
{
    struct glmt_share *share = calloc(1, sizeof(*share));
    if (!share) return NULL;
    share->refs = 1;
    share->capacity = 1024;
    share->next_name = 1;
    share->slots = calloc(share->capacity, sizeof(*share->slots));
    if (!share->slots)
    {
        free(share);
        return NULL;
    }
    return share;
}

static void free_pending(struct glmt_texture *t)
{
    for (int i = 0; i < GLMT_MAX_LEVELS; i++)
    {
        free(t->pending[i].rgba);
        t->pending[i].rgba = NULL;
    }
    t->dirty = false;
}

static void texture_free(struct glmt_texture *t, struct glmt_backend *be)
{
    free_pending(t);
    if (t->be_texture) be->texture_destroy(be, t->be_texture);
    free(t);
}

void glmt_share_release(struct glmt_share *share, struct glmt_backend *be)
{
    if (--share->refs) return;
    for (uint32_t i = 0; i < share->capacity; i++)
        if (share->slots[i]) texture_free(share->slots[i], be);
    free(share->slots);
    free(share);
}

static struct glmt_texture **find_slot(struct glmt_texture **slots, uint32_t capacity, GLuint name)
{
    uint32_t i = hash_name(name) & (capacity - 1);
    while (slots[i] && slots[i]->name != name) i = (i + 1) & (capacity - 1);
    return &slots[i];
}

static struct glmt_texture *lookup(struct glmt_share *share, GLuint name)
{
    return *find_slot(share->slots, share->capacity, name);
}

struct glmt_texture *glmt_texture_lookup(struct glmt_share *share, GLuint name)
{
    return name ? lookup(share, name) : NULL;
}

static bool grow(struct glmt_share *share)
{
    uint32_t capacity = share->capacity * 2;
    struct glmt_texture **slots = calloc(capacity, sizeof(*slots));
    if (!slots) return false;
    for (uint32_t i = 0; i < share->capacity; i++)
        if (share->slots[i]) *find_slot(slots, capacity, share->slots[i]->name) = share->slots[i];
    free(share->slots);
    share->slots = slots;
    share->capacity = capacity;
    return true;
}

static uint32_t sampler_key(const struct glmt_texture *t);

static struct glmt_texture *create(struct glmt_share *share, GLuint name)
{
    struct glmt_texture *t;

    if ((share->count + 1) * 2 > share->capacity && !grow(share)) return NULL;
    if (!(t = calloc(1, sizeof(*t)))) return NULL;
    t->name = name;
    t->min_filter = GL_NEAREST_MIPMAP_LINEAR;
    t->mag_filter = GL_LINEAR;
    t->wrap_s = t->wrap_t = GL_REPEAT;
    t->anisotropy = 1.0f;
    t->sampler = sampler_key(t);
    *find_slot(share->slots, share->capacity, name) = t;
    share->count++;
    return t;
}

static void remove_name(struct glmt_share *share, GLuint name)
{
    uint32_t mask = share->capacity - 1;
    uint32_t i = (uint32_t)(find_slot(share->slots, share->capacity, name) - share->slots);

    if (!share->slots[i]) return;
    share->slots[i] = NULL;
    share->count--;
    /* Put back the entries that followed it, so that none is cut off from its home slot. */
    for (uint32_t j = (i + 1) & mask; share->slots[j]; j = (j + 1) & mask)
    {
        struct glmt_texture *moved = share->slots[j];
        share->slots[j] = NULL;
        *find_slot(share->slots, share->capacity, moved->name) = moved;
    }
}

/* ---- sampler ---- */

static uint32_t wrap_key(GLenum wrap)
{
    switch (wrap)
    {
    case GL_REPEAT: return GLMT_WRAP_REPEAT;
    case GL_MIRRORED_REPEAT: return GLMT_WRAP_MIRROR;
    default: return GLMT_WRAP_CLAMP;
    }
}

static uint32_t sampler_key(const struct glmt_texture *t)
{
    uint32_t key = 0;
    uint32_t aniso = t->anisotropy < 1.0f ? 1 : t->anisotropy > GLMT_MAX_ANISOTROPY ? GLMT_MAX_ANISOTROPY : (uint32_t)t->anisotropy;

    switch (t->min_filter)
    {
    case GL_LINEAR: key |= GLMT_SAMPLER_MIN_LINEAR; break;
    case GL_NEAREST_MIPMAP_NEAREST: key |= GLMT_SAMPLER_MIP_NEAREST; break;
    case GL_LINEAR_MIPMAP_NEAREST: key |= GLMT_SAMPLER_MIN_LINEAR | GLMT_SAMPLER_MIP_NEAREST; break;
    case GL_NEAREST_MIPMAP_LINEAR: key |= GLMT_SAMPLER_MIP_LINEAR; break;
    case GL_LINEAR_MIPMAP_LINEAR: key |= GLMT_SAMPLER_MIN_LINEAR | GLMT_SAMPLER_MIP_LINEAR; break;
    default: break;
    }
    if (t->mag_filter == GL_LINEAR) key |= GLMT_SAMPLER_MAG_LINEAR;
    key |= wrap_key(t->wrap_s) << GLMT_SAMPLER_WRAP_S_SHIFT;
    key |= wrap_key(t->wrap_t) << GLMT_SAMPLER_WRAP_T_SHIFT;
    key |= aniso << GLMT_SAMPLER_ANISO_SHIFT;
    return key;
}

/* ---- pixels ---- */

/* The number of components of a client format, 0 for one glmt does not read. */
static int format_components(GLenum format)
{
    switch (format)
    {
    case GL_RGBA:
    case GL_BGRA: return 4;
    case GL_RGB:
    case GL_BGR: return 3;
    case GL_LUMINANCE_ALPHA: return 2;
    case GL_LUMINANCE:
    case GL_ALPHA: return 1;
    default: return 0;
    }
}

/* What the texture's own format leaves undefined, by the internal format it was created with. */
static uint32_t internal_format_flags(GLint internal)
{
    switch (internal)
    {
    case 1:
    case 3:
    case GL_RGB:
    case GL_R3_G3_B2:
    case GL_RGB4:
    case GL_RGB5:
    case GL_RGB8:
    case GL_RGB10:
    case GL_LUMINANCE:
    case GL_LUMINANCE4:
    case GL_LUMINANCE8: return GLMT_TEX_NO_ALPHA;
    case GL_ALPHA:
    case GL_ALPHA4:
    case GL_ALPHA8: return GLMT_TEX_NO_COLOR;
    default: return 0;
    }
}

/* Converts a rectangle of client pixels to tightly packed RGBA 8888, honouring the unpack state.
 * What a format lacks reads as OpenGL defines it: alpha 1, and for an alpha texture color 1 too, so
 * that modulating by it leaves color alone. */
static void to_rgba(const struct glmt_context *c, uint8_t *out, const void *pixels, int width, int height,
                    GLenum format)
{
    int comps = format_components(format);
    int row_pixels = c->unpack_row_length > 0 ? c->unpack_row_length : width;
    int align = c->unpack_alignment > 0 ? c->unpack_alignment : 1;
    size_t row_bytes = ((size_t)row_pixels * comps + align - 1) / align * align;
    const uint8_t *base = (const uint8_t *)pixels + (size_t)c->unpack_skip_rows * row_bytes +
                          (size_t)c->unpack_skip_pixels * comps;

    for (int y = 0; y < height; y++)
    {
        const uint8_t *in = base + (size_t)y * row_bytes;
        uint8_t *o = out + (size_t)y * width * 4;

        switch (format)
        {
        case GL_RGBA: memcpy(o, in, (size_t)width * 4); break;
        case GL_BGRA:
            for (int x = 0; x < width; x++, in += 4, o += 4) o[0] = in[2], o[1] = in[1], o[2] = in[0], o[3] = in[3];
            break;
        case GL_RGB:
            for (int x = 0; x < width; x++, in += 3, o += 4) o[0] = in[0], o[1] = in[1], o[2] = in[2], o[3] = 255;
            break;
        case GL_BGR:
            for (int x = 0; x < width; x++, in += 3, o += 4) o[0] = in[2], o[1] = in[1], o[2] = in[0], o[3] = 255;
            break;
        case GL_LUMINANCE_ALPHA:
            for (int x = 0; x < width; x++, in += 2, o += 4) o[0] = o[1] = o[2] = in[0], o[3] = in[1];
            break;
        case GL_LUMINANCE:
            for (int x = 0; x < width; x++, in += 1, o += 4) o[0] = o[1] = o[2] = in[0], o[3] = 255;
            break;
        default: /* GL_ALPHA */
            for (int x = 0; x < width; x++, in += 1, o += 4) o[0] = o[1] = o[2] = 255, o[3] = in[0];
            break;
        }
    }
}

/* ---- the backend's texture ---- */

bool glmt_texture_realize(struct glmt_context *c, struct glmt_texture *t)
{
    int levels = 0;

    if (!t->dirty) return t->be_texture != 0;

    /* The levels from 0 that are there and halve as mip levels do. */
    while (levels < GLMT_MAX_LEVELS && t->pending[levels].rgba)
    {
        if (levels)
        {
            int w = t->pending[levels - 1].width / 2, h = t->pending[levels - 1].height / 2;
            if (t->pending[levels].width != (w ? w : 1) || t->pending[levels].height != (h ? h : 1)) break;
        }
        levels++;
    }
    if (!levels)
    {
        /* Level 0 is in the backend already and later levels came alone: upload those that fit. */
        if (t->be_texture)
            for (int i = 1; i < t->be_levels; i++)
                if (t->pending[i].rgba)
                {
                    c->be->texture_upload(c->be, t->be_texture, i, 0, 0, t->pending[i].width, t->pending[i].height,
                                          t->pending[i].rgba);
                    c->stats.texture_uploads++;
                }
        free_pending(t);
        return t->be_texture != 0;
    }

    /* Draws already in the stream use the texture as it is. */
    glmt_flush_packets(c);
    /* A texture of the same size with at least these levels keeps its other levels, as OpenGL's
     * does when one level is given again. */
    if (t->be_texture &&
        (t->be_width != t->pending[0].width || t->be_height != t->pending[0].height || t->be_levels < levels))
    {
        c->be->texture_destroy(c->be, t->be_texture);
        t->be_texture = 0;
    }
    if (!t->be_texture)
    {
        t->be_texture = c->be->texture_create(c->be, t->pending[0].width, t->pending[0].height, levels);
        t->be_width = t->pending[0].width;
        t->be_height = t->pending[0].height;
        t->be_levels = levels;
        GLMT_DEBUG("glmt: texture %u: %dx%d, %d levels%s%s", t->name, t->be_width, t->be_height, levels,
                   t->flags & GLMT_TEX_NO_ALPHA ? ", no alpha" : "", t->flags & GLMT_TEX_NO_COLOR ? ", no color" : "");
    }
    if (t->be_texture)
        for (int i = 0; i < levels; i++)
        {
            c->be->texture_upload(c->be, t->be_texture, i, 0, 0, t->pending[i].width, t->pending[i].height,
                                  t->pending[i].rgba);
            c->stats.texture_uploads++;
        }
    free_pending(t);
    return t->be_texture != 0;
}

/* ---- entry points ---- */

void glmt_texture_init(struct glmt_context *c)
{
    for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++) c->unit[u].env_mode = GL_MODULATE;
}

/* The texture bound to the active unit, NULL for name 0. OpenGL's name 0 is a texture object of its
 * own; id Tech 3 never gives it an image, and glmt gives it none: a unit with name 0 bound draws
 * untextured. */
static struct glmt_texture *bound_texture(struct glmt_context *c)
{
    struct glmt_tex_unit *unit = &c->unit[c->active_unit];
    return unit->texture;
}

void glmt_glGenTextures(GLsizei n, GLuint *textures)
{
    GLMT_CONTEXT();
    for (GLsizei i = 0; i < n; i++)
    {
        while (c->share->next_name == 0 || lookup(c->share, c->share->next_name)) c->share->next_name++;
        textures[i] = c->share->next_name;
        /* Reserved from here on, as an object that has no image yet. */
        if (!create(c->share, c->share->next_name)) glmt_set_error(c, GL_OUT_OF_MEMORY);
        c->share->next_name++;
    }
}

void glmt_glDeleteTextures(GLsizei n, const GLuint *textures)
{
    GLMT_CONTEXT();
    for (GLsizei i = 0; i < n; i++)
    {
        struct glmt_texture *t = textures[i] ? lookup(c->share, textures[i]) : NULL;
        if (!t) continue;
        /* Draws already in the stream still name the backend's texture. */
        if (t->be_texture) glmt_flush_packets(c);
        for (int u = 0; u < GLMT_MAX_TEX_UNITS; u++)
            if (c->unit[u].texture == t)
            {
                c->unit[u].texture = NULL;
                c->unit[u].bound = 0;
            }
        remove_name(c->share, textures[i]);
        texture_free(t, c->be);
    }
}

void glmt_glBindTexture(GLenum target, GLuint texture)
{
    GLMT_CONTEXT();
    struct glmt_tex_unit *unit = &c->unit[c->active_unit];
    struct glmt_texture *t = NULL;

    GLMT_TRACE_ARGS("target 0x%04x, texture %u, unit %d", target, texture, c->active_unit);
    if (target != GL_TEXTURE_2D)
    {
        GLMT_LOG_ONCE("glmt: glBindTexture(0x%04x): glmt has 2D textures only", target);
        return;
    }
    if (unit->bound == texture && (unit->texture || !texture)) return;
    if (texture && !(t = lookup(c->share, texture)) && !(t = create(c->share, texture)))
    {
        glmt_set_error(c, GL_OUT_OF_MEMORY);
        return;
    }
    unit->bound = texture;
    unit->texture = t;
}

GLboolean glmt_glIsTexture(GLuint texture)
{
    GLMT_CONTEXT(GL_FALSE);
    return texture && lookup(c->share, texture);
}

void glmt_glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
                       GLint border, GLenum format, GLenum type, const void *pixels)
{
    GLMT_CONTEXT();
    struct glmt_texture *t = bound_texture(c);
    struct glmt_tex_level *pending;

    if (target != GL_TEXTURE_2D || !t)
    {
        GLMT_LOG_ONCE("glmt: glTexImage2D(target 0x%04x) with %s is ignored", target,
                      t ? "a target that is not 2D" : "texture 0 bound");
        return;
    }
    if (level < 0 || level >= GLMT_MAX_LEVELS || width < 0 || height < 0 || border ||
        width > GLMT_MAX_TEXTURE_SIZE || height > GLMT_MAX_TEXTURE_SIZE)
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    if (type != GL_UNSIGNED_BYTE || !format_components(format))
    {
        glmt_log("glmt: glTexImage2D(format 0x%04x, type 0x%04x) is not supported", format, type);
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }

    pending = &t->pending[level];
    free(pending->rgba);
    pending->rgba = NULL;
    if (!width || !height) return;
    if (!(pending->rgba = malloc((size_t)width * height * 4)))
    {
        glmt_set_error(c, GL_OUT_OF_MEMORY);
        return;
    }
    pending->width = width;
    pending->height = height;
    /* Without pixels the image is undefined: make it black, so a later glTexSubImage2D has a
     * level to write into. */
    if (pixels) to_rgba(c, pending->rgba, pixels, width, height, format);
    else memset(pending->rgba, 0, (size_t)width * height * 4);
    if (level == 0) t->flags = internal_format_flags(internalformat);
    t->dirty = true;
}

void glmt_glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height,
                          GLenum format, GLenum type, const void *pixels)
{
    GLMT_CONTEXT();
    struct glmt_texture *t = bound_texture(c);
    uint8_t *rgba;

    if (target != GL_TEXTURE_2D || !t || level < 0 || level >= GLMT_MAX_LEVELS) return;
    if (type != GL_UNSIGNED_BYTE || !format_components(format))
    {
        glmt_log("glmt: glTexSubImage2D(format 0x%04x, type 0x%04x) is not supported", format, type);
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    if (width <= 0 || height <= 0 || !pixels) return;

    if (t->pending[level].rgba)
    {
        /* The level has not reached the backend: write into the waiting copy. */
        struct glmt_tex_level *pending = &t->pending[level];
        if (xoffset < 0 || yoffset < 0 || xoffset + width > pending->width || yoffset + height > pending->height)
        {
            glmt_set_error(c, GL_INVALID_VALUE);
            return;
        }
        if (xoffset == 0 && width == pending->width)
            to_rgba(c, pending->rgba + (size_t)yoffset * pending->width * 4, pixels, width, height, format);
        else
        {
            if (!(rgba = malloc((size_t)width * height * 4))) return;
            to_rgba(c, rgba, pixels, width, height, format);
            for (int y = 0; y < height; y++)
                memcpy(pending->rgba + ((size_t)(yoffset + y) * pending->width + xoffset) * 4,
                       rgba + (size_t)y * width * 4, (size_t)width * 4);
            free(rgba);
        }
        return;
    }

    if (!t->be_texture || level >= t->be_levels)
    {
        glmt_set_error(c, GL_INVALID_OPERATION);
        return;
    }
    if (xoffset < 0 || yoffset < 0 || xoffset + width > (t->be_width >> level ? t->be_width >> level : 1) ||
        yoffset + height > (t->be_height >> level ? t->be_height >> level : 1))
    {
        glmt_set_error(c, GL_INVALID_VALUE);
        return;
    }
    if (!(rgba = malloc((size_t)width * height * 4)))
    {
        glmt_set_error(c, GL_OUT_OF_MEMORY);
        return;
    }
    to_rgba(c, rgba, pixels, width, height, format);
    /* Draws already in the stream use the texture as it was. */
    glmt_flush_packets(c);
    c->be->texture_upload(c->be, t->be_texture, level, xoffset, yoffset, width, height, rgba);
    c->stats.texture_uploads++;
    free(rgba);
}

static void tex_parameter(struct glmt_context *c, GLenum target, GLenum pname, float param)
{
    struct glmt_texture *t = bound_texture(c);

    if (target != GL_TEXTURE_2D || !t) return;
    switch (pname)
    {
    case GL_TEXTURE_MIN_FILTER: t->min_filter = (GLenum)param; break;
    case GL_TEXTURE_MAG_FILTER: t->mag_filter = (GLenum)param; break;
    case GL_TEXTURE_WRAP_S: t->wrap_s = (GLenum)param; break;
    case GL_TEXTURE_WRAP_T: t->wrap_t = (GLenum)param; break;
    case GL_TEXTURE_MAX_ANISOTROPY_EXT: t->anisotropy = param; break;
    /* Accepted and not applied. */
    case GL_TEXTURE_PRIORITY:
    case GL_TEXTURE_BORDER_COLOR:
    case GL_TEXTURE_BASE_LEVEL:
    case GL_TEXTURE_MAX_LEVEL:
    case GL_TEXTURE_LOD_BIAS: return;
    case GL_GENERATE_MIPMAP:
        if (param != 0.0f) glmt_log("glmt: GL_GENERATE_MIPMAP is not supported");
        return;
    default:
        glmt_log("glmt: glTexParameter(0x%04x) is not known", pname);
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    t->sampler = sampler_key(t);
}

void glmt_glTexParameteri(GLenum target, GLenum pname, GLint param)
{
    GLMT_CONTEXT();
    tex_parameter(c, target, pname, (float)param);
}

void glmt_glTexParameterf(GLenum target, GLenum pname, GLfloat param)
{
    GLMT_CONTEXT();
    tex_parameter(c, target, pname, param);
}

void glmt_glTexParameteriv(GLenum target, GLenum pname, const GLint *params)
{
    GLMT_CONTEXT();
    tex_parameter(c, target, pname, (float)params[0]);
}

void glmt_glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params)
{
    GLMT_CONTEXT();
    tex_parameter(c, target, pname, params[0]);
}

static void tex_env(struct glmt_context *c, GLenum target, GLenum pname, GLenum param)
{
    if (target != GL_TEXTURE_ENV) return;
    if (pname == GL_TEXTURE_ENV_COLOR) return; /* read by GL_BLEND only */
    if (pname != GL_TEXTURE_ENV_MODE)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    if (param != GL_MODULATE && param != GL_REPLACE && param != GL_DECAL && param != GL_ADD)
    {
        /* GL_BLEND and GL_COMBINE: id Tech 3 uses neither. */
        glmt_log("glmt: texture environment mode 0x%04x is not supported, GL_MODULATE is used", param);
        param = GL_MODULATE;
    }
    c->unit[c->active_unit].env_mode = param;
}

void glmt_glTexEnvi(GLenum target, GLenum pname, GLint param)
{
    GLMT_CONTEXT();
    tex_env(c, target, pname, (GLenum)param);
}

void glmt_glTexEnvf(GLenum target, GLenum pname, GLfloat param)
{
    GLMT_CONTEXT();
    tex_env(c, target, pname, (GLenum)param);
}

void glmt_glTexEnviv(GLenum target, GLenum pname, const GLint *params)
{
    GLMT_CONTEXT();
    tex_env(c, target, pname, (GLenum)params[0]);
}

void glmt_glTexEnvfv(GLenum target, GLenum pname, const GLfloat *params)
{
    GLMT_CONTEXT();
    tex_env(c, target, pname, (GLenum)params[0]);
}

void glmt_glActiveTexture(GLenum texture)
{
    GLMT_CONTEXT();
    if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + GLMT_MAX_TEX_UNITS)
    {
        glmt_set_error(c, GL_INVALID_ENUM);
        return;
    }
    c->active_unit = (int)(texture - GL_TEXTURE0);
}

void glmt_glActiveTextureARB(GLenum texture) { glmt_glActiveTexture(texture); }
