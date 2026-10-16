# GitHub runner Windows 11 template

This 4-vCPU, 8192-MiB Windows 11 x64 template is built from the provider's
Windows 11 25H2 disk image. Windows Sandbox templates cannot be built from a
Dockerfile or an existing template, and qshell has no disk-image or OS-platform
options, so the build uses `kodoctl sbx tpl build --from-disk-image
--os-platform windows`.

The build copies `scripts/setup-template.ps1` and the `KEY=VALUE` lines of
`template.env` into `C:\qiniu-build`. It runs the script with Windows
PowerShell 5.1, then removes the directory. Every download is pinned by URL,
size, and SHA-256. The script installs:

- the GitHub Actions Runner win-x64 archive in `C:\actions-runner`;
- Git for Windows, with `Git\cmd` and `Git\bin` on the machine `PATH`, so
  `git`, `bash`, and `sh` resolve like they do on GitHub-hosted Windows images;
- PowerShell 7 (`pwsh`), the default `run` shell on Windows runners.

It also creates `C:\runner\work` and `C:\hostedtoolcache`, sets
`RUNNER_TOOL_CACHE`, `AGENT_TOOLSDIRECTORY`, `ImageOS=win11`, and
`ImageVersion` machine-wide, and writes template identity to
`C:\ProgramData\qiniu-runner\image.env`.

Templates are memory snapshots, so envd keeps the environment it had before
setup. runnerd's Windows start script reloads the persisted machine and user
environment before it starts the runner.

The template guarantees only this minimal core. Other GitHub-hosted
windows-2025 tools, Docker, and Visual Studio Build Tools are not provided;
install them in the workflow or build a custom template.

## Build

```bash
task template-build-windows-11 KODOCTL_CONTEXT=<kodoctl-context>
```

`template.env` holds the provider inputs and must never contain an
environment-specific template ID. `RUNNER_WIN_X64_VERSION` must equal
`RUNNER_VERSION` in `templates/common/actions-runner.env`; the build helper
fails closed when an Actions Runner update leaves the Windows archive pin
behind. Bump `TEMPLATE_VERSION` when the template contents change.

## Use

Match Windows jobs with a spec whose labels include `windows`, for example
`self-hosted,windows,x64,qiniu,windows-11`. runnerd selects its Windows launch
path from the `windows` label. Windows runners never require Docker.
