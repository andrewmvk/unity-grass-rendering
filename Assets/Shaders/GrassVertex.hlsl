#ifndef GRASS_VERTEX_INCLUDED
#define GRASS_VERTEX_INCLUDED

#include "GrassBladeSpine.hlsl"
#include "GrassStructs.hlsl"
#include "GrassTerrainSampling.hlsl"

StructuredBuffer<GrassData> _GrassDataBuffer;

BladeParams GetBladeParams(GrassData grass)
{
    BladeParams p;
    p.height = grass.height;
    p.width = grass.width;
    p.bend = grass.bend;
    p.tilt = grass.tilt;
    p.sideCurve = grass.sideCurve;
    return p;
}

// Depth-only pass: absolute (non camera-relative) world-space vertex position.
float3 GetGrassVertexWorldPosition(uint vertexID, uint instanceID)
{
    GrassData grass = _GrassDataBuffer[instanceID];
    BladeParams params = GetBladeParams(grass);
    float3 groundNormal = ComputeTerrainNormal(grass.position.xz);
    float3 localPos = GetBladeLocalPosition(params, vertexID);
    return grass.position + ApplyBladeOrientation(localPos, grass.facing, groundNormal);
}

struct GrassVertexData
{
    float3 positionWS;
    float3 normalWS;
    float heightPercent;
    uint bladeHash;
};

// Forward pass: position plus everything the lighting model needs.
GrassVertexData GetGrassVertexData(uint vertexID, uint instanceID)
{
    GrassData grass = _GrassDataBuffer[instanceID];
    BladeParams params = GetBladeParams(grass);
    float3 groundNormal = ComputeTerrainNormal(grass.position.xz);

    float3 localPos = GetBladeLocalPosition(params, vertexID);
    float3 localNormal = GetBladeLocalNormal(params, vertexID, grass.bladeHash);

    GrassVertexData o;
    o.positionWS = grass.position + ApplyBladeOrientation(localPos, grass.facing, groundNormal);
    o.normalWS = normalize(ApplyBladeOrientation(localNormal, grass.facing, groundNormal));
    o.heightPercent = GetBladeHeightPercent(vertexID);
    o.bladeHash = grass.bladeHash;
    return o;
}

#endif
