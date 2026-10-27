#ifndef GRASS_BLADE_SPINE_INCLUDED
#define GRASS_BLADE_SPINE_INCLUDED

#include "Compute/GrassHash.hlsl"

// 15-vertex strip: 7 tapering left/right pairs plus 1 tip. Submitted as an indexed
// triangle list (39 indices, see GrassManager.cs), so vertexID is already a strip index.
#if defined(_GRASS_LOD_LOW)
    #define BLADE_STRIP_VERTEX_COUNT 3
#else
    #define BLADE_ROW_COUNT 7
    #define BLADE_STRIP_VERTEX_COUNT 15
#endif

// Fake-round cross-section: left/right vertices get their normal tilted away
// from the flat face, so a single-sided ribbon reads as a rounded blade under lighting.
#define BLADE_ROUNDNESS_ANGLE 0.7
#define BLADE_ROUNDNESS_JITTER 0.15

// Fraction of its full width a blade keeps on screen when seen edge-on.
#define BLADE_MIN_SCREEN_WIDTH_RATIO 0.5

struct BladeParams
{
    float height;
    float width;
    float bend;
    float tilt;
    float sideCurve;
};

// Cubic Bezier spine, with height as the root-to-tip distance:
//  - tilt (forward) and sideCurve (sideways) only set the tip's lean direction, as
//    offsets per unit of up, so they never change how far the tip is from the root;
//  - the midpoint lies on the root-to-tip line, pushed off it by "bend" (a fraction of
//    height) along the line's perpendicular (bend = 0 collapses the curve to a straight line);
//  - the two interior control points sit 2/3 of the way from each endpoint to the midpoint.
float3 GetBladeTip(BladeParams p)
{
    return p.height * normalize(float3(p.sideCurve, 1.0, p.tilt));
}

void GetBezierControlPoints(BladeParams p, out float3 root, out float3 p1, out float3 p2, out float3 tip)
{
    root = float3(0, 0, 0);
    tip = GetBladeTip(p);

    float3 dir = normalize(float3(p.sideCurve, 1.0, p.tilt));
    float3 perp = float3(0, dir.z, -dir.y) / length(dir.yz);

    float3 mid = tip * 0.5 + perp * p.bend * p.height;
    p1 = root + (mid - root) * (2.0 / 3.0);
    p2 = tip + (mid - tip) * (2.0 / 3.0);
}

float3 EvaluateCubicBezier(BladeParams p, float t)
{
    float3 root, p1, p2, tip;
    GetBezierControlPoints(p, root, p1, p2, tip);

    float u = 1.0 - t;
    return u * u * u * root
         + 3.0 * u * u * t * p1
         + 3.0 * u * t * t * p2
         + t * t * t * tip;
}

// Derivative of the same curve, i.e. the spine's tangent direction at t.
float3 EvaluateCubicBezierTangent(BladeParams p, float t)
{
    float3 root, p1, p2, tip;
    GetBezierControlPoints(p, root, p1, p2, tip);

    float u = 1.0 - t;
    float3 tangent = 3.0 * u * u * (p1 - root)
                    + 6.0 * u * t * (p2 - p1)
                    + 3.0 * t * t * (tip - p2);

    float len = length(tangent);
    return len > 1e-6 ? tangent / len : float3(0, 1, 0);
}

float GetBladeWidthAt(BladeParams p, float t)
{
    return 0.5 * p.width * (1.0 - t);
}

float GetBladeHeightPercent(uint stripIndex)
{
#if defined(_GRASS_LOD_LOW)
    return stripIndex == 2 ? 1.0 : 0.0;
#else
    bool isTip = stripIndex == (BLADE_STRIP_VERTEX_COUNT - 1);
    uint row = stripIndex / 2;
    return isTip ? 1.0 : row / (float)BLADE_ROW_COUNT;
#endif
}

// Signed distance from the spine along the blade's right axis; the tip apex has none.
float GetBladeLateralOffset(BladeParams p, uint stripIndex)
{
#if defined(_GRASS_LOD_LOW)
    if (stripIndex == 2)
        return 0.0;

    float sideSign = (stripIndex == 0) ? -1.0 : 1.0;
    return sideSign * GetBladeWidthAt(p, 0.0);
#else
    bool isTip = stripIndex == (BLADE_STRIP_VERTEX_COUNT - 1);
    if (isTip)
        return 0.0;

    float sideSign = (stripIndex % 2 == 0) ? -1.0 : 1.0;
    return sideSign * GetBladeWidthAt(p, (stripIndex / 2) / (float)BLADE_ROW_COUNT);
#endif
}

// The strip's actual position logic. stripIndex is in [0, BLADE_STRIP_VERTEX_COUNT).
float3 GetStripVertexPosition(BladeParams p, uint stripIndex)
{
    float3 lateral = float3(GetBladeLateralOffset(p, stripIndex), 0, 0);
#if defined(_GRASS_LOD_LOW)
    return stripIndex == 2 ? GetBladeTip(p) : lateral;
#else
    // The final vertex (14) is the single tip apex where the strip converges.
    return EvaluateCubicBezier(p, GetBladeHeightPercent(stripIndex)) + lateral;
#endif
}

float3 GetBladeLocalPosition(BladeParams p, uint stripIndex)
{
    return GetStripVertexPosition(p, stripIndex);
}

float3 RotateAroundY(float3 v, float angle)
{
    float s, c;
    sincos(angle, s, c);
    return float3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

// Local-space normal for the fake-round grass blade: perpendicular to the spine's
// tangent, then rotated outward per side to fake a rounded cross-section.
float3 GetBladeLocalNormal(BladeParams p, uint stripIndex, uint bladeHash)
{
#if defined(_GRASS_LOD_LOW)
    float2 chordYZ = GetBladeTip(p).yz;
    float chordLen = length(chordYZ);
    return chordLen > 1e-5 ? float3(0, -chordYZ.y, chordYZ.x) / chordLen : float3(0, 0, 1);
#else
    float t = GetBladeHeightPercent(stripIndex);
    float3 tangent = EvaluateCubicBezierTangent(p, t);

    float2 yz = float2(tangent.y, tangent.z);
    float yzLen = length(yz);
    float3 faceNormal = yzLen > 1e-5 ? float3(0, -yz.y, yz.x) / yzLen : float3(0, 0, 1);

    float sideSign = (stripIndex % 2 == 0) ? -1.0 : 1.0;
    float jitter = HashToSigned(bladeHash, 30) * BLADE_ROUNDNESS_JITTER;
    float angle = sideSign * (BLADE_ROUNDNESS_ANGLE + jitter);

    return RotateAroundY(faceNormal, angle);
#endif
}

float3 GetBladeRightWS(float2 facing)
{
    return normalize(float3(facing.x, 0, facing.y));
}

// Builds the blade's world-space orientation from its facing direction.
float3 ApplyBladeOrientation(float3 localPos, float2 facing)
{
    float3 up = float3(0, 1, 0);
    float3 right = GetBladeRightWS(facing);
    float3 forward = cross(right, up);

    return right * localPos.x + up * localPos.y + forward * localPos.z;
}

#endif
