/* Tests of glmt's front end: OpenGL calls in, packets out, read from the recording backend. They run
 * on any system and need no Metal. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "api.h"
#include "internal.h"
#include "record.h"

static int failures, checks;
static const char *current_test;

#define CHECK(cond) \
    do \
    { \
        checks++; \
        if (!(cond)) \
        { \
            failures++; \
            printf("FAIL %s (%s:%d): %s\n", current_test, __FILE__, __LINE__, #cond); \
        } \
    } while (0)

#define CHECK_EQ(a, b) \
    do \
    { \
        long long a_ = (long long)(a), b_ = (long long)(b); \
        checks++; \
        if (a_ != b_) \
        { \
            failures++; \
            printf("FAIL %s (%s:%d): %s is %lld, expected %lld\n", current_test, __FILE__, __LINE__, #a, a_, b_); \
        } \
    } while (0)

#define CHECK_NEAR(a, b) \
    do \
    { \
        double a_ = (double)(a), b_ = (double)(b); \
        checks++; \
        if (fabs(a_ - b_) > 1e-4) \
        { \
            failures++; \
            printf("FAIL %s (%s:%d): %s is %g, expected %g\n", current_test, __FILE__, __LINE__, #a, a_, b_); \
        } \
    } while (0)

/* ---- a context on a fresh recording backend ---- */

static struct rec *rec;
static glmt_context *ctx;
static glmt_surface *surface;

static void begin(const char *name, uint32_t arena_bytes)
{
    current_test = name;
    rec = rec_create(arena_bytes);
    glmt_set_backend(&rec->base);
    glmt_init(NULL);
    ctx = glmt_context_create(NULL);
    surface = glmt_surface_create(NULL, 640, 480, 0);
    glmt_make_current(ctx, surface);
}

static void end(void)
{
    glmt_make_current(NULL, NULL);
    glmt_context_destroy(ctx);
    glmt_surface_destroy(surface);
}

/* Everything drawn so far is in rec. */
static void flush(void) { glmt_glFinish(); }

static const struct glmt_uniforms *uniforms_of(const struct rec_draw *draw)
{
    return (const struct glmt_uniforms *)(draw->arena + draw->d.uniforms);
}

static const float *positions_of(const struct rec_draw *draw) { return (const float *)(draw->arena + draw->d.position); }
static const uint8_t *colors_of(const struct rec_draw *draw) { return draw->arena + draw->d.color; }
static const float *texcoords_of(const struct rec_draw *draw, int unit)
{
    return (const float *)(draw->arena + draw->d.texcoord[unit]);
}
static const uint32_t *indices_of(const struct rec_draw *draw)
{
    return (const uint32_t *)(draw->arena + draw->d.index_offset);
}

/* id Tech 3's vertex layout: xyz padded to 16 bytes. */
static float quad_xyz[4][4] = {{0, 0, 0, 99}, {1, 0, 0, 99}, {1, 1, 0, 99}, {0, 1, 0, 99}};
static uint8_t quad_colors[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 128}};
static float quad_st[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
static float quad_st2[4][2] = {{0.5f, 0.5f}, {2, 0}, {2, 2}, {0, 2}};
static const uint32_t quad_indices[6] = {0, 1, 2, 0, 2, 3};

static void make_texture(GLuint name, GLint internal, GLenum format, int size, int levels)
{
    static uint8_t pixels[64 * 64 * 4];
    memset(pixels, 200, sizeof(pixels));
    glmt_glBindTexture(GL_TEXTURE_2D, name);
    for (int level = 0; level < levels; level++, size = size > 1 ? size / 2 : 1)
        glmt_glTexImage2D(GL_TEXTURE_2D, level, internal, size, size, 0, format, GL_UNSIGNED_BYTE, pixels);
    glmt_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, levels > 1 ? GL_LINEAR_MIPMAP_NEAREST : GL_LINEAR);
    glmt_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
}

/* ---- tests ---- */

static void test_entry_points(void)
{
    begin("entry points", 1 << 20);
    CHECK(glmt_get_proc_address("glEnable") == (void *)glmt_glEnable);
    CHECK(glmt_get_proc_address("glLockArraysEXT") == (void *)glmt_glLockArraysEXT);
    CHECK(glmt_get_proc_address("glActiveTextureARB") != NULL);
    /* an OpenGL 1.1 name without an implementation has a stub, and calling it is harmless */
    void (*accum)(GLenum, GLfloat) = (void (*)(GLenum, GLfloat))glmt_get_proc_address("glAccum");
    CHECK(accum != NULL);
    CHECK(accum != (void (*)(GLenum, GLfloat))glmt_get_proc_address("glCallList"));
    if (accum) accum(0x0100, 1.0f);
    /* anything else has no address: Wine then does not offer it */
    CHECK(glmt_get_proc_address("glCreateShader") == NULL);
    CHECK(glmt_get_proc_address("glGenFramebuffers") == NULL);
    CHECK(glmt_get_proc_address("glBindBuffer") == NULL);
    /* the four names Wine itself calls without a check at make current and at swap */
    CHECK(glmt_get_proc_address("glBindFramebuffer") != NULL);
    CHECK(glmt_get_proc_address("glDrawBuffer") == (void *)glmt_glDrawBuffer);
    CHECK(glmt_get_proc_address("glReadBuffer") == (void *)glmt_glReadBuffer);
    CHECK(glmt_get_proc_address("glScissor") == (void *)glmt_glScissor);
    glmt_glBindFramebuffer(0x8CA9, 0);
    /* and the strings it reads without a check when a context is first made current */
    CHECK(glmt_glGetString(GL_VENDOR) && glmt_glGetString(GL_RENDERER));
    CHECK(!strncmp((const char *)glmt_glGetString(GL_VERSION), "1.3", 3));

    CHECK(strstr((const char *)glmt_glGetString(GL_EXTENSIONS), "GL_EXT_compiled_vertex_array") != NULL);
    CHECK(strstr((const char *)glmt_glGetString(GL_EXTENSIONS), "GL_ARB_multitexture") != NULL);
    CHECK(strstr((const char *)glmt_glGetString(GL_EXTENSIONS), "shader") == NULL);
    CHECK(strstr((const char *)glmt_glGetString(GL_EXTENSIONS), "framebuffer") == NULL);

    GLint value[4] = {0};
    glmt_glGetIntegerv(GL_MAX_TEXTURE_UNITS, value);
    CHECK_EQ(value[0], 2);
    glmt_glGetIntegerv(GL_VIEWPORT, value);
    CHECK_EQ(value[2], 640);
    CHECK_EQ(value[3], 480);
    CHECK_EQ(glmt_glGetError(), GL_NO_ERROR);
    glmt_glDepthFunc(0x1234);
    CHECK_EQ(glmt_glGetError(), GL_INVALID_ENUM);
    CHECK_EQ(glmt_glGetError(), GL_NO_ERROR);
    end();
}

/* A two-stage shader as RB_StageIteratorGeneric draws it: positions locked once, colors and texture
 * coordinates set again for each stage at the same addresses. */
static void test_multipass_surface(void)
{
    static const float projection[16] = {2, 0, 0, 0, 0, 3, 0, 0, 0, 0, -1, -1, 0, 0, -2, 0};
    static const float modelview[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 6, 7, 1};
    uint8_t colors[4][4];
    float st[4][2];

    begin("multipass surface", 1 << 20);
    make_texture(1024, 3, GL_RGB, 4, 3);
    make_texture(1025, 4, GL_RGBA, 2, 1);

    glmt_glMatrixMode(GL_PROJECTION);
    glmt_glLoadMatrixf(projection);
    glmt_glMatrixMode(GL_MODELVIEW);
    glmt_glLoadMatrixf(modelview);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glEnable(GL_DEPTH_TEST);
    glmt_glDepthFunc(GL_LEQUAL);
    glmt_glEnable(GL_CULL_FACE);
    glmt_glCullFace(GL_FRONT);

    glmt_glDisableClientState(GL_COLOR_ARRAY);
    glmt_glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);
    glmt_glLockArraysEXT(0, 4);
    glmt_glEnableClientState(GL_COLOR_ARRAY);
    glmt_glEnableClientState(GL_TEXTURE_COORD_ARRAY);

    /* stage 1: opaque */
    memcpy(colors, quad_colors, sizeof(colors));
    memcpy(st, quad_st, sizeof(st));
    glmt_glColorPointer(4, GL_UNSIGNED_BYTE, 0, colors);
    glmt_glTexCoordPointer(2, GL_FLOAT, 0, st);
    glmt_glBindTexture(GL_TEXTURE_2D, 1024);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);

    /* stage 2: a lightmap-style blend, new contents at the same addresses */
    memset(colors, 77, sizeof(colors));
    memcpy(st, quad_st2, sizeof(st));
    glmt_glColorPointer(4, GL_UNSIGNED_BYTE, 0, colors);
    glmt_glTexCoordPointer(2, GL_FLOAT, 0, st);
    glmt_glBindTexture(GL_TEXTURE_2D, 1025);
    glmt_glEnable(GL_BLEND);
    glmt_glBlendFunc(GL_DST_COLOR, GL_ZERO);
    glmt_glDepthMask(GL_FALSE);
    glmt_glDepthFunc(GL_EQUAL);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    /* the same stage again: nothing changed, so nothing but the changed arrays is sent again */
    glmt_glColorPointer(4, GL_UNSIGNED_BYTE, 0, colors);
    glmt_glTexCoordPointer(2, GL_FLOAT, 0, st);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    glmt_glUnlockArraysEXT();
    flush();

    CHECK_EQ(rec->draw_count, 3);
    const struct rec_draw *a = &rec->draws[0], *b = &rec->draws[1], *c3 = &rec->draws[2];

    /* positions: one copy for the lock, the game's 16-byte layout as it is */
    CHECK_EQ(a->d.position, b->d.position);
    CHECK_EQ(a->d.position, c3->d.position);
    CHECK(!memcmp(positions_of(a), quad_xyz, sizeof(quad_xyz)));
    CHECK_EQ(a->d.vertex_count, 4);
    /* colors and texture coordinates: a copy per draw, with that draw's contents */
    CHECK(a->d.color != b->d.color);
    CHECK(!memcmp(colors_of(a), quad_colors, sizeof(quad_colors)));
    CHECK_EQ(colors_of(b)[0], 77);
    CHECK(a->d.texcoord[0] != b->d.texcoord[0]);
    CHECK(!memcmp(texcoords_of(a, 0), quad_st, sizeof(quad_st)));
    CHECK(!memcmp(texcoords_of(b, 0), quad_st2, sizeof(quad_st2)));
    CHECK_EQ(a->d.texcoord[1], GLMT_NO_OFFSET);
    /* indices */
    CHECK_EQ(a->d.index_count, 6);
    CHECK(!memcmp(indices_of(a), quad_indices, sizeof(quad_indices)));
    CHECK_EQ(a->d.base_vertex, 0);
    CHECK_EQ(a->d.primitive, GLMT_PRIM_TRIANGLES);

    /* keys */
    CHECK_EQ(a->d.pipeline, GLMT_PIPE_HAS_COLOR | GLMT_PIPE_HAS_TC0 | 0xfu << GLMT_PIPE_MASK_SHIFT);
    CHECK_EQ(b->d.pipeline, GLMT_PIPE_HAS_COLOR | GLMT_PIPE_HAS_TC0 | 0xfu << GLMT_PIPE_MASK_SHIFT | GLMT_PIPE_BLEND |
                                GLMT_BLEND_DST_COLOR << GLMT_PIPE_SRC_SHIFT | GLMT_BLEND_ZERO << GLMT_PIPE_DST_SHIFT);
    CHECK_EQ(a->d.depth, GLMT_DEPTH_TEST | (GL_LEQUAL - GL_NEVER) << GLMT_DEPTH_FUNC_SHIFT | GLMT_DEPTH_WRITE);
    CHECK_EQ(b->d.depth, GLMT_DEPTH_TEST | (GL_EQUAL - GL_NEVER) << GLMT_DEPTH_FUNC_SHIFT);
    CHECK_EQ(a->d.raster, GLMT_RASTER_CULL_FRONT);
    CHECK_EQ(a->d.stencil, 0);
    CHECK_EQ(a->d.viewport[2], 640);
    CHECK_NEAR(a->d.depth_range[1], 1.0);

    /* textures: made at the first draw, with the levels the game uploaded */
    CHECK(a->d.texture[0] != 0 && b->d.texture[0] != 0 && a->d.texture[0] != b->d.texture[0]);
    CHECK_EQ(a->d.texture[1], 0);
    CHECK_EQ(rec->textures[a->d.texture[0]].levels, 3);
    CHECK_EQ(rec->textures[a->d.texture[0]].width, 4);
    CHECK_EQ(rec->textures[a->d.texture[0]].uploads, 3);
    CHECK_EQ(rec->textures[b->d.texture[0]].levels, 1);
    CHECK_EQ(a->d.sampler[0], (GLMT_SAMPLER_MIN_LINEAR | GLMT_SAMPLER_MIP_NEAREST | GLMT_SAMPLER_MAG_LINEAR |
                               1u << GLMT_SAMPLER_ANISO_SHIFT));
    CHECK_EQ(b->d.sampler[0], (GLMT_SAMPLER_MIN_LINEAR | GLMT_SAMPLER_MAG_LINEAR | 1u << GLMT_SAMPLER_ANISO_SHIFT));

    /* uniforms: projection times modelview, the environment, what the texture's format lacks */
    const struct glmt_uniforms *ua = uniforms_of(a), *ub = uniforms_of(b);
    CHECK_NEAR(ua->mvp[0], 2);
    CHECK_NEAR(ua->mvp[5], 3);
    CHECK_NEAR(ua->mvp[12], 10);  /* 2 * 5 */
    CHECK_NEAR(ua->mvp[13], 18);  /* 3 * 6 */
    CHECK_NEAR(ua->mvp[14], -9);  /* -1 * 7 - 2 */
    CHECK_NEAR(ua->mvp[15], -7);
    CHECK_EQ(ua->tex_env[0], GLMT_ENV_MODULATE);
    CHECK_EQ(ua->tex_env[1], GLMT_ENV_OFF);
    CHECK_EQ(ua->tex_flags[0], GLMT_TEX_NO_ALPHA);
    CHECK_EQ(ub->tex_flags[0], 0);
    CHECK_EQ(ua->flags, GLMT_UNIFORM_COLOR_ARRAY);
    CHECK(a->d.uniforms != b->d.uniforms);
    CHECK_EQ(b->d.uniforms, c3->d.uniforms);
    CHECK_EQ(sizeof(struct glmt_uniforms), 128);
    end();
}

/* A one-stage shader: color and texture coordinate arrays are enabled before the lock, so they are
 * compiled too, and a second draw under the lock copies nothing but indices. */
static void test_single_pass_surface(void)
{
    begin("single pass surface", 1 << 20);
    make_texture(1024, 4, GL_RGBA, 4, 1);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glEnableClientState(GL_COLOR_ARRAY);
    glmt_glColorPointer(4, GL_UNSIGNED_BYTE, 0, quad_colors);
    glmt_glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glmt_glTexCoordPointer(2, GL_FLOAT, 0, quad_st);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);
    glmt_glLockArraysEXT(0, 4);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    glmt_glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_INT, quad_indices);
    glmt_glUnlockArraysEXT();
    /* after the unlock the arrays may have changed: everything is copied again */
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();

    CHECK_EQ(rec->draw_count, 3);
    CHECK_EQ(rec->draws[0].d.position, rec->draws[1].d.position);
    CHECK_EQ(rec->draws[0].d.color, rec->draws[1].d.color);
    CHECK_EQ(rec->draws[0].d.texcoord[0], rec->draws[1].d.texcoord[0]);
    CHECK(rec->draws[0].d.index_offset != rec->draws[1].d.index_offset);
    CHECK_EQ(rec->draws[1].d.index_count, 3);
    CHECK(rec->draws[2].d.position != rec->draws[0].d.position);
    CHECK(rec->draws[2].d.color != rec->draws[0].d.color);
    CHECK_EQ(rec->draws[0].d.uniforms, rec->draws[2].d.uniforms);
    end();
}

/* DrawMultitextured: a second unit with its own texture, environment and coordinate array. */
static void test_multitexture(void)
{
    begin("multitexture", 1 << 20);
    make_texture(1024, 3, GL_RGB, 4, 1);
    make_texture(1025, 3, GL_RGB, 4, 1);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);
    glmt_glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glmt_glTexCoordPointer(2, GL_FLOAT, 0, quad_st);
    glmt_glBindTexture(GL_TEXTURE_2D, 1024);

    glmt_glActiveTextureARB(GL_TEXTURE0 + 1);
    glmt_glClientActiveTextureARB(GL_TEXTURE0 + 1);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    /* interleaved in a 16-byte stride, as tess.texCoords is */
    static float interleaved[4][4] = {{9, 9, 0.25f, 0.5f}, {9, 9, 1, 0}, {9, 9, 1, 1}, {9, 9, 0, 1}};
    glmt_glTexCoordPointer(2, GL_FLOAT, 16, &interleaved[0][2]);
    glmt_glBindTexture(GL_TEXTURE_2D, 1025);
    glmt_glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_ADD);
    glmt_glColor4f(0.5f, 0.25f, 1.0f, 1.0f);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);

    glmt_glDisable(GL_TEXTURE_2D);
    glmt_glActiveTextureARB(GL_TEXTURE0);
    glmt_glClientActiveTextureARB(GL_TEXTURE0);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();

    CHECK_EQ(rec->draw_count, 2);
    const struct rec_draw *a = &rec->draws[0], *b = &rec->draws[1];
    CHECK_EQ(a->d.pipeline & (GLMT_PIPE_HAS_COLOR | GLMT_PIPE_HAS_TC0 | GLMT_PIPE_HAS_TC1),
             GLMT_PIPE_HAS_TC0 | GLMT_PIPE_HAS_TC1);
    CHECK(a->d.texture[1] != 0 && a->d.texture[1] != a->d.texture[0]);
    CHECK_EQ(a->d.color, GLMT_NO_OFFSET);
    CHECK_NEAR(texcoords_of(a, 1)[0], 0.25);
    CHECK_NEAR(texcoords_of(a, 1)[1], 0.5);
    CHECK_NEAR(texcoords_of(a, 1)[2], 1.0);
    CHECK_EQ(uniforms_of(a)->tex_env[0], GLMT_ENV_MODULATE);
    CHECK_EQ(uniforms_of(a)->tex_env[1], GLMT_ENV_ADD);
    CHECK_EQ(uniforms_of(a)->flags, 0);
    CHECK_NEAR(uniforms_of(a)->color[1], 0.25);
    /* unit 1 off again */
    CHECK_EQ(b->d.pipeline & GLMT_PIPE_HAS_TC1, 0);
    CHECK_EQ(b->d.texture[1], 0);
    CHECK_EQ(uniforms_of(b)->tex_env[1], GLMT_ENV_OFF);
    end();
}

/* RB_SetGL2D and a glBegin(GL_QUADS) picture, as cinematics and the sky use. */
static void test_immediate(void)
{
    begin("immediate mode", 1 << 20);
    make_texture(1024, 4, GL_RGBA, 4, 1);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glMatrixMode(GL_PROJECTION);
    glmt_glLoadIdentity();
    glmt_glOrtho(0, 640, 480, 0, 0, 1);
    glmt_glMatrixMode(GL_MODELVIEW);
    glmt_glLoadIdentity();
    glmt_glColor4f(1.0f, 0.5f, 0.0f, 1.0f);
    glmt_glBegin(GL_QUADS);
    glmt_glTexCoord2f(0, 0);
    glmt_glVertex2f(0, 0);
    glmt_glTexCoord2f(1, 0);
    glmt_glVertex2f(640, 0);
    glmt_glTexCoord2f(1, 1);
    glmt_glVertex2f(640, 480);
    glmt_glTexCoord2f(0, 1);
    glmt_glVertex2f(0, 480);
    glmt_glEnd();

    glmt_glDisable(GL_TEXTURE_2D);
    glmt_glBegin(GL_TRIANGLE_STRIP);
    for (int i = 0; i < 5; i++) glmt_glVertex3f((float)i, 0, 0);
    glmt_glEnd();
    glmt_glBegin(GL_LINE_LOOP);
    for (int i = 0; i < 3; i++) glmt_glVertex3f((float)i, 0, 0);
    glmt_glEnd();
    glmt_glBegin(GL_POLYGON);
    for (int i = 0; i < 5; i++) glmt_glVertex3f((float)i, 0, 0);
    glmt_glEnd();
    flush();

    CHECK_EQ(rec->draw_count, 4);
    const struct rec_draw *quad = &rec->draws[0];
    CHECK_EQ(quad->d.primitive, GLMT_PRIM_TRIANGLES);
    CHECK_EQ(quad->d.vertex_count, 4);
    CHECK_EQ(quad->d.index_count, 6);
    CHECK(!memcmp(indices_of(quad), quad_indices, sizeof(quad_indices)));
    CHECK_NEAR(positions_of(quad)[2 * 4 + 0], 640);
    CHECK_NEAR(positions_of(quad)[2 * 4 + 1], 480);
    CHECK_EQ(colors_of(quad)[0], 255);
    CHECK_EQ(colors_of(quad)[1], 128);
    CHECK_EQ(colors_of(quad)[2], 0);
    CHECK_NEAR(texcoords_of(quad, 0)[2 * 2 + 1], 1.0);
    /* glOrtho(0, 640, 480, 0): the top left of the window is x -1, y +1 in clip space */
    const float *mvp = uniforms_of(quad)->mvp;
    CHECK_NEAR(mvp[0] * 0 + mvp[12], -1.0);
    CHECK_NEAR(mvp[5] * 0 + mvp[13], 1.0);
    CHECK_NEAR(mvp[0] * 640 + mvp[12], 1.0);
    CHECK_NEAR(mvp[5] * 480 + mvp[13], -1.0);

    CHECK_EQ(rec->draws[1].d.primitive, GLMT_PRIM_TRIANGLE_STRIP);
    CHECK_EQ(rec->draws[1].d.index_offset, GLMT_NO_OFFSET);
    CHECK_EQ(rec->draws[1].d.vertex_count, 5);
    CHECK_EQ(rec->draws[1].d.pipeline & GLMT_PIPE_HAS_TC0, 0);
    CHECK_EQ(rec->draws[2].d.primitive, GLMT_PRIM_LINE_STRIP);
    CHECK_EQ(rec->draws[2].d.index_count, 4);
    CHECK_EQ(indices_of(&rec->draws[2])[3], 0);
    CHECK_EQ(rec->draws[3].d.primitive, GLMT_PRIM_TRIANGLES);
    CHECK_EQ(rec->draws[3].d.index_count, 9);
    CHECK_EQ(indices_of(&rec->draws[3])[8], 4);
    end();
}

static void test_state_keys(void)
{
    begin("state keys", 1 << 20);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);

    glmt_glEnable(GL_ALPHA_TEST);
    glmt_glAlphaFunc(GL_GEQUAL, 0.5f);
    glmt_glEnable(GL_POLYGON_OFFSET_FILL);
    glmt_glPolygonOffset(-1.0f, -2.0f);
    glmt_glEnable(GL_SCISSOR_TEST);
    glmt_glScissor(10, 20, 30, 40);
    glmt_glViewport(1, 2, 300, 200);
    glmt_glDepthRange(0.0, 0.3);
    glmt_glColorMask(GL_TRUE, GL_FALSE, GL_TRUE, GL_FALSE);
    glmt_glEnable(GL_CULL_FACE);
    glmt_glCullFace(GL_BACK);
    glmt_glFrontFace(GL_CW);
    glmt_glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
    glmt_glEnable(GL_STENCIL_TEST);
    glmt_glStencilFunc(GL_EQUAL, 3, 0xff);
    glmt_glStencilOp(GL_KEEP, GL_INCR, GL_REPLACE);
    glmt_glStencilMask(0x0f);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);

    /* alpha test that always passes needs no discard; depth test off writes no depth */
    glmt_glAlphaFunc(GL_ALWAYS, 0.0f);
    glmt_glDisable(GL_POLYGON_OFFSET_FILL);
    glmt_glDisable(GL_STENCIL_TEST);
    glmt_glDepthMask(GL_TRUE);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();

    CHECK_EQ(rec->draw_count, 2);
    const struct glmt_cmd_draw *d = &rec->draws[0].d;
    CHECK_EQ(d->pipeline, GLMT_PIPE_ALPHA_TEST | 0x5u << GLMT_PIPE_MASK_SHIFT);
    CHECK_EQ(uniforms_of(&rec->draws[0])->alpha_func, GL_GEQUAL - GL_NEVER);
    CHECK_NEAR(uniforms_of(&rec->draws[0])->alpha_ref, 0.5);
    CHECK_EQ(d->raster, GLMT_RASTER_CULL_BACK | GLMT_RASTER_FRONT_CW | GLMT_RASTER_DEPTH_BIAS | GLMT_RASTER_LINES |
                            GLMT_RASTER_SCISSOR);
    CHECK_NEAR(d->depth_bias_factor, -1.0);
    CHECK_NEAR(d->depth_bias_units, -2.0);
    CHECK_EQ(d->scissor[0], 10);
    CHECK_EQ(d->scissor[3], 40);
    CHECK_EQ(d->viewport[1], 2);
    CHECK_EQ(d->viewport[2], 300);
    CHECK_NEAR(d->depth_range[1], 0.3);
    CHECK_EQ(d->depth, 0);
    CHECK_EQ(d->stencil, GLMT_STENCIL_TEST | (GL_EQUAL - GL_NEVER) << GLMT_STENCIL_FUNC_SHIFT |
                             GLMT_STENCIL_OP_KEEP << GLMT_STENCIL_SFAIL_SHIFT |
                             GLMT_STENCIL_OP_INCR << GLMT_STENCIL_ZFAIL_SHIFT |
                             GLMT_STENCIL_OP_REPLACE << GLMT_STENCIL_ZPASS_SHIFT |
                             0xffu << GLMT_STENCIL_READ_MASK_SHIFT | 0x0fu << GLMT_STENCIL_WRITE_MASK_SHIFT);
    CHECK_EQ(d->stencil_ref, 3);

    d = &rec->draws[1].d;
    CHECK_EQ(d->pipeline & GLMT_PIPE_ALPHA_TEST, 0);
    CHECK_EQ(d->raster & GLMT_RASTER_DEPTH_BIAS, 0);
    CHECK_EQ(d->stencil, 0);
    end();
}

static void test_clear(void)
{
    begin("clear", 1 << 20);
    glmt_glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
    glmt_glClearDepth(1.0);
    glmt_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    /* a buffer that may not be written is not cleared */
    glmt_glDepthMask(GL_FALSE);
    glmt_glEnable(GL_SCISSOR_TEST);
    glmt_glScissor(1, 2, 3, 4);
    glmt_glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glmt_glClear(GL_DEPTH_BUFFER_BIT);
    flush();

    CHECK_EQ(rec->clear_count, 2);
    CHECK_EQ(rec->clears[0].mask, GLMT_CLEAR_COLOR | GLMT_CLEAR_DEPTH | GLMT_CLEAR_STENCIL);
    CHECK_NEAR(rec->clears[0].color[2], 0.75);
    CHECK_NEAR(rec->clears[0].depth, 1.0);
    CHECK_EQ(rec->clears[0].scissor_on, 0);
    CHECK_EQ(rec->clears[1].mask, GLMT_CLEAR_COLOR);
    CHECK_EQ(rec->clears[1].scissor_on, 1);
    CHECK_EQ(rec->clears[1].scissor[2], 3);
    end();
}

/* A portal's clip plane: given in the coordinates of the modelview matrix of that moment, applied in
 * the coordinates of each later draw. */
static void test_clip_plane(void)
{
    static const GLdouble plane[4] = {0, 0, 1, 0};

    begin("clip plane", 1 << 20);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);
    glmt_glMatrixMode(GL_MODELVIEW);
    glmt_glLoadIdentity();
    glmt_glTranslatef(0, 0, -10);
    glmt_glClipPlane(GL_CLIP_PLANE0, plane);
    glmt_glEnable(GL_CLIP_PLANE0);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    glmt_glLoadIdentity();
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    glmt_glDisable(GL_CLIP_PLANE0);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();

    CHECK_EQ(rec->draw_count, 3);
    /* under the same matrix, the plane as it was given */
    const float *p = uniforms_of(&rec->draws[0])->clip_plane;
    CHECK(rec->draws[0].d.pipeline & GLMT_PIPE_CLIP_PLANE);
    CHECK_NEAR(p[2], 1.0);
    CHECK_NEAR(p[3], 0.0);
    /* under identity, the plane in eye space: z + 10 >= 0 */
    p = uniforms_of(&rec->draws[1])->clip_plane;
    CHECK_NEAR(p[2], 1.0);
    CHECK_NEAR(p[3], 10.0);
    CHECK_EQ(rec->draws[2].d.pipeline & GLMT_PIPE_CLIP_PLANE, 0);
    end();
}

/* Without a lock the vertex range comes from the indices. */
static void test_unlocked_range(void)
{
    static float xyz[8][3];
    static const uint16_t indices[3] = {5, 2, 4};

    begin("unlocked range", 1 << 20);
    for (int i = 0; i < 8; i++) xyz[i][0] = (float)i;
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 0, xyz);
    glmt_glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, indices);
    glmt_glDrawArrays(GL_TRIANGLE_FAN, 1, 5);
    flush();

    CHECK_EQ(rec->draw_count, 2);
    const struct rec_draw *d = &rec->draws[0];
    CHECK_EQ(d->d.vertex_count, 4); /* vertices 2 to 5 */
    CHECK_EQ(d->d.base_vertex, -2);
    CHECK_NEAR(positions_of(d)[0], 2.0);
    CHECK_NEAR(positions_of(d)[3 * 4], 5.0);
    CHECK_NEAR(positions_of(d)[3], 1.0); /* tightly packed input gets w = 1 */
    CHECK_EQ(indices_of(d)[0], 5);
    CHECK_EQ(indices_of(d)[1], 2);
    d = &rec->draws[1];
    CHECK_EQ(d->d.vertex_count, 5);
    CHECK_EQ(d->d.index_count, 9);
    CHECK_EQ(d->d.base_vertex, 0);
    CHECK_NEAR(positions_of(d)[0], 1.0);
    end();
}

/* A frame that needs more than one arena: packets go out with the arena they point into, and what
 * was copied under the lock is copied again into the new one. */
static void test_arena_overflow(void)
{
    static float xyz[64][4];

    begin("arena overflow", 2048);
    for (int i = 0; i < 64; i++) xyz[i][0] = (float)i;
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, xyz);
    glmt_glLockArraysEXT(0, 64); /* 1024 bytes of positions */
    for (int i = 0; i < 40; i++) glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    glmt_glUnlockArraysEXT();
    flush();

    CHECK_EQ(rec->draw_count, 40);
    CHECK(rec->arenas > 1);
    for (int i = 0; i < 40; i++)
    {
        const struct rec_draw *d = &rec->draws[i];
        CHECK(d->d.position + 64 * 16 <= 2048);
        CHECK_NEAR(positions_of(d)[63 * 4], 63.0);
        CHECK_EQ(indices_of(d)[5], 3);
        CHECK_NEAR(uniforms_of(d)->mvp[0], 1.0);
    }
    /* too large for any arena: dropped, nothing breaks */
    static float big[200][4];
    glmt_glVertexPointer(3, GL_FLOAT, 16, big);
    glmt_glDrawArrays(GL_TRIANGLES, 0, 198);
    flush();
    CHECK_EQ(rec->draw_count, 40);
    end();
}

static void test_textures(void)
{
    static const uint8_t red[4] = {255, 0, 0, 255}, bgr[3] = {1, 2, 3};
    static uint8_t block[16 * 4];
    GLuint names[3];

    begin("textures", 1 << 20);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);

    /* glGenTextures skips a name the game took by itself */
    glmt_glBindTexture(GL_TEXTURE_2D, 1);
    glmt_glGenTextures(3, names);
    CHECK(names[0] != 1 && names[1] != 1 && names[2] != 1 && names[0] != names[1] && names[1] != names[2]);
    CHECK(glmt_glIsTexture(names[0]));
    CHECK(!glmt_glIsTexture(999));

    /* a texture without an image draws untextured */
    glmt_glBindTexture(GL_TEXTURE_2D, names[0]);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();
    CHECK_EQ(rec->draws[0].d.texture[0], 0);
    CHECK_EQ(rec->draws[0].d.pipeline & GLMT_PIPE_HAS_TC0, 0);

    /* an update before the first draw goes into the waiting image */
    memset(block, 9, sizeof(block));
    glmt_glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glmt_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, block);
    glmt_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, red);
    glmt_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glmt_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
    glmt_glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT, 8.0f);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();
    uint32_t id = rec->draws[1].d.texture[0];
    CHECK(id != 0);
    CHECK_EQ(rec->textures[id].uploads, 1);
    CHECK_EQ(rec->textures[id].first_pixel[0], 255);
    CHECK_EQ(rec->textures[id].first_pixel[1], 0);
    CHECK_EQ(rec->draws[1].d.sampler[0], (GLMT_SAMPLER_MAG_LINEAR | GLMT_WRAP_CLAMP << GLMT_SAMPLER_WRAP_S_SHIFT |
                                          8u << GLMT_SAMPLER_ANISO_SHIFT));

    /* an update afterwards goes straight to the backend, converted to RGBA */
    glmt_glTexSubImage2D(GL_TEXTURE_2D, 0, 2, 3, 1, 1, GL_BGR, GL_UNSIGNED_BYTE, bgr);
    CHECK_EQ(rec->textures[id].uploads, 2);
    CHECK_EQ(rec->textures[id].x, 2);
    CHECK_EQ(rec->textures[id].y, 3);
    CHECK_EQ(rec->textures[id].first_pixel[0], 3);
    CHECK_EQ(rec->textures[id].first_pixel[2], 1);
    CHECK_EQ(rec->textures[id].first_pixel[3], 255);

    /* the same size again keeps the backend's texture; another size replaces it */
    glmt_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, block);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();
    CHECK_EQ(rec->draws[2].d.texture[0], id);
    glmt_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, block);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();
    CHECK(rec->draws[3].d.texture[0] != id);
    CHECK_EQ(rec->textures[id].destroyed, 1);

    /* deleting unbinds */
    id = rec->draws[3].d.texture[0];
    glmt_glDeleteTextures(1, &names[0]);
    CHECK_EQ(rec->textures[id].destroyed, 1);
    CHECK(!glmt_glIsTexture(names[0]));
    GLint bound = -1;
    glmt_glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
    CHECK_EQ(bound, 0);
    end();
}

/* A screenshot as id Tech 3 takes it: GL_RGB with the default pack alignment of 4. */
static void test_read_pixels(void)
{
    uint8_t out[2 * 12];

    begin("read pixels", 1 << 20);
    memset(out, 0xee, sizeof(out));
    glmt_glReadPixels(10, 20, 3, 2, GL_RGB, GL_UNSIGNED_BYTE, out);
    CHECK_EQ(out[0], 10);
    CHECK_EQ(out[1], 20);
    CHECK_EQ(out[2], 7);
    CHECK_EQ(out[6], 12);
    CHECK_EQ(out[9], 0xee);       /* row padding is not written */
    CHECK_EQ(out[12], 10);        /* the second row starts at the next multiple of 4 */
    CHECK_EQ(out[13], 21);
    glmt_glReadPixels(0, 0, 1, 1, GL_BGRA, GL_UNSIGNED_BYTE, out);
    CHECK_EQ(out[0], 7);
    CHECK_EQ(out[3], 255);
    end();
}

/* Steam's overlay in the game's frame: glPushAttrib, its own state and a quad in the double
 * spellings, glPopAttrib. The game's state has to be what it was. */
static void test_overlay(void)
{
    begin("overlay", 1 << 20);
    make_texture(1024, 4, GL_RGBA, 4, 1);
    glmt_glEnable(GL_TEXTURE_2D);
    glmt_glEnable(GL_DEPTH_TEST);
    glmt_glColor4f(1.0f, 0.5f, 0.25f, 1.0f);
    glmt_glViewport(0, 0, 640, 480);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);

    glmt_glPushAttrib(0xffffffffu);
    glmt_glPushClientAttrib(0xffffffffu);
    glmt_glMatrixMode(GL_COLOR);
    GLfloat color_matrix[16] = {0};
    glmt_glGetFloatv(GL_COLOR_MATRIX, color_matrix);
    CHECK_NEAR(color_matrix[5], 1.0);
    glmt_glLoadIdentity();
    glmt_glMatrixMode(GL_MODELVIEW);
    glmt_glDisable(0x0BF2); /* GL_COLOR_LOGIC_OP and others glmt does not have: no error */
    glmt_glDisable(0x84F5);
    CHECK_EQ(glmt_glRenderMode(GL_RENDER), 0);
    glmt_glPixelZoom(1.0f, 1.0f);
    glmt_glDisable(GL_DEPTH_TEST);
    glmt_glDisable(GL_TEXTURE_2D);
    glmt_glEnable(GL_BLEND);
    glmt_glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glmt_glViewport(10, 10, 100, 100);
    glmt_glColor4f(0.0f, 0.0f, 0.0f, 0.5f);
    glmt_glDisableClientState(GL_VERTEX_ARRAY);
    glmt_glBindTexture(GL_TEXTURE_2D, 0);
    glmt_glBegin(GL_QUADS);
    glmt_glTexCoord2d(0.0, 0.0);
    glmt_glVertex2d(0.0, 0.0);
    glmt_glTexCoord2d(1.0, 0.0);
    glmt_glVertex2d(1.0, 0.0);
    glmt_glTexCoord2d(1.0, 1.0);
    glmt_glVertex2d(1.0, 1.0);
    glmt_glTexCoord2d(0.0, 1.0);
    glmt_glVertex2d(0.0, 1.0);
    glmt_glEnd();
    glmt_glPopClientAttrib();
    glmt_glPopAttrib();
    CHECK_EQ(glmt_glGetError(), GL_NO_ERROR);

    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    flush();
    CHECK_EQ(rec->draw_count, 2);
    const struct rec_draw *overlay = &rec->draws[0], *game = &rec->draws[1];
    CHECK_EQ(overlay->d.vertex_count, 4);
    CHECK_EQ(overlay->d.index_count, 6);
    CHECK(overlay->d.pipeline & GLMT_PIPE_BLEND);
    CHECK_EQ(overlay->d.texture[0], 0);
    CHECK_EQ(overlay->d.viewport[0], 10);
    CHECK_EQ(overlay->d.depth, 0);
    CHECK_NEAR(positions_of(overlay)[2 * 4 + 1], 1.0);
    /* the game's draw, as if the overlay had not been there */
    CHECK_EQ(game->d.pipeline & GLMT_PIPE_BLEND, 0);
    CHECK(game->d.texture[0] != 0);
    CHECK_EQ(game->d.viewport[0], 0);
    CHECK_EQ(game->d.viewport[2], 640);
    CHECK(game->d.depth & GLMT_DEPTH_TEST);
    CHECK_NEAR(uniforms_of(game)->color[1], 0.5);
    CHECK_EQ(game->d.vertex_count, 4);
    /* more pops than pushes is an error, not a crash */
    glmt_glPopAttrib();
    CHECK_EQ(glmt_glGetError(), GL_STACK_UNDERFLOW);
    end();
}

static void test_swap(void)
{
    begin("swap", 1 << 20);
    glmt_glEnableClientState(GL_VERTEX_ARRAY);
    glmt_glVertexPointer(3, GL_FLOAT, 16, quad_xyz);
    glmt_glClear(GL_COLOR_BUFFER_BIT);
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    CHECK_EQ(rec->draw_count, 0); /* still with the front end */
    glmt_swap_buffers(surface, 0);
    CHECK_EQ(rec->draw_count, 1);
    CHECK_EQ(rec->clear_count, 1);
    CHECK_EQ(rec->presents, 1);
    /* the next frame's uniforms are in the next frame's arena */
    glmt_glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, quad_indices);
    glmt_swap_buffers(surface, 1);
    CHECK_EQ(rec->draw_count, 2);
    CHECK(rec->draws[0].arena != rec->draws[1].arena);
    CHECK_NEAR(uniforms_of(&rec->draws[1])->mvp[0], 1.0);
    CHECK_EQ(rec->last_interval, 1);
    /* a resize reaches the backend */
    glmt_surface_resize(surface, 800, 600);
    CHECK_EQ(rec->width, 800);
    end();
}

int main(void)
{
    test_entry_points();
    test_multipass_surface();
    test_single_pass_surface();
    test_multitexture();
    test_immediate();
    test_state_keys();
    test_clear();
    test_clip_plane();
    test_unlocked_range();
    test_arena_overflow();
    test_textures();
    test_read_pixels();
    test_overlay();
    test_swap();
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
