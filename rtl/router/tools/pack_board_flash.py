#!/usr/bin/env python3
"""Pack relative coefficient images for the board's nonzero Flash resource area.

The output BIN begins with instrument 0, not with 8MiB of padding. Program it at
FLASH_BASE. Program FPGA firmware separately at 0; never bulk erase between them.
"""
from pathlib import Path
import argparse, hashlib, json, re

ROOT = Path(__file__).resolve().parents[3]
BOARD_TOP = ROOT / 'rtl/platform/tang_mega_138k_pro/instrument_board_top.sv'


def board_layout(path=BOARD_TOP):
    source = Path(path).read_text()
    base = re.search(r"parameter logic \[31:0\] FLASH_BASE=32'h([0-9a-fA-F_]+)", source)
    capacity = re.search(r'parameter int FLASH_BYTES=([0-9_]+)', source)
    if not base or not capacity:
        raise ValueError('Cannot determine board FLASH_BASE/FLASH_BYTES')
    return int(base[1].replace('_', ''), 16), int(capacity[1].replace('_', ''))


def check_layout(base, capacity, length):
    if base < 0 or base % 64:
        raise ValueError('Flash resource base must be nonnegative and 64-byte aligned')
    if capacity <= 0 or base + length > min(capacity, 1 << 24):
        raise ValueError('Resource image exceeds physical Flash or 24-bit address space')


def pack(instruments, table_bytes, base, capacity):
    if not instruments:
        raise ValueError('No instruments supplied')
    if table_bytes <= 0 or table_bytes % 64 or any(not 0 <= ident <= 15 for ident in instruments):
        raise ValueError('Invalid table size or instrument ID')
    check_layout(base, capacity, (max(instruments) + 1) * table_bytes)
    image = bytearray(b'\xff' * ((max(instruments) + 1) * table_bytes))
    records = []
    for ident, path in sorted(instruments.items()):
        if not 0 <= ident <= 15:
            raise ValueError('Instrument must be 0..15')
        path = Path(path)
        original = path.read_bytes()
        if len(original) == table_bytes:
            data = original
        elif len(original) == (ident + 1) * table_bytes and all(b == 255 for b in original[:ident * table_bytes]):
            # Existing guitar_flash.bin includes its erased instrument-0 region.
            data = original[ident * table_bytes:]
        else:
            raise ValueError(f'{path}: expected one table or an erased-prefix relative image')
        if any(data[i + 28:i + 32] != b'\0' * 4 for i in range(0, table_bytes, 64)):
            raise ValueError(f'{path}: reserved coefficient word is not zero')
        offset = ident * table_bytes
        image[offset:offset + table_bytes] = data
        records.append(dict(instrument=ident, offset=offset, flash_address=base + offset,
                            bytes=table_bytes, source=str(path.resolve()),
                            source_sha256=hashlib.sha256(original).hexdigest(),
                            table_sha256=hashlib.sha256(data).hexdigest()))
    check_layout(base, capacity, len(image))
    return bytes(image), records


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--instrument', action='append', metavar='ID=BIN', help='Repeat for multiple instruments; default is six deployed timbres')
    ap.add_argument('--notes', type=int, choices=(16, 32), default=16)
    ap.add_argument('--out', type=Path, default=ROOT / 'build/flash_resources/resources.bin')
    args = ap.parse_args()
    try:
        entries = args.instrument or [f'{ident}={Path(__file__).parent/"performance"/(name+"_"+engine+".bin")}'
            for ident,name,engine in [(0,'piano','eng0'),(1,'guitar','eng0'),(3,'trumpet','eng1'),
                                      (5,'violin','eng1'),(10,'piano_abc','eng1'),(11,'guitar_abc','eng1')]]
        instruments = {}
        for entry in entries:
            ident, path = entry.split('=', 1)
            ident = int(ident, 0)
            if ident in instruments or not 0 <= ident <= 15:
                raise ValueError('Duplicate/invalid instrument ID')
            instruments[ident] = path
        base, capacity = board_layout()
        image, records = pack(instruments, args.notes * 64 * 64, base, capacity)
        for region in records:
            data=image[region['offset']:region['offset']+region['bytes']]
            matrix=region['instrument'] in (0,1)
            region['engine']='eng0' if matrix else 'eng1'
            for offset in range(0,len(data),64):
                abc=data[offset+60:offset+64]==b'P1T1' and data[offset+12:offset+32]==bytes(20)
                if abc==matrix:
                    raise ValueError('Instrument ID/engine format mismatch: IDs 0/1 require matrix; other IDs require ENG1 ABC/P1T1')
    except (ValueError, OSError) as exc:
        ap.error(str(exc))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(image)
    manifest = dict(schema=2, format='instrument-indexed eng0 matrix + eng1 ABC/P1T1', flash_base=base, flash_bytes=capacity, image_flash_address=base,
                    image_bytes=len(image), notes=args.notes, storage_modes=64, record_bytes=64,
                    image_sha256=hashlib.sha256(image).hexdigest(), instruments=records,
                    firmware_flash_address=0, bulk_erase_between_files=False)
    args.out.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'PASS resource BIN {args.out}: {len(image)} bytes; program at 0x{base:06X}')
    for entry in records:
        print(f'  instrument {entry["instrument"]}: relative 0x{entry["offset"]:06X}, Flash 0x{entry["flash_address"]:06X}')


if __name__ == '__main__':
    main()
