#!/usr/bin/env bash
# 把一次构建产物发布到内网静态源（默认 /var/ftp/pub，由 nginx 容器的 9999 端口提供）。
#
# 用法:
#   ./scripts/publish_intranet_update.sh --apk <APK 路径> --version 1.0.92 \
#       [--notes "更新说明"] [--dest /var/ftp/pub/fqapp] [--tag v1.0.92]
#
# 产出（<dest> 下）:
#   fqapp-<版本>-arm64.apk   安装包（同名覆盖）
#   SHA256SUMS               安装包哈希清单
#   update.json              App「更新源」读取的清单，原子替换
#
# 发布前会校验 APK 确实带签名（v2 签名块或 v1 签名文件）——未签名包在
# Android 11+ 上根本装不上（安装器报「解析软件包时出现问题」），拦在这里
# 而不是让用户装的时候才发现。
set -euo pipefail

APK=""
VERSION=""
NOTES=""
TAG=""
DEST="/var/ftp/pub/fqapp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk)     APK="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --notes)   NOTES="${2:-}"; shift 2 ;;
    --tag)     TAG="${2:-}"; shift 2 ;;
    --dest)    DEST="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$APK" || -z "$VERSION" ]]; then
  echo "必须提供 --apk 与 --version（-h 看用法）" >&2
  exit 2
fi
[[ -f "$APK" ]] || { echo "找不到 APK: $APK" >&2; exit 1; }
[[ -n "$TAG" ]] || TAG="v$VERSION"

NAME="fqapp-$VERSION-arm64.apk"

# --- 签名与结构校验 -------------------------------------------------------
python3 - "$APK" <<'PY'
import sys, zipfile

path = sys.argv[1]
data = open(path, 'rb').read()
if len(data) < 1024:
    sys.exit(f'APK 太小，疑似损坏: {path} ({len(data)} 字节)')

try:
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
except zipfile.BadZipFile:
    sys.exit(f'不是有效的 ZIP/APK 文件: {path}')

if 'AndroidManifest.xml' not in names:
    sys.exit('APK 里没有 AndroidManifest.xml，不是有效的安装包')

has_v2 = b'APK Sig Block 42' in data
v1 = [n for n in names if n.startswith('META-INF/') and n.endswith(('.RSA', '.DSA', '.EC'))]
if not has_v2 and not v1:
    sys.exit('APK 未签名（无 v2 签名块、无 v1 签名文件）：Android 11+ 上无法安装，拒绝发布')
print(f'签名校验通过（v2={"yes" if has_v2 else "no"}, v1={"yes" if v1 else "no"}）')
PY

# --- 落盘 -----------------------------------------------------------------
mkdir -p "$DEST"
install -m 0644 "$APK" "$DEST/$NAME.tmp"
mv -f "$DEST/$NAME.tmp" "$DEST/$NAME"

SIZE="$(stat -c %s "$DEST/$NAME")"
SHA="$(sha256sum "$DEST/$NAME" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$SHA" "$NAME" > "$DEST/SHA256SUMS"

# update.json：用 python 生成，保证 notes 里的引号/换行被正确转义。
python3 - "$DEST/update.json" "$TAG" "$NAME" "$SIZE" "$SHA" "$NOTES" <<'PY'
import json, os, sys, tempfile

target, tag, apk, size, sha, notes = sys.argv[1:7]
payload = {
    'tag': tag,
    'notes': notes,
    'apk': apk,
    'size': int(size),
    'sha256': sha,
}
directory = os.path.dirname(os.path.abspath(target))
fd, tmp = tempfile.mkstemp(dir=directory, prefix='.update.json.')
with os.fdopen(fd, 'w', encoding='utf-8') as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
os.chmod(tmp, 0o644)
os.replace(tmp, target)   # 原子替换：App 不会读到写一半的清单
PY

echo "已发布到 $DEST"
echo "  $NAME  ($((SIZE / 1024)) KiB, sha256 ${SHA:0:16}…)"
echo "  update.json -> $TAG"
echo "App「更新源」填该目录的访问地址即可，例如：http://<主机>:9999/fqapp"
