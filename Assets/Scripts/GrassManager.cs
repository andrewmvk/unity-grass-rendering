using System.Collections.Generic;
using UnityEngine;

public class GrassManager : MonoBehaviour
{
    [Header("Grid Settings")]
    public float worldSize = 200f;
    public float tileSize = 10f;
    public int grassPerAxisPerTile = 16; // E.g., 16x16 = 256 blades per tile

    [Header("References")]
    public Camera mainCamera;
    public ComputeShader grassBuilderCS;
    public ComputeShader grassCounterCS;
    public Material grassMaterial;

    public struct TileData { public Vector3 center; }
    public struct GrassData { public Vector3 position; }

    private Bounds[] tileBounds;
    private TileData[] allTiles;
    private List<TileData> visibleTilesList;
    private Plane[] cameraFrustumPlanes;

    // Buffers
    private GraphicsBuffer visibleTilesBuffer;
    private GraphicsBuffer grassDataBuffer;
    private GraphicsBuffer argsBuffer;
    private GraphicsBuffer countBuffer;

    private int numTilesPerAxis;
    private int totalTiles;
    private int buildKernel;
    private int countKernel;

    void Start()
    {
        if (mainCamera == null) mainCamera = Camera.main;

        buildKernel = grassBuilderCS.FindKernel("BuildGrass");
        countKernel = grassCounterCS.FindKernel("PrepareArgs");

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
                allTiles[index] = new TileData { center = center };
                index++;
            }
        }
    }

    private void InitializeBuffers()
    {
        visibleTilesBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, totalTiles, 12);
        
        // Max possible grass blades
        int maxGrassCount = totalTiles * grassPerAxisPerTile * grassPerAxisPerTile;
        
        // Append buffer for grass instances (stride = 12 bytes for Vector3 position)
        grassDataBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Append, maxGrassCount, 12);
        
        // Buffer to hold the extracted count from the append buffer
        countBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Raw, 1, 4);
        
        // Indirect Draw Arguments buffer (5 uints)
        argsBuffer = new GraphicsBuffer(GraphicsBuffer.Target.IndirectArguments, 1, 5 * sizeof(uint));
        uint[] args = new uint[] { 3, 0, 0, 0, 0 };
        /* 
        * 1 - Vertex count per instance: 3
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
        if (tileBounds == null || cameraFrustumPlanes == null) return;

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
        cameraFrustumPlanes = GeometryUtility.CalculateFrustumPlanes(mainCamera);

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

        // Dispatch threads based on visible tiles
        int threadGroups = Mathf.CeilToInt(grassPerAxisPerTile / 8f);

        // Execute the BuildGrass compute shader 
        grassBuilderCS.Dispatch(buildKernel, threadGroups, threadGroups, visibleTilesList.Count);
    }

    private void PrepareIndirectArgs()
    {
        // 1. Copy the internal counter of the Append buffer to our standard buffer
        GraphicsBuffer.CopyCount(grassDataBuffer, countBuffer, 0);

        // 2. Dispatch CS2 to read the count and insert it into the argsBuffer
        grassCounterCS.SetBuffer(countKernel, "_CountBuffer", countBuffer);
        grassCounterCS.SetBuffer(countKernel, "_ArgsBuffer", argsBuffer);
        grassCounterCS.Dispatch(countKernel, 1, 1, 1);
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
        countBuffer?.Release();
    }
}