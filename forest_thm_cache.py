# -*- coding: utf-8 -*-
"""X-Ray object THM thumbnail -> PNG cache, no third-party dependencies.

Decoding follows XRayTHMTools thm_decoder.cpp (MIT), adapted to Python.
https://github.com/r3tr0-hub/XRayTHMTools
Only handles object THM thumbnail chunk 0x0811 and version 0x0012.
Files are read-only; saves generated PNGs in the cache folder.
"""
from __future__ import annotations

from pathlib import Path
import struct
import zlib
import sys

W = 128
H = 128
DECODED_SIZE = W * H * 4


class ThmDecodeError(ValueError):
    pass


def u32(buf: bytes, off: int = 0) -> int:
    return struct.unpack_from('<I', buf, off)[0]


class LZH:
    # Mirrors the classic LZHUF decoder used by XRayTHMTools.
    N, F, NC, T, R = 4096, 60, 314, 627, 626

    def __init__(self, data: bytes):
        self.data = data
        self.bit = 0
        self.freq = [0] * (self.T + 1)
        self.parent = [0] * (self.T + self.NC)
        self.son = [0] * self.T
        for i in range(self.NC):
            self.freq[i] = 1
            self.son[i] = i + self.T
            self.parent[i + self.T] = i
        j = 0
        for i in range(self.NC, self.R + 1):
            self.freq[i] = self.freq[j] + self.freq[j + 1]
            self.son[i] = j
            self.parent[j] = i
            self.parent[j + 1] = i
            j += 2
        self.freq[self.T] = 65535
        self.parent[self.R] = 0

    def get(self) -> int:
        if self.bit >= len(self.data) * 8:
            raise ThmDecodeError('Truncated LZH bitstream')
        value = (self.data[self.bit // 8] >> (7 - (self.bit % 8))) & 1
        self.bit += 1
        return value

    def rebuild(self) -> None:
        j = 0
        for i in range(self.T):
            if self.son[i] >= self.T:
                self.freq[j] = (self.freq[i] + 1) // 2
                self.son[j] = self.son[i]
                j += 1
        k = 0
        for i in range(self.NC, self.T):
            f = self.freq[k] + self.freq[k + 1]
            at = i - 1
            while at >= 0 and f < self.freq[at]:
                at -= 1
            at += 1
            for z in range(i, at, -1):
                self.freq[z] = self.freq[z - 1]
                self.son[z] = self.son[z - 1]
            self.freq[at] = f
            self.son[at] = k
            k += 2
        for i in range(self.T):
            k = self.son[i]
            if k >= self.T:
                self.parent[k] = i
            else:
                self.parent[k] = i
                self.parent[k + 1] = i

    def update(self, c: int) -> None:
        if self.freq[self.R] == 32768:
            self.rebuild()
        c = self.parent[c + self.T]
        while True:
            f = self.freq[c] + 1
            self.freq[c] = f
            l = c + 1
            if f > self.freq[l]:
                while True:
                    l += 1
                    if not f > self.freq[l]:
                        break
                l -= 1
                self.freq[c] = self.freq[l]
                self.freq[l] = f
                a = self.son[c]
                self.parent[a] = l
                if a < self.T:
                    self.parent[a + 1] = l
                b = self.son[l]
                self.son[l] = a
                self.parent[b] = c
                if b < self.T:
                    self.parent[b + 1] = c
                self.son[c] = b
                c = l
            c = self.parent[c]
            if c == 0:
                break

    def symbol(self) -> int:
        c = self.son[self.R]
        while c < self.T:
            c = self.son[c + self.get()]
        c -= self.T
        self.update(c)
        return c

    def position(self) -> int:
        counts = (0, 0, 0, 1, 3, 8, 12, 24, 16)
        code = first = index = 0
        for length in range(1, 9):
            code = (code << 1) | self.get()
            if code - first < counts[length]:
                upper = index + code - first
                lower = 0
                for _ in range(6):
                    lower = (lower << 1) | self.get()
                return (upper << 6) | lower
            index += counts[length]
            first = (first + counts[length]) << 1
        raise ThmDecodeError('Invalid LZH position code')

    def run(self) -> bytes:
        out = bytearray()
        ring = bytearray([32] * self.N)
        r = self.N - self.F
        while len(out) < DECODED_SIZE:
            c = self.symbol()
            if c < 256:
                out.append(c)
                ring[r] = c
                r = (r + 1) & (self.N - 1)
            else:
                pos = (r - self.position() - 1) & (self.N - 1)
                length = c - 255 + 2
                if len(out) + length > DECODED_SIZE:
                    raise ThmDecodeError('LZH output overrun')
                for k in range(length):
                    value = ring[(pos + k) & (self.N - 1)]
                    out.append(value)
                    ring[r] = value
                    r = (r + 1) & (self.N - 1)
        return bytes(out)


def decode_object_thm(data: bytes) -> bytes:
    if not 8 <= len(data) <= 4 * 1024 * 1024:
        raise ThmDecodeError('THM file size out of bounds')
    version_ok = False
    payload = None
    compressed = False
    off = 0
    chunk_count = 0
    while off < len(data):
        if off + 8 > len(data):
            raise ThmDecodeError('Truncated THM chunk')
        raw_id, count = struct.unpack_from('<II', data, off)
        off += 8
        if count > len(data) - off:
            raise ThmDecodeError('THM chunk overrun')
        chunk_id = raw_id & 0x7fffffff
        value = data[off:off + count]
        off += count
        chunk_count += 1
        if chunk_count > 1024:
            raise ThmDecodeError('Too many THM chunks')
        if chunk_id == 0x810:
            version_ok = count == 2 and value == b'\x12\x00'
        if chunk_id == 0x811:
            if payload is not None:
                raise ThmDecodeError('Duplicate thumbnail chunk')
            payload = value
            compressed = bool(raw_id & 0x80000000)
    if not version_ok or payload is None:
        raise ThmDecodeError('Not supported object THM')
    if not compressed:
        if len(payload) != DECODED_SIZE:
            raise ThmDecodeError('Unexpected raw thumbnail size')
        return payload
    if len(payload) < 5 or u32(payload) != DECODED_SIZE:
        raise ThmDecodeError('Invalid compressed thumbnail header')
    return LZH(payload[4:]).run()


def png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (struct.pack('>I', len(payload)) + tag + payload +
            struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff))


def save_bgra_png(bgra: bytes, destination: Path) -> None:
    if len(bgra) != DECODED_SIZE:
        raise ThmDecodeError('Wrong BGRA array length')
    # Object THM BGRA -> PNG RGBA. Some SDK thumbnail buffers have unused A=0.
    # In that case show an opaque thumbnail rather than an invisible tile.
    alpha_unused = not any(bgra[3::4])
    image_rows = []
    # X-Ray object THM stores scanlines bottom-first; PNG uses top-first.
    for y in range(H):
        source_y = H - 1 - y
        line = bgra[source_y * W * 4:(source_y + 1) * W * 4]
        rgba = bytearray(len(line))
        rgba[0::4] = line[2::4]
        rgba[1::4] = line[1::4]
        rgba[2::4] = line[0::4]
        rgba[3::4] = (b'\xff' * W) if alpha_unused else line[3::4]
        image_rows.append(b'\0' + rgba)
    header = struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)
    png = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', header) +
           png_chunk(b'IDAT', zlib.compress(b''.join(image_rows), 6)) +
           png_chunk(b'IEND', b''))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(png)


def build_cache(objects_root: str, cache_dir: str, manifest_path: str) -> dict:
    root = Path(objects_root)
    cache = Path(cache_dir)
    manifest = Path(manifest_path)
    if not root.is_dir():
        raise ValueError(f'Invalid objects root: {root}')
    refs = [line.strip().replace('/', '\\') for line in manifest.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    # Version stamp forces rebuilding old, vertically mirrored PNGs once.
    stamp = cache / '.forest_thm_v2'
    force_rebuild = not stamp.is_file()
    counts = {'total': len(refs), 'converted': 0, 'cached': 0, 'missing': 0, 'failed': 0}
    for ref in refs:
        if '..' in Path(ref.replace('\\', '/')).parts or ':' in ref or ref.startswith('\\'):
            counts['failed'] += 1
            continue
        relative = Path(*ref.split('\\'))
        thm = root / relative.with_suffix('.thm')
        output = cache / ('_'.join(ref.split('\\')) + '.png')
        if not thm.is_file():
            counts['missing'] += 1
            continue
        if (not force_rebuild) and output.is_file() and output.stat().st_mtime >= thm.stat().st_mtime:
            counts['cached'] += 1
            continue
        try:
            save_bgra_png(decode_object_thm(thm.read_bytes()), output)
            counts['converted'] += 1
        except (OSError, ValueError, IndexError, struct.error) as exc:
            counts['failed'] += 1
            print('[THM]', thm.name, ':', exc)
    if counts['failed'] == 0:
        cache.mkdir(parents=True, exist_ok=True)
        stamp.write_text('flip_y=1\ncache_version=2\n', encoding='ascii')
    print('Forest THM cache:', counts)
    return counts


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print('Usage: python forest_thm_cache.py <sdk_objects_root> <png_cache_dir> <manifest.txt>')
        raise SystemExit(2)
    build_cache(sys.argv[1], sys.argv[2], sys.argv[3])
