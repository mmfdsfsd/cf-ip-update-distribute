#!/bin/bash

# ==========================================================
# Cloudflare 优选 IP 自动分配工具
#
# SG / JP 地区独立 IP 池
#
# 配置文件：
#   /root/cf-ip-update/sg-domains.conf
#   /root/cf-ip-update/jp-domains.conf
#
# 格式：
#   domain|ip数量
#
# 例如：
#   sg1.example.com|3
#   sg2.example.com|3
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

CF_API_TOKEN="my-cf-token"

ZONE_ID="my-cf-zone-id"

TTL=60

# false = DNS Only
# true  = Cloudflare Proxy
PROXIED=false


# ==========================================================
# 优选 IP API
# ==========================================================

IP_API="https://ip.v2too.top/api/nodes"


# ==========================================================
# 综合评分权重
# ==========================================================

SPEED_WEIGHT=50
LATENCY_WEIGHT=30
REGION_WEIGHT=15
CARRIER_WEIGHT=5


# ==========================================================
# 地区配置
#
# SG -> SIN
# JP -> NRT
#
# API 中 region 必须与这里对应
# ==========================================================

SG_REGION="SIN"
JP_REGION="NRT"


# ==========================================================
# 优先运营商
#
# 注意：
# SG / JP 如果 API carrier 不同，可以分别配置
# ==========================================================

SG_PREFERRED_CARRIER="ct"
JP_PREFERRED_CARRIER="ct"


# ==========================================================
# 默认每个域名 IP 数量
# ==========================================================

DEFAULT_MAX_IPS=3


# ==========================================================
# API IP 最低速度
#
# 低于这个速度的节点直接过滤
# ==========================================================

MIN_SPEED=10


# ==========================================================
# 文件
# ==========================================================

CONFIG_DIR="/root/cf-ip-update"

SG_DOMAIN_CONFIG="$CONFIG_DIR/sg-domains.conf"
JP_DOMAIN_CONFIG="$CONFIG_DIR/jp-domains.conf"

LOG_FILE="$CONFIG_DIR/cf-ip-update-distribute.log"

LOCK_FILE="$CONFIG_DIR/cf-ip-update-distribute.lock"


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
    command -v cut >/dev/null 2>&1 || MISSING+=("cut")
    command -v paste >/dev/null 2>&1 || MISSING+=("paste")

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
# 初始化配置文件
# ==========================================================

init_domain_config() {

    for FILE in \
        "$SG_DOMAIN_CONFIG" \
        "$JP_DOMAIN_CONFIG"
    do

        if [ ! -f "$FILE" ]; then

            touch "$FILE"

            chmod 600 "$FILE"

            log INFO "创建域名配置文件：$FILE"
        fi

    done
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
# 加载指定地区域名
#
# 参数：
#   $1 = SG / JP
#
# 输出到：
#   DOMAINS
#   DOMAIN_IP_COUNTS
# ==========================================================

load_domains() {

    local REGION="$1"

    DOMAINS=()
    DOMAIN_IP_COUNTS=()


    local CONFIG_FILE

    case "$REGION" in

        SG)
            CONFIG_FILE="$SG_DOMAIN_CONFIG"
            ;;

        JP)
            CONFIG_FILE="$JP_DOMAIN_CONFIG"
            ;;

        *)
            log ERROR "未知地区：$REGION"
            return 1
            ;;
    esac


    [ ! -f "$CONFIG_FILE" ] && return 0


    while IFS='|' read -r DOMAIN IP_COUNT; do

        DOMAIN=$(echo "$DOMAIN" | xargs)

        [ -z "$DOMAIN" ] && continue

        [[ "$DOMAIN" =~ ^# ]] && continue


        if ! validate_domain "$DOMAIN"; then

            log ERROR "[$REGION] 域名配置无效，跳过：$DOMAIN"

            continue
        fi


        IP_COUNT=$(echo "$IP_COUNT" | xargs)


        if ! [[ "$IP_COUNT" =~ ^[0-9]+$ ]]; then

            log ERROR "[$REGION] IP 数量无效，跳过：$DOMAIN|$IP_COUNT"

            continue
        fi


        if [ "$IP_COUNT" -lt 1 ]; then

            log ERROR "[$REGION] IP 数量必须大于 0，跳过：$DOMAIN"

            continue
        fi


        DOMAINS+=("$DOMAIN")
        DOMAIN_IP_COUNTS+=("$IP_COUNT")

    done < "$CONFIG_FILE"
}


# ==========================================================
# 保存指定地区域名配置
# ==========================================================

save_domains() {

    local REGION="$1"

    local CONFIG_FILE

    case "$REGION" in

        SG)
            CONFIG_FILE="$SG_DOMAIN_CONFIG"
            ;;

        JP)
            CONFIG_FILE="$JP_DOMAIN_CONFIG"
            ;;

        *)
            return 1
            ;;
    esac


    local TEMP_FILE

    TEMP_FILE="${CONFIG_FILE}.tmp"


    : > "$TEMP_FILE"


    local i

    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        echo "${DOMAINS[$i]}|${DOMAIN_IP_COUNTS[$i]}" >> "$TEMP_FILE"

    done


    chmod 600 "$TEMP_FILE"

    mv "$TEMP_FILE" "$CONFIG_FILE"


    log INFO "[$REGION] 域名配置已保存：$CONFIG_FILE"
}


# ==========================================================
# 查找域名
# ==========================================================

find_domain_index() {

    local SEARCH_DOMAIN="$1"

    local i

    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        if [ "${DOMAINS[$i]}" = "$SEARCH_DOMAIN" ]; then

            echo "$i"

            return 0
        fi

    done

    return 1
}


# ==========================================================
# Cloudflare API
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

    ZONE_NAME=$(
        echo "$RESPONSE" |
        jq -r '.result.name // empty'
    )


    log INFO "Cloudflare API 正常"

    [ -n "$ZONE_NAME" ] &&
        log INFO "Zone：$ZONE_NAME"


    return 0
}


# ==========================================================
# 获取指定地区 API 节点
#
# 参数：
#   $1 = SG / JP
#
# SG -> SIN
# JP -> NRT
#
# 最终保存：
#
# NODE_IPS
# NODE_SPEEDS
# NODE_LATENCIES
# NODE_REGIONS
# NODE_TIMES
# NODE_CARRIERS
# ==========================================================

get_api_nodes() {

    local TARGET_REGION="$1"

    NODE_IPS=()
    NODE_SPEEDS=()
    NODE_LATENCIES=()
    NODE_REGIONS=()
    NODE_TIMES=()
    NODE_CARRIERS=()


    local API_REGION
    local PREFERRED_CARRIER


    case "$TARGET_REGION" in

        SG)

            API_REGION="$SG_REGION"
            PREFERRED_CARRIER="$SG_PREFERRED_CARRIER"

            ;;

        JP)

            API_REGION="$JP_REGION"
            PREFERRED_CARRIER="$JP_PREFERRED_CARRIER"

            ;;

        *)

            log ERROR "未知地区：$TARGET_REGION"

            return 1

            ;;
    esac


    log INFO "[$TARGET_REGION] 请求优选 IP API：$IP_API"

    log INFO "[$TARGET_REGION] API 地区过滤：region=$API_REGION"


    local RESPONSE


    RESPONSE=$(
        curl -L -sS \
            --connect-timeout 10 \
            --max-time 30 \
            "$IP_API"
    )


    if [ -z "$RESPONSE" ]; then

        log ERROR "[$TARGET_REGION] 优选 IP API 无返回"

        return 1
    fi


    if ! echo "$RESPONSE" | jq empty >/dev/null 2>&1; then

        log ERROR "[$TARGET_REGION] 优选 IP API 返回无效 JSON"

        log ERROR "$RESPONSE"

        return 1
    fi


    if ! echo "$RESPONSE" |
        jq -e 'type == "array"' >/dev/null 2>&1; then

        log ERROR "[$TARGET_REGION] API 返回的数据不是 JSON 数组"

        return 1
    fi


    # ------------------------------------------------------
    # 提取指定地区节点
    # ------------------------------------------------------

    while IFS=$'\t' read -r \
        IP \
        SPEED \
        LATENCY \
        REGION \
        TIME \
        CARRIER
    do

        [ -z "$IP" ] && continue


        # --------------------------------------------------
        # 只允许当前地区
        # --------------------------------------------------

        if [ "$REGION" != "$API_REGION" ]; then
            continue
        fi


        # --------------------------------------------------
        # 速度过滤
        # --------------------------------------------------

        if ! awk \
            -v speed="${SPEED:-0}" \
            -v min_speed="$MIN_SPEED" '
            BEGIN {
                if ((speed + 0) < (min_speed + 0)) {
                    exit 1
                }

                exit 0
            }
        '; then

            log INFO \
                "[$TARGET_REGION] 过滤低速 IP：$IP speed=${SPEED:-0} < $MIN_SPEED"

            continue
        fi


        # --------------------------------------------------
        # IPv4 验证
        # --------------------------------------------------

        if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

            log WARN \
                "[$TARGET_REGION] 跳过无效 IPv4：$IP"

            continue
        fi


        NODE_IPS+=("$IP")
        NODE_SPEEDS+=("${SPEED:-0}")
        NODE_LATENCIES+=("${LATENCY:-999999}")
        NODE_REGIONS+=("${REGION:-UNKNOWN}")
        NODE_TIMES+=("${TIME:-UNKNOWN}")
        NODE_CARRIERS+=("${CARRIER:-UNKNOWN}")

    done < <(

        echo "$RESPONSE" |
        jq -r '
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


    # ------------------------------------------------------
    # 没有节点
    # ------------------------------------------------------

    if [ "${#NODE_IPS[@]}" -eq 0 ]; then

        log ERROR \
            "[$TARGET_REGION] API 中没有符合条件的有效 IPv4"

        return 1
    fi


    # ------------------------------------------------------
    # 去重
    # ------------------------------------------------------

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


    log INFO \
        "[$TARGET_REGION] 获取到 ${#NODE_IPS[@]} 个有效节点"


    return 0
}

# ==========================================================
# 计算指定地区综合评分
#
# 参数：
#   $1 = SG / JP
#
# SG：
#   region = SIN
#   carrier = SG_PREFERRED_CARRIER
#
# JP：
#   region = NRT
#   carrier = JP_PREFERRED_CARRIER
# ==========================================================

calculate_scores() {

    local TARGET_REGION="${1:-}"

    local count=${#NODE_IPS[@]}

    if [[ "$count" -eq 0 ]]; then
        log ERROR "[$TARGET_REGION] 没有节点可计算评分"
        return 1
    fi

    # ------------------------------------------------------
    # 根据地区获取评分配置
    # ------------------------------------------------------

    local API_REGION=""
    local PREFERRED_CARRIER=""

    case "$TARGET_REGION" in

        SG)
            API_REGION="$SG_REGION"
            PREFERRED_CARRIER="$SG_PREFERRED_CARRIER"
            ;;

        JP)
            API_REGION="$JP_REGION"
            PREFERRED_CARRIER="$JP_PREFERRED_CARRIER"
            ;;

        *)
            log ERROR "未知评分地区：$TARGET_REGION"
            return 1
            ;;

    esac


    # ------------------------------------------------------
    # 清洗 speed / latency
    # ------------------------------------------------------

    local i
    local speed
    local latency

    for ((i=0; i<count; i++)); do

        speed="${NODE_SPEEDS[$i]:-0}"
        latency="${NODE_LATENCIES[$i]:-0}"

        # 删除非数字字符
        speed=$(printf '%s' "$speed" | sed 's/[^0-9.]//g')
        latency=$(printf '%s' "$latency" | sed 's/[^0-9.]//g')

        [[ -z "$speed" ]] && speed="0"
        [[ -z "$latency" ]] && latency="999999"

        # 必须是合法数字
        if ! [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            speed="0"
        fi

        if ! [[ "$latency" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            latency="999999"
        fi

        NODE_SPEEDS[$i]="$speed"
        NODE_LATENCIES[$i]="$latency"

    done


    # ------------------------------------------------------
    # 获取最大 / 最小速度
    # ------------------------------------------------------

    local min_speed
    local max_speed
    local min_latency
    local max_latency

    min_speed=$(
        printf '%s\n' "${NODE_SPEEDS[@]}" |
        awk '
            NR==1 {
                min=$1
                next
            }
            $1 < min {
                min=$1
            }
            END {
                print min+0
            }
        '
    )

    max_speed=$(
        printf '%s\n' "${NODE_SPEEDS[@]}" |
        awk '
            NR==1 {
                max=$1
                next
            }
            $1 > max {
                max=$1
            }
            END {
                print max+0
            }
        '
    )


    # ------------------------------------------------------
    # 获取最大 / 最小延迟
    # ------------------------------------------------------

    min_latency=$(
        printf '%s\n' "${NODE_LATENCIES[@]}" |
        awk '
            NR==1 {
                min=$1
                next
            }
            $1 < min {
                min=$1
            }
            END {
                print min+0
            }
        '
    )

    max_latency=$(
        printf '%s\n' "${NODE_LATENCIES[@]}" |
        awk '
            NR==1 {
                max=$1
                next
            }
            $1 > max {
                max=$1
            }
            END {
                print max+0
            }
        '
    )


    # ------------------------------------------------------
    # 初始化评分
    # ------------------------------------------------------

    NODE_SCORES=()

    local speed_score
    local latency_score
    local region_score
    local carrier_score
    local final_score

    local carrier_lower


    # ------------------------------------------------------
    # 开始计算
    # ------------------------------------------------------

    for ((i=0; i<count; i++)); do

        speed="${NODE_SPEEDS[$i]}"
        latency="${NODE_LATENCIES[$i]}"


        # ==================================================
        # Speed Score
        # 速度越高越好
        # ==================================================

        if awk \
            -v min="$min_speed" \
            -v max="$max_speed" \
            'BEGIN {
                exit !(max > min)
            }'
        then

            speed_score=$(
                awk \
                    -v min="$min_speed" \
                    -v max="$max_speed" \
                    -v value="$speed" \
                    'BEGIN {
                        score=((value-min)/(max-min))*100

                        if (score < 0)
                            score=0

                        if (score > 100)
                            score=100

                        printf "%.4f", score
                    }'
            )

        else

            # 所有节点速度相同
            speed_score="100"

        fi


        # ==================================================
        # Latency Score
        # 延迟越低越好
        # ==================================================

        if awk \
            -v min="$min_latency" \
            -v max="$max_latency" \
            'BEGIN {
                exit !(max > min)
            }'
        then

            latency_score=$(
                awk \
                    -v min="$min_latency" \
                    -v max="$max_latency" \
                    -v value="$latency" \
                    'BEGIN {
                        score=((max-value)/(max-min))*100

                        if (score < 0)
                            score=0

                        if (score > 100)
                            score=100

                        printf "%.4f", score
                    }'
            )

        else

            # 所有节点延迟相同
            latency_score="100"

        fi


        # ==================================================
        # Region Score
        #
        # get_api_nodes() 已经进行了地区过滤：
        #
        # SG -> SIN
        # JP -> NRT
        #
        # 所以当前节点全部属于目标地区。
        # ==================================================

        if [[ "${NODE_REGIONS[$i]:-}" == "$API_REGION" ]]; then
            region_score="100"
        else
            region_score="0"
        fi


        # ==================================================
        # Carrier Score
        # ==================================================

        carrier_score="0"

        carrier_lower=$(
            printf '%s' "${NODE_CARRIERS[$i]:-}" |
            tr '[:upper:]' '[:lower:]'
        )

        local preferred_carrier_lower

        preferred_carrier_lower=$(
            printf '%s' "$PREFERRED_CARRIER" |
            tr '[:upper:]' '[:lower:]'
        )

        if [[ "$carrier_lower" == "$preferred_carrier_lower" ]]; then
            carrier_score="100"
        fi


        # ==================================================
        # 综合评分
        #
        # Speed    50%
        # Latency  30%
        # Region   15%
        # Carrier   5%
        # ==================================================

        final_score=$(
			awk \
				-v speed="$speed_score" \
				-v latency="$latency_score" \
				-v region="$region_score" \
				-v carrier="$carrier_score" \
				-v sw="$SPEED_WEIGHT" \
				-v lw="$LATENCY_WEIGHT" \
				-v rw="$REGION_WEIGHT" \
				-v cw="$CARRIER_WEIGHT" \
				'BEGIN {
					score = speed * sw / 100 + latency * lw / 100 + region * rw / 100 + carrier * cw / 100
					printf "%.4f", score
				}'
		)


        NODE_SCORES[$i]="$final_score"

    done


    log INFO \
        "[$TARGET_REGION] 评分完成：Speed=${SPEED_WEIGHT}% Latency=${LATENCY_WEIGHT}% Region=${REGION_WEIGHT}% Carrier=${CARRIER_WEIGHT}%"

    return 0
}

# ==========================================================
# 节点排序
# ==========================================================

sort_nodes_by_score() {

    local TARGET_REGION="$1"


    calculate_scores "$TARGET_REGION" || return 1


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


    while IFS=$'\t' read -r \
        SCORE \
        IP \
        SPEED \
        LATENCY \
        REGION \
        TIME \
        CARRIER
    do

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
# 获取指定地区优选 IP
#
# 最终：
#
# IPS
#
# 为当前地区独立 IP 池
# ==========================================================

get_preferred_ips() {

    local TARGET_REGION="$1"


    log INFO "[$TARGET_REGION] 获取优选 IP..."


    if ! get_api_nodes "$TARGET_REGION"; then

        return 1
    fi


    if ! sort_nodes_by_score "$TARGET_REGION"; then

        return 1
    fi


    IPS=("${SORTED_IPS[@]}")


    log INFO \
        "[$TARGET_REGION] 综合评分排序完成，共 ${#IPS[@]} 个 IP"


    local i


    for ((i=0; i<${#SORTED_IPS[@]}; i++)); do

        log INFO \
            "[$TARGET_REGION] IP[$((i+1))]：${SORTED_IPS[$i]} speed=${SORTED_SPEEDS[$i]} latency=${SORTED_LATENCIES[$i]} region=${SORTED_REGIONS[$i]} carrier=${SORTED_CARRIERS[$i]} score=${SORTED_SCORES[$i]}"

    done


    return 0
}


# ==========================================================
# 获取 Cloudflare DNS A 记录
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

    SUCCESS=$(
        echo "$RESPONSE" |
        jq -r '.success // false'
    )


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
# IP 集合比较
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

    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')


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

    SUCCESS=$(
        echo "$RESPONSE" |
        jq -r '.success // false'
    )


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
# 生成当前地区目标 IP
#
# 注意：
# 这里的偏移只根据当前地区的 DOMAINS 计算
#
# SG 不会使用 JP 的偏移
# JP 不会使用 SG 的偏移
# ==========================================================

generate_target_ips() {

    local DOMAIN_INDEX="$1"
    local IP_COUNT="$2"


    TARGET_IPS=()


    local TOTAL_IPS="${#IPS[@]}"


    if [ "$TOTAL_IPS" -eq 0 ]; then

        return 1
    fi


    local GLOBAL_OFFSET=0

    local K


    for ((K=0; K<DOMAIN_INDEX; K++)); do

        GLOBAL_OFFSET=$(
            (
                echo "$GLOBAL_OFFSET + ${DOMAIN_IP_COUNTS[$K]}"
            ) |
            bc
        )

    done


    local J
    local IP_INDEX


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

    local TARGET_REGION="$1"
    local DOMAIN="$2"
    local DOMAIN_INDEX="$3"
    local IP_COUNT="$4"


    separator

    log INFO "[$TARGET_REGION] 处理：$DOMAIN"

    log INFO "[$TARGET_REGION] IP 数量：$IP_COUNT"


    # ------------------------------------------------------
    # 生成目标 IP
    # ------------------------------------------------------

    if ! generate_target_ips \
        "$DOMAIN_INDEX" \
        "$IP_COUNT"
    then

        log ERROR "[$TARGET_REGION] $DOMAIN：无法生成目标 IP"

        return 1
    fi


    log INFO \
        "[$TARGET_REGION] $DOMAIN 目标 IP：${TARGET_IPS[*]}"


    # ------------------------------------------------------
    # 获取当前 DNS
    # ------------------------------------------------------

    local RECORD_DATA


    if ! RECORD_DATA=$(get_dns_records "$DOMAIN"); then

        log ERROR \
            "[$TARGET_REGION] $DOMAIN：无法读取 Cloudflare DNS"

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
    # 比较 IP
    # ------------------------------------------------------

    local TARGET_TEXT


    TARGET_TEXT=$(
        printf '%s\n' "${TARGET_IPS[@]}"
    )


    if ips_equal "$CURRENT_IPS" "$TARGET_TEXT"; then

        log INFO \
            "[$TARGET_REGION] $DOMAIN：IP 未变化，跳过"

        return 0
    fi


    if [ -n "$CURRENT_IPS" ]; then

        log INFO \
            "[$TARGET_REGION] $DOMAIN 当前 IP：${CURRENT_IPS//$'\n'/ }"

    else

        log INFO \
            "[$TARGET_REGION] $DOMAIN 当前 IP：无"

    fi


    log INFO \
        "[$TARGET_REGION] $DOMAIN 目标 IP：${TARGET_IPS[*]}"


    # ------------------------------------------------------
    # 先创建新记录
    # ------------------------------------------------------

    CREATED_IPS=()

    local CREATE_FAILED=0


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

        log ERROR \
            "[$TARGET_REGION] $DOMAIN：新记录创建失败"

        log ERROR \
            "[$TARGET_REGION] $DOMAIN：保留原有记录，不删除"


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
                "$RECORD_ID"
            then

                DELETE_FAILED=1

            fi

        done <<< "$CURRENT_IDS"

    fi


    if [ "$DELETE_FAILED" -eq 1 ]; then

        log ERROR \
            "[$TARGET_REGION] $DOMAIN：部分旧记录删除失败"

        return 1
    fi


    log INFO \
        "[$TARGET_REGION] $DOMAIN：更新成功"

    return 0
}


# ==========================================================
# 更新指定地区全部域名
#
# 参数：
#   $1 = SG / JP
# ==========================================================

run_region_update() {

    local TARGET_REGION="$1"


    load_domains "$TARGET_REGION"


    local TOTAL="${#DOMAINS[@]}"


    if [ "$TOTAL" -eq 0 ]; then

        log INFO \
            "[$TARGET_REGION] 没有配置域名，跳过"

        return 0
    fi


    log INFO \
        "[$TARGET_REGION] 开始处理 $TOTAL 个域名"


    # ------------------------------------------------------
    # 获取当前地区 IP 池
    # ------------------------------------------------------

    if ! get_preferred_ips "$TARGET_REGION"; then

        log ERROR \
            "[$TARGET_REGION] 获取优选 IP 失败"

        return 1
    fi


    log INFO \
        "[$TARGET_REGION] 当前 IP 池：${IPS[*]}"


    # ------------------------------------------------------
    # 处理域名
    # ------------------------------------------------------

    local SUCCESS=0
    local FAILED=0


    local i


    for ((i=0; i<TOTAL; i++)); do

        if process_domain \
            "$TARGET_REGION" \
            "${DOMAINS[$i]}" \
            "$i" \
            "${DOMAIN_IP_COUNTS[$i]}"
        then

            ((SUCCESS++))

        else

            ((FAILED++))

        fi


        sleep 0.5

    done


    separator

    log INFO "[$TARGET_REGION] 任务完成"

    log INFO "[$TARGET_REGION] 域名总数：$TOTAL"

    log INFO "[$TARGET_REGION] 成功：$SUCCESS"

    log INFO "[$TARGET_REGION] 失败：$FAILED"

    separator


    if [ "$FAILED" -gt 0 ]; then

        return 1
    fi


    return 0
}


# ==========================================================
# Cron 模式
# ==========================================================

cron_mode() {

    log INFO "=========================================="
    log INFO "Cloudflare SG / JP 自动任务启动"
    log INFO "=========================================="


    local SG_RESULT=0
    local JP_RESULT=0


    # ------------------------------------------------------
    # SG
    # ------------------------------------------------------

    log INFO "开始执行 SG 地区"


    if ! run_region_update "SG"; then

        SG_RESULT=1

    fi


    # ------------------------------------------------------
    # JP
    # ------------------------------------------------------

    log INFO "开始执行 JP 地区"


    if ! run_region_update "JP"; then

        JP_RESULT=1

    fi


    # ------------------------------------------------------
    # 最终结果
    # ------------------------------------------------------

    separator

    log INFO "全部地区任务完成"

    log INFO "SG：$([ "$SG_RESULT" -eq 0 ] && echo "成功" || echo "失败")"

    log INFO "JP：$([ "$JP_RESULT" -eq 0 ] && echo "成功" || echo "失败")"

    separator


    if [ "$SG_RESULT" -ne 0 ] ||
       [ "$JP_RESULT" -ne 0 ]; then

        return 1
    fi


    return 0
}


# ==========================================================
# 显示指定地区域名
# ==========================================================

show_domains() {

    local TARGET_REGION="$1"


    load_domains "$TARGET_REGION"


    clear


    separator

    echo " $TARGET_REGION 域名列表"

    separator

    echo


    local CONFIG_FILE


    if [ "$TARGET_REGION" = "SG" ]; then

        CONFIG_FILE="$SG_DOMAIN_CONFIG"

    else

        CONFIG_FILE="$JP_DOMAIN_CONFIG"

    fi


    echo "配置文件：$CONFIG_FILE"

    echo "域名数量：${#DOMAINS[@]}"

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "当前没有配置域名。"

        echo

        return
    fi


    printf "%-5s %-45s %-10s\n" \
        "编号" \
        "域名" \
        "IP数量"


    echo "----------------------------------------------------------"


    local i


    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        printf "%-5s %-45s %-10s\n" \
            "$((i+1))" \
            "${DOMAINS[$i]}" \
            "${DOMAIN_IP_COUNTS[$i]}"

    done


    echo
}


# ==========================================================
# 查看两个地区域名
# ==========================================================

show_all_domains() {

    clear


    separator

    echo " SG / JP 域名配置"

    separator

    echo


    show_domains "SG"

    show_domains "JP"
}


# ==========================================================
# 添加域名
# ==========================================================

add_domain() {

    local TARGET_REGION="$1"


    load_domains "$TARGET_REGION"


    echo

    separator

    echo " 添加 $TARGET_REGION 域名"

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


    [ -z "$NEW_IP_COUNT" ] &&
        NEW_IP_COUNT="$DEFAULT_MAX_IPS"


    if ! [[ "$NEW_IP_COUNT" =~ ^[0-9]+$ ]] ||
       [ "$NEW_IP_COUNT" -lt 1 ]; then

        echo

        echo "[ERROR] IP 数量必须是大于 0 的整数"

        echo

        return
    fi


    DOMAINS+=("$NEW_DOMAIN")

    DOMAIN_IP_COUNTS+=("$NEW_IP_COUNT")


    save_domains "$TARGET_REGION"


    echo

    echo "[OK] [$TARGET_REGION] 域名添加成功：$NEW_DOMAIN"

    echo "[OK] IP 数量：$NEW_IP_COUNT"

    echo
}


# ==========================================================
# 批量添加域名
# ==========================================================

add_multiple_domains() {

    local TARGET_REGION="$1"


    load_domains "$TARGET_REGION"


    echo

    separator

    echo " 批量添加 $TARGET_REGION 域名"

    separator

    echo


    echo "多个域名使用空格分隔。"

    echo


    read -rp "域名： " DOMAIN_INPUT


    if [ -z "$DOMAIN_INPUT" ]; then

        echo "[ERROR] 没有输入域名"

        return
    fi


    read -rp \
        "这些域名统一挂几个 IP？[默认 $DEFAULT_MAX_IPS]: " \
        INPUT_COUNT


    [ -z "$INPUT_COUNT" ] &&
        INPUT_COUNT="$DEFAULT_MAX_IPS"


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


        echo "[OK] [$TARGET_REGION] 添加：$DOMAIN"

        ((ADD_COUNT++))

    done


    if [ "$ADD_COUNT" -gt 0 ]; then

        save_domains "$TARGET_REGION"

    fi


    echo

    echo "成功添加 $ADD_COUNT 个域名。"

    echo
}


# ==========================================================
# 删除域名
# ==========================================================

delete_domain() {

    local TARGET_REGION="$1"


    load_domains "$TARGET_REGION"


    echo

    separator

    echo " 删除 $TARGET_REGION 域名"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "没有任何域名。"

        return
    fi


    show_domains "$TARGET_REGION"


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


    save_domains "$TARGET_REGION"


    echo

    echo "[OK] 已从 $TARGET_REGION 自动任务列表删除：$DOMAIN"

    echo

    echo "这里只是停止以后 Cron 自动管理该域名。"

    echo "不会删除 Cloudflare 中现有的 DNS 记录。"

    echo
}


# ==========================================================
# 修改 IP 数量
# ==========================================================

change_ip_count() {

    local TARGET_REGION="$1"


    load_domains "$TARGET_REGION"


    echo

    separator

    echo " 修改 $TARGET_REGION IP 数量"

    separator

    echo


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo "没有任何域名。"

        return
    fi


    show_domains "$TARGET_REGION"


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


    save_domains "$TARGET_REGION"


    echo

    echo "[OK] 修改成功"

    echo "地区：$TARGET_REGION"

    echo "域名：$DOMAIN"

    echo "IP 数量：$OLD_COUNT -> $NEW_COUNT"

    echo
}


# ==========================================================
# 手动立即执行指定地区
# ==========================================================

run_update_region() {

    local TARGET_REGION="$1"


    if ! check_cloudflare_api; then

        return 1
    fi


    load_domains "$TARGET_REGION"


    if [ "${#DOMAINS[@]}" -eq 0 ]; then

        echo

        echo "[$TARGET_REGION] 当前没有配置域名。"

        echo

        return 0
    fi


    if ! get_preferred_ips "$TARGET_REGION"; then

        return 1
    fi


    echo

    separator

    echo "准备更新 $TARGET_REGION"

    echo "域名数量：${#DOMAINS[@]}"

    echo "IP 池：${IPS[*]}"

    separator

    echo


    echo "评分策略："

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


    run_region_update "$TARGET_REGION"
}


# ==========================================================
# 手动立即执行 SG + JP
# ==========================================================

run_update_all() {

    if ! check_cloudflare_api; then

        return 1
    fi


    echo

    separator

    echo "准备更新 SG + JP"

    separator

    echo


    read -rp "确认执行全部地区？[y/N]: " CONFIRM


    case "$CONFIRM" in

        y|Y|yes|YES)
            ;;

        *)
            echo "已取消。"
            return
            ;;

    esac


    cron_mode
}


# ==========================================================
# 查看指定地区 API Top10
# ==========================================================

show_api_top10() {

    local TARGET_REGION="$1"


    clear


    separator

    echo " $TARGET_REGION API 当前 Top10"

    separator

    echo


    if ! get_api_nodes "$TARGET_REGION"; then

        echo

        echo "[ERROR] 获取 API 数据失败"

        echo

        return 1
    fi


    if ! sort_nodes_by_score "$TARGET_REGION"; then

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

    echo "API 地区：$TARGET_REGION"

    echo "评分策略："

    echo "  Speed   ${SPEED_WEIGHT}%"

    echo "  Latency ${LATENCY_WEIGHT}%"

    echo "  Region  ${REGION_WEIGHT}%"

    echo "  Carrier ${CARRIER_WEIGHT}%"

    echo
}


# ==========================================================
# 查看所有域名当前 IP
# ==========================================================

show_all_domain_ips() {

    clear


    separator

    echo " SG / JP 域名当前 IP"

    separator

    echo


    local TARGET_REGION

    local i

    local DOMAIN

    local CONFIG_COUNT

    local RECORD_DATA

    local CURRENT_IPS

    local IP_DISPLAY


    for TARGET_REGION in SG JP; do

        load_domains "$TARGET_REGION"


        echo

        echo "================ $TARGET_REGION ================"

        echo


        if [ "${#DOMAINS[@]}" -eq 0 ]; then

            echo "没有配置域名。"

            continue

        fi


        printf "%-5s %-40s %-10s %s\n" \
            "编号" \
            "域名" \
            "IP数量" \
            "当前 IP"


        echo "------------------------------------------------------------------------------------------"


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

    done


    echo

    separator

    echo
}


# ==========================================================
# 菜单
# ==========================================================

interactive_menu() {

    while true; do

        clear


        separator

        echo " Cloudflare 优选 IP 自动分配工具"

        separator

        echo


        load_domains "SG"
        local SG_COUNT="${#DOMAINS[@]}"


        load_domains "JP"
        local JP_COUNT="${#DOMAINS[@]}"


        echo "SG 域名数量：$SG_COUNT"

        echo "JP 域名数量：$JP_COUNT"

        echo


        echo "1. 查看 SG 域名"

        echo "2. 查看 JP 域名"

        echo "3. 添加 SG 域名"

        echo "4. 添加 JP 域名"

        echo "5. 批量添加 SG 域名"

        echo "6. 批量添加 JP 域名"

        echo "7. 删除 SG 域名"

        echo "8. 删除 JP 域名"

        echo "9. 修改 SG IP 数量"

        echo "10. 修改 JP IP 数量"

        echo

        echo "────────── DNS 更新 ──────────"

        echo

        echo "11. 立即更新 SG"

        echo "12. 立即更新 JP"

        echo "13. 立即更新 SG + JP"

        echo "14. 查看 SG / JP 当前 DNS IP"

        echo

        echo "────────── IP 优选 ──────────"

        echo

        echo "20. 查看 SG API Top10"

        echo "21. 查看 JP API Top10"

        echo

        echo "0. 退出"

        echo


        read -rp "请选择： " MENU


        case "$MENU" in

            1)

                show_domains "SG"

                read -rp "按回车继续..." _

                ;;

            2)

                show_domains "JP"

                read -rp "按回车继续..." _

                ;;

            3)

                add_domain "SG"

                read -rp "按回车继续..." _

                ;;

            4)

                add_domain "JP"

                read -rp "按回车继续..." _

                ;;

            5)

                add_multiple_domains "SG"

                read -rp "按回车继续..." _

                ;;

            6)

                add_multiple_domains "JP"

                read -rp "按回车继续..." _

                ;;

            7)

                delete_domain "SG"

                read -rp "按回车继续..." _

                ;;

            8)

                delete_domain "JP"

                read -rp "按回车继续..." _

                ;;

            9)

                change_ip_count "SG"

                read -rp "按回车继续..." _

                ;;

            10)

                change_ip_count "JP"

                read -rp "按回车继续..." _

                ;;

            11)

                run_update_region "SG"

                read -rp "按回车继续..." _

                ;;

            12)

                run_update_region "JP"

                read -rp "按回车继续..." _

                ;;

            13)

                run_update_all

                read -rp "按回车继续..." _

                ;;

            14)

                show_all_domain_ips

                read -rp "按回车继续..." _

                ;;

            20)

                show_api_top10 "SG"

                read -rp "按回车继续..." _

                ;;

            21)

                show_api_top10 "JP"

                read -rp "按回车继续..." _

                ;;

            0)

                echo

                echo "退出。"

                exit 0

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
# Cron
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
