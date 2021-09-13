//
//  Shaders.metal
//  Solutions
//
//  Created by Noah on 2021/9/11.
//

#include <metal_stdlib>
#include <simd/simd.h>

// Include header shared between this Metal shader code and C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct {
    float2 position [[attribute(kVertexAttributePosition)]];
    float2 texCoord [[attribute(kVertexAttributeTexcoord)]];
} ImageVertex;


typedef struct {
    float4 position [[position]];
} ImageColorInOut;

/**
 https://www.shadertoy.com/view/XsXXDn
 If you intend to reuse this shader, please add credits to 'Danilo Guanabara'
 */

float2 mod(float2 p1, float p2)
{
    float2 result;
    result.x = p1.x - p2 * floor(p1.x / p2);
    result.y = p1.y - p2 * floor(p1.y / p2);
    return result;
}


vertex ImageColorInOut vertex_001(ImageVertex in [[stage_in]]) {
    ImageColorInOut out;
    
    out.position = float4(in.position, 0.0, 1.0);
    
    return out;
}

fragment half4 fragment_001(ImageColorInOut in [[stage_in]],
                            constant SharedUniforms &uniforms [[ buffer(kBufferIndexSharedUniforms) ]]) {
    float3 color = float3();
    float2 res = uniforms.res;
    float time = uniforms.time;
    float l,z = time;
    for(int i = 0; i < 3; i++) {
        float2 uv,p = in.position.xy / float2(res.x,res.y);
        uv = p;
        p -= .5;
        p.y *= res.y / res.x ;
        z += .07;
        l = length(p);
        uv += p / l * (sin(z) + 1.) * abs(sin( l * 9 - z * 2));
        float2 modValue = mod(uv, 1.0);
        color[i] = 0.01/length(abs(modValue - .5));
        }
    return half4(half3(color / l),half(time));
}


