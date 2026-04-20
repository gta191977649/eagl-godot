class_name CarAsset
extends "res://eagl/assets/base_asset.gd"

var car_id := ""
var objects: Array[Dictionary] = []
var dashboard_objects: Array[Dictionary] = []
var solid_packs: Array[Dictionary] = []
var dashboard_solid_packs: Array[Dictionary] = []
var part_groups: Dictionary = {}
var locators: Array[Dictionary] = []
var unknown_chunks: Array[Dictionary] = []
var texture_bank = null
var physics_tuning: Dictionary = {}
var bounds := AABB()
var has_bounds := false


func _init() -> void:
	asset_type = "car"


func all_objects() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append_array(objects)
	out.append_array(dashboard_objects)
	return out


func vertex_count() -> int:
	var count := 0
	for obj in all_objects():
		for block in obj.get("blocks", []):
			count += block.get("run", {}).get("vertices", []).size()
	return count


func block_count() -> int:
	var count := 0
	for obj in all_objects():
		count += obj.get("blocks", []).size()
	return count


func texture_ref_count() -> int:
	var count := 0
	for obj in all_objects():
		count += obj.get("texture_hashes", []).size()
	return count


func summary() -> Dictionary:
	return {
		"car_id": car_id,
		"object_count": objects.size(),
		"dashboard_object_count": dashboard_objects.size(),
		"block_count": block_count(),
		"vertex_count": vertex_count(),
		"texture_ref_count": texture_ref_count(),
		"solid_pack_count": solid_packs.size(),
		"dashboard_solid_pack_count": dashboard_solid_packs.size(),
		"locator_count": locators.size(),
		"unknown_chunk_count": unknown_chunks.size(),
		"part_groups": part_groups.duplicate(true),
		"physics_tuning": physics_tuning.duplicate(true),
		"texture_count": texture_bank.decoded_count if texture_bank != null else 0,
		"skipped_texture_count": texture_bank.skipped_count if texture_bank != null else 0,
		"bounds": bounds,
		"warnings": warnings,
	}
