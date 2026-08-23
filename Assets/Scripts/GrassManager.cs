using System.Collections.Generic;
using UnityEngine;

public class GrassManager : MonoBehaviour
{
    [Header("Grid Settings")]
    public float worldSize = 200f;
    public float tileSize = 10f;
    public int grassPerAxisPerTile = 16; // E.g., 16x16 = 256 blades per tile

    [Header("Blade Shape - base values, randomized per-blade in Step 3")]
    public float bladeHeight = 1f;
    public float bladeWidth = 0.06f;
    public float bladeBend = 0.25f;
    public float bladeTilt = 1f;

    [Header("Per-Blade Randomization (Step 3)")]
    [Range(0f, 1f)] public float shapeVariance = 0.3f; // +/- fraction of base height/width/bend/tilt
    public float sideCurveStrength = 0.05f;            // max random sideways curve magnitude
    [Range(0f, 1f)] public float jitterStrength = 1f;  // fraction of grid step used as position jitter

    [Header("References")]
    public Camera mainCamera;
    public ComputeShader grassBuilderCS;
    public Material grassMaterial;

    public struct TileData { public Vector3 center; public uint tileId; }

    // Bytes: center(12) + tileId(4) = 16.
    private const int tileDataStride = 16;
    public struct GrassData
    {
        public Vector3 position;
        public Vector2 facing;
        public float height;
        public float width;
        public float tilt;
        public float bend;
        public float sideCurve;
    }

    // Bytes: position(12) + facing(8) + height/width/tilt/bend/sideCurve(5*4=20) = 40.
    private const int grassDataStride = 40;

    private Bounds[] tileBounds;
    private TileData[] allTiles;
    private List<TileData> visibleTilesList;
    private readonly Plane[] cameraFrustumPlanes = new Plane[6];

    // Buffers
    private GraphicsBuffer visibleTilesBuffer;
    private GraphicsBuffer grassDataBuffer;
    private GraphicsBuffer argsBuffer;

    private int numTilesPerAxis;
    private int totalTiles;
    private int buildKernel;

    // Must match BLADE_VERTEX_COUNT in Assets/Shaders/GrassBladeSpine.hlsl
    // (15-vertex strip expanded into a non-indexed triangle list: 13 tris * 3 = 39).
    private const uint bladeVertexCount = 39;

    void Start()
    {
        if (mainCamera == null) mainCamera = Camera.main;

        buildKernel = grassBuilderCS.FindKernel("BuildGrass");

        InitializeGrid();
        InitializeBuffers();
    }

    private void InitializeGrid()
    {
        numTilesPerAxis = Mathf.CeilToInt(worldSize / tileSize);
        totalTiles = numTilesPerAxis * numTilesPerAxis;

        tileBounds = new Bounds[totalTiles];
        allTiles = new TileData[totalTiles];
        visibleTilesList = new List<TileData>(totalTiles);

        // Starts at the negative x and negative z corner based on the world size
        Vector3 startPos = transform.position - new Vector3(worldSize / 2f, 0, worldSize / 2f) + new Vector3(tileSize / 2f, 0, tileSize / 2f);

        int index = 0;
        for (int x = 0; x < numTilesPerAxis; x++)
        {
            for (int z = 0; z < numTilesPerAxis; z++)
            {
                Vector3 center = startPos + new Vector3(x * tileSize, 0, z * tileSize);
                tileBounds[index] = new Bounds(center, new Vector3(tileSize, 5f, tileSize));
                allTiles[index] = new TileData { center = center, tileId = (uint)index };
                index++;
            }
        }
    }

    private void InitializeBuffers()
    {
        visibleTilesBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, totalTiles, tileDataStride);
        
        // Max possible grass blades
        int maxGrassCount = totalTiles * grassPerAxisPerTile * grassPerAxisPerTile;
        
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

    private void OnDrawGizmos()
    {
        // Draw the grid in the editor for visualization
        if (tileBounds == null) return;

        for (int i = 0; i < totalTiles; i++)
        {
            bool isVisible = GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, tileBounds[i]);
            Gizmos.color = isVisible ? new Color(0f, 1f, 0f, 0.35f) : new Color(1f, 0f, 0f, 0.15f);
            Gizmos.DrawWireCube(tileBounds[i].center, tileBounds[i].size);
        }
    }

    void Update()
    {
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

        for (int i = 0; i < totalTiles; i++)
        {
            if (GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, tileBounds[i]))
            {
                visibleTilesList.Add(allTiles[i]);
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

        // Dispatch threads based on visible tiles
        int threadGroups = Mathf.CeilToInt(grassPerAxisPerTile / 8f);

        // Execute the BuildGrass compute shader 
        grassBuilderCS.Dispatch(buildKernel, threadGroups, threadGroups, visibleTilesList.Count);
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

        // Draw instances blindly using our args buffer
        Bounds bounds = new Bounds(transform.position, new Vector3(worldSize, worldSize, worldSize));
        Graphics.DrawProceduralIndirect(grassMaterial, bounds, MeshTopology.Triangles, argsBuffer, 0, null, null, UnityEngine.Rendering.ShadowCastingMode.Off, true, gameObject.layer);
    }

    private void OnDestroy()
    {
        visibleTilesBuffer?.Release();
        grassDataBuffer?.Release();
        argsBuffer?.Release();
    }
}