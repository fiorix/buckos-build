"""Seed toolchain resolution helper."""

load("//tc:toolchain_rules.bzl", "buckos_bootstrap_toolchain")
load("//defs/rules:toolchain_import.bzl", "toolchain_import")

def maybe_export_seed():
    """Conditionally export the local seed archive at the root package level.

    Called from the root BUCK file.  Declares export_file(name=seed_path)
    so that //:<seed_path> is a valid label for tc/seed:seed-toolchain to
    depend on.  No-op when seed_path is not configured.
    """
    path = read_config("buckos", "seed_path", "")
    if path:
        native.export_file(
            name = path,
            visibility = ["PUBLIC"],
        )

_DEFAULT_SEED_URL = read_config("buckos", "default_seed_url", "")
_DEFAULT_SEED_SHA256 = read_config("buckos", "default_seed_sha256", "")

def seed_toolchain():
    """Declare the seed-toolchain target based on .buckconfig.

    Priority (highest first):
      1. buckos.source_mode = true  — force bootstrap regardless of seed config
      2. buckos.seed_path           — local archive (export_file)
      3. buckos.seed_url            — explicit remote URL (http_file)
      4. default seed URL           — auto-download from buckos.default_seed_url
      5. none configured            — bootstrap from source (stage 1 cross-compiler)

    The full seed archive (//tc/bootstrap:seed-export) must be built
    explicitly — it cannot be the seed-toolchain dep because
    seed-export → host-tools → packages → seed-toolchain creates a
    configured target cycle.
    """
    source_mode = read_config("buckos", "source_mode", "") in ("true", "1", "yes")
    url = read_config("buckos", "seed_url", "")
    path = read_config("buckos", "seed_path", "")

    if source_mode:
        archive = None
    elif path:
        archive = "//:" + path
    elif url or _DEFAULT_SEED_URL:
        native.http_file(
            name = "seed-archive",
            urls = [url or _DEFAULT_SEED_URL],
            sha256 = read_config("buckos", "seed_sha256", "") or _DEFAULT_SEED_SHA256,
            out = "buckos-seed.tar.zst",
        )
        archive = ":seed-archive"
    else:
        archive = None

    if archive:
        native.alias(
            name = "seed-archive-ref",
            actual = archive,
            visibility = ["PUBLIC"],
        )
        toolchain_import(
            name = "seed-toolchain",
            archive = archive,
            target_triple = "x86_64-buckos-linux-gnu",
            has_host_tools = True,
            extra_cflags = ["-march=x86-64-v3"],
            labels = ["buckos:seed"],
            visibility = ["PUBLIC"],
        )
    else:
        buckos_bootstrap_toolchain(
            name = "seed-toolchain",
            bootstrap_stage = "//tc/bootstrap/stage1:stage1",
            host_tools = "//tc/bootstrap:host-tools-exec",
            extra_cflags = ["-march=x86-64-v3"],
            extra_ldflags = [
                "-Wl,--dynamic-linker," + "/" * 228 + "lib64/ld-linux-x86-64.so.2",
                "-Wl,-rpath,$ORIGIN/../lib64:$ORIGIN/../lib",
            ],
            visibility = ["PUBLIC"],
        )
