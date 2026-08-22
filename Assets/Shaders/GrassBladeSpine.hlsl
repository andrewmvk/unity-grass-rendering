#ifndef GRASS_BLADE_SPINE_INCLUDED
#define GRASS_BLADE_SPINE_INCLUDED

// 15-vertex strip: 7 tapering left/right pairs + 1 tip.
// Expanded to 39 non-indexed vertices (13 triangles), since
// DrawProceduralIndirect has no triangle-strip topology.
#define BLADE_ROW_COUNT 7
#define BLADE_STRIP_VERTEX_COUNT 15
#define BLADE_TRIANGLE_COUNT (BLADE_STRIP_VERTEX_COUNT - 2)
#define BLADE_VERTEX_COUNT (BLADE_TRIANGLE_COUNT * 3)

static const float _BladeBaseWidth = 0.06;
static const float _BladeHeight = 0.5;
static const float _BladeBend = 0.25;
static const float _BladeTilt = 0.08;

// Cubic Bezier spine control points, built from base/bend/tilt.
// The curve lives in the local YZ plane (Y = up along the blade, Z = lean/bend direction).
float3 GetBladeControlPoint(int i)
{
    if (i == 0) return float3(0, 0, 0);
    if (i == 1) return float3(0, _BladeHeight * 0.33, _BladeTilt * 0.5);
    if (i == 2) return float3(0, _BladeHeight * 0.66, _BladeTilt * 0.8 + _BladeBend * 0.5);
    return float3(0, _BladeHeight, _BladeTilt + _BladeBend);
}

float3 EvaluateCubicBezier(float t)
{
    float3 p0 = GetBladeControlPoint(0);
    float3 p1 = GetBladeControlPoint(1);
    float3 p2 = GetBladeControlPoint(2);
    float3 p3 = GetBladeControlPoint(3);

    float u = 1.0 - t;
    return u * u * u * p0
         + 3.0 * u * u * t * p1
         + 3.0 * u * t * t * p2
         + t * t * t * p3;
}

float GetBladeWidthAt(float t)
{
    return _BladeBaseWidth * (1.0 - t);
}

// The 15-vertex strip's actual position logic. stripIndex is in [0, BLADE_STRIP_VERTEX_COUNT).
float3 GetStripVertexPosition(uint stripIndex)
{
    uint row = stripIndex / 2;
    uint side = stripIndex % 2;

    // The final vertex (14) is the single tip apex where the strip converges.
    bool isTip = stripIndex == (BLADE_STRIP_VERTEX_COUNT - 1);
    float t = isTip ? 1.0 : row / (float)BLADE_ROW_COUNT;

    float3 center = EvaluateCubicBezier(t);
    float width = isTip ? 0.0 : GetBladeWidthAt(t);

    float sideSign = (side == 0) ? -1.0 : 1.0;
    return center + float3(sideSign * width, 0, 0);
}

// Expands the 15-vertex strip into a non-indexed triangle list.
// vertexID must be in [0, BLADE_VERTEX_COUNT) i.e. [0, BLADE_TRIANGLE_COUNT * 3).
float3   (uint vertexID)
{
    uint triangleIndex = vertexID / 3;
    uint corner = vertexID % 3;
    uint stripIndex = triangleIndex + corner;
    return GetStripVertexPosition(stripIndex);
}

#endif