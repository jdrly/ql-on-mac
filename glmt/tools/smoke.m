/* Draws through libglmt.dylib on this Mac without Wine and checks the pixels: the OpenGL entry points
 * as the host hands them out, the Metal backend on a 64x64 surface without a layer, glReadPixels to
 * see what came of it. Then a few frames on a CAMetalLayer that is in no window, for the present
 * path.
 *
 *     make -C glmt smoke
 *
 * This is where the backend's behaviour is pinned down: which way is up, which winding is front,
 * which depth is near, what each texture environment and blend does. Add a scene here with every
 * backend change. */
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

#include <string.h>
#include <unistd.h>

#include "gl.h"
#include "glmt.h"

#define SIZE 64

#define GL(ret, name, params) static ret (*name) params
GL(void, glClearColor, (GLclampf, GLclampf, GLclampf, GLclampf));
GL(void, glClearDepth, (GLclampd));
GL(void, glClear, (GLbitfield));
GL(void, glEnable, (GLenum));
GL(void, glDisable, (GLenum));
GL(void, glBindTexture, (GLenum, GLuint));
GL(void, glTexImage2D, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *));
GL(void, glTexSubImage2D, (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *));
GL(void, glTexParameteri, (GLenum, GLenum, GLint));
GL(void, glTexEnvi, (GLenum, GLenum, GLint));
GL(void, glBegin, (GLenum));
GL(void, glEnd, (void));
GL(void, glColor4f, (GLfloat, GLfloat, GLfloat, GLfloat));
GL(void, glTexCoord2f, (GLfloat, GLfloat));
GL(void, glTexCoord2d, (GLdouble, GLdouble));
GL(void, glMultiTexCoord2fARB, (GLenum, GLfloat, GLfloat));
GL(void, glVertex2f, (GLfloat, GLfloat));
GL(void, glVertex2d, (GLdouble, GLdouble));
GL(void, glVertex3f, (GLfloat, GLfloat, GLfloat));
GL(void, glReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *));
GL(void, glCullFace, (GLenum));
GL(void, glAlphaFunc, (GLenum, GLclampf));
GL(void, glBlendFunc, (GLenum, GLenum));
GL(void, glDepthFunc, (GLenum));
GL(void, glDepthMask, (GLboolean));
GL(void, glColorMask, (GLboolean, GLboolean, GLboolean, GLboolean));
GL(void, glScissor, (GLint, GLint, GLsizei, GLsizei));
GL(void, glViewport, (GLint, GLint, GLsizei, GLsizei));
GL(void, glMatrixMode, (GLenum));
GL(void, glLoadIdentity, (void));
GL(void, glOrtho, (GLdouble, GLdouble, GLdouble, GLdouble, GLdouble, GLdouble));
GL(void, glActiveTextureARB, (GLenum));
GL(void, glClientActiveTextureARB, (GLenum));
GL(void, glEnableClientState, (GLenum));
GL(void, glDisableClientState, (GLenum));
GL(void, glVertexPointer, (GLint, GLenum, GLsizei, const void *));
GL(void, glColorPointer, (GLint, GLenum, GLsizei, const void *));
GL(void, glTexCoordPointer, (GLint, GLenum, GLsizei, const void *));
GL(void, glLockArraysEXT, (GLint, GLsizei));
GL(void, glUnlockArraysEXT, (void));
GL(void, glDrawElements, (GLenum, GLsizei, GLenum, const void *));
GL(void, glPushAttrib, (GLbitfield));
GL(void, glPopAttrib, (void));
GL(void, glPushClientAttrib, (GLbitfield));
GL(void, glPopClientAttrib, (void));
GL(void, glPolygonOffset, (GLfloat, GLfloat));
GL(void, glStencilFunc, (GLenum, GLint, GLuint));
GL(void, glStencilOp, (GLenum, GLenum, GLenum));
GL(void, glClearStencil, (GLint));
GL(void, glFinish, (void));
GL(GLenum, glGetError, (void));
#undef GL

static int failures, checks;

static void load(void)
{
#define LOAD(name) \
    if (!(name = glmt_get_proc_address(#name))) \
    { \
        fprintf(stderr, "smoke: no %s\n", #name); \
        exit(1); \
    }
    LOAD(glClearColor) LOAD(glClearDepth) LOAD(glClear) LOAD(glEnable) LOAD(glDisable) LOAD(glBindTexture)
    LOAD(glTexImage2D) LOAD(glTexSubImage2D) LOAD(glTexParameteri) LOAD(glTexEnvi) LOAD(glBegin) LOAD(glEnd)
    LOAD(glColor4f) LOAD(glTexCoord2f) LOAD(glTexCoord2d) LOAD(glMultiTexCoord2fARB) LOAD(glVertex2f) LOAD(glVertex2d)
    LOAD(glVertex3f) LOAD(glReadPixels) LOAD(glCullFace) LOAD(glAlphaFunc) LOAD(glBlendFunc) LOAD(glDepthFunc)
    LOAD(glDepthMask) LOAD(glColorMask) LOAD(glScissor) LOAD(glViewport) LOAD(glMatrixMode) LOAD(glLoadIdentity)
    LOAD(glOrtho) LOAD(glActiveTextureARB) LOAD(glClientActiveTextureARB) LOAD(glEnableClientState)
    LOAD(glDisableClientState) LOAD(glVertexPointer) LOAD(glColorPointer) LOAD(glTexCoordPointer) LOAD(glLockArraysEXT)
    LOAD(glUnlockArraysEXT) LOAD(glDrawElements) LOAD(glPushAttrib) LOAD(glPopAttrib) LOAD(glPushClientAttrib)
    LOAD(glPopClientAttrib) LOAD(glPolygonOffset) LOAD(glStencilFunc) LOAD(glStencilOp) LOAD(glClearStencil)
    LOAD(glFinish) LOAD(glGetError)
#undef LOAD
}

/* The pixel at (x, y), OpenGL's way: the origin is the bottom left. */
static void expect(const char *what, int x, int y, int r, int g, int b)
{
    uint8_t p[4] = {0};

    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, p);
    checks++;
    if (abs(p[0] - r) > 3 || abs(p[1] - g) > 3 || abs(p[2] - b) > 3)
    {
        failures++;
        printf("FAIL %s: pixel (%d, %d) is %d %d %d, expected %d %d %d\n", what, x, y, p[0], p[1], p[2], r, g, b);
    }
}

/* A rectangle in clip space at depth z, with texture coordinates 0..1 across it on both units. */
static void quad(float x0, float y0, float x1, float y1, float z)
{
    static const float corner[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};

    glBegin(GL_QUADS);
    for (int i = 0; i < 4; i++)
    {
        glTexCoord2f(corner[i][0], corner[i][1]);
        glMultiTexCoord2fARB(GL_TEXTURE0 + 1, corner[i][0], corner[i][1]);
        glVertex3f(corner[i][0] ? x1 : x0, corner[i][1] ? y1 : y0, z);
    }
    glEnd();
}

static void full_quad(void) { quad(-1, -1, 1, 1, 0); }

static void clear(float r, float g, float b)
{
    glClearColor(r, g, b, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

static void texture(GLuint name, int width, int height, const uint8_t *rgba, GLint internal)
{
    glBindTexture(GL_TEXTURE_2D, name);
    glTexImage2D(GL_TEXTURE_2D, 0, internal, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
}

static void scenes(void)
{
    /* red, green in the first row (t = 0); blue, white in the second */
    static const uint8_t four[] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
    /* opaque red, then red that is fully transparent */
    static const uint8_t holes[] = {255, 0, 0, 255, 255, 0, 0, 0};
    static const uint8_t grey[] = {128, 128, 128, 255}, white[] = {255, 255, 255, 255};

    /* clear */
    clear(1, 0, 0);
    expect("clear", 32, 32, 255, 0, 0);

    /* a quad in the current color, and which way is up */
    glColor4f(0, 1, 0, 1);
    full_quad();
    expect("quad", 32, 32, 0, 255, 0);
    glColor4f(0, 0, 1, 1);
    quad(-1, -1, 0, 0, 0);
    expect("bottom left quarter", 16, 16, 0, 0, 255);
    expect("the rest stays", 48, 48, 0, 255, 0);
    expect("the rest stays", 16, 48, 0, 255, 0);

    /* the viewport's origin is the bottom left */
    clear(0, 0, 0);
    glViewport(32, 32, 32, 32);
    glColor4f(1, 0, 1, 1);
    full_quad();
    glViewport(0, 0, SIZE, SIZE);
    expect("viewport, inside", 48, 48, 255, 0, 255);
    expect("viewport, outside", 16, 16, 0, 0, 0);
    expect("viewport, outside", 48, 16, 0, 0, 0);

    /* glOrtho as id Tech 3 sets 2D up: y down */
    clear(0, 0, 0);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, 640, 480, 0, 0, 1);
    glMatrixMode(GL_MODELVIEW);
    glColor4f(1, 1, 0, 1);
    quad(0, 0, 320, 240, 0); /* the top left quarter of a 640x480 screen */
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    expect("ortho, top left", 16, 48, 255, 255, 0);
    expect("ortho, bottom right", 48, 16, 0, 0, 0);

    /* winding: counter-clockwise is the front, and back faces are culled */
    clear(0, 0, 0);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    glColor4f(1, 1, 1, 1);
    full_quad(); /* counter-clockwise */
    expect("front face is drawn", 32, 32, 255, 255, 255);
    clear(0, 0, 0);
    quad(1, -1, -1, 1, 0); /* mirrored: clockwise */
    expect("back face is culled", 32, 32, 0, 0, 0);
    glCullFace(GL_FRONT);
    quad(1, -1, -1, 1, 0);
    expect("front culled, back drawn", 32, 32, 255, 255, 255);
    glDisable(GL_CULL_FACE);

    /* a texture: s to the right, t up, the first row of the image at the bottom */
    clear(0, 0, 0);
    glEnable(GL_TEXTURE_2D);
    texture(100, 2, 2, four, GL_RGBA8);
    full_quad();
    expect("texel 0,0 bottom left", 16, 16, 255, 0, 0);
    expect("texel 1,0 bottom right", 48, 16, 0, 255, 0);
    expect("texel 0,1 top left", 16, 48, 0, 0, 255);
    expect("texel 1,1 top right", 48, 48, 255, 255, 255);
    /* modulated by the color */
    glColor4f(0.5f, 0.5f, 0.5f, 1);
    full_quad();
    expect("modulate", 48, 48, 128, 128, 128);
    expect("modulate", 16, 16, 128, 0, 0);
    /* an update of a part */
    glTexSubImage2D(GL_TEXTURE_2D, 0, 1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, four);
    glColor4f(1, 1, 1, 1);
    full_quad();
    expect("glTexSubImage2D", 48, 48, 255, 0, 0);
    expect("glTexSubImage2D leaves the rest", 16, 48, 0, 0, 255);

    /* alpha test: transparent texels leave what was there */
    clear(0, 0, 1);
    texture(101, 2, 1, holes, GL_RGBA8);
    glEnable(GL_ALPHA_TEST);
    glAlphaFunc(GL_GREATER, 0.5f);
    full_quad();
    expect("alpha test passes", 16, 32, 255, 0, 0);
    expect("alpha test discards", 48, 32, 0, 0, 255);
    glDisable(GL_ALPHA_TEST);

    /* blending */
    clear(0.25f, 0, 0);
    glDisable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glColor4f(0, 0.5f, 0, 1);
    full_quad();
    expect("additive blend", 32, 32, 64, 128, 0);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    clear(0, 0, 1);
    glColor4f(1, 0, 0, 0.5f);
    full_quad();
    expect("alpha blend", 32, 32, 128, 0, 128);
    glBlendFunc(GL_DST_COLOR, GL_ZERO); /* a lightmap pass */
    clear(1, 0.5f, 0.25f);
    glColor4f(0.5f, 0.5f, 0.5f, 1);
    full_quad();
    expect("multiply blend", 32, 32, 128, 64, 32);
    glDisable(GL_BLEND);

    /* depth: smaller z is nearer */
    clear(0, 0, 0);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glColor4f(1, 0, 0, 1);
    quad(-1, -1, 1, 1, -0.5f);
    glColor4f(0, 1, 0, 1);
    quad(-1, -1, 1, 1, 0.5f);
    expect("the farther quad is hidden", 32, 32, 255, 0, 0);
    glColor4f(0, 0, 1, 1);
    quad(-1, -1, 1, 1, -0.9f);
    expect("the nearer quad shows", 32, 32, 0, 0, 255);
    /* a depth clear in the middle of the frame, as id Tech 3 does before each view */
    glClear(GL_DEPTH_BUFFER_BIT);
    expect("a depth clear leaves color", 32, 32, 0, 0, 255);
    glColor4f(0, 1, 0, 1);
    quad(-1, -1, 1, 1, 0.5f);
    expect("after the depth clear the far quad shows", 32, 32, 0, 255, 0);
    /* depth writes off */
    glDepthMask(GL_FALSE);
    glColor4f(1, 1, 1, 1);
    quad(-1, -1, 1, 1, 0.0f);
    glDepthMask(GL_TRUE);
    glColor4f(1, 0, 1, 1);
    quad(-1, -1, 1, 1, 0.25f);
    expect("a quad drawn without depth writes hides nothing", 32, 32, 255, 0, 255);
    /* polygon offset pulls a coplanar decal in front under GL_LESS */
    glClear(GL_DEPTH_BUFFER_BIT);
    glDepthFunc(GL_LESS);
    glColor4f(1, 0, 0, 1);
    full_quad();
    glColor4f(0, 1, 0, 1);
    full_quad();
    expect("coplanar under GL_LESS is hidden", 32, 32, 255, 0, 0);
    glEnable(GL_POLYGON_OFFSET_FILL);
    glPolygonOffset(-1, -2);
    full_quad();
    glDisable(GL_POLYGON_OFFSET_FILL);
    expect("polygon offset brings it forward", 32, 32, 0, 255, 0);
    glDisable(GL_DEPTH_TEST);

    /* scissor, for draws and for clears */
    clear(0, 0, 0);
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, 0, 32, 32);
    glColor4f(1, 1, 1, 1);
    full_quad();
    expect("scissor, inside", 16, 16, 255, 255, 255);
    expect("scissor, outside", 48, 48, 0, 0, 0);
    glScissor(32, 32, 32, 32);
    glClearColor(1, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    expect("scissored clear, inside", 48, 48, 255, 255, 0);
    expect("scissored clear, outside", 16, 16, 255, 255, 255);
    glDisable(GL_SCISSOR_TEST);

    /* color mask, for draws and for clears */
    clear(0, 0, 0);
    glColorMask(GL_TRUE, GL_FALSE, GL_FALSE, GL_TRUE);
    glColor4f(1, 1, 1, 1);
    full_quad();
    expect("color mask", 32, 32, 255, 0, 0);
    glColorMask(GL_FALSE, GL_TRUE, GL_FALSE, GL_TRUE);
    glClearColor(1, 1, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    expect("masked clear", 32, 32, 255, 255, 0);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

    /* stencil: draw where the first quad marked */
    glClearStencil(0);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    glEnable(GL_STENCIL_TEST);
    glStencilFunc(GL_ALWAYS, 1, 0xff);
    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
    glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    quad(-1, -1, 0, 1, 0);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glStencilFunc(GL_EQUAL, 1, 0xff);
    glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
    glColor4f(0, 1, 1, 1);
    full_quad();
    glDisable(GL_STENCIL_TEST);
    expect("stencil, marked", 16, 32, 0, 255, 255);
    expect("stencil, not marked", 48, 32, 0, 0, 0);

    /* two texture units, as a lightmapped surface: modulate, then add */
    clear(0, 0, 0);
    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, 100);
    glActiveTextureARB(GL_TEXTURE0 + 1);
    glEnable(GL_TEXTURE_2D);
    texture(102, 1, 1, grey, GL_RGBA8);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
    glColor4f(1, 1, 1, 1);
    full_quad();
    expect("two units, modulate", 16, 16, 128, 0, 0);
    expect("two units, modulate", 16, 48, 0, 0, 128);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_ADD);
    full_quad();
    expect("two units, add", 16, 16, 255, 128, 128);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
    glDisable(GL_TEXTURE_2D);
    glActiveTextureARB(GL_TEXTURE0);

    /* a surface as id Tech 3 draws it: locked positions in its 16-byte layout, a color array, a
     * texture coordinate array, glDrawElements */
    {
        static const float xyz[4][4] = {{-1, -1, 0, 9}, {1, -1, 0, 9}, {1, 1, 0, 9}, {-1, 1, 0, 9}};
        static const uint8_t colors[4][4] = {{255, 0, 0, 255}, {255, 0, 0, 255}, {0, 0, 255, 255}, {0, 0, 255, 255}};
        static const float st[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
        static const uint32_t indices[6] = {0, 1, 2, 0, 2, 3};

        clear(0, 0, 0);
        texture(103, 1, 1, white, GL_RGB8);
        glEnableClientState(GL_VERTEX_ARRAY);
        glVertexPointer(3, GL_FLOAT, 16, xyz);
        glLockArraysEXT(0, 4);
        glEnableClientState(GL_COLOR_ARRAY);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        glColorPointer(4, GL_UNSIGNED_BYTE, 0, colors);
        glTexCoordPointer(2, GL_FLOAT, 0, st);
        glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, indices);
        glUnlockArraysEXT();
        glDisableClientState(GL_COLOR_ARRAY);
        glDisableClientState(GL_TEXTURE_COORD_ARRAY);
        glDisableClientState(GL_VERTEX_ARRAY);
        /* the colors run from red at the bottom edge to blue at the top edge; a pixel's center is
         * half a pixel in */
        expect("arrays, near the bottom", 32, 2, 245, 0, 10);
        expect("arrays, near the top", 32, 61, 10, 0, 245);
        expect("arrays, middle", 32, 32, 126, 0, 129);
    }

    /* Steam's overlay: everything saved, its own state, a quad with the double spellings, everything
     * put back */
    clear(0, 0, 0);
    glBindTexture(GL_TEXTURE_2D, 100);
    glColor4f(1, 1, 1, 1);
    glPushAttrib(0xffffffffu);
    glPushClientAttrib(0xffffffffu);
    glDisable(GL_TEXTURE_2D);
    glDisable(0x84F5); /* a capability glmt does not have */
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glColor4f(0, 0.25f, 0, 1);
    glViewport(0, 0, 32, 32);
    glBegin(GL_QUADS);
    glTexCoord2d(0, 0);
    glVertex2d(-1, -1);
    glTexCoord2d(1, 0);
    glVertex2d(1, -1);
    glTexCoord2d(1, 1);
    glVertex2d(1, 1);
    glTexCoord2d(0, 1);
    glVertex2d(-1, 1);
    glEnd();
    glPopClientAttrib();
    glPopAttrib();
    expect("the overlay's quad", 16, 16, 0, 64, 0);
    full_quad(); /* the game's state again: textured, no blend, the whole viewport, white */
    expect("state after glPopAttrib", 48, 48, 255, 0, 0);
    expect("state after glPopAttrib", 16, 16, 255, 0, 0);
    glDisable(GL_TEXTURE_2D);
}

int main(void)
{
    @autoreleasepool
    {
        struct glmt_host host = {GLMT_ABI_VERSION, NULL};
        bool metal = !getenv("GLMT_BACKEND") || !strcmp(getenv("GLMT_BACKEND"), "metal");
        CAMetalLayer *layer = [CAMetalLayer layer];
        glmt_context *context;
        glmt_surface *offscreen, *window;

        if (glmt_init(&host))
        {
            fprintf(stderr, "smoke: glmt_init failed\n");
            return 1;
        }
        load();
        if (!(context = glmt_context_create(NULL)) || !(offscreen = glmt_surface_create(NULL, SIZE, SIZE, 0)) ||
            glmt_make_current(context, offscreen))
        {
            fprintf(stderr, "smoke: no context or no surface\n");
            return 1;
        }

        if (metal)
        {
            scenes();
            if (glGetError() != GL_NO_ERROR)
            {
                printf("FAIL an OpenGL error was raised\n");
                failures++;
            }
            printf("smoke: %d pixel checks, %d failures\n", checks, failures);
        }

        /* the present path: frames on a layer, a resize in between */
        if (!(window = glmt_surface_create((__bridge void *)layer, 640, 480, 0)) || glmt_make_current(context, window))
        {
            fprintf(stderr, "smoke: no surface on a layer\n");
            return 1;
        }
        for (int frame = 0; frame < 5; frame++)
        {
            clear(0.1f * (float)frame, 0.2f, 0.3f);
            glColor4f(1, 1, 1, 1);
            full_quad();
            glClear(GL_DEPTH_BUFFER_BIT);
            if (frame == 2) glmt_surface_resize(window, 800, 600);
            if (glmt_swap_buffers(window, 0))
            {
                fprintf(stderr, "smoke: swap %d failed\n", frame);
                return 1;
            }
        }
        glFinish();
        /* the GPU finishes the last frames and hands their arenas back */
        [NSThread sleepForTimeInterval:0.3];
        if (getenv("GLMT_PRESENT") && !strcmp(getenv("GLMT_PRESENT"), "async"))
        {
            /* GLMT_PRESENT=async: what its presenter thread has to live through. The game asks for
             * vsync and takes it back (the thread hands the layer over and gets it again), a
             * read-back in the middle of a frame, and a second surface on the layer of one that
             * was just destroyed. This shows that nothing hangs or crashes (a hang ends the run
             * after 30 seconds), not what reaches a display: the layer is in no window. */
            static const int intervals[] = {0, 0, 0, 1, 1, 0, 0, 0};
            unsigned char pixel[4];

            alarm(30);
            for (int frame = 0; frame < 8; frame++)
            {
                clear(0.3f, 0.1f * (float)frame, 0.2f);
                full_quad();
                if (frame == 6) glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
                full_quad();
                if (glmt_swap_buffers(window, intervals[frame]))
                {
                    fprintf(stderr, "smoke: async swap %d failed\n", frame);
                    return 1;
                }
                [NSThread sleepForTimeInterval:0.01];
            }
            glmt_make_current(context, offscreen);
            glmt_surface_destroy(window);
            if (!(window = glmt_surface_create((__bridge void *)layer, 800, 600, 0)) || glmt_make_current(context, window))
            {
                fprintf(stderr, "smoke: no second surface on the layer\n");
                return 1;
            }
            for (int frame = 0; frame < 3; frame++)
            {
                clear(0.2f, 0.3f, 0.1f * (float)frame);
                full_quad();
                glmt_swap_buffers(window, 0);
                [NSThread sleepForTimeInterval:0.01];
            }
            [NSThread sleepForTimeInterval:0.2];
            alarm(0);
            printf("smoke: async: vsync on and off, a read-back in a frame and a second surface on the layer, no hang\n");
        }
        glmt_make_current(NULL, NULL);
        glmt_context_destroy(context);
        glmt_surface_destroy(window);
        glmt_surface_destroy(offscreen);
        printf("smoke: 5 frames presented on the %s backend\n", metal ? "metal" : getenv("GLMT_BACKEND"));
        return failures != 0;
    }
}
