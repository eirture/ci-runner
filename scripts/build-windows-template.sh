#!/usr/bin/env bash
set -euo pipefail

# Builds a Windows runner template with kodoctl. Windows Sandbox templates are
# built from a provider disk image; qshell has no disk-image or OS options.

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/build-windows-template.sh TEMPLATE_DIR" >&2
  exit 64
fi

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
template_dir="$1"
if [[ "$template_dir" != /* ]]; then
  template_dir="$repository_root/$template_dir"
fi
template_env="$template_dir/template.env"
setup_script="$template_dir/scripts/setup-template.ps1"
runner_env="$repository_root/templates/common/actions-runner.env"
kodoctl_bin="${KODOCTL:-kodoctl}"

for file in "$template_env" "$setup_script" "$runner_env"; do
  test -f "$file" || {
    echo "required file does not exist: $file" >&2
    exit 66
  }
done
command -v "$kodoctl_bin" >/dev/null 2>&1 || {
  echo "kodoctl executable not found: $kodoctl_bin" >&2
  exit 69
}

read_value() {
  local file="$1" key="$2" value
  value="$(sed -n "s/^${key}=//p" "$file" | tail -n 1)"
  test -n "$value" || {
    echo "$key is missing from $file" >&2
    exit 65
  }
  printf '%s' "$value"
}

if grep -Eq '^(TEMPLATE_ID|template_id)=' "$template_env"; then
  echo "$template_env must not contain an environment-specific template ID" >&2
  exit 65
fi
runner_version="$(read_value "$runner_env" RUNNER_VERSION)"
windows_runner_version="$(read_value "$template_env" RUNNER_WIN_X64_VERSION)"
if [ "$windows_runner_version" != "$runner_version" ]; then
  echo "RUNNER_WIN_X64_VERSION $windows_runner_version does not match common RUNNER_VERSION $runner_version" >&2
  echo "update the Windows runner archive pin in $template_env" >&2
  exit 65
fi

template_name="$(read_value "$template_env" TEMPLATE_NAME)"
disk_image="$(read_value "$template_env" DISK_IMAGE)"
cpu_count="$(read_value "$template_env" CPU_COUNT)"
memory_mb="$(read_value "$template_env" MEMORY_MB)"
min_free_disk_mb="$(read_value "$template_env" MIN_FREE_DISK_MB)"

# kodoctl resolves --copy sources relative to the current directory. Stage
# only the reviewed build inputs so nothing else from the checkout is uploaded.
stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT
mkdir "$stage_root/qiniu-build"
cp "$setup_script" "$stage_root/qiniu-build/setup-template.ps1"
grep -E '^[A-Z0-9_]+=' "$template_env" >"$stage_root/qiniu-build/build.env"

context_args=()
if [ -n "${KODOCTL_CONTEXT:-}" ]; then
  context_args=(-c "$KODOCTL_CONTEXT")
fi
build_args=(
  sbx tpl build
  --name "$template_name"
  --os-platform windows
  --from-disk-image "$disk_image"
  --cpu "$cpu_count"
  --memory "$memory_mb"
  --min-free-disk "$min_free_disk_mb"
  --copy 'qiniu-build:C:\qiniu-build'
  --run-cmd 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\qiniu-build\setup-template.ps1 -BuildEnvironmentFile C:\qiniu-build\build.env'
  --run-cmd 'rmdir /s /q C:\qiniu-build'
  --ready-cmd ver
)
if [ "${NO_CACHE:-}" = 1 ]; then
  build_args+=(--no-cache)
fi

echo "building Windows template $template_name from $disk_image"
cd "$stage_root"
"$kodoctl_bin" "${context_args[@]}" "${build_args[@]}"
