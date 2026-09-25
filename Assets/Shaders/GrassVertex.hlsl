#ifndef GRASS_VERTEX_INCLUDED
#define GRASS_VERTEX_INCLUDED

#include "GrassBladeSpine.hlsl"
#include "GrassStructs.hlsl"
#include "GrassTerrainSampling.hlsl"

StructuredBuffer<GrassData> _GrassDataBuffer;

// Explicitly the GrassManager's Main Camera reference (also used for frustum culling and
// tile streaming), not necessarily whichever camera HDRP is currently rendering with. This
// is deliberate: it lets the Scene view camera move freely to debug culling/streaming
// without perturbing the fade.
float3 _GrassCameraPosition;

float _GrassFarShadingStartDist;
float _GrassFarShadingEndDist;

struct GrassVertexData
{
    float3 positionWS;
    float3 normalWS;
    float3 groundNormalWS;
    float farFade;
    float heightPercent;
    float3 clumpColor;
    float windNoise;
    uint bladeHash;
};

// Used by both passes: position, normal, and everything the lighting model/normal buffer need.
GrassVertexData GetGrassVertexData(uint vertexID, uint instanceID)
{
    GrassData grass = _GrassDataBuffer[instanceID];

    BladeParams params;
    params.height = grass.height;
    params.width = grass.width;
    params.bend = grass.bend;
    params.tilt = grass.tilt;
    params.sideCurve = grass.sideCurve;

    float3 localPos = GetBladeLocalPosition(params, vertexID);
    float3 localNormal = GetBladeLocalNormal(params, vertexID, grass.bladeHash);

    float distToCamera = length(grass.position - _GrassCameraPosition);
    float farFade = GetGrassFarShadingFade(distToCamera, _GrassFarShadingStartDist, _GrassFarShadingEndDist);

    GrassVertexData o;
    o.positionWS = grass.position + ApplyBladeOrientation(localPos, grass.facing);
    o.normalWS = normalize(ApplyBladeOrientation(localNormal, grass.facing));
    o.groundNormalWS = farFade > 0.0 ? ComputeTerrainNormal(grass.position.xz) : float3(0, 1, 0);
    o.farFade = farFade;
    o.heightPercent = GetBladeHeightPercent(vertexID);
    o.clumpColor = grass.clumpColor;
    o.windNoise = grass.windStrength;
    o.bladeHash = grass.bladeHash;
    return o;
}

float3 GetGrassShadingNormal(float3 bladeNormalWS, float3 groundNormalWS, float farFade, bool isFrontFace)
{
    float3 bladeNormal = normalize(bladeNormalWS) * (isFrontFace ? 1.0 : -1.0);
    return normalize(lerp(bladeNormal, groundNormalWS, farFade));
}

#endif
