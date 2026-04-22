class_name CarAsset
extends "res://eagl/assets/base_asset.gd"

var car_id = ""
var objects: Array[Dictionary] = []
var part_bundles: Array[Dictionary] = []
var assembly_summary: Dictionary = {}
var locators: Array[Dictionary] = []
var wheel_slots: Array[Dictionary] = []


func _init() -> void:
	asset_type = "car"


func summary() -> Dictionary:
	return {
		"car_id": car_id,
		"object_count": objects.size(),
		"part_bundle_count": part_bundles.size(),
		"assembly_summary": assembly_summary,
		"locator_count": locators.size(),
		"wheel_slot_count": wheel_slots.size(),
		"warnings": warnings,
	}
