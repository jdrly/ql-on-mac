/* A picture that shows where the display tears, drawn through libglmt.dylib at the game's rate, in
 * a window that covers the screen, without Wine: to see and to measure how frames reach a display
 * before the game is played on it.
 *
 *     make -C glmt pace                        vsync, then tear at 250 and at 125, 15 s in all
 *     GLMT_PRESENT=mailbox build/pace 125 20   one mode: frames a second, seconds
 *     PACE_SYNC=1 build/pace                   with vsync (a swap interval of 1)
 *     PACE_HIDDEN=1 build/pace                 the window is made and never shown
 *     GLMT_FLIP_TRACE=/path build/pace         every flip as a line in that file
 *
 * The picture: white bars that move to the right at a steady speed, and a grey line at every tenth
 * of the height. A frame that is shown whole has straight bars. A tear is a step in the bars, and
 * the grey lines tell at what height it is. Escape ends it. Hard on the eyes: keep it short.
 *
 * It draws as Quake Live does: a frame every whole number of milliseconds (8 for 125, 4 for 250),
 * never waiting for the display. glmt's statistics go to the terminal, a set every second.
 *
 * On 2026-11-21 this window ran eleven times with schedules of timed presents. macOS kept none
 * of them, and that code is gone again. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

#include "gl.h"
#include "glmt.h"

#define GL(ret, name, params) static ret (*name) params
GL(void, glClearColor, (GLclampf, GLclampf, GLclampf, GLclampf));
GL(void, glClear, (GLbitfield));
GL(void, glBegin, (GLenum));
GL(void, glEnd, (void));
GL(void, glColor4f, (GLfloat, GLfloat, GLfloat, GLfloat));
GL(void, glVertex2f, (GLfloat, GLfloat));
GL(void, glViewport, (GLint, GLint, GLsizei, GLsizei));
GL(void, glDisable, (GLenum));
#undef GL

static void load(void)
{
#define LOAD(name) \
    if (!(name = glmt_get_proc_address(#name))) \
    { \
        fprintf(stderr, "pace: no %s\n", #name); \
        exit(1); \
    }
    LOAD(glClearColor) LOAD(glClear) LOAD(glBegin) LOAD(glEnd) LOAD(glColor4f) LOAD(glVertex2f) LOAD(glViewport)
    LOAD(glDisable)
#undef LOAD
}

static double seconds_now(void)
{
    static mach_timebase_info_data_t timebase;

    if (!timebase.denom) mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * timebase.numer / timebase.denom * 1e-9;
}

/* Sleeps to half a millisecond before t, then spins: the game's own limiter is as exact. */
static void sleep_until(double t)
{
    double now = seconds_now();

    if (t - now > 0.0007) usleep((useconds_t)((t - now - 0.0005) * 1e6));
    while (seconds_now() < t) {}
}

static void rect(float x0, float y0, float x1, float y1)
{
    glVertex2f(x0, y0);
    glVertex2f(x1, y0);
    glVertex2f(x1, y1);
    glVertex2f(x0, y1);
}

struct run
{
    void *layer;
    int width, height;
    int fps;
    double seconds;
    int interval;
};

static void *game(void *argument)
{
    struct run *run = argument;
    struct glmt_host host = {GLMT_ABI_VERSION, NULL};
    glmt_context *context;
    glmt_surface *surface;
    double frame = floor(1000.0 / run->fps) / 1000.0, start, next;
    /* the bars cross the screen in two seconds: 32 pixels a refresh on a 4K display at 60 Hz */
    const double speed = 1.0, spacing = 0.25, width = 0.02;

    if (glmt_init(&host) || (load(), 0) || !(context = glmt_context_create(NULL)) ||
        !(surface = glmt_surface_create(run->layer, run->width, run->height, 0)) || glmt_make_current(context, surface))
    {
        fprintf(stderr, "pace: no glmt context or surface\n");
        exit(1);
    }
    glViewport(0, 0, run->width, run->height);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);

    start = next = seconds_now();
    while (next - start < run->seconds)
    {
        /* the game's time is the time the frame was meant for, as in Quake */
        double shift = fmod((next - start) * speed, spacing);

        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glBegin(GL_QUADS);
        glColor4f(0.35f, 0.35f, 0.35f, 1);
        for (int i = 1; i < 10; i++) rect(-1, -1 + 0.2f * i - 0.002f, 1, -1 + 0.2f * i + 0.002f);
        glColor4f(1, 1, 1, 1);
        for (double x = -1.0 - spacing + shift; x < 1.0; x += spacing) rect((float)x, -1, (float)(x + width), 1);
        glEnd();
        glmt_swap_buffers(surface, run->interval);

        next += frame;
        /* a frame that took too long does not make the next ones hurry */
        if (seconds_now() > next) next = seconds_now();
        sleep_until(next);
    }
    glmt_make_current(NULL, NULL);
    glmt_context_destroy(context);
    glmt_surface_destroy(surface);
    exit(0);
}

/* A window without a frame takes no keys unless it says it does. */
@interface PaceWindow : NSWindow
@end

@implementation PaceWindow
- (BOOL)canBecomeKeyWindow
{
    return YES;
}
- (BOOL)canBecomeMainWindow
{
    return YES;
}
@end

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        static struct run run;
        NSApplication *app = [NSApplication sharedApplication];
        NSScreen *screen = NSScreen.mainScreen;
        NSRect frame = screen.frame;
        CGFloat scale = screen.backingScaleFactor;
        NSWindow *window;
        NSView *view;
        CAMetalLayer *layer = [CAMetalLayer layer];
        pthread_t thread;

        run.fps = argc > 1 ? atoi(argv[1]) : 250;
        run.seconds = argc > 2 ? atof(argv[2]) : 6.0;
        run.interval = getenv("PACE_SYNC") ? 1 : 0;
        if (run.fps < 1 || run.fps > 1000 || run.seconds <= 0.0)
        {
            fprintf(stderr, "usage: pace [frames a second] [seconds]\n");
            return 1;
        }
        if (!getenv("GLMT_STATS")) setenv("GLMT_STATS", run.interval ? "60" : argc > 1 ? argv[1] : "250", 1);

        /* PACE_HIDDEN: the window is made and never shown, for a run that only has to not hang */
        bool hidden = getenv("PACE_HIDDEN") != NULL;

        [app setActivationPolicy:hidden ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular];
        /* A window without a frame over the whole screen, above the menu bar, opaque, with nothing
         * but the Metal layer in it: what macOS can put on the display without compositing. */
        window = [[PaceWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.level = NSMainMenuWindowLevel + 1;
        window.opaque = YES;
        window.backgroundColor = NSColor.blackColor;
        window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
        view = [[NSView alloc] initWithFrame:frame];
        layer.opaque = YES;
        layer.contentsScale = scale;
        layer.frame = view.bounds;
        view.layer = layer;
        view.wantsLayer = YES;
        window.contentView = view;
        if (!hidden)
        {
            [window makeKeyAndOrderFront:nil];
            [app activateIgnoringOtherApps:YES];
            [NSCursor hide];
        }
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                              handler:^NSEvent *(NSEvent *event) {
                                                if (event.keyCode == 53) exit(0); /* Escape */
                                                return event;
                                              }];

        run.layer = (__bridge void *)layer;
        run.width = (int)(frame.size.width * scale);
        run.height = (int)(frame.size.height * scale);
        fprintf(stderr, "pace: %d frames a second for %.0f s, %dx%d, GLMT_PRESENT=%s%s\n", run.fps, run.seconds, run.width, run.height,
                getenv("GLMT_PRESENT") ? getenv("GLMT_PRESENT") : "tear", run.interval ? ", with vsync" : "");
        pthread_create(&thread, NULL, game, &run);
        /* whatever the drawing thread does, the screen is given back */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((run.seconds + 3.0) * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                         fprintf(stderr, "pace: the drawing thread did not end by itself\n");
                         _exit(1);
                       });
        [app run];
    }
    return 0;
}
