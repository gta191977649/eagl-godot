class_name EAGLBaseAsset
extends Resource

@export var asset_type := ""
@export var source_path := ""

var source_files: Dictionary = {}
var metadata: Dictionary = {}
var warnings: Array[String] = []


func add_warning(message: String) -> void:
	warnings.append(message)
	push_warning(message)
