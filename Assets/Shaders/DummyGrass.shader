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

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"

            struct GrassData
            {
                float3 position;
            };
            StructuredBuffer<GrassData> _GrassDataBuffer;

            struct v2f { float4 pos : SV_POSITION; };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                v2f o;
                GrassData grass = _GrassDataBuffer[instanceID];
                
                // Simple triangle logic from Section 2
                float3 localPos = float3(0, 0, 0);
                if (vertexID == 0) localPos = float3(-0.1, 0, 0);
                if (vertexID == 1) localPos = float3(0.1, 0, 0);
                if (vertexID == 2) localPos = float3(0, 0.5, 0);

                // HDRP Fix: Convert Absolute World Space to Camera-Relative
                float3 absoluteWorldPos = grass.position + localPos;
                float3 cameraRelativePos = GetCameraRelativePositionWS(absoluteWorldPos);
                
                o.pos = TransformWorldToHClip(cameraRelativePos);
                return o;
            }

            float4 frag (v2f i) : SV_Target
            {
                return float4(0, 0, 0, 0);
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

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"

            struct GrassData
            {
                float3 position;
            };
            StructuredBuffer<GrassData> _GrassDataBuffer;

            struct v2f { float4 pos : SV_POSITION; };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                v2f o;
                GrassData grass = _GrassDataBuffer[instanceID];
                
                float3 localPos = float3(0, 0, 0);
                if (vertexID == 0) localPos = float3(-0.1, 0, 0);
                if (vertexID == 1) localPos = float3(0.1, 0, 0);
                if (vertexID == 2) localPos = float3(0, 0.5, 0);

                float3 absoluteWorldPos = grass.position + localPos;
                float3 cameraRelativePos = GetCameraRelativePositionWS(absoluteWorldPos);
                
                o.pos = TransformWorldToHClip(cameraRelativePos);
                return o;
            }

            float4 frag (v2f i) : SV_Target
            {
                float3 color = float3(0.2, 0.8, 0.2);
                return float4(color, 1.0);
            }
            ENDHLSL
        }
    }
}