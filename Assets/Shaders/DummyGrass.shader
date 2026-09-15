Shader "Custom/DummyGrass"
{
    SubShader
    {
        Tags { "RenderPipeline"="HDRenderPipeline" "RenderType"="Opaque" "Queue"="Geometry" }

        // DEPTH PREPASS - Forces grass depth to render before the terrain, fixing visibility from above
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
            #pragma multi_compile_local _ _GRASS_LOD_LOW

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"
            #include "GrassVertex.hlsl"

            struct v2f { float4 pos : SV_POSITION; float3 normalWS : TEXCOORD0; };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                GrassVertexData g = GetGrassVertexData(vertexID, instanceID);
                float3 cameraRelativePos = GetCameraRelativePositionWS(g.positionWS);

                v2f o;
                o.pos = TransformWorldToHClip(cameraRelativePos);
                o.normalWS = g.normalWS;
                return o;
            }

            // SV_Target0 here IS HDRP's normal buffer for Forward-rendered opaque geometry (used by
            // SSAO/SSR/contact shadows and AOV normal export), not a color output - assumes MSAA off
            // (this project's HDRP asset has it disabled; with MSAA on HDRP shifts this to SV_Target1).
            float4 frag (v2f i, bool isFrontFace : SV_IsFrontFace) : SV_Target
            {
                NormalData normalData;
                normalData.normalWS = normalize(i.normalWS) * (isFrontFace ? 1.0 : -1.0);
                normalData.perceptualRoughness = 1.0;

                float4 outNormalBuffer;
                EncodeIntoNormalBuffer(normalData, outNormalBuffer);
                return outNormalBuffer;
            }
            ENDHLSL
        }

        // FORWARD PASS - Renders the actual color
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

            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 positionWS : TEXCOORD0; // camera-relative
                float3 normalWS : TEXCOORD1;
                float heightPercent : TEXCOORD2;
                nointerpolation uint bladeHash : TEXCOORD3;
            };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                GrassVertexData g = GetGrassVertexData(vertexID, instanceID);
                float3 cameraRelativePos = GetCameraRelativePositionWS(g.positionWS);

                v2f o;
                o.pos = TransformWorldToHClip(cameraRelativePos);
                o.positionWS = cameraRelativePos;
                o.normalWS = g.normalWS;
                o.heightPercent = g.heightPercent;
                o.bladeHash = g.bladeHash;
                return o;
            }

            float4 frag (v2f i, bool isFrontFace : SV_IsFrontFace) : SV_Target
            {
                float3 normal = normalize(i.normalWS) * (isFrontFace ? 1.0 : -1.0);
                float3 lightDir = normalize(_GrassLightDir);

                float3 baseColor = lerp(_GrassBaseColorLow.rgb, _GrassBaseColorHigh.rgb, HashToFloat01(i.bladeHash, 40));
                float3 tipColor = lerp(_GrassTipColorLow.rgb, _GrassTipColorHigh.rgb, HashToFloat01(i.bladeHash, 41));
                float3 albedo = lerp(baseColor, tipColor, pow(saturate(i.heightPercent), 1.5));
                albedo *= 1.0 + HashToSigned(i.bladeHash, 42) * _GrassShadeJitterStrength;

                float wrap = 0.5;
                float diffuseTerm = saturate((dot(normal, lightDir) + wrap) / (1.0 + wrap));

#if defined(_GRASS_LOD_LOW)
                float3 viewDir = normalize(-i.positionWS);
                float3 diffuse = diffuseTerm * _GrassLightColor.rgb * albedo;

                // Fake subsurface scattering: light glows through the blade when backlit.
                float backLight = saturate((dot(viewDir, -lightDir) + wrap) / (1.0 + wrap));
                float3 subsurface = pow(backLight, 2.0) * _GrassSSSStrength * _GrassLightColor.rgb * albedo * (0.4 + 0.6 * i.heightPercent);

                float3 ambient = _GrassAmbientColor.rgb * albedo;
                float3 color = ambient + diffuse + subsurface;
                return float4(color, 1.0);
#else
                float3 viewDir = normalize(-i.positionWS);

                // Fake AO: dense grass self-shadows near the root, fading out fast with height.
                float rootAO = lerp(1.0 - _GrassRootAOStrength, 1.0, saturate(i.heightPercent / max(_GrassRootAOHeight, 1e-4)));
                float occlusion = rootAO * rootAO;
                albedo *= occlusion;

                float3 diffuse = diffuseTerm * _GrassLightColor.rgb * albedo;

                float3 halfDir = normalize(lightDir + viewDir);
                float specNormalization = (_GrassSpecPower * 0.5 + 1.0) / PI;
                float specTerm = specNormalization * pow(saturate(dot(normal, halfDir)), _GrassSpecPower);
                float3 specular = specTerm * _GrassSpecStrength * _GrassLightColor.rgb * occlusion;

                // Fake subsurface scattering: light glows through the blade when backlit.
                float backLight = saturate((dot(viewDir, -lightDir) + wrap) / (1.0 + wrap));
                float3 subsurface = pow(backLight, 2.0) * _GrassSSSStrength * _GrassLightColor.rgb * albedo * (0.4 + 0.6 * i.heightPercent);

                float3 ambient = _GrassAmbientColor.rgb * albedo;
                float3 color = ambient + diffuse + specular + subsurface;
                return float4(color, 1.0);
#endif
            }
            ENDHLSL
        }
    }
}
