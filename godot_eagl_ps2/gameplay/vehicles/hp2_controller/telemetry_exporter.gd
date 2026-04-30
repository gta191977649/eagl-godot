class_name HP2TelemetryExporter
extends Node


const HEADER := [
	"t",
	"speed_kmh",
	"speed_ms",
	"yaw_rate",
	"sideslip",
	"heading",
	"vx",
	"vy",
	"pos_x",
	"pos_y",
	"accel_long",
	"rpm",
	"gear",
	"shift_cut",
	"grip_FL",
	"grip_FR",
	"grip_RL",
	"grip_RR",
	"load_FL",
	"load_FR",
	"load_RL",
	"load_RR",
	"surface_type",
	"surface_mu",
]

@export var output_dir := "user://hp2_benchmarks"
@export var capture_on_physics_frame := true

var car = null
var is_capturing := false
var test_name := ""
var last_output_path := ""
var _rows: Array[Dictionary] = []


func _ready() -> void:
	car = get_parent()


func _physics_process(_delta: float) -> void:
	if capture_on_physics_frame and is_capturing:
		sample()


func start_capture(new_test_name: String) -> void:
	test_name = new_test_name
	last_output_path = ""
	_rows.clear()
	is_capturing = true
	sample()


func sample() -> void:
	if car == null:
		car = get_parent()
	if car == null:
		return
	_rows.append(car.get_telemetry_row())


func stop_capture() -> String:
	if is_capturing:
		sample()
	is_capturing = false
	last_output_path = _write_csv()
	return last_output_path


func clear() -> void:
	_rows.clear()
	is_capturing = false
	test_name = ""
	last_output_path = ""


func _write_csv() -> String:
	var resolved_dir := ProjectSettings.globalize_path(output_dir)
	DirAccess.make_dir_recursive_absolute(resolved_dir)
	var safe_name := _sanitize_file_stem(test_name)
	if safe_name == "":
		safe_name = "telemetry"
	var path := output_dir.path_join("godot_%s.csv" % safe_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to write HP2 telemetry CSV: %s" % FileAccess.get_open_error())
		return ""

	file.store_line(",".join(HEADER))
	for row in _rows:
		var values: Array[String] = []
		for column in HEADER:
			values.append(_format_csv_value(row.get(column, "")))
		file.store_line(",".join(values))
	file.close()
	return path


func _format_csv_value(value) -> String:
	if value is float:
		return "%.6f" % value
	if value is int:
		return str(value)
	var text := str(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		text = "\"" + text.replace("\"", "\"\"") + "\""
	return text


func _sanitize_file_stem(value: String) -> String:
	var output := value.strip_edges().to_lower()
	var sanitized := ""
	for index in range(output.length()):
		var code := output.unicode_at(index)
		var is_digit := code >= 48 and code <= 57
		var is_lower := code >= 97 and code <= 122
		sanitized += output[index] if is_digit or is_lower else "_"
	while sanitized.contains("__"):
		sanitized = sanitized.replace("__", "_")
	while sanitized.begins_with("_"):
		sanitized = sanitized.substr(1)
	while sanitized.ends_with("_"):
		sanitized = sanitized.substr(0, sanitized.length() - 1)
	return sanitized
