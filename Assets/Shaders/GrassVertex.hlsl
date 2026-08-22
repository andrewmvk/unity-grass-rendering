#ifndef GRASS_VERTEX_INCLUDED
#define GRASS_VERTEX_INCLUDED

#include "GrassBladeSpine.hlsl"

struct GrassData
{
    float3 position;
    float2 facing;
    float height;
    float width;
    float tilt;
    float bend;
    float sideCurve;
};
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

    float3 localPos = GetBladeLocalPosition(params, vertexID);
    localPos = ApplyBladeFacing(localPos, grass.facing);

    return grass.position + localPos;
}

#endif
