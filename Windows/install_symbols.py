"""Index a matching Windows executable/PDB pair in a local symbol store."""
import argparse
from pathlib import Path
import shutil
import struct
import uuid


def identity(executable, pdb):
    image = executable.read_bytes()
    pe = struct.unpack_from('<I', image, 0x3c)[0]
    if image[pe:pe + 4] != b'PE\0\0':
        raise ValueError('Not a PE image')
    sections, timestamp = struct.unpack_from('<HI', image, pe + 6)
    optional_size = struct.unpack_from('<H', image, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from('<H', image, optional)[0]
    if magic not in (0x10b, 0x20b):
        raise ValueError('Unsupported PE format')
    image_size = struct.unpack_from('<I', image, optional + 56)[0]
    directories = optional + (112 if magic == 0x20b else 96)
    debug_rva, debug_size = struct.unpack_from('<II', image, directories + 6 * 8)
    debug = None
    for i in range(sections):
        start = optional + optional_size + i * 40
        size, rva, raw_size, raw = struct.unpack_from('<IIII', image, start + 8)
        if rva <= debug_rva and debug_rva + debug_size <= rva + raw_size:
            debug = raw + debug_rva - rva
            break
    if debug is None:
        raise ValueError('The executable has no symbol reference')
    records = []
    for start in range(debug, debug + debug_size, 28):
        kind, size, _, offset = struct.unpack_from('<IIII', image, start + 12)
        if kind == 2 and image[offset:offset + 4] == b'RSDS' and size >= 25:
            guid = image[offset + 4:offset + 20]
            age = struct.unpack_from('<I', image, offset + 20)[0]
            name = image[offset + 24:offset + size].split(b'\0')[0].decode().replace('\\', '/').split('/')[-1]
            records.append((guid, age, name))
    if len(records) != 1:
        raise ValueError('Expected exactly one PDB reference')
    guid, age, name = records[0]
    data = pdb.read_bytes()
    if not data.startswith(b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0'):
        raise ValueError('Unsupported PDB format')
    block, _, blocks, directory_size, _, block_map = struct.unpack_from('<IIIIII', data, 32)
    if block not in (512, 1024, 2048, 4096) or blocks * block > len(data):
        raise ValueError('Invalid PDB block layout')
    count = (directory_size + block - 1) // block
    directory_blocks = struct.unpack_from('<' + 'I' * count, data, block_map * block)
    directory = b''.join(data[i * block:(i + 1) * block] for i in directory_blocks)[:directory_size]
    streams = struct.unpack_from('<I', directory)[0]
    sizes = struct.unpack_from('<' + 'I' * streams, directory, 4)
    cursor = 4 + streams * 4
    info = None
    for index, size in enumerate(sizes):
        count = 0 if size == 0xffffffff else (size + block - 1) // block
        indices = struct.unpack_from('<' + 'I' * count, directory, cursor)
        cursor += count * 4
        if index == 1:
            info = b''.join(data[i * block:(i + 1) * block] for i in indices)[:size]
            break
    if info is None or len(info) < 28 or info[12:28] != guid or struct.unpack_from('<I', info, 8)[0] != age:
        raise ValueError('PDB does not match the executable GUID and age')
    if pdb.name.lower() != name.lower():
        raise ValueError('PDB filename does not match the executable reference')
    return name, uuid.UUID(bytes_le=guid).hex.upper() + format(age, 'X'), f'{timestamp:08X}{image_size:x}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('pdb', type=Path)
    parser.add_argument('--store', type=Path, default=Path('C:/Symbols'))
    args = parser.parse_args()
    name, pdb_key, image_key = identity(args.executable, args.pdb)
    for source, destination in ((args.pdb, args.store / name / pdb_key / name),
                                (args.executable, args.store / args.executable.name / image_key / args.executable.name)):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists() and destination.read_bytes() != source.read_bytes():
            raise ValueError(f'Refusing to replace a different file at {destination}')
        if not destination.exists():
            shutil.copy2(source, destination)
        print(destination)
    print('PASS executable and PDB GUID/age match; indexed symbols and image')


if __name__ == '__main__':
    main()
