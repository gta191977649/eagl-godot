extends RigidBody3D

const CAMERA_DISTANCE := 8.5
const CAMERA_TARGET_HEIGHT := 1.4
const CAMERA_LOOK_AHEAD := 2.5
const CAMERA_MOUSE_SENSITIVITY := 0.0035
const CAMERA_MIN_PITCH := deg_to_rad(-18.0)
const CAMERA_MAX_PITCH := deg_to_rad(45.0)
const CAMERA_FOLLOW_LERP_SPEED := 6.0


@export var draw_debug: bool = false
@export var wheels: Array[RaycastWheel]

@export var acceleration := 600.0
#@export var deceleration := 200.0
@export var max_speed := 20.0
@export var tire_turn_speed := 2.0
@export var tire_max_turn_degrees := 25.0

@export var accel_curve : Curve




var motor_input := 0


@export var ui_accel_ratio : ProgressBar

@export var camera_path: NodePath
@onready var debug_camera: Camera3D = get_node_or_null(camera_path) as Camera3D

var _camera_yaw := 0.0
var _camera_pitch := deg_to_rad(14.0)
var _camera_target_position := Vector3.ZERO
var _camera_position := Vector3.ZERO

func _ready() -> void:
	_ensure_debug_camera()
	_seed_camera_from_car()


func _process(delta: float) -> void:
	_update_debug_camera(delta)

func _basic_steering_rotation(delta: float) -> void:
	var turn_input := Input.get_axis("turn_l","turn_r") * tire_turn_speed

	if turn_input:
		$WheelFL.rotation.y = clampf($WheelFL.rotation.y + turn_input * delta, deg_to_rad(-tire_max_turn_degrees),deg_to_rad(tire_max_turn_degrees))
		

func _physics_process(delta: float) -> void:
	var grounded := false

	for wheel in wheels:
		if wheel.is_colliding():
			grounded = true

		wheel.force_raycast_update()
		_do_single_wheel_suspension(wheel)
		_do_single_wheel_acceleration(wheel)

	if grounded:
		center_of_mass = Vector3.ZERO
	else:
		center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		center_of_mass = Vector3.DOWN * 0.5


func _get_point_velocity(point: Vector3) -> Vector3:
	return linear_velocity + angular_velocity.cross(point - global_position)


func _do_single_wheel_acceleration(ray: RaycastWheel) -> void:
	var forward_dir := -ray.global_basis.z
	var vel := forward_dir.dot(linear_velocity)
	# Wheel Spin
	ray.wheel.rotate_x(-vel * get_process_delta_time() / ray.wheel_radius)


	if ray.is_colliding() and ray.is_motor:
		var contact := ray.wheel.global_position
		var force_pos := contact - global_position
		var ac := 0.0

		if ray.is_motor and motor_input:
			var speed_ratio := vel/ max_speed
			ac = accel_curve.sample_baked(speed_ratio)
			
			var force_vector := forward_dir * acceleration * motor_input * ac

			var force_vector_projected :Vector3 =  (force_vector - ray.get_collision_normal()* force_vector.dot(ray.get_collision_normal()))

			apply_force(force_vector,force_pos)	
			#apply_force(force_vector_projected,force_pos)
			if draw_debug: DebugDraw3D.draw_arrow_ray(contact,force_vector.normalized(),2.5,Color.RED,0.1)
			if draw_debug: DebugDraw3D.draw_arrow_ray(contact,force_vector_projected.normalized(),2.5,Color.BLACK,0.1)
			# 	elif abs(vel) > 0.015 and not motor_input:
			# 	var drag_force_vector = global_basis.z * deceleration * signf(vel)
			# 	apply_force(drag_force_vector,force_pos)
			# 	if draw_debug: DebugDraw3D.draw_arrow_ray(contact,drag_force_vector.normalized(),2.5,Color.PINK,0.1)
		
		if draw_debug:
			ui_accel_ratio.value = ac * 100.0 
		



  
func _unhandled_input(event: InputEvent) -> void:
	# input control:
	if event.is_action_pressed("accelerate"):
		motor_input = 1
	elif event.is_action_released("accelerate"):
		motor_input = 0

	if event.is_action_pressed("brakes"):
		motor_input = -1
	elif event.is_action_released("brakes"):
		motor_input = 0


	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw -= event.relative.x * CAMERA_MOUSE_SENSITIVITY
		_camera_pitch = clampf(
			_camera_pitch - event.relative.y * CAMERA_MOUSE_SENSITIVITY,
			CAMERA_MIN_PITCH,
			CAMERA_MAX_PITCH
		)




func _do_single_wheel_suspension(ray: RaycastWheel) -> void:
	if ray.is_colliding(): 
		# remove the pulling force of the car
		ray.target_position.y = -(ray.rest_dist + ray.wheel_radius + ray.over_extend)


		var contact := ray.get_collision_point()

		var spring_up_dir := ray.global_basis.y
		var spring_len := ray.global_position.distance_to(contact) - ray.wheel_radius
		var offset := ray.rest_dist - spring_len

		# Set "WheelMesh" Pos
		var wheel_trans := ray.wheel
		if wheel_trans:
			wheel_trans.position.y = -spring_len

		else :
			print("Error find WheelMesh")



		var spring_force := ray.spring_strength * offset
		# damping force = damping * relative velocity
		var world_vel := _get_point_velocity(contact)
		var relative_vel := spring_up_dir.dot(world_vel)

		# calc spring_damping
		var z := ray.dump_coff
		var k := ray.spring_strength
		var spring_damping := z * (2 * sqrt(k * mass))

		var spring_damp_force := ray.spring_damping * relative_vel

		var force_vector := (spring_force - spring_damp_force) * ray.get_collision_normal()

		contact = ray.wheel.global_position
		var force_pos_offset := contact - global_position

		# debug draw
		if draw_debug:
			# render spring force vec
			DebugDraw3D.draw_arrow_ray(
				contact,
				force_vector.normalized(),
				2.5,
				Color.BLUE,
				0.05
			)
			# render component debug
		
			var text_pos := ray.position
			DebugDraw3D.draw_text(text_pos, ray.name)
			var width := 0.1

			var ca = wheel_trans.global_position - Vector3(-width,0,0)
			var cb = wheel_trans.global_position - Vector3(width,0,0)
			
			DebugDraw3D.draw_cylinder_ab(ca,cb,ray.wheel_radius)
		

		apply_force(force_vector,force_pos_offset)

	DebugDraw3D.draw_sphere(ray.get_collision_point(),0.5)



func _ensure_debug_camera() -> void:
	if debug_camera != null:
		debug_camera.current = true
		return

	debug_camera = Camera3D.new()
	debug_camera.name = "DebugCamera"
	debug_camera.top_level = true
	debug_camera.current = true
	debug_camera.fov = 70.0
	add_child(debug_camera)


func _seed_camera_from_car() -> void:
	var forward := (global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	_camera_yaw = atan2(-forward.z, forward.x)
	_camera_target_position = global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT
	var horizontal_radius := cos(_camera_pitch) * CAMERA_DISTANCE
	var orbit_offset := Vector3(
		-cos(_camera_yaw) * horizontal_radius,
		sin(_camera_pitch) * CAMERA_DISTANCE,
		-sin(_camera_yaw) * horizontal_radius
	)
	_camera_position = _camera_target_position + forward * CAMERA_LOOK_AHEAD + orbit_offset
	if debug_camera != null:
		debug_camera.global_position = _camera_position
		debug_camera.look_at(_camera_target_position, Vector3.UP)


func _update_debug_camera(delta: float) -> void:


	if debug_camera == null:
		return

	var forward := global_transform.basis * Vector3(0.0, 0.0, 1.0)
	var desired_target := global_transform.origin + Vector3.UP * CAMERA_TARGET_HEIGHT + forward * CAMERA_LOOK_AHEAD
	var horizontal_radius := cos(_camera_pitch) * CAMERA_DISTANCE
	var orbit_offset := Vector3(
		-cos(_camera_yaw) * horizontal_radius,
		sin(_camera_pitch) * CAMERA_DISTANCE,
		-sin(_camera_yaw) * horizontal_radius
	)
	var desired_position := desired_target + orbit_offset
	var follow_weight := clampf(delta * CAMERA_FOLLOW_LERP_SPEED, 0.0, 1.0)
	_camera_target_position = _camera_target_position.lerp(desired_target, follow_weight)
	_camera_position = _camera_position.lerp(desired_position, follow_weight)
	debug_camera.global_position = _camera_position
	debug_camera.look_at(_camera_target_position, Vector3.UP)
