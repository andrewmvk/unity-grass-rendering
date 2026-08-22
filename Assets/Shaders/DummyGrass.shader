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
            #include "GrassVertex.hlsl"

            struct v2f { float4 pos : SV_POSITION; };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                v2f o;
                float3 absoluteWorldPos = GetGrassVertexWorldPosition(vertexID, instanceID);

                // HDRP Fix: Convert Absolute World Space to Camera-Relative
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
            #include "GrassVertex.hlsl"

            struct v2f { float4 pos : SV_POSITION; };

            v2f vert (uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                v2f o;
                float3 absoluteWorldPos = GetGrassVertexWorldPosition(vertexID, instanceID);
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
