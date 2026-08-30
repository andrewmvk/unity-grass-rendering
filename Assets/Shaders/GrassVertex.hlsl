#ifndef GRASS_VERTEX_INCLUDED
#define GRASS_VERTEX_INCLUDED

#include "GrassBladeSpine.hlsl"
#include "GrassStructs.hlsl"
#include "GrassTerrainSampling.hlsl"

StructuredBuffer<GrassData> _GrassDataBuffer;

// Shared by both DummyGrass.shader passes: looks up this instance's GrassData
// and returns its absolute (non camera-relative) world-space vertex position.
float3 GetGrassVertexWorldPosition(uint vertexID, uint instanceID)
{
    GrassData grass = _GrassDataBuffer[instanceID];

    BladeParams params;
    params.height = grass.height;
    params.width = grass.width;
    params.bend = grass.bend;
    params.tilt = grass.tilt;
    params.sideCurve = grass.sideCurve;

    float3 groundNormal = _UseTerrainHeight > 0.5 ? ComputeTerrainNormal(grass.position.xz) : float3(0, 1, 0);

    float3 localPos = GetBladeLocalPosition(params, vertexID);
    localPos = ApplyBladeOrientation(localPos, grass.facing, groundNormal);

    return grass.position + localPos;
}

float3 GetGrassVertexClumpColor(uint instanceID)
{
    return _GrassDataBuffer[instanceID].clumpColor;
}

#endif
