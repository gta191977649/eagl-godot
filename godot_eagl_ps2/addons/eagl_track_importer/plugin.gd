@tool
extends EditorPlugin

var _import_plugin


func _enter_tree() -> void:
	_import_plugin = preload("res://addons/eagl_track_importer/eagl_track_import_plugin.gd").new()
	add_import_plugin(_import_plugin)


func _exit_tree() -> void:
	if _import_plugin != null:
		remove_import_plugin(_import_plugin)
	_import_plugin = null
