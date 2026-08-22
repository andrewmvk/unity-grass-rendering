#ifndef GRASS_HASH_INCLUDED
#define GRASS_HASH_INCLUDED

// Cheap integer hash (xxhash-ish avalanche), used to seed all per-blade
// randomization deterministically from (tile, thread) indices so the
// result is stable across frames without storing any random state.
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

// Returns a float in [0, 1) derived from seed, decorrelated per "channel"
// so multiple properties of the same blade don't move in lockstep.
float HashToFloat01(uint seed, uint channel)
{
    return HashUInt(seed + channel * 9781u) / 4294967295.0;
}

// Maps a [0,1) hash value to [-1, 1).
float HashToSigned(uint seed, uint channel)
{
    return HashToFloat01(seed, channel) * 2.0 - 1.0;
}

#endif
