class_name EAGLTypes
extends RefCounted

const PLATFORM_HOTPUSUIT2_PS2 := "EAGL_HOTPUSUIT2_PS2"
const PLATFORM_HOTPURSUIT2_PS2 := "EAGL_HOTPURSUIT2_PS2"

const ASSET_TRACK := "track"
const ASSET_CAR := "car"
const ASSET_AUDIO := "audio"


static func is_hp2_ps2_platform(value: String) -> bool:
	var normalized := value.strip_edges().to_upper()
	return normalized == PLATFORM_HOTPUSUIT2_PS2 or normalized == PLATFORM_HOTPURSUIT2_PS2


static func canonical_platform(value: String) -> String:
	if is_hp2_ps2_platform(value):
		return PLATFORM_HOTPUSUIT2_PS2
	return value.strip_edges().to_upper()
