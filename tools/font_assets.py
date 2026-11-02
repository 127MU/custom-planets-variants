"""Verify release icon glyphs before packaging (catches stale Flutter subsets)."""
import struct

def has_glyph(data, code):
    tables = {}
    for i in range(struct.unpack_from('>H', data, 4)[0]):
        pos = 12 + i * 16
        tables[data[pos:pos+4]] = struct.unpack_from('>II', data, pos+8)
    base, _ = tables[b'cmap']
    for i in range(struct.unpack_from('>H', data, base+2)[0]):
        _, _, offset = struct.unpack_from('>HHI', data, base+4+i*8)
        start = base + offset
        fmt = struct.unpack_from('>H', data, start)[0]
        if fmt == 12:
            for j in range(struct.unpack_from('>I', data, start+12)[0]):
                low, high, glyph = struct.unpack_from('>III', data, start+16+j*12)
                if low <= code <= high and glyph + code - low:
                    return True
        elif fmt == 4 and code <= 0xffff:
            count = struct.unpack_from('>H', data, start+6)[0] // 2
            for j in range(count):
                high = struct.unpack_from('>H', data, start+14+j*2)[0]
                low = struct.unpack_from('>H', data, start+16+count*2+j*2)[0]
                if not low <= code <= high:
                    continue
                delta = struct.unpack_from('>h', data, start+16+count*4+j*2)[0]
                address = start+16+count*6+j*2
                shift = struct.unpack_from('>H', data, address)[0]
                glyph = (code+delta)&0xffff if not shift else struct.unpack_from('>H', data, address+shift+(code-low)*2)[0]
                if glyph:
                    return True
    return False

def verify_icons(root):
    font = root/'data/flutter_assets/fonts/MaterialIcons-Regular.otf'
    data = font.read_bytes()
    for name, code in [('download', 0xe201), ('fact_check_outlined', 0xf045)]:
        if not has_glyph(data, code):
            raise RuntimeError(f'Release font is missing {name}; clean and rebuild Flutter assets before packaging')
