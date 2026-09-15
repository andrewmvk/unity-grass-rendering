using System.Collections.Generic;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;

public class GrassManager : MonoBehaviour
{
    // Worst-case bounds (Sucker Punch's approach). Buffers are sized for these once at
    // Start, so the sliders below can be tuned live without ever reallocating.
    private const int MaxGrassPerAxisPerTile = 64;
    private const int MaxRenderDistanceInTiles = 16;

    // Tile size in world units. Not a live-tunable field: changing it while playing
    // would invalidate every already-streamed tile's position and AABB.
    private const float TileSize = 10f;

    [Header("Grid Streaming Settings")]
    [SerializeField] [Tooltip("E.g. 16 = 16x16 = 256 blades per tile.")]
    [Range(1, MaxGrassPerAxisPerTile)] private int grassPerAxisPerTile = 16;
    [SerializeField] [Tooltip("Render distance expressed in tiles (radius). Tiles further than this from Main Camera are unloaded.")]
    [Range(1, MaxRenderDistanceInTiles)] private int renderDistanceInTiles = 8;
    [SerializeField] [Range(0.05f, 1f)] [Tooltip("Fraction of render distance where blades start shrinking toward zero height, reaching it exactly at render distance.")]
    private float heightFadeStartFraction = 0.75f;

    [Header("Geometric LOD")]
    [SerializeField] [Tooltip("Distance from camera beyond which blades switch from the full 15-vertex mesh to a simplified 3-vertex flat mesh.")]
    private float lodSwitchDistance = 20f;
    [SerializeField] [Tooltip("Blade curvature (bend) fades to 0 over this distance just before lodSwitchDistance, so the switch to the flat low-LOD shape is seamless.")]
    private float lodBendBlendDistance = 5f;
    
    [Header("Density LOD")]
    [SerializeField] [Tooltip("Distance from camera where blade density starts thinning, down to minDensityFraction at the render distance edge.")]
    private float densityFadeStartDistance = 20f;
    [SerializeField] [Range(0f, 1f)] [Tooltip("Fraction of blades kept at the render distance edge - the rest are stochastically dropped as density thins.")]
    private float minDensityFraction = 0.25f;

    [Header("Terrain")]
    [SerializeField] [Tooltip("Required. Blades are placed on this terrain's surface, follow its slope, and are masked by its painted layer-0 texture.")]
    private Terrain terrain;
    [SerializeField] [Range(0f, 1f)] [Tooltip("How strongly a blade's facing is pulled downhill as slope steepens (baked in once per blade at build time). 0 = always random facing, 1 = fully downhill on any slope. Blades themselves still grow straight up regardless of this value - see GrassBladeSpine.hlsl.")]
    private float slopeLeanStrength = 0.6f;

    [Header("Clumping")]
    [SerializeField] [Tooltip("World-space size of a Voronoi clump cell. Smaller = more, tighter patches.")]
    private float clumpSize = 3f;
    [SerializeField] [Range(0f, 1f)] [Tooltip("How far each clump's seed point can drift from its cell center, as a fraction of clump size. Keep <= 1 so the 3x3 neighbor search stays correct.")]
    private float clumpJitterStrength = 1f;
    [SerializeField] [Range(0f, 1f)] [Tooltip("How strongly a blade's facing is pulled toward its clump's shared facing direction. 0 = ignore clumping, 1 = fully comb toward the clump direction.")]
    private float clumpFacingStrength = 0.45f;
    [SerializeField] private Color clumpColorA = new Color(0.33f, 0.75f, 0.26f);
    [SerializeField] private Color clumpColorB = new Color(1f, 0.82f, 0.18f);
    [SerializeField] [Range(0f, 1f)] [Tooltip("How strongly the per-clump color tint is applied over the base hash-based tint.")]
    private float clumpColorStrength = 0.5f;
    [SerializeField] [Range(0f, 1f)] [Tooltip("How much shorter blades get the further they sit from their clump's center. 0 = uniform height, 1 = blades taper to minimum height at the clump cell edge.")]
    private float clumpHeightFalloff = 0.5f;
    [SerializeField] [Tooltip("Debug: renders each blade's raw clump color unlit, bypassing lighting, to visualize Voronoi cell boundaries.")]
    private bool debugClumpView = false;

    [Header("Blade Shape - base values")]
    [SerializeField] private float bladeHeight = 1f;
    [SerializeField] private float bladeWidth = 0.06f;
    [SerializeField] private float bladeBend = 0.25f;
    [SerializeField] private float bladeTilt = 1f;

    [Header("Per-Blade Randomization")]
    [SerializeField] [Range(0f, 1f)] private float shapeVariance = 0.3f; // +/- fraction of base height/width/bend/tilt
    [SerializeField] private float sideCurveStrength = 0.05f;            // max random sideways curve magnitude
    [SerializeField] [Range(0f, 1f)] private float jitterStrength = 1f;  // fraction of grid step used as position jitter

    [Header("Lighting")]
    [SerializeField] [Tooltip("Directional light driving diffuse/specular/subsurface. Falls back to a fixed direction if left empty.")]
    private Light sunLight;
    [SerializeField] [Range(0f, 4f)] private float lightIntensity = 1f;
    [SerializeField] private Color ambientColor = new Color(0.18f, 0.22f, 0.14f);
    [SerializeField] private Color baseColorLow = new Color(0.05f, 0.12f, 0.02f);
    [SerializeField] private Color baseColorHigh = new Color(0.08f, 0.18f, 0.03f);
    [SerializeField] private Color tipColorLow = new Color(0.35f, 0.45f, 0.12f);
    [SerializeField] private Color tipColorHigh = new Color(0.55f, 0.6f, 0.2f);
    [SerializeField] [Range(0f, 1f)] private float shadeJitterStrength = 0.25f;
    [SerializeField] [Range(0f, 256f)] private float specularPower = 24f;
    [SerializeField] [Range(0f, 1f)] private float specularStrength = 0.15f;
    [SerializeField] [Range(0f, 4f)] private float subsurfaceStrength = 1.2f;
    [SerializeField] [Range(0f, 1f)] [Tooltip("How dark the fake root AO gets at the very base of the blade.")]
    private float rootAOStrength = 0.5f;
    [SerializeField] [Range(0.01f, 1f)] [Tooltip("Height percent at which the fake root AO fades to fully lit.")]
    private float rootAOHeight = 0.5f;

    [Header("References")]
    [SerializeField] [Tooltip("Drives frustum culling, tile streaming, and the distance fade. Defaults to Camera.main if left empty.")]
    private Camera mainCamera;
    [SerializeField] private ComputeShader grassBuilderCS;
    [SerializeField] private Material grassMaterial;

    // Must match TileData in Assets/Shaders/GrassStructs.hlsl exactly (field order and types).
    [StructLayout(LayoutKind.Sequential)]
    private struct TileData { public Vector3 center; public uint tileId; }
    private static readonly int tileDataStride = Marshal.SizeOf<TileData>();

    // GrassData is populated entirely on the GPU; only its byte stride is needed here to size the buffer.
    private const int grassDataStride = 68;

    private struct TileEntry { public TileData data; public Bounds bounds; }

    // Streamed tile pool, keyed by stable grid coordinate.
    private Dictionary<Vector2Int, TileEntry> activeTiles;
    private HashSet<Vector2Int> desiredCoords;
    private List<Vector2Int> coordsToRemove;

    private List<TileData> visibleTilesList;
    private readonly Plane[] cameraFrustumPlanes = new Plane[6];

    private GraphicsBuffer visibleTilesBuffer;
    private GraphicsBuffer grassDataBuffer;
    private GraphicsBuffer argsBuffer;
    private GraphicsBuffer bladeIndexBuffer;

    // Low-LOD mirror of the buffers above, for the simplified 3-vertex blade.
    private GraphicsBuffer grassDataBufferLow;
    private GraphicsBuffer argsBufferLow;
    private GraphicsBuffer bladeIndexBufferLow;

    private int maxTilesInView;
    private int buildKernel;
    private Vector4[] frustumPlaneVectors;

    // 13 triangles x 3 corners, indexing the 15-vertex strip (BLADE_STRIP_VERTEX_COUNT
    // in Assets/Shaders/GrassBladeSpine.hlsl).
    private const uint bladeIndexCount = 39;

    // Single triangle: root-left, root-right, tip.
    private const uint bladeIndexCountLow = 3;

    private const string LODLowKeyword = "_GRASS_LOD_LOW";
    private const string ClumpDebugKeyword = "_GRASS_DEBUG_CLUMP";
    private Material grassMaterialLow;

    private bool initialized;

    private void OnEnable()
    {
        RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
    }

    private void OnDisable()
    {
        RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
    }

    void Start()
    {
        if (terrain == null)
        {
            Debug.LogError("GrassManager requires a Terrain reference.", this);
            enabled = false;
            return;
        }

        if (mainCamera == null) mainCamera = Camera.main;

        buildKernel = grassBuilderCS.FindKernel("BuildGrass");

        grassMaterial.DisableKeyword(LODLowKeyword);
        grassMaterialLow = new Material(grassMaterial);
        grassMaterialLow.EnableKeyword(LODLowKeyword);
        ApplyDebugClumpKeyword();

        frustumPlaneVectors = new Vector4[6];

        InitializeStreamingPool();
        InitializeBuffers();

        initialized = true;
    }

    private void InitializeStreamingPool()
    {
        // Sized for MaxRenderDistanceInTiles (the worst case), so it never needs to grow when render distance changes.
        int span = MaxRenderDistanceInTiles * 2 + 1;
        maxTilesInView = span * span;

        activeTiles = new Dictionary<Vector2Int, TileEntry>(maxTilesInView);
        desiredCoords = new HashSet<Vector2Int>(maxTilesInView);
        coordsToRemove = new List<Vector2Int>(maxTilesInView);
        visibleTilesList = new List<TileData>(maxTilesInView);
    }

    private void InitializeBuffers()
    {
        visibleTilesBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, maxTilesInView, tileDataStride);

        // Worst case: every streamable tile, at MaxGrassPerAxisPerTile density.
        int maxGrassCount = maxTilesInView * MaxGrassPerAxisPerTile * MaxGrassPerAxisPerTile;

        // Append buffer for grass instances. Both LOD tiers use the same worst-case
        // size, since either could hold every visible blade (e.g. all beyond lodSwitchDistance).
        grassDataBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Append, maxGrassCount, grassDataStride);
        grassDataBufferLow = new GraphicsBuffer(GraphicsBuffer.Target.Append, maxGrassCount, grassDataStride);

        argsBuffer = CreateArgsBuffer(bladeIndexCount);
        argsBufferLow = CreateArgsBuffer(bladeIndexCountLow);

        bladeIndexBuffer = new GraphicsBuffer(GraphicsBuffer.Target.Index, (int)bladeIndexCount, sizeof(ushort));
        bladeIndexBuffer.SetData(BuildBladeIndexBuffer());

        bladeIndexBufferLow = new GraphicsBuffer(GraphicsBuffer.Target.Index, (int)bladeIndexCountLow, sizeof(ushort));
        bladeIndexBufferLow.SetData(new ushort[] { 0, 1, 2 });
    }

    // Indirect Draw Indexed Arguments buffer (5 uints):
    // index count per instance, instance count, start index, base vertex, start instance.
    private static GraphicsBuffer CreateArgsBuffer(uint indexCount)
    {
        GraphicsBuffer buffer = new GraphicsBuffer(GraphicsBuffer.Target.IndirectArguments, 1, 5 * sizeof(uint));
        buffer.SetData(new uint[] { indexCount, 0, 0, 0, 0 });
        return buffer;
    }

    // Expands the 15-vertex strip into 13 triangles as indices (instead of raw
    // vertexIDs), so the GPU's post-transform cache can reuse shared corners.
    // Odd triangles swap their first two corners to fix triangle winding.
    private static ushort[] BuildBladeIndexBuffer()
    {
        ushort[] indices = new ushort[bladeIndexCount];
        for (uint i = 0; i < bladeIndexCount; i++)
        {
            uint triangleIndex = i / 3;
            uint corner = i % 3;
            if ((triangleIndex & 1) == 1 && corner < 2) corner = 1 - corner;
            indices[i] = (ushort)(triangleIndex + corner);
        }
        return indices;
    }

    // Encodes a tile grid coordinate (can be negative) into a stable uint id, so a
    // tile's random seed depends only on its position, not on load order.
    private static uint EncodeTileId(Vector2Int coord)
    {
        uint ux = (uint)(coord.x + 32768);
        uint uz = (uint)(coord.y + 32768);
        return (ux << 16) | (uz & 0xFFFF);
    }

    private void UpdateTileStreaming()
    {
        Vector3 followPos = mainCamera.transform.position;
        int centerX = Mathf.FloorToInt((followPos.x - transform.position.x) / TileSize);
        int centerZ = Mathf.FloorToInt((followPos.z - transform.position.z) / TileSize);

        // Circular (distance-to-camera) cutoff instead of the square tile-grid bounds,
        // for a rounder streaming edge that matches the height fade below.
        float renderDistanceWorld = renderDistanceInTiles * TileSize;
        float renderDistanceWorldSqr = renderDistanceWorld * renderDistanceWorld;

        desiredCoords.Clear();
        for (int dx = -renderDistanceInTiles; dx <= renderDistanceInTiles; dx++)
        {
            for (int dz = -renderDistanceInTiles; dz <= renderDistanceInTiles; dz++)
            {
                Vector2Int coord = new Vector2Int(centerX + dx, centerZ + dz);

                (float tileCenterX, float tileCenterZ) = GetTileCenterXZ(coord);
                float offsetX = tileCenterX - followPos.x;
                float offsetZ = tileCenterZ - followPos.z;
                if (offsetX * offsetX + offsetZ * offsetZ > renderDistanceWorldSqr)
                    continue;

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

    private (float x, float z) GetTileCenterXZ(Vector2Int coord)
    {
        return (transform.position.x + (coord.x + 0.5f) * TileSize, transform.position.z + (coord.y + 0.5f) * TileSize);
    }

    private TileEntry LoadTile(Vector2Int coord)
    {
        (float centerX, float centerZ) = GetTileCenterXZ(coord);

        (float minY, float maxY) = SampleTileHeightRange(centerX, centerZ);

        // Pad the vertical extent so grown blades (root already at minY..maxY)
        // still fit fully inside the AABB used for CPU frustum culling.
        float verticalPadding = 2f * ComputeBladeBoundingRadius();
        Bounds bounds = new Bounds(
            new Vector3(centerX, (minY + maxY) * 0.5f, centerZ),
            new Vector3(TileSize, Mathf.Max(0.01f, maxY - minY) + verticalPadding, TileSize));

        TileData data = new TileData
        {
            center = new Vector3(centerX, 0f, centerZ), // y is resolved per-blade from the heightmap on the GPU
            tileId = EncodeTileId(coord)
        };

        return new TileEntry { data = data, bounds = bounds };
    }

    private (float minY, float maxY) SampleTileHeightRange(float centerX, float centerZ)
    {
        float half = TileSize * 0.5f;
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
        if (activeTiles == null) return;

        foreach (TileEntry entry in activeTiles.Values)
        {
            bool isVisible = GeometryUtility.TestPlanesAABB(cameraFrustumPlanes, entry.bounds);
            Gizmos.color = isVisible ? new Color(0f, 1f, 0f, 0.35f) : new Color(1f, 0f, 0f, 0.15f);
            Gizmos.DrawWireCube(entry.bounds.center, entry.bounds.size);
        }
    }

    // Runs right before the camera records its render commands, avoiding a race with the
    // camera's own update. Streaming, culling, and the build dispatch are gated to the main
    // camera only, since that's what the frustum and distance fade use. Drawing is also
    // gated to the Scene view camera, so grass stays visible while debugging there.
    private void OnBeginCameraRendering(ScriptableRenderContext context, Camera camera)
    {
        if (!initialized) return;

        if (camera == mainCamera)
        {
            UpdateTileStreaming();
            PerformCPUCulling();

            if (visibleTilesList.Count > 0)
            {
                UpdateDistanceFadeGlobals();
                DispatchGrassBuilder();
                PrepareIndirectArgs();
                UpdateLightingGlobals();
            }
        }

        bool shouldDraw = camera == mainCamera || camera.cameraType == CameraType.SceneView;
        if (shouldDraw && visibleTilesList.Count > 0)
        {
            RenderGrass();
        }
    }

    private void UpdateDistanceFadeGlobals()
    {
        float renderDistanceWorld = renderDistanceInTiles * TileSize;
        Shader.SetGlobalFloat("_GrassFadeStartDist", renderDistanceWorld * heightFadeStartFraction);
        Shader.SetGlobalFloat("_GrassFadeEndDist", renderDistanceWorld);
        Shader.SetGlobalVector("_GrassCameraPosition", mainCamera.transform.position);
        Shader.SetGlobalFloat("_GrassLODSwitchDist", lodSwitchDistance);
        Shader.SetGlobalFloat("_GrassLODBendBlendDist", lodBendBlendDistance);
        Shader.SetGlobalFloat("_GrassDensityFadeStartDist", densityFadeStartDistance);
        Shader.SetGlobalFloat("_GrassDensityFadeEndDist", renderDistanceWorld);
        Shader.SetGlobalFloat("_GrassMinDensityFraction", minDensityFraction);
    }

    private void UpdateLightingGlobals()
    {
        Vector3 lightDir = sunLight != null ? -sunLight.transform.forward : new Vector3(0.3f, 0.8f, 0.2f).normalized;
        Color lightColor = (sunLight != null ? sunLight.color : Color.white) * lightIntensity;

        Shader.SetGlobalVector("_GrassLightDir", lightDir);
        Shader.SetGlobalColor("_GrassLightColor", lightColor);
        Shader.SetGlobalColor("_GrassAmbientColor", ambientColor);
        Shader.SetGlobalColor("_GrassBaseColorLow", baseColorLow);
        Shader.SetGlobalColor("_GrassBaseColorHigh", baseColorHigh);
        Shader.SetGlobalColor("_GrassTipColorLow", tipColorLow);
        Shader.SetGlobalColor("_GrassTipColorHigh", tipColorHigh);
        Shader.SetGlobalFloat("_GrassShadeJitterStrength", shadeJitterStrength);
        Shader.SetGlobalFloat("_GrassSpecPower", specularPower);
        Shader.SetGlobalFloat("_GrassSpecStrength", specularStrength);
        Shader.SetGlobalFloat("_GrassSSSStrength", subsurfaceStrength);
        Shader.SetGlobalFloat("_GrassRootAOStrength", rootAOStrength);
        Shader.SetGlobalFloat("_GrassRootAOHeight", rootAOHeight);
        Shader.SetGlobalFloat("_ClumpColorStrength", clumpColorStrength);
    }

    private void ApplyDebugClumpKeyword()
    {
        if (grassMaterial == null || grassMaterialLow == null) return;

        if (debugClumpView)
        {
            grassMaterial.EnableKeyword(ClumpDebugKeyword);
            grassMaterialLow.EnableKeyword(ClumpDebugKeyword);
        }
        else
        {
            grassMaterial.DisableKeyword(ClumpDebugKeyword);
            grassMaterialLow.DisableKeyword(ClumpDebugKeyword);
        }
    }

    private void OnValidate()
    {
        ApplyDebugClumpKeyword();
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
        grassDataBuffer.SetCounterValue(0);
        grassDataBufferLow.SetCounterValue(0);

        grassBuilderCS.SetBuffer(buildKernel, "_VisibleTiles", visibleTilesBuffer);
        grassBuilderCS.SetBuffer(buildKernel, "_GrassDataBuffer", grassDataBuffer);
        grassBuilderCS.SetBuffer(buildKernel, "_GrassDataBufferLow", grassDataBufferLow);
        grassBuilderCS.SetFloat("_TileSize", TileSize);
        grassBuilderCS.SetInt("_GrassPerAxis", grassPerAxisPerTile);
        grassBuilderCS.SetFloat("_BaseHeight", bladeHeight);
        grassBuilderCS.SetFloat("_BaseWidth", bladeWidth);
        grassBuilderCS.SetFloat("_BaseBend", bladeBend);
        grassBuilderCS.SetFloat("_BaseTilt", bladeTilt);
        grassBuilderCS.SetFloat("_ShapeVariance", shapeVariance);
        grassBuilderCS.SetFloat("_SideCurveStrength", sideCurveStrength);
        grassBuilderCS.SetFloat("_JitterStrength", jitterStrength);
        grassBuilderCS.SetFloat("_SlopeLeanStrength", slopeLeanStrength);
        grassBuilderCS.SetFloat("_ClumpSize", clumpSize);
        grassBuilderCS.SetFloat("_ClumpJitterStrength", clumpJitterStrength);
        grassBuilderCS.SetFloat("_ClumpFacingStrength", clumpFacingStrength);
        grassBuilderCS.SetVector("_ClumpColorA", clumpColorA);
        grassBuilderCS.SetVector("_ClumpColorB", clumpColorB);
        grassBuilderCS.SetFloat("_ClumpHeightFalloff", clumpHeightFalloff);

        for (int i = 0; i < 6; i++)
        {
            Plane plane = cameraFrustumPlanes[i];
            frustumPlaneVectors[i] = new Vector4(plane.normal.x, plane.normal.y, plane.normal.z, plane.distance);
        }
        grassBuilderCS.SetVectorArray("_FrustumPlanes", frustumPlaneVectors);
        grassBuilderCS.SetFloat("_BladeBoundingRadius", ComputeBladeBoundingRadius());

        // Terrain sampling params are set as shader globals instead of passed to the kernel
        // directly, for convenience: only GrassBuilder.compute reads them, once per blade, to
        // place it on the surface and bake its downhill facing lean (GrassTerrainSampling.hlsl).
        TerrainData data = terrain.terrainData;
        Shader.SetGlobalTexture("_HeightmapTexture", data.heightmapTexture);
        Shader.SetGlobalVector("_TerrainOriginXZ", new Vector4(terrain.transform.position.x, terrain.transform.position.z, 0, 0));
        Shader.SetGlobalVector("_TerrainSize", new Vector4(data.size.x, data.size.z, 0, 0));
        Shader.SetGlobalFloat("_TerrainBaseY", terrain.transform.position.y);
        Shader.SetGlobalFloat("_TerrainHeightScale", data.size.y * 2f);

        // Ground-validity mask: the terrain's own painted layer-0 texture (its splat weight),
        // instead of a separate hand-authored mask. Falls back to "always valid" if the
        // terrain has no layers painted.
        Texture2D[] alphamaps = data.alphamapTextures;
        Texture2D grassMask = alphamaps.Length > 0 ? alphamaps[0] : Texture2D.whiteTexture;
        grassBuilderCS.SetTexture(buildKernel, "_ControlTexture", grassMask);

        int threadGroups = Mathf.CeilToInt(grassPerAxisPerTile / 8f);
        grassBuilderCS.Dispatch(buildKernel, threadGroups, threadGroups, visibleTilesList.Count);
    }

    // Worst-case root-to-vertex distance across all randomized blades, given the current
    // base shape params. This is a triangle-inequality upper bound: a vertex is the root
    // plus a sum of offsets (height, tilt, bend, sideCurve, width), so the sum of their
    // max magnitudes is always >= the true bounding radius.
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
        // Copies each append buffer's live counter into its args buffer's instance count.
        GraphicsBuffer.CopyCount(grassDataBuffer, argsBuffer, 4);
        GraphicsBuffer.CopyCount(grassDataBufferLow, argsBufferLow, 4);
    }

    private void RenderGrass()
    {
        float span = (renderDistanceInTiles * 2 + 1) * TileSize + 2f * ComputeBladeBoundingRadius();
        float centerY = terrain.transform.position.y + terrain.terrainData.size.y * 0.5f;
        float height = terrain.terrainData.size.y + 2f * ComputeBladeBoundingRadius();

        Vector3 center = new Vector3(mainCamera.transform.position.x, centerY, mainCamera.transform.position.z);
        Bounds bounds = new Bounds(center, new Vector3(span, height, span));

        grassMaterial.SetBuffer("_GrassDataBuffer", grassDataBuffer);
        Graphics.DrawProceduralIndirect(grassMaterial, bounds, MeshTopology.Triangles, bladeIndexBuffer, argsBuffer, 0, null, null, UnityEngine.Rendering.ShadowCastingMode.Off, true, gameObject.layer);

        grassMaterialLow.SetBuffer("_GrassDataBuffer", grassDataBufferLow);
        Graphics.DrawProceduralIndirect(grassMaterialLow, bounds, MeshTopology.Triangles, bladeIndexBufferLow, argsBufferLow, 0, null, null, UnityEngine.Rendering.ShadowCastingMode.Off, true, gameObject.layer);
    }

    private void OnDestroy()
    {
        visibleTilesBuffer?.Release();
        grassDataBuffer?.Release();
        argsBuffer?.Release();
        bladeIndexBuffer?.Release();
        grassDataBufferLow?.Release();
        argsBufferLow?.Release();
        bladeIndexBufferLow?.Release();

        if (grassMaterialLow != null) Destroy(grassMaterialLow);
    }
}
