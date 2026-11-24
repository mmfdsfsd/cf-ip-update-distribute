#!/bin/bash

set -Eeuo pipefail

BASE_DIR="/root/ip-cloudflare-sync"

source "$BASE_DIR/config.conf"

mkdir -p "$DATA_DIR" "$(dirname "$LOG_FILE")"

RAW_FILE="$DATA_DIR/latest.json"
FILTERED_FILE="$DATA_DIR/filtered.json"
TOP_FILE="$DATA_DIR/top2.json"
CURRENT_FILE="$DATA_DIR/current.txt"

LOCK_FILE="/var/run/ip-cloudflare-sync.lock"

# ============================================================
# 日志
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ============================================================
# 配置检查
# ============================================================

for cmd in curl jq flock sort mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "缺少依赖：$cmd"
        exit 1
    }
done

[[ -n "$API_URL" ]] || exit 1
[[ -n "$CF_API_TOKEN" ]] || exit 1
[[ -n "$CF_ZONE_ID" ]] || exit 1
[[ -f "$DOMAIN_FILE" ]] || {
    echo "域名文件不存在：$DOMAIN_FILE"
    exit 1
}

[[ "$MIN_SPEED" =~ ^[0-9]+([.][0-9]+)?$ ]] || exit 1
[[ "$MAX_IPS_PER_DOMAIN" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ "$CF_TTL" =~ ^[0-9]+$ ]] || exit 1

# ============================================================
# 执行锁
# ============================================================

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    log "已有任务运行，跳过本次执行"
    exit 0
fi

trap 'rc=$?; log "执行异常，退出代码：$rc"; exit "$rc"' ERR

# ============================================================
# 读取域名
# ============================================================

load_domains() {

    mapfile -t DOMAINS < <(
        sed 's/\r$//' "$DOMAIN_FILE" |
        sed 's/#.*//' |
        sed 's/^[[:space:]]*//' |
        sed 's/[[:space:]]*$//' |
        grep -v '^$' |
        sort -u
    )

    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        log "域名列表为空，终止任务"
        return 1
    fi

    for domain in "${DOMAINS[@]}"; do
        if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            log "域名格式错误：$domain"
            return 1
        fi
    done

    log "读取到 ${#DOMAINS[@]} 个域名"
}

# ============================================================
# 获取 API 数据
# ============================================================

fetch_api() {

    log "开始请求 Mileet API"

    local tmp
    tmp=$(mktemp "$DATA_DIR/api.XXXXXX")

    if ! curl -fsS \
        --connect-timeout 10 \
        --max-time "$API_TIMEOUT" \
        -H "Accept: application/json" \
        "$API_URL" \
        -o "$tmp"; then

        rm -f "$tmp"
        log "API 请求失败"
        return 1
    fi

    if ! jq -e 'type == "array" and length > 0' \
        "$tmp" >/dev/null; then

        rm -f "$tmp"
        log "API JSON 无效或为空"
        return 1
    fi

    mv "$tmp" "$RAW_FILE"

    log "API 获取成功：$(jq 'length' "$RAW_FILE") 条"
}

# ============================================================
# 筛选 IP
# ============================================================


filter_ips() {

    log "开始筛选 IP：速度大于 ${MIN_SPEED} Mbps，端口必须为 8443"

    local tmp
    tmp=$(mktemp "$DATA_DIR/filter.XXXXXX")

    jq \
        --argjson min_speed "$MIN_SPEED" '
        def valid_ipv4:
            if type != "string" then false
            elif (split(".") | length) != 4 then false
            else
                split(".") |
                all(.[];
                    test("^[0-9]{1,3}$")
                    and (tonumber <= 255)
                )
            end;

        [
            .[]
            | select(type == "object")
            | select(.ip | valid_ipv4)

            # 端口必须是 8443
            | select((.port | type) == "number")
            | select(.port == 8443)

            # 速度必须严格大于设定值
            | select((.speed_mbps | type) == "number")
            | select(.speed_mbps > $min_speed)

            | {
                ip: .ip,
                port: .port,
                speed_mbps: .speed_mbps,
                country: (.country // ""),
                city: (.city // ""),
                colo: (.colo // ""),
                score: (.score // 0)
            }
        ]
        | sort_by(-.speed_mbps)
        | group_by(.ip)
        | map(max_by(.speed_mbps))
        | sort_by(-.speed_mbps)
        ' "$RAW_FILE" > "$tmp"

    mv "$tmp" "$FILTERED_FILE"

    local count
    count=$(jq 'length' "$FILTERED_FILE")

    log "符合条件的独立 IP 数量：$count"

    # 一个合格 IP 都没有，则不修改任何域名 DNS
    if (( count == 0 )); then
        log "没有符合条件的 IP，所有域名保留原有 DNS"
        return 1
    fi

    # 最多选择 MAX_IPS_PER_DOMAIN 个，允许实际数量不足
    jq \
        --argjson limit "$MAX_IPS_PER_DOMAIN" \
        '.[:$limit]' \
        "$FILTERED_FILE" > "$TOP_FILE"

    jq -r '.[].ip' "$TOP_FILE" | sort -u > "$CURRENT_FILE"

    local selected_count
    selected_count=$(wc -l < "$CURRENT_FILE")

    log "最终选择 IP 数量：$selected_count"

    jq -r '.[] | "\(.ip):\(.port) - \(.speed_mbps) Mbps"' \
        "$TOP_FILE" |
        while IFS= read -r line; do
            log "$line"
        done

    if (( selected_count == 0 )); then
        log "最终 IP 数量异常，停止 DNS 同步"
        return 1
    fi
}


# ============================================================
# Cloudflare API
# ============================================================

cf_request() {

    local method="$1"
    local url="$2"
    local body="${3:-}"

    local args=(
        -sS
        --connect-timeout 10
        --max-time 30
        -X "$method"
        -H "Authorization: Bearer $CF_API_TOKEN"
        -H "Content-Type: application/json"
    )

    if [[ -n "$body" ]]; then
        args+=(-d "$body")
    fi

    curl "${args[@]}" "$url"
}

# ============================================================
# 查询指定域名 DNS
# ============================================================

get_dns_records() {

    local domain="$1"

    cf_request GET \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${domain}&per_page=500"
}

# ============================================================
# 同步单个域名
# ============================================================

sync_domain() {

    local domain="$1"

    log "----------------------------------------"
    log "开始同步域名：$domain"

    local dns_json

    if ! dns_json=$(get_dns_records "$domain"); then
        log "DNS 查询请求失败：$domain"
        return 1
    fi

    if ! jq -e '
        .success == true
        and (.result | type == "array")
        and (.result_info.total_pages // 1) <= 1
    ' <<< "$dns_json" >/dev/null; then

        log "DNS 查询结果无效：$domain"
        return 1
    fi

    local existing_ips

    existing_ips=$(jq -r '.result[].content' <<< "$dns_json" | sort -u)

    # --------------------------------------------------------
    # 第一步：添加缺失 IP
    # --------------------------------------------------------

    while IFS= read -r new_ip; do

        [[ -z "$new_ip" ]] && continue

        if grep -Fxq "$new_ip" <<< "$existing_ips"; then
            log "IP 已存在：$new_ip"
            continue
        fi

        log "添加 IP：$new_ip"

        local payload

        payload=$(jq -n \
            --arg name "$domain" \
            --arg ip "$new_ip" \
            --argjson ttl "$CF_TTL" \
            --argjson proxied "$CF_PROXIED" \
            '{
                type: "A",
                name: $name,
                content: $ip,
                ttl: $ttl,
                proxied: $proxied
            }')

        local response

        if ! response=$(cf_request POST \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            "$payload"); then

            log "新增请求失败：$new_ip"
            return 1
        fi

        if ! jq -e '.success == true' <<< "$response" >/dev/null; then
            log "新增失败：$new_ip"
            log "$response"
            return 1
        fi

        log "新增成功：$new_ip"

    done < "$CURRENT_FILE"

    # --------------------------------------------------------
    # 第二步：重新查询 DNS
    # --------------------------------------------------------

    if ! dns_json=$(get_dns_records "$domain"); then
        log "新增后 DNS 验证查询失败，停止删除"
        return 1
    fi

    if ! jq -e '
        .success == true
        and (.result | type == "array")
        and (.result_info.total_pages // 1) <= 1
    ' <<< "$dns_json" >/dev/null; then
        log "新增后 DNS 验证失败，停止删除"
        return 1
    fi

    # 确保两个目标 IP 均存在
    while IFS= read -r target_ip; do

        if ! jq -e --arg ip "$target_ip" \
            '.result | any(.content == $ip)' \
            <<< "$dns_json" >/dev/null; then

            log "目标 IP 未确认存在：$target_ip"
            log "停止删除旧记录"
            return 1
        fi

    done < "$CURRENT_FILE"

    # --------------------------------------------------------
    # 第三步：删除不在 TOP 2 中的旧 IP
    # --------------------------------------------------------

    while IFS= read -r old_record; do

        local record_id old_ip

        record_id=$(jq -r '.id' <<< "$old_record")
        old_ip=$(jq -r '.content' <<< "$old_record")

        if grep -Fxq "$old_ip" "$CURRENT_FILE"; then
            continue
        fi

        log "删除旧 IP：$old_ip"

        local response

        if ! response=$(cf_request DELETE \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}"); then

            log "删除请求失败：$old_ip"
            return 1
        fi

        if ! jq -e '.success == true' <<< "$response" >/dev/null; then
            log "删除失败：$old_ip"
            return 1
        fi

        log "删除成功：$old_ip"

    done < <(jq -c '.result[]' <<< "$dns_json")

    log "域名同步完成：$domain"
}

# ============================================================
# 主程序
# ============================================================

main() {

    log "========================================"
    log "开始执行 Cloudflare 多域名 IP 同步"

    load_domains || return 1

    fetch_api || return 1

    filter_ips || return 1

    local success=0
    local failed=0

    for domain in "${DOMAINS[@]}"; do

        if sync_domain "$domain"; then
            ((success += 1))
        else
            ((failed += 1))
            log "域名同步失败：$domain"
        fi

    done

    log "========================================"
    log "任务执行结束"
    log "成功域名：$success"
    log "失败域名：$failed"
    log "========================================"

    (( failed == 0 ))
}

main "$@"
