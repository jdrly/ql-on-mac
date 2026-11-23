/* A 32-bit Windows program for Wine: does opengl32's batching (patches/wine/0004, WINE_GLMT_BATCH)
 * draw what one call per crossing draws, and what does a call cost each way?
 *
 * It draws the way id Tech 3 does: one set of arrays that is written anew for every surface and
 * again between a surface's two stages, positions locked with GL_EXT_compiled_vertex_array,
 * glDrawElements. If a batch let a state call or an array pointer overtake a draw, or a draw
 * read arrays that were already rewritten, the picture would differ. The picture is read back
 * and its checksum printed: the same number with batching off and on is the pass.
 *
 * Then two timings: state calls alone (glEnable and glDisable in turn), and whole surfaces
 * (a dozen state calls and two draws each, as in the game's traced frames).
 *
 * scripts/batchtest.zsh builds it with llvm-mingw and runs it both ways under the engine's Wine,
 * as glmt's program (WINE_GLMT_EXE). */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <GL/gl.h>

#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif
#define GL_TEXTURE0_ARB 0x84C0

#define SIZE 256
#define SURFACES 64

static void (WINAPI *p_glLockArraysEXT)(GLint first, GLsizei count);
static void (WINAPI *p_glUnlockArraysEXT)(void);
static void (WINAPI *p_glActiveTextureARB)(GLenum texture);
static void (WINAPI *p_glClientActiveTextureARB)(GLenum texture);

/* the one set of arrays every surface is written into, as tess.xyz and its neighbours are */
static float xyz[4][4];
static float st[4][2];
static unsigned char colors[4][4];
static const unsigned int indexes[6] = {0, 1, 2, 0, 2, 3};

static double now_ms(void)
{
    LARGE_INTEGER count, rate;

    QueryPerformanceCounter(&count);
    QueryPerformanceFrequency(&rate);
    return (double)count.QuadPart * 1000.0 / (double)rate.QuadPart;
}

/* One surface: its quad goes into the shared arrays, two stages are drawn from them, and between
 * the stages the colors and texture coordinates are written anew in place. */
static void surface(int n, GLuint texture)
{
    float x = (float)(n % 8) * 32.0f, y = (float)(n / 8) * 32.0f, w = 20.0f + (float)(n % 5) * 3.0f;
    int i;

    xyz[0][0] = x;     xyz[0][1] = y;
    xyz[1][0] = x + w; xyz[1][1] = y;
    xyz[2][0] = x + w; xyz[2][1] = y + w;
    xyz[3][0] = x;     xyz[3][1] = y + w;
    for (i = 0; i < 4; i++) xyz[i][2] = 0.0f, xyz[i][3] = 1.0f;

    glScissor((GLint)x, (GLint)y, 30, 30);
    glVertexPointer(3, GL_FLOAT, 16, xyz);
    p_glLockArraysEXT(0, 4);

    /* the first stage: opaque, the texture times a color of the surface's own */
    for (i = 0; i < 4; i++)
    {
        colors[i][0] = (unsigned char)(40 + n * 3);
        colors[i][1] = (unsigned char)(250 - n * 2);
        colors[i][2] = (unsigned char)(i * 60);
        colors[i][3] = 255;
        st[i][0] = (float)(i == 1 || i == 2);
        st[i][1] = (float)(i >= 2);
    }
    glEnableClientState(GL_COLOR_ARRAY);
    glColorPointer(4, GL_UNSIGNED_BYTE, 0, colors);
    p_glClientActiveTextureARB(GL_TEXTURE0_ARB);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glTexCoordPointer(2, GL_FLOAT, 0, st);
    p_glActiveTextureARB(GL_TEXTURE0_ARB);
    glBindTexture(GL_TEXTURE_2D, texture);
    glDisable(GL_BLEND);
    glDepthMask(GL_TRUE);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, indexes);

    /* the second stage: added on top, from the same arrays with new contents */
    for (i = 0; i < 4; i++)
    {
        colors[i][0] = (unsigned char)(n * 2);
        colors[i][1] = 30;
        colors[i][2] = (unsigned char)(200 - i * 40);
        colors[i][3] = 255;
        st[i][0] *= 0.5f;
        st[i][1] *= 0.5f;
    }
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glDepthMask(GL_FALSE);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, indexes);

    glDisableClientState(GL_COLOR_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    p_glUnlockArraysEXT();
}

static void frame(GLuint texture)
{
    int n;

    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.1f, 0.2f, 0.3f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_TEXTURE_2D);
    glEnableClientState(GL_VERTEX_ARRAY);
    for (n = 0; n < SURFACES; n++) surface(n, texture);
}

int main(void)
{
    static const unsigned char texels[4][4] = {{255, 255, 255, 255}, {255, 64, 64, 255}, {64, 255, 64, 255}, {64, 64, 255, 255}};
    static unsigned char pixels[SIZE * SIZE * 4];
    PIXELFORMATDESCRIPTOR pfd;
    unsigned int sum = 2166136261u, lit = 0;
    double start, state_ns, surface_ns;
    GLuint texture = 0;
    HGLRC context;
    HWND window;
    int i, format;
    HDC dc;

    window = CreateWindowExA(0, "static", "glmt batch test", WS_POPUP | WS_VISIBLE, 80, 80, SIZE, SIZE, NULL, NULL, NULL, NULL);
    if (!window || !(dc = GetDC(window)))
    {
        printf("batchtest: no window\n");
        return 2;
    }
    memset(&pfd, 0, sizeof(pfd));
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    if (!(format = ChoosePixelFormat(dc, &pfd)) || !SetPixelFormat(dc, format, &pfd) || !(context = wglCreateContext(dc)) ||
        !wglMakeCurrent(dc, context))
    {
        printf("batchtest: no OpenGL context (error %lu)\n", GetLastError());
        return 2;
    }
    printf("batchtest: renderer %s, version %s\n", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));

    p_glLockArraysEXT = (void *)wglGetProcAddress("glLockArraysEXT");
    p_glUnlockArraysEXT = (void *)wglGetProcAddress("glUnlockArraysEXT");
    p_glActiveTextureARB = (void *)wglGetProcAddress("glActiveTextureARB");
    p_glClientActiveTextureARB = (void *)wglGetProcAddress("glClientActiveTextureARB");
    if (!p_glLockArraysEXT || !p_glUnlockArraysEXT || !p_glActiveTextureARB || !p_glClientActiveTextureARB)
    {
        printf("batchtest: an extension function is missing\n");
        return 2;
    }

    glViewport(0, 0, SIZE, SIZE);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, SIZE, 0, SIZE, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
    glDepthFunc(GL_LEQUAL);
    glEnable(GL_DEPTH_TEST);

    /* the picture */
    frame(texture);
    glDisable(GL_SCISSOR_TEST);
    glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    for (i = 0; i < SIZE * SIZE * 4; i++) sum = (sum ^ pixels[i]) * 16777619u;
    for (i = 0; i < SIZE * SIZE; i++) lit += pixels[i * 4] > 60 || pixels[i * 4 + 1] > 80;
    printf("batchtest: picture checksum %08x, %u of %u pixels drawn on, GL error 0x%04x\n", sum, lit, (unsigned)(SIZE * SIZE),
           glGetError());
    printf("batchtest: pixel (10,10) %u %u %u, (170,200) %u %u %u, (31,31) %u %u %u\n", pixels[(10 * SIZE + 10) * 4],
           pixels[(10 * SIZE + 10) * 4 + 1], pixels[(10 * SIZE + 10) * 4 + 2], pixels[(200 * SIZE + 170) * 4],
           pixels[(200 * SIZE + 170) * 4 + 1], pixels[(200 * SIZE + 170) * 4 + 2], pixels[(31 * SIZE + 31) * 4],
           pixels[(31 * SIZE + 31) * 4 + 1], pixels[(31 * SIZE + 31) * 4 + 2]);
    SwapBuffers(dc);

    /* state calls alone: a million pairs, with a glFinish at the end so that nothing is left waiting */
    glFinish();
    start = now_ms();
    for (i = 0; i < 1000000; i++)
    {
        glEnable(GL_BLEND);
        glDisable(GL_BLEND);
    }
    glFinish();
    state_ns = (now_ms() - start) * 1e6 / 2000000.0;

    /* whole surfaces: 2,000 frames of 64 */
    start = now_ms();
    for (i = 0; i < 2000; i++) frame(texture);
    glFinish();
    surface_ns = (now_ms() - start) * 1e6 / (2000.0 * SURFACES);
    printf("batchtest: a state call %.0f ns; a surface (21 state calls, 2 draws) %.0f ns, so %.2f ms for a frame of 300 surfaces\n",
           state_ns, surface_ns, surface_ns * 300.0 / 1e6);

    /* and the picture once more after all that, to see that the state is still what it was */
    frame(texture);
    glDisable(GL_SCISSOR_TEST);
    glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    for (sum = 2166136261u, i = 0; i < SIZE * SIZE * 4; i++) sum = (sum ^ pixels[i]) * 16777619u;
    printf("batchtest: picture checksum at the end %08x\n", sum);

    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(context);
    ReleaseDC(window, dc);
    DestroyWindow(window);
    return 0;
}
