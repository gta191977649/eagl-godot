class_name TrackDefinition
extends Resource

@export var id := ""
@export var display_name := ""
@export var editable_track_scene: PackedScene
@export_file("*.scn") var source_scn_path := ""
@export var player_start_marker_path: NodePath
