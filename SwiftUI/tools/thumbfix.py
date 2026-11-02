#!/usr/bin/env python3
"""Sets the Thumb bit on stored pointers to Thumb functions in a linked armv7 binary.

    thumbfix.py [--check] BINARY

Embedded Swift's runtime libraries for armv7-apple-none-macho mix Thumb and
ARM code. Some of their data holds pointers to local Thumb functions: the
task metadata's destroy functions in libswift_Concurrency.a, and the task
group vtables. Those pointers are stored as section-relative addresses, and
the linker writes them out without bit 0, the Thumb bit, even when the object
has it. Calling through one with `blx` then switches to ARM state and runs
Thumb instructions as ARM ones: releasing a finished Task crashed this way, in
destroyTask.

This runs after linking (and before signing). dyld's rebase information lists
every pointer the binary stores; each one whose value is the start of a
Thumb function (N_ARM_THUMB_DEF in the symbol table) gets bit 0 set. --check
only reports them.
"""

import struct
import sys

MH_MAGIC = 0xFEEDFACE
LC_SEGMENT = 0x1
LC_SYMTAB = 0x2
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
N_STAB = 0xE0
N_TYPE = 0x0E
N_SECT = 0x0E
N_ARM_THUMB_DEF = 0x0008
REBASE_TYPE_POINTER = 1


def uleb(data, offset):
    result = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, offset


def rebased_pointers(data, segments, rebase_off, rebase_size):
    """The file offsets of the pointers dyld rebases."""
    pointers = []
    offset, end = rebase_off, rebase_off + rebase_size
    kind, segment, address = REBASE_TYPE_POINTER, 0, 0

    def add():
        if kind == REBASE_TYPE_POINTER:
            vmaddr, fileoff = segments[segment]
            pointers.append(fileoff + address - vmaddr)

    while offset < end:
        byte = data[offset]
        offset += 1
        opcode, immediate = byte & 0xF0, byte & 0x0F
        if opcode == 0x00:  # DONE
            break
        elif opcode == 0x10:  # SET_TYPE_IMM
            kind = immediate
        elif opcode == 0x20:  # SET_SEGMENT_AND_OFFSET_ULEB
            segment = immediate
            value, offset = uleb(data, offset)
            address = segments[segment][0] + value
        elif opcode == 0x30:  # ADD_ADDR_ULEB
            value, offset = uleb(data, offset)
            address = (address + value) & 0xFFFFFFFF
        elif opcode == 0x40:  # ADD_ADDR_IMM_SCALED
            address += immediate * 4
        elif opcode == 0x50:  # DO_REBASE_IMM_TIMES
            for _ in range(immediate):
                add()
                address += 4
        elif opcode == 0x60:  # DO_REBASE_ULEB_TIMES
            count, offset = uleb(data, offset)
            for _ in range(count):
                add()
                address += 4
        elif opcode == 0x70:  # DO_REBASE_ADD_ADDR_ULEB
            value, offset = uleb(data, offset)
            add()
            address += 4 + value
        elif opcode == 0x80:  # DO_REBASE_ULEB_TIMES_SKIPPING_ULEB
            count, offset = uleb(data, offset)
            skip, offset = uleb(data, offset)
            for _ in range(count):
                add()
                address += 4 + skip
        else:
            raise SystemExit(f"thumbfix: unknown rebase opcode 0x{byte:02x}")
    return pointers


def fix(path, check):
    with open(path, "rb") as handle:
        data = bytearray(handle.read())
    if struct.unpack_from("<I", data, 0)[0] != MH_MAGIC:
        raise SystemExit(f"thumbfix: {path} isn't a 32-bit Mach-O binary")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 28
    segments = []  # (vmaddr, fileoff), in load command order
    symtab = rebase = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_SEGMENT:
            vmaddr, _vmsize, fileoff = struct.unpack_from("<III", data, offset + 24)
            segments.append((vmaddr, fileoff))
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, offset + 8)
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            rebase = struct.unpack_from("<II", data, offset + 8)
        offset += size
    if symtab is None or rebase is None:
        raise SystemExit(f"thumbfix: {path} has no symbol table or rebase information")

    symoff, nsyms, stroff, _ = symtab
    thumb = {}
    for index in range(nsyms):
        strx, n_type, _n_sect, n_desc, value = struct.unpack_from("<IBBHI", data, symoff + index * 12)
        if n_type & N_STAB or (n_type & N_TYPE) != N_SECT or not n_desc & N_ARM_THUMB_DEF:
            continue
        end = data.index(b"\0", stroff + strx)
        thumb[value] = data[stroff + strx:end].decode(errors="replace")

    fixed = []
    for location in rebased_pointers(data, segments, *rebase):
        value = struct.unpack_from("<I", data, location)[0]
        if value in thumb:
            fixed.append(thumb[value])
            if not check:
                struct.pack_into("<I", data, location, value | 1)
    if fixed and not check:
        with open(path, "wb") as handle:
            handle.write(data)
    return fixed


def main():
    check = "--check" in sys.argv[1:]
    paths = [p for p in sys.argv[1:] if p != "--check"]
    if len(paths) != 1:
        raise SystemExit(__doc__.split("\n\n")[1])
    fixed = fix(paths[0], check)
    for name in fixed:
        print(("needs " if check else "fixed ") + name)
    print(f"thumbfix: {len(fixed)} pointers to Thumb functions {'need' if check else 'got'} the Thumb bit",
          file=sys.stderr)


if __name__ == "__main__":
    main()
