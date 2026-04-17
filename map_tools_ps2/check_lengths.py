import sys
from pathlib import Path
sys.path.insert(0, str(Path("src").resolve()))

from map_tools_ps2.cli import parse_chunks, parse_scene, load_bundle_bytes

def main():
    data = load_bundle_bytes(Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB32.LZC"))
    chunks = parse_chunks(data)
    scene = parse_scene(chunks, data)

    mismatches = 0
    for obj in scene.objects:
        for block in obj.blocks:
            if len(block.run.texcoords) != len(block.run.vertices):
                mismatches += 1
    print(f"Mismatches: {mismatches}")

if __name__ == "__main__":
    main()
