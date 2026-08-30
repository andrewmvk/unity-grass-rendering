using System.Collections.Generic;
using System.Runtime.InteropServices;
using UnityEngine;

public class GrassManager : MonoBehaviour
{
    [Header("Grid Streaming Settings")]
    [Tooltip("Tiles stream in/out around this transform. Defaults to Main Camera if left empty.")]
    public Transform followTarget;
    public float tileSize = 10f;
    public int grassPerAxisPerTile = 16; // E.g., 16x16 = 256 blades per tile
    [Tooltip("Render distance expressed in tiles (radius). Tiles further than this from followTarget are unloaded.")]
    public int renderDistanceInTiles = 8;

    [Header("Terrain (optional)")]
    [Tooltip("When assigned, blades are placed on this terrain's surface and tile AABBs hug its height. When empty, grass stays flat at y=0.")]
    public Terrain terrain;

    [Header("Fallback World Extent (used only without a Terrain)")]
    [Tooltip("Size of the square region the control-texture mapping and fallback tile-height AABB use when no Terrain is assigned.")]
    public float worldSize = 200f;

    [Header("Blade Shape - base values")]
    public float bladeHeight = 1f;
    public float bladeWidth = 0.06f;
    public float bladeBend = 0.25f;
    public float bladeTilt = 1f;

    [Header("Per-Blade Randomization")]
    [Range(0f, 1f)] public float shapeVariance = 0.3f; // +/- fraction of base height/width/bend/tilt
    public float sideCurveStrength = 0.05f;            // max random sideways curve magnitude
    [Range(0f, 1f)] public float jitterStrength = 1f;  // fraction of grid step used as position jitter

    [Header("Fine Culling")]
    [Tooltip("Single-channel mask; >0.5 = grass allowed. Left empty, a 1x1 white texture is used (grass allowed everywhere).")]
    public Texture2D controlTexture;

    [Header("References")]
    public Camera mainCamera;
    public ComputeShader grassBuilderCS;
    public Material grassMaterial;

    // Must be kept in sync with TileData in Assets/Shaders/GrassStructs.hlsl, this forces .NET to not reorder the fields in memory
    [StructLayout(LayoutKind.Sequential)]
    public struct TileData { public Vector3 center; public uint tileId; }
    private static readonly int tileDataStride = Marshal.SizeOf<TileData>();

    // GrassData itself is populated entirely on the GPU. Only the byte stride is needed here to size the buffer (manually).
    private const int grassDataStride = 68;

    private struct TileEntry { public TileData data; public Bounds bounds; }

    // Streamed tile pool, keyed by stable grid coordinate (independent of load/unload order).
    private Dictionary<Vector2Int, TileEntry> activeTiles;
    private HashSet<Vector2Int> desiredCoords;
    private List<Vector2Int> coordsToRemove;

    private List<TileData> visibleTilesList;
    private readonly Plane[] cameraFrustumPlanes = new Plane[6];

    // Buffers
    private GraphicsBuffer visibleTilesBuffer;
    private GraphicsBuffer grassDataBuffer;
    private GraphicsBuffer argsBuffer;

    private int maxTilesInView;
    private int buildKernel;
    private Texture2D defaultControlTexture;
    private Texture2D defaultHeightmapTexture;
    private Vector4[] frustumPlaneVectors;

    // Must match BLADE_VERTEX_COUNT in Assets/Shaders/GrassBladeSpine.hlsl
    // (15-vertex strip expanded into a non-indexed triangle list: 13 tris * 3 = 39).
    private const uint bladeVertexCount = 39;

    void Start()
    {
        if (mainCamera == null) mainCamera = Camera.main;
        if (followTarget == null) followTarget = mainCamera.transform;

        buildKernel = grassBuilderCS.FindKernel("BuildGrass");

        if (controlTexture == null)
        {
            defaultControlTexture = new Texture2D(1, 1, TextureFormat.R8, false);
            defaultControlTexture.SetPixel(0, 0, Color.white);
            defaultControlTexture.Apply();
        }

        if (terrain == null)
        {
            defaultHeightmapTexture = new Texture2D(1, 1, TextureFormat.R8, false);
            defaultHeightmapTexture.SetPixel(0, 0, Color.black);
            defaultHeightmapTexture.Apply();
        }

        frustumPlaneVectors = new Vector4[6];

        InitializeStreamingPool();
        InitializeBuffers();
    }

    private void InitializeStreamingPool()
    {
        int span = renderDistanceInTiles * 2 + 1;
        maxTilesInView = span * span;

        activeTiles = new Dictionary<Vector2Int, TileEntry>(maxTilesInView);
        desiredCoords = new HashSet<Vector2Int>(maxTilesInView);
        coordsToRemove = new List<Vector2Int>(maxTilesInView);
        visibleTilesList = new List<TileData>(maxTilesInView);
    }

    private void InitializeBuffers()
    {
        visibleTilesBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, maxTilesInView, tileDataStride);

        // Max possible grass blades: every currently-streamed tile, fully dense.
        int maxGrassCount = maxTilesInView * grassPerAxisPerTile * grassPerAxisPerTile;

        // Append buffer for grass instances
        grassDataBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Append, maxGrassCount, grassDataStride);

        // Indirect Draw Arguments buffer (5 uints)
        argsBuffer = new GraphicsBuffer(GraphicsBuffer.Target.IndirectArguments, 1, 5 * sizeof(uint));
        uint[] args = new uint[] { bladeVertexCount, 0, 0, 0, 0 };
        /*
        * 1 - Vertex count per instance: bladeVertexCount (must match BLADE_VERTEX_COUNT in GrassBladeSpine.hlsl)
        * 2 - Instance count: initaliy 0
        * 3 - Start vertex: 0
        * 4 - Start instance: 0
        * 5 - Padding or unused value
        */
        argsBuffer.SetData(args);
    }

    // Encodes a (possibly negative) tile grid coordinate into a stable uint id,
    // so a tile's random seed only depends on its position, not on load order.
    private static uint EncodeTileId(Vector2Int coord)
    {
        uint ux = (uint)(coord.x + 32768);
        uint uz = (uint)(coord.y + 32768);
        return (ux << 16) | (uz & 0xFFFF);
    }

    private void UpdateTileStreaming()
    {
        Vector3 followPos = followTarget.position;
        int centerX = Mathf.FloorToInt((followPos.x - transform.position.x) / tileSize);
        int centerZ = Mathf.FloorToInt((followPos.z - transform.position.z) / tileSize);

        desiredCoords.Clear();
        for (int dx = -renderDistanceInTiles; dx <= renderDistanceInTiles; dx++)
        {
            for (int dz = -renderDistanceInTiles; dz <= renderDistanceInTiles; dz++)
            {
                Vector2Int coord = new Vector2Int(centerX + dx, centerZ + dz);
                desiredCoords.Add(coord);

                if (!activeTiles.ContainsKey(coord))
                {
                    activeTiles.Add(coord, LoadTile(coord));
                }
            }
        }

        coordsToRemove.Clear();
        foreach (KeyValuePair<Vector2Int, TileEntry> kvp in activeTiles)
        {
            if (!desiredCoords.Contains(kvp.Key))
            {
                coordsToRemove.Add(kvp.Key);
            }
        }
        for (int i = 0; i < coordsToRemove.Count; i++)
        {
            activeTiles.Remove(coordsToRemove[i]);
        }
    }

    private TileEntry LoadTile(Vector2Int coord)
    {
        float centerX = transform.position.x + (coord.x + 0.5f) * tileSize;
        float centerZ = transform.position.z + (coord.y + 0.5f) * tileSize;

        (float minY, float maxY) = SampleTileHeightRange(centerX, centerZ);

        // Pad the vertical extent so grown blades (root already at minY..maxY)
        // still fit fully inside the AABB used for CPU frustum culling.
        float verticalPadding = 2f * ComputeBladeBoundingRadius();
        Bounds bounds = new Bounds(
            new Vector3(centerX, (minY + maxY) * 0.5f, centerZ),
            new Vector3(tileSize, Mathf.Max(0.01f, maxY - minY) + verticalPadding, tileSize));

        TileData data = new TileData
        {
            center = new Vector3(centerX, 0f, centerZ), // y is resolved per-blade from the heightmap on the GPU
            tileId = EncodeTileId(coord)
        };

        return new TileEntry { data = data, bounds = bounds };
    }

    private (float minY, float maxY) SampleTileHeightRange(float centerX, float centerZ)
    {
        if (terrain == null)
        {
            // Preserves the old fixed-height assumption used before Step 7.
            return (-2.5f, 2.5f);
        }

        float half = tileSize * 0.5f;
        float minY = float.MaxValue;
        float maxY = float.MinValue;

        for (int sx = -1; sx <= 1; sx++)
        {
            for (int sz = -1; sz <= 1; sz++)
            {
                Vector3 samplePos = new Vector3(centerX + sx * half, 0f, centerZ + sz * half);
                float h = terrain.SampleHeight(samplePos) + terrain.transform.position.y;
                minY = Mathf.Min(minY, h);
                maxY = Mathf.Max(maxY, h);
            }
        }

        return (minY, maxY);
    }

    private void OnDrawGizmos()
    {
        // Draw the streamed tile pool in the editor for visualization
        if (activeTiles == null) return;

        foreach (TileEntry entry in activeTiles.Values)
        {
            bool isVisible = GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, entry.bounds);
            Gizmos.color = isVisible ? new Color(0f, 1f, 0f, 0.35f) : new Color(1f, 0f, 0f, 0.15f);
            Gizmos.DrawWireCube(entry.bounds.center, entry.bounds.size);
        }
    }

    void Update()
    {
        UpdateTileStreaming();
        PerformCPUCulling();

        if (visibleTilesList.Count > 0)
        {
            DispatchGrassBuilder();
            PrepareIndirectArgs();
            RenderGrass();
        }
    }

    private void PerformCPUCulling()
    {
        visibleTilesList.Clear();
        GeometryUtility.CalculateFrustumPlanes(mainCamera, cameraFrustumPlanes);

        foreach (TileEntry entry in activeTiles.Values)
        {
            if (GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, entry.bounds))
            {
                visibleTilesList.Add(entry.data);
            }
        }

        if (visibleTilesList.Count > 0)
        {
            visibleTilesBuffer.SetData(visibleTilesList);
        }
    }

    private void DispatchGrassBuilder()
    {
        // Reset append buffer counter to 0
        grassDataBuffer.SetCounterValue(0);

        grassBuilderCS.SetBuffer(buildKernel, "_VisibleTiles", visibleTilesBuffer);
        grassBuilderCS.SetBuffer(buildKernel, "_GrassDataBuffer", grassDataBuffer);
        grassBuilderCS.SetFloat("_TileSize", tileSize);
        grassBuilderCS.SetInt("_GrassPerAxis", grassPerAxisPerTile);
        grassBuilderCS.SetFloat("_BaseHeight", bladeHeight);
        grassBuilderCS.SetFloat("_BaseWidth", bladeWidth);
        grassBuilderCS.SetFloat("_BaseBend", bladeBend);
        grassBuilderCS.SetFloat("_BaseTilt", bladeTilt);
        grassBuilderCS.SetFloat("_ShapeVariance", shapeVariance);
        grassBuilderCS.SetFloat("_SideCurveStrength", sideCurveStrength);
        grassBuilderCS.SetFloat("_JitterStrength", jitterStrength);

        for (int i = 0; i < 6; i++)
        {
            Plane plane = cameraFrustumPlanes[i];
            frustumPlaneVectors[i] = new Vector4(plane.normal.x, plane.normal.y, plane.normal.z, plane.distance);
        }
        grassBuilderCS.SetVectorArray("_FrustumPlanes", frustumPlaneVectors);
        grassBuilderCS.SetFloat("_BladeBoundingRadius", ComputeBladeBoundingRadius());

        grassBuilderCS.SetTexture(buildKernel, "_ControlTexture", controlTexture != null ? controlTexture : defaultControlTexture);

        // Terrain sampling params are set as shader globals since GrassVertex.hlsl also reads them, to derive ground normals
        // for blade orientation at render time, done at GrassTerrainSampling.hlsl.
        bool useTerrain = terrain != null;
        Shader.SetGlobalFloat("_UseTerrainHeight", useTerrain ? 1f : 0f);

        if (useTerrain)
        {
            TerrainData data = terrain.terrainData;
            Shader.SetGlobalTexture("_HeightmapTexture", data.heightmapTexture);
            Shader.SetGlobalVector("_TerrainOriginXZ", new Vector4(terrain.transform.position.x, terrain.transform.position.z, 0, 0));
            Shader.SetGlobalVector("_TerrainSize", new Vector4(data.size.x, data.size.z, 0, 0));
            Shader.SetGlobalFloat("_TerrainBaseY", terrain.transform.position.y);
            Shader.SetGlobalFloat("_TerrainHeightScale", data.size.y * 2f);

            // The control mask paints over the same footprint as the terrain.
            grassBuilderCS.SetVector("_WorldOriginXZ", new Vector4(terrain.transform.position.x, terrain.transform.position.z, 0, 0));
            grassBuilderCS.SetVector("_WorldSize", new Vector4(data.size.x, data.size.z, 0, 0));
        }
        else
        {
            Shader.SetGlobalTexture("_HeightmapTexture", defaultHeightmapTexture);
            Shader.SetGlobalVector("_TerrainOriginXZ", Vector4.zero);
            Shader.SetGlobalVector("_TerrainSize", new Vector4(1, 1, 0, 0));
            Shader.SetGlobalFloat("_TerrainBaseY", 0f);
            Shader.SetGlobalFloat("_TerrainHeightScale", 0f);

            grassBuilderCS.SetVector("_WorldOriginXZ", new Vector4(transform.position.x - worldSize / 2f, transform.position.z - worldSize / 2f, 0, 0));
            grassBuilderCS.SetVector("_WorldSize", new Vector4(worldSize, worldSize, 0, 0));
        }

        // Dispatch threads based on visible tiles
        int threadGroups = Mathf.CeilToInt(grassPerAxisPerTile / 8f);

        // Execute the BuildGrass compute shader
        grassBuilderCS.Dispatch(buildKernel, threadGroups, threadGroups, visibleTilesList.Count);
    }

    // Worst-case root-to-vertex distance across all randomized blades, given the
    // current base shape params. Triangle-inequality upper bound: since a vertex is
    // root plus a sum of (height, tilt, bend, sideCurve, width) offsets, the sum of
    // their max magnitudes is guaranteed to be >= the true bounding radius.
    private float ComputeBladeBoundingRadius()
    {
        float maxHeight = bladeHeight * (1f + shapeVariance);
        float maxTilt = Mathf.Abs(bladeTilt) * (1f + shapeVariance);
        float maxBend = Mathf.Abs(bladeBend) * (1f + shapeVariance);
        float maxWidth = bladeWidth * (1f + shapeVariance);

        return maxHeight + maxTilt + maxBend + sideCurveStrength + maxWidth;
    }

    private void PrepareIndirectArgs()
    {
        // Copy the append buffer's internal counter directly into argsBuffer's
        GraphicsBuffer.CopyCount(grassDataBuffer, argsBuffer, 4);
    }

    private void RenderGrass()
    {
        // Pass the generated buffer to the rendering material
        grassMaterial.SetBuffer("_GrassDataBuffer", grassDataBuffer);
        
        float span = (renderDistanceInTiles * 2 + 1) * tileSize + 2f * ComputeBladeBoundingRadius();
        float centerY;
        float height;
        if (terrain != null)
        {
            centerY = terrain.transform.position.y + terrain.terrainData.size.y * 0.5f;
            height = terrain.terrainData.size.y + 2f * ComputeBladeBoundingRadius();
        }
        else
        {
            centerY = 0f;
            height = 10f;
        }

        Vector3 center = new Vector3(followTarget.position.x, centerY, followTarget.position.z);
        Bounds bounds = new Bounds(center, new Vector3(span, height, span));
        Graphics.DrawProceduralIndirect(grassMaterial, bounds, MeshTopology.Triangles, argsBuffer, 0, null, null, UnityEngine.Rendering.ShadowCastingMode.Off, true, gameObject.layer);
    }

    private void OnDestroy()
    {
        visibleTilesBuffer?.Release();
        grassDataBuffer?.Release();
        argsBuffer?.Release();

        if (defaultControlTexture != null) Destroy(defaultControlTexture);
        if (defaultHeightmapTexture != null) Destroy(defaultHeightmapTexture);
    }
}
