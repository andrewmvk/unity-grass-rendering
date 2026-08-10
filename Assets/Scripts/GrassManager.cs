using System.Collections.Generic;
using UnityEngine;

public class GrassManager : MonoBehaviour
{
    [Header("Grid Settings")]
    public float worldSize = 200f; // Total size of the world (worldSize x worldSize)
    public float tileSize = 10f;   // Size of each tile
    
    [Header("References")]
    public Camera mainCamera;

    // Data structure to send to the GPU
    public struct TileData
    {
        public Vector3 center;
    }

    private Bounds[] tileBounds;
    private TileData[] allTiles;
    private List<TileData> visibleTilesList;
    private Plane[] cameraFrustumPlanes;

    // Buffer to hold visible tiles for the Compute Shader
    private GraphicsBuffer visibleTilesBuffer;

    private int numTilesPerAxis;
    private int totalTiles;

    void Start()
    {
        mainCamera ??= Camera.main;

        InitializeGrid();
    }

    private void InitializeGrid()
    {
        numTilesPerAxis = Mathf.CeilToInt(worldSize / tileSize);
        totalTiles = numTilesPerAxis * numTilesPerAxis;

        tileBounds = new Bounds[totalTiles];
        allTiles = new TileData[totalTiles];
        visibleTilesList = new List<TileData>(totalTiles);

        // Center the grid around the GameObject's position
        Vector3 startPos = transform.position - new Vector3(worldSize / 2f, 0, worldSize / 2f) + new Vector3(tileSize / 2f, 0, tileSize / 2f);

        int index = 0;
        for (int x = 0; x < numTilesPerAxis; x++)
        {
            for (int z = 0; z < numTilesPerAxis; z++)
            {
                Vector3 center = startPos + new Vector3(x * tileSize, 0, z * tileSize);
                
                // Assuming a flat world for now; give it a height of 5 units for frustum culling tolerance
                Vector3 size = new Vector3(tileSize, 5f, tileSize); 
                
                tileBounds[index] = new Bounds(center, size);
                allTiles[index] = new TileData { center = center };
                index++;
            }
        }

        // Initialize the GraphicsBuffer (stride is 12 bytes because Vector3 is 3 floats * 4 bytes)
        visibleTilesBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, totalTiles, 12);
    }

    void Update()
    {
        PerformCPUCulling();
    }

    private void PerformCPUCulling()
    {
        visibleTilesList.Clear();
        cameraFrustumPlanes = GeometryUtility.CalculateFrustumPlanes(mainCamera);

        for (int i = 0; i < totalTiles; i++)
        {
            // Test if the tile's bounding box is within the camera's frustum
            if (GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, tileBounds[i]))
            {
                visibleTilesList.Add(allTiles[i]);
            }
        }

        // Upload visible tiles to the GPU buffer
        if (visibleTilesList.Count > 0)
        {
            visibleTilesBuffer.SetData(visibleTilesList);
        }
    }

    private void OnDrawGizmosSelected()
    {
        // Draw the grid in the editor for visualization
        if (tileBounds == null || cameraFrustumPlanes == null) return;

        for (int i = 0; i < totalTiles; i++)
        {
            bool isVisible = GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, tileBounds[i]);
            Gizmos.color = isVisible ? new Color(0, 1, 0, 0.3f) : new Color(1, 0, 0, 0.1f);
            Gizmos.DrawWireCube(tileBounds[i].center, tileBounds[i].size);
        }
    }

    private void OnDestroy()
    {
        visibleTilesBuffer?.Release();
        visibleTilesBuffer = null;
    }
}