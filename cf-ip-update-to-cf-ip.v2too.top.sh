#!/bin/bash

# ==========================================================
# Cloudflare 优选 IP 自动分配工具
#
# 文件：
#   /usr/local/bin/cf-ip-update-distribute.sh
#
# 配置目录：
#   /root/cf-ip-update/
#
# 域名配置：
#   /root/cf-ip-update/domains.conf
#
# 日志：
#   /root/cf-ip-update/cf-ip-update-distribute.log
#
# 手动运行：
#   /usr/local/bin/cf-ip-update-distribute.sh
#
# Cron：
#   /usr/local/bin/cf-ip-update-distribute.sh --cron
#
# ==========================================================

set -u
set -o pipefail


# ==========================================================
# Cloudflare 配置
# ==========================================================

CF_API_TOKEN="my-token"

ZONE_ID="my-id"

TTL=60

# false = DNS Only
# true  = Cloudflare Proxy
PROXIED=false


# ==========================================================
# 优选 IP API
# ==========================================================

IP_API="https://ip.v2too.top/api/nodes"


# ==========================================================
# IP 优选策略
#
# 综合评分：
#
# speed   = 50%
# latency = 30%
# region  = 15%
# carrier = 5%
#
# speed：
#   越高越好
#
# latency：
#   越低越好
#
# region：
#   PREFERRED_REGIONS 中的地区优先
#
# carrier：
#   PREFERRED_CARRIER 优先
# ==========================================================

SPEED_WEIGHT=50
LATENCY_WEIGHT=30
REGION_WEIGHT=15
CARRIER_WEIGHT=5

# 优先地区
PREFERRED_REGIONS=("SIN" "NRT")

# 优先运营商
PREFERRED_CARRIER="ct"


# ==========================================================
# 默认配置
# 每个域名分配3个IP
# ==========================================================

DEFAULT_MAX_IPS=3

# API IP 最低速度要求
# 速度低于此值的 IP 将直接剔除
MIN_SPEED=10

# ==========================================================
# 文件
# ==========================================================

CONFIG_DIR="/root/cf-ip-update"

DOMAIN_CONFIG="$CONFIG_DIR/domains.conf"

LOG_FILE="/root/cf-ip-update/cf-ip-update-distribute.log"

LOCK_FILE="/root/cf-ip-update/cf-ip-update-distribute.lock"


# ==========================================================
# 运行模式
# ==========================================================

MODE="interactive"

if [ "${1:-}" = "--cron" ]; then
    MODE="cron"
fi


# ==========================================================
# 创建目录
# ==========================================================

mkdir -p "$CONFIG_DIR" 2>/dev/null || true


# ==========================================================
# 日志
# ==========================================================

log() {

    local LEVEL="$1"

    shift

    local MESSAGE="$*"

    local NOW

    NOW=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$NOW] [$LEVEL] $MESSAGE"

    echo "[$NOW] [$LEVEL] $MESSAGE" >> "$LOG_FILE" 2>/dev/null || true

}


# ==========================================================
# 分隔线
# ==========================================================

separator() {

    echo "=========================================================="

}


# ==========================================================
# 检查依赖
# ==========================================================

check_dependencies() {

    local MISSING=()

    command -v curl >/dev/null 2>&1 || MISSING+=("curl")

    command -v jq >/dev/null 2>&1 || MISSING+=("jq")

    command -v awk >/dev/null 2>&1 || MISSING+=("awk")

    command -v grep >/dev/null 2>&1 || MISSING+=("grep")

    command -v sed >/dev/null 2>&1 || MISSING+=("sed")

    command -v sort >/dev/null 2>&1 || MISSING+=("sort")

    command -v flock >/dev/null 2>&1 || MISSING+=("flock")

    command -v bc >/dev/null 2>&1 || MISSING+=("bc")


    if [ "${#MISSING[@]}" -gt 0 ]; then

        echo

        echo "[ERROR] 缺少依赖：${MISSING[*]}"

        echo

        echo "Debian / Ubuntu："

        echo

        echo "apt update && apt install -y curl jq gawk grep sed coreutils util-linux bc"

        echo

        exit 1

    fi

}


# ==========================================================
# 检查 Cloudflare 配置
# ==========================================================

check_config() {

    if [ -z "$CF_API_TOKEN" ] ||
       [ "$CF_API_TOKEN" = "请填写你的Cloudflare_API_Token" ]; then

        log ERROR "CF_API_TOKEN 未配置"

        exit 1

    fi


    if [ -z "$ZONE_ID" ] ||
       [ "$ZONE_ID" = "请填写你的Zone_ID" ]; then

        log ERROR "ZONE_ID 未配置"

        exit 1

    fi

}


# ==========================================================
# 创建域名配置文件
# ==========================================================

init_domain_config() {

    if [ ! -f "$DOMAIN_CONFIG" ]; then

        touch "$DOMAIN_CONFIG"

        chmod 600 "$DOMAIN_CONFIG"

        log INFO "创建域名配置文件：$DOMAIN_CONFIG"

    fi

}


# ==========================================================
# 验证域名
# ==========================================================

validate_domain() {

    local DOMAIN="$1"

    DOMAIN=$(echo "$DOMAIN" | xargs)

    if [ -z "$DOMAIN" ]; then
        return 1
    fi

    if [[ "$DOMAIN" == http://* ]] ||
       [[ "$DOMAIN" == https://* ]]; then

        return 1

    fi

    if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then

        return 1

    fi

    return 0

}


# ==========================================================
# 加载域名配置
#
# 格式：
#
# domain|ip数量
#
# ==========================================================

load_domains() {

    DOMAINS=()

    DOMAIN_IP_COUNTS=()


    if [ ! -f "$DOMAIN_CONFIG" ]; then
        return 0
    fi


    while IFS='|' read -r DOMAIN IP_COUNT; do

        [ -z "$DOMAIN" ] && continue

        [[ "$DOMAIN" =~ ^# ]] && continue


        if ! validate_domain "$DOMAIN"; then

            log ERROR "域名配置无效，跳过：$DOMAIN"

            continue

        fi


        if ! [[ "$IP_COUNT" =~ ^[0-9]+$ ]]; then

            log ERROR "IP 数量无效，跳过：$DOMAIN|$IP_COUNT"

            continue

        fi


        if [ "$IP_COUNT" -lt 1 ]; then

            log ERROR "IP 数量必须大于 0，跳过：$DOMAIN"

            continue

        fi


        DOMAINS+=("$DOMAIN")

        DOMAIN_IP_COUNTS+=("$IP_COUNT")


    done < "$DOMAIN_CONFIG"

}


# ==========================================================
# 保存全部域名配置
# ==========================================================

save_domains() {

    local TEMP_FILE

    TEMP_FILE="${DOMAIN_CONFIG}.tmp"


    : > "$TEMP_FILE"


    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        echo "${DOMAINS[$i]}|${DOMAIN_IP_COUNTS[$i]}" >> "$TEMP_FILE"

    done


    chmod 600 "$TEMP_FILE"

    mv "$TEMP_FILE" "$DOMAIN_CONFIG"


    log INFO "域名配置已保存：$DOMAIN_CONFIG"

}


# ==========================================================
# 查找域名索引
# ==========================================================

find_domain_index() {

    local SEARCH_DOMAIN="$1"


    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        if [ "${DOMAINS[$i]}" = "$SEARCH_DOMAIN" ]; then

            echo "$i"

            return 0

        fi

    done


    return 1

}


# ==========================================================
# 显示域名
# ==========================================================

show_domains() {

    load_domains

    clear


    separator

    echo " 当前域名列表"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "当前没有配置任何域名。"

        echo

        return

    fi


    printf "%-5s %-45s %-10s\n" "编号" "域名" "IP数量"

    echo "----------------------------------------------------------"


    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        printf "%-5s %-45s %-10s\n" \
            "$((i+1))" \
            "${DOMAINS[$i]}" \
            "${DOMAIN_IP_COUNTS[$i]}"

    done


    echo

}


# ==========================================================
# Cloudflare API 请求
# ==========================================================

cf_api() {

    local METHOD="$1"

    local URL="$2"

    shift 2


    curl -sS \
        --connect-timeout 10 \
        --max-time 30 \
        -X "$METHOD" \
        "$URL" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$@"

}


# ==========================================================
# 检测 Cloudflare API
# ==========================================================

check_cloudflare_api() {

    log INFO "检测 Cloudflare API..."


    local RESPONSE


    RESPONSE=$(
        cf_api \
            GET \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID"
    )


    if [ -z "$RESPONSE" ]; then

        log ERROR "Cloudflare API 无返回"

        return 1

    fi


    if ! echo "$RESPONSE" | jq empty >/dev/null 2>&1; then

        log ERROR "Cloudflare API 返回无效 JSON"

        log ERROR "$RESPONSE"

        return 1

    fi


    local SUCCESS

    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')


    if [ "$SUCCESS" != "true" ]; then

        log ERROR "Cloudflare API 验证失败"


        echo "$RESPONSE" |
            jq -r '.errors[]? | "\(.code): \(.message)"' |
            while read -r ERROR_LINE; do

                log ERROR "$ERROR_LINE"

            done


        return 1

    fi


    local ZONE_NAME

    ZONE_NAME=$(echo "$RESPONSE" |
        jq -r '.result.name // empty')


    log INFO "Cloudflare API 正常"

    [ -n "$ZONE_NAME" ] &&
        log INFO "Zone：$ZONE_NAME"


    return 0

}


# ==========================================================
# 判断地区是否优先
# ==========================================================

is_preferred_region() {

    local REGION="$1"

    local ITEM


    for ITEM in "${PREFERRED_REGIONS[@]}"; do

        if [ "$REGION" = "$ITEM" ]; then

            return 0

        fi

    done


    return 1

}


# ==========================================================
# 获取 API 节点
#
# 这个函数负责：
#
# 1. 请求 API
# 2. 检查 JSON
# 3. 提取：
#      IP
#      speed
#      latency
#      region
#      time
#      carrier
#
# 原始数据保存到：
#
# NODE_IPS
# NODE_SPEEDS
# NODE_LATENCIES
# NODE_REGIONS
# NODE_TIMES
# NODE_CARRIERS
#
# ==========================================================

get_api_nodes() {

    NODE_IPS=()
    NODE_SPEEDS=()
    NODE_LATENCIES=()
    NODE_REGIONS=()
    NODE_TIMES=()
    NODE_CARRIERS=()


    log INFO "请求优选 IP API：$IP_API"


    local RESPONSE


    RESPONSE=$(
        curl -L -sS \
            --connect-timeout 10 \
            --max-time 30 \
            "$IP_API"
    )


    if [ -z "$RESPONSE" ]; then

        log ERROR "优选 IP API 无返回"

        return 1

    fi


    if ! echo "$RESPONSE" | jq empty >/dev/null 2>&1; then

        log ERROR "优选 IP API 返回无效 JSON"

        log ERROR "$RESPONSE"

        return 1

    fi


    if ! echo "$RESPONSE" |
        jq -e 'type == "array"' >/dev/null 2>&1; then

        log ERROR "优选 IP API 返回的数据不是 JSON 数组"

        return 1

    fi


	while IFS=$'\t' read -r IP SPEED LATENCY REGION TIME CARRIER; do
		[[ -z "$IP" ]] && continue

		# 过滤速度低于最低要求的 IP
		if ! awk -v speed="${SPEED:-0}" -v min_speed="$MIN_SPEED" '
			BEGIN {
				if ((speed + 0) < (min_speed + 0)) {
					exit 1
				}
				exit 0
			}
		'; then
			log INFO "过滤低速 IP：$IP speed=${SPEED:-0} < ${MIN_SPEED}"
			continue
		fi

		# 验证 IPv4
		if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
			log WARN "跳过无效 IPv4：$IP"
			continue
		fi

		NODE_IPS+=("$IP")
		NODE_SPEEDS+=("${SPEED:-0}")
		NODE_LATENCIES+=("${LATENCY:-999999}")
		NODE_REGIONS+=("${REGION:-UNKNOWN}")
		NODE_TIMES+=("${TIME:-UNKNOWN}")
		NODE_CARRIERS+=("${CARRIER:-UNKNOWN}")

	done < <(
		echo "$RESPONSE" | jq -r '
			.[] |
			[
				(.ip // ""),
				(.speed // 0),
				(.latency // 999999),
				(.region // "UNKNOWN"),
				(.time // "UNKNOWN"),
				(.carrier // "UNKNOWN")
			] |
			@tsv
		'
	)


    if [ "${#NODE_IPS[@]}" -eq 0 ]; then

        log ERROR "API 中没有获取到有效 IPv4"

        return 1

    fi


    # 去重
    local UNIQUE_IPS=()
    local UNIQUE_SPEEDS=()
    local UNIQUE_LATENCIES=()
    local UNIQUE_REGIONS=()
    local UNIQUE_TIMES=()
    local UNIQUE_CARRIERS=()

    declare -A SEEN_IPS=()


    local i
    local IP


    for ((i=0; i<${#NODE_IPS[@]}; i++)); do

        IP="${NODE_IPS[$i]}"


        if [ -n "${SEEN_IPS[$IP]+x}" ]; then
            continue
        fi


        SEEN_IPS["$IP"]=1


        UNIQUE_IPS+=("$IP")
        UNIQUE_SPEEDS+=("${NODE_SPEEDS[$i]}")
        UNIQUE_LATENCIES+=("${NODE_LATENCIES[$i]}")
        UNIQUE_REGIONS+=("${NODE_REGIONS[$i]}")
        UNIQUE_TIMES+=("${NODE_TIMES[$i]}")
        UNIQUE_CARRIERS+=("${NODE_CARRIERS[$i]}")

    done


    NODE_IPS=("${UNIQUE_IPS[@]}")
    NODE_SPEEDS=("${UNIQUE_SPEEDS[@]}")
    NODE_LATENCIES=("${UNIQUE_LATENCIES[@]}")
    NODE_REGIONS=("${UNIQUE_REGIONS[@]}")
    NODE_TIMES=("${UNIQUE_TIMES[@]}")
    NODE_CARRIERS=("${UNIQUE_CARRIERS[@]}")


    log INFO "API 获取到 ${#NODE_IPS[@]} 个有效节点"


    return 0

}


# ==========================================================
# 计算综合评分
#
# speed：
#   最大值 = 100
#   最小值 = 0
#
# latency：
#   最低延迟 = 100
#   最高延迟 = 0
#
# region：
#   优先地区 = 100
#   其他地区 = 0
#
# carrier：
#   优先运营商 = 100
#   其他运营商 = 0
#
# 综合：
#
# speed_score   * 50%
# latency_score * 30%
# region_score  * 15%
# carrier_score * 5%
#
# ==========================================================

calculate_scores() {

    NODE_SCORES=()

    local COUNT="${#NODE_IPS[@]}"

    if [ "$COUNT" -eq 0 ]; then
        return 1
    fi


    local MIN_SPEED
    local MAX_SPEED
    local MIN_LATENCY
    local MAX_LATENCY


    MIN_SPEED=$(printf '%s\n' "${NODE_SPEEDS[@]}" |
        sort -n |
        head -n1)

    MAX_SPEED=$(printf '%s\n' "${NODE_SPEEDS[@]}" |
        sort -n |
        tail -n1)

    MIN_LATENCY=$(printf '%s\n' "${NODE_LATENCIES[@]}" |
        sort -n |
        head -n1)

    MAX_LATENCY=$(printf '%s\n' "${NODE_LATENCIES[@]}" |
        sort -n |
        tail -n1)


    local i

    for ((i=0; i<COUNT; i++)); do

        local SPEED="${NODE_SPEEDS[$i]}"
        local LATENCY="${NODE_LATENCIES[$i]}"
        local REGION="${NODE_REGIONS[$i]}"
        local CARRIER="${NODE_CARRIERS[$i]}"

        local SPEED_SCORE
        local LATENCY_SCORE
        local REGION_SCORE=0
        local CARRIER_SCORE=0
        local FINAL_SCORE


        # --------------------------------------------------
        # Speed
        # --------------------------------------------------

        if [ "$(echo "$MAX_SPEED == $MIN_SPEED" | bc -l)" -eq 1 ]; then

            SPEED_SCORE=100

        else

            SPEED_SCORE=$(
                echo "scale=4; (($SPEED-$MIN_SPEED)/($MAX_SPEED-$MIN_SPEED))*100" |
                bc -l
            )

        fi


        # --------------------------------------------------
        # Latency
        # --------------------------------------------------

        if [ "$(echo "$MAX_LATENCY == $MIN_LATENCY" | bc -l)" -eq 1 ]; then

            LATENCY_SCORE=100

        else

            LATENCY_SCORE=$(
                echo "scale=4; (($MAX_LATENCY-$LATENCY)/($MAX_LATENCY-$MIN_LATENCY))*100" |
                bc -l
            )

        fi


        # --------------------------------------------------
        # Region
        # --------------------------------------------------

        if is_preferred_region "$REGION"; then

            REGION_SCORE=100

        fi


        # --------------------------------------------------
        # Carrier
        # --------------------------------------------------

        if [ "$CARRIER" = "$PREFERRED_CARRIER" ]; then

            CARRIER_SCORE=100

        fi


        # --------------------------------------------------
        # 综合评分
        # --------------------------------------------------

        FINAL_SCORE=$(
            echo "scale=4; \
                $SPEED_SCORE * $SPEED_WEIGHT / 100 + \
                $LATENCY_SCORE * $LATENCY_WEIGHT / 100 + \
                $REGION_SCORE * $REGION_WEIGHT / 100 + \
                $CARRIER_SCORE * $CARRIER_WEIGHT / 100" |
            bc -l
        )


        NODE_SCORES+=("$FINAL_SCORE")

    done


    return 0

}


# ==========================================================
# 按综合评分排序
#
# 结果保存到：
#
# SORTED_IPS
# SORTED_SPEEDS
# SORTED_LATENCIES
# SORTED_REGIONS
# SORTED_TIMES
# SORTED_CARRIERS
# SORTED_SCORES
#
# ==========================================================

sort_nodes_by_score() {

    calculate_scores || return 1


    local TEMP_FILE

    TEMP_FILE=$(mktemp)


    local i


    for ((i=0; i<${#NODE_IPS[@]}; i++)); do

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${NODE_SCORES[$i]}" \
            "${NODE_IPS[$i]}" \
            "${NODE_SPEEDS[$i]}" \
            "${NODE_LATENCIES[$i]}" \
            "${NODE_REGIONS[$i]}" \
            "${NODE_TIMES[$i]}" \
            "${NODE_CARRIERS[$i]}" \
            >> "$TEMP_FILE"

    done


    SORTED_IPS=()
    SORTED_SPEEDS=()
    SORTED_LATENCIES=()
    SORTED_REGIONS=()
    SORTED_TIMES=()
    SORTED_CARRIERS=()
    SORTED_SCORES=()


    while IFS=$'\t' read -r SCORE IP SPEED LATENCY REGION TIME CARRIER; do

        SORTED_SCORES+=("$SCORE")
        SORTED_IPS+=("$IP")
        SORTED_SPEEDS+=("$SPEED")
        SORTED_LATENCIES+=("$LATENCY")
        SORTED_REGIONS+=("$REGION")
        SORTED_TIMES+=("$TIME")
        SORTED_CARRIERS+=("$CARRIER")

    done < <(
        sort -t $'\t' -k1,1nr "$TEMP_FILE"
    )


    rm -f "$TEMP_FILE"


    return 0

}


# ==========================================================
# 获取优选 IP
#
# 自动 DNS 更新使用这个函数。
#
# 最终：
#
# IPS[0] = 综合评分最高
# IPS[1] = 综合评分第二
# ...
#
# ==========================================================

get_preferred_ips() {

    log INFO "获取优选 IP..."


    if ! get_api_nodes; then
        return 1
    fi


    if ! sort_nodes_by_score; then
        return 1
    fi


    IPS=("${SORTED_IPS[@]}")


    log INFO "综合评分排序完成"

    log INFO "获取到 ${#IPS[@]} 个优选 IP"


    local INDEX=1

    local i


    for ((i=0; i<${#SORTED_IPS[@]}; i++)); do

        log INFO \
            "IP[$INDEX]：${SORTED_IPS[$i]} speed=${SORTED_SPEEDS[$i]} latency=${SORTED_LATENCIES[$i]} region=${SORTED_REGIONS[$i]} carrier=${SORTED_CARRIERS[$i]} score=${SORTED_SCORES[$i]}"

        ((INDEX++))

    done


    return 0

}


# ==========================================================
# 显示 API 当前 Top10
# ==========================================================

show_api_top10() {

    clear

    separator

    echo " API 当前 Top10 优选 IP"

    separator

    echo

    echo "API：$IP_API"

    echo

    if ! get_api_nodes; then

        echo

        echo "[ERROR] 获取 API 数据失败"

        echo

        return 1

    fi


    if ! sort_nodes_by_score; then

        echo

        echo "[ERROR] 综合评分计算失败"

        echo

        return 1

    fi


    printf "%-4s %-16s %-9s %-10s %-8s %-10s %-10s\n" \
        "排名" \
        "IP" \
        "Speed" \
        "Latency" \
        "Region" \
        "Carrier" \
        "Score"

    echo "--------------------------------------------------------------------------"


    local LIMIT=10

    if [ "${#SORTED_IPS[@]}" -lt "$LIMIT" ]; then
        LIMIT="${#SORTED_IPS[@]}"
    fi


    local i


    for ((i=0; i<LIMIT; i++)); do

        printf "%-4s %-16s %-9s %-10s %-8s %-10s %-10s\n" \
            "$((i+1))" \
            "${SORTED_IPS[$i]}" \
            "${SORTED_SPEEDS[$i]}" \
            "${SORTED_LATENCIES[$i]}" \
            "${SORTED_REGIONS[$i]}" \
            "${SORTED_CARRIERS[$i]}" \
            "${SORTED_SCORES[$i]}"

    done


    echo

    echo "评分策略："

    echo "  Speed   ${SPEED_WEIGHT}%"

    echo "  Latency ${LATENCY_WEIGHT}%"

    echo "  Region  ${REGION_WEIGHT}%"

    echo "  Carrier ${CARRIER_WEIGHT}%"

    echo

    echo "优先地区：${PREFERRED_REGIONS[*]}"

    echo "优先运营商：$PREFERRED_CARRIER"

    echo

}


# ==========================================================
# 按速度排序
# ==========================================================

show_nodes_by_speed() {

    clear

    separator

    echo " 按速度 Speed 排序"

    separator

    echo


    if ! get_api_nodes; then

        echo

        echo "[ERROR] 获取 API 数据失败"

        echo

        return 1

    fi


    local TEMP_FILE

    TEMP_FILE=$(mktemp)


    local i


    for ((i=0; i<${#NODE_IPS[@]}; i++)); do

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${NODE_SPEEDS[$i]}" \
            "${NODE_IPS[$i]}" \
            "${NODE_LATENCIES[$i]}" \
            "${NODE_REGIONS[$i]}" \
            "${NODE_CARRIERS[$i]}" \
            "${NODE_TIMES[$i]}" \
            >> "$TEMP_FILE"

    done


    printf "%-4s %-16s %-10s %-10s %-8s %-10s\n" \
        "排名" \
        "IP" \
        "Speed" \
        "Latency" \
        "Region" \
        "Carrier"

    echo "------------------------------------------------------------------"


    local RANK=1


    while IFS=$'\t' read -r SPEED IP LATENCY REGION CARRIER TIME; do

        printf "%-4s %-16s %-10s %-10s %-8s %-10s\n" \
            "$RANK" \
            "$IP" \
            "$SPEED" \
            "$LATENCY" \
            "$REGION" \
            "$CARRIER"

        ((RANK++))

    done < <(
        sort -t $'\t' -k1,1nr "$TEMP_FILE"
    )


    rm -f "$TEMP_FILE"


    echo

}


# ==========================================================
# 按延迟排序
# ==========================================================

show_nodes_by_latency() {

    clear

    separator

    echo " 按延迟 Latency 排序"

    separator

    echo


    if ! get_api_nodes; then

        echo

        echo "[ERROR] 获取 API 数据失败"

        echo

        return 1

    fi


    local TEMP_FILE

    TEMP_FILE=$(mktemp)


    local i


    for ((i=0; i<${#NODE_IPS[@]}; i++)); do

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${NODE_LATENCIES[$i]}" \
            "${NODE_IPS[$i]}" \
            "${NODE_SPEEDS[$i]}" \
            "${NODE_REGIONS[$i]}" \
            "${NODE_CARRIERS[$i]}" \
            "${NODE_TIMES[$i]}" \
            >> "$TEMP_FILE"

    done


    printf "%-4s %-16s %-10s %-10s %-8s %-10s\n" \
        "排名" \
        "IP" \
        "Latency" \
        "Speed" \
        "Region" \
        "Carrier"

    echo "------------------------------------------------------------------"


    local RANK=1


    while IFS=$'\t' read -r LATENCY IP SPEED REGION CARRIER TIME; do

        printf "%-4s %-16s %-10s %-10s %-8s %-10s\n" \
            "$RANK" \
            "$IP" \
            "$LATENCY" \
            "$SPEED" \
            "$REGION" \
            "$CARRIER"

        ((RANK++))

    done < <(
        sort -t $'\t' -k1,1n "$TEMP_FILE"
    )


    rm -f "$TEMP_FILE"


    echo

}


# ==========================================================
# 查看 IP 详细信息
# ==========================================================

show_node_details() {

    clear

    separator

    echo " API IP 详细信息"

    separator

    echo


    if ! get_api_nodes; then

        echo

        echo "[ERROR] 获取 API 数据失败"

        echo

        return 1

    fi


    if ! sort_nodes_by_score; then

        echo

        echo "[ERROR] 综合评分计算失败"

        echo

        return 1

    fi


    local LIMIT=10

    if [ "${#SORTED_IPS[@]}" -lt "$LIMIT" ]; then
        LIMIT="${#SORTED_IPS[@]}"
    fi


    local i


    for ((i=0; i<LIMIT; i++)); do

        echo "----------------------------------------------------------"

        echo "排名      ：$((i+1))"

        echo "IP        ：${SORTED_IPS[$i]}"

        echo "Speed     ：${SORTED_SPEEDS[$i]}"

        echo "Latency   ：${SORTED_LATENCIES[$i]}"

        echo "Region    ：${SORTED_REGIONS[$i]}"

        echo "Carrier   ：${SORTED_CARRIERS[$i]}"

        echo "检测时间  ：${SORTED_TIMES[$i]}"

        echo "综合评分  ：${SORTED_SCORES[$i]}"

        echo

    done


    separator

    echo

}


# ==========================================================
# 获取 DNS A 记录
# ==========================================================

get_dns_records() {

    local DOMAIN="$1"


    local RESPONSE


    RESPONSE=$(
        cf_api \
            GET \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&per_page=100&name=$DOMAIN"
    )


    if [ -z "$RESPONSE" ]; then

        log ERROR "$DOMAIN：Cloudflare API 无返回"

        return 1

    fi


    if ! echo "$RESPONSE" | jq empty >/dev/null 2>&1; then

        log ERROR "$DOMAIN：API 返回无效 JSON"

        return 1

    fi


    local SUCCESS

    SUCCESS=$(echo "$RESPONSE" |
        jq -r '.success // false')


    if [ "$SUCCESS" != "true" ]; then

        log ERROR "$DOMAIN：获取 DNS 记录失败"


        echo "$RESPONSE" |
            jq -r '.errors[]? | "\(.code): \(.message)"' |
            while read -r ERROR_LINE; do

                log ERROR "$DOMAIN：$ERROR_LINE"

            done


        return 1

    fi


    echo "$RESPONSE" |
        jq -r '
            .result[] |
            "\(.id)|\(.content)"
        '

}


# ==========================================================
# 比较 IP
# ==========================================================

ips_equal() {

    local CURRENT="$1"

    local TARGET="$2"


    local CURRENT_SORTED

    CURRENT_SORTED=$(
        printf '%s\n' "$CURRENT" |
        sed '/^$/d' |
        sort
    )


    local TARGET_SORTED

    TARGET_SORTED=$(
        printf '%s\n' "$TARGET" |
        sed '/^$/d' |
        sort
    )


    [ "$CURRENT_SORTED" = "$TARGET_SORTED" ]

}


# ==========================================================
# 创建 DNS
# ==========================================================

create_dns_record() {

    local DOMAIN="$1"

    local IP="$2"


    local DATA


    DATA=$(
        jq -n \
            --arg name "$DOMAIN" \
            --arg content "$IP" \
            --argjson ttl "$TTL" \
            --argjson proxied "$PROXIED" \
            '{
                type: "A",
                name: $name,
                content: $content,
                ttl: $ttl,
                proxied: $proxied
            }'
    )


    local RESPONSE


    RESPONSE=$(
        cf_api \
            POST \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            --data "$DATA"
    )


    if [ -z "$RESPONSE" ]; then

        log ERROR "$DOMAIN -> $IP：API 无返回"

        return 1

    fi


    if ! echo "$RESPONSE" | jq empty >/dev/null 2>&1; then

        log ERROR "$DOMAIN -> $IP：API 返回无效 JSON"

        return 1

    fi


    local SUCCESS

    SUCCESS=$(echo "$RESPONSE" |
        jq -r '.success // false')


    if [ "$SUCCESS" != "true" ]; then

        log ERROR "$DOMAIN -> $IP：创建失败"


        echo "$RESPONSE" |
            jq -r '.errors[]? | "\(.code): \(.message)"' |
            while read -r ERROR_LINE; do

                log ERROR "$DOMAIN -> $IP：$ERROR_LINE"

            done


        return 1

    fi


    log INFO "$DOMAIN -> $IP：创建成功"

    return 0

}


# ==========================================================
# 删除 DNS
# ==========================================================

delete_dns_record() {

    local DOMAIN="$1"

    local RECORD_ID="$2"


    local RESPONSE


    RESPONSE=$(
        cf_api \
            DELETE \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID"
    )


    if [ -z "$RESPONSE" ]; then

        log ERROR "$DOMAIN：删除记录 $RECORD_ID 无返回"

        return 1

    fi


    local SUCCESS

    SUCCESS=$(echo "$RESPONSE" |
        jq -r '.success // false')


    if [ "$SUCCESS" != "true" ]; then

        log ERROR "$DOMAIN：删除记录 $RECORD_ID 失败"


        echo "$RESPONSE" |
            jq -r '.errors[]? | "\(.code): \(.message)"' |
            while read -r ERROR_LINE; do

                log ERROR "$DOMAIN：$ERROR_LINE"

            done


        return 1

    fi


    log INFO "$DOMAIN：删除旧记录成功 ID=$RECORD_ID"

    return 0

}


# ==========================================================
# 生成目标 IP
#
# 使用综合评分后的 IPS。
#
# 优先保证：
#   1. 高评分 IP
#   2. 不同域名尽量不重复
#
# 当域名总需求超过 API IP 数量时，
# 才会循环使用 IP。
# ==========================================================

generate_target_ips() {

    local DOMAIN_INDEX="$1"

    local IP_COUNT="$2"

    TARGET_IPS=()


    local TOTAL_IPS="${#IPS[@]}"

    local J

    local IP_INDEX

    local GLOBAL_OFFSET=0


    if [ "$TOTAL_IPS" -eq 0 ]; then

        return 1

    fi


    # ------------------------------------------------------
    # 根据前面域名实际需求计算偏移
    #
    # 避免原来：
    #
    # DOMAIN_INDEX * IP_COUNT
    #
    # 导致不同 IP_COUNT 的域名分配异常。
    # ------------------------------------------------------

    local K


    for ((K=0; K<DOMAIN_INDEX; K++)); do

        GLOBAL_OFFSET=$((GLOBAL_OFFSET + DOMAIN_IP_COUNTS[K]))

    done


    for ((J=0; J<IP_COUNT; J++)); do

        IP_INDEX=$(( (GLOBAL_OFFSET + J) % TOTAL_IPS ))

        TARGET_IPS+=("${IPS[$IP_INDEX]}")

    done


    # ------------------------------------------------------
    # 去重
    # ------------------------------------------------------

    local UNIQUE=()

    declare -A SEEN=()


    local IP


    for IP in "${TARGET_IPS[@]}"; do

        if [ -z "${SEEN[$IP]+x}" ]; then

            UNIQUE+=("$IP")

            SEEN["$IP"]=1

        fi

    done


    TARGET_IPS=("${UNIQUE[@]}")

}


# ==========================================================
# 处理单个域名
# ==========================================================

process_domain() {

    local DOMAIN="$1"

    local DOMAIN_INDEX="$2"

    local IP_COUNT="$3"


    separator

    log INFO "处理：$DOMAIN"

    log INFO "IP 数量：$IP_COUNT"


    # ------------------------------------------------------
    # 生成目标 IP
    # ------------------------------------------------------

    generate_target_ips "$DOMAIN_INDEX" "$IP_COUNT"


    log INFO "目标 IP：${TARGET_IPS[*]}"


    # ------------------------------------------------------
    # 获取当前记录
    # ------------------------------------------------------

    local RECORD_DATA


    RECORD_DATA=$(get_dns_records "$DOMAIN")


    if [ $? -ne 0 ]; then

        log ERROR "$DOMAIN：无法读取 Cloudflare DNS"

        return 1

    fi


    local CURRENT_IPS

    local CURRENT_IDS


    CURRENT_IPS=$(
        echo "$RECORD_DATA" |
        cut -d'|' -f2
    )


    CURRENT_IDS=$(
        echo "$RECORD_DATA" |
        cut -d'|' -f1
    )


    # ------------------------------------------------------
    # IP 未变化
    # ------------------------------------------------------

    local TARGET_TEXT


    TARGET_TEXT=$(
        printf '%s\n' "${TARGET_IPS[@]}"
    )


    if ips_equal "$CURRENT_IPS" "$TARGET_TEXT"; then

        log INFO "$DOMAIN：IP 未变化，跳过"

        return 0

    fi


    if [ -n "$CURRENT_IPS" ]; then

        log INFO "当前 IP：${CURRENT_IPS//$'\n'/ }"

    else

        log INFO "当前 IP：无"

    fi


    log INFO "目标 IP：${TARGET_IPS[*]}"


    # ------------------------------------------------------
    # 先创建新记录
    # ------------------------------------------------------

    CREATED_IPS=()

    CREATE_FAILED=0


    local IP


    for IP in "${TARGET_IPS[@]}"; do

        if create_dns_record "$DOMAIN" "$IP"; then

            CREATED_IPS+=("$IP")

        else

            CREATE_FAILED=1

            break

        fi

    done


    # ------------------------------------------------------
    # 新记录创建失败
    # ------------------------------------------------------

    if [ "$CREATE_FAILED" -eq 1 ]; then

        log ERROR "$DOMAIN：新记录创建失败"

        log ERROR "$DOMAIN：保留原有记录，不删除"


        local NEW_DATA


        NEW_DATA=$(get_dns_records "$DOMAIN" 2>/dev/null || true)


        local RECORD_ID

        local RECORD_IP

        local CREATED_IP


        while IFS='|' read -r RECORD_ID RECORD_IP; do

            [ -z "$RECORD_ID" ] && continue


            for CREATED_IP in "${CREATED_IPS[@]}"; do

                if [ "$RECORD_IP" = "$CREATED_IP" ]; then

                    delete_dns_record \
                        "$DOMAIN" \
                        "$RECORD_ID" \
                        || true

                fi

            done

        done <<< "$NEW_DATA"


        return 1

    fi


    # ------------------------------------------------------
    # 删除旧记录
    # ------------------------------------------------------

    local DELETE_FAILED=0


    if [ -n "$CURRENT_IDS" ]; then

        while read -r RECORD_ID; do

            [ -z "$RECORD_ID" ] && continue


            if ! delete_dns_record \
                "$DOMAIN" \
                "$RECORD_ID"; then

                DELETE_FAILED=1

            fi


        done <<< "$CURRENT_IDS"

    fi


    if [ "$DELETE_FAILED" -eq 1 ]; then

        log ERROR "$DOMAIN：部分旧记录删除失败"

        return 1

    fi


    log INFO "$DOMAIN：更新成功"

    return 0

}


# ==========================================================
# 查看所有域名当前 IP
# ==========================================================

show_all_domain_ips() {

    load_domains

    clear


    separator

    echo " domains.conf 域名当前 IP"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "domains.conf 中没有配置任何域名。"

        echo

        return

    fi


    echo "配置文件：$DOMAIN_CONFIG"

    echo "域名数量：${#DOMAINS[@]}"

    echo


    printf "%-5s %-40s %-10s %s\n" \
        "编号" \
        "域名" \
        "IP数量" \
        "当前 IP"


    echo "------------------------------------------------------------------------------------------"


    local i

    local DOMAIN

    local CONFIG_COUNT

    local RECORD_DATA

    local CURRENT_IPS

    local IP_DISPLAY


    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        DOMAIN="${DOMAINS[$i]}"

        CONFIG_COUNT="${DOMAIN_IP_COUNTS[$i]}"


        RECORD_DATA=$(get_dns_records "$DOMAIN" 2>/dev/null)


        if [ $? -ne 0 ]; then

            printf "%-5s %-40s %-10s %s\n" \
                "$((i+1))" \
                "$DOMAIN" \
                "$CONFIG_COUNT" \
                "查询失败"

            continue

        fi


        CURRENT_IPS=$(
            echo "$RECORD_DATA" |
            cut -d'|' -f2 |
            sed '/^$/d' |
            sort -u
        )


        if [ -z "$CURRENT_IPS" ]; then

            printf "%-5s %-40s %-10s %s\n" \
                "$((i+1))" \
                "$DOMAIN" \
                "$CONFIG_COUNT" \
                "无 A 记录"

            continue

        fi


        IP_DISPLAY=$(
            echo "$CURRENT_IPS" |
            paste -sd ',' -
        )


        printf "%-5s %-40s %-10s %s\n" \
            "$((i+1))" \
            "$DOMAIN" \
            "$CONFIG_COUNT" \
            "$IP_DISPLAY"

    done


    echo

    separator

    echo

}


# ==========================================================
# 添加域名
# ==========================================================

add_domain() {

    load_domains


    echo

    separator

    echo " 添加域名"

    separator

    echo


    read -rp "请输入域名： " NEW_DOMAIN


    NEW_DOMAIN=$(echo "$NEW_DOMAIN" | xargs)


    if ! validate_domain "$NEW_DOMAIN"; then

        echo

        echo "[ERROR] 域名格式无效：$NEW_DOMAIN"

        echo

        return

    fi


    if find_domain_index "$NEW_DOMAIN" >/dev/null 2>&1; then

        echo

        echo "[ERROR] 域名已经存在：$NEW_DOMAIN"

        echo

        return

    fi


    read -rp \
        "每个域名挂几个 IP？[默认 $DEFAULT_MAX_IPS]: " \
        NEW_IP_COUNT


    if [ -z "$NEW_IP_COUNT" ]; then

        NEW_IP_COUNT="$DEFAULT_MAX_IPS"

    fi


    if ! [[ "$NEW_IP_COUNT" =~ ^[0-9]+$ ]] ||
       [ "$NEW_IP_COUNT" -lt 1 ]; then

        echo

        echo "[ERROR] IP 数量必须是大于 0 的整数"

        echo

        return

    fi


    DOMAINS+=("$NEW_DOMAIN")

    DOMAIN_IP_COUNTS+=("$NEW_IP_COUNT")


    save_domains


    echo

    echo "[OK] 域名添加成功：$NEW_DOMAIN"

    echo "[OK] IP 数量：$NEW_IP_COUNT"

    echo

}


# ==========================================================
# 批量添加域名
# ==========================================================

add_multiple_domains() {

    load_domains


    echo

    separator

    echo " 批量添加域名"

    separator

    echo


    echo "多个域名使用空格分隔。"

    echo

    echo "例如："

    echo "jp1.awsno.com jp2.awsno.com sg1.awsno.com"

    echo


    read -rp "域名： " DOMAIN_INPUT


    if [ -z "$DOMAIN_INPUT" ]; then

        echo "[ERROR] 没有输入域名"

        return

    fi


    read -rp \
        "这些域名统一挂几个 IP？[默认 $DEFAULT_MAX_IPS]: " \
        INPUT_COUNT


    if [ -z "$INPUT_COUNT" ]; then

        INPUT_COUNT="$DEFAULT_MAX_IPS"

    fi


    if ! [[ "$INPUT_COUNT" =~ ^[0-9]+$ ]] ||
       [ "$INPUT_COUNT" -lt 1 ]; then

        echo "[ERROR] IP 数量无效"

        return

    fi


    local ADD_COUNT=0


    local DOMAIN


    for DOMAIN in $DOMAIN_INPUT; do

        DOMAIN=$(echo "$DOMAIN" | xargs)


        if ! validate_domain "$DOMAIN"; then

            echo "[WARNING] 无效域名，跳过：$DOMAIN"

            continue

        fi


        if find_domain_index "$DOMAIN" >/dev/null 2>&1; then

            echo "[WARNING] 已存在，跳过：$DOMAIN"

            continue

        fi


        DOMAINS+=("$DOMAIN")

        DOMAIN_IP_COUNTS+=("$INPUT_COUNT")


        echo "[OK] 添加：$DOMAIN"

        ((ADD_COUNT++))

    done


    if [ "$ADD_COUNT" -gt 0 ]; then

        save_domains

    fi


    echo

    echo "成功添加 $ADD_COUNT 个域名。"

    echo

}


# ==========================================================
# 删除域名
# ==========================================================

delete_domain() {

    load_domains


    echo

    separator

    echo " 删除域名"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "没有任何域名。"

        return

    fi


    show_domains


    read -rp "请输入要删除的编号： " INDEX


    if ! [[ "$INDEX" =~ ^[0-9]+$ ]] ||
       [ "$INDEX" -lt 1 ] ||
       [ "$INDEX" -gt "${#DOMAINS[@]}" ]; then

        echo

        echo "[ERROR] 无效编号"

        return

    fi


    local REAL_INDEX=$((INDEX-1))


    local DOMAIN="${DOMAINS[$REAL_INDEX]}"


    echo

    echo "准备删除：$DOMAIN"

    echo


    read -rp "确认删除？[y/N]: " CONFIRM


    case "$CONFIRM" in

        y|Y|yes|YES)
            ;;

        *)
            echo "已取消。"
            return
            ;;

    esac


    unset 'DOMAINS[REAL_INDEX]'

    unset 'DOMAIN_IP_COUNTS[REAL_INDEX]'


    DOMAINS=("${DOMAINS[@]}")

    DOMAIN_IP_COUNTS=("${DOMAIN_IP_COUNTS[@]}")


    save_domains


    echo

    echo "[OK] 已从自动任务列表删除：$DOMAIN"

    echo

    echo "这里只是停止以后 Cron 自动管理该域名。"

    echo "不会删除 Cloudflare 中现有的 DNS 记录。"

    echo

}


# ==========================================================
# 修改域名 IP 数量
# ==========================================================

change_ip_count() {

    load_domains


    echo

    separator

    echo " 修改 IP 数量"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "没有任何域名。"

        return

    fi


    show_domains


    read -rp "请输入域名编号： " INDEX


    if ! [[ "$INDEX" =~ ^[0-9]+$ ]] ||
       [ "$INDEX" -lt 1 ] ||
       [ "$INDEX" -gt "${#DOMAINS[@]}" ]; then

        echo "[ERROR] 无效编号"

        return

    fi


    local REAL_INDEX=$((INDEX-1))

    local DOMAIN="${DOMAINS[$REAL_INDEX]}"

    local OLD_COUNT="${DOMAIN_IP_COUNTS[$REAL_INDEX]}"


    echo

    echo "域名：$DOMAIN"

    echo "当前 IP 数量：$OLD_COUNT"

    echo


    read -rp "新的 IP 数量： " NEW_COUNT


    if ! [[ "$NEW_COUNT" =~ ^[0-9]+$ ]] ||
       [ "$NEW_COUNT" -lt 1 ]; then

        echo

        echo "[ERROR] IP 数量必须大于 0"

        return

    fi


    DOMAIN_IP_COUNTS[$REAL_INDEX]="$NEW_COUNT"


    save_domains


    echo

    echo "[OK] 修改成功"

    echo "域名：$DOMAIN"

    echo "IP 数量：$OLD_COUNT -> $NEW_COUNT"

    echo

}


# ==========================================================
# 手动为所有 domains.conf 域名设置统一 IP
# ==========================================================

set_all_domains_same_ip() {

    load_domains

    clear


    separator

    echo " 手动设置所有域名统一 IP"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "domains.conf 中没有配置任何域名。"

        echo

        return

    fi


    echo "将会处理以下 ${#DOMAINS[@]} 个域名："

    echo


    local i


    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        echo "  $((i+1)). ${DOMAINS[$i]}"

    done


    echo


    read -rp "请输入统一 IP： " UNIFIED_IP


    UNIFIED_IP=$(echo "$UNIFIED_IP" | xargs)


    if ! [[ "$UNIFIED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

        echo

        echo "[ERROR] IP 地址格式错误：$UNIFIED_IP"

        echo

        return 1

    fi


    IFS='.' read -r IP1 IP2 IP3 IP4 <<< "$UNIFIED_IP"


    if [ "$IP1" -gt 255 ] ||
       [ "$IP2" -gt 255 ] ||
       [ "$IP3" -gt 255 ] ||
       [ "$IP4" -gt 255 ]; then

        echo

        echo "[ERROR] 无效 IPv4 地址：$UNIFIED_IP"

        echo

        return 1

    fi


    echo

    separator

    echo "即将执行："

    echo

    echo "所有 ${#DOMAINS[@]} 个域名"

    echo "        ↓"

    echo "统一设置为"

    echo "        ↓"

    echo "$UNIFIED_IP"

    echo

    echo "每个域名现有的 A 记录都会被删除。"

    echo "最终每个域名只保留一个 A 记录：$UNIFIED_IP"

    echo

    separator

    echo


    read -rp "确定执行吗？请输入 YES 确认： " CONFIRM


    if [ "$CONFIRM" != "YES" ]; then

        echo

        echo "操作已取消。"

        echo

        return 0

    fi


    if ! check_cloudflare_api; then

        echo

        echo "[ERROR] Cloudflare API 检测失败，操作终止。"

        echo

        return 1

    fi


    echo

    separator

    echo "开始设置统一 IP"

    separator

    echo


    local TOTAL="${#DOMAINS[@]}"

    local SUCCESS=0

    local FAILED=0


    local DOMAIN

    local RECORD_DATA

    local CURRENT_IPS

    local CURRENT_COUNT

    local NEW_RECORD_DATA

    local DELETE_FAILED


    for ((i=0; i<TOTAL; i++)); do

        DOMAIN="${DOMAINS[$i]}"


        echo

        echo "[$((i+1))/$TOTAL] 处理：$DOMAIN"


        RECORD_DATA=$(get_dns_records "$DOMAIN" 2>/dev/null)


        if [ $? -ne 0 ]; then

            echo "[ERROR] 无法获取 $DOMAIN 的 DNS 记录"

            ((FAILED++))

            continue

        fi


        CURRENT_IPS=$(
            echo "$RECORD_DATA" |
            cut -d'|' -f2 |
            sed '/^$/d' |
            sort -u
        )


        CURRENT_COUNT=$(
            echo "$CURRENT_IPS" |
            sed '/^$/d' |
            wc -l
        )


        if [ "$CURRENT_COUNT" -eq 1 ] &&
           [ "$CURRENT_IPS" = "$UNIFIED_IP" ]; then

            echo "[SKIP] $DOMAIN 已经是 $UNIFIED_IP"

            ((SUCCESS++))

            continue

        fi


        echo "[INFO] 创建目标 IP：$UNIFIED_IP"


        if ! create_dns_record "$DOMAIN" "$UNIFIED_IP"; then

            echo "[ERROR] $DOMAIN 创建新 IP 失败"

            ((FAILED++))

            continue

        fi


        NEW_RECORD_DATA=$(get_dns_records "$DOMAIN" 2>/dev/null)


        if [ $? -ne 0 ]; then

            echo "[ERROR] $DOMAIN 创建后重新查询 DNS 失败"

            ((FAILED++))

            continue

        fi


        DELETE_FAILED=0


        local RECORD_ID

        local RECORD_IP


        while IFS='|' read -r RECORD_ID RECORD_IP; do

            [ -z "$RECORD_ID" ] && continue


            if [ "$RECORD_IP" = "$UNIFIED_IP" ]; then
                continue
            fi


            echo "[INFO] 删除旧 IP：$RECORD_IP"


            if ! delete_dns_record "$DOMAIN" "$RECORD_ID"; then

                DELETE_FAILED=1

                echo "[ERROR] 删除失败：$RECORD_IP"

            fi


        done <<< "$NEW_RECORD_DATA"


        if [ "$DELETE_FAILED" -eq 1 ]; then

            echo "[ERROR] $DOMAIN 部分旧记录删除失败"

            ((FAILED++))

            continue

        fi


        echo "[OK] $DOMAIN → $UNIFIED_IP"

        ((SUCCESS++))


        sleep 0.5

    done


    echo

    separator

    echo "统一 IP 设置完成"

    echo

    echo "目标 IP：$UNIFIED_IP"

    echo "域名总数：$TOTAL"

    echo "成功：$SUCCESS"

    echo "失败：$FAILED"

    separator

    echo

}


# ==========================================================
# 实际更新
# ==========================================================

run_update_core() {

    local TOTAL="${#DOMAINS[@]}"

    local SUCCESS=0

    local FAILED=0


    local i

    local DOMAIN

    local IP_COUNT


    for ((i=0; i<TOTAL; i++)); do

        DOMAIN="${DOMAINS[$i]}"

        IP_COUNT="${DOMAIN_IP_COUNTS[$i]}"


        if process_domain \
            "$DOMAIN" \
            "$i" \
            "$IP_COUNT"; then

            ((SUCCESS++))

        else

            ((FAILED++))

        fi


        sleep 0.5

    done


    separator

    log INFO "任务完成"

    log INFO "域名总数：$TOTAL"

    log INFO "成功：$SUCCESS"

    log INFO "失败：$FAILED"

    separator


    if [ "$FAILED" -gt 0 ]; then

        return 1

    fi


    return 0

}


# ==========================================================
# 手动立即执行
# ==========================================================

run_update() {

    load_domains


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo

        echo "[ERROR] 当前没有配置域名。"

        echo

        return

    fi


    if ! check_cloudflare_api; then

        return 1

    fi


    if ! get_preferred_ips; then

        return 1

    fi


    echo

    separator

    echo "准备更新 ${#DOMAINS[@]} 个域名"

    separator

    echo


    echo "本次将按照以下综合评分选择 IP："

    echo

    echo "  Speed   ${SPEED_WEIGHT}%"

    echo "  Latency ${LATENCY_WEIGHT}%"

    echo "  Region  ${REGION_WEIGHT}%"

    echo "  Carrier ${CARRIER_WEIGHT}%"

    echo


    read -rp "确认执行？[y/N]: " CONFIRM


    case "$CONFIRM" in

        y|Y|yes|YES)
            ;;

        *)
            echo "已取消。"
            return
            ;;

    esac


    run_update_core

}


# ==========================================================
# Cron 模式
# ==========================================================

cron_mode() {

    log INFO "=========================================="

    log INFO "Cron 自动任务启动"

    log INFO "=========================================="


    load_domains


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        log INFO "没有配置任何域名，任务结束"

        return 0

    fi


    log INFO "读取到 ${#DOMAINS[@]} 个域名"


    if ! check_cloudflare_api; then

        log ERROR "Cloudflare API 检测失败"

        return 1

    fi


    if ! get_preferred_ips; then

        log ERROR "获取优选 IP 失败"

        return 1

    fi


    run_update_core

}


# ==========================================================
# 手动菜单
# ==========================================================

interactive_menu() {

    while true; do

        clear


        separator

        echo " Cloudflare 优选 IP 自动分配工具"

        separator

        echo


        load_domains


        echo "当前域名数量：${#DOMAINS[@]}"

        echo


        echo "1. 查看当前域名"

        echo "2. 添加域名"

        echo "3. 批量添加域名"

        echo "4. 删除域名"

        echo "5. 修改域名 IP 数量"

        echo "6. 立即执行 DNS 更新"

        echo "7. 查看所有域名当前 IP"

        echo "8. 所有域名设置统一 IP"

        echo

        echo "────────── IP 优选 ──────────"

        echo

        echo "10. 查看 API 当前获取到的有效IP"

        echo "11. 按速度重新排序"

        echo "12. 按延迟重新排序"

        echo "13. 查看 IP 详细信息"

        echo

        echo "0. 退出"

        echo


        read -rp "请选择 [1-13]： " MENU


        case "$MENU" in

            1)

                show_domains

                read -rp "按回车继续..." _

                ;;


            2)

                add_domain

                read -rp "按回车继续..." _

                ;;


            3)

                add_multiple_domains

                read -rp "按回车继续..." _

                ;;


            4)

                delete_domain

                read -rp "按回车继续..." _

                ;;


            5)

                change_ip_count

                read -rp "按回车继续..." _

                ;;


            6)

                run_update

                read -rp "按回车继续..." _

                ;;


            7)

                show_all_domain_ips

                read -rp "按回车继续..." _

                ;;


            8)

                set_all_domains_same_ip

                read -rp "按回车继续..." _

                ;;


            0)

                echo

                echo "退出。"

                exit 0

                ;;


            10)

                show_api_top10

                read -rp "按回车继续..." _

                ;;


            11)

                show_nodes_by_speed

                read -rp "按回车继续..." _

                ;;


            12)

                show_nodes_by_latency

                read -rp "按回车继续..." _

                ;;


            13)

                show_node_details

                read -rp "按回车继续..." _

                ;;


            *)

                echo

                echo "[ERROR] 无效选择"

                sleep 1

                ;;

        esac

    done

}


# ==========================================================
# 主程序
# ==========================================================

check_dependencies

check_config

init_domain_config


# ==========================================================
# Cron 模式
# ==========================================================

if [ "$MODE" = "cron" ]; then

    exec 200>"$LOCK_FILE"


    if ! flock -n 200; then

        log INFO "检测到已有任务正在运行，本次 Cron 跳过"

        exit 0

    fi


    trap 'flock -u 200' EXIT


    cron_mode

    EXIT_CODE=$?


    exit "$EXIT_CODE"

fi


# ==========================================================
# 手动模式
# ==========================================================

interactive_menu