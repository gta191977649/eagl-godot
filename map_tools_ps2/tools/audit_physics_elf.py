"""Save narrow, reproducible ELF evidence windows (research tool).

Requires pyelftools and capstone. Capstone's generic MIPS decoder is NOT a
complete R5900 decoder; EE/VU opcodes below are emitted as raw words instead.
"""
import argparse
import hashlib
import json
from pathlib import Path

from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS64, CS_MODE_LITTLE_ENDIAN
from elftools.elf.elffile import ELFFile

WINDOWS = {
    'section_runtime_id_34101': (0x14ed30, 0x14ed60),
    'lod_thresholds_not_physics_34102': (0x14ffc4, 0x150034),
    'physics_template_loader_34026': (0x21f080, 0x21f0e8),
    'physics_binding_loader_34027': (0x21f18c, 0x21f1b0),
    'section_and_instance_lookup': (0x21f294, 0x21f2dc),
    'physics_template_hash_lookup': (0x21f8f8, 0x21f930),
    'rigid_body_params': (0x220488, 0x22049c),
    'rigid_body_mass_and_reciprocal': (0x19cc58, 0x19cc84),
    'collision_hash_and_reference': (0x2204e4, 0x2204f8),
    'collision_header_hash_lookup': (0x219078, 0x2190d0),
    'attachment_threshold_initialization': (0x220554, 0x220574),
    'attachment_threshold_branch': (0x221364, 0x22138c),
    'attachment_threshold_consumption': (0x2213f8, 0x221490),
    'source_tumbleweed_model_branch': (0x220d44, 0x220d7c),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    with args.elf.open('rb') as handle:
        elf = ELFFile(handle)
        section = elf.get_section_by_name('.text')
        data, base = section.data(), section['sh_addr']
    decoder = Cs(CS_ARCH_MIPS, CS_MODE_MIPS64 | CS_MODE_LITTLE_ENDIAN)
    result = {'source': str(args.elf.resolve()),
              'sha256': hashlib.sha256(args.elf.read_bytes()).hexdigest(), 'windows': {}}
    for label, (start, end) in WINDOWS.items():
        rows = []
        for address in range(start, end, 4):
            raw = data[address - base:address - base + 4]
            if len(raw) != 4:
                raise ValueError(f'ELF does not cover evidence address {address:x}')
            word = int.from_bytes(raw, 'little')
            # COP2, LQC2/SQC2, EE MMI, or EE mult with a nonzero rd.
            unsupported = word >> 26 in (0x12, 0x1c, 0x36, 0x3e)
            unsupported |= word >> 26 == 0 and word & 63 in (24, 25) and (word >> 11) & 31 != 0
            instructions = [] if unsupported else list(decoder.disasm(raw, address))
            text = '; '.join(i.mnemonic + ' ' + i.op_str for i in instructions)
            rows.append({'address': f'0x{address:08x}', 'bytes': raw.hex(),
                         'instruction': text or 'R5900/undecoded: inspect raw opcode'})
        result['windows'][label] = rows
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
