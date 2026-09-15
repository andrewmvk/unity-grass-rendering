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

struct BladeParams
{
    float height;
    float width;
    float bend;
    float tilt;
    float sideCurve;
};

// Cubic Bezier spine:
//  - the tip sits at a height/tilt offset from the root (facing is applied after);
//  - the midpoint lies on the root-to-tip line, pushed off it by "bend" along the
//    line's perpendicular (bend = 0 collapses the curve to a straight line);
//  - the two interior control points sit 2/3 of the way from each endpoint to the midpoint;
//  - sideCurve is applied after this tilt/bend curve.
void GetBezierControlPoints(BladeParams p, out float3 root, out float3 p1, out float3 p2, out float3 tip)
{
    root = float3(0, 0, 0);
    tip = float3(0, p.height, p.tilt);

    float3 toTip = tip - root;
    float toTipLen = length(toTip);
    float3 dir = toTipLen > 1e-6 ? toTip / toTipLen : float3(0, 1, 0);
    float3 up = float3(0, 1, 0);
    float3 perp = up - dot(up, dir) * dir;
    float perpLen = length(perp);
    perp = perpLen > 1e-5 ? perp / perpLen : float3(0, 0, 1);

    float3 mid = lerp(root, tip, 0.5) + perp * p.bend;
    p1 = root + (mid - root) * (2.0 / 3.0);
    p2 = tip + (mid - tip) * (2.0 / 3.0);
}

float3 EvaluateCubicBezier(BladeParams p, float t)
{
    float3 root, p1, p2, tip;
    GetBezierControlPoints(p, root, p1, p2, tip);

    float u = 1.0 - t;
    float3 curvePos = u * u * u * root
                     + 3.0 * u * u * t * p1
                     + 3.0 * u * t * t * p2
                     + t * t * t * tip;

    // root/tip/mid/p1/p2 all have x = 0, so curvePos.x is always 0 here.
    curvePos.x = p.sideCurve * t;
    return curvePos;
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
    tangent.x = p.sideCurve;

    float len = length(tangent);
    return len > 1e-6 ? tangent / len : float3(0, 1, 0);
}

float GetBladeWidthAt(BladeParams p, float t)
{
    return p.width * (1.0 - t);
}

// The strip's actual position logic. stripIndex is in [0, BLADE_STRIP_VERTEX_COUNT).
float3 GetStripVertexPosition(BladeParams p, uint stripIndex)
{
#if defined(_GRASS_LOD_LOW)
    bool isTip = stripIndex == 2;
    float t = isTip ? 1.0 : 0.0;
    float sideSign = (stripIndex == 0) ? -1.0 : 1.0;
#else
    uint row = stripIndex / 2;
    uint side = stripIndex % 2;

    // The final vertex (14) is the single tip apex where the strip converges.
    bool isTip = stripIndex == (BLADE_STRIP_VERTEX_COUNT - 1);
    float t = isTip ? 1.0 : row / (float)BLADE_ROW_COUNT;
    float sideSign = (side == 0) ? -1.0 : 1.0;
#endif

    float3 center = EvaluateCubicBezier(p, t);
    float width = isTip ? 0.0 : GetBladeWidthAt(p, t);
    return center + float3(sideSign * width, 0, 0);
}

float3 GetBladeLocalPosition(BladeParams p, uint stripIndex)
{
    return GetStripVertexPosition(p, stripIndex);
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
    float t = GetBladeHeightPercent(stripIndex);
    float3 tangent = EvaluateCubicBezierTangent(p, t);

    float2 yz = float2(tangent.y, tangent.z);
    float yzLen = length(yz);
    float3 faceNormal = yzLen > 1e-5 ? float3(0, -yz.y, yz.x) / yzLen : float3(0, 0, 1);

#if defined(_GRASS_LOD_LOW)
    return faceNormal;
#else
    float sideSign = (stripIndex % 2 == 0) ? -1.0 : 1.0;
    float jitter = HashToSigned(bladeHash, 30) * BLADE_ROUNDNESS_JITTER;
    float angle = sideSign * (BLADE_ROUNDNESS_ANGLE + jitter);

    return RotateAroundY(faceNormal, angle);
#endif
}

// Builds the blade's world-space orientation from its facing direction.
float3 ApplyBladeOrientation(float3 localPos, float2 facing)
{
    float3 up = float3(0, 1, 0);
    float3 right = normalize(float3(facing.x, 0, facing.y));
    float3 forward = cross(right, up);

    return right * localPos.x + up * localPos.y + forward * localPos.z;
}

#endif
