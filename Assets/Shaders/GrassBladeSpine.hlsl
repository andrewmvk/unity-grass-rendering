#ifndef GRASS_BLADE_SPINE_INCLUDED
#define GRASS_BLADE_SPINE_INCLUDED

// 15-vertex strip: 7 tapering left/right pairs + 1 tip.
// Expanded to 39 non-indexed vertices (13 triangles), since
// DrawProceduralIndirect has no triangle-strip topology.
#define BLADE_ROW_COUNT 7
#define BLADE_STRIP_VERTEX_COUNT 15
#define BLADE_TRIANGLE_COUNT (BLADE_STRIP_VERTEX_COUNT - 2)
#define BLADE_VERTEX_COUNT (BLADE_TRIANGLE_COUNT * 3)

struct BladeParams
{
    float height;
    float width;
    float bend;
    float tilt;
    float sideCurve;
};

// Cubic Bezier spine:
//  - the tip sits at a height/tilt-derived offset from the root (facing is applied
//    afterwards);
//  - the midpoint lies on the root-to-tip line, pushed off it by "bend" along the
//    perpendicular to that line (so bend=0 collapses the curve onto a straight line);
//  - the two interior cubic control points sit 2/3 of the way from each endpoint
//    to that midpoint.
//  - sideCurve is applied after the tilt/bend curve below.
float3 EvaluateCubicBezier(BladeParams p, float t)
{
    float3 root = float3(0, 0, 0);
    float3 tip = float3(0, p.height, p.tilt);

    float3 toTip = tip - root;
    float toTipLen = length(toTip);
    float3 dir = toTipLen > 1e-6 ? toTip / toTipLen : float3(0, 1, 0);
    float3 up = float3(0, 1, 0);
    float3 perp = up - dot(up, dir) * dir;
    float perpLen = length(perp);
    perp = perpLen > 1e-5 ? perp / perpLen : float3(0, 0, 1);

    float3 mid = lerp(root, tip, 0.5) + perp * p.bend;

    float3 p1 = root + (mid - root) * (2.0 / 3.0);
    float3 p2 = tip + (mid - tip) * (2.0 / 3.0);

    float u = 1.0 - t;
    float3 curvePos = u * u * u * root
                     + 3.0 * u * u * t * p1
                     + 3.0 * u * t * t * p2
                     + t * t * t * tip;

    // root/tip/mid/p1/p2 all have x = 0, so curvePos.x is always 0 here.
    curvePos.x = p.sideCurve * t;
    return curvePos;
}

float GetBladeWidthAt(BladeParams p, float t)
{
    return p.width * (1.0 - t);
}

// The 15-vertex strip's actual position logic. stripIndex is in [0, BLADE_STRIP_VERTEX_COUNT).
float3 GetStripVertexPosition(BladeParams p, uint stripIndex)
{
    uint row = stripIndex / 2;
    uint side = stripIndex % 2;

    // The final vertex (14) is the single tip apex where the strip converges.
    bool isTip = stripIndex == (BLADE_STRIP_VERTEX_COUNT - 1);
    float t = isTip ? 1.0 : row / (float)BLADE_ROW_COUNT;

    float3 center = EvaluateCubicBezier(p, t);
    float width = isTip ? 0.0 : GetBladeWidthAt(p, t);

    float sideSign = (side == 0) ? -1.0 : 1.0;
    return center + float3(sideSign * width, 0, 0);
}

// Expands the 15-vertex strip into a non-indexed triangle list.
// vertexID must be in [0, BLADE_VERTEX_COUNT) i.e. [0, BLADE_TRIANGLE_COUNT * 3).
float3 GetBladeLocalPosition(BladeParams p, uint vertexID)
{
    uint triangleIndex = vertexID / 3;
    uint corner = vertexID % 3;
    uint stripIndex = triangleIndex + corner;
    return GetStripVertexPosition(p, stripIndex);
}

// Rotates a blade-local position around the vertical (Y) axis so the blade
// points along "facing" (a normalized 2D direction in the world XZ plane).
float3 ApplyBladeFacing(float3 localPos, float2 facing)
{
    float rotatedX = localPos.x * facing.x - localPos.z * facing.y;
    float rotatedZ = localPos.x * facing.y + localPos.z * facing.x;
    return float3(rotatedX, localPos.y, rotatedZ);
}

#endif
