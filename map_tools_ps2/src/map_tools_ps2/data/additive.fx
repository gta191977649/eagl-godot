texture gSourceTexture < string textureState="0,Texture"; >;

technique hp2AdditiveSurface
{
    pass P0
    {
        Texture[0] = gSourceTexture;
        ColorOp[0] = Modulate;
        ColorArg1[0] = Texture;
        ColorArg2[0] = Diffuse;
        AlphaOp[0] = Modulate;
        AlphaArg1[0] = Texture;
        AlphaArg2[0] = Diffuse;
        AlphaBlendEnable = true;
        SrcBlend = SrcAlpha;
        DestBlend = One;
        ZWriteEnable = false;
    }
}
