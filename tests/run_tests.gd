extends SceneTree
## Lanceur de tests minimaliste, sans dépendance.
## Exécution :  tools\run_tests.bat   (ou : godot --headless --path . --import  puis
##               godot --headless --path . -s tests/run_tests.gd)
## Chaque fichier tests/test_*.gd doit exposer des méthodes `test_*` et hériter de TestCase.

const TestCase := preload("res://tests/test_case.gd")

var _passed := 0
var _failed := 0


func _init() -> void:
	var dir := DirAccess.open("res://tests")
	var files: Array[String] = []
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
			files.append(f)
	files.sort()
	for f in files:
		_run_file("res://tests/" + f)
	print("\n=== %d réussi(s), %d échec(s) ===" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _run_file(path: String) -> void:
	var script: GDScript = load(path)
	var case: TestCase = script.new()
	print("\n# " + path.get_file())
	for m in script.get_script_method_list():
		var name: String = m.name
		if not name.begins_with("test_"):
			continue
		case.reset()
		case.call(name)
		if case.failures.is_empty():
			_passed += 1
			print("  ✔ " + name)
		else:
			_failed += 1
			print("  ✘ " + name)
			for msg in case.failures:
				print("      " + msg)
