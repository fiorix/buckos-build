#!/usr/bin/env python3
"""Pack a bootstrap stage output into a distributable toolchain archive.

Collects compiler binaries, sysroot, support libraries, and GCC internal
tools, generates metadata.json, and packs everything into a compressed tar.

Archive format (v2):
  tools/                  cross-compiler (stage 1 output)
  host-tools/             merged FHS tree (hermetic PATH, backwards compat)
  packages/               per-package archives (granular invalidation)
    bash-5.2.37.tar.zst
    rust-1.91.0.tar.zst
    ...
  metadata.json           provenance + package manifest
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

from _env import clean_env, sanitize_global_env


def sha256_directory(directory):
    """Compute SHA256 of all files in a directory tree."""
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(directory)):
        dirs.sort()
        for fname in sorted(files):
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, directory)
            h.update(rel.encode())
            if os.path.islink(fpath):
                h.update(os.readlink(fpath).encode())
            elif os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    for chunk in iter(lambda: f.read(65536), b""):
                        h.update(chunk)
    return h.hexdigest()


def sha256_file(path):
    """Compute SHA256 of a single file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _scrub_build_paths(directory):
    """Replace absolute buck-out paths in ELF binaries with /build.

    Build systems (especially glibc) embed __FILE__ paths in binaries
    that contain the Buck2 action directory (buck-out/...).  Replace
    with a generic /build prefix padded with null bytes to preserve
    binary layout.
    """
    pattern = re.compile(rb'/[^\x00]*?buck-out[^\x00]*')
    scrubbed = 0

    for dirpath, _, filenames in os.walk(directory):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, 'rb') as f:
                    magic = f.read(4)
                if magic != b'\x7fELF':
                    continue
                with open(path, 'rb') as f:
                    data = f.read()
                if b'buck-out' not in data:
                    continue

                def _replace(m):
                    orig = m.group(0)
                    repl = b'/build'
                    if len(repl) >= len(orig):
                        return orig
                    return repl + b'\x00' * (len(orig) - len(repl))

                new_data = pattern.sub(_replace, data)
                if new_data != data:
                    orig_mode = os.stat(path).st_mode
                    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                    with open(path, 'wb') as f:
                        f.write(new_data)
                    os.chmod(path, orig_mode)
                    scrubbed += 1
            except (PermissionError, OSError):
                pass

    if scrubbed:
        print(f"  scrubbed build paths from {scrubbed} ELF files", file=sys.stderr)


def _elf_data_ranges(data):
    """Return list of (start, end) byte ranges for ELF data sections.

    Only returns ranges for sections that contain string/path data
    (rodata, strtab, comment, debug sections).  Excludes executable
    code sections (.text, .init, .fini, .plt) to avoid corrupting
    machine code that happens to match path patterns.
    """
    if len(data) < 64 or data[:4] != b'\x7fELF':
        return []
    # Only handle 64-bit LE
    if data[4] != 2 or data[5] != 1:
        return []

    SHT_PROGBITS = 1
    SHT_STRTAB = 3
    SHT_NOTE = 7

    e_shoff = struct.unpack_from('<Q', data, 40)[0]
    e_shentsize = struct.unpack_from('<H', data, 58)[0]
    e_shnum = struct.unpack_from('<H', data, 60)[0]
    e_shstrndx = struct.unpack_from('<H', data, 62)[0]

    if e_shoff == 0 or e_shnum == 0:
        return []

    # Read section header string table to get section names
    shstrtab_off = 0
    if e_shstrndx < e_shnum:
        idx_off = e_shoff + e_shstrndx * e_shentsize
        shstrtab_off = struct.unpack_from('<Q', data, idx_off + 24)[0]

    # Executable section names to skip
    _EXEC_NAMES = {b'.text', b'.init', b'.fini', b'.plt', b'.plt.got',
                   b'.plt.sec'}

    ranges = []
    for i in range(e_shnum):
        sh_off = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from('<I', data, sh_off + 4)[0]
        sh_flags = struct.unpack_from('<Q', data, sh_off + 8)[0]
        sh_offset = struct.unpack_from('<Q', data, sh_off + 24)[0]
        sh_size = struct.unpack_from('<Q', data, sh_off + 32)[0]
        sh_name_idx = struct.unpack_from('<I', data, sh_off)[0]

        if sh_size == 0:
            continue

        # Get section name
        sec_name = b''
        if shstrtab_off and sh_name_idx:
            end = data.find(0, shstrtab_off + sh_name_idx)
            if end > 0:
                sec_name = data[shstrtab_off + sh_name_idx:end]

        # Skip executable sections
        SHF_EXECINSTR = 0x4
        if sh_flags & SHF_EXECINSTR:
            continue
        if sec_name in _EXEC_NAMES:
            continue

        # Include string tables, rodata, comment, debug, note sections
        if sh_type == SHT_STRTAB:
            ranges.append((sh_offset, sh_offset + sh_size))
        elif sh_type == SHT_NOTE:
            ranges.append((sh_offset, sh_offset + sh_size))
        elif sh_type == SHT_PROGBITS and sec_name in (
            b'.rodata', b'.rodata.str1.1', b'.rodata.str1.8',
            b'.comment', b'.GCC.command.line',
        ):
            ranges.append((sh_offset, sh_offset + sh_size))
        elif sec_name.startswith(b'.debug'):
            ranges.append((sh_offset, sh_offset + sh_size))

    return ranges


def _scrub_home_paths(directory):
    """Replace /home/... paths in ELF data sections with zeroes.

    Build-machine home directories should not appear in shipped
    artifacts.  Only scrubs data sections (rodata, strtab, debug
    info) — never touches executable code sections.
    """
    pattern = re.compile(rb'/home/[^\x00]+')
    scrubbed = 0

    for dirpath, _, filenames in os.walk(directory):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                with open(path, 'rb') as f:
                    magic = f.read(4)
                if magic != b'\x7fELF':
                    continue
                with open(path, 'rb') as f:
                    data = bytearray(f.read())
                if b'/home/' not in data:
                    continue

                ranges = _elf_data_ranges(bytes(data))
                if not ranges:
                    continue

                modified = False
                for m in pattern.finditer(bytes(data)):
                    start, end = m.start(), m.end()
                    # Only scrub if the match falls entirely within a data section
                    in_data = any(rs <= start and end <= re
                                  for rs, re in ranges)
                    if in_data:
                        for j in range(start, end):
                            data[j] = 0
                        modified = True

                if modified:
                    orig_mode = os.stat(path).st_mode
                    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
                    with open(path, 'wb') as f:
                        f.write(data)
                    os.chmod(path, orig_mode)
                    scrubbed += 1
            except (PermissionError, OSError, struct.error):
                pass

    if scrubbed:
        print(f"  scrubbed home paths from {scrubbed} ELF files", file=sys.stderr)



def main():
    parser = argparse.ArgumentParser(description="Pack bootstrap toolchain into archive")
    parser.add_argument("--stage-dir", required=True, help="Stage 2 output directory")
    parser.add_argument("--output", required=True, help="Output archive path")
    parser.add_argument("--target-triple", default="x86_64-buckos-linux-gnu")
    parser.add_argument("--gcc-version", default="14.3.0")
    parser.add_argument("--glibc-version", default="2.42")
    parser.add_argument("--compression", choices=["zst", "xz", "gz"], default="zst")
    parser.add_argument("--host-tools-dir", default=None,
                        help="Directory containing host tools to include as host-tools/")
    parser.add_argument("--package", nargs=4, action="append", default=[],
                        metavar=("LABEL", "NAME", "VERSION", "PREFIX"),
                        help="Per-package archive: label name version prefix_dir (repeatable)")
    args = parser.parse_args()
    sanitize_global_env()

    stage_dir = os.path.abspath(args.stage_dir)
    output = os.path.abspath(args.output)

    if not os.path.isdir(stage_dir):
        print(f"error: stage directory not found: {stage_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)

    with tempfile.TemporaryDirectory() as tmpdir:
        # Copy stage dir so we can scrub build paths (Buck2 artifacts
        # are read-only).
        stage_copy = os.path.join(tmpdir, "stage")
        print("Copying stage dir for path scrubbing...", file=sys.stderr)
        shutil.copytree(stage_dir, stage_copy, symlinks=True)

        # If host tools are provided, stage them under host-tools/ in the
        # temp dir so the archive layout matches what toolchain_import expects.
        has_host_tools = False
        host_tools_dst = None
        if args.host_tools_dir:
            host_tools_src = os.path.abspath(args.host_tools_dir)
            if not os.path.isdir(host_tools_src):
                print(f"error: host-tools directory not found: {host_tools_src}", file=sys.stderr)
                sys.exit(1)
            host_tools_dst = os.path.join(tmpdir, "host-tools")
            shutil.copytree(host_tools_src, host_tools_dst, symlinks=True)
            has_host_tools = True

        # Scrub absolute buck-out paths from ELF binaries in the cross-compiler
        # tree only.  Host-tools binaries must NOT be scrubbed because tools
        # like flex and bison store paths to helper programs (m4) at compile
        # time — scrubbing truncates those to "/build" which breaks exec().
        print("Scrubbing build paths...", file=sys.stderr)
        _scrub_build_paths(stage_copy)

        # Scrub /home/... paths from data sections so build-machine
        # paths don't appear in shipped artifacts.  Section-aware:
        # only touches rodata, strtab, debug — never executable code.
        print("Scrubbing home paths...", file=sys.stderr)
        _scrub_home_paths(stage_copy)
        if has_host_tools:
            _scrub_home_paths(host_tools_dst)

        # All host-tools binaries are built by our GCC with specs, so they
        # have padded interp + $ORIGIN RPATH at link time.  No pack-time
        # ELF patching needed — RPATH is correct from build time, and
        # unpack rewrites the padded interp to the actual seed path.

        # Create per-package archives if --package was given
        pkg_manifest = {}
        if args.package:
            pkg_dir = os.path.join(tmpdir, "packages")
            os.makedirs(pkg_dir, exist_ok=True)
            for label, name, version, prefix in args.package:
                prefix = os.path.abspath(prefix)
                if not os.path.isdir(prefix):
                    print(f"warning: package prefix not found, skipping: {prefix}", file=sys.stderr)
                    continue
                archive_name = f"{name}-{version}.tar.zst"
                archive_path = os.path.join(pkg_dir, archive_name)
                print(f"  packing package {name}-{version}...", file=sys.stderr)
                tar_p = subprocess.Popen(
                    ["tar", "-cf", "-", "-C", prefix, "."],
                    stdout=subprocess.PIPE, env=clean_env(),
                )
                zstd_p = subprocess.Popen(
                    ["zstd", "-T0", "-9", "-o", archive_path],
                    stdin=tar_p.stdout, env=clean_env(),
                )
                tar_p.stdout.close()
                zstd_p.wait()
                rc = tar_p.wait() or zstd_p.returncode
                if rc != 0:
                    print(f"error: failed to pack package {name}", file=sys.stderr)
                    sys.exit(1)
                pkg_manifest[label] = {
                    "archive": f"packages/{archive_name}",
                    "sha256": sha256_file(archive_path),
                    "name": name,
                    "version": version,
                }
            print(f"Packed {len(pkg_manifest)} per-package archives", file=sys.stderr)

        # Compute content hash from scrubbed stage
        print("Computing content hash...", file=sys.stderr)
        contents_sha256 = sha256_directory(stage_copy)

        # Generate metadata
        fmt_version = 2 if pkg_manifest else 1
        metadata = {
            "format_version": fmt_version,
            "target_triple": args.target_triple,
            "gcc_version": args.gcc_version,
            "glibc_version": args.glibc_version,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "contents_sha256": contents_sha256,
        }
        if has_host_tools:
            metadata["has_host_tools"] = True
        if pkg_manifest:
            metadata["packages"] = pkg_manifest

        meta_path = os.path.join(tmpdir, "metadata.json")
        with open(meta_path, "w") as f:
            json.dump(metadata, f, indent=2)
            f.write("\n")

        print(f"Packing {stage_dir} -> {output}", file=sys.stderr)

        # Build tar command with multiple -C flags to collect all
        # archive components without symlinks or --dereference.
        tar_items = ["-C", stage_copy, "."]
        tar_items.extend(["-C", tmpdir, "metadata.json"])
        if has_host_tools:
            tar_items.extend(["-C", tmpdir, "host-tools"])
        if pkg_manifest:
            tar_items.extend(["-C", tmpdir, "packages"])

        if args.compression == "zst":
            tar_p = subprocess.Popen(
                ["tar", "-cf", "-"] + tar_items,
                stdout=subprocess.PIPE, env=clean_env(),
            )
            zstd_p = subprocess.Popen(
                ["zstd", "-T0", "-19", "-o", output],
                stdin=tar_p.stdout, env=clean_env(),
            )
            tar_p.stdout.close()
            zstd_p.wait()
            rc = tar_p.wait() or zstd_p.returncode
            result = type("R", (), {"returncode": rc})()
        elif args.compression == "xz":
            result = subprocess.run(
                ["tar", "-cJf", output] + tar_items,
                env=clean_env())
        else:
            result = subprocess.run(
                ["tar", "-czf", output] + tar_items,
                env=clean_env())

    if result.returncode != 0:
        print(f"error: tar failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(1)

    # Print summary
    archive_sha256 = sha256_file(output)
    size_bytes = os.path.getsize(output)
    size_mb = size_bytes / (1024 * 1024)

    print(f"Archive:  {output}", file=sys.stderr)
    print(f"Size:     {size_mb:.1f} MB ({size_bytes} bytes)", file=sys.stderr)
    print(f"SHA256:   {archive_sha256}", file=sys.stderr)
    print(f"Triple:   {args.target_triple}", file=sys.stderr)
    print(f"GCC:      {args.gcc_version}", file=sys.stderr)
    print(f"glibc:    {args.glibc_version}", file=sys.stderr)

    # Print machine-readable output to stdout
    print(json.dumps({
        "archive": output,
        "size_bytes": size_bytes,
        "archive_sha256": archive_sha256,
        **metadata,
    }))


if __name__ == "__main__":
    main()
