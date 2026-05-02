extends Control

@export var max_speed_kmh := 260.0
@export var max_rpm := 8000.0
@export var redline_rpm := 6800.0

var speed_kmh := 0.0
var rpm := 0.0
var gear := 1


func set_values(new_speed_kmh: float, new_rpm: float, new_gear: int, new_redline_rpm: float = 0.0) -> void:
	speed_kmh = maxf(new_speed_kmh, 0.0)
	rpm = maxf(new_rpm, 0.0)
	gear = new_gear
	if new_redline_rpm > 0.0:
		redline_rpm = new_redline_rpm
	queue_redraw()


func _draw() -> void:
	var bounds := get_rect().size
	if bounds.x <= 1.0 or bounds.y <= 1.0:
		return

	var center := Vector2(bounds.x * 0.48, bounds.y * 0.68)
	var radius := minf(bounds.x * 0.43, bounds.y * 0.62)
	var start_angle := deg_to_rad(225.0)
	var end_angle := deg_to_rad(340.0)
	var font := get_theme_default_font()
	var font_size := 24
	if font == null:
		return

	draw_circle(center, radius + 10.0, Color(0.0, 0.0, 0.0, 0.42))
	draw_arc(center, radius, start_angle, end_angle, 72, Color(0.95, 0.95, 0.9, 0.9), 6.0, true)
	_draw_redline(center, radius, start_angle, end_angle)
	_draw_ticks(center, radius, start_angle, end_angle, font, font_size)
	_draw_needle(center, radius, start_angle, end_angle)
	_draw_gear(center, font)
	_draw_speed_readout(center, radius, font)


func _draw_redline(center: Vector2, radius: float, start_angle: float, end_angle: float) -> void:
	var redline_start := clampf(redline_rpm / maxf(max_rpm, 1.0), 0.0, 1.0)
	var red_start_angle := lerpf(start_angle, end_angle, redline_start)
	draw_arc(center, radius + 2.0, red_start_angle, end_angle, 24, Color(0.95, 0.08, 0.08, 0.95), 14.0, true)


func _draw_ticks(center: Vector2, radius: float, start_angle: float, end_angle: float, font: Font, font_size: int) -> void:
	var max_thousands := maxi(1, int(ceil(max_rpm / 1000.0)))
	for index in range(max_thousands + 1):
		var t := float(index) / float(max_thousands)
		var angle := lerpf(start_angle, end_angle, t)
		var dir := Vector2(cos(angle), sin(angle))
		var tick_outer := center + dir * radius
		var tick_inner := center + dir * (radius - (12.0 if index % 2 == 0 else 8.0))
		draw_line(tick_inner, tick_outer, Color.WHITE, 4.0 if index % 2 == 0 else 2.5, true)
		if index > 0:
			var label := str(index)
			var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
			var label_pos := center + dir * (radius - 38.0) - label_size * 0.5
			draw_string(font, label_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.96, 0.96, 0.9, 0.96))


func _draw_needle(center: Vector2, radius: float, start_angle: float, end_angle: float) -> void:
	var rpm_t := clampf(rpm / maxf(max_rpm, 1.0), 0.0, 1.0)
	var angle := lerpf(start_angle, end_angle, rpm_t)
	var dir := Vector2(cos(angle), sin(angle))
	var tip := center + dir * (radius - 14.0)
	var tail := center - dir * 12.0
	draw_line(tail, tip, Color(0.98, 0.68, 0.16, 1.0), 6.0, true)
	draw_circle(center, 17.0, Color(0.05, 0.05, 0.05, 0.92))
	draw_circle(center, 12.0, Color(0.92, 0.92, 0.86, 0.95))


func _draw_gear(center: Vector2, font: Font) -> void:
	var gear_text := "R" if gear < 0 else str(gear)
	var font_size := 38
	var text_size := font.get_string_size(gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	draw_string(font, center - text_size * 0.5 + Vector2(0.0, text_size.y * 0.35), gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.95, 0.95, 0.9, 1.0))


func _draw_speed_readout(center: Vector2, radius: float, font: Font) -> void:
	var speed_text := "%03d" % int(round(speed_kmh))
	var box_size := Vector2(108.0, 44.0)
	var box_pos := center + Vector2(-box_size.x * 0.5, radius * 0.42)
	draw_rect(Rect2(box_pos, box_size), Color(0.08, 0.06, 0.04, 0.86), true)
	draw_rect(Rect2(box_pos, box_size), Color(0.88, 0.72, 0.38, 0.82), false, 2.0)

	var font_size := 36
	var text_size := font.get_string_size(speed_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var text_pos := box_pos + (box_size - text_size) * 0.5 + Vector2(0.0, text_size.y * 0.34)
	draw_string(font, text_pos, speed_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(1.0, 0.83, 0.42, 1.0))
