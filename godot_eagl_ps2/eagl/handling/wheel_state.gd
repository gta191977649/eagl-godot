class_name WheelState
extends RefCounted


var slot_id = ""
var axle = "front"
var side = "left"

var local_position_ps2 = Vector3.ZERO
var wheel_radius = 0.33

var rest_length = 1.25
var min_travel = 0.0
var max_travel = 1.5
var preload_force = 0.0

var progressive_spring_scale = 0.0
var spring_coefficient = 50.0
var rebound_damping = 5.0
var bump_damping = 5.0
var bump_stop_coefficient = 20.0

var lateral_grip = 1.0
var longitudinal_grip = 1.0

var steer_angle = 0.0
var roll_angle = 0.0
var world_attachment_ps2 = Vector3.ZERO
var world_wheel_center_ps2 = Vector3.ZERO
var contact_point_ps2 = Vector3.ZERO
var normal_ps2 = Vector3(0.0, 0.0, 1.0)
var material_id = -1
var suspension_distance = 0.0
var center_offset = 0.0

var compression = 0.0
var prev_compression = 0.0
var compression_velocity = 0.0
var suspension_force = 0.0
var grounded = false

var forward_speed = 0.0
var lateral_speed = 0.0
var angular_speed = 0.0
var load_ratio = 0.0


func reset_runtime() -> void:
	world_attachment_ps2 = Vector3.ZERO
	world_wheel_center_ps2 = Vector3.ZERO
	contact_point_ps2 = Vector3.ZERO
	normal_ps2 = Vector3(0.0, 0.0, 1.0)
	material_id = -1
	suspension_distance = 0.0
	center_offset = 0.0
	roll_angle = 0.0
	compression = 0.0
	prev_compression = 0.0
	compression_velocity = 0.0
	suspension_force = 0.0
	grounded = false
	forward_speed = 0.0
	lateral_speed = 0.0
	angular_speed = 0.0
	load_ratio = 0.0


func is_front() -> bool:
	return axle == "front"


func is_rear() -> bool:
	return axle == "rear"


func is_left() -> bool:
	return side == "left"
