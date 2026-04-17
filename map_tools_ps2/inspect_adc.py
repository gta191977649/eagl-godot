import sys
from pathlib import Path
sys.path.insert(0, str(Path("src").resolve()))

from map_tools_ps2.cli import parse_chunks, parse_scene, load_bundle_bytes

def main():
    data = load_bundle_bytes(Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB32.LZC"))
    chunks = parse_chunks(data)
    scene = parse_scene(chunks, data)

    # Let's inspect objects
    for obj in scene.objects:
        for block_index, block in enumerate(obj.blocks):
            if block.run.packed_values:
                adcs = [bool(v & 0x8000) for v in block.run.packed_values]
                if any(adcs):
                    print(f"Object {obj.name} Block {block_index} has ADCs: {adcs[:20]}")
                    break

if __name__ == "__main__":
    main()
