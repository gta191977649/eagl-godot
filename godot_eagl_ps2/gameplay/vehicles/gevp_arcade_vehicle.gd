extends "res://addons/gevp/scripts/vehicle.gd"


func get_camera_forward_vector() -> Vector3:
	# GEVP arcade_car's visual/driving forward is opposite the chase camera's
	# default +Z assumption, so expose the corrected forward just for camera use.
	return -(global_transform.basis * Vector3(0.0, 0.0, 1.0))
