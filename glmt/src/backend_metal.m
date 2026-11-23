/* The Metal backend. macOS only, Objective-C with ARC.
 *
 * It executes the packets of backend.h. A draw packet names its whole state by small keys, and each
 * key is looked up in a table of Metal state objects that is filled on first use: render pipelines
 * (one vertex and one fragment function in four specializations, so making one compiles nothing
 * new), depth stencil states and samplers. The frame arena is a shared Metal buffer that the front
 * end wrote vertices, indices and uniforms into; a draw binds it at the packet's offsets.
 *
 * Coordinates: OpenGL's clip space and Metal's agree in x and y (y up), so nothing is mirrored and
 * a triangle's winding is the same in both. What differs is the framebuffer's origin (OpenGL bottom
 * left, Metal top left), so viewport, scissor and read-back rectangles are flipped here, and depth
 * (the vertex function maps -w..w to 0..w).
 *
 * Showing a frame: the game draws at its own rate (125 or 250 frames a second), the display takes 60
 * or 120. Every frame is drawn into a texture of the surface's own, never into a drawable of the
 * layer, so drawing never waits for the display. At the swap a frame is either copied into a
 * drawable and presented, or dropped (see present_frame for which). A layer has three drawables and
 * macOS returns them at the display's rate: presenting every frame at 250 a second made one frame
 * in six wait 10 ms for a drawable.
 *
 * Tried and taken out (2026-11-21): a thread of glmt's own that showed one frame for each refresh
 * with display sync off,
 * timed to flip at the refresh. macOS holds about a third of such presents back by 5 to 17 ms, in
 * the test window and in the game's, and no schedule of presents got round it.
 *
 * tools/smoke.m draws through this file natively and reads the pixels back: run `make smoke` after
 * a change. Everything here runs on the thread that makes the OpenGL calls, except the handler
 * that hears when a frame reached the display and the display link's callback. What those share
 * with the OpenGL thread is behind @synchronized(surface).
 *
 * Not done yet: the on-disk list of pipeline keys (pipelines are made on first use, a few
 * milliseconds each the first time a build runs). */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CVDisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CABase.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <pthread/qos.h>

#include <math.h>
#include <stdarg.h>
#include <stdio.h>

#include "backend.h"
#include "internal.h"
#include "shaders.inc"

#define ARENA_BYTES (32u * 1024 * 1024)
#define COLOR_FORMAT MTLPixelFormatBGRA8Unorm
#define DEPTH_FORMAT MTLPixelFormatDepth32Float_Stencil8
#define UNIFORM_VERTEX_INDEX 8 /* [[buffer(8)]] in the vertex functions */

/* What the render encoder has set, to set again only what a draw changes. */
struct bound_state
{
    bool valid;
    uint32_t pipeline, depth, stencil, stencil_ref, raster;
    float bias_factor, bias_units;
    int32_t viewport[4];
    float depth_range[2];
    MTLScissorRect scissor;
    uint32_t texture[GLMT_MAX_TEX_UNITS], sampler[GLMT_MAX_TEX_UNITS];
    uint32_t uniforms;
    uint32_t stream[4];
    __unsafe_unretained id<MTLBuffer> arena;
};

@interface GlmtSurface : NSObject
{
  @public
    struct bound_state bound;
}
@property(nonatomic, strong) CAMetalLayer *layer;
/* what every frame is drawn into; a surface with a layer shows copies of it */
@property(nonatomic, strong) id<MTLTexture> offscreen;
@property(nonatomic, strong) id<MTLTexture> depthStencil;
@property(nonatomic) int width, height;
/* the frame being drawn; nil between a present and the next packet */
@property(nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property(nonatomic, strong) id<MTLTexture> target; /* the frame's color texture */
@property(nonatomic, strong) id<MTLRenderCommandEncoder> encoder;
/* an earlier render pass of this frame drew to the target: a later one loads it */
@property(nonatomic) BOOL colorDrawn;
/* a clear that arrived before the render pass began: it becomes the pass's load action */
@property(nonatomic) uint32_t pendingClear;
@property(nonatomic) MTLClearColor clearColor;
@property(nonatomic) double clearDepth;
@property(nonatomic) uint32_t clearStencil;
@property(nonatomic) int displaySync; /* -1: not set yet */
/* showing frames (present_frame); times are CACurrentMediaTime's seconds */
@property(nonatomic) double refresh;      /* seconds between two refreshes of the display */
@property(nonatomic) double lastVblank;   /* when a frame of ours last reached the display, 0: not known */
@property(nonatomic) double targetVblank; /* the refresh the newest presented frame is for */
@property(nonatomic) double lastPresent;  /* when a frame was last presented */
@property(nonatomic) double lastSwap, frameTime; /* the last swap, and the smoothed time between swaps */
@property(nonatomic) int inFlight;        /* presented and not yet on the display */
@property(nonatomic) double margin;       /* mailbox: what is added to one refresh for the lead, learned */
@property(nonatomic) uint64_t shown, dropped, late;
@property(nonatomic, strong) id<MTLCommandQueue> asyncQueue; /* async: the queue the frames are committed to */
@end

#define FLIP_SAMPLES 512
@interface GlmtSurface ()
{
  @public
    /* Since the last statistics line: how long each presented frame took to the display, and at
     * which tenth of the refresh (counted from the display's own vsync time) it got there. */
    float flipDelay[FLIP_SAMPLES];
    float flipReport[FLIP_SAMPLES]; /* and how long after it the display's report came */
    uint32_t flipCount;
    uint32_t flipPhase[10];
    double phaseCos, phaseSin; /* the same as a mean: the sum of each flip's place on the refresh's circle */
    uint32_t phaseCount;

    /* GLMT_PRESENT=async (async_main): what the game's thread and the surface's presenter thread
     * share, all of it under asyncLock. Presented handlers never take asyncLock. */
    pthread_mutex_t asyncLock;
    pthread_cond_t asyncCond;
    BOOL asyncStarted;     /* the presenter thread exists */
    BOOL asyncStop;        /* the surface is gone: the thread ends */
    BOOL asyncIdle;        /* the game's thread shows the frames itself (it asked for vsync) */
    BOOL asyncBusy;        /* the presenter is between taking a drawable and presenting it */
    BOOL asyncPartial;     /* part of the frame being drawn is committed already: no copy now */
    uint64_t asyncSeq;     /* whole frames committed so far */
    double asyncSwapTime;  /* when the newest of them was swapped */
}
@end

@implementation GlmtSurface
- (instancetype)init
{
    if ((self = [super init]))
    {
        pthread_mutex_init(&asyncLock, NULL);
        pthread_cond_init(&asyncCond, NULL);
    }
    return self;
}
- (void)dealloc
{
    pthread_cond_destroy(&asyncCond);
    pthread_mutex_destroy(&asyncLock);
}
@end

@interface GlmtMetal : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLLibrary> library;
/* by specialization: bit 0 alpha test, bit 1 clip plane */
@property(nonatomic, strong) NSArray<id<MTLFunction>> *vertexFunctions, *fragmentFunctions;
@property(nonatomic, strong) id<MTLFunction> clearVertex, clearFragment;
/* state objects by key; NSNull for a key that failed, so it is reported once */
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *pipelines, *depthStates, *samplers, *clearPipelines,
    *clearDepthStates;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLTexture>> *textures;
@property(nonatomic) uint32_t nextTexture;
@property(nonatomic, strong) id<MTLTexture> whiteTexture; /* for a unit without a texture */
@property(nonatomic, strong) id<MTLBuffer> constants;     /* for a stream a draw does not have */
/* The arena being filled, and arenas no command buffer reads any more. */
@property(nonatomic, strong) id<MTLBuffer> arena;
@property(nonatomic) uint32_t arenaUsed;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *freeArenas;
/* Arenas the frame being drawn has used: they go back to freeArenas when its command buffer is done. */
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *frameArenas;
@end

@implementation GlmtMetal

- (id<MTLBuffer>)takeArena
{
    id<MTLBuffer> buffer = nil;
    @synchronized(self.freeArenas)
    {
        buffer = self.freeArenas.lastObject;
        if (buffer) [self.freeArenas removeLastObject];
    }
    if (!buffer) buffer = [self.device newBufferWithLength:ARENA_BYTES options:MTLResourceStorageModeShared];
    return buffer;
}

- (void)nextArena
{
    if (self.arena) [self.frameArenas addObject:self.arena];
    self.arena = [self takeArena];
    self.arenaUsed = 0;
}

@end

struct metal_backend
{
    struct glmt_backend base;
    void *impl; /* a retained GlmtMetal */
};

static GlmtMetal *impl_of(struct glmt_backend *be) { return (__bridge GlmtMetal *)((struct metal_backend *)be)->impl; }

static void metal_destroy(struct glmt_backend *be)
{
    struct metal_backend *mb = (struct metal_backend *)be;
    CFBridgingRelease(mb->impl);
    free(mb);
}

/* ---- state objects by key ---- */

static MTLBlendFactor blend_factor(uint32_t factor)
{
    switch (factor)
    {
    case GLMT_BLEND_ZERO: return MTLBlendFactorZero;
    case GLMT_BLEND_SRC_COLOR: return MTLBlendFactorSourceColor;
    case GLMT_BLEND_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
    case GLMT_BLEND_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
    case GLMT_BLEND_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
    case GLMT_BLEND_DST_ALPHA: return MTLBlendFactorDestinationAlpha;
    case GLMT_BLEND_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
    case GLMT_BLEND_DST_COLOR: return MTLBlendFactorDestinationColor;
    case GLMT_BLEND_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
    case GLMT_BLEND_SRC_ALPHA_SATURATE: return MTLBlendFactorSourceAlphaSaturated;
    default: return MTLBlendFactorOne;
    }
}

static MTLColorWriteMask write_mask(uint32_t mask)
{
    return (mask & 1 ? MTLColorWriteMaskRed : 0) | (mask & 2 ? MTLColorWriteMaskGreen : 0) |
           (mask & 4 ? MTLColorWriteMaskBlue : 0) | (mask & 8 ? MTLColorWriteMaskAlpha : 0);
}

/* The streams of backend.h as attributes 0 to 3 from buffers 0 to 3. A stream the draw does not
 * have reads one constant for every vertex (the shader does not use it). */
static MTLVertexDescriptor *vertex_descriptor(uint32_t key)
{
    static const MTLVertexFormat formats[] = {MTLVertexFormatFloat3, MTLVertexFormatUChar4Normalized,
                                              MTLVertexFormatFloat2, MTLVertexFormatFloat2};
    static const NSUInteger strides[] = {GLMT_POSITION_STRIDE, GLMT_COLOR_STRIDE, GLMT_TEXCOORD_STRIDE,
                                         GLMT_TEXCOORD_STRIDE};
    const bool present[] = {true, (key & GLMT_PIPE_HAS_COLOR) != 0, (key & GLMT_PIPE_HAS_TC0) != 0,
                            (key & GLMT_PIPE_HAS_TC1) != 0};
    MTLVertexDescriptor *descriptor = [MTLVertexDescriptor vertexDescriptor];

    for (NSUInteger i = 0; i < 4; i++)
    {
        descriptor.attributes[i].format = formats[i];
        descriptor.attributes[i].bufferIndex = i;
        descriptor.attributes[i].offset = 0;
        descriptor.layouts[i].stride = strides[i];
        descriptor.layouts[i].stepFunction = present[i] ? MTLVertexStepFunctionPerVertex : MTLVertexStepFunctionConstant;
        descriptor.layouts[i].stepRate = present[i] ? 1 : 0;
    }
    return descriptor;
}

static id<MTLRenderPipelineState> pipeline_for(GlmtMetal *m, uint32_t key)
{
    NSNumber *boxed = @(key);
    id state = m.pipelines[boxed];
    MTLRenderPipelineDescriptor *descriptor;
    MTLRenderPipelineColorAttachmentDescriptor *color;
    NSUInteger variant = (key & GLMT_PIPE_ALPHA_TEST ? 1 : 0) | (key & GLMT_PIPE_CLIP_PLANE ? 2 : 0);
    NSError *error = nil;

    if (state) return state == [NSNull null] ? nil : state;

    descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = m.vertexFunctions[variant];
    descriptor.fragmentFunction = m.fragmentFunctions[variant];
    descriptor.vertexDescriptor = vertex_descriptor(key);
    descriptor.depthAttachmentPixelFormat = DEPTH_FORMAT;
    descriptor.stencilAttachmentPixelFormat = DEPTH_FORMAT;
    color = descriptor.colorAttachments[0];
    color.pixelFormat = COLOR_FORMAT;
    color.writeMask = write_mask((key >> GLMT_PIPE_MASK_SHIFT) & 0xf);
    if (key & GLMT_PIPE_BLEND)
    {
        color.blendingEnabled = YES;
        color.sourceRGBBlendFactor = color.sourceAlphaBlendFactor = blend_factor((key >> GLMT_PIPE_SRC_SHIFT) & 0xf);
        color.destinationRGBBlendFactor = color.destinationAlphaBlendFactor = blend_factor((key >> GLMT_PIPE_DST_SHIFT) & 0xf);
    }
    state = [m.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!state) glmt_log("glmt: no pipeline for key 0x%x: %s", key, error.localizedDescription.UTF8String);
    else GLMT_DEBUG("glmt: pipeline 0x%x made (%lu so far)", key, (unsigned long)m.pipelines.count + 1);
    m.pipelines[boxed] = state ?: [NSNull null];
    return state;
}

/* The comparison functions and the stencil operations of backend.h are numbered as Metal's. */
static id<MTLDepthStencilState> depth_state_for(GlmtMetal *m, uint32_t depth, uint32_t stencil)
{
    NSNumber *boxed = @((uint64_t)stencil << 8 | depth);
    id<MTLDepthStencilState> state = m.depthStates[boxed];
    MTLDepthStencilDescriptor *descriptor;

    if (state) return state;
    descriptor = [MTLDepthStencilDescriptor new];
    descriptor.depthCompareFunction = depth & GLMT_DEPTH_TEST ? (MTLCompareFunction)((depth >> GLMT_DEPTH_FUNC_SHIFT) & 7)
                                                              : MTLCompareFunctionAlways;
    descriptor.depthWriteEnabled = (depth & GLMT_DEPTH_TEST) && (depth & GLMT_DEPTH_WRITE);
    if (stencil & GLMT_STENCIL_TEST)
    {
        MTLStencilDescriptor *face = [MTLStencilDescriptor new];
        face.stencilCompareFunction = (MTLCompareFunction)((stencil >> GLMT_STENCIL_FUNC_SHIFT) & 7);
        face.stencilFailureOperation = (MTLStencilOperation)((stencil >> GLMT_STENCIL_SFAIL_SHIFT) & 7);
        face.depthFailureOperation = (MTLStencilOperation)((stencil >> GLMT_STENCIL_ZFAIL_SHIFT) & 7);
        face.depthStencilPassOperation = (MTLStencilOperation)((stencil >> GLMT_STENCIL_ZPASS_SHIFT) & 7);
        face.readMask = (stencil >> GLMT_STENCIL_READ_MASK_SHIFT) & 0xff;
        face.writeMask = (stencil >> GLMT_STENCIL_WRITE_MASK_SHIFT) & 0xff;
        descriptor.frontFaceStencil = descriptor.backFaceStencil = face;
    }
    state = [m.device newDepthStencilStateWithDescriptor:descriptor];
    m.depthStates[boxed] = state;
    return state;
}

static MTLSamplerAddressMode address_mode(uint32_t wrap)
{
    return wrap == GLMT_WRAP_REPEAT ? MTLSamplerAddressModeRepeat
           : wrap == GLMT_WRAP_MIRROR ? MTLSamplerAddressModeMirrorRepeat
                                      : MTLSamplerAddressModeClampToEdge;
}

static id<MTLSamplerState> sampler_for(GlmtMetal *m, uint32_t key)
{
    NSNumber *boxed = @(key);
    id<MTLSamplerState> state = m.samplers[boxed];
    MTLSamplerDescriptor *descriptor;
    NSUInteger anisotropy = (key >> GLMT_SAMPLER_ANISO_SHIFT) & 0x1f;

    if (state) return state;
    descriptor = [MTLSamplerDescriptor new];
    descriptor.minFilter = key & GLMT_SAMPLER_MIN_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    descriptor.magFilter = key & GLMT_SAMPLER_MAG_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    descriptor.mipFilter = key & GLMT_SAMPLER_MIP_LINEAR ? MTLSamplerMipFilterLinear
                           : key & GLMT_SAMPLER_MIP_NEAREST ? MTLSamplerMipFilterNearest
                                                            : MTLSamplerMipFilterNotMipmapped;
    descriptor.sAddressMode = address_mode((key >> GLMT_SAMPLER_WRAP_S_SHIFT) & 3);
    descriptor.tAddressMode = address_mode((key >> GLMT_SAMPLER_WRAP_T_SHIFT) & 3);
    descriptor.maxAnisotropy = anisotropy < 1 ? 1 : anisotropy > 16 ? 16 : anisotropy;
    state = [m.device newSamplerStateWithDescriptor:descriptor];
    m.samplers[boxed] = state;
    return state;
}

/* ---- GLMT_FLIP_TRACE=file: every flip, swap and display link callback as a line, for reading
 * afterwards what macOS did with each present. Times are CACurrentMediaTime's seconds.
 *   L now vsync period               the display link fired
 *   S time interval mode             the game swapped
 *   W time ms                        the swap at `time` asked for a drawable, and nextDrawable took
 *                                    that many milliseconds of the game's thread
 *   N time ms                        async: the presenter thread asked for a drawable at `time`
 *                                    and nextDrawable took that many milliseconds of its own
 *   F kind presented flipped reported target drawable returned
 *                                    a frame's report: kind s (with display sync) or t (without);
 *                                    which of the layer's drawables it was (target and returned
 *                                    are 0: they were the timed experiments')
 */
static FILE *trace_file;
static os_unfair_lock trace_lock = OS_UNFAIR_LOCK_INIT;

static void trace_line(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void trace_line(const char *format, ...)
{
    static int opened;
    va_list args;

    os_unfair_lock_lock(&trace_lock);
    if (!opened)
    {
        const char *path = getenv("GLMT_FLIP_TRACE");

        opened = 1;
        if (path && *path && (trace_file = fopen(path, "w"))) setvbuf(trace_file, NULL, _IOFBF, 1 << 20);
    }
    if (trace_file)
    {
        va_start(args, format);
        vfprintf(trace_file, format, args);
        va_end(args);
    }
    os_unfair_lock_unlock(&trace_lock);
}

static void trace_flush(void)
{
    os_unfair_lock_lock(&trace_lock);
    if (trace_file) fflush(trace_file);
    os_unfair_lock_unlock(&trace_lock);
}

/* ---- the display's vsync times ----
 * A display link calls back once per refresh with the time of a vsync and the measured period. It
 * only tells the time here: nothing is presented from it. One for the process, on the main
 * display. (CVDisplayLink is deprecated in favour of links that need a view or a run loop; it has
 * a thread of its own, which is what a library inside Wine can use.) */
static struct
{
    os_unfair_lock lock;
    double vsync;  /* a vsync, in CACurrentMediaTime's seconds; 0: none yet */
    double period; /* seconds between two, as measured */
} display_clock = {OS_UNFAIR_LOCK_INIT, 0.0, 0.0};

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CVReturn display_link_fired(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output,
                                   CVOptionFlags flags_in, CVOptionFlags *flags_out, void *context)
{
    static mach_timebase_info_data_t timebase;
    double period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link);

    if (!timebase.denom) mach_timebase_info(&timebase);
    trace_line("L %.6f %.6f %.6f\n", (double)now->hostTime * timebase.numer / timebase.denom * 1e-9,
               (double)output->hostTime * timebase.numer / timebase.denom * 1e-9, period);
    os_unfair_lock_lock(&display_clock.lock);
    /* the host time of the refresh this callback is for */
    display_clock.vsync = (double)output->hostTime * timebase.numer / timebase.denom * 1e-9;
    if (period > 0.001 && period < 0.1) display_clock.period = period;
    os_unfair_lock_unlock(&display_clock.lock);
    return kCVReturnSuccess;
}

static void start_display_clock(void)
{
    static bool started;
    CVDisplayLinkRef link = NULL;

    if (started) return;
    started = true;
    if (CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link) != kCVReturnSuccess || !link ||
        CVDisplayLinkSetOutputCallback(link, display_link_fired, NULL) != kCVReturnSuccess ||
        CVDisplayLinkStart(link) != kCVReturnSuccess)
        glmt_log("glmt: no display link: the display's vsync times are not known");
#pragma clang diagnostic pop
}

/* A vsync and the period, false if the display link has not reported yet. */
static bool display_vsync(double *vsync, double *period)
{
    os_unfair_lock_lock(&display_clock.lock);
    *vsync = display_clock.vsync;
    *period = display_clock.period;
    os_unfair_lock_unlock(&display_clock.lock);
    return *vsync > 0.0 && *period > 0.0;
}

/* ---- surfaces ---- */


/* Seconds between two refreshes of the main display; 1/60 where macOS does not say. */
static double display_refresh(void)
{
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
    double rate = mode ? CGDisplayModeGetRefreshRate(mode) : 0.0;

    if (mode) CGDisplayModeRelease(mode);
    return rate >= 24.0 && rate <= 500.0 ? 1.0 / rate : 1.0 / 60.0;
}

static void make_targets(GlmtMetal *m, GlmtSurface *s)
{
    MTLTextureDescriptor *descriptor;

    s.depthStencil = nil;
    s.offscreen = nil;
    if (s.width <= 0 || s.height <= 0) return;
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:DEPTH_FORMAT
                                                                    width:(NSUInteger)s.width
                                                                   height:(NSUInteger)s.height
                                                                mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModePrivate;
    s.depthStencil = [m.device newTextureWithDescriptor:descriptor];
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:COLOR_FORMAT
                                                                    width:(NSUInteger)s.width
                                                                   height:(NSUInteger)s.height
                                                                mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    s.offscreen = [m.device newTextureWithDescriptor:descriptor];
}

static void *metal_surface_create(struct glmt_backend *be, void *layer, int width, int height, int depth_bits,
                                  int stencil_bits)
{
    GlmtMetal *m = impl_of(be);
    GlmtSurface *s = [GlmtSurface new];

    s.layer = (__bridge CAMetalLayer *)layer;
    s.width = width;
    s.height = height;
    s.displaySync = -1;
    if (s.layer)
    {
        s.layer.device = m.device;
        s.layer.pixelFormat = COLOR_FORMAT;
        /* Wine's layer is made framebuffer-only; a frame is copied into its drawable. */
        s.layer.framebufferOnly = NO;
        s.layer.drawableSize = CGSizeMake(width, height);
        s.refresh = display_refresh();
        start_display_clock();
    }
    make_targets(m, s);
    return (void *)CFBridgingRetain(s);
}

static void async_pause(GlmtSurface *s);

/* Ends what the surface's frame has so far without showing it. */
static void abandon_frame(GlmtSurface *s)
{
    [s.encoder endEncoding];
    s.encoder = nil;
    /* (async: what is in the surface's texture now is not a whole frame) */
    pthread_mutex_lock(&s->asyncLock);
    if (s.commandBuffer) s->asyncPartial = YES;
    [s.commandBuffer commit];
    pthread_mutex_unlock(&s->asyncLock);
    s.commandBuffer = nil;
    s.target = nil;
    s.colorDrawn = NO;
    s->bound.valid = false;
}

static void metal_surface_destroy(struct glmt_backend *be, void *surface)
{
    GlmtSurface *s = CFBridgingRelease(surface);
    abandon_frame(s);
    /* The layer outlives the surface and may go to the next one: the presenter thread is seen
     * out of it first (async_pause: as long as its nextDrawable takes, a second at most). Then it
     * ends by itself, with the reference of its own; nobody waits for that. */
    async_pause(s);
    pthread_mutex_lock(&s->asyncLock);
    s->asyncStop = YES;
    pthread_cond_broadcast(&s->asyncCond);
    pthread_mutex_unlock(&s->asyncLock);
}

static void metal_surface_resize(struct glmt_backend *be, void *surface, int width, int height)
{
    GlmtMetal *m = impl_of(be);
    GlmtSurface *s = (__bridge GlmtSurface *)surface;

    /* what was drawn at the old size has nowhere to go */
    abandon_frame(s);
    async_pause(s);
    pthread_mutex_lock(&s->asyncLock);
    @synchronized(s)
    {
        s.width = width;
        s.height = height;
        if (s.layer) s.layer.drawableSize = CGSizeMake(width, height);
        make_targets(m, s);
    }
    pthread_mutex_unlock(&s->asyncLock);
}

/* ---- textures ---- */

static uint32_t metal_texture_create(struct glmt_backend *be, int width, int height, int levels)
{
    GlmtMetal *m = impl_of(be);
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:(NSUInteger)width
                                                          height:(NSUInteger)height
                                                       mipmapped:NO];
    id<MTLTexture> texture;

    descriptor.mipmapLevelCount = (NSUInteger)levels;
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    if (!(texture = [m.device newTextureWithDescriptor:descriptor])) return 0;
    m.nextTexture = m.nextTexture + 1;
    m.textures[@(m.nextTexture)] = texture;
    return m.nextTexture;
}

static void metal_texture_upload(struct glmt_backend *be, uint32_t texture, int level, int x, int y, int width,
                                 int height, const uint8_t *rgba)
{
    id<MTLTexture> t = impl_of(be).textures[@(texture)];

    /* OpenGL's first row is t = 0 and so is Metal's: the rows go in as they are. */
    [t replaceRegion:MTLRegionMake2D((NSUInteger)x, (NSUInteger)y, (NSUInteger)width, (NSUInteger)height)
         mipmapLevel:(NSUInteger)level
           withBytes:rgba
         bytesPerRow:(NSUInteger)width * 4];
}

static void metal_texture_destroy(struct glmt_backend *be, uint32_t texture)
{
    /* A command buffer that uses the texture keeps it alive until it is done. */
    [impl_of(be).textures removeObjectForKey:@(texture)];
}

/* ---- arena ---- */

static void *metal_arena_alloc(struct glmt_backend *be, uint32_t size, uint32_t align, uint32_t *offset)
{
    GlmtMetal *m = impl_of(be);
    uint32_t start = (m.arenaUsed + align - 1) & ~(align - 1);

    if (start > ARENA_BYTES || size > ARENA_BYTES - start) return NULL;
    m.arenaUsed = start + size;
    *offset = start;
    return (uint8_t *)m.arena.contents + start;
}

static void metal_arena_next(struct glmt_backend *be) { [impl_of(be) nextArena]; }

/* ---- frame ---- */

static id<MTLCommandBuffer> frame_command_buffer(GlmtMetal *m, GlmtSurface *s)
{
    if (!s.commandBuffer) s.commandBuffer = [m.queue commandBuffer];
    return s.commandBuffer;
}

/* The frame's color texture: the surface's own. nil if there is none. */
static id<MTLTexture> frame_target(GlmtSurface *s)
{
    return s.target = s.offscreen;
}

/* The render pass of the surface's frame, begun if there is none. nil if there is nothing to draw
 * to. */
static id<MTLRenderCommandEncoder> frame_encoder(GlmtMetal *m, GlmtSurface *s)
{
    MTLRenderPassDescriptor *pass;

    if (s.encoder) return s.encoder;
    if (!frame_target(s) || !s.depthStencil) return nil;

    pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = s.target;
    /* A frame's color starts as what glClear said or, without one, as black: OpenGL leaves the
     * back buffer undefined after a swap, and a clear costs this GPU nothing where loading the
     * drawable's old contents would. */
    pass.colorAttachments[0].loadAction = s.colorDrawn && !(s.pendingClear & GLMT_CLEAR_COLOR) ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = s.pendingClear & GLMT_CLEAR_COLOR ? s.clearColor : MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    /* Depth and stencil keep their contents from frame to frame, as OpenGL's do. */
    pass.depthAttachment.texture = s.depthStencil;
    pass.depthAttachment.loadAction = (s.pendingClear & GLMT_CLEAR_DEPTH) ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.depthAttachment.clearDepth = s.clearDepth;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.texture = s.depthStencil;
    pass.stencilAttachment.loadAction = (s.pendingClear & GLMT_CLEAR_STENCIL) ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.stencilAttachment.clearStencil = s.clearStencil;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    s.pendingClear = 0;
    s.colorDrawn = YES;
    s->bound.valid = false;
    s.encoder = [frame_command_buffer(m, s) renderCommandEncoderWithDescriptor:pass];
    return s.encoder;
}

/* An OpenGL rectangle (origin bottom left) as a Metal scissor rectangle inside the surface. False if
 * nothing of it is inside. */
static bool flipped_rect(GlmtSurface *s, const int32_t r[4], MTLScissorRect *out)
{
    long x0 = r[0], y0 = (long)s.height - ((long)r[1] + r[3]), x1 = (long)r[0] + r[2], y1 = (long)s.height - r[1];

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > s.width) x1 = s.width;
    if (y1 > s.height) y1 = s.height;
    if (x1 <= x0 || y1 <= y0) return false;
    *out = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
    return true;
}

/* ---- clear ---- */

/* mirrors ClearUniforms in shaders.metal */
struct clear_uniforms
{
    float color[4];
    float depth;
    float pad[3];
};

/* glClear in the middle of a render pass, or of a part of the surface: a triangle over everything,
 * limited by the scissor rectangle, that writes what the clear names. Ending the pass to clear
 * would make the GPU store and reload every tile. */
static void draw_clear(GlmtMetal *m, GlmtSurface *s, const struct glmt_cmd_clear *clear)
{
    id<MTLRenderCommandEncoder> e = frame_encoder(m, s);
    uint32_t color_mask = clear->mask & GLMT_CLEAR_COLOR ? clear->color_mask : 0;
    bool depth = clear->mask & GLMT_CLEAR_DEPTH, stencil = clear->mask & GLMT_CLEAR_STENCIL;
    NSNumber *pipeline_key = @(color_mask), *depth_key = @((depth ? 1u : 0) | (stencil ? 2u | clear->stencil_mask << 8 : 0));
    id<MTLRenderPipelineState> pipeline = m.clearPipelines[pipeline_key];
    id<MTLDepthStencilState> depth_state = m.clearDepthStates[depth_key];
    const int32_t whole[4] = {0, 0, s.width, s.height};
    struct clear_uniforms uniforms = {.depth = clear->depth};
    MTLScissorRect rect;

    if (!e || !flipped_rect(s, clear->scissor_on ? clear->scissor : whole, &rect)) return;
    if (!pipeline)
    {
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        NSError *error = nil;

        descriptor.vertexFunction = m.clearVertex;
        descriptor.fragmentFunction = m.clearFragment;
        descriptor.colorAttachments[0].pixelFormat = COLOR_FORMAT;
        descriptor.colorAttachments[0].writeMask = write_mask(color_mask);
        descriptor.depthAttachmentPixelFormat = DEPTH_FORMAT;
        descriptor.stencilAttachmentPixelFormat = DEPTH_FORMAT;
        if (!(pipeline = [m.device newRenderPipelineStateWithDescriptor:descriptor error:&error]))
        {
            GLMT_LOG_ONCE("glmt: no pipeline for a clear: %s", error.localizedDescription.UTF8String);
            return;
        }
        m.clearPipelines[pipeline_key] = pipeline;
    }
    if (!depth_state)
    {
        MTLDepthStencilDescriptor *descriptor = [MTLDepthStencilDescriptor new];

        descriptor.depthCompareFunction = MTLCompareFunctionAlways;
        descriptor.depthWriteEnabled = depth;
        if (stencil)
        {
            MTLStencilDescriptor *face = [MTLStencilDescriptor new];
            face.stencilCompareFunction = MTLCompareFunctionAlways;
            face.depthStencilPassOperation = MTLStencilOperationReplace;
            face.writeMask = clear->stencil_mask;
            descriptor.frontFaceStencil = descriptor.backFaceStencil = face;
        }
        depth_state = [m.device newDepthStencilStateWithDescriptor:descriptor];
        m.clearDepthStates[depth_key] = depth_state;
    }

    memcpy(uniforms.color, clear->color, sizeof(uniforms.color));
    [e setRenderPipelineState:pipeline];
    [e setDepthStencilState:depth_state];
    [e setStencilReferenceValue:clear->stencil];
    [e setCullMode:MTLCullModeNone];
    [e setTriangleFillMode:MTLTriangleFillModeFill];
    [e setDepthBias:0 slopeScale:0 clamp:0];
    [e setViewport:(MTLViewport){0, 0, s.width, s.height, 0, 1}];
    [e setScissorRect:rect];
    [e setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:UNIFORM_VERTEX_INDEX];
    [e setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    s->bound.valid = false;
}

static void encode_clear(GlmtMetal *m, GlmtSurface *s, const struct glmt_cmd_clear *clear)
{
    bool whole = !clear->scissor_on && (!(clear->mask & GLMT_CLEAR_COLOR) || clear->color_mask == 0xf) &&
                 (!(clear->mask & GLMT_CLEAR_STENCIL) || clear->stencil_mask == 0xff);

    if (s.encoder || !whole)
    {
        draw_clear(m, s, clear);
        return;
    }
    /* Before the pass began: the load action clears. */
    s.pendingClear |= clear->mask;
    if (clear->mask & GLMT_CLEAR_COLOR)
        s.clearColor = MTLClearColorMake(clear->color[0], clear->color[1], clear->color[2], clear->color[3]);
    if (clear->mask & GLMT_CLEAR_DEPTH) s.clearDepth = clear->depth;
    if (clear->mask & GLMT_CLEAR_STENCIL) s.clearStencil = clear->stencil;
}

/* ---- draw ---- */

static void encode_draw(GlmtMetal *m, GlmtSurface *s, const struct glmt_cmd_draw *d)
{
    static const MTLPrimitiveType primitives[] = {MTLPrimitiveTypeTriangle, MTLPrimitiveTypeTriangleStrip,
                                                  MTLPrimitiveTypeLine, MTLPrimitiveTypeLineStrip, MTLPrimitiveTypePoint};
    const int32_t whole[4] = {0, 0, s.width, s.height};
    const uint32_t streams[4] = {d->position, d->color, d->texcoord[0], d->texcoord[1]};
    bool triangles = d->primitive == GLMT_PRIM_TRIANGLES || d->primitive == GLMT_PRIM_TRIANGLE_STRIP;
    struct bound_state *b = &s->bound;
    id<MTLRenderCommandEncoder> e;
    id<MTLRenderPipelineState> pipeline;
    id<MTLBuffer> arena = m.arena;
    MTLScissorRect rect;
    bool all;

    if (d->primitive > GLMT_PRIM_POINTS || !d->vertex_count) return;
    /* both faces culled: no polygon is drawn (lines and points still are) */
    if (triangles && (d->raster & GLMT_RASTER_CULL_FRONT) && (d->raster & GLMT_RASTER_CULL_BACK)) return;
    if (!flipped_rect(s, d->raster & GLMT_RASTER_SCISSOR ? d->scissor : whole, &rect)) return;
    if (!(pipeline = pipeline_for(m, d->pipeline)) || !(e = frame_encoder(m, s))) return;
    all = !b->valid;

    if (all || b->pipeline != d->pipeline)
    {
        [e setRenderPipelineState:pipeline];
        b->pipeline = d->pipeline;
    }
    if (all || b->depth != d->depth || b->stencil != d->stencil)
    {
        [e setDepthStencilState:depth_state_for(m, d->depth, d->stencil)];
        b->depth = d->depth;
        b->stencil = d->stencil;
    }
    if (all || b->stencil_ref != d->stencil_ref)
    {
        [e setStencilReferenceValue:d->stencil_ref];
        b->stencil_ref = d->stencil_ref;
    }
    if (all || b->raster != d->raster || b->bias_factor != d->depth_bias_factor || b->bias_units != d->depth_bias_units)
    {
        [e setCullMode:d->raster & GLMT_RASTER_CULL_BACK ? MTLCullModeBack
                       : d->raster & GLMT_RASTER_CULL_FRONT ? MTLCullModeFront
                                                            : MTLCullModeNone];
        [e setFrontFacingWinding:d->raster & GLMT_RASTER_FRONT_CW ? MTLWindingClockwise : MTLWindingCounterClockwise];
        [e setTriangleFillMode:d->raster & GLMT_RASTER_LINES ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
        if (d->raster & GLMT_RASTER_DEPTH_BIAS) [e setDepthBias:d->depth_bias_units slopeScale:d->depth_bias_factor clamp:0];
        else [e setDepthBias:0 slopeScale:0 clamp:0];
        b->raster = d->raster;
        b->bias_factor = d->depth_bias_factor;
        b->bias_units = d->depth_bias_units;
    }
    if (all || memcmp(b->viewport, d->viewport, sizeof(b->viewport)) || memcmp(b->depth_range, d->depth_range, sizeof(b->depth_range)))
    {
        [e setViewport:(MTLViewport){d->viewport[0], (double)s.height - ((double)d->viewport[1] + d->viewport[3]),
                                     d->viewport[2], d->viewport[3], d->depth_range[0], d->depth_range[1]}];
        memcpy(b->viewport, d->viewport, sizeof(b->viewport));
        memcpy(b->depth_range, d->depth_range, sizeof(b->depth_range));
    }
    if (all || memcmp(&b->scissor, &rect, sizeof(rect)))
    {
        [e setScissorRect:rect];
        b->scissor = rect;
    }
    for (NSUInteger unit = 0; unit < GLMT_MAX_TEX_UNITS; unit++)
    {
        if (all || b->texture[unit] != d->texture[unit])
        {
            id<MTLTexture> texture = d->texture[unit] ? m.textures[@(d->texture[unit])] : nil;
            [e setFragmentTexture:texture ?: m.whiteTexture atIndex:unit];
            b->texture[unit] = d->texture[unit];
        }
        if (all || b->sampler[unit] != d->sampler[unit])
        {
            [e setFragmentSamplerState:sampler_for(m, d->sampler[unit]) atIndex:unit];
            b->sampler[unit] = d->sampler[unit];
        }
    }
    /* The arena: a buffer other than the one bound is bound whole; the same one only moves. */
    if (all || b->arena != arena)
    {
        [e setVertexBuffer:arena offset:d->uniforms atIndex:UNIFORM_VERTEX_INDEX];
        [e setFragmentBuffer:arena offset:d->uniforms atIndex:0];
        b->uniforms = d->uniforms;
        for (NSUInteger i = 0; i < 4; i++)
        {
            if (streams[i] == GLMT_NO_OFFSET) [e setVertexBuffer:m.constants offset:0 atIndex:i];
            else [e setVertexBuffer:arena offset:streams[i] atIndex:i];
            b->stream[i] = streams[i];
        }
        b->arena = arena;
    }
    else
    {
        if (b->uniforms != d->uniforms)
        {
            [e setVertexBufferOffset:d->uniforms atIndex:UNIFORM_VERTEX_INDEX];
            [e setFragmentBufferOffset:d->uniforms atIndex:0];
            b->uniforms = d->uniforms;
        }
        for (NSUInteger i = 0; i < 4; i++)
        {
            if (b->stream[i] == streams[i]) continue;
            if (streams[i] == GLMT_NO_OFFSET) [e setVertexBuffer:m.constants offset:0 atIndex:i];
            else if (b->stream[i] == GLMT_NO_OFFSET) [e setVertexBuffer:arena offset:streams[i] atIndex:i];
            else [e setVertexBufferOffset:streams[i] atIndex:i];
            b->stream[i] = streams[i];
        }
    }
    b->valid = true;

    if (d->index_offset != GLMT_NO_OFFSET)
        [e drawIndexedPrimitives:primitives[d->primitive]
                      indexCount:d->index_count
                       indexType:MTLIndexTypeUInt32
                     indexBuffer:arena
               indexBufferOffset:d->index_offset
                   instanceCount:1
                      baseVertex:d->base_vertex
                    baseInstance:0];
    else [e drawPrimitives:primitives[d->primitive] vertexStart:0 vertexCount:d->vertex_count];
}

static void metal_submit(struct glmt_backend *be, void *surface, const void *packets, uint32_t bytes)
{
    GlmtMetal *m = impl_of(be);
    GlmtSurface *s = (__bridge GlmtSurface *)surface;
    const uint8_t *p = packets, *end = p + bytes;

    @autoreleasepool
    {
        while (p < end)
        {
            const struct glmt_cmd *cmd = (const struct glmt_cmd *)p;
            switch (cmd->op)
            {
            case GLMT_CMD_CLEAR: encode_clear(m, s, (const struct glmt_cmd_clear *)cmd); break;
            case GLMT_CMD_DRAW: encode_draw(m, s, (const struct glmt_cmd_draw *)cmd); break;
            default: break;
            }
            p += cmd->size;
        }
    }
}

/* glReadPixels (screenshots): what the frame has drawn so far goes to the GPU now, the rectangle is
 * copied into a buffer, and this thread waits for it. The frame then goes on in a new command
 * buffer and a new render pass, on the same texture. */
static void metal_read_pixels(struct glmt_backend *be, void *surface, int x, int y, int width, int height,
                              uint8_t *rgba)
{
    GlmtMetal *m = impl_of(be);
    GlmtSurface *s = (__bridge GlmtSurface *)surface;
    const int32_t wanted[4] = {x, y, width, height};
    MTLScissorRect rect;

    memset(rgba, 0, (size_t)width * height * 4);
    @autoreleasepool
    {
        id<MTLBlitCommandEncoder> blit;
        id<MTLBuffer> buffer;
        const uint8_t *bgra;

        /* a clear nothing was drawn after still has to be in the picture */
        if (!s.encoder && s.pendingClear) frame_encoder(m, s);
        if (!frame_target(s) || !flipped_rect(s, wanted, &rect)) return;
        [s.encoder endEncoding];
        s.encoder = nil;
        if (!(buffer = [m.device newBufferWithLength:rect.width * rect.height * 4 options:MTLResourceStorageModeShared])) return;

        blit = [frame_command_buffer(m, s) blitCommandEncoder];
        [blit copyFromTexture:s.target
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(rect.x, rect.y, 0)
                          sourceSize:MTLSizeMake(rect.width, rect.height, 1)
                            toBuffer:buffer
                   destinationOffset:0
              destinationBytesPerRow:rect.width * 4
            destinationBytesPerImage:rect.width * rect.height * 4];
        [blit endEncoding];
        /* (async: the frame goes on after this; no copy of it until its swap) */
        pthread_mutex_lock(&s->asyncLock);
        s->asyncPartial = YES;
        [s.commandBuffer commit];
        pthread_mutex_unlock(&s->asyncLock);
        [s.commandBuffer waitUntilCompleted];
        s.commandBuffer = nil;

        /* The buffer holds the part of the rectangle that is inside the surface, top row first, as
         * blue, green, red, alpha. */
        bgra = buffer.contents;
        for (NSUInteger row = 0; row < rect.height; row++)
        {
            /* the surface row of this buffer row, counted from the bottom, and its place in the result */
            long gl_y = (long)s.height - 1 - (long)(rect.y + row);
            uint8_t *out = rgba + ((size_t)(gl_y - y) * width + (size_t)((long)rect.x - x)) * 4;
            const uint8_t *in = bgra + row * rect.width * 4;

            for (NSUInteger i = 0; i < rect.width; i++, in += 4, out += 4)
            {
                out[0] = in[2];
                out[1] = in[1];
                out[2] = in[0];
                out[3] = in[3];
            }
        }
    }
}

/* How frames are shown when the game asks for no vsync (GLMT_PRESENT):
 *   tear     (default) every frame at once, as long as a drawable is free; a frame that finds
 *            none is dropped. The lowest latency there is, even frame times, and tearing.
 *   mailbox  one frame for each refresh of the display, the others dropped, display sync on. No
 *            tearing, and the game is not held back, but macOS shows a synced frame more than a
 *            refresh after it was presented. An experiment: twice it made the picture judder.
 *   wait     every frame at once, waiting for a drawable if none is free (what glmt did first:
 *            at 250 frames a second one frame in six waited 10 ms)
 *   async    as tear, but a thread of the surface's own takes the drawable and presents
 *            (async_main, below): the game's swap never waits for the display. Measured with
 *            tear on 2026-11-22: nextDrawable holds the game's thread for 4 to 8 ms about every
 *            two seconds, and for 10 to 20 ms many times a second while something else on the
 *            desktop disturbs the display.
 * A game that asks for vsync (a swap interval of 1 or more) gets it: every frame, in step with the
 * display, which holds the game at the display's rate. */
enum present_mode { PRESENT_MAILBOX, PRESENT_TEAR, PRESENT_WAIT, PRESENT_ASYNC };

static enum present_mode present_mode(void)
{
    static int mode = -1;

    if (mode < 0)
    {
        const char *value = getenv("GLMT_PRESENT");

        mode = value && !strcmp(value, "mailbox") ? PRESENT_MAILBOX
               : value && !strcmp(value, "wait")  ? PRESENT_WAIT
               : value && !strcmp(value, "async") ? PRESENT_ASYNC
                                                  : PRESENT_TEAR;
        if (mode != PRESENT_TEAR) glmt_log("glmt: GLMT_PRESENT=%s", value);
    }
    return (enum present_mode)mode;
}

/* Mailbox: how long before a refresh a frame has to be presented to be on the display at that
 * refresh. Measured on the M5 Max's 60 Hz display (2026-11-21): with display sync on, no frame was
 * on the display sooner than one refresh after it was presented (16.6 to 17.9 ms). So the lead is
 * one refresh plus a margin, and only the margin is learned: a frame that arrives a refresh after
 * the one aimed at adds half a millisecond, every frame on time takes a little off.
 * Three things were wrong before: a lead of 4 ms, a lead limited to 14 ms, and a lead taken from
 * the measured time itself, which is the lead it was presented with and so only ever grew.
 * GLMT_PRESENT_LEAD fixes the whole lead, in milliseconds. */
#define MARGIN_START 0.002
#define MARGIN_MIN 0.0005
#define MARGIN_MAX 0.008

static double fixed_lead(void)
{
    static double lead = -1.0;

    if (lead < 0.0)
    {
        const char *value = getenv("GLMT_PRESENT_LEAD");
        lead = value ? atof(value) / 1000.0 : 0.0;
        if (lead < 0.0 || lead > 0.1) lead = 0.0;
    }
    return lead;
}

static double present_lead(GlmtSurface *s)
{
    if (fixed_lead() > 0.0) return fixed_lead();
    return s.refresh + (s.margin > 0.0 ? s.margin : MARGIN_START);
}

/* What the display's report of a flip adds to the statistics: how long the frame took from
 * `presented`, how long after the flip the report came, and where in the refresh the flip was. The
 * caller holds the surface's lock. */
static void count_flip(GlmtSurface *s, char kind, double presented, double flipped, double target, uintptr_t drawable,
                       double returned)
{
    double vsync, period;

    trace_line("F %c %.6f %.6f %.6f %.6f %lx %.6f\n", kind, presented, flipped, CACurrentMediaTime(), target,
               (unsigned long)drawable, returned);
    if (s->flipCount < FLIP_SAMPLES)
    {
        s->flipDelay[s->flipCount] = (float)(flipped - presented);
        s->flipReport[s->flipCount++] = (float)(CACurrentMediaTime() - flipped);
    }
    if (display_vsync(&vsync, &period))
    {
        /* 0 is at a vsync of the display link, 0.5 halfway to the next */
        double phase = fmod(flipped - vsync, period) / period;

        if (phase < 0.0) phase += 1.0;
        s->flipPhase[(int)(phase * 10.0) % 10]++;
        s->phaseCos += cos(2.0 * M_PI * phase);
        s->phaseSin += sin(2.0 * M_PI * phase);
        s->phaseCount++;
    }
}

/* Whether the frame that is finished now goes to the display. */
static bool frame_is_shown(GlmtSurface *s, int interval, double now)
{
    enum present_mode mode = present_mode();
    double next, lead;
    int in_flight;

    if (interval > 0 || mode == PRESENT_WAIT) return true;
    @synchronized(s) { in_flight = s.inFlight; }
    /* A layer has three drawables, and asking for one while all three are on their way waits. So a
     * frame that finds all three out is dropped. (Unsynced, a frame is on the display about 3 ms
     * after it is presented, so three out is rare; the count runs high because the display's
     * reports come in late, and with a limit of two a quarter of the frames at 250 a second were
     * dropped for nothing.) With display sync on, two: the third would wait for a refresh. If none
     * has come back for two refreshes, the count is not to be trusted (a hidden window, a display
     * that reports nothing): present anyway, at worst with a wait. */
    if (in_flight >= (mode == PRESENT_TEAR ? 3 : 2))
    {
        if (now - s.lastPresent < s.refresh * 2.0) return false;
        @synchronized(s) { s.inFlight = 0; }
    }
    if (mode == PRESENT_TEAR) return true;

    lead = present_lead(s);
    if (s.lastVblank <= 0.0 || now - s.lastVblank > 1.0)
        /* Not known yet when the display refreshes or how long a frame takes to get there: one
         * frame per refresh interval. */
        return now - s.lastPresent >= s.refresh * 0.95;

    /* The first refresh a frame presented now can reach. One frame per refresh, and of the frames
     * that could reach it the last: if the next frame would be finished in time too, wait for it. */
    next = s.lastVblank + ceil((now + lead - s.lastVblank) / s.refresh) * s.refresh;
    if (next - s.targetVblank < s.refresh * 0.5) return false;
    if (s.frameTime > 0.0 && now + s.frameTime <= next - lead) return false;
    s.targetVblank = next;
    return true;
}

/* Copies the finished frame into a drawable of the layer and presents it with the frame's command
 * buffer. */
static void present_frame(GlmtSurface *s, int interval, double now)
{
    bool sync = interval > 0 || (present_mode() == PRESENT_MAILBOX);
    bool aimed = interval == 0 && present_mode() == PRESENT_MAILBOX && s.lastVblank > 0.0 && fixed_lead() <= 0.0;
    double target = s.targetVblank, refresh = s.refresh, asked;
    id<CAMetalDrawable> drawable;
    id<MTLBlitCommandEncoder> blit;
    GlmtSurface *surface = s;
    uintptr_t texture_id;

    if (s.displaySync != sync)
    {
        s.layer.displaySyncEnabled = sync;
        s.displaySync = sync;
    }
    if (!s.offscreen || !s.commandBuffer) return;
    asked = CACurrentMediaTime();
    drawable = [s.layer nextDrawable];
    trace_line("W %.6f %.3f\n", now, (CACurrentMediaTime() - asked) * 1000.0);
    if (!drawable) return;
    if (drawable.texture.width != s.offscreen.width || drawable.texture.height != s.offscreen.height) return;

    blit = [s.commandBuffer blitCommandEncoder];
    [blit copyFromTexture:s.offscreen
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(s.offscreen.width, s.offscreen.height, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    @synchronized(s) { s.inFlight = s.inFlight + 1; }
    texture_id = (uintptr_t)(__bridge void *)drawable.texture;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
      @synchronized(surface)
      {
          if (surface.inFlight > 0) surface.inFlight = surface.inFlight - 1;
          /* 0 for a frame that was never on the display */
          if (shown.presentedTime > 0.0)
          {
              surface.lastVblank = shown.presentedTime;
              count_flip(surface, sync ? 's' : 't', now, shown.presentedTime, 0.0, texture_id, 0.0);
              if (aimed)
              {
                  double margin = surface.margin > 0.0 ? surface.margin : MARGIN_START;

                  if (shown.presentedTime - target > refresh * 0.5)
                  {
                      /* it was for the refresh before the one it reached */
                      surface.late = surface.late + 1;
                      margin += 0.0005;
                  }
                  else margin -= 0.00001;
                  surface.margin = margin < MARGIN_MIN ? MARGIN_MIN : margin > MARGIN_MAX ? MARGIN_MAX : margin;
              }
          }
      }
    }];
    [s.commandBuffer presentDrawable:drawable];
    s.lastPresent = now;
}

/* ---- GLMT_PRESENT=async: the surface's presenter thread.
 *
 * The game's swap commits its frame, counts it (asyncSeq) and wakes this thread; it touches
 * neither the layer nor a drawable. The thread takes a drawable only when a frame it has not
 * shown is there, copies the surface's texture into it with a command buffer of its own on the
 * same queue, and presents. Command buffers of one queue run in the order they were committed,
 * and the copy is committed under asyncLock, as the frames are: so it reads the newest whole
 * frame, whichever that is by the time the drawable is in hand, and never half of one
 * (asyncPartial: a frame that was committed in parts, by glReadPixels or a resize, is whole at its
 * swap). A frame the display had no drawable for in time is replaced by the next: counted as
 * dropped, and nobody waited for it.
 *
 * In this mode the thread alone touches the layer, display sync included. When the game asks for
 * vsync the game's thread shows the frames again (present_frame), after async_pause has seen the
 * thread out of the layer. The thread holds a reference to its surface and ends by itself when
 * the surface is destroyed. Nothing of a drawable is called under the surface's own lock
 * (@synchronized), which the presented handlers take; asyncLock they never take. */
static void *async_main(void *arg)
{
    GlmtSurface *s = CFBridgingRelease(arg);
    uint64_t shown = 0;

    pthread_setname_np("glmt present");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    for (;;)
    {
        @autoreleasepool
        {
            id<CAMetalDrawable> drawable;
            id<MTLCommandBuffer> buffer;
            id<MTLBlitCommandEncoder> blit;
            id<MTLTexture> source;
            GlmtSurface *surface = s;
            uintptr_t texture_id;
            double asked, swapped;
            uint64_t seq;
            BOOL stop;

            pthread_mutex_lock(&s->asyncLock);
            s->asyncBusy = NO;
            pthread_cond_broadcast(&s->asyncCond);
            while (!s->asyncStop && (s->asyncIdle || s->asyncSeq == shown)) pthread_cond_wait(&s->asyncCond, &s->asyncLock);
            stop = s->asyncStop;
            s->asyncBusy = !stop;
            pthread_mutex_unlock(&s->asyncLock);
            if (stop) break;

            if (s.displaySync != 0)
            {
                s.layer.displaySyncEnabled = NO;
                s.displaySync = 0;
            }
            asked = CACurrentMediaTime();
            drawable = [s.layer nextDrawable];
            trace_line("N %.6f %.3f\n", asked, (CACurrentMediaTime() - asked) * 1000.0);
            /* none within nextDrawable's second (a window that is not on a display): ask again */
            if (!drawable) continue;

            pthread_mutex_lock(&s->asyncLock);
            while (!s->asyncStop && !s->asyncIdle && s->asyncPartial) pthread_cond_wait(&s->asyncCond, &s->asyncLock);
            source = s.offscreen;
            seq = s->asyncSeq;
            swapped = s->asyncSwapTime;
            if (s->asyncStop || s->asyncIdle || seq == shown || !source || drawable.texture.width != source.width ||
                drawable.texture.height != source.height || !(buffer = [s.asyncQueue commandBuffer]))
            {
                /* nothing to show after all (or a drawable of the size before a resize): the
                 * drawable goes back unused */
                if (!s->asyncStop && !s->asyncIdle && seq != shown) shown = seq;
                pthread_mutex_unlock(&s->asyncLock);
                continue;
            }
            blit = [buffer blitCommandEncoder];
            [blit copyFromTexture:source
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(source.width, source.height, 1)
                        toTexture:drawable.texture
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            texture_id = (uintptr_t)(__bridge void *)drawable.texture;
            [drawable addPresentedHandler:^(id<MTLDrawable> flipped) {
              @synchronized(surface)
              {
                  /* 0 for a frame that was never on the display */
                  if (flipped.presentedTime > 0.0)
                  {
                      surface.lastVblank = flipped.presentedTime;
                      count_flip(surface, 't', swapped, flipped.presentedTime, 0.0, texture_id, 0.0);
                  }
              }
            }];
            [buffer presentDrawable:drawable];
            [buffer commit];
            pthread_mutex_unlock(&s->asyncLock);

            @synchronized(s)
            {
                s.shown = s.shown + 1;
                s.dropped = s.dropped + (seq - shown - 1);
            }
            shown = seq;
        }
    }
    return NULL;
}

/* The game's thread is about to touch the layer itself (vsync, a resize): the presenter stops
 * taking drawables, and this returns when it holds none. That can take as long as its
 * nextDrawable does, a second at most for a window that is not on a display. */
static void async_pause(GlmtSurface *s)
{
    pthread_mutex_lock(&s->asyncLock);
    if (s->asyncStarted && !s->asyncIdle)
    {
        s->asyncIdle = YES;
        pthread_cond_broadcast(&s->asyncCond);
        while (s->asyncBusy) pthread_cond_wait(&s->asyncCond, &s->asyncLock);
    }
    pthread_mutex_unlock(&s->asyncLock);
}

/* async: the frame of this swap is committed and counted, and the presenter is woken. */
static void async_commit(GlmtMetal *m, GlmtSurface *s, double now)
{
    pthread_mutex_lock(&s->asyncLock);
    if (s.commandBuffer || s->asyncPartial)
    {
        [s.commandBuffer commit];
        s->asyncSeq++;
        s->asyncSwapTime = now;
    }
    s->asyncPartial = NO;
    s->asyncIdle = NO;
    if (!s->asyncStarted)
    {
        pthread_attr_t attr;
        pthread_t thread;
        void *reference = (void *)CFBridgingRetain(s); /* the thread's own, released in async_main */

        s.asyncQueue = m.queue;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (!pthread_create(&thread, &attr, async_main, reference)) s->asyncStarted = YES;
        else
        {
            CFRelease(reference);
            glmt_log("glmt: no presenter thread: GLMT_PRESENT=async shows nothing");
        }
        pthread_attr_destroy(&attr);
    }
    pthread_cond_broadcast(&s->asyncCond);
    pthread_mutex_unlock(&s->asyncLock);
}

static void metal_present(struct glmt_backend *be, void *surface, int interval)
{
    GlmtMetal *m = impl_of(be);
    GlmtSurface *s = (__bridge GlmtSurface *)surface;

    @autoreleasepool
    {
        NSArray<id<MTLBuffer>> *arenas;
        NSMutableArray<id<MTLBuffer>> *freeArenas = m.freeArenas;
        double now = CACurrentMediaTime();
        BOOL async;

        if (s.layer) trace_line("S %.6f %d %d\n", now, interval, (int)present_mode());
        /* A frame that only cleared still shows its clear. */
        if (!s.encoder && s.pendingClear) frame_encoder(m, s);
        [s.encoder endEncoding];
        s.encoder = nil;

        /* the time between two swaps, smoothed, without the pauses of a map load */
        if (s.lastSwap > 0.0 && now - s.lastSwap < 0.1)
            s.frameTime = s.frameTime > 0.0 ? s.frameTime * 0.9 + (now - s.lastSwap) * 0.1 : now - s.lastSwap;
        s.lastSwap = now;

        async = s.layer && interval == 0 && present_mode() == PRESENT_ASYNC;
        if (!async && s.layer) async_pause(s);
        if (!async && s.layer && s.commandBuffer)
        {
            if (frame_is_shown(s, interval, now))
            {
                present_frame(s, interval, now);
                s.shown = s.shown + 1;
            }
            else s.dropped = s.dropped + 1;
        }

        /* The arenas of this frame are free again when the GPU is done with them. */
        [m nextArena];
        arenas = [m.frameArenas copy];
        [m.frameArenas removeAllObjects];
        if (s.commandBuffer)
        {
            [s.commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
              @synchronized(freeArenas) { [freeArenas addObjectsFromArray:arenas]; }
            }];
        }
        else
        {
            @synchronized(freeArenas) { [freeArenas addObjectsFromArray:arenas]; }
        }
        if (async) async_commit(m, s, now);
        else if (s.commandBuffer)
        {
            /* (under the lock, and a whole frame again: a later async swap finds its state right) */
            pthread_mutex_lock(&s->asyncLock);
            [s.commandBuffer commit];
            s->asyncPartial = NO;
            pthread_mutex_unlock(&s->asyncLock);
        }
        s.commandBuffer = nil;
        s.target = nil;
        /* A frame starts black unless the game clears it (see frame_encoder); a surface without a
         * layer keeps its picture, for whoever reads it back. */
        s.colorDrawn = s.layer == nil;
        s->bound.valid = false;
    }
}

static int compare_delays(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y;
}

/* For the statistics line: how many of the frames since the last call went to the display; and
 * lines of its own with when they got there. */
static void metal_frame_note(struct glmt_backend *be, void *surface, char *note, size_t size)
{
    GlmtSurface *s = (__bridge GlmtSurface *)surface;
    float delays[FLIP_SAMPLES], reports[FLIP_SAMPLES];
    uint32_t n, phase[10], phases;
    double vsync = 0.0, period = 0.0, phase_cos, phase_sin;
    uint64_t late, shown, dropped;

    if (!s.layer) return;
    trace_flush();
    @synchronized(s)
    {
        late = s.late;
        shown = s.shown;
        dropped = s.dropped;
        s.late = s.shown = s.dropped = 0;
        n = s->flipCount;
        memcpy(delays, s->flipDelay, n * sizeof(float));
        memcpy(reports, s->flipReport, n * sizeof(float));
        memcpy(phase, s->flipPhase, sizeof(phase));
        phase_cos = s->phaseCos;
        phase_sin = s->phaseSin;
        phases = s->phaseCount;
        s->flipCount = s->phaseCount = 0;
        s->phaseCos = s->phaseSin = 0.0;
        memset(s->flipPhase, 0, sizeof(s->flipPhase));
    }
    snprintf(note, size, "; shown %llu, dropped %llu", (unsigned long long)shown, (unsigned long long)dropped);
    if (present_mode() == PRESENT_MAILBOX)
        snprintf(note + strlen(note), size - strlen(note), ", %llu a refresh late, lead %.1f ms", (unsigned long long)late,
                 present_lead(s) * 1000.0);

    /* When the frames got to the display, as the display reported it:
     *   how long after they were presented (tear: after the swap, the frame's GPU work included;
     *   with display sync: after nextDrawable returned), and how long after that the report came;
     *   where in the refresh, counted from the display link's vsync: the mean with how closely
     *   the flips keep to it (0%: all over the refresh, 100%: all at one point), and the count in
     *   each tenth. Unsynced frames of a game at 250 fps fall all over the refresh if the reported
     *   moment is the real flip; synced ones sit at one point. */
    if (n)
    {
        double mean = 0.0, together = 0.0;

        display_vsync(&vsync, &period);
        qsort(delays, n, sizeof(float), compare_delays);
        qsort(reports, n, sizeof(float), compare_delays);
        if (phases)
        {
            mean = atan2(phase_sin, phase_cos) / (2.0 * M_PI);
            if (mean < -0.25) mean += 1.0;
            together = sqrt(phase_cos * phase_cos + phase_sin * phase_sin) / phases;
        }
        glmt_log("glmt:   to the display ms: shortest %.2f, median %.2f, 95%% %.2f, 99%% %.2f, longest %.2f; the report %.2f after "
                 "(shortest %.2f); in the refresh: %.2f ms after the display link's vsync, %.0f%% together, by tenths "
                 "%u %u %u %u %u %u %u %u %u %u; refresh %.3f ms%s",
                 delays[0] * 1000.0, delays[n / 2] * 1000.0, delays[(uint32_t)((n - 1) * 0.95)] * 1000.0,
                 delays[(uint32_t)((n - 1) * 0.99)] * 1000.0, delays[n - 1] * 1000.0, reports[n / 2] * 1000.0, reports[0] * 1000.0,
                 mean * period * 1000.0, together * 100.0, phase[0], phase[1], phase[2], phase[3], phase[4], phase[5], phase[6],
                 phase[7], phase[8], phase[9], period * 1000.0, period > 0.0 ? "" : " (no display link)");
    }
}

struct glmt_backend *glmt_backend_metal_create(void)
{
    struct metal_backend *mb;
    GlmtMetal *m = [GlmtMetal new];
    NSMutableArray<id<MTLFunction>> *vertex = [NSMutableArray new], *fragment = [NSMutableArray new];
    static const uint8_t white[4] = {255, 255, 255, 255};
    MTLTextureDescriptor *descriptor;
    NSError *error = nil;

    if (!(m.device = MTLCreateSystemDefaultDevice()))
    {
        glmt_log("glmt: no Metal device");
        return NULL;
    }
    m.queue = [m.device newCommandQueue];
    m.textures = [NSMutableDictionary new];
    m.pipelines = [NSMutableDictionary new];
    m.depthStates = [NSMutableDictionary new];
    m.samplers = [NSMutableDictionary new];
    m.clearPipelines = [NSMutableDictionary new];
    m.clearDepthStates = [NSMutableDictionary new];
    m.freeArenas = [NSMutableArray new];
    m.frameArenas = [NSMutableArray new];
    [m nextArena];

    /* One vertex and one fragment function: Metal compiles the source here and keeps the result in
     * its own on-disk cache, so only the first start of a build pays for it. */
    m.library = [m.device newLibraryWithSource:@(glmt_shader_source) options:[MTLCompileOptions new] error:&error];
    if (!m.library)
    {
        glmt_log("glmt: the shaders do not compile: %s", error.localizedDescription.UTF8String);
        return NULL;
    }
    for (int variant = 0; variant < 4; variant++)
    {
        bool alpha_test = variant & 1, clip_plane = variant & 2;
        MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
        id<MTLFunction> v, f;

        [constants setConstantValue:&alpha_test type:MTLDataTypeBool atIndex:0];
        [constants setConstantValue:&clip_plane type:MTLDataTypeBool atIndex:1];
        v = [m.library newFunctionWithName:@"glmt_vertex" constantValues:constants error:&error];
        f = v ? [m.library newFunctionWithName:@"glmt_fragment" constantValues:constants error:&error] : nil;
        if (!v || !f)
        {
            glmt_log("glmt: no shader function (alpha test %d, clip plane %d): %s", alpha_test, clip_plane,
                     error.localizedDescription.UTF8String);
            return NULL;
        }
        [vertex addObject:v];
        [fragment addObject:f];
    }
    m.vertexFunctions = vertex;
    m.fragmentFunctions = fragment;
    m.clearVertex = [m.library newFunctionWithName:@"glmt_clear_vertex"];
    m.clearFragment = [m.library newFunctionWithName:@"glmt_clear_fragment"];

    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    m.whiteTexture = [m.device newTextureWithDescriptor:descriptor];
    [m.whiteTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:white bytesPerRow:4];
    m.constants = [m.device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    if (!m.clearVertex || !m.clearFragment || !m.whiteTexture || !m.constants)
    {
        glmt_log("glmt: Metal made no clear function, texture or buffer");
        return NULL;
    }
    glmt_log("glmt: Metal device %s", m.device.name.UTF8String);

    if (!(mb = calloc(1, sizeof(*mb)))) return NULL;
    mb->impl = (void *)CFBridgingRetain(m);
    mb->base.name = "metal";
    mb->base.destroy = metal_destroy;
    mb->base.surface_create = metal_surface_create;
    mb->base.surface_destroy = metal_surface_destroy;
    mb->base.surface_resize = metal_surface_resize;
    mb->base.texture_create = metal_texture_create;
    mb->base.texture_upload = metal_texture_upload;
    mb->base.texture_destroy = metal_texture_destroy;
    mb->base.arena_alloc = metal_arena_alloc;
    mb->base.arena_next = metal_arena_next;
    mb->base.submit = metal_submit;
    mb->base.read_pixels = metal_read_pixels;
    mb->base.present = metal_present;
    mb->base.frame_note = metal_frame_note;
    return &mb->base;
}
