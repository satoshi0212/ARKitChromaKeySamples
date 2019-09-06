#include <metal_stdlib>
using namespace metal;

kernel void ChromaKeyFilter(texture2d<float, access::read> inTexture [[ texture(0) ]],
                            texture2d<float, access::write> outTexture [[ texture(1) ]],
                            const device float *colorRed [[ buffer(0) ]],
                            const device float *colorGreen [[ buffer(1) ]],
                            const device float *colorBlue [[ buffer(2) ]],
                            const device float *threshold [[ buffer(3) ]],
                            const device float *smoothing [[ buffer(4) ]],
                            uint2 gid [[ thread_position_in_grid ]])
{
    const float4 inColor = inTexture.read(gid);
    const float3 maskColor = float3(*colorRed, *colorGreen, *colorBlue);

    const float3 YVector = float3(0.2989, 0.5866, 0.1145);

    const float maskY = dot(maskColor, YVector);
    const float maskCr = 0.7131 * (maskColor.r - maskY);
    const float maskCb = 0.5647 * (maskColor.b - maskY);

    const float Y = dot(inColor.rgb, YVector);
    const float Cr = 0.7131 * (inColor.r - Y);
    const float Cb = 0.5647 * (inColor.b - Y);

    const float alpha = smoothstep(*threshold, *threshold + *smoothing, distance(float2(Cr, Cb), float2(maskCr, maskCb)));

    const float4 outColor = alpha * float4(inColor.r, inColor.g, inColor.b, 1.0);
    outTexture.write(outColor, gid);
}

//#include <metal_stdlib>
//using namespace metal;
//
///// - SeeAlso: http://www.fundza.com/rman_shaders/smoothstep/index.html
//kernel void ChromaKeyFilter(
//                            // 入力画像情報
//                            texture2d<float, access::read> inTexture [[ texture(0) ]],
//                            // 出力画像情報
//                            texture2d<float, access::write> outTexture [[ texture(1) ]],
//                            // マスク対象の赤成分
//                            const device float *colorRed [[ buffer(0) ]],
//                            // マスク対象の緑成分
//                            const device float *colorGreen [[ buffer(1) ]],
//                            // マスク対象の青成分
//                            const device float *colorBlue [[ buffer(2) ]],
//                            // 透過値が0-1の領域の下限
//                            const device float *threshold [[ buffer(3) ]],
//                            // 透過値が0-1の領域の下限から上限までの絶対値
//                            const device float *smoothing [[ buffer(4) ]],
//                            // 座標情報
//                            uint2 gid [[ thread_position_in_grid ]])
//{
//    const float4 inColor = inTexture.read(gid);
//
//    // maskの対象の色。緑色を透過するためmaskColorはfloat3(0, 1, 0)になる
//    const float3 maskColor = float3(*colorRed, *colorGreen, *colorBlue);
//
//    // RGBからYへの射
//    const float3 YVector = float3(0.2989, 0.5866, 0.1145);
//
//    // maskColor(緑色)をYCrCbへ変換
//    const float maskY = dot(maskColor, YVector);
//    const float maskCr = 0.7131 * (maskColor.r - maskY);
//    const float maskCb = 0.5647 * (maskColor.b - maskY);
//
//    // 座標のRGBをYCrCbへ変換
//    const float Y = dot(inColor.rgb, YVector);
//    const float Cr = 0.7131 * (inColor.r - Y);
//    const float Cb = 0.5647 * (inColor.b - Y);
//
//    // YCrCb、閾値、緑色との距離により透過度を算出
//    const float alpha = smoothstep(
//                                   *threshold,
//                                   *threshold + *smoothing,
//                                   distance(float2(Cr, Cb), float2(maskCr, maskCb))
//                                   );
//
//    // 座標のRGBを算出した透過度で出力する色を計算
//    const float4 outColor = alpha * float4(inColor.r, inColor.g, inColor.b, 1.0);
//    outTexture.write(outColor, gid);
//}
