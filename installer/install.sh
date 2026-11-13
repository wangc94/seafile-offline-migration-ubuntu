#!/usr/bin/env bash
# Single-entry-point offline restore/upgrade installer v0.8 for Seafile 13.0.28 + ONLYOFFICE 8.1.0.1 + SeaDoc 2.0.
set -Eeuo pipefail
umask 077

PKG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STATE=/var/lib/seafile-offline-migration
LOGDIR=/var/log/seafile-offline-migration
LOG=""
SETTINGS_FILE=""
PACKAGE_ID_FILE=""
ALLOW_EXISTING_PORTS=0
CURRENT_TARGET_IP=""
CURRENT_ONLYOFFICE_PORT=""
CURRENT_TIME_ZONE=""
RABBITMQ_HOSTNAME="05831744982c"
ONLYOFFICE_PG_VOLUME="seafile-onlyoffice-postgresql"
ONLYOFFICE_RABBIT_VOLUME="seafile-onlyoffice-rabbitmq"
ONLYOFFICE_REDIS_VOLUME="seafile-onlyoffice-redis"
UPGRADE_BACKUP_DIR=""
UPGRADE_ACTIVE=0
UPGRADE_CONFIG_APPLIED=0
DISCOVERED_RABBITMQ_HOSTNAME=""
DISCOVERED_PG_VOLUME=""
DISCOVERED_RABBIT_VOLUME=""
DISCOVERED_REDIS_VOLUME=""

die(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
mark(){ date -Is > "$STATE/$1.done"; }
done_stage(){ [[ -f "$STATE/$1.done" ]]; }
dc(){ (cd /opt/seafile && docker compose "$@"); }
http_status(){
  python3 - "$1" <<'PYHTTP'
from urllib.request import build_opener, ProxyHandler
from urllib.error import HTTPError
import sys
opener = build_opener(ProxyHandler({}))
try:
    with opener.open(sys.argv[1], timeout=15) as response:
        print(response.status)
except HTTPError as error:
    print(error.code)
except Exception as error:
    print(f"HTTP_CHECK_ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PYHTTP
}

[[ $EUID -eq 0 ]] || { echo "请使用 sudo bash ./install.sh"; exit 1; }
mkdir -p "$STATE" "$LOGDIR"
chmod 700 "$STATE" "$LOGDIR"
LOG="$LOGDIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
info "日志：$LOG"

preflight(){
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux 系统"
  local arch
  arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || die "当前迁移包中的 Docker 镜像为 amd64 架构，目标 CPU 必须为 x86_64；当前架构：$arch"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local os_name="${PRETTY_NAME:-${ID:-unknown}}"
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
      info "检测到 Ubuntu 24.04（本次迁移包的基线验证环境）"
    else
      echo "[WARN] 当前系统：$os_name"
      echo "[WARN] 本迁移包以 Ubuntu 24.04 为基线制作；当前发行版/版本尚未在本迁移包中实机验证。"
      read -r -p "仍要继续执行恢复前检查？[y/N] " os_confirm
      [[ "$os_confirm" =~ ^[Yy]$ ]] || die "用户取消：未确认非基线操作系统"
    fi
  else
    echo "[WARN] 无法识别当前 Linux 发行版（缺少 /etc/os-release）。"
    read -r -p "仍要继续执行恢复前检查？[y/N] " os_confirm
    [[ "$os_confirm" =~ ^[Yy]$ ]] || die "用户取消：未确认未知 Linux 发行版"
  fi

  for x in docker tar sha256sum python3 ip ss; do command -v "$x" >/dev/null || die "缺少命令：$x"; done
  docker info >/dev/null 2>&1 || die "Docker Engine 未运行"
  docker compose version >/dev/null 2>&1 || die "Docker Compose Plugin 不可用"
  local security_options
  security_options="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
  [[ "$security_options" != *rootless* ]] || die "当前恢复流程要求 rootful Docker；检测到 rootless Docker"
  local root free1 free2 min=$((25*1024*1024*1024))
  root="$(docker info --format '{{.DockerRootDir}}')"
  free1="$(df -PB1 /opt | awk 'NR==2{print $4}')"
  free2="$(df -PB1 "$root" | awk 'NR==2{print $4}')"
  ((free1>=min)) || die "/opt 所在文件系统至少需要 25 GiB 可用空间"
  ((free2>=min)) || die "Docker 数据目录至少需要 25 GiB 可用空间"
  info "Linux、Docker、Compose、架构和磁盘检查通过"
}

verify_archive_sha256(){
  local archive="$1" expected actual
  [[ -s "$archive.sha256" ]] || die "缺少 SHA256 文件：$archive.sha256"
  expected="$(awk 'NR==1 {print $1}' "$archive.sha256")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA256 文件格式错误：$archive.sha256"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA256 不匹配：$archive"
  info "SHA256：$(basename "$archive") PASS"
}

verify_bundle(){
  local files=(
    01-images/docker-images.tar
    02-config/seafile-config.tar
    02-config/caddy-data.tar
    02-config/ubuntu/seafile-server.yml
    02-config/ubuntu/caddy.yml
    02-config/ubuntu/onlyoffice.yml
    02-config/ubuntu/seadoc.yml
    01-images/seadoc-image.tar
    01-images/seadoc-image.tar.sha256
    09-manifests/seadoc-image-inspect.json
    03-database/mariadb-data.tar
    04-seafile-data/seafile-data.tar
    05-onlyoffice/onlyoffice-data.tar
    05-onlyoffice/onlyoffice-fonts.tar
    06-docker-volumes/postgresql/data.tar
    06-docker-volumes/rabbitmq/data.tar
    06-docker-volumes/redis/data.tar
    07-patches/onlyoffice-patch-sources.tar
  )
  local f
  for f in "${files[@]}"; do [[ -s "$PKG/$f" ]] || die "迁移包缺少：$f"; done

  local archives=(
    01-images/docker-images.tar 01-images/seadoc-image.tar
    02-config/seafile-config.tar 02-config/caddy-data.tar
    03-database/mariadb-data.tar 04-seafile-data/seafile-data.tar
    05-onlyoffice/onlyoffice-data.tar 05-onlyoffice/onlyoffice-fonts.tar
    06-docker-volumes/postgresql/data.tar
    06-docker-volumes/rabbitmq/data.tar
    06-docker-volumes/redis/data.tar
    07-patches/onlyoffice-patch-sources.tar
  )
  for f in "${archives[@]}"; do
    [[ -s "$PKG/$f" ]] || die "归档文件为空：$f"
    verify_archive_sha256 "$PKG/$f"
    tar -tf "$PKG/$f" >/dev/null || die "TAR 结构损坏：$f"
  done

  # These two archives were created with a named top-level directory, unlike
  # the data archives created from `tar -C DIR .`. Validate that layout now.
  # Data archives created with `tar -C DIR .` must contain paths rooted at ./.
  local root_archive
  for root_archive in \
    02-config/caddy-data.tar \
    03-database/mariadb-data.tar \
    04-seafile-data/seafile-data.tar \
    05-onlyoffice/onlyoffice-data.tar \
    06-docker-volumes/postgresql/data.tar \
    06-docker-volumes/rabbitmq/data.tar \
    06-docker-volumes/redis/data.tar; do
    tar -tf "$PKG/$root_archive" | awk '$0=="." || $0=="./" || index($0,"./")==1 {next} {bad=1} END {exit bad}' \
      || die "数据归档不是预期的目录内容格式：$root_archive"
  done
  tar -tf "$PKG/03-database/mariadb-data.tar" | awk 'index($0,"./ibdata1")==1 {found=1} END {exit !found}' \
    || die "MariaDB 归档缺少 ibdata1"
  tar -tf "$PKG/04-seafile-data/seafile-data.tar" | awk 'index($0,"./seafile/seafile-data/current_version")==1 {found=1} END {exit !found}' \
    || die "Seafile 归档缺少 current_version"
  tar -tf "$PKG/06-docker-volumes/rabbitmq/data.tar" | awk 'index($0,"./mnesia/rabbit@05831744982c/")==1 {found=1} END {exit !found}' \
    || die "RabbitMQ 归档缺少原活动节点数据"
  tar -tf "$PKG/05-onlyoffice/onlyoffice-fonts.tar" | awk '$0 ~ /^onlyoffice-fonts\// {found=1} END {exit !found}' \
    || die "字体归档目录结构与预期不符（缺少 onlyoffice-fonts/ 顶层目录）"
  tar -tf "$PKG/02-config/seafile-config.tar" | awk '$0 ~ /^seafile\// {found=1} END {exit !found}' \
    || die "Seafile 配置归档结构错误（缺少 seafile/ 顶层目录）"
  tar -tf "$PKG/07-patches/onlyoffice-patch-sources.tar" | awk '$0 ~ /^seafile-recovery\/onlyoffice-patch\// {found=1} END {exit !found}' \
    || die "补丁源码归档结构错误"

  local oo_compose="$PKG/02-config/ubuntu/onlyoffice.yml"
  grep -Fq 'hostname: "${RABBITMQ_HOSTNAME:-05831744982c}"' "$oo_compose" || die "ONLYOFFICE Compose 未保留可配置 RabbitMQ hostname"
  [[ "$(grep -c 'name: \${ONLYOFFICE_' "$oo_compose")" -eq 3 ]] \
    || die "ONLYOFFICE Compose 缺少三个可配置具名卷定义"
  [[ "$(grep -c 'external: true' "$oo_compose")" -eq 3 ]] \
    || die "ONLYOFFICE 三个恢复数据卷必须声明 external: true，避免 Compose 拒绝手工恢复的具名卷"
  grep -Fq 'ONLYOFFICE_INTERNAL_FILESERVER_ROOT=http://seafile:8082' "$PKG/02-config/ubuntu/seafile-server.yml" \
    || die "Seafile Compose 缺少内部 FileServer 地址"
  grep -Fq 'ONLYOFFICE_INTERNAL_SEAHUB_ROOT=http://seafile' "$PKG/02-config/ubuntu/seafile-server.yml" \
    || die "Seafile Compose 缺少内部回调地址"
  grep -Fq 'ENABLE_SEADOC=${ENABLE_SEADOC:-true}' "$PKG/02-config/ubuntu/seafile-server.yml" \
    || die "Seafile Compose 未将 ENABLE_SEADOC 传入容器"
  grep -Fq 'SEADOC_SERVER_URL=${SEAFILE_SERVER_PROTOCOL:-http}://${SEAFILE_SERVER_HOSTNAME:?Variable is not set or empty}/sdoc-server' "$PKG/02-config/ubuntu/seafile-server.yml" \
    || die "Seafile Compose 未配置 SeaDoc 外部访问 URL"

  tar -xOf "$PKG/01-images/docker-images.tar" manifest.json | python3 -c '
import json,sys
m=json.load(sys.stdin)
tags={t for x in m for t in (x.get("RepoTags") or [])}
need={"seafileltd/seafile-mc:13.0-latest","onlyoffice/documentserver:8.1.0.1",
"mariadb:10.11","lucaslorentz/caddy-docker-proxy:2.12-alpine","redis:latest"}
if need-tags: sys.exit("Docker 镜像归档缺少预期镜像："+", ".join(sorted(need-tags)))
print("五个 Docker 镜像清单通过")
 ' || die "基础 Docker 镜像清单验证失败"
  tar -xOf "$PKG/01-images/seadoc-image.tar" manifest.json | python3 -c '
import json,sys
m=json.load(sys.stdin)
tags={t for x in m for t in (x.get("RepoTags") or [])}
need="seafileltd/sdoc-server:2.0-latest"
if need not in tags:
    sys.exit("SeaDoc 镜像归档缺少："+need)
' || die "SeaDoc 镜像归档清单验证失败"

  python3 - "$PKG/09-manifests/seadoc-image-inspect.json" <<'PYSDOC'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    data=json.load(f)
if not isinstance(data,list) or not data:
    raise SystemExit("SeaDoc image inspect 文件格式错误")
item=data[0]
if not item.get("Id","").startswith("sha256:"):
    raise SystemExit("SeaDoc Image ID 缺失")
if "seafileltd/sdoc-server:2.0-latest" not in (item.get("RepoTags") or []):
    raise SystemExit("SeaDoc inspect 标签不匹配")
if item.get("Os") != "linux" or item.get("Architecture") != "amd64":
    raise SystemExit("SeaDoc 镜像必须为 linux/amd64")
print("SeaDoc 镜像身份清单：PASS")
PYSDOC

  grep -Fq 'SEAHUB_SERVICE_URL=${SEAFILE_SERVICE_URL:-http://seafile}' "$PKG/02-config/ubuntu/seadoc.yml" \
    || die "SeaDoc 内部 Seahub 地址配置不正确"
  grep -Fq 'caddy.2_handle_path: "/sdoc-server/*"' "$PKG/02-config/ubuntu/seadoc.yml" \
    || die "SeaDoc Caddy /sdoc-server 路由缺失"
  grep -Fq 'caddy.1_handle_path: "/socket.io/*"' "$PKG/02-config/ubuntu/seadoc.yml" \
    || die "SeaDoc WebSocket 路由缺失"
  [[ -s "$PKG/SHA256SUMS" ]] || die "缺少迁移包总校验清单 SHA256SUMS"
  info "验证迁移包总校验清单"
  (cd "$PKG" && sha256sum -c SHA256SUMS) || die "迁移包总 SHA256 校验失败"

  local package_id saved_id id_file="${PACKAGE_ID_FILE:-$STATE/package-id}"
  package_id="$(sha256sum "$PKG/SHA256SUMS" | awk '{print $1}')"
  if [[ -f "$id_file" ]]; then
    saved_id="$(cat "$id_file")"
    [[ "$saved_id" == "$package_id" ]] || die "当前迁移包与此前同一部署模式使用的包不同；为防止混用数据，停止执行。"
  else
    printf '%s\n' "$package_id" > "$id_file"
    chmod 600 "$id_file"
  fi
  info "迁移包身份校验通过：$package_id"
  info "12 个归档（含 SeaDoc 镜像）的 SHA256 和 TAR 结构检查通过"
}

configure(){
  local saved="${SETTINGS_FILE:-$STATE/target-settings.env}" ip port tz
  if [[ -f "$saved" ]]; then
    echo "已保存目标配置："; cat "$saved"
    read -r -p "继续使用？[Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      # shellcheck disable=SC1090
      source "$saved"
      ip -o -4 addr show scope global | awk -v ip="${TARGET_IPV4:-}" '$2 !~ /^(docker0|br-|veth|tailscale|wg)/ {split($4,a,"/");if(a[1]==ip)found=1} END {exit !found}' \
        || die "已保存的 IP 当前不在物理/主机网卡上；请选择 N 重新输入"
      [[ "${ONLYOFFICE_PORT:-}" =~ ^[0-9]+$ ]] && ((ONLYOFFICE_PORT>0 && ONLYOFFICE_PORT<=65535)) \
        || die "已保存的 ONLYOFFICE 端口无效"
      [[ "$ONLYOFFICE_PORT" != 80 && "$ONLYOFFICE_PORT" != 443 ]] || die "已保存的 ONLYOFFICE 端口与 Caddy 冲突"
      [[ -e "/usr/share/zoneinfo/${TIME_ZONE:-}" ]] || die "已保存的 Seafile 时区无效"
      if ! done_stage config-applied; then
        if [[ "$ALLOW_EXISTING_PORTS" == "1" ]]; then
          if [[ -n "$CURRENT_ONLYOFFICE_PORT" && "$ONLYOFFICE_PORT" != "$CURRENT_ONLYOFFICE_PORT" ]]; then
            ss -H -ltn | awk -v p="$ONLYOFFICE_PORT" '{n=split($4,a,":");if(a[n]==p)found=1} END {exit !found}' \
              && die "新指定的 ONLYOFFICE 端口 $ONLYOFFICE_PORT 已被占用"
          fi
        else
          for p in 80 443 "$ONLYOFFICE_PORT"; do
            ss -H -ltn | awk -v p="$p" '{n=split($4,a,":");if(a[n]==p)found=1} END {exit !found}' && die "端口 $p 已被占用"
          done
        fi
      fi
      return
    fi
  fi
  echo "本机全局 IPv4 地址："
  ip -o -4 addr show scope global | awk '{a=$4;sub(/\/.*/,"",a);if($2 !~ /^(docker0|br-|veth|tailscale|wg)/)print "  "$2"  "a}'
  read -r -p "请输入已配置在主机网卡上的固定 IPv4 [${CURRENT_TARGET_IP:-}]: " ip
  ip="${ip:-${CURRENT_TARGET_IP:-}}"
  python3 - "$ip" <<'PY' || die "IPv4 格式无效"
import ipaddress,sys
try:
 x=ipaddress.IPv4Address(sys.argv[1])
 if x.is_loopback or x.is_unspecified or x.is_multicast: raise ValueError()
except Exception: sys.exit(1)
PY
  ip -o -4 addr show scope global | awk -v ip="$ip" '$2 !~ /^(docker0|br-|veth|tailscale|wg)/ {split($4,a,"/");if(a[1]==ip)found=1} END {exit !found}' || die "该 IP 未配置在主机物理/普通网卡上"
  read -r -p "ONLYOFFICE 端口 [${CURRENT_ONLYOFFICE_PORT:-6233}]：" port; port="${port:-${CURRENT_ONLYOFFICE_PORT:-6233}}"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port>0 && port<=65535)) || die "端口无效"
  [[ "$port" != 80 && "$port" != 443 ]] || die "端口不能为 80 或 443"
  read -r -p "Seafile 服务时区 [${CURRENT_TIME_ZONE:-Etc/UTC}]：" tz; tz="${tz:-${CURRENT_TIME_ZONE:-Etc/UTC}}"
  [[ "$tz" =~ ^[A-Za-z0-9_+./-]+$ && -e "/usr/share/zoneinfo/$tz" ]] || die "时区无效"
  if ! done_stage config-applied; then
    if [[ "$ALLOW_EXISTING_PORTS" == "1" ]]; then
      if [[ -n "$CURRENT_ONLYOFFICE_PORT" && "$port" != "$CURRENT_ONLYOFFICE_PORT" ]]; then
        ss -H -ltn | awk -v p="$port" '{n=split($4,a,":");if(a[n]==p)found=1} END {exit !found}' \
          && die "新指定的 ONLYOFFICE 端口 $port 已被占用"
      fi
    else
      for p in 80 443 "$port"; do
        ss -H -ltn | awk -v p="$p" '{n=split($4,a,":");if(a[n]==p)found=1} END {exit !found}' && die "端口 $p 已被占用"
      done
    fi
  fi
  echo
  echo "Seafile：      http://$ip"
  echo "ONLYOFFICE：   http://$ip:$port"
  echo "APIJS：        http://$ip:$port/web-apps/apps/api/documents/api.js"
  echo "内部下载：     http://seafile:8082"
  echo "内部回调：     http://seafile"
  echo "Seafile 时区： $tz"
  echo "RabbitMQ：     rabbit@$RABBITMQ_HOSTNAME"
  read -r -p "确认以上配置并开始恢复？[y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "用户取消"
  printf 'TARGET_IPV4=%s\nONLYOFFICE_PORT=%s\nTIME_ZONE=%s\nRABBITMQ_HOSTNAME=%s\nONLYOFFICE_PG_VOLUME=%s\nONLYOFFICE_RABBIT_VOLUME=%s\nONLYOFFICE_REDIS_VOLUME=%s\n' \
    "$ip" "$port" "$tz" "$RABBITMQ_HOSTNAME" "$ONLYOFFICE_PG_VOLUME" "$ONLYOFFICE_RABBIT_VOLUME" "$ONLYOFFICE_REDIS_VOLUME" > "$saved"
  chmod 600 "$saved"
}

load_images(){
  local -A expected=(
    [seafileltd/seafile-mc:13.0-latest]=sha256:b0c90832126bf432db908449f1bb450211e6bbf75a2193bab3399e2a9636eccf
    [onlyoffice/documentserver:8.1.0.1]=sha256:423328ee377374c48a30c2aa416e4afedf621faff068f97966cb9b87a28550bd
    [mariadb:10.11]=sha256:0d0945c57f75b3a3b9ebe71aedaaad005fa5305054e8fca3d2e42a8c92b43b5e
    [lucaslorentz/caddy-docker-proxy:2.12-alpine]=sha256:c0a1707abe5814ed682c43a1182ded7fe3975405b47462c9df48a9f4e3a525d7
    [redis:latest]=sha256:97ec88159e6d7cfb5ddef9015386087d58a912de80112f06ebdfa78fa5989901
  )
  local image actual missing=0
  for image in "${!expected[@]}"; do
    actual="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
    [[ "$actual" == "${expected[$image]}" ]] || missing=1
  done
  if (( missing )); then
    info "导入五个基础 Docker 镜像"
    docker load -i "$PKG/01-images/docker-images.tar"
  else
    info "五个基础镜像 Image ID 均匹配，跳过导入"
  fi
  for image in "${!expected[@]}"; do
    actual="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
    [[ "$actual" == "${expected[$image]}" ]] || die "基础镜像 Image ID 不匹配：$image（实际：${actual:-missing}）"
  done

  local expected_seadoc actual_seadoc
  expected_seadoc="$(python3 - "$PKG/09-manifests/seadoc-image-inspect.json" <<'PYSDOC'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    print(json.load(f)[0]["Id"])
PYSDOC
)"
  actual_seadoc="$(docker image inspect seafileltd/sdoc-server:2.0-latest --format '{{.Id}}' 2>/dev/null || true)"
  if [[ "$actual_seadoc" != "$expected_seadoc" ]]; then
    info "导入归档中的 SeaDoc 2.0 镜像"
    docker load -i "$PKG/01-images/seadoc-image.tar"
  else
    info "SeaDoc 镜像 Image ID 匹配，跳过导入"
  fi
  actual_seadoc="$(docker image inspect seafileltd/sdoc-server:2.0-latest --format '{{.Id}}' 2>/dev/null || true)"
  [[ "$actual_seadoc" == "$expected_seadoc" ]] || die "SeaDoc Image ID 不匹配（实际：${actual_seadoc:-missing}）"

  mark images
}

load_seadoc_image_only(){
  local expected actual
  expected="$(python3 - "$PKG/09-manifests/seadoc-image-inspect.json" <<'PYSDOC'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    item=json.load(f)[0]
if item.get("Os")!="linux" or item.get("Architecture")!="amd64":
    raise SystemExit("SeaDoc 镜像不是 linux/amd64")
print(item["Id"])
PYSDOC
)"
  actual="$(docker image inspect seafileltd/sdoc-server:2.0-latest --format '{{.Id}}' 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    info "仅导入 SeaDoc 镜像；不会替换现有 Seafile、MariaDB、ONLYOFFICE、Caddy 镜像"
    docker load -i "$PKG/01-images/seadoc-image.tar"
  fi
  actual="$(docker image inspect seafileltd/sdoc-server:2.0-latest --format '{{.Id}}' 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || die "SeaDoc 镜像 Image ID 不匹配"
  info "SeaDoc 镜像身份检查通过"
}

restore_dir(){
  local archive="$1" target="$2" stage="$3" marker="$4"
  if done_stage "$marker"; then
    [[ -d "$target" ]] || die "恢复标记存在但目标目录缺失：$target"
    info "$target 已恢复，跳过"
    return
  fi
  [[ ! -e "$stage" ]] || die "发现未完成的临时目录：$stage，请人工检查"
  if [[ -e "$target" ]]; then
    [[ -d "$target" && -z "$(find "$target" -mindepth 1 -print -quit)" ]] || die "目标非空，拒绝覆盖：$target"
    rmdir "$target"
  fi
  mkdir -p "$(dirname "$target")" "$stage"
  tar --numeric-owner --acls --xattrs -xpf "$archive" -C "$stage"
  mv "$stage" "$target"
  mark "$marker"
  info "已恢复：$target"
}

restore_empty_dir(){
  local target="$1" marker="$2"
  if done_stage "$marker"; then
    [[ -d "$target" ]] || die "目录恢复标记存在但目标目录缺失：$target"
    info "$target 已准备，跳过"
    return
  fi
  if [[ -e "$target" ]]; then
    [[ -d "$target" && -z "$(find "$target" -mindepth 1 -print -quit)" ]] \
      || die "SeaDoc 目录已存在且非空；为保护现有数据而停止：$target"
  fi
  mkdir -p "$target"
  mark "$marker"
  info "已准备新的 SeaDoc 持久化目录：$target"
}

restore_wrapped_dir(){
  # Restore archives made with: tar -C /opt onlyoffice-fonts
  # The archive contains onlyoffice-fonts/ as its top-level directory.
  local archive="$1" target="$2" wrapper="$3" stage="$4" marker="$5"
  if done_stage "$marker"; then
    [[ -d "$target" ]] || die "恢复标记存在但目标目录缺失：$target"
    info "$target 已恢复，跳过"
    return
  fi
  [[ ! -e "$stage" ]] || die "发现未完成的临时目录：$stage，请人工检查"
  if [[ -e "$target" ]]; then
    [[ -d "$target" && -z "$(find "$target" -mindepth 1 -print -quit)" ]] \
      || die "目标非空，拒绝覆盖：$target"
    rmdir "$target"
  fi
  mkdir -p "$(dirname "$target")" "$stage"
  tar --numeric-owner --acls --xattrs -xpf "$archive" -C "$stage"
  [[ -d "$stage/$wrapper" ]] || die "归档缺少预期目录：$wrapper"
  mv "$stage/$wrapper" "$target"
  rmdir "$stage"
  mark "$marker"
  info "已恢复：$target"
}

restore_config(){
  if done_stage config; then
    [[ -d /opt/seafile && -s /opt/seafile/.env ]] || die "配置恢复标记存在，但 /opt/seafile/.env 缺失"
  else
    local stage=/opt/.seafile-config.restore-staging
    [[ ! -e "$stage" ]] || die "配置临时目录已存在：$stage"
    [[ ! -e /opt/seafile ]] || { [[ -d /opt/seafile && -z "$(find /opt/seafile -mindepth 1 -print -quit)" ]] || die "/opt/seafile 非空，拒绝覆盖"; rmdir /opt/seafile; }
    mkdir -p "$stage"
    tar --numeric-owner --acls --xattrs -xpf "$PKG/02-config/seafile-config.tar" -C "$stage"
    [[ -d "$stage/seafile" ]] || die "配置归档结构错误"
    mv "$stage/seafile" /opt/seafile
    rmdir "$stage"
    mark config
  fi
  if done_stage patch-source; then
    [[ -d /opt/seafile-recovery/onlyoffice-patch ]] || die "补丁源码恢复标记存在，但源文件目录缺失"
  else
    local stage=/opt/.seafile-recovery.restore-staging
    [[ ! -e "$stage" ]] || die "补丁源恢复临时目录已存在，请人工检查"
    if [[ -e /opt/seafile-recovery ]]; then
      [[ -d /opt/seafile-recovery && -z "$(find /opt/seafile-recovery -mindepth 1 -print -quit)" ]] \
        || die "补丁源备份目标已存在且非空，请人工检查"
      rmdir /opt/seafile-recovery
    fi
    mkdir -p "$stage"
    tar --numeric-owner --acls --xattrs -xpf "$PKG/07-patches/onlyoffice-patch-sources.tar" -C "$stage"
    [[ -d "$stage/seafile-recovery" ]] || die "补丁源归档结构错误"
    mv "$stage/seafile-recovery" /opt/seafile-recovery
    rmdir "$stage"
    mark patch-source
  fi
}

restore_volume(){
  local name="$1" sub="$2" marker="$3" exists=0
  if done_stage "$marker"; then
    docker volume inspect "$name" >/dev/null 2>&1 || die "数据卷恢复标记存在，但卷 $name 不存在"
    info "卷 $name 已恢复，跳过"
    return
  fi
  docker volume inspect "$name" >/dev/null 2>&1 && exists=1 || true
  if ((exists)); then
    local content
    content="$(docker run --rm --network none --mount "type=volume,source=$name,target=/v,readonly" --entrypoint sh seafileltd/seafile-mc:13.0-latest -c 'find /v -mindepth 1 -print -quit')"
    [[ -z "$content" ]] || die "卷 $name 已有数据且没有完成标记，拒绝覆盖"
  else
    docker volume create "$name" >/dev/null
  fi
  docker run --rm --network none \
    --mount "type=volume,source=$name,target=/restore" \
    --mount "type=bind,source=$PKG/06-docker-volumes,target=/backup,readonly" \
    --entrypoint sh seafileltd/seafile-mc:13.0-latest \
    -c "tar --numeric-owner --acls --xattrs -xpf /backup/$sub/data.tar -C /restore"
  mark "$marker"
}

apply_config(){
  local settings="${SETTINGS_FILE:-$STATE/target-settings.env}"
  # shellcheck disable=SC1090
  source "$settings"
  local patch=/opt/seafile/patches/onlyoffice/utils.py
  local expected=900ba73c637ef3271770fb6fd22ee7b90644d293706457fed59a30c61b83a926
  [[ -f "$patch" ]] || die "ONLYOFFICE 补丁不存在"
  [[ "$(sha256sum "$patch" | awk '{print $1}')" == "$expected" ]] || die "ONLYOFFICE 补丁 SHA256 不匹配"

  for f in seafile-server.yml caddy.yml onlyoffice.yml seadoc.yml; do
    install -m 0644 "$PKG/02-config/ubuntu/$f" "/opt/seafile/$f"
  done

  # Preserve the restored, unmodified configuration before applying target-specific values.
  [[ -e /opt/seafile/.env.pre-migration ]] || cp -a /opt/seafile/.env /opt/seafile/.env.pre-migration
  [[ -e /opt/seafile-data/seafile/conf/seahub_settings.py.pre-migration ]] || \
    cp -a /opt/seafile-data/seafile/conf/seahub_settings.py \
      /opt/seafile-data/seafile/conf/seahub_settings.py.pre-migration

  python3 - "$TARGET_IPV4" "$ONLYOFFICE_PORT" "$TIME_ZONE" "$RABBITMQ_HOSTNAME" "$ONLYOFFICE_PG_VOLUME" "$ONLYOFFICE_RABBIT_VOLUME" "$ONLYOFFICE_REDIS_VOLUME" <<'PY'
from pathlib import Path
import re,sys
ip,port,tz,rabbit_host,pg_volume,rabbit_volume,redis_volume=sys.argv[1:]
p=Path("/opt/seafile/.env"); s=p.read_text(encoding="utf-8")
values={
 "SEAFILE_SERVER_HOSTNAME":ip,
 "ONLYOFFICE_PORT":port,
 "TIME_ZONE":tz,
 "COMPOSE_FILE":"'seafile-server.yml,caddy.yml,onlyoffice.yml,seadoc.yml'",
 "ENABLE_SEADOC":"true",
 "SEADOC_IMAGE":"seafileltd/sdoc-server:2.0-latest",
 "SEADOC_VOLUME":"/opt/seadoc-data",
 "RABBITMQ_HOSTNAME":rabbit_host,
 "ONLYOFFICE_PG_VOLUME":pg_volume,
 "ONLYOFFICE_RABBIT_VOLUME":rabbit_volume,
 "ONLYOFFICE_REDIS_VOLUME":redis_volume,
}
for k,v in values.items():
 pat=re.compile(rf"(?m)^{re.escape(k)}=.*$")
 n=len(pat.findall(s))
 if n>1: raise SystemExit(f".env 中 {k} 重复")
 s=pat.sub(f"{k}={v}",s) if n else s+f"\n{k}={v}\n"
p.write_text(s,encoding="utf-8")
p=Path("/opt/seafile-data/seafile/conf/seahub_settings.py"); s=p.read_text(encoding="utf-8")
pat=re.compile(r"""(ONLYOFFICE_APIJS_URL\s*=\s*\(\s*['"]https?://)[^:'"]+:\d+(/['"]\s*['"]web-apps/apps/api/documents/api\.js['"]\s*\))""")
m=list(pat.finditer(s))
if len(m)!=1: raise SystemExit(f"ONLYOFFICE_APIJS_URL 匹配数量异常：{len(m)}")
rep=m[0].group(1)+ip+":"+port+m[0].group(2)
p.write_text(pat.sub(lambda _:rep,s,count=1),encoding="utf-8")
PY
  chmod 600 /opt/seafile/.env
  (cd /opt/seafile && docker compose config --quiet) || die "Compose 配置检查失败"
  local compose_json
  compose_json="$(mktemp)"
  if ! (cd /opt/seafile && docker compose config --format json > "$compose_json"); then
    rm -f "$compose_json"
    die "无法生成 Compose JSON 配置"
  fi
  if ! python3 - "$compose_json" "$TARGET_IPV4" "$ONLYOFFICE_PORT" "$RABBITMQ_HOSTNAME" "$ONLYOFFICE_PG_VOLUME" "$ONLYOFFICE_RABBIT_VOLUME" "$ONLYOFFICE_REDIS_VOLUME" <<'PYCFG'
import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    cfg=json.load(f)
ip,port,rabbit_host,pg_volume,rabbit_volume,redis_volume=sys.argv[2:]
services=cfg["services"]
seafile=services["seafile"]
oo=services["onlyoffice"]
sd=services["seadoc"]
caddy=services["caddy"]
assert oo.get("hostname")==rabbit_host, "ONLYOFFICE hostname 不正确"
targets={v.get("target") for v in oo.get("volumes",[]) if v.get("type")=="volume"}
need={"/var/lib/postgresql","/var/lib/rabbitmq","/var/lib/redis"}
assert need.issubset(targets), f"ONLYOFFICE 具名卷挂载不完整：{need-targets}"
expected_volumes={
    "onlyoffice-postgresql":pg_volume,
    "onlyoffice-rabbitmq":rabbit_volume,
    "onlyoffice-redis":redis_volume,
}
for key,name in expected_volumes.items():
    volume_cfg=cfg.get("volumes",{}).get(key,{})
    assert volume_cfg.get("name")==name, f"Docker 具名卷名称错误：{key}"
    assert volume_cfg.get("external") is True, f"Docker 具名卷必须声明 external: true：{key}"
env=seafile.get("environment",{})
assert env.get("ONLYOFFICE_INTERNAL_FILESERVER_ROOT")=="http://seafile:8082"
assert env.get("ONLYOFFICE_INTERNAL_SEAHUB_ROOT")=="http://seafile"
patch_target="/opt/seafile/seafile-server-13.0.28/seahub/seahub/onlyoffice/utils.py"
patches=[v for v in seafile.get("volumes",[]) if v.get("target")==patch_target]
assert len(patches)==1 and patches[0].get("read_only") is True, "ONLYOFFICE 补丁未只读挂载"
ports={str(p.get("published")) for p in caddy.get("ports",[])}
assert {"80","443",port}.issubset(ports), f"Caddy 端口不完整：{ports}"
labels=oo.get("labels",{})
assert labels.get("caddy")==f"http://{ip}:{port}", "ONLYOFFICE Caddy 路由 IP/端口不正确"
assert seafile.get("labels",{}).get("caddy")==f"http://{ip}", "Seafile Caddy 路由 IP 不正确"

seafile_env=seafile.get("environment",{})
sd_env=sd.get("environment",{})
assert str(seafile_env.get("ENABLE_SEADOC","")).lower()=="true", "Seafile 容器未启用 SeaDoc"
assert seafile_env.get("SEADOC_SERVER_URL")==f"http://{ip}/sdoc-server", "Seafile SeaDoc 外部 URL 不正确"
assert sd.get("image")=="seafileltd/sdoc-server:2.0-latest", "SeaDoc 镜像标签不正确"
assert sd_env.get("DB_HOST")=="db", "SeaDoc 数据库主机不正确"
assert sd_env.get("DB_NAME")=="seahub_db", "SeaDoc 应使用现有 seahub_db"
assert sd_env.get("JWT_PRIVATE_KEY")==seafile_env.get("JWT_PRIVATE_KEY"), "SeaDoc 与 Seafile JWT_PRIVATE_KEY 不一致"
assert sd_env.get("SEAHUB_SERVICE_URL")=="http://seafile", "SeaDoc 内部 Seahub 地址不正确"
assert any(v.get("source")=="/opt/seadoc-data" and v.get("target")=="/shared" for v in sd.get("volumes",[])), "SeaDoc 持久化目录挂载不正确"
sd_labels=sd.get("labels",{})
assert sd_labels.get("caddy")==f"http://{ip}", "SeaDoc Caddy 主机路由不正确"
assert sd_labels.get("caddy.1_handle_path")=="/socket.io/*", "SeaDoc WebSocket 路由不正确"
assert sd_labels.get("caddy.2_handle_path")=="/sdoc-server/*", "SeaDoc API 路由不正确"
print("Compose 关键配置（含 SeaDoc）：PASS")
PYCFG
  then
    rm -f "$compose_json"
    die "Compose 关键配置校验失败"
  fi
  rm -f "$compose_json"
  mark config-applied
}

wait_health(){
  local name="$1" timeout="${2:-300}" elapsed=0 status
  while ((elapsed<timeout)); do
    status="$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [[ "$status" == healthy || "$status" == running ]] && { info "$name：$status"; return; }
    [[ "$status" == unhealthy || "$status" == exited || "$status" == dead ]] && { docker logs --tail=60 "$name" || true; die "$name 状态异常：$status"; }
    sleep 5; elapsed=$((elapsed+5))
  done
  docker logs --tail=80 "$name" || true
  die "$name 健康检查超时"
}

start_services(){
  # Always run Compose reconciliation. This also applies a corrected target IP/port
  # after a previous run reached the start stage but failed final verification.
  cd /opt/seafile
  docker compose up -d db redis
  wait_health seafile-mysql 300
  docker compose up -d seafile
  wait_health seafile 300
  docker compose up -d onlyoffice caddy
  local elapsed=0
  until docker exec seafile-onlyoffice bash -lc 'curl -fsS http://127.0.0.1/healthcheck >/dev/null' 2>/dev/null; do
    ((elapsed<300)) || { docker logs --tail=100 seafile-onlyoffice || true; die "ONLYOFFICE 启动超时"; }
    sleep 5; elapsed=$((elapsed+5))
  done
  info "启动 SeaDoc 知识库服务"
  docker compose up -d seadoc
  wait_health seadoc 180

  # The SeaDoc image has no Docker healthcheck; "running" alone is not readiness.
  # Poll the public reverse-proxy endpoint until the sdoc-server welcome page is served.
  local seadoc_elapsed=0 seadoc_code=""
  until seadoc_code="$(http_status "http://$TARGET_IPV4/sdoc-server/")" && [[ "$seadoc_code" == "200" ]]; do
    if ((seadoc_elapsed >= 180)); then
      docker logs --tail=100 seadoc || true
      die "SeaDoc HTTP endpoint did not become ready within 180 seconds"
    fi
    sleep 5
    seadoc_elapsed=$((seadoc_elapsed + 5))
  done

  wait_health seafile-caddy 180
  mark started
}

verify(){
  local settings="${SETTINGS_FILE:-$STATE/target-settings.env}"
  [[ -f "$settings" ]] || die "没有目标配置，请先完成安装或升级"
  # shellcheck disable=SC1090
  source "$settings"
  cd /opt/seafile
  docker compose ps
  docker exec -i seafile python3 - <<'PY'
import os,sys,MySQLdb
for db in ("ccnet_db","seafile_db","seahub_db"):
 try:
  c=MySQLdb.connect(host=os.getenv("SEAFILE_MYSQL_DB_HOST","db"),user=os.getenv("SEAFILE_MYSQL_DB_USER","seafile"),passwd=os.getenv("SEAFILE_MYSQL_DB_PASSWORD",""),db=db,connect_timeout=5)
  c.close(); print(db+": PASS")
 except Exception as e:
  print(db+": FAIL",e); sys.exit(1)
PY
  docker exec seafile-onlyoffice bash -lc 'curl -fsS http://127.0.0.1/healthcheck'
  echo
  local node
  node="$(docker exec seafile-onlyoffice bash -lc 'rabbitmqctl -q eval "node()."' | tr -d '\r"')"
  echo "RabbitMQ node: $node"
  [[ "$node" == "rabbit@$RABBITMQ_HOSTNAME" ]] || die "RabbitMQ 节点身份不匹配"
  local mnesia_dir
  mnesia_dir="$(docker exec seafile-onlyoffice bash -lc 'rabbitmqctl -q eval "mnesia:system_info(directory)."' | tr -d '\r"')"
  echo "RabbitMQ Mnesia: $mnesia_dir"
  [[ "$mnesia_dir" == */rabbit@"$RABBITMQ_HOSTNAME" ]] || die "RabbitMQ 未使用原 Mnesia 节点目录"
  local code
  code="$(docker exec seafile-onlyoffice bash -lc 'curl --connect-timeout 3 --max-time 8 -sS -o /dev/null -w "%{http_code}" http://seafile:8082/')" || die "FileServer 内部访问失败"
  [[ "$code" == 404 ]] || die "FileServer 根路径预期 404，实际 $code"
  code="$(docker exec seafile-onlyoffice bash -lc 'curl --connect-timeout 3 --max-time 8 -sS -o /dev/null -w "%{http_code}" http://seafile/onlyoffice/editor-callback/')" || die "回调路由不可达"
  [[ "$code" == 200 ]] || die "回调路由 HTTP $code"
  docker exec seafile sh -lc 'curl -fsS http://onlyoffice/healthcheck' | grep -q true || die "Seafile 无法访问 ONLYOFFICE"
  code="$(http_status "http://$TARGET_IPV4/")" || die "Seafile 浏览器入口无法访问"
  [[ "$code" == 200 || "$code" == 302 ]] || die "Seafile 浏览器入口 HTTP $code"
  code="$(http_status "http://$TARGET_IPV4:$ONLYOFFICE_PORT/web-apps/apps/api/documents/api.js")" || die "ONLYOFFICE APIJS 无法访问"
  [[ "$code" == 200 ]] || die "ONLYOFFICE APIJS HTTP $code"

  docker inspect seadoc >/dev/null 2>&1 || die "SeaDoc 容器不存在"
  [[ "$(docker inspect seadoc --format '{{.State.Status}}')" == "running" ]] || die "SeaDoc 容器未运行"
  grep -Fq "ENABLE_SEADOC=true" /opt/seafile/.env || die ".env 未启用 SeaDoc"
  [[ "$(docker exec seafile printenv ENABLE_SEADOC 2>/dev/null || true)" == "true" ]] \
    || die "Seafile 容器运行环境未启用 SeaDoc"
  [[ "$(docker exec seafile printenv SEADOC_SERVER_URL 2>/dev/null || true)" == "http://$TARGET_IPV4/sdoc-server" ]] \
    || die "Seafile 容器中的 SEADOC_SERVER_URL 不正确"
  [[ -d /opt/seadoc-data ]] || die "SeaDoc 持久化目录不存在"
  code="$(http_status "http://$TARGET_IPV4/sdoc-server/")" || die "SeaDoc /sdoc-server 入口无法访问"
  [[ "$code" == 200 ]] || die "SeaDoc /sdoc-server HTTP $code"
  python3 - "http://$TARGET_IPV4/sdoc-server/" <<'PYSDOC'
from urllib.request import build_opener,ProxyHandler
from urllib.error import HTTPError
import sys
opener=build_opener(ProxyHandler({}))
try:
    with opener.open(sys.argv[1],timeout=15) as r:
        body=r.read(1024*1024).decode("utf-8","replace")
except HTTPError as e:
    raise SystemExit(f"SeaDoc HTTP {e.code}")
if "Welcome to sdoc-server" not in body:
    raise SystemExit("SeaDoc 返回内容未包含官方欢迎文本")
print("SeaDoc welcome endpoint: PASS")
PYSDOC
  grep -Fq "http://$TARGET_IPV4:$ONLYOFFICE_PORT/" /opt/seafile-data/seafile/conf/seahub_settings.py \
    || die "Seahub ONLYOFFICE_APIJS_URL 与目标 IP/端口不一致"
  [[ "$(cat /opt/seafile-data/seafile/seafile-data/current_version 2>/dev/null || true)" == "13.0.28" ]] \
    || die "Seafile 数据版本不是预期的 13.0.28"

  local fonts
  fonts="$(find /opt/onlyoffice-fonts -type f | wc -l)"
  ((fonts>0)) || die "字体目录为空"
  echo "字体文件数量：$fonts"
  docker inspect seafile-onlyoffice --format '{{range .Mounts}}{{if eq .Destination "/usr/share/fonts/truetype/custom"}}{{println .Source .Destination .RW}}{{end}}{{end}}' \
    | grep -q '/opt/onlyoffice-fonts /usr/share/fonts/truetype/custom false' \
    || die "ONLYOFFICE 字体目录未按预期只读挂载"
  docker inspect seafile --format '{{range .Mounts}}{{if eq .Destination "/opt/seafile/seafile-server-13.0.28/seahub/seahub/onlyoffice/utils.py"}}{{println .Source .Destination .RW}}{{end}}{{end}}' \
    | grep -q '/opt/seafile/patches/onlyoffice/utils.py' \
    || die "ONLYOFFICE 内部通信补丁未正确挂载"
  echo
  echo "自动检查通过。请人工验证：浏览器打开 DOCX、单人保存回写、双用户实时协作及最终保存。"
}


upgrade_get_mount(){
  local container="$1" destination="$2" field="$3"
  case "$field" in
    source) docker inspect "$container" --format "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Source}}{{end}}{{end}}" ;;
    name)   docker inspect "$container" --format "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Name}}{{end}}{{end}}" ;;
    type)   docker inspect "$container" --format "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{.Type}}{{end}}{{end}}" ;;
    *) die "内部错误：未知 mount 字段 $field" ;;
  esac
}

upgrade_read_env(){
  python3 - "$1" "$2" <<'PYENV'
from pathlib import Path
import sys
key=sys.argv[2]
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line=raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k,v=line.split("=",1)
    if k.strip()==key:
        v=v.strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in ("'",'"'):
            v=v[1:-1]
        print(v)
        break
PYENV
}

upgrade_check_existing(){
  [[ -s /opt/seafile/.env ]] || die "未发现 /opt/seafile/.env，不属于受支持的现有部署"
  for f in seafile-server.yml caddy.yml onlyoffice.yml; do
    [[ -s "/opt/seafile/$f" ]] || die "现有部署缺少 /opt/seafile/$f"
  done

  local c
  for c in seafile seafile-mysql seafile-redis seafile-caddy seafile-onlyoffice; do
    docker inspect "$c" >/dev/null 2>&1 || die "缺少现有容器：$c"
    [[ "$(docker inspect "$c" --format '{{.State.Status}}')" == "running" ]] \
      || die "现有容器 $c 未运行；升级模式要求先确认现有服务状态"
  done
  if docker inspect seadoc >/dev/null 2>&1; then
    die "检测到已有 seadoc 容器；当前升级入口仅处理尚未启用 SeaDoc 的现有部署"
  fi

  # Strictly constrain in-place upgrade to the exact software images already validated
  # by this migration package. This is not a cross-version Seafile upgrade.
  local -A expected_ids=(
    [seafile]=sha256:b0c90832126bf432db908449f1bb450211e6bbf75a2193bab3399e2a9636eccf
    [seafile-mysql]=sha256:0d0945c57f75b3a3b9ebe71aedaaad005fa5305054e8fca3d2e42a8c92b43b5e
    [seafile-redis]=sha256:97ec88159e6d7cfb5ddef9015386087d58a912de80112f06ebdfa78fa5989901
    [seafile-caddy]=sha256:c0a1707abe5814ed682c43a1182ded7fe3975405b47462c9df48a9f4e3a525d7
    [seafile-onlyoffice]=sha256:423328ee377374c48a30c2aa416e4afedf621faff068f97966cb9b87a28550bd
  )
  for c in "${!expected_ids[@]}"; do
    local actual
    actual="$(docker inspect "$c" --format '{{.Image}}')"
    [[ "$actual" == "${expected_ids[$c]}" ]] \
      || die "容器 $c 的镜像 ID 不属于本迁移包验证过的版本；拒绝自动升级"
  done

  local services
  services="$(cd /opt/seafile && docker compose config --services)" \
    || die "无法解析当前 /opt/seafile Compose 项目"
  for c in db redis seafile caddy onlyoffice; do
    grep -Fxq "$c" <<<"$services" || die "当前 Compose 项目缺少服务 $c"
  done
  [[ "$(grep -c . <<<"$services")" -eq 5 ]] || die "当前 Compose 项目包含额外服务；为避免遗漏其数据和停机顺序，拒绝自动升级"

  [[ "$(docker exec seafile printenv ENABLE_SEADOC 2>/dev/null || true)" != "true" ]]     || die "当前 Seafile 容器已启用 SeaDoc；请使用检查模式，不要重复升级"

  local seafile_service_url seadoc_db_name
  seafile_service_url="$(upgrade_read_env /opt/seafile/.env SEAFILE_SERVICE_URL)"
  [[ -z "$seafile_service_url" || "$seafile_service_url" == "http://seafile" ]]     || die "现有 SEAFILE_SERVICE_URL 不是 Docker 内部地址 http://seafile"
  seadoc_db_name="$(upgrade_read_env /opt/seafile/.env SEADOC_MYSQL_DB_NAME)"
  [[ -z "$seadoc_db_name" || "$seadoc_db_name" == "seahub_db" ]]     || die "现有 SEADOC_MYSQL_DB_NAME 不是受支持的 seahub_db"

  local sf_shared db_data oo_logs oo_data oo_lib oo_fonts caddy_data patch_source
  sf_shared="$(upgrade_get_mount seafile /shared source)"
  db_data="$(upgrade_get_mount seafile-mysql /var/lib/mysql source)"
  oo_logs="$(upgrade_get_mount seafile-onlyoffice /var/log/onlyoffice source)"
  oo_data="$(upgrade_get_mount seafile-onlyoffice /var/www/onlyoffice/Data source)"
  oo_lib="$(upgrade_get_mount seafile-onlyoffice /var/lib/onlyoffice source)"
  oo_fonts="$(upgrade_get_mount seafile-onlyoffice /usr/share/fonts/truetype/custom source)"
  caddy_data="$(upgrade_get_mount seafile-caddy /data/caddy source)"
  patch_source="$(upgrade_get_mount seafile /opt/seafile/seafile-server-13.0.28/seahub/seahub/onlyoffice/utils.py source)"

  [[ "$sf_shared" == "/opt/seafile-data" ]] || die "现有 Seafile /shared 挂载不是 /opt/seafile-data；不支持自动改写自定义数据路径"
  [[ "$db_data" == "/opt/seafile-mysql/db" ]] || die "现有 MariaDB 数据目录不是 /opt/seafile-mysql/db"
  [[ "$oo_logs" == "/opt/onlyoffice/logs" && "$oo_data" == "/opt/onlyoffice/data" && "$oo_lib" == "/opt/onlyoffice/lib" ]] \
    || die "现有 ONLYOFFICE bind mount 与已验证路径不一致"
  [[ "$oo_fonts" == "/opt/onlyoffice-fonts" ]] || die "ONLYOFFICE 字体目录不是 /opt/onlyoffice-fonts"
  [[ "$caddy_data" == "/opt/seafile-caddy" ]] || die "Caddy 数据目录不是 /opt/seafile-caddy"
  [[ "$patch_source" == "/opt/seafile/patches/onlyoffice/utils.py" ]] || die "现有 Seafile 未挂载本迁移包要求的 ONLYOFFICE 补丁"

  local current_compose_json
  current_compose_json="$(mktemp)"
  if ! (cd /opt/seafile && docker compose config --format json > "$current_compose_json"); then
    rm -f "$current_compose_json"
    die "无法解析现有 Compose 的实际挂载路径"
  fi
  if ! python3 - "$current_compose_json" <<'PYUPGRADE'
import json,sys
cfg=json.load(open(sys.argv[1],encoding="utf-8"))
def src(service,target):
    for v in cfg["services"][service].get("volumes",[]):
        if v.get("target")==target:
            return v.get("source")
    return None
expected={
 ("seafile","/shared"):"/opt/seafile-data",
 ("db","/var/lib/mysql"):"/opt/seafile-mysql/db",
 ("onlyoffice","/var/log/onlyoffice"):"/opt/onlyoffice/logs",
 ("onlyoffice","/var/www/onlyoffice/Data"):"/opt/onlyoffice/data",
 ("onlyoffice","/var/lib/onlyoffice"):"/opt/onlyoffice/lib",
 ("onlyoffice","/usr/share/fonts/truetype/custom"):"/opt/onlyoffice-fonts",
 ("caddy","/data/caddy"):"/opt/seafile-caddy",
}
for (service,target),want in expected.items():
    got=src(service,target)
    if got!=want:
        raise SystemExit(f"{service}:{target} source={got!r}, expected={want!r}")
print("Existing Compose bind paths: PASS")
PYUPGRADE
  then
    rm -f "$current_compose_json"
    die "现有 Compose 配置路径与运行中容器挂载不一致"
  fi
  rm -f "$current_compose_json"

  [[ "$(cat "$sf_shared/seafile/seafile-data/current_version" 2>/dev/null || true)" == "13.0.28" ]] \
    || die "当前 Seafile 数据版本不是 13.0.28；本升级模式不执行跨 Seafile 版本升级"
  [[ "$(upgrade_read_env /opt/seafile/.env SEAFILE_MYSQL_DB_CCNET_DB_NAME)" =~ ^(ccnet_db)?$ ]] \
    || die "当前 ccnet 数据库名称不是本升级模式支持的 ccnet_db"
  [[ "$(upgrade_read_env /opt/seafile/.env SEAFILE_MYSQL_DB_SEAFILE_DB_NAME)" =~ ^(seafile_db)?$ ]] \
    || die "当前 seafile 数据库名称不是本升级模式支持的 seafile_db"
  [[ "$(upgrade_read_env /opt/seafile/.env SEAFILE_MYSQL_DB_SEAHUB_DB_NAME)" =~ ^(seahub_db)?$ ]] \
    || die "当前 seahub 数据库名称不是本升级模式支持的 seahub_db"

  [[ "$(sha256sum "$patch_source" | awk '{print $1}')" == "900ba73c637ef3271770fb6fd22ee7b90644d293706457fed59a30c61b83a926" ]] \
    || die "现有 ONLYOFFICE 补丁版本与本迁移包不一致"

  local vol_info
  vol_info="$(upgrade_get_mount seafile-onlyoffice /var/lib/postgresql type)|$(upgrade_get_mount seafile-onlyoffice /var/lib/postgresql name)"
  [[ "$vol_info" == "volume|"* && "${vol_info#volume|}" != "" ]] || die "无法识别 ONLYOFFICE PostgreSQL 数据卷"
  ONLYOFFICE_PG_VOLUME="${vol_info#volume|}"

  vol_info="$(upgrade_get_mount seafile-onlyoffice /var/lib/rabbitmq type)|$(upgrade_get_mount seafile-onlyoffice /var/lib/rabbitmq name)"
  [[ "$vol_info" == "volume|"* && "${vol_info#volume|}" != "" ]] || die "无法识别 ONLYOFFICE RabbitMQ 数据卷"
  ONLYOFFICE_RABBIT_VOLUME="${vol_info#volume|}"

  vol_info="$(upgrade_get_mount seafile-onlyoffice /var/lib/redis type)|$(upgrade_get_mount seafile-onlyoffice /var/lib/redis name)"
  [[ "$vol_info" == "volume|"* && "${vol_info#volume|}" != "" ]] || die "无法识别 ONLYOFFICE Redis 数据卷"
  ONLYOFFICE_REDIS_VOLUME="${vol_info#volume|}"

  local node rabbit_host rabbit_hostname
  node="$(docker exec seafile-onlyoffice bash -lc 'rabbitmqctl -q eval "node()."' | tr -d '\r"')"
  [[ "$node" == rabbit@* ]] || die "无法读取现有 RabbitMQ 节点身份"
  rabbit_host="${node#rabbit@}"
  rabbit_hostname="$(docker inspect seafile-onlyoffice --format '{{.Config.Hostname}}')"
  [[ "$rabbit_hostname" == "$rabbit_host" ]] \
    || die "现有 RabbitMQ node name 与容器 hostname 不一致；拒绝更改节点身份"
  RABBITMQ_HOSTNAME="$rabbit_host"
  DISCOVERED_RABBITMQ_HOSTNAME="$rabbit_host"
  DISCOVERED_PG_VOLUME="$ONLYOFFICE_PG_VOLUME"
  DISCOVERED_RABBIT_VOLUME="$ONLYOFFICE_RABBIT_VOLUME"
  DISCOVERED_REDIS_VOLUME="$ONLYOFFICE_REDIS_VOLUME"

  CURRENT_TARGET_IP="$(upgrade_read_env /opt/seafile/.env SEAFILE_SERVER_HOSTNAME)"
  CURRENT_ONLYOFFICE_PORT="$(upgrade_read_env /opt/seafile/.env ONLYOFFICE_PORT)"
  CURRENT_TIME_ZONE="$(upgrade_read_env /opt/seafile/.env TIME_ZONE)"
  [[ -n "$CURRENT_ONLYOFFICE_PORT" ]] || CURRENT_ONLYOFFICE_PORT=6233
  [[ -n "$CURRENT_TIME_ZONE" ]] || CURRENT_TIME_ZONE=Etc/UTC

  [[ ! -L /opt/seadoc-data ]] || die "/opt/seadoc-data 是符号链接；请先人工检查"
  [[ ! -e /opt/seadoc-data ]] || {
    [[ -d /opt/seadoc-data && -z "$(find /opt/seadoc-data -mindepth 1 -print -quit)" ]] \
      || die "/opt/seadoc-data 已存在且非空；为保护已有 SeaDoc 数据，停止升级"
  }

  info "现有部署识别通过：Seafile 13.0.28"
  info "RabbitMQ 节点：$node"
  info "ONLYOFFICE 原始卷：PostgreSQL=$ONLYOFFICE_PG_VOLUME RabbitMQ=$ONLYOFFICE_RABBIT_VOLUME Redis=$ONLYOFFICE_REDIS_VOLUME"
}

upgrade_make_backup(){
  local default_backup="/opt/seafile-upgrade-backups/$(date +%Y%m%d-%H%M%S)"
  local backup parent required=0 available=0 size p mp canonical
  read -r -p "升级前完整备份目录 [$default_backup]：" backup
  backup="${backup:-$default_backup}"
  [[ "$backup" == /* ]] || die "备份目录必须使用绝对路径"
  parent="$(dirname "$backup")"
  backup="$(realpath -m "$backup")"
  [[ ! -e "$backup" ]] || die "备份目录已存在，拒绝覆盖"

  local -a sources=(
    /opt/seafile
    /opt/seafile-data
    /opt/seafile-mysql/db
    /opt/onlyoffice
    /opt/onlyoffice-fonts
    /opt/seafile-caddy
  )
  if [[ -d /opt/seafile-recovery ]]; then sources+=(/opt/seafile-recovery); fi
  for v in "$ONLYOFFICE_PG_VOLUME" "$ONLYOFFICE_RABBIT_VOLUME" "$ONLYOFFICE_REDIS_VOLUME"; do
    mp="$(docker volume inspect "$v" --format '{{.Mountpoint}}')"
    [[ -d "$mp" ]] || die "Docker 卷挂载目录不存在：$v"
    sources+=("$mp")
  done

  for p in "${sources[@]}"; do
    [[ -d "$p" ]] || die "升级备份源目录不存在：$p"
    canonical="$(realpath -m "$p")"
    case "$backup/" in "$canonical/"*) die "备份目录不能位于待备份数据目录内部：$canonical" ;; esac
    size="$(du -sb "$p" | awk '{print $1}')"
    required=$((required + size))
  done
  mkdir -p "$parent"
  required=$((required + required / 10 + 1073741824))
  available="$(df -PB1 "$parent" | awk 'NR==2 {print $4}')"
  (( available >= required )) || die "备份目标空间不足：需要约 $((required/1024/1024/1024)) GiB，可用 $((available/1024/1024/1024)) GiB"

  mkdir -p "$backup"
  chmod 700 "$backup"
  UPGRADE_BACKUP_DIR="$backup"
  printf '%s\n' "$backup" > "$STATE/upgrade-backup-path"
  chmod 600 "$STATE/upgrade-backup-path"

  info "停止现有服务，准备一致性冷备份"
  docker stop -t 120 seafile-onlyoffice seafile seafile-redis seafile-mysql seafile-caddy >/dev/null

  tar --numeric-owner --acls --xattrs -cpf "$backup/seafile-config.tar" -C /opt seafile
  tar --numeric-owner --acls --xattrs -cpf "$backup/seafile-data.tar" -C /opt/seafile-data .
  tar --numeric-owner --acls --xattrs -cpf "$backup/mariadb-data.tar" -C /opt/seafile-mysql/db .
  tar --numeric-owner --acls --xattrs -cpf "$backup/onlyoffice-bind-data.tar" -C /opt onlyoffice
  tar --numeric-owner --acls --xattrs -cpf "$backup/onlyoffice-fonts.tar" -C /opt onlyoffice-fonts
  tar --numeric-owner --acls --xattrs -cpf "$backup/caddy-data.tar" -C /opt/seafile-caddy .
  if [[ -d /opt/seafile-recovery ]]; then
    tar --numeric-owner --acls --xattrs -cpf "$backup/seafile-recovery.tar" -C /opt seafile-recovery
  fi

  mp="$(docker volume inspect "$ONLYOFFICE_PG_VOLUME" --format '{{.Mountpoint}}')"
  tar --numeric-owner --acls --xattrs -cpf "$backup/onlyoffice-postgresql-volume.tar" -C "$mp" .
  mp="$(docker volume inspect "$ONLYOFFICE_RABBIT_VOLUME" --format '{{.Mountpoint}}')"
  tar --numeric-owner --acls --xattrs -cpf "$backup/onlyoffice-rabbitmq-volume.tar" -C "$mp" .
  mp="$(docker volume inspect "$ONLYOFFICE_REDIS_VOLUME" --format '{{.Mountpoint}}')"
  tar --numeric-owner --acls --xattrs -cpf "$backup/onlyoffice-redis-volume.tar" -C "$mp" .

  docker inspect seafile seafile-mysql seafile-redis seafile-caddy seafile-onlyoffice \
    > "$backup/containers-inspect.json"
  docker volume inspect "$ONLYOFFICE_PG_VOLUME" "$ONLYOFFICE_RABBIT_VOLUME" "$ONLYOFFICE_REDIS_VOLUME" \
    > "$backup/onlyoffice-volumes-inspect.json"
  {
    printf 'SEAFILE_VERSION=13.0.28\n'
    printf 'RABBITMQ_HOSTNAME=%s\n' "$RABBITMQ_HOSTNAME"
    printf 'ONLYOFFICE_PG_VOLUME=%s\n' "$ONLYOFFICE_PG_VOLUME"
    printf 'ONLYOFFICE_RABBIT_VOLUME=%s\n' "$ONLYOFFICE_RABBIT_VOLUME"
    printf 'ONLYOFFICE_REDIS_VOLUME=%s\n' "$ONLYOFFICE_REDIS_VOLUME"
  } > "$backup/upgrade-manifest.env"
  chmod 600 "$backup"/*
  (cd "$backup" && sha256sum *.tar *.json *.env > SHA256SUMS)
  (cd "$backup" && sha256sum -c SHA256SUMS) || die "升级前备份校验失败"
  info "升级前一致性备份完成：$backup"
}

upgrade_exit_handler(){
  if [[ "$UPGRADE_ACTIVE" == "1" ]]; then
    echo
    echo "[ERROR] 保留数据升级未正常完成。"
    echo "升级前备份位于：${UPGRADE_BACKUP_DIR:-$(cat "$STATE/upgrade-backup-path" 2>/dev/null || echo unknown)}"
    if [[ "$UPGRADE_CONFIG_APPLIED" != "1" ]]; then
      echo "新配置尚未应用，尝试启动原有容器。"
      (cd /opt/seafile && docker compose start) || true
    else
      echo "新配置已经应用，不自动覆盖数据库或配置。请保留现场及备份，先检查日志。"
      echo "不要执行 docker compose down -v 或 docker volume prune。"
    fi
  fi
}

upgrade_existing(){
  [[ ! -f "$STATE/installation-complete.done" ]] || die "检测到本安装器已完成全新恢复；不能再运行原地升级模式"
  [[ ! -f "$STATE/upgrade-complete.done" ]] || die "保留数据升级已经完成；请使用检查功能"
  SETTINGS_FILE="$STATE/upgrade-target-settings.env"
  PACKAGE_ID_FILE="$STATE/upgrade-package-id"
  ALLOW_EXISTING_PORTS=1
  preflight
  verify_bundle
  upgrade_check_existing

  configure

  # Re-load the confirmed values, including existing RabbitMQ node/volume identities.
  # shellcheck disable=SC1090
  source "$SETTINGS_FILE"
  [[ "$RABBITMQ_HOSTNAME" == "$DISCOVERED_RABBITMQ_HOSTNAME" ]] || die "保存的 RabbitMQ 节点身份与当前容器不一致"
  [[ "$ONLYOFFICE_PG_VOLUME" == "$DISCOVERED_PG_VOLUME" ]] || die "保存的 PostgreSQL 卷与当前容器不一致"
  [[ "$ONLYOFFICE_RABBIT_VOLUME" == "$DISCOVERED_RABBIT_VOLUME" ]] || die "保存的 RabbitMQ 卷与当前容器不一致"
  [[ "$ONLYOFFICE_REDIS_VOLUME" == "$DISCOVERED_REDIS_VOLUME" ]] || die "保存的 Redis 卷与当前容器不一致"
  load_seadoc_image_only

  echo
  echo "升级将保留现有 Seafile、MariaDB、ONLYOFFICE、Caddy 数据目录和三个原 Docker 数据卷。"
  echo "不会解压迁移包中的旧 MariaDB/Seafile/ONLYOFFICE 数据 TAR。"
  echo "升级前将先停止服务并创建独立冷备份。"
  read -r -p "确认执行保留数据升级？[y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "用户取消升级"

  UPGRADE_ACTIVE=1
  trap 'upgrade_exit_handler' EXIT
  upgrade_make_backup

  if [[ -e /opt/seadoc-data ]]; then
    [[ -d /opt/seadoc-data && -z "$(find /opt/seadoc-data -mindepth 1 -print -quit)" ]] \
      || die "/opt/seadoc-data 在备份后变为非空，停止升级"
  fi
  mkdir -p /opt/seadoc-data
  chmod 755 /opt/seadoc-data

  UPGRADE_CONFIG_APPLIED=1
  apply_config
  start_services
  verify

  mark upgrade-complete
  UPGRADE_ACTIVE=0
  trap - EXIT

  echo
  echo "=========================================="
  echo "保留数据升级完成（Seafile 13.0.28 + SeaDoc）"
  echo "Seafile：    http://$TARGET_IPV4"
  echo "ONLYOFFICE： http://$TARGET_IPV4:$ONLYOFFICE_PORT"
  echo "SeaDoc：     http://$TARGET_IPV4/sdoc-server/"
  echo "升级前备份： $UPGRADE_BACKUP_DIR"
  echo "=========================================="
}


install_all(){
  SETTINGS_FILE="$STATE/target-settings.env"
  PACKAGE_ID_FILE="$STATE/restore-package-id"
  RABBITMQ_HOSTNAME="05831744982c"
  ONLYOFFICE_PG_VOLUME="seafile-onlyoffice-postgresql"
  ONLYOFFICE_RABBIT_VOLUME="seafile-onlyoffice-rabbitmq"
  ONLYOFFICE_REDIS_VOLUME="seafile-onlyoffice-redis"
  ALLOW_EXISTING_PORTS=0
  [[ ! -f "$STATE/upgrade-complete.done" ]] || die "检测到已完成的保留数据升级；不能再执行首次完整恢复"
  [[ ! -f "$STATE/installation-complete.done" ]] || die "已完成安装；请使用检查菜单，不要重复恢复"
  preflight
  verify_bundle
  configure

  for c in seafile seafile-mysql seafile-redis seafile-caddy seafile-onlyoffice seadoc; do
    if docker inspect "$c" >/dev/null 2>&1; then
      done_stage config-applied || die "发现同名容器 $c，但本迁移尚未应用配置；为保护现有部署而停止"
    fi
  done
  if docker network inspect seafile-net >/dev/null 2>&1; then
    local network_label
    network_label="$(docker network inspect seafile-net --format '{{ index .Labels "com.docker.compose.network" }}' 2>/dev/null || true)"
    [[ "$network_label" == "seafile-net" ]] || die "发现同名 Docker 网络 seafile-net，但它不是本 Compose 项目的网络；拒绝复用"
  fi
  local target marker item
  local -a target_checks=(
    "/opt/seafile:config"
    "/opt/seafile-data:seafile-data"
    "/opt/seafile-mysql/db:mariadb-data"
    "/opt/onlyoffice:onlyoffice-data"
    "/opt/onlyoffice-fonts:fonts"
    "/opt/seafile-caddy:caddy-data"
    "/opt/seadoc-data:seadoc-data"
    "/opt/seafile-recovery:patch-source"
  )
  for item in "${target_checks[@]}"; do
    target="${item%%:*}"
    marker="${item##*:}"
    if done_stage "$marker"; then
      [[ -d "$target" ]] || die "恢复标记存在但目标路径缺失：$target"
    elif [[ -e "$target" ]]; then
      [[ -d "$target" && -z "$(find "$target" -mindepth 1 -print -quit 2>/dev/null)" ]] \
        || die "目标路径已存在且非空，拒绝覆盖：$target"
    fi
  done
  load_images
  restore_config
  restore_dir "$PKG/04-seafile-data/seafile-data.tar" /opt/seafile-data /opt/.seafile-data.restore-staging seafile-data
  restore_dir "$PKG/03-database/mariadb-data.tar" /opt/seafile-mysql/db /opt/seafile-mysql/.db.restore-staging mariadb-data
  restore_dir "$PKG/05-onlyoffice/onlyoffice-data.tar" /opt/onlyoffice /opt/.onlyoffice.restore-staging onlyoffice-data
  restore_wrapped_dir "$PKG/05-onlyoffice/onlyoffice-fonts.tar" /opt/onlyoffice-fonts onlyoffice-fonts /opt/.onlyoffice-fonts.restore-staging fonts
  restore_dir "$PKG/02-config/caddy-data.tar" /opt/seafile-caddy /opt/.seafile-caddy.restore-staging caddy-data
  restore_empty_dir /opt/seadoc-data seadoc-data

  restore_volume seafile-onlyoffice-postgresql postgresql volume-postgresql
  restore_volume seafile-onlyoffice-rabbitmq rabbitmq volume-rabbitmq
  restore_volume seafile-onlyoffice-redis redis volume-redis

  apply_config
  start_services
  verify
  mark installation-complete
  echo
  echo "=========================================="
  echo "Seafile + ONLYOFFICE + SeaDoc 离线恢复部署完成"
  echo "Seafile：    http://$TARGET_IPV4"
  echo "ONLYOFFICE： http://$TARGET_IPV4:$ONLYOFFICE_PORT"
  echo "SeaDoc：     http://$TARGET_IPV4/sdoc-server/"
  echo "日志：       $LOG"
  echo "=========================================="
}

status(){
  if [[ -d /opt/seafile ]]; then (cd /opt/seafile && docker compose ps) || true; else echo "尚未恢复 /opt/seafile"; fi
  echo "最近安装日志："
  local f; f="$(ls -1t "$LOGDIR"/install-*.log 2>/dev/null | head -1 || true)"
  [[ -n "$f" ]] && tail -n 35 "$f" || true
}

while true; do
  echo
  echo "=========================================="
  echo " Seafile + ONLYOFFICE + SeaDoc 离线部署工具 v0.8"
  echo "=========================================="
  echo "1. 首次安装 / 从迁移包完整恢复（目标目录必须为空）"
  echo "2. 保留数据升级（现有 Seafile 13.0.28，增加 SeaDoc）"
  echo "3. 检查当前部署"
  echo "4. 查看服务状态"
  echo "0. 退出"
  read -r -p "请选择 [0-4]：" choice
  case "$choice" in
    1) install_all ;;
    2) upgrade_existing ;;
    3)
      if [[ -f "$STATE/upgrade-target-settings.env" ]]; then
        SETTINGS_FILE="$STATE/upgrade-target-settings.env"
      else
        SETTINGS_FILE="$STATE/target-settings.env"
      fi
      verify
      ;;
    4) status ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
