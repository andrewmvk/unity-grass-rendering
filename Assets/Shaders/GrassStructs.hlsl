#ifndef GRASS_STRUCTS_INCLUDED
#define GRASS_STRUCTS_INCLUDED

// Single source of truth for the two buffer layouts shared between GrassBuilder.compute
// (writer) and GrassVertex.hlsl (reader). The C# mirrors in GrassManager.cs (TileData,
// and the grassDataStride byte count) must be kept in sync manually.

struct TileData
{
    float3 center;
    uint tileId; // stable index into the full grid, independent of visibility/order
};

struct GrassData
{
    float3 position;
    float2 facing;
    float height;
    float width;
    float tilt;
    float bend;
    float sideCurve;
    float2 clumpFacing;
    float3 clumpColor;
    float windStrength;
    uint bladeHash;
};

// Below this, a blade's distance-fade shrink factor is treated as fully zero.
#define GRASS_FADE_CUTOFF 0.05

// Distance-based shrink factor: 1 at/inside fadeStartDist, 0 at/beyond fadeEndDist.
float GetGrassFadeShrink(float3 grassPosition, float3 cameraPosition, float fadeStartDist, float fadeEndDist)
{
    float distToCamera = length(grassPosition - cameraPosition);
    float fade = smoothstep(fadeStartDist, fadeEndDist, distToCamera);
    float shrink = 1.0 - fade;
    return shrink < GRASS_FADE_CUTOFF ? 0.0 : shrink;
}

float GetGrassLODBendFade(float distToCamera, float blendStartDist, float lodSwitchDist)
{
    return 1.0 - smoothstep(blendStartDist, lodSwitchDist, distToCamera);
}

float GetGrassFarShadingFade(float distToCamera, float startDist, float endDist)
{
    return smoothstep(startDist, endDist, distToCamera);
}

#endif
