from types import SimpleNamespace

from map_tools_ps2.special_textures import reflection_layer_for_texture
from map_tools_ps2.textures import _reflection_channel_stats


def _classified(rgba: bytes) -> str:
    luminance_max, grayscale_fraction, correlation = _reflection_channel_stats(rgba)
    return reflection_layer_for_texture(SimpleNamespace(
        luminance_max=luminance_max,
        grayscale_fraction=grayscale_fraction,
        alpha_luminance_correlation=correlation,
    ))


def test_reflection_layer_classifies_black_control_raster_as_mask():
    assert _classified(bytes((0, 0, 0, 230, 0, 0, 0, 254))) == "mask"


def test_reflection_layer_classifies_inverse_grayscale_alpha_as_mask():
    assert _classified(bytes((0, 0, 0, 255, 255, 255, 255, 0))) == "mask"


def test_reflection_layer_does_not_turn_coloured_water_into_mask():
    assert _classified(bytes((25, 70, 90, 255, 100, 35, 20, 0))) == "surface"


def test_reflection_layer_never_uses_texture_name():
    texture = SimpleNamespace(
        name="PUDDLE_MASK_LOOKING_NAME",
        luminance_max=120.0,
        grayscale_fraction=0.0,
        alpha_luminance_correlation=-1.0,
    )
    assert reflection_layer_for_texture(texture) == "surface"
