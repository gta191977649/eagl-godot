from types import SimpleNamespace

import pytest

from map_tools_ps2.gui import ExportGui


def value(item):
    return SimpleNamespace(get=lambda: item)


def gui(tmp_path, packed, track="31 - Medit", export_type="MTA Resource"):
    instance = ExportGui.__new__(ExportGui)
    for name in ("resource_name", "collision", "native_collision", "vertex_colors", "chunk_size",
                 "lod_mode", "lod_min_size", "lod_target_ratio", "lod_small_size",
                 "lod_small_diagonal", "lod_min_triangles", "lod_repeated_triangles", "lod_repeated_count"):
        setattr(instance, name, value(""))
    instance.track = value(track)
    instance.export_type = value(export_type)
    instance.export_packed = value(packed)
    instance.output_dir = value(str(tmp_path))
    instance.game_dir = value("D:/ps2_game/GAME")
    instance.author = value("tester")
    return instance


@pytest.mark.parametrize("track,family", [(11,"parkland"),(26,"desert"),(31,"medit"),(46,"alpine"),(66,"tropic")])
def test_packed_exports_selected_family_without_creating_standalone_folder(tmp_path, track, family):
    args, target = gui(tmp_path, True, str(track))._cli_args()
    assert args[0] == "export-mta-families"
    assert args[args.index("--family") + 1] == family
    assert args[args.index("--output") + 1] == str(tmp_path)
    assert target == tmp_path / f"hp2_{family}_pack"
    assert list(tmp_path.iterdir()) == []


def test_unchecked_exports_standalone(tmp_path):
    args, target = gui(tmp_path, False)._cli_args()
    assert args[0] == "export-mta"
    assert args[args.index("--track") + 1] == "31"
    assert target == tmp_path / "HP2_TRACK31"


def test_packed_rejects_existing_output(tmp_path):
    target = tmp_path / "hp2_medit_pack"
    target.mkdir()
    (target / "meta.xml").write_text("existing")
    with pytest.raises(ValueError, match="new or empty"):
        gui(tmp_path, True)._cli_args()


def test_packed_does_not_override_other_export_types(tmp_path):
    args, _ = gui(tmp_path, True, export_type="GLB Only")._cli_args()
    assert args[0] == "export"
