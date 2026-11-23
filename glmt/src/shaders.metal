// glmt's shaders: OpenGL's fixed-function pipeline, the part id Tech 3 uses, as one vertex and one
// fragment function.
//
// What changes from draw to draw (matrices, the texture environment, the alpha reference) is in
// the uniforms, so there is nothing to compile while the game runs. The two things that would
// cost every draw if they were always on are function constants: discard (it takes fragments off
// the GPU's early depth path) and the clip distance. That makes four specializations in all, built
// when the backend starts.
//
// tools/shadercheck.m compiles this source the way the backend does and builds a pipeline from
// each specialization: run it (make shadercheck, macOS) after every change here.

#include <metal_stdlib>
using namespace metal;

// Mirrors struct glmt_uniforms in backend.h, 128 bytes. Change both together.
struct Uniforms
{
    float4x4 mvp;
    float4 color;
    float4 clip_plane;
    float alpha_ref;
    uint alpha_func;
    uint tex_env[2];
    uint tex_flags[2];
    uint flags;
    uint pad;
};

// enum glmt_tex_env, GLMT_TEX_*, GLMT_UNIFORM_* in backend.h
#define ENV_OFF 0u
#define ENV_MODULATE 1u
#define ENV_REPLACE 2u
#define ENV_DECAL 3u
#define ENV_ADD 4u
#define TEX_NO_ALPHA 1u
#define TEX_NO_COLOR 2u
#define UNIFORM_COLOR_ARRAY 1u

constant bool alpha_test [[function_constant(0)]];
constant bool clip_plane [[function_constant(1)]];

// The vertex streams of backend.h. A stream a draw does not have is bound to a constant by the
// backend's vertex descriptor (step function constant) and is not read here.
struct VertexIn
{
    float3 position [[attribute(0)]];
    float4 color [[attribute(1)]];
    float2 texcoord0 [[attribute(2)]];
    float2 texcoord1 [[attribute(3)]];
};

struct VertexOut
{
    float4 position [[position]];
    float4 color;
    float2 texcoord0;
    float2 texcoord1;
    float clip [[clip_distance, function_constant(clip_plane)]];
};

vertex VertexOut glmt_vertex(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(8)]])
{
    VertexOut out;
    float4 object = float4(in.position, 1.0);
    float4 p = u.mvp * object;

    // OpenGL's clip space has z from -w to w, Metal's from 0 to w. glDepthRange is the viewport's
    // near and far.
    p.z = (p.z + p.w) * 0.5;
    out.position = p;
    out.color = (u.flags & UNIFORM_COLOR_ARRAY) != 0 ? in.color : u.color;
    out.texcoord0 = in.texcoord0;
    out.texcoord1 = in.texcoord1;
    if (clip_plane) out.clip = dot(u.clip_plane, object);
    return out;
}

// glTexEnv for one unit. Every texture is stored as RGBA: one without alpha of its own has alpha 1,
// one without color of its own has color 1, and the flags say which, for the modes where OpenGL
// then keeps the incoming value instead.
static float4 texture_environment(float4 incoming, float4 texel, uint mode, uint flags)
{
    bool no_alpha = (flags & TEX_NO_ALPHA) != 0;
    bool no_color = (flags & TEX_NO_COLOR) != 0;

    switch (mode)
    {
    case ENV_REPLACE:
        return float4(no_color ? incoming.rgb : texel.rgb, no_alpha ? incoming.a : texel.a);
    case ENV_DECAL:
        return float4(mix(incoming.rgb, texel.rgb, no_alpha ? 1.0 : texel.a), incoming.a);
    case ENV_ADD:
        return float4(no_color ? incoming.rgb : incoming.rgb + texel.rgb, incoming.a * texel.a);
    default: // ENV_MODULATE
        return incoming * texel;
    }
}

// glAlphaFunc: func is the OpenGL comparison minus GL_NEVER.
static bool alpha_passes(uint func, float alpha, float ref)
{
    switch (func)
    {
    case 0u: return false;
    case 1u: return alpha < ref;
    case 2u: return alpha == ref;
    case 3u: return alpha <= ref;
    case 4u: return alpha > ref;
    case 5u: return alpha != ref;
    case 6u: return alpha >= ref;
    default: return true;
    }
}

fragment float4 glmt_fragment(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> texture0 [[texture(0)]],
                              texture2d<float> texture1 [[texture(1)]],
                              sampler sampler0 [[sampler(0)]],
                              sampler sampler1 [[sampler(1)]])
{
    float4 color = in.color;

    // The branches depend on uniforms only, so the derivatives the samples need are defined.
    if (u.tex_env[0] != ENV_OFF)
        color = texture_environment(color, texture0.sample(sampler0, in.texcoord0), u.tex_env[0], u.tex_flags[0]);
    if (u.tex_env[1] != ENV_OFF)
        color = texture_environment(color, texture1.sample(sampler1, in.texcoord1), u.tex_env[1], u.tex_flags[1]);
    color = saturate(color);

    if (alpha_test && !alpha_passes(u.alpha_func, color.a, u.alpha_ref)) discard_fragment();
    return color;
}

// glClear in the middle of a frame: a triangle that covers the viewport, drawn with a depth stencil
// state that always passes and writes, a color mask from the clear, and the scissor rectangle.
// (A clear at the start of a frame is the render pass's load action instead.)
struct ClearUniforms
{
    float4 color;
    float depth;
};

struct ClearOut
{
    float4 position [[position]];
};

vertex ClearOut glmt_clear_vertex(uint vertex_id [[vertex_id]], constant ClearUniforms &u [[buffer(8)]])
{
    ClearOut out;
    float2 corner = float2((vertex_id << 1) & 2, vertex_id & 2);
    out.position = float4(corner * 2.0 - 1.0, u.depth, 1.0);
    return out;
}

fragment float4 glmt_clear_fragment(constant ClearUniforms &u [[buffer(0)]])
{
    return u.color;
}
