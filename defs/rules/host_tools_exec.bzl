"""
host_tools_exec rule: make stage3 host tools executable on the build host.

Stage3 host tools are hermetically built with GCC specs that inject a
padded ELF interpreter (///...///lib64/ld-linux-x86-64.so.2).  This
resolves to the host /lib64/ld-linux-x86-64.so.2 at runtime, but using
the host ld-linux with buckos-built glibc can cause ABI mismatches.

This rule copies the merged host tools directory and rewrites the padded
interpreters to point to the actual buckos ld-linux from the bootstrap
sysroot.  The output is a directory of hermetically-built, host-runnable
tools suitable for use as host_bin_dir in BuildToolchainInfo.
"""

load("//defs:providers.bzl", "BootstrapStageInfo")

def _host_tools_exec_impl(ctx):
    stage = ctx.attrs.stage[BootstrapStageInfo]
    tools_dir = ctx.attrs.host_tools[DefaultInfo].default_outputs[0]
    output = ctx.actions.declare_output("host-tools-exec", dir = True)

    # The sysroot contains the buckos ld-linux that matches our glibc.
    ld_linux = stage.sysroot.project("lib64/ld-linux-x86-64.so.2")

    cmd = cmd_args(ctx.attrs._rewrite_tool[RunInfo])
    cmd.add("--tools-dir", tools_dir)
    cmd.add("--ld-linux", ld_linux)
    cmd.add("--output-dir", output.as_output())

    ctx.actions.run(
        cmd,
        category = "host_tools_exec",
        identifier = ctx.attrs.name,
    )

    return [DefaultInfo(default_output = output)]

host_tools_exec = rule(
    impl = _host_tools_exec_impl,
    attrs = {
        "stage": attrs.dep(providers = [BootstrapStageInfo]),
        "host_tools": attrs.dep(),
        "_rewrite_tool": attrs.default_only(
            attrs.exec_dep(default = "//tools:rewrite_interps"),
        ),
    },
)
