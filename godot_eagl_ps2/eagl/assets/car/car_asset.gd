class_name CarAsset
extends "res://eagl/assets/base_asset.gd"

var car_id = ""
var objects: Array[Dictionary] = []
var part_bundles: Array[Dictionary] = []
var assembly_summary: Dictionary = {}


func _init() -> void:
	asset_type = "car"


func summary() -> Dictionary:
	return {
		"car_id": car_id,
		"object_count": objects.size(),
		"part_bundle_count": part_bundles.size(),
		"assembly_summary": assembly_summary,
		"warnings": warnings,
	}
