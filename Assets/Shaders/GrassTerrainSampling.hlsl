#ifndef GRASS_TERRAIN_SAMPLING_INCLUDED
#define GRASS_TERRAIN_SAMPLING_INCLUDED

// Shared by GrassBuilder.compute (blade placement/culling) and GrassVertex.hlsl
// (blade orientation): reads Unity's own Terrain.terrainData.heightmapTexture.
// Set as globals from GrassManager.cs so both the compute shader and the
// render material see the same terrain data without duplicating it per-blade.
Texture2D<float4> _HeightmapTexture;
float2 _TerrainOriginXZ;
float2 _TerrainSize;
float _TerrainBaseY;
float _TerrainHeightScale;
float _UseTerrainHeight;

SamplerState sampler_LinearClamp;

float SampleTerrainHeight(float2 worldPosXZ)
{
    float2 uv = saturate((worldPosXZ - _TerrainOriginXZ) / _TerrainSize);
    float normalizedHeight = _HeightmapTexture.SampleLevel(sampler_LinearClamp, uv, 0).r;
    return _TerrainBaseY + normalizedHeight * _TerrainHeightScale;
}

float3 ComputeTerrainNormal(float2 worldPosXZ)
{
    uint texWidth, texHeight;
    _HeightmapTexture.GetDimensions(texWidth, texHeight);
    float2 texelSize = _TerrainSize / float2(max(texWidth, 1u) - 1, max(texHeight, 1u) - 1);
    float epsX = max(texelSize.x, 0.01);
    float epsZ = max(texelSize.y, 0.01);

    float hL = SampleTerrainHeight(worldPosXZ - float2(epsX, 0));
    float hR = SampleTerrainHeight(worldPosXZ + float2(epsX, 0));
    float hD = SampleTerrainHeight(worldPosXZ - float2(0, epsZ));
    float hU = SampleTerrainHeight(worldPosXZ + float2(0, epsZ));

    return normalize(float3((hL - hR) / (2.0 * epsX), 1.0, (hD - hU) / (2.0 * epsZ)));
}

#endif
