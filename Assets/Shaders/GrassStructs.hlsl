#ifndef GRASS_STRUCTS_INCLUDED
#define GRASS_STRUCTS_INCLUDED

// Single source of truth for the two buffer layouts shared between
// GrassBuilder.compute (writer) and GrassVertex.hlsl (reader).
// The C# mirrors in GrassManager.cs (TileData, and the grassDataStride
// byte count) must be kept in sync manually.

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

#endif
