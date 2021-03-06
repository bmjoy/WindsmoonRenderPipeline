#ifndef WINDSMOON_SHADOW_INCLUDED
#define WINDSMOON_SHADOW_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Shadow/ShadowSamplingTent.hlsl"

#if defined(DIRECTIONAL_PCF3X3)
	#define DIRECTIONAL_FILTER_SAMPLES 4
	#define DIRECTIONAL_FILTER_SETUP SampleShadow_ComputeSamples_Tent_3x3
#elif defined(DIRECTIONAL_PCF5X5)
	#define DIRECTIONAL_FILTER_SAMPLES 9
	#define DIRECTIONAL_FILTER_SETUP SampleShadow_ComputeSamples_Tent_5x5
#elif defined(DIRECTIONAL_PCF7X7)
	#define DIRECTIONAL_FILTER_SAMPLES 16
	#define DIRECTIONAL_FILTER_SETUP SampleShadow_ComputeSamples_Tent_7x7
#endif

#define MAX_DIRECTIONAL_SHADOW_COUNT 4
#define MAX_CASCADE_COUNT 4

TEXTURE2D_SHADOW(_DirectionalShadowMap); // ?? what does TEXTURE2D_SHADOW mean ?
#define SHADOW_SAMPLER sampler_linear_clamp_compare // ??
SAMPLER_CMP(SHADOW_SAMPLER); // ?? note : use a special SAMPLER_CMP macro to define the sampler state, as this does define a different way to sample shadow maps, because regular bilinear filtering doesn't make sense for depth data.

struct ShadowMask 
{
	bool useDistanceShadowMask;
	float4 shadows;
};

CBUFFER_START(ShadowInfo)
    int _CascadeCount;
    float4 _CascadeCullingSpheres[MAX_CASCADE_COUNT];
    float4x4 _DirectionalShadowMatrices[MAX_DIRECTIONAL_SHADOW_COUNT * MAX_CASCADE_COUNT];
    //float _MaxShadowDistance;
    float4 _ShadowDistanceFade; // x means 1/maxShadowDistance, y means 1/distanceFade
    float4 _CascadeInfos[MAX_CASCADE_COUNT]; // x : 1 / (radius of cullingSphere) ^ 2
    float4 _DirectionalShadowMapSize;
CBUFFER_END 

struct DirectionalShadowInfo // the info of the direcctional light
{
    float shadowStrength; // if surface is not in any culling sphere, global shadowStrength set to 0 to avoid any shadow 
    int tileIndex;
    float normalBias;
};

struct ShadowData // the info of the fragment
{
    int cascadeIndex;
    float cascadeBlend;
    float strength;
    ShadowMask shadowMask;
};

// fadeScale is from 0 to 1 but not equal 0
// scale means 1 / maxDistancce
// fadeScale control the begin point of fade
float GetFadedShadowStrength(float depth, float scale, float fadeScale) 
{
    // (1 - depth / maxDistance) / fadeScale
    // (1 - depth / maxDistance) means from 0 to 1, the shadow strength from 1 to 0 linearly
    // divided by fadeScale and saturate the resulit means the fade begin at the point (1 - fadeScale) in the line form 0 to maxDisatance
    return saturate((1.0 - depth * scale) * fadeScale);
}

// todo : add cascade keyword
ShadowData GetShadowData(Surface surfaceWS)
{
    ShadowData shadowData;
    shadowData.shadowMask.useDistanceShadowMask = false;
	shadowData.shadowMask.shadows = 1.0;
    
    // ?? : is this fade meaningful ?
    
    // the outermost culling sphere doesn't end exactly at the max shadow distance but extends a bit beyond it
    
    //if (surfaceWS.depth >= _MaxShadowDistance)
    //{
    //    shadowInfo.cascadeIndex = 0;
    //    shadowInfo.strength = 0.0f;
    //    return shadowInfo;
    //}
    
    shadowData.cascadeBlend = 1.0;
    shadowData.strength = GetFadedShadowStrength(surfaceWS.depth, _ShadowDistanceFade.x, _ShadowDistanceFade.y);
    
    for (int i = 0; i < _CascadeCount; ++i)
    {
        float4 cullingSphere = _CascadeCullingSpheres[i];
        float squaredDistance = GetDistanceSquared(cullingSphere.xyz, surfaceWS.position);
        
        if (squaredDistance < cullingSphere.w)
        {
            // todo : I think it is useless because there has already have distance fade 
            float fade = GetFadedShadowStrength(squaredDistance, _CascadeInfos[i].x, _ShadowDistanceFade.z);
            
            if (i == _CascadeCount - 1)
            {
                // shadowData.strength *= GetFadedShadowStrength(squaredDistance, _CascadeInfos[i].x, _ShadowDistanceFade.z);
                shadowData.strength *= fade;
            }
            
            else
            {
                shadowData.cascadeBlend = fade;
            }
            
            break;
        }
    }
    
    if (i == _CascadeCount)
    {
        shadowData.strength = 0.0;
    }
    
    #if defined(CASCADE_BLEND_DITHER)
		else if (shadowData.cascadeBlend < surfaceWS.dither) 
		{
			i += 1;
		}
	#endif
	
	#if !defined(CASCADE_BLEND_SOFT)
		shadowData.cascadeBlend = 1.0;
	#endif
    
    shadowData.cascadeIndex = i;
    return shadowData;
}

float SampleDirectionalShadow(float3 positionShadowMap)
{
    return SAMPLE_TEXTURE2D_SHADOW(_DirectionalShadowMap, SHADOW_SAMPLER, positionShadowMap);
}

float FilterDirectionalShadow (float3 positionSTS) {
	#if defined(DIRECTIONAL_FILTER_SETUP)
		float weights[DIRECTIONAL_FILTER_SAMPLES];
		float2 positions[DIRECTIONAL_FILTER_SAMPLES];
		float4 size = _DirectionalShadowMapSize.yyxx;
		DIRECTIONAL_FILTER_SETUP(size, positionSTS.xy, weights, positions);
		float shadow = 0;
		
		for (int i = 0; i < DIRECTIONAL_FILTER_SAMPLES; i++) 
		{
			shadow += weights[i] * SampleDirectionalShadow(float3(positions[i].xy, positionSTS.z));
		}
		
		return shadow;
	#else
		return SampleDirectionalShadow(positionSTS);
	#endif
}

float GetDirectionalShadowAttenuation(DirectionalShadowInfo directionalShadowInfo, ShadowData globalShadowData, Surface surfaceWS)
{
    #if !defined(RECEIVE_SHADOWS)
        return 1.0f;
    #else
        if (directionalShadowInfo.shadowStrength <= 0.0f) // todo : when strength is zero, this light should be discard in c# part 
        {
	    	return 1.0f;
	    }
	    
	    float3 normalBias = surfaceWS.normal * directionalShadowInfo.normalBias * _CascadeInfos[globalShadowData.cascadeIndex].y;
        float3 positionShadowMap = mul(_DirectionalShadowMatrices[directionalShadowInfo.tileIndex], float4(surfaceWS.position + normalBias, 1.0f));
        float shadow = FilterDirectionalShadow(positionShadowMap);
        
        if (globalShadowData.cascadeBlend < 1.0) // ??
        {
            normalBias = surfaceWS.normal * (directionalShadowInfo.normalBias * _CascadeInfos[globalShadowData.cascadeIndex + 1].y);
            positionShadowMap = mul(_DirectionalShadowMatrices[directionalShadowInfo.tileIndex + 1], float4(surfaceWS.position + normalBias, 1.0f));
            shadow = lerp(FilterDirectionalShadow(positionShadowMap), shadow, globalShadowData.cascadeBlend);
        }
        
        return lerp(1.0f, shadow, directionalShadowInfo.shadowStrength); // ?? why directly use shadow map value than cmpare their depth
    #endif
}

#endif