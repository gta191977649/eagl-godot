class_name CarAsset
extends "res://eagl/assets/base_asset.gd"

var car_id = ""
var objects: Array[Dictionary] = []
var part_bundles: Array[Dictionary] = []
var assembly_summary: Dictionary = {}
var assembly_tables: Dictionary = {}
var locators: Array[Dictionary] = []
var wheel_slots: Array[Dictionary] = []
var texture_bank = null


func _init() -> void:
	asset_type = "car"


func summary() -> Dictionary:
	return {
		"car_id": car_id,
		"object_count": objects.size(),
		"part_bundle_count": part_bundles.size(),
		"assembly_summary": assembly_summary,
		"assembly_tables": assembly_tables,
		"locator_count": locators.size(),
		"wheel_slot_count": wheel_slots.size(),
		"texture_count": texture_bank.decoded_count if texture_bank != null else 0,
		"skipped_texture_count": texture_bank.skipped_count if texture_bank != null else 0,
		"warnings": warnings,
	}
