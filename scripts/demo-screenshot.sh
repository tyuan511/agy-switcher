#!/bin/bash
# 构建 Debug 版并用演示模式启动，把 README 截图保存到 docs/screenshots/。
# 用法：scripts/demo-screenshot.sh [usage|accounts|menu-bar|all] [输出目录]
#   usage     -AGYDemoUsage 启动，截「用量」页
#   accounts  -AGYDemoAccounts 启动，截「账号管理」页
#   menu-bar  与 accounts 同一次启动，截自动弹出的菜单栏弹窗
#   all       依次截 usage、accounts、menu-bar（默认）
# 旧用法 `scripts/demo-screenshot.sh 输出.png` 仍然有效，等价于 usage。
# 首次使用需在 系统设置 → 隐私与安全性 → 屏幕录制 中授权终端，屏幕截图还需辅助功能权限（System Events 激活应用）；
# 截图时屏幕不能处于锁定状态。
set -euo pipefail
cd "$(dirname "$0")/.."

targets="${1:-all}"
outfile=""
if [[ "$targets" == *.png ]]; then
  outfile="$targets"
  targets="usage"
fi
outdir="${2:-docs/screenshots}"
build="DerivedData/Demo"
app="$build/Build/Products/Debug/AGY Switcher.app"
trap 'pkill -x "AGY Switcher" 2>/dev/null || true' EXIT
mkdir -p "$outdir"

xcodebuild -project AGYSwitcher.xcodeproj -scheme AGYSwitcher -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$build" \
  CONFIGURATION_BUILD_DIR="$build/Build/Products/Debug" build -quiet

# 等待应用出现匹配的窗口（按标题与最小高度过滤），输出 "窗口ID x y w h"。
# 演示模式固定简体中文，主窗口标题即导航标题；菜单栏弹窗无标题。
wait_window() {
  local title="$1" min_height="$2" timeout="$3" info=""
  for _ in $(seq 1 $((timeout * 2))); do
    info=$(/usr/bin/swift scripts/window-id.swift "AGY Switcher" "$title" "$min_height" 2>/dev/null || true)
    if [[ -n "$info" ]]; then echo "$info"; return 0; fi
    sleep 0.5
  done
  return 1
}

run_demo() {
  # 通过 LaunchServices 启动，并确保应用真正成为前台激活状态：
  # 玻璃材质在未激活应用里会渲染成暗色变体。
  open "$app" --args "$@" -appLanguage zh-Hans -appAppearance light
  osascript -e 'tell application "System Events" to set frontmost of process "AGY Switcher" to true'
}

stop_demo() {
  pkill -x "AGY Switcher" 2>/dev/null || true
  sleep 1
}

if [[ "$targets" == usage || "$targets" == all ]]; then
  run_demo -AGYDemoUsage
  window=$(wait_window "用量" 0 30) || { echo "未找到用量窗口" >&2; exit 1; }
  sleep 2
  screencapture -x -o -l "${window%% *}" "${outfile:-$outdir/usage.png}"
  echo "已保存 ${outfile:-$outdir/usage.png}"
  stop_demo
fi

if [[ "$targets" == accounts || "$targets" == menu-bar || "$targets" == all ]]; then
  run_demo -AGYDemoAccounts
  window=$(wait_window "账号管理" 0 30) || { echo "未找到账号窗口" >&2; exit 1; }
  sleep 2
  if [[ "$targets" == accounts || "$targets" == all ]]; then
    screencapture -x -o -l "${window%% *}" "$outdir/accounts.png"
    echo "已保存 $outdir/accounts.png"
  fi
  if [[ "$targets" == menu-bar || "$targets" == all ]]; then
    # 演示模式在启动约 4 秒后自动弹出菜单栏弹窗；按无标题 + 高度过滤跳过状态栏按钮。
    popover=$(wait_window "" 30 30) || { echo "未找到菜单栏弹窗" >&2; exit 1; }
    sleep 2
    # 窗口缓冲里的玻璃材质与屏幕实际渲染不一致，改按屏幕区域截取；
    # 弹窗窗口含箭头和留白，向内收紧到气泡主体。
    read -r _ px py pw ph <<< "$popover"
    screencapture -x -o -R "$(( px + 5 )),$(( py + 12 )),$(( pw - 10 )),$(( ph - 24 ))" "$outdir/menu-bar.png"
    echo "已保存 $outdir/menu-bar.png"
  fi
  stop_demo
fi
