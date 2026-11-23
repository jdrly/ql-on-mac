/* The host's side of glmt (glmt.h): contexts, surfaces, the entry point table, the log. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "api.h"
#include "internal.h"

_Thread_local struct glmt_context *glmt_current;

static struct glmt_backend *backend;
static void (*host_log)(const char *line);
static FILE *log_file;
static int stats_interval; /* frames between two lines of GLMT_STATS, 0: none */
bool glmt_debug;
bool glmt_trace;
bool glmt_profile;
/* GLMT_TRACE="30 300 3000": the frames whose entry points are logged by name, counted from 1 */
static uint64_t trace_frames[8];
static int trace_count;

static bool traced(uint64_t frame)
{
    for (int i = 0; i < trace_count; i++)
        if (trace_frames[i] == frame) return true;
    return false;
}

/* ---- log ---- */

void glmt_log(const char *format, ...)
{
    char line[1024];
    va_list args;

    va_start(args, format);
    vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (host_log) host_log(line);
    else
    {
        FILE *out = log_file ? log_file : stderr;
        fprintf(out, "%s\n", line);
        fflush(out);
    }
}

double glmt_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ---- entry points by name ---- */

/* An OpenGL 1.1 entry point glmt does not implement. Wine calls it through its table without a
 * check, so it has to exist; what it does is count the call and name it in the log the first time.
 * The game's real needs show up there. On arm64 a function that takes no arguments and returns 0
 * can stand in for any signature: the caller owns the argument registers and the stack. */
struct stub
{
    const char *name;
    uint64_t calls;
};

enum
{
#define GL_CORE(name) STUB_##name,
#include "gl_core.inc"
#undef GL_CORE
    STUB_COUNT
};

static struct stub stubs[STUB_COUNT] = {
#define GL_CORE(name) {#name, 0},
#include "gl_core.inc"
#undef GL_CORE
};

static uintptr_t stub_called(int index)
{
    if (!stubs[index].calls++) glmt_log("glmt: %s is called, and glmt does not implement it", stubs[index].name);
    if (glmt_trace) glmt_log("glmt: > %s (not implemented)", stubs[index].name);
    return 0;
}

#define GL_CORE(name) \
    static uintptr_t stub_##name(void) { return stub_called(STUB_##name); }
#include "gl_core.inc"
#undef GL_CORE

static const struct
{
    const char *name;
    void *address;
} implemented[] = {
#define GL_IMPL(ret, name, params) {#name, (void *)glmt_##name},
#include "gl_impl.inc"
#undef GL_IMPL
}, stubbed[] = {
#define GL_CORE(name) {#name, (void *)stub_##name},
#include "gl_core.inc"
#undef GL_CORE
};

void *glmt_get_proc_address(const char *name)
{
    for (size_t i = 0; i < sizeof(implemented) / sizeof(implemented[0]); i++)
        if (!strcmp(implemented[i].name, name)) return implemented[i].address;
    for (size_t i = 0; i < sizeof(stubbed) / sizeof(stubbed[0]); i++)
        if (!strcmp(stubbed[i].name, name)) return stubbed[i].address;
    return NULL;
}

/* One line with every unimplemented entry point called so far, when the list or a count changed. */
static void log_stub_calls(void)
{
    static uint64_t reported;
    char line[900];
    uint64_t total = 0;
    size_t used = 0;

    for (int i = 0; i < STUB_COUNT; i++) total += stubs[i].calls;
    if (total == reported) return;
    reported = total;
    line[0] = 0;
    for (int i = 0; i < STUB_COUNT && used < sizeof(line) - 64; i++)
        if (stubs[i].calls)
            used += (size_t)snprintf(line + used, sizeof(line) - used, " %s %llu,", stubs[i].name, (unsigned long long)stubs[i].calls);
    glmt_log("glmt: called without an implementation so far:%s", line);
}

/* ---- init ---- */

void glmt_set_backend(struct glmt_backend *be) { backend = be; }

int glmt_init(const struct glmt_host *host)
{
    const char *value;

    if (host && host->abi_version != GLMT_ABI_VERSION) return -1;
    host_log = host ? host->log : NULL;
    if (!host_log && !log_file && (value = getenv("GLMT_LOG")) && *value) log_file = fopen(value, "a");
    if ((value = getenv("GLMT_STATS"))) stats_interval = atoi(value);
    glmt_debug = (value = getenv("GLMT_DEBUG")) && *value && strcmp(value, "0");
    glmt_profile = (value = getenv("GLMT_PROFILE")) && *value && strcmp(value, "0");
    if (glmt_profile && !stats_interval) stats_interval = 1000;
    if ((value = getenv("GLMT_TRACE")))
    {
        char *end;
        unsigned long long frame;

        for (trace_count = 0; trace_count < 8 && (frame = strtoull(value, &end, 10), end != value); value = end)
            trace_frames[trace_count++] = frame;
        glmt_trace = traced(1);
    }

    if (!backend)
    {
        /* GLMT_BACKEND=null draws nothing: the frame rate with it is what the game, FEX and Wine's
         * call path cost before Metal does anything. */
        value = getenv("GLMT_BACKEND");
        if (value && !strcmp(value, "null")) backend = glmt_backend_null_create();
        else backend = glmt_backend_metal_create();
        if (!backend)
        {
            glmt_log("glmt: no %s backend in this build", value && *value ? value : "metal");
            return -1;
        }
    }
    glmt_log("glmt: %s backend, ABI %d%s", backend->name, GLMT_ABI_VERSION, glmt_debug ? ", debug" : "");
    GLMT_DEBUG("glmt: extensions: %s", glmt_extensions());
    return 0;
}

/* ---- pixel formats ---- */

static const struct glmt_pixel_format pixel_formats[] = {
    {32, 8, 24, 8, 1},
    {32, 8, 24, 0, 1},
    {32, 0, 24, 8, 1},
    {32, 0, 24, 0, 1},
};

unsigned int glmt_pixel_format_count(void) { return sizeof(pixel_formats) / sizeof(pixel_formats[0]); }

int glmt_describe_pixel_format(unsigned int index, struct glmt_pixel_format *format)
{
    if (index >= glmt_pixel_format_count()) return -1;
    *format = pixel_formats[index];
    return 0;
}

/* ---- packets and arena ---- */

void glmt_flush_packets(struct glmt_context *c)
{
    if (!c->packet_bytes) return;
    if (c->surface)
    {
        double start = stats_interval ? glmt_now() : 0.0;

        c->be->submit(c->be, c->surface->be_surface, c->packets, c->packet_bytes);
        if (stats_interval)
        {
            double ms = (glmt_now() - start) * 1000.0;
            if (ms > c->stats.worst_submit_ms) c->stats.worst_submit_ms = ms;
        }
    }
    c->packet_bytes = 0;
}

void *glmt_packet(struct glmt_context *c, uint16_t op, uint16_t size)
{
    struct glmt_cmd *cmd;

    if (!c->surface) return NULL; /* nothing to draw to */
    if (c->packet_bytes + size > GLMT_PACKET_BYTES) glmt_flush_packets(c);
    cmd = (struct glmt_cmd *)(c->packets + c->packet_bytes);
    memset(cmd, 0, size);
    cmd->op = op;
    cmd->size = size;
    c->packet_bytes += size;
    return cmd;
}

void *glmt_arena(struct glmt_context *c, uint32_t size, uint32_t align, uint32_t *offset)
{
    void *memory = c->be->arena_alloc(c->be, size, align, offset);

    if (memory) return memory;
    /* Full: the packets so far go out with the arena they point into, then a fresh one. */
    glmt_flush_packets(c);
    c->be->arena_next(c->be);
    c->arena_epoch++;
    glmt_draw_invalidate(c);
    return c->be->arena_alloc(c->be, size, align, offset);
}

/* ---- contexts and surfaces ---- */

glmt_context *glmt_context_create(glmt_context *share)
{
    struct glmt_context *c;

    if (!backend || !(c = calloc(1, sizeof(*c)))) return NULL;
    c->be = backend;
    if (share)
    {
        c->share = share->share;
        c->share->refs++;
    }
    else if (!(c->share = glmt_share_create()))
    {
        free(c);
        return NULL;
    }
    if (!(c->packets = malloc(GLMT_PACKET_BYTES)))
    {
        glmt_share_release(c->share, c->be);
        free(c);
        return NULL;
    }

    /* OpenGL's initial state */
    glmt_matrix_init(c);
    glmt_texture_init(c);
    glmt_draw_init(c);
    c->alpha_func = GL_ALWAYS;
    c->blend_src = GL_ONE;
    c->blend_dst = GL_ZERO;
    c->depth_func = GL_LESS;
    c->depth_mask = true;
    c->depth_far = 1.0;
    c->color_mask[0] = c->color_mask[1] = c->color_mask[2] = c->color_mask[3] = true;
    c->cull_mode = GL_BACK;
    c->front_face = GL_CCW;
    c->polygon_mode = GL_FILL;
    c->shade_model = GL_SMOOTH;
    c->stencil_func = GL_ALWAYS;
    c->stencil_sfail = c->stencil_zfail = c->stencil_zpass = GL_KEEP;
    c->stencil_value_mask = c->stencil_write_mask = 0xffffffffu;
    c->clear_depth = 1.0;
    c->draw_buffer = c->read_buffer = GL_BACK;
    c->line_width = c->point_size = 1.0f;
    c->unpack_alignment = c->pack_alignment = 4;
    c->stats.report_time = glmt_now();
    c->swap_interval = -1;
    GLMT_DEBUG("glmt: context %p created%s", (void *)c, share ? ", sharing textures" : "");
    return c;
}

void glmt_context_destroy(glmt_context *c)
{
    if (!c) return;
    GLMT_DEBUG("glmt: context %p destroyed after %llu frames", (void *)c, (unsigned long long)c->stats.frames);
    if (glmt_current == c) glmt_make_current(NULL, NULL);
    glmt_share_release(c->share, c->be);
    glmt_draw_destroy(c);
    free(c->attrib_stack);
    free(c->client_stack);
    free(c->packets);
    free(c);
}

glmt_surface *glmt_surface_create(void *layer, int width, int height, unsigned int pixel_format)
{
    struct glmt_surface *s;

    if (!backend || pixel_format >= glmt_pixel_format_count() || !(s = calloc(1, sizeof(*s)))) return NULL;
    s->format = pixel_formats[pixel_format];
    s->width = width;
    s->height = height;
    if (!(s->be_surface = backend->surface_create(backend, layer, width, height, s->format.depth_bits, s->format.stencil_bits)))
    {
        glmt_log("glmt: the %s backend made no surface of %dx%d", backend->name, width, height);
        free(s);
        return NULL;
    }
    GLMT_DEBUG("glmt: surface %p created: %dx%d, depth %d, stencil %d, %s", (void *)s, width, height,
               s->format.depth_bits, s->format.stencil_bits, layer ? "on a layer" : "no layer");
    return s;
}

void glmt_surface_destroy(glmt_surface *s)
{
    if (!s) return;
    if (glmt_current && glmt_current->surface == s)
    {
        glmt_flush_packets(glmt_current);
        glmt_current->surface = NULL;
    }
    backend->surface_destroy(backend, s->be_surface);
    free(s);
}

void glmt_surface_resize(glmt_surface *s, int width, int height)
{
    if (!s || (s->width == width && s->height == height)) return;
    if (glmt_current && glmt_current->surface == s) glmt_flush_packets(glmt_current);
    GLMT_DEBUG("glmt: surface %p resized from %dx%d to %dx%d", (void *)s, s->width, s->height, width, height);
    s->width = width;
    s->height = height;
    backend->surface_resize(backend, s->be_surface, width, height);
}

int glmt_make_current(glmt_context *c, glmt_surface *surface)
{
    struct glmt_context *previous = glmt_current;

    if (previous && (previous != c || previous->surface != surface)) glmt_flush_packets(previous);
    if (previous && previous != c) previous->surface = NULL;
    if (previous != c || (c && c->surface != surface))
        GLMT_DEBUG("glmt: context %p is current on surface %p", (void *)c, (void *)surface);
    glmt_current = c;
    if (!c) return 0;
    c->surface = surface;
    if (surface && !c->viewport_set)
    {
        /* The first time a context is made current, viewport and scissor take the window's size. */
        c->viewport[2] = c->scissor[2] = surface->width;
        c->viewport[3] = c->scissor[3] = surface->height;
        c->viewport_set = true;
    }
    return 0;
}

static int compare_floats(const void *a, const void *b);

/* GLMT_PROFILE: one clock read per entry point (about 20 ns each, so a tenth of a millisecond in a
 * frame of 6,000 calls). A gap is the time from one entry into glmt to the next within a frame,
 * so glmt's own work for the first call and everything outside glmt until the second:
 *   a short gap is the way out of glmt and back in (Wine's thunk to the 32-bit side and back,
 *   under FEX) with next to no code of the game's between, as between glEnableClientState and
 *   glTexCoordPointer; the shortest gaps are what one call costs to make;
 *   a long gap is the game computing between two calls: a surface's vertices and colors.
 * The time from a swap to the next frame's first call is no gap: that is the game before it
 * draws (its simulation, and its wait for the frame's time to be up), and the line gives it as
 * what is left of a frame beside its OpenGL part. */
void glmt_profile_call(struct glmt_context *c)
{
    struct glmt_stats *s = &c->stats;
    double now = glmt_now();

    if (s->first_call == 0.0) s->first_call = now;
    else
    {
        double gap = now - s->last_call;
        uint64_t step = gap > 0.0 ? (uint64_t)(gap * 1e9) / GLMT_GAP_STEP_NS : 0;

        s->gap[step < GLMT_GAP_STEPS - 1 ? step : GLMT_GAP_STEPS - 1]++;
        s->gap_count++;
        if (gap * 1e9 < GLMT_GAP_LONG_NS) s->gap_short_s += gap;
        else s->gap_long_s += gap;
    }
    s->last_call = now;
}

/* The gap under which `share` of the counted gaps lie, in nanoseconds (a step's lower edge). */
static unsigned gap_percentile(const struct glmt_stats *s, double share)
{
    uint64_t want = (uint64_t)((double)s->gap_count * share), seen = 0;

    for (unsigned i = 0; i < GLMT_GAP_STEPS; i++)
        if ((seen += s->gap[i]) > want) return i * GLMT_GAP_STEP_NS;
    return (GLMT_GAP_STEPS - 1) * GLMT_GAP_STEP_NS;
}

/* The profile's line: see glmt_profile_call. "slow" frames took 5 ms or more, which at 250 frames a
 * second is a frame that did not fit; their two numbers say whether the OpenGL part of the frame
 * (from its first call to its swap) or the rest of it (the game before it draws) was the long one. */
static void report_profile(struct glmt_stats *s, double frames)
{
    float sorted[GLMT_STATS_FRAMES], slow_frame[GLMT_STATS_FRAMES], slow_gl[GLMT_STATS_FRAMES];
    uint32_t n = s->frame_count, slow = 0;
    unsigned low = gap_percentile(s, 0.1);

    if (!n || !s->gap_count) return;
    for (uint32_t i = 0; i < n; i++)
    {
        sorted[i] = s->gl_ms[i];
        if (s->frame_ms[i] >= 5.0f)
        {
            slow_frame[slow] = s->frame_ms[i];
            slow_gl[slow++] = s->gl_ms[i];
        }
    }
    qsort(sorted, n, sizeof(float), compare_floats);
    qsort(slow_frame, slow, sizeof(float), compare_floats);
    qsort(slow_gl, slow, sizeof(float), compare_floats);
    glmt_log("glmt:   profile: a frame's OpenGL part (first call to swap) ms: median %.2f, 99%% %.2f, longest %.2f; "
             "slow frames (5 ms or more): %u, median %.2f ms, of it OpenGL part %.2f; "
             "between two calls ns: 10%% under %u, half under %u, 90%% under %u; per frame: %.2f ms in gaps under %d ns, "
             "%.2f ms in longer ones; %.0f calls at the 10%% gap: %.2f ms",
             sorted[n / 2], sorted[(uint32_t)((double)(n - 1) * 0.99)], sorted[n - 1], slow, slow ? slow_frame[slow / 2] : 0.0,
             slow ? slow_gl[slow / 2] : 0.0, low + GLMT_GAP_STEP_NS, gap_percentile(s, 0.5) + GLMT_GAP_STEP_NS,
             gap_percentile(s, 0.9) + GLMT_GAP_STEP_NS,
             s->gap_short_s * 1000.0 / frames, GLMT_GAP_LONG_NS, s->gap_long_s * 1000.0 / frames, (double)s->calls / frames,
             (double)s->calls / frames * (double)(low + GLMT_GAP_STEP_NS) * 1e-6);
}

static int compare_floats(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

static void report_stats(struct glmt_context *c)
{
    struct glmt_stats *s = &c->stats;
    double now = glmt_now(), seconds = now - s->report_time;
    double frames = (double)s->report_frames;

    /* (before the frame times are sorted below: it pairs them with their OpenGL parts) */
    if (glmt_profile) report_profile(s, frames);
    glmt_log("glmt: %.1f fps, per frame: %.0f GL calls, %.0f draws, %.0f vertices, %.0f indices, %.0f clears, "
             "%.0f KB arena, %.1f texture uploads",
             seconds > 0.0 ? frames / seconds : 0.0, (double)s->calls / frames, (double)s->draws / frames,
             (double)s->vertices / frames, (double)s->indices / frames, (double)s->clears / frames,
             (double)s->arena_bytes / frames / 1024.0, (double)s->texture_uploads / frames);
    if (s->frame_count)
    {
        /* The second line: how even the frames were. "over" counts frames that took more than one and
         * a half times the median, which is what a hitch looks like. The backend's worst times say
         * whether a hitch was glmt's (submit: encoding, a pipeline made on first use; present:
         * waiting for a drawable) or came from before it (the game, FEX, Wine). */
        uint32_t n = s->frame_count, over = 0;
        char note[160] = "";
        float median;

        if (c->be->frame_note && c->surface) c->be->frame_note(c->be, c->surface->be_surface, note, sizeof(note));

        qsort(s->frame_ms, n, sizeof(float), compare_floats);
        median = s->frame_ms[n / 2];
        for (uint32_t i = 0; i < n; i++) over += s->frame_ms[i] > median * 1.5f;
        glmt_log("glmt:   frame ms: median %.2f, 99%% %.2f, worst %.2f, %u of %u over 1.5x the median; "
                 "backend's worst: submit %.2f, present %.2f%s",
                 median, s->frame_ms[(uint32_t)((double)(n - 1) * 0.99)], s->frame_ms[n - 1], over, n, s->worst_submit_ms,
                 s->worst_present_ms, note);
    }
    s->frame_count = 0;
    memset(s->gap, 0, sizeof(s->gap));
    s->gap_count = 0;
    s->gap_short_s = s->gap_long_s = 0.0;
    s->worst_submit_ms = s->worst_present_ms = 0.0;
    s->calls = s->draws = s->vertices = s->indices = s->clears = s->arena_bytes = s->texture_uploads = 0;
    s->report_frames = 0;
    s->report_time = now;
}

int glmt_swap_buffers(glmt_surface *surface, int interval)
{
    struct glmt_context *c = glmt_current;

    if (!surface) return -1;
    if (c && c->surface == surface)
    {
        double start;

        glmt_flush_packets(c);
        start = stats_interval ? glmt_now() : 0.0;
        backend->present(backend, surface->be_surface, interval);
        if (stats_interval)
        {
            double now = glmt_now(), ms = (now - start) * 1000.0;

            if (ms > c->stats.worst_present_ms) c->stats.worst_present_ms = ms;
            if (c->stats.last_swap > 0.0 && c->stats.frame_count < GLMT_STATS_FRAMES)
            {
                /* (start: this swap, after the frame's last packets were submitted) */
                c->stats.gl_ms[c->stats.frame_count] = c->stats.first_call > 0.0 ? (float)((start - c->stats.first_call) * 1000.0) : 0.0f;
                c->stats.frame_ms[c->stats.frame_count++] = (float)((now - c->stats.last_swap) * 1000.0);
            }
            c->stats.first_call = 0.0;
            c->stats.last_swap = now;
        }
        /* The arena of the frame is gone with the frame. */
        c->arena_epoch++;
        glmt_draw_invalidate(c);
        c->stats.frames++;
        if (interval != c->swap_interval)
        {
            /* (the game's r_swapInterval arrives here, through wglSwapIntervalEXT) */
            GLMT_DEBUG("glmt: frame %llu is presented with swap interval %d (0: at once, no vsync)",
                       (unsigned long long)c->stats.frames, interval);
            c->swap_interval = interval;
        }
        if (trace_count)
        {
            /* frame N is what is drawn between swap N - 1 and swap N */
            uint64_t next = c->stats.frames + 1;
            bool on = traced(next);
            if (on != glmt_trace) glmt_log("glmt: %s of frame %llu", on ? "trace" : "end of the trace, at the swap", (unsigned long long)(on ? next : c->stats.frames));
            glmt_trace = on;
        }
        if (stats_interval > 0 && ++c->stats.report_frames >= (uint64_t)stats_interval)
        {
            report_stats(c);
            log_stub_calls();
        }
    }
    else backend->present(backend, surface->be_surface, interval);
    return 0;
}
