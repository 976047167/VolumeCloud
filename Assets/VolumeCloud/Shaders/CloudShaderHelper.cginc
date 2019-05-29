#include "UnityCG.cginc"

#define THICKNESS 8000.0
#define CENTER 5500.0

#define EARTH_RADIUS 6371000.0
#define EARTH_CENTER float3(0, -EARTH_RADIUS, 0)
#define CLOUDS_START (CENTER - THICKNESS/2)
#define CLOUDS_END (CENTER + THICKNESS/2)

#define TRANSMITTANCE_SAMPLE_STEP 256.0f

static const float bayerOffsets[3][3] = {
	{0, 7, 3},
	{6, 5, 2},
	{4, 1, 8}
};

//Base shape
sampler3D _BaseTex;
float _BaseTile;
sampler2D _HeightDensity;
//Detal shape
sampler3D _DetailTex;
float _DetailTile;
float _DetailStrength;
//Curl distortion
sampler2D _CurlNoise;
float _CurlTile;
float _CurlStrength;
//Top offset
float _CloudTopOffset;

//Overall cloud size.
float _CloudSize;
//Overall Density
float _CloudOverallDensity;
float _CloudCoverageModifier;
float _CloudTypeModifier;

half4 _WindDirection;
sampler2D _WeatherTex;
float _WeatherTexSize;

//Lighting
float _ScatteringCoefficient;
float _ExtinctionCoefficient;
float _SilverIntensity;
float _SilverSpread;

float SampleDensity(float3 worldPos, int lod, bool cheap, out float wetness);

float Remap(float original_value, float original_min, float original_max, float new_min, float new_max)
{
	return new_min + (((original_value - original_min) / (original_max - original_min)) * (new_max - new_min));
}

float RemapClamped(float original_value, float original_min, float original_max, float new_min, float new_max)
{
	return new_min + (saturate((original_value - original_min) / (original_max - original_min)) * (new_max - new_min));
}

float HeightPercent(float3 worldPos) {
	float sqrMag = worldPos.x * worldPos.x + worldPos.z * worldPos.z;

	float heightOffset = EARTH_RADIUS - sqrt(max(0.0, EARTH_RADIUS * EARTH_RADIUS - sqrMag));

	return saturate((worldPos.y + heightOffset - CENTER + THICKNESS / 2) / THICKNESS);
}

static float4 cloudGradients[3] = {
	float4(0, 0.07, 0.08, 0.15),
	float4(0, 0.2, 0.42, 0.6),
	float4(0, 0.08, 0.75, 1)
};

float SampleHeight(float heightPercent,float cloudType) {
	float4 gradient;
	float cloudTypeVal;
	if (cloudType < 0.5) {
		gradient = lerp(cloudGradients[0], cloudGradients[1], cloudType*2.0);
	}
	else {
		gradient = lerp(cloudGradients[1], cloudGradients[2], (cloudType - 0.5)*2.0);
	} 

	return RemapClamped(heightPercent, gradient.x, gradient.y, 0.0, 1.0)
			* RemapClamped(heightPercent, gradient.z, gradient.w, 1.0, 0.0);
}

float3 ApplyWind(float3 worldPos) {
	float heightPercent = HeightPercent(worldPos);
	
	// skew in wind direction
	worldPos.xz -= (heightPercent) * _WindDirection.xy * _CloudTopOffset;

	//animate clouds in wind direction and add a small upward bias to the wind direction
	worldPos.xz -= (_WindDirection.xy + float3(0.0, 0.1, 0.0)) * _Time.y * _WindDirection.z;
	worldPos.y -= _WindDirection.z * 0.4 * _Time.y;
	return worldPos;
}

float HenryGreenstein(float g, float cosTheta) {

	float k = 3.0 / (8.0 * 3.1415926f) * (1.0 - g * g) / (2.0 + g * g);
	return k * (1.0 + cosTheta * cosTheta) / pow(abs(1.0 + g * g - 2.0 * g * cosTheta), 1.5);
}

float SampleDensity(float3 worldPos,int lod, bool cheap, out float wetness) {
	//Store the pos without wind applied.
	float3 unwindWorldPos = worldPos;
	
	//Sample the weather map.
	half4 coverageSampleUV = half4((unwindWorldPos.xz / _WeatherTexSize), 0, 2.5);
	coverageSampleUV.xy = (coverageSampleUV.xy + 0.5);
	float3 weatherData = tex2Dlod(_WeatherTex, coverageSampleUV);
	weatherData *= float3(_CloudCoverageModifier, 1.0, _CloudTypeModifier);
	float cloudCoverage = RemapClamped(weatherData.r, 0.0 ,1.0, 0.3, 1.0);
	float cloudType = weatherData.b;
	wetness = weatherData.g;

	//Calculate the normalized height between[0,1]
	float heightPercent = HeightPercent(worldPos);
	if (heightPercent <= 0.0f || heightPercent >= 1.0f)
		return 0.0;

	//Sample base noise.
	fixed4 tempResult;
	worldPos = ApplyWind(worldPos);
	tempResult = tex3Dlod(_BaseTex, half4(worldPos / _CloudSize * _BaseTile, lod)).rgba;
	float low_freq_fBm = (tempResult.g * .625) + (tempResult.b * 0.25) + (tempResult.a * 0.125);
	float sampleResult = RemapClamped(tempResult.r, 0.0, .1, .0, 1.0);	//perlin-worley
	sampleResult = RemapClamped(low_freq_fBm, -0.5 * sampleResult, 1.0, 0.0, 1.0);

	//Sample Height-Density map.
	float2 densityAndErodeness = tex2D(_HeightDensity, float2(cloudType, heightPercent)).rg;

	sampleResult *= densityAndErodeness.x;
	//Clip the result using coverage map.
	sampleResult = RemapClamped(sampleResult, 1.0 - cloudCoverage.x, 1.0, 0.0, 1.0);
	sampleResult *= cloudCoverage.x;

	if (!cheap) {
		float2 curl_noise = tex2Dlod(_CurlNoise, float4(unwindWorldPos.xz / _CloudSize * _CurlTile, 0.0, 1.0)).rg;
		worldPos.xz += curl_noise.rg * (1.0 - heightPercent) * _CloudSize * _CurlStrength;

		float3 tempResult2;
		tempResult2 = tex3Dlod(_DetailTex, half4(worldPos / _CloudSize * _DetailTile, lod)).rgb;
		float detailsampleResult = (tempResult2.r * 0.625) + (tempResult2.g * 0.25) + (tempResult2.b * 0.125);
		//Detail sample result here is worley-perlin fbm.

		//On cloud marked with low erodness, we see cauliflower style, so when doing erodness, we use 1.0f - detail.
		//On cloud marked with high erodness, we see thin line style, so when doing erodness we use detail.
		float detail_modifier = lerp(1.0f - detailsampleResult, detailsampleResult, densityAndErodeness.y);
		sampleResult = RemapClamped(sampleResult, min(0.8, detail_modifier * _DetailStrength), 1.0, 0.0, 1.0);
	}

	//sampleResult = pow(sampleResult, 1.2);
	return max(0, sampleResult) * _CloudOverallDensity;
}

float _MultiScatteringA;
float _MultiScatteringB;
float _MultiScatteringC;

//We raymarch to sun using length of pattern 1,2,4,8, corresponding to step value.
//First sample(length 1) should sample at length 0.5, meaning an average inside length 1.
//Second sample should sample at 1.5, meaning an average inside [1, 2],
//Third should sample at 3.0, which is [2, 4]
//Forth at 6.0, meaning [4, 8]
static const float shadowSampleDistance[5] = {
	0.5, 1.5, 3.0, 6.0, 12.0
};

static const float shadowSampleContribution[5] = {
	1.0f, 1.0f, 2.0f, 4.0f, 8.0f
};

float SampleOpticsDistanceToSun(float3 worldPos) {
	int mipmapOffset = 0.5;
	float opticsDistance = 0.0f;
	[unroll]
	for (int i = 0; i < 5; i++) {
		half3 direction = _WorldSpaceLightPos0;
		float3 samplePoint = worldPos + direction * shadowSampleDistance[i] * TRANSMITTANCE_SAMPLE_STEP;
		float wetness;
		float sampleResult = SampleDensity(samplePoint, mipmapOffset, true, wetness);
		opticsDistance += shadowSampleContribution[i] * TRANSMITTANCE_SAMPLE_STEP * sampleResult;
		mipmapOffset += 0.5;
	}
	return opticsDistance;
}

float SampleEnergy(float3 worldPos, float3 viewDir) {
	float opticsDistance = SampleOpticsDistanceToSun(worldPos);
	float result = 0.0f;
	[unroll]
	for (int octaveIndex = 0; octaveIndex < 2; octaveIndex++) {	//Multi scattering approximation from Frostbite.
		float transmittance = exp(-_ExtinctionCoefficient * pow(_MultiScatteringB, octaveIndex) * opticsDistance);
		float cosTheta = dot(viewDir, _WorldSpaceLightPos0);
		float ecMult = pow(_MultiScatteringC, octaveIndex);
		float phase = lerp(HenryGreenstein(.1f * ecMult, cosTheta), HenryGreenstein((0.99 - _SilverSpread) * ecMult, cosTheta), 0.5f);
		result += phase * transmittance * _ScatteringCoefficient * pow(_MultiScatteringA, octaveIndex);
	}
	return result;
}

//Code from https://area.autodesk.com/blogs/game-dev-blog/volumetric-clouds/.
bool ray_trace_sphere(float3 center, float3 rd, float3 offset, float radius, out float t1, out float t2) {
	float3 p = center - offset;
	float b = dot(p, rd);
	float c = dot(p, p) - (radius * radius);

	float f = b * b - c;
	if (f >= 0.0) {
		t1 = -b - sqrt(f);
		t2 = -b + sqrt(f);
		return true;
	}
	return false;
}

bool resolve_ray_start_end(float3 ws_origin, float3 ws_ray, out float startt, out float endt) {
	//case includes on ground, inside atm, above atm.
	float ot1, ot2, it1, it2;
	bool outIntersected = ray_trace_sphere(ws_origin, ws_ray, EARTH_CENTER, EARTH_RADIUS + CLOUDS_END, ot1, ot2);
	if (!outIntersected)
		return false;	//you see nothing.

	bool inIntersected = ray_trace_sphere(ws_origin, ws_ray, EARTH_CENTER, EARTH_RADIUS + CLOUDS_START, it1, it2);
	
	if (inIntersected) {
		if (it1 < 0) {
			//we're on ground.
			start = max(it2, 0);
			end = ot2;
		}
		else {
			//we're inside atm, or above atm.
			end = it1;
			if (ot1 < 0) {
				//inside atm.
				start = 0.0f;
			}
			else {
				//above atm.
				start = ot1;
			}
		}
	}
	else {
		end = ot2;
		start = max(ot1, 0);
	}
	return true;
}

struct RaymarchStatus {
	float intensity;
	float depth;
	float depthweightsum;
	float intTransmittance;
}

void InitRaymarchStatus(inout RaymarchStatus result){
	result.intTransmittance = 1.0f;
	result.intensity = 0.0f;
	result.depthweightsum = 0.00001f;
	result.depth = 0.0f;
}

void IntegrateRaymarch(float3 rayPos, float stepsize, inout RaymarchStatus result){
	float wetness;
	float density = SampleDensity(rayPos, 0, false, wetness);
	if (density <= 0.0f)
		return;
	float extinction = _ExtinctionCoefficient * density;

	float clampedExtinction = max(extinction, 1e-7);
	float transmittance = exp(-extinction * sample_step);
			
	float luminance = SampleEnergy(rayPos, dir) * lerp(1.0f, 0.3f, wetness);
	float integScatt = (luminance - luminance * transmittance) / clampedExtinction;
	float depthWeight = result.intTransmittance;		//Is it a better idead to use (1-transmittance) * intTransmittance as depth weight?

	result.intensity += result.intTransmittance * integScatt;
	result.depth += depthWeight * length(rayPos - startPos);
	result.depthweightsum += depthWeight;
	result.intTransmittance *= transmittance;
}