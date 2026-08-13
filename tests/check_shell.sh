#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mapfile -d '' scripts < <(find "${repo_root}" -type f -name '*.sh' -not -path '*/.git/*' -print0)

if (( ${#scripts[@]} == 0 )); then
  echo "没有找到 Shell 脚本。" >&2
  exit 1
fi

for script in "${scripts[@]}"; do
  bash -n "${script}"
done
echo "Bash 语法检查通过：${#scripts[@]} 个脚本。"

python_bin=${PYTHON_BIN:-}
if [[ -z ${python_bin} ]] && command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif [[ -z ${python_bin} ]] && command -v python >/dev/null 2>&1; then
  python_bin=python
fi

if [[ -n ${python_bin} ]]; then
"${python_bin}" - "${repo_root}/install_imghub.sh" <<'PY'
import ast
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("PYTHON_SCRIPT_CONTENT=")
start = source.index("\n", start) + 1
end = source.index("\nEND_OF_PYTHON_SCRIPT", start)
ast.parse(source[start:end])
print("ImgHub 嵌入式 Python 语法检查通过。")
PY
else
  echo "未安装 Python，已跳过 ImgHub 嵌入脚本检查。" >&2
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --shell=bash --severity=warning "${scripts[@]}"
  echo "ShellCheck warning 级检查通过。"
else
  echo "未安装 ShellCheck，已跳过静态分析。" >&2
fi
