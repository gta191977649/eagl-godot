class_name HP2BenchmarkRunner
extends Node


const HP2CarScene := preload("res://gameplay/vehicles/hp2_controller/hp2_car.tscn")
const HP2ScriptedInputScript := preload("res://gameplay/vehicles/hp2_controller/scripted_input.gd")
const HP2TelemetryExporterScript := preload("res://gameplay/vehicles/hp2_controller/telemetry_exporter.gd")
const GlobalBHandlingLoaderScript := preload("res://eagl/handling/globalb_handling_loader.gd")

@export var auto_run := true
@export var quit_when_done := true
@export var output_dir := "user://hp2_benchmarks"
@export var car_name := "CORVETTE"
@export var duplicate_index := 1
@export var drive_type := "RWD"
@export_global_dir var game_root := ""
@export var run_surface_validation := true

var car = null
var telemetry = null
var scripted_input = null
var exported_files: Array[String] = []


func _ready() -> void:
	if auto_run:
		call_deferred("_run_all_tests_deferred")


func run_all_tests() -> Array[String]:
	_ensure_car()
	exported_files.clear()
	await _run("step_steer", _phases_step_steer())
	await _run("acceleration", _phases_acceleration())
	await _run("braking", _phases_braking())
	await _run("drift_init", _phases_drift_init())
	await _run("steady_circle", _phases_steady_circle())
	if run_surface_validation:
		await _run_surface_validation("asphalt")
		await _run_surface_validation("dirt")
		await _run_surface_validation("grass")
		await _run_airborne_spin_validation()
	return exported_files


func _run_all_tests_deferred() -> void:
	await run_all_tests()
	for path in exported_files:
		print("HP2 benchmark CSV: %s" % ProjectSettings.globalize_path(path))
	if quit_when_done:
		get_tree().quit()


func _ensure_car() -> void:
	if car != null and telemetry != null:
		return
	car = get_node_or_null("HP2Car")
	if car == null:
		var instance := HP2CarScene.instantiate()
		instance.name = "HP2Car"
		add_child(instance)
		car = instance
	telemetry = car.get_node_or_null("TelemetryExporter")
	if telemetry == null:
		telemetry = HP2TelemetryExporterScript.new()
		telemetry.name = "TelemetryExporter"
		car.add_child(telemetry)
	telemetry.output_dir = output_dir
	scripted_input = HP2ScriptedInputScript.new()
	car.input_source = scripted_input
	var loaded_config = _load_benchmark_config()
	if loaded_config != null:
		car.apply_config(loaded_config)
	_write_reference_params()


func _run(test_name: String, phases: Array[Dictionary]) -> void:
	await _reset_car()
	telemetry.start_capture(test_name)
	for phase in phases:
		scripted_input.set_values(
			float(phase.get("throttle", 0.0)),
			float(phase.get("brake", 0.0)),
			float(phase.get("steer", 0.0))
		)
		await _wait(float(phase.get("duration", 0.0)))
	var path: String = telemetry.stop_capture()
	if path != "":
		exported_files.append(path)


func _run_surface_validation(surface: String) -> void:
	var previous_surface: String = car.surface_type
	car.surface_type = surface
	await _reset_car()
	car.set_forward_speed(100.0 / 3.6)
	telemetry.start_capture("surface_%s_braking" % surface)
	scripted_input.set_values(0.0, 1.0, 0.0)
	await _wait(8.0)
	var path: String = telemetry.stop_capture()
	if path != "":
		exported_files.append(path)
	car.surface_type = previous_surface


func _run_airborne_spin_validation() -> void:
	await _reset_car()
	car.set_airborne_debug_enabled(true, 25.0)
	scripted_input.set_values(0.0, 0.0, 0.0)
	await _wait(0.5)
	var coast_snapshot: Dictionary = car.get_debug_snapshot()
	var coast_rear_rpm := 0.0
	for coast_wheel in coast_snapshot.get("wheels", []):
		if String(coast_wheel.get("slot", "")).begins_with("R"):
			coast_rear_rpm = maxf(coast_rear_rpm, absf(float(coast_wheel.get("rpm", 0.0))))
	scripted_input.set_values(1.0, 0.0, 0.0)
	await _wait(1.0)
	var snapshot: Dictionary = car.get_debug_snapshot()
	var rear_rpm := 0.0
	for wheel in snapshot.get("wheels", []):
		if String(wheel.get("slot", "")).begins_with("R"):
			rear_rpm = maxf(rear_rpm, absf(float(wheel.get("rpm", 0.0))))
	print("HP2 airborne validation coast_rear_wheel_rpm=%.2f throttle_rear_wheel_rpm=%.2f grounded_load_RL=%.2f height=%.2f" % [
		coast_rear_rpm,
		rear_rpm,
		float(car.get_telemetry_row().get("load_RL", 0.0)),
		car.global_position.y,
	])
	scripted_input.set_values(0.0, 0.0, 0.0)
	car.set_airborne_debug_enabled(false, car.ride_height)


func _wait(seconds: float) -> void:
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()


func _reset_car() -> void:
	scripted_input.set_values(0.0, 0.0, 0.0)
	car.reset_runtime_state(Transform3D(Basis.IDENTITY, Vector3(0.0, car.ride_height, 0.0)))
	await get_tree().physics_frame


func _load_benchmark_config():
	var globalb_path := _resolved_globalb_path()
	if globalb_path == "":
		push_warning("HP2 benchmark is using default controller params; GLOBALB.BUN was not found.")
		return null
	var loader = GlobalBHandlingLoaderScript.new()
	var loaded = loader.load_config_from_globalb(globalb_path, car_name.to_upper(), duplicate_index, drive_type)
	if loaded == null:
		push_warning("HP2 benchmark failed to load %s duplicate %d from %s" % [car_name, duplicate_index, globalb_path])
	return loaded


func _resolved_globalb_path() -> String:
	var root := game_root
	if root == "":
		root = str(ProjectSettings.get_setting("eagl/game_root", ""))
	if root == "":
		root = OS.get_environment("EAGL_HP2_GAME_ROOT")
	if root == "":
		return ""
	var bun_path := root.path_join("GLOBAL/GLOBALB.BUN")
	if FileAccess.file_exists(bun_path):
		return bun_path
	var lzc_path := root.path_join("GLOBAL/GLOBALB.LZC")
	if FileAccess.file_exists(lzc_path):
		return lzc_path
	return ""


func _write_reference_params() -> void:
	var resolved_dir := ProjectSettings.globalize_path(output_dir)
	DirAccess.make_dir_recursive_absolute(resolved_dir)
	var path := output_dir.path_join("godot_hp2_params.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Failed to write HP2 benchmark params: %s" % FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(car.get_reference_params(), "\t"))
	file.close()


func _phases_step_steer() -> Array[Dictionary]:
	return [
		{"throttle": 0.6, "brake": 0.0, "steer": 0.0, "duration": 5.0},
		{"throttle": 0.3, "brake": 0.0, "steer": 0.5, "duration": 4.0},
	]


func _phases_acceleration() -> Array[Dictionary]:
	return [
		{"throttle": 1.0, "brake": 0.0, "steer": 0.0, "duration": 15.0},
	]


func _phases_braking() -> Array[Dictionary]:
	return [
		{"throttle": 1.0, "brake": 0.0, "steer": 0.0, "duration": 8.0},
		{"throttle": 0.0, "brake": 1.0, "steer": 0.0, "duration": 8.0},
	]


func _phases_drift_init() -> Array[Dictionary]:
	return [
		{"throttle": 0.8, "brake": 0.0, "steer": 0.0, "duration": 4.0},
		{"throttle": 1.0, "brake": 0.0, "steer": 0.7, "duration": 5.0},
	]


func _phases_steady_circle() -> Array[Dictionary]:
	return [
		{"throttle": 0.8, "brake": 0.0, "steer": 0.0, "duration": 3.0},
		{"throttle": 0.45, "brake": 0.0, "steer": 0.4, "duration": 12.0},
	]
