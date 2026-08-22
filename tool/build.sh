#!/usr/bin/env bash
# BiliHaromny 命令行构建脚本（macOS + DevEco Studio）
# 用法: bash tool/build.sh [clean] [release]
set -e
cd "$(dirname "$0")/.."

export HOME="$PWD/.home"                                  # hvigor/npm 缓存收进工程目录
export NODE_HOME="/Applications/DevEco-Studio.app/Contents/tools/node"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export HOS_SDK_HOME="$DEVECO_SDK_HOME"
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export PATH="$NODE_HOME/bin:$DEVECO_SDK_HOME/../tools/ohpm/bin:$DEVECO_SDK_HOME/../tools/hvigor/bin:$JAVA_HOME/bin:$PATH"
export npm_config_cache="$HOME/.npm"
export npm_config_prefix="$HOME/.npm-global"
export npm_config_globalconfig="$HOME/etc/npmrc"
export npm_config_userconfig="$HOME/.npmrc"
export npm_config_local_prefix="$HOME"
export npm_config_global_prefix="$HOME/.npm-global"
unset npm_execpath npm_config_node_gyp npm_config_init_module npm_config_npm_version       npm_config_user_agent npm_lifecycle_script npm_package_json npm_config_allow_scripts       npm_config_noproxy npm_config_registry 2>/dev/null || true
mkdir -p "$HOME/.npm" "$HOME/.npm-global"

ohpm install --all
BUILD_MODE="debug"
CLEAN_BUILD="false"
for ARG in "$@"; do
  if [ "$ARG" = "release" ]; then BUILD_MODE="release"; fi
  if [ "$ARG" = "clean" ]; then CLEAN_BUILD="true"; fi
done
if [ "$CLEAN_BUILD" = "true" ]; then
  hvigorw clean assembleHap --mode module -p product=default -p buildMode="$BUILD_MODE"
else
  hvigorw assembleHap --mode module -p product=default -p buildMode="$BUILD_MODE"
fi
echo
echo "构建模式: $BUILD_MODE"
echo "产物: entry/build/default/outputs/default/entry-default-unsigned.hap"
