#ifndef GRASS_CLUMP_INCLUDED
#define GRASS_CLUMP_INCLUDED

#include "GrassHash.hlsl"

// Distinct from GrassBuilder.compute's own blade-hash seed space, so clump cells and
// blades never accidentally correlate. Same primes as the standard spatial-hashing scheme.
#define CLUMP_HASH_PRIME_X 73856093u
#define CLUMP_HASH_PRIME_Z 19349663u

uint HashClumpCell(int2 cell)
{
    uint ux = (uint) cell.x * CLUMP_HASH_PRIME_X;
    uint uz = (uint) cell.y * CLUMP_HASH_PRIME_Z;
    return HashUInt(ux ^ uz);
}

// Jittered-grid Voronoi lookup keyed purely on world position (independent of tileId), so
// results are identical for any two blades landing in the same clump cell regardless of
// which tile streamed them in.
uint GetClumpId(float2 worldXZ, float clumpSize, float jitterStrength, out float distToCenter)
{
    float safeSize = max(clumpSize, 1e-4);
    float safeJitter = saturate(jitterStrength);

    int2 cellCoord = int2(floor(worldXZ / safeSize));

    float bestDistSq = 1e10;
    uint bestHash = 0;

    [unroll]
    for (int dz = -1; dz <= 1; dz++)
    {
        [unroll]
        for (int dx = -1; dx <= 1; dx++)
        {
            int2 neighborCell = cellCoord + int2(dx, dz);
            uint cellHash = HashClumpCell(neighborCell);

            float2 jitter2D = float2(HashToFloat01(cellHash, 0), HashToFloat01(cellHash, 1));
            float2 seedPoint = (float2(neighborCell) + 0.5 + (jitter2D - 0.5) * safeJitter) * safeSize;

            float2 delta = worldXZ - seedPoint;
            float distSq = dot(delta, delta);

            if (distSq < bestDistSq)
            {
                bestDistSq = distSq;
                bestHash = cellHash;
            }
        }
    }

    distToCenter = sqrt(bestDistSq);
    return bestHash;
}

#endif
