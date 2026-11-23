/* Checks glmt's shaders on this Mac, the way the backend uses them: the source the library carries
 * goes through Metal's runtime compiler, each of the four specializations (alpha test and clip plane
 * on and off) is made, and a render pipeline is built from each with the backend's vertex layout.
 *
 *     make -C glmt shadercheck
 *
 * A shader that does not compile would otherwise show up only when the game starts, as no OpenGL. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "backend.h"
#include "shaders.inc"

static MTLVertexDescriptor *vertex_descriptor(void)
{
    static const MTLVertexFormat formats[] = {MTLVertexFormatFloat3, MTLVertexFormatUChar4Normalized,
                                              MTLVertexFormatFloat2, MTLVertexFormatFloat2};
    static const NSUInteger strides[] = {GLMT_POSITION_STRIDE, GLMT_COLOR_STRIDE, GLMT_TEXCOORD_STRIDE,
                                         GLMT_TEXCOORD_STRIDE};
    MTLVertexDescriptor *descriptor = [MTLVertexDescriptor vertexDescriptor];

    for (NSUInteger i = 0; i < 4; i++)
    {
        descriptor.attributes[i].format = formats[i];
        descriptor.attributes[i].bufferIndex = i;
        descriptor.attributes[i].offset = 0;
        descriptor.layouts[i].stride = strides[i];
        descriptor.layouts[i].stepFunction = MTLVertexStepFunctionPerVertex;
    }
    return descriptor;
}

int main(void)
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> library;
        int failures = 0;

        if (!device)
        {
            fprintf(stderr, "shadercheck: no Metal device\n");
            return 1;
        }
        library = [device newLibraryWithSource:@(glmt_shader_source) options:[MTLCompileOptions new] error:&error];
        if (!library)
        {
            fprintf(stderr, "shadercheck: the shaders do not compile:\n%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        if (error) printf("shadercheck: compiler warnings:\n%s\n", error.localizedDescription.UTF8String);

        for (int variant = 0; variant < 4; variant++)
        {
            bool alpha_test = variant & 1, clip_plane = variant & 2;
            MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
            MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
            id<MTLFunction> vertex, fragment;

            [constants setConstantValue:&alpha_test type:MTLDataTypeBool atIndex:0];
            [constants setConstantValue:&clip_plane type:MTLDataTypeBool atIndex:1];
            error = nil;
            vertex = [library newFunctionWithName:@"glmt_vertex" constantValues:constants error:&error];
            if (vertex) fragment = [library newFunctionWithName:@"glmt_fragment" constantValues:constants error:&error];
            if (!vertex || !fragment)
            {
                fprintf(stderr, "shadercheck: alpha test %d, clip plane %d: no function: %s\n", alpha_test, clip_plane,
                        error.localizedDescription.UTF8String);
                failures++;
                continue;
            }
            pipeline.vertexFunction = vertex;
            pipeline.fragmentFunction = fragment;
            pipeline.vertexDescriptor = vertex_descriptor();
            pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pipeline.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            pipeline.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            if (![device newRenderPipelineStateWithDescriptor:pipeline error:&error])
            {
                fprintf(stderr, "shadercheck: alpha test %d, clip plane %d: no pipeline: %s\n", alpha_test, clip_plane,
                        error.localizedDescription.UTF8String);
                failures++;
            }
        }

        {
            MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
            pipeline.vertexFunction = [library newFunctionWithName:@"glmt_clear_vertex"];
            pipeline.fragmentFunction = [library newFunctionWithName:@"glmt_clear_fragment"];
            pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pipeline.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            pipeline.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            error = nil;
            if (!pipeline.vertexFunction || !pipeline.fragmentFunction ||
                ![device newRenderPipelineStateWithDescriptor:pipeline error:&error])
            {
                fprintf(stderr, "shadercheck: the clear pipeline: %s\n", error.localizedDescription.UTF8String);
                failures++;
            }
        }

        if (failures) return 1;
        printf("shadercheck: the shaders compile on %s: 4 specializations and the clear, each as a pipeline\n",
               device.name.UTF8String);
        return 0;
    }
}
