#!/bin/bash

# ==========================================================
# Cloudflare 优选 IP 自动分配工具
#
# 文件：
#   /usr/local/bin/cf-ip-update-distribute.sh
#
# 配置目录：
#   /etc/cf-ip-update/
#
# 域名配置：
#   /etc/cf-ip-update/domains.conf
#
# 日志：
#   /var/log/cf-ip-update-distribute.log
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

CF_API_TOKEN="YvkOMgdfgdgdEhhhdfgdgdgdgubGLm9ksjhFvnWW"

ZONE_ID="e7eb4b0fgdfgfdgdg7f7cd23bfc0"

TTL=60

# false = DNS Only
# true  = Cloudflare Proxy
PROXIED=false


# ==========================================================
# 优选 IP API
# ==========================================================

IP_API="https://ip.164746.xyz/ipTop10.html"


# ==========================================================
# 默认配置
# ==========================================================

DEFAULT_MAX_IPS=3


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


    if [ "${#MISSING[@]}" -gt 0 ]; then

        echo

        echo "[ERROR] 缺少依赖：${MISSING[*]}"

        echo

        echo "Debian / Ubuntu："

        echo

        echo "apt update && apt install -y curl jq gawk grep sed coreutils util-linux"

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


    # 去掉前后空格

    DOMAIN=$(echo "$DOMAIN" | xargs)


    if [ -z "$DOMAIN" ]; then

        return 1

    fi


    # 不允许协议

    if [[ "$DOMAIN" == http://* ]] ||
       [[ "$DOMAIN" == https://* ]]; then

        return 1

    fi


    # 基本域名格式检查

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
# 例如：
#
# jp-vip1-4.awsno.com|3
# jp-vip1-5.awsno.com|3
# sg-vip1-1.awsno.com|2
#
# ==========================================================

load_domains() {

    DOMAINS=()

    DOMAIN_IP_COUNTS=()


    if [ ! -f "$DOMAIN_CONFIG" ]; then

        return 0

    fi


    while IFS='|' read -r DOMAIN IP_COUNT; do

        # 空行
        [ -z "$DOMAIN" ] && continue

        # 注释
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
# 显示 domains.conf 中所有域名的当前 Cloudflare IP
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

    for ((i=0; i<${#DOMAINS[@]}; i++)); do

        DOMAIN="${DOMAINS[$i]}"
        CONFIG_COUNT="${DOMAIN_IP_COUNTS[$i]}"

        # --------------------------------------------------
        # 只查询 domains.conf 中的这个域名
        # --------------------------------------------------

        RECORD_DATA=$(get_dns_records "$DOMAIN" 2>/dev/null)

        if [ $? -ne 0 ]; then

            printf "%-5s %-40s %-10s %s\n" \
                "$((i+1))" \
                "$DOMAIN" \
                "$CONFIG_COUNT" \
                "查询失败"

            continue

        fi

        # --------------------------------------------------
        # 获取当前 A 记录 IP
        # --------------------------------------------------

        CURRENT_IPS=$(
            echo "$RECORD_DATA" |
            cut -d'|' -f2 |
            sed '/^$/d' |
            sort -u
        )

        # --------------------------------------------------
        # 当前没有 A 记录
        # --------------------------------------------------

        if [ -z "$CURRENT_IPS" ]; then

            printf "%-5s %-40s %-10s %s\n" \
                "$((i+1))" \
                "$DOMAIN" \
                "$CONFIG_COUNT" \
                "无 A 记录"

            continue

        fi

        # --------------------------------------------------
        # 转成一行显示
        # --------------------------------------------------

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

    echo "该域名以后会自动被 Cron 处理。"

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


    REAL_INDEX=$((INDEX-1))


    DOMAIN="${DOMAINS[$REAL_INDEX]}"


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

    echo "注意："

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


    REAL_INDEX=$((INDEX-1))


    DOMAIN="${DOMAINS[$REAL_INDEX]}"

    OLD_COUNT="${DOMAIN_IP_COUNTS[$REAL_INDEX]}"


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
# 获取优选 IP
# ==========================================================

get_preferred_ips() {

    log INFO "获取优选 IP..."


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


    mapfile -t IPS < <(

        echo "$RESPONSE" |

        grep -Eo \
            '([0-9]{1,3}\.){3}[0-9]{1,3}' |

        awk '
        {
            split($0, a, ".")

            valid=1

            for(i=1;i<=4;i++) {

                if(a[i] < 0 || a[i] > 255) {

                    valid=0

                }

            }

            if(valid && !seen[$0]++) {

                print $0

            }

        }
        '

    )


    if [ "${#IPS[@]}" -eq 0 ]; then

        log ERROR "没有获取到有效优选 IP"

        return 1

    fi


    log INFO "获取到 ${#IPS[@]} 个优选 IP"


    local INDEX=1


    for IP in "${IPS[@]}"; do

        log INFO "IP[$INDEX]：$IP"

        ((INDEX++))

    done


    return 0

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


    CURRENT_SORTED=$(
        printf '%s\n' "$CURRENT" |
        sed '/^$/d' |
        sort
    )


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
# 不同域名从 IP 列表不同位置开始。
# ==========================================================

generate_target_ips() {

    local DOMAIN_INDEX="$1"
    local IP_COUNT="$2"

    TARGET_IPS=()

    local J
    local IP_INDEX

    for ((J=0; J<IP_COUNT; J++)); do

        IP_INDEX=$(( (DOMAIN_INDEX * IP_COUNT + J) % ${#IPS[@]} ))

        TARGET_IPS+=("${IPS[$IP_INDEX]}")

    done


    # 去重

    local UNIQUE=()

    declare -A SEEN=()


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

    TARGET_TEXT=$(
        printf '%s\n' "${TARGET_IPS[@]}"
    )


    if ips_equal "$CURRENT_IPS" "$TARGET_TEXT"; then

        log INFO "$DOMAIN：IP 未变化，跳过"

        return 0

    fi


    # ------------------------------------------------------
    # IP 变化
    # ------------------------------------------------------

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
    #
    # 保留旧记录
    # ------------------------------------------------------

    if [ "$CREATE_FAILED" -eq 1 ]; then

        log ERROR "$DOMAIN：新记录创建失败"

        log ERROR "$DOMAIN：保留原有记录，不删除"


        # 删除已经创建的新记录

        NEW_DATA=$(get_dns_records "$DOMAIN" 2>/dev/null || true)


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

    DELETE_FAILED=0


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


    # ------------------------------------------------------
    # Cloudflare
    # ------------------------------------------------------

    if ! check_cloudflare_api; then

        return 1

    fi


    # ------------------------------------------------------
    # 获取 IP
    # ------------------------------------------------------

    if ! get_preferred_ips; then

        return 1

    fi


    echo


    separator

    echo "准备更新 ${#DOMAINS[@]} 个域名"

    separator

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
# 实际更新
# ==========================================================

run_update_core() {

    local TOTAL="${#DOMAINS[@]}"

    local SUCCESS=0

    local FAILED=0


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


    # ------------------------------------------------------
    # Cloudflare API
    # ------------------------------------------------------

    if ! check_cloudflare_api; then

        log ERROR "Cloudflare API 检测失败"

        return 1

    fi


    # ------------------------------------------------------
    # 获取 IP
    # ------------------------------------------------------

    if ! get_preferred_ips; then

        log ERROR "获取优选 IP 失败"

        return 1

    fi


    # ------------------------------------------------------
    # 不需要确认
    # ------------------------------------------------------

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

        echo "8. 退出"

        echo


        read -rp "请选择 [1-8]： " MENU


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
# Cron 模式
# ==========================================================

if [ "$MODE" = "cron" ]; then


    # ------------------------------------------------------
    # flock
    #
    # -n = 非阻塞
    #
    # 如果已经有一个任务在执行，
    # 当前任务直接退出。
    # ------------------------------------------------------

    exec 200>"$LOCK_FILE"


    if ! flock -n 200; then

        log INFO "检测到已有任务正在运行，本次 Cron 跳过"

        exit 0

    fi


    # 获得锁

    trap 'flock -u 200' EXIT


    cron_mode

    EXIT_CODE=$?


    exit "$EXIT_CODE"

fi


# ==========================================================
# 手动模式
# ==========================================================

interactive_menu
