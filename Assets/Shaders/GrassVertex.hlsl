#ifndef GRASS_VERTEX_INCLUDED
#define GRASS_VERTEX_INCLUDED

#include "GrassBladeSpine.hlsl"
#include "GrassStructs.hlsl"

StructuredBuffer<GrassData> _GrassDataBuffer;

// World-space distance from the camera where the height shrink-to-ground fade
// begins and ends (0 height), hiding the tile-streaming pop at render distance.
float _GrassFadeStartDist;
float _GrassFadeEndDist;

// Explicitly the GrassManager's Main Camera reference (also used for frustum
// culling/tile streaming), NOT necessarily whichever camera HDRP is currently
// rendering with - deliberate, so the Scene view camera can be moved around
// to debug culling/streaming without perturbing the fade. Swap this for HDRP's
// actual rendering camera (e.g. via GetCameraRelativePositionWS) if this ever
// needs to be correct for a real multi-camera/XR production setup.
float3 _GrassCameraPosition;

float _GrassLODSwitchDist;
float _GrassLODBendBlendDist;

BladeParams GetBladeParams(GrassData grass)
{
    BladeParams p;
    p.height = grass.height;
    p.width = grass.width;
    p.bend = grass.bend;
    p.tilt = grass.tilt;
    p.sideCurve = grass.sideCurve;

    float shrink = GetGrassFadeShrink(grass.position, _GrassCameraPosition, _GrassFadeStartDist, _GrassFadeEndDist);
    p.height *= shrink;
    p.tilt *= shrink;
    p.bend *= shrink;

#if !defined(_GRASS_LOD_LOW)
    float distToCamera = length(grass.position - _GrassCameraPosition);
    float bendFade = GetGrassLODBendFade(distToCamera, _GrassLODSwitchDist - _GrassLODBendBlendDist, _GrassLODSwitchDist);
    p.bend *= bendFade;
#endif

    return p;
}

struct GrassVertexData
{
    float3 positionWS;
    float3 normalWS;
    float heightPercent;
    uint bladeHash;
};

// Used by both passes: position, normal, and everything the lighting model/normal buffer need.
GrassVertexData GetGrassVertexData(uint vertexID, uint instanceID)
{
    GrassData grass = _GrassDataBuffer[instanceID];
    BladeParams params = GetBladeParams(grass);

    float3 localPos = GetBladeLocalPosition(params, vertexID);
    float3 localNormal = GetBladeLocalNormal(params, vertexID, grass.bladeHash);

    GrassVertexData o;
    o.positionWS = grass.position + ApplyBladeOrientation(localPos, grass.facing);
    o.normalWS = normalize(ApplyBladeOrientation(localNormal, grass.facing));
    o.heightPercent = GetBladeHeightPercent(vertexID);
    o.bladeHash = grass.bladeHash;
    return o;
}

#endif
