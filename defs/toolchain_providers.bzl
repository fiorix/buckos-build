"""
Toolchain provider types for BuckOS language toolchains.

These providers give Buck2 typed, structured access to toolchain
metadata. Toolchain rules wrap existing ebuild_package outputs
and return these providers alongside DefaultInfo.
"""

GoToolchainInfo = provider(fields = {
    "goroot": provider_field(typing.Any),  # Artifact: Go installation root
    "version": provider_field(str),
})

RustToolchainInfo = provider(fields = {
    "rust_root": provider_field(typing.Any),  # Artifact: Rust installation root
    "version": provider_field(str),
})
