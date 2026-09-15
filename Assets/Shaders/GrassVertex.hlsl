#ifndef GRASS_VERTEX_INCLUDED
#define GRASS_VERTEX_INCLUDED

#include "GrassBladeSpine.hlsl"
#include "GrassStructs.hlsl"

StructuredBuffer<GrassData> _GrassDataBuffer;

// World-space distance from the camera where the height shrink-to-ground fade
// begins and ends (0 height), hiding the tile-streaming pop at render distance.
float _GrassFadeStartDist;
float _GrassFadeEndDist;

// Explicitly the GrassManager's Main Camera reference (also used for frustum culling and
// tile streaming), not necessarily whichever camera HDRP is currently rendering with. This
// is deliberate: it lets the Scene view camera move freely to debug culling/streaming
// without perturbing the fade. Swap this for HDRP's actual rendering camera (e.g. via
// GetCameraRelativePositionWS) if this ever needs to be correct for multi-camera/XR.
float3 _GrassCameraPosition;

float _GrassLODSwitchDist;
float _GrassLODBendBlendDist;

// Wind: a scrolling noise texture sampled once per blade at its world position, combined
// with the blade's own baked windStrength to push its tilt/sideCurve Bezier controls
// toward a shared world-space wind direction. _WindScrollOffset is in world units (not
// noise-UV space), so wind speed and gust size (_WindNoiseScale) stay independently tunable.
Texture2D<float4> _WindNoiseTexture;
SamplerState sampler_WindNoiseTexture; // matches the texture's own wrap/filter (Repeat/Bilinear), set in GrassManager.cs
float2 _WindScrollOffset;
float2 _WindDirection;
float _WindNoiseScale;
float _WindBendAmount;
float _WindStrengthMultiplier;

BladeParams GetBladeParams(GrassData grass, out float windNoise)
{
    BladeParams p;
    p.height = grass.height;
    p.width = grass.width;
    p.bend = grass.bend;
    p.tilt = grass.tilt;
    p.sideCurve = grass.sideCurve;

    float2 windUV = (grass.position.xz + _WindScrollOffset) * _WindNoiseScale;
    windNoise = _WindNoiseTexture.SampleLevel(sampler_WindNoiseTexture, windUV, 0).r;
    float windLean = windNoise * grass.windStrength * _WindStrengthMultiplier;

    // Decomposes the world-space wind lean into this blade's own local tilt (forward)
    // and sideCurve (right) axes, so every blade sways toward the same world direction
    // regardless of which way it individually faces.
    float2 right2D = grass.facing;
    float2 forward2D = float2(-grass.facing.y, grass.facing.x);
    float2 windOffset2D = _WindDirection * windLean * _WindBendAmount;
    p.tilt += dot(windOffset2D, forward2D);
    p.sideCurve += dot(windOffset2D, right2D);

    float shrink = GetGrassFadeShrink(grass.position, _GrassCameraPosition, _GrassFadeStartDist, _GrassFadeEndDist);
    p.height *= shrink;
    p.tilt *= shrink;
    p.bend *= shrink;

    #if !defined(_GRASS_LOD_LOW)
        float distToCamera = length(grass.position - _GrassCameraPosition);
        float bendFade = GetGrassLODBendFade(distToCamera, _GrassLODSwitchDist - _GrassLODBendBlendDist, _GrassLODSwitchDist);
        p.bend *= bendFade;
    #endif

    return p;
}

struct GrassVertexData
{
    float3 positionWS;
    float3 normalWS;
    float heightPercent;
    float3 clumpColor;
    float windNoise;
    uint bladeHash;
};

// Used by both passes: position, normal, and everything the lighting model/normal buffer need.
GrassVertexData GetGrassVertexData(uint vertexID, uint instanceID)
{
    GrassData grass = _GrassDataBuffer[instanceID];
    float windNoise;
    BladeParams params = GetBladeParams(grass, windNoise);

    float3 localPos = GetBladeLocalPosition(params, vertexID);
    float3 localNormal = GetBladeLocalNormal(params, vertexID, grass.bladeHash);

    GrassVertexData o;
    o.positionWS = grass.position + ApplyBladeOrientation(localPos, grass.facing);
    o.normalWS = normalize(ApplyBladeOrientation(localNormal, grass.facing));
    o.heightPercent = GetBladeHeightPercent(vertexID);
    o.clumpColor = grass.clumpColor;
    o.windNoise = windNoise;
    o.bladeHash = grass.bladeHash;
    return o;
}

#endif
