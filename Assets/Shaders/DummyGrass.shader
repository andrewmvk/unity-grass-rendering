Shader "Custom/DummyGrass"
{
    SubShader
    {
        Tags { "RenderPipeline"="HDRenderPipeline" "RenderType"="Opaque" "Queue"="Geometry" }

        // Depth pre-pass: forces grass depth to render before the terrain, fixing visibility from above.
        Pass
        {
            Name "DepthForwardOnly"
            Tags { "LightMode" = "DepthForwardOnly" }

            Cull Off
            ZWrite On
            ZTest LEqual

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.5

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"
            #include "GrassVertex.hlsl"

            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 normalWS : TEXCOORD0;
                nointerpolation float3 groundNormalWS : TEXCOORD1;
                nointerpolation float farFade : TEXCOORD2;
            };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                GrassVertexData g = GetGrassVertexData(vertexID, instanceID);
                float3 cameraRelativePos = GetCameraRelativePositionWS(g.positionWS);

                v2f o;
                o.pos = TransformWorldToHClip(cameraRelativePos);
                o.normalWS = g.normalWS;
                o.groundNormalWS = g.groundNormalWS;
                o.farFade = g.farFade;
                return o;
            }

            // SV_Target0 is HDRP's normal buffer for forward-rendered opaque geometry (used by
            // SSAO/SSR/contact shadows and AOV normal export), not a color output. Assumes MSAA
            // is off, as in this project's HDRP asset (HDRP writes to SV_Target1 instead with MSAA on).
            float4 frag (v2f i, bool isFrontFace : SV_IsFrontFace) : SV_Target
            {
                NormalData normalData;
                normalData.normalWS = GetGrassShadingNormal(i.normalWS, i.groundNormalWS, i.farFade, isFrontFace);
                normalData.perceptualRoughness = 1.0;

                float4 outNormalBuffer;
                EncodeIntoNormalBuffer(normalData, outNormalBuffer);
                return outNormalBuffer;
            }
            ENDHLSL
        }

        // Forward pass: renders the actual color.
        Pass
        {
            Name "ForwardOnly"
            Tags { "LightMode" = "ForwardOnly" }

            Cull Off
            ZWrite On
            ZTest LEqual

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.5
            #pragma multi_compile_local _ _GRASS_LOD_LOW
            #pragma multi_compile_local _ _GRASS_DEBUG_CLUMP
            #pragma multi_compile_local _ _GRASS_DEBUG_WIND

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
            #include "GrassVertex.hlsl"

            float3 _GrassLightDir;
            float4 _GrassLightColor;
            float4 _GrassAmbientColor;
            float4 _GrassBaseColorLow;
            float4 _GrassBaseColorHigh;
            float4 _GrassTipColorLow;
            float4 _GrassTipColorHigh;
            float _GrassShadeJitterStrength;
            float _GrassSpecPower;
            float _GrassSpecStrength;
            float _GrassSSSStrength;
            float _GrassRootAOStrength;
            float _GrassRootAOHeight;
            float _ClumpColorStrength;

            struct v2f
            {
                float4 pos : SV_POSITION;
            #if defined(_GRASS_LOD_LOW)
                float3 color : TEXCOORD0;
            #else
                float3 positionWS : TEXCOORD0; // camera-relative
                float3 normalWS : TEXCOORD1;
                float heightPercent : TEXCOORD2;
                nointerpolation uint bladeHash : TEXCOORD3;
                nointerpolation float3 clumpColor : TEXCOORD4;
                nointerpolation float windNoise : TEXCOORD5;
                nointerpolation float3 groundNormalWS : TEXCOORD6;
                nointerpolation float farFade : TEXCOORD7;
            #endif
            };

            // Blue (calm) -> green -> yellow -> red (strong gust), for the wind debug view.
            float3 WindHeatMap(float t)
            {
                float3 calm = float3(0.0, 0.0, 1.0);
                float3 mild = float3(0.0, 1.0, 0.0);
                float3 strong = float3(1.0, 1.0, 0.0);
                float3 gust = float3(1.0, 0.0, 0.0);

                float3 low = lerp(calm, mild, saturate(t / 0.33));
                float3 high = lerp(mild, lerp(strong, gust, saturate((t - 0.66) / 0.34)), saturate((t - 0.33) / 0.33));
                return t < 0.33 ? low : high;
            }

            float3 GetGrassColor(float3 normal, float3 viewDir, float heightPercent, uint bladeHash, float3 clumpColor, float windNoise, float farFade)
            {
            #if defined(_GRASS_DEBUG_CLUMP)
                return clumpColor;
            #elif defined(_GRASS_DEBUG_WIND)
                return WindHeatMap(windNoise);
            #else
                float3 lightDir = normalize(_GrassLightDir);
                float nearFade = 1.0 - farFade;

                float baseColorVariation = lerp(0.5, HashToFloat01(bladeHash, 40), nearFade);
                float tipColorVariation = lerp(0.5, HashToFloat01(bladeHash, 41), nearFade);
                float3 baseColor = lerp(_GrassBaseColorLow.rgb, _GrassBaseColorHigh.rgb, baseColorVariation);
                float3 tipColor = lerp(_GrassTipColorLow.rgb, _GrassTipColorHigh.rgb, tipColorVariation);
                float3 albedo = lerp(baseColor, tipColor, pow(saturate(heightPercent), 1.5));
                albedo *= 1.0 + HashToSigned(bladeHash, 42) * _GrassShadeJitterStrength * nearFade;
                albedo = lerp(albedo, albedo * clumpColor, _ClumpColorStrength);

                #if !defined(_GRASS_LOD_LOW)
                    // Fake AO: dense grass self-shadows near the root, fading out fast with height.
                    float rootAO = lerp(1.0 - _GrassRootAOStrength, 1.0, saturate(heightPercent / max(_GrassRootAOHeight, 1e-4)));
                    float occlusion = rootAO * rootAO;
                    albedo *= occlusion;
                #endif

                float wrap = 0.5;
                float diffuseTerm = saturate((dot(normal, lightDir) + wrap) / (1.0 + wrap));
                float3 diffuse = diffuseTerm * _GrassLightColor.rgb * albedo;

                // Fake subsurface scattering: light glows through the blade when backlit.
                float backLight = saturate((dot(viewDir, -lightDir) + wrap) / (1.0 + wrap));
                float3 subsurface = pow(backLight, 2.0) * _GrassSSSStrength * _GrassLightColor.rgb * albedo * (0.4 + 0.6 * heightPercent);

                float3 ambient = _GrassAmbientColor.rgb * albedo;
                float3 color = ambient + diffuse + subsurface;

                #if !defined(_GRASS_LOD_LOW)
                    float3 halfDir = normalize(lightDir + viewDir);
                    float specNormalization = (_GrassSpecPower * 0.5 + 1.0) / PI;
                    float specTerm = specNormalization * pow(saturate(dot(normal, halfDir)), _GrassSpecPower);
                    color += specTerm * _GrassSpecStrength * _GrassLightColor.rgb * occlusion * nearFade;
                #endif

                return color;
            #endif
            }

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                GrassVertexData g = GetGrassVertexData(vertexID, instanceID);
                float3 cameraRelativePos = GetCameraRelativePositionWS(g.positionWS);

                v2f o;
                o.pos = TransformWorldToHClip(cameraRelativePos);
            #if defined(_GRASS_LOD_LOW)
                float3 viewDir = normalize(-cameraRelativePos);
                bool facesCamera = dot(g.normalWS, viewDir) >= 0.0;
                float3 normal = GetGrassShadingNormal(g.normalWS, g.groundNormalWS, g.farFade, facesCamera);
                o.color = GetGrassColor(normal, viewDir, g.heightPercent, g.bladeHash, g.clumpColor, g.windNoise, g.farFade);
            #else
                o.positionWS = cameraRelativePos;
                o.normalWS = g.normalWS;
                o.heightPercent = g.heightPercent;
                o.bladeHash = g.bladeHash;
                o.clumpColor = g.clumpColor;
                o.windNoise = g.windNoise;
                o.groundNormalWS = g.groundNormalWS;
                o.farFade = g.farFade;
            #endif
                return o;
            }

            float4 frag (v2f i, bool isFrontFace : SV_IsFrontFace) : SV_Target
            {
            #if defined(_GRASS_LOD_LOW)
                return float4(i.color, 1.0);
            #else
                float3 normal = GetGrassShadingNormal(i.normalWS, i.groundNormalWS, i.farFade, isFrontFace);
                float3 viewDir = normalize(-i.positionWS);
                return float4(GetGrassColor(normal, viewDir, i.heightPercent, i.bladeHash, i.clumpColor, i.windNoise, i.farFade), 1.0);
            #endif
            }
            ENDHLSL
        }
    }
}
