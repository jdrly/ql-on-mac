/* glmt: OpenGL 1.x (the id Tech 3 subset) on Metal.
 *
 * This is the whole interface between glmt and its host, Wine's Mac driver (winemac.so,
 * dlls/winemac.drv/glmt.c in patches/wine). The host loads libglmt.dylib, asks for the OpenGL
 * entry points by name and hands them to win32u, which gives them to opengl32. The header has no
 * Wine, Objective-C or OpenGL types, so both sides build without the other's headers. */
#ifndef GLMT_H
#define GLMT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on every change to this header that breaks a host built against the previous one. The host
 * refuses a library with another number. */
#define GLMT_ABI_VERSION 1

#define GLMT_API __attribute__((visibility("default")))

typedef struct glmt_context glmt_context;
typedef struct glmt_surface glmt_surface;

/* What a window's default framebuffer has. glmt offers a short fixed list. */
struct glmt_pixel_format
{
    uint8_t color_bits;   /* 32: RGBA 8888 */
    uint8_t alpha_bits;
    uint8_t depth_bits;
    uint8_t stencil_bits;
    uint8_t double_buffer;
};

struct glmt_host
{
    uint32_t abi_version; /* GLMT_ABI_VERSION of the host's build */
    /* One line of log text, without a newline. NULL: glmt writes to the file GLMT_LOG names, or to
     * stderr. */
    void (*log)(const char *line);
};

/* Once per process, before anything else. 0 on success. On failure glmt is unusable, and the host
 * reports that OpenGL is not supported: there is no fallback to another OpenGL. */
GLMT_API int glmt_init(const struct glmt_host *host);

/* The address of an OpenGL entry point (default C calling convention), or NULL for a name glmt does
 * not have. Every OpenGL 1.1 name has an address: glmt's function, or a stub that logs the call. */
GLMT_API void *glmt_get_proc_address(const char *name);

/* The extensions glmt offers, as one space-separated string (what GL_EXTENSIONS returns). */
GLMT_API const char *glmt_extensions(void);

GLMT_API unsigned int glmt_pixel_format_count(void);
/* index from 0. 0 on success. */
GLMT_API int glmt_describe_pixel_format(unsigned int index, struct glmt_pixel_format *format);

/* share: a context whose textures the new one uses too, or NULL. */
GLMT_API glmt_context *glmt_context_create(glmt_context *share);
GLMT_API void glmt_context_destroy(glmt_context *context);

/* layer: the window's CAMetalLayer (not retained by the host for glmt: glmt retains it), or NULL
 * for a surface nothing is shown from. width and height: the framebuffer's size in pixels. */
GLMT_API glmt_surface *glmt_surface_create(void *layer, int width, int height, unsigned int pixel_format);
GLMT_API void glmt_surface_destroy(glmt_surface *surface);
/* The window's framebuffer changed size. */
GLMT_API void glmt_surface_resize(glmt_surface *surface, int width, int height);

/* Makes the context current on the calling thread, drawing to surface. NULL, NULL releases the
 * thread's context. 0 on success. */
GLMT_API int glmt_make_current(glmt_context *context, glmt_surface *surface);

/* Shows what was drawn to the surface. interval: 0 presents at once, 1 or more waits for that many
 * display refreshes. 0 on success. */
GLMT_API int glmt_swap_buffers(glmt_surface *surface, int interval);

#ifdef __cplusplus
}
#endif

#endif
