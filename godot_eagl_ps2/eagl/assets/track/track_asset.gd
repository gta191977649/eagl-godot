class_name TrackAsset
extends "res://eagl/assets/base_asset.gd"

var track_id := ""
var objects: Array[Dictionary] = []
var solid_packs: Array[Dictionary] = []
var scenery_sections: Array[Dictionary] = []
var scenery_instances: Array[Dictionary] = []
var scenery_template_offsets: Dictionary = {}
var unknown_chunks: Array[Dictionary] = []
var environment_config: Dictionary = {}
var collision_surfaces: Array[Dictionary] = []
var collision_stats: Dictionary = {}
var route_points: Array[Dictionary] = []
var route_stats: Dictionary = {}
var texture_bank = null
var bounds := AABB()
var has_bounds := false


func _init() -> void:
	asset_type = "track"


func vertex_count() -> int:
	var count := 0
	for obj in objects:
		for block in obj.get("blocks", []):
			count += block.get("run", {}).get("vertices", []).size()
	return count


func block_count() -> int:
	var count := 0
	for obj in objects:
		count += obj.get("blocks", []).size()
	return count


func collision_triangle_count() -> int:
	var count := 0
	for surface in collision_surfaces:
		count += int(surface.get("triangle_count", 0))
	return count


func summary() -> Dictionary:
	return {
		"track_id": track_id,
		"object_count": objects.size(),
		"block_count": block_count(),
		"vertex_count": vertex_count(),
		"collision_surface_count": collision_surfaces.size(),
		"collision_triangle_count": collision_triangle_count(),
		"collision_stats": collision_stats.duplicate(true),
		"route_point_count": route_points.size(),
		"route_stats": route_stats.duplicate(true),
		"solid_pack_count": solid_packs.size(),
		"scenery_section_count": scenery_sections.size(),
		"scenery_instance_count": scenery_instances.size(),
		"unknown_chunk_count": unknown_chunks.size(),
		"has_environment_config": not environment_config.is_empty(),
		"texture_count": texture_bank.decoded_count if texture_bank != null else 0,
		"skipped_texture_count": texture_bank.skipped_count if texture_bank != null else 0,
		"bounds": bounds,
		"warnings": warnings,
	}
