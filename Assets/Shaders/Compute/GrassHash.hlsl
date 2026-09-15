#ifndef GRASS_HASH_INCLUDED
#define GRASS_HASH_INCLUDED

// Cheap integer hash (xxhash-style avalanche). Seeds all per-blade randomization
// deterministically from (tile, thread) indices, with no random state to store.
uint HashUInt(uint x)
{
    x ^= 2747636419u;
    x *= 2654435769u;
    x ^= x >> 16;
    x *= 2654435769u;
    x ^= x >> 16;
    x *= 2654435769u;
    return x;
}

// Float in [0, 1), derived from seed. Each channel is decorrelated, so different
// properties of the same blade don't move in lockstep.
float HashToFloat01(uint seed, uint channel)
{
    return HashUInt(seed + channel * 9781u) / 4294967295.0;
}

float HashToSigned(uint seed, uint channel)
{
    return HashToFloat01(seed, channel) * 2.0 - 1.0;
}

#endif
