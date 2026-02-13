#!/usr/bin/env bash

set -euo pipefail

# ---------- 初始化 ----------
readonly SCRIPT_NAME="WiFi 管理器 (NetworkManager)"

# 颜色（若终端支持）
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

# ---------- 公用函数 ----------
check_nm() {
    if ! systemctl is-active --quiet NetworkManager; then
        echo "${RED}错误：NetworkManager 未运行。${RESET}" >&2
        exit 1
    fi
    if ! command -v nmcli >/dev/null 2>&1; then
        echo "${RED}错误：未找到 nmcli 命令。${RESET}" >&2
        exit 1
    fi
}

# 获取已保存的所有 WiFi SSID（返回数组）
get_saved_wifi_ssids() {
    local list
    mapfile -t list < <(
        nmcli -t -f TYPE,NAME connection show 2>/dev/null |
        grep '^802-11-wireless:' 2>/dev/null | cut -d: -f2 || true
    )
    printf '%s\n' "${list[@]}"
}

# 获取当前连接的 WiFi SSID（若已连接）
get_current_wifi_ssid() {
    local active_conn
    active_conn=$(
        nmcli -t -f DEVICE,TYPE,CONNECTION device status 2>/dev/null |
        grep -E ":wifi:" | head -1 || true
    )
    if [[ -n "$active_conn" ]]; then
        IFS=':' read -r _ _ conn <<< "$active_conn"
        echo "$conn"
    else
        echo ""
    fi
}

# ---------- 功能模块 ----------
show_status() {
    echo "${BOLD}${BLUE}========== 当前网络状态 ==========${RESET}"
    local wifi_status
    wifi_status=$(nmcli radio wifi)
    if [[ "$wifi_status" == "enabled" ]]; then
        echo "WiFi 开关: ${GREEN}已启用${RESET}"
    else
        echo "WiFi 开关: ${RED}已禁用${RESET}"
    fi

    local current_ssid
    current_ssid=$(get_current_wifi_ssid)
    if [[ -n "$current_ssid" ]]; then
        echo "已连接 WiFi: ${GREEN}$current_ssid${RESET}"
        # 显示 IP 地址
        local dev
        dev=$(
            nmcli -t -f DEVICE,TYPE device status 2>/dev/null |
            grep -E ":wifi:" | head -1 | cut -d: -f1 || true
        )
        if [[ -n "$dev" ]]; then
            nmcli -f IP4.ADDRESS device show "$dev" 2>/dev/null |
                awk '/IP4.ADDRESS/ {print $2; exit}'
        fi
    else
        echo "已连接 WiFi: ${YELLOW}无${RESET}"
    fi
    echo "${BLUE}=====================================${RESET}\n"
}

list_saved_wifi() {
    echo "${BOLD}已保存的 WiFi 网络:${RESET}"
    local current_ssid
    current_ssid=$(get_current_wifi_ssid)

    while true; do
        local ssids
        mapfile -t ssids < <(get_saved_wifi_ssids)
        if [[ ${#ssids[@]} -eq 0 ]]; then
            echo "${YELLOW}没有已保存的 WiFi 连接。${RESET}"
            return
        fi

        # 显示列表（对齐）
        printf "  %-4s %-30s %s\n" "序号" "SSID" "状态"
        local i=1
        for ssid in "${ssids[@]}"; do
            local status=""
            if [[ "$ssid" == "$current_ssid" ]]; then
                status="${GREEN}[已连接]${RESET}"
            fi
            printf "  %-4d %-30s %s\n" "$i" "$ssid" "$status"
            ((i++))
        done
        echo "  0) 返回上级菜单"

        local choice
        read -p "请输入序号连接 WiFi (0返回): " choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
            echo "${RED}输入无效，请输入数字。${RESET}"
            continue
        fi
        if (( choice == 0 )); then
            return
        elif (( choice <= ${#ssids[@]} )); then
            local target="${ssids[$((choice-1))]}"
            echo "正在连接 $target ..."
            if nmcli connection up id "$target" >/dev/null 2>&1; then
                echo "${GREEN}已成功连接到 $target${RESET}"
                current_ssid=$(get_current_wifi_ssid)   # 更新连接状态
            else
                echo "${RED}连接失败，请检查网络状态。${RESET}" >&2
            fi
        else
            echo "${RED}编号超出范围。${RESET}"
        fi
    done
}

forget_wifi_menu() {
    local ssids choice target
    mapfile -t ssids < <(get_saved_wifi_ssids)
    if [[ ${#ssids[@]} -eq 0 ]]; then
        echo "${RED}没有可忘记的已保存 WiFi。${RESET}"
        return
    fi

    while true; do
        echo "${BOLD}${YELLOW}--- 选择要忘记的 WiFi ---${RESET}"
        local i=1
        for ssid in "${ssids[@]}"; do
            echo "  $i) $ssid"
            ((i++))
        done
        echo "  0) 返回上级菜单"

        read -p "请输入编号: " choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
            echo "${RED}输入无效，请重试。${RESET}"
            continue
        fi
        if (( choice == 0 )); then
            return
        elif (( choice <= ${#ssids[@]} )); then
            target="${ssids[$((choice-1))]}"
            echo "正在忘记 WiFi: $target"
            if nmcli connection delete id "$target" >/dev/null 2>&1; then
                echo "${GREEN}成功忘记 WiFi: $target${RESET}"
                # 删除后更新列表
                mapfile -t ssids < <(get_saved_wifi_ssids)
                if [[ ${#ssids[@]} -eq 0 ]]; then
                    echo "${YELLOW}已无已保存 WiFi。${RESET}"
                    return
                fi
            else
                echo "${RED}操作失败，请检查权限。${RESET}" >&2
            fi
        else
            echo "${RED}编号超出范围。${RESET}"
        fi
    done
}

connect_new_wifi() {
    echo "${BOLD}${YELLOW}--- 扫描附近 WiFi 网络 ---${RESET}"
    
    # 触发重新扫描（异步，不等待完成）
    if ! nmcli device wifi rescan >/dev/null 2>&1; then
        echo "${YELLOW}警告：无法触发WiFi扫描，将使用缓存列表。${RESET}" >&2
    fi
    # 等待扫描完成（可根据环境调整等待时间）
    sleep 2

    local tmpfile scan_result
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' RETURN

    # 获取当前可见的WiFi列表（不触发新扫描）
    if ! nmcli -t -f SSID,SIGNAL,SECURITY device wifi list > "$tmpfile" 2>/dev/null; then
        echo "${RED}获取WiFi列表失败，请检查无线网卡状态。${RESET}" >&2
        return
    fi

    # 解析、去重、按信号排序（保留最终版的优化逻辑）
    mapfile -t scan_result < <(
        awk -F: '
            $1 != "" && $1 != "--" {
                ssid = $1; sig = $2; sec = $3;
                if (!(ssid in seen) || seen_sig[ssid] < sig) {
                    seen[ssid] = 1;
                    seen_sig[ssid] = sig;
                    store[ssid] = sig ":" sec;
                }
            }
            END {
                for (s in store) print store[s] ":" s;
            }
        ' "$tmpfile" | sort -t: -k1,1nr
    )

    if [[ ${#scan_result[@]} -eq 0 ]]; then
        echo "${RED}未扫描到任何 WiFi 网络。${RESET}"
        return
    fi

    # 显示网络列表（保留最终版的美观格式）
    echo "可用的 WiFi 网络:"
    local i=1
    local -a ssid_list
    local -a sec_list
    local line sig_pct sec ssid sig_bar
    for line in "${scan_result[@]}"; do
        IFS=':' read -r sig_pct sec ssid <<< "$line"
        ssid_list+=("$ssid")
        sec_list+=("$sec")

        local bar_len=$(( sig_pct / 20 ))
        local bar_full="▉▉▉▉▉"
        sig_bar="${bar_full:0:$bar_len}"
        printf -v sig_bar "%-5s" "$sig_bar"

        local sec_tag
        if [[ "$sec" == "--" || -z "$sec" ]]; then
            sec_tag="${GREEN}[开放]${RESET}"
        else
            sec_tag="${YELLOW}[加密]${RESET}"
        fi

        printf "  %2d) %-30s %s %3d%% %s\n" \
            "$i" "$ssid" "$sig_bar" "$sig_pct" "$sec_tag"
        ((i++))
    done
    echo "  0) 返回上级菜单"

    # 用户选择、连接逻辑（与最终版完全一致）
    local choice selected_ssid selected_sec
    while true; do
        read -p "请输入编号选择 WiFi: " choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
            echo "${RED}请输入数字。${RESET}"
            continue
        fi
        if (( choice == 0 )); then
            return
        elif (( choice <= ${#ssid_list[@]} )); then
            selected_ssid="${ssid_list[$((choice-1))]}"
            selected_sec="${sec_list[$((choice-1))]}"
            break
        else
            echo "${RED}编号超出范围。${RESET}"
        fi
    done

    # 检查是否已保存
    local saved_ssids
    mapfile -t saved_ssids < <(get_saved_wifi_ssids)
    local is_saved=false
    for s in "${saved_ssids[@]}"; do
        if [[ "$s" == "$selected_ssid" ]]; then
            is_saved=true
            break
        fi
    done

    if $is_saved; then
        echo "WiFi '${selected_ssid}' 已保存，正在连接..."
        if nmcli connection up id "$selected_ssid" >/dev/null 2>&1; then
            echo "${GREEN}已连接到 $selected_ssid${RESET}"
        else
            echo "${RED}连接失败。${RESET}" >&2
        fi
        return
    fi

    # 新网络，需要密码
    local password password_confirm
    if [[ "$selected_sec" != "--" && -n "$selected_sec" ]]; then
        while true; do
            read -p "请输入密码: " -s password
            echo
            if [[ -z "$password" ]]; then
                echo "${RED}密码不能为空。${RESET}"
                continue
            fi
            read -p "请再次输入密码: " -s password_confirm
            echo
            if [[ "$password" != "$password_confirm" ]]; then
                echo "${RED}两次密码不一致，请重新输入。${RESET}"
            else
                break
            fi
        done
        if nmcli device wifi connect "$selected_ssid" password "$password" >/dev/null 2>&1; then
            echo "${GREEN}成功连接到 $selected_ssid${RESET}"
        else
            echo "${RED}连接失败，请检查密码或信号。${RESET}" >&2
        fi
    else
        # 开放网络
        if nmcli device wifi connect "$selected_ssid" >/dev/null 2>&1; then
            echo "${GREEN}成功连接到 $selected_ssid${RESET}"
        else
            echo "${RED}连接失败。${RESET}" >&2
        fi
    fi
}

toggle_wifi() {
    local status
    status=$(nmcli radio wifi)
    if [[ "$status" == "enabled" ]]; then
        echo "正在关闭 WiFi..."
        nmcli radio wifi off
        echo "${YELLOW}WiFi 已关闭${RESET}"
    else
        echo "正在开启 WiFi..."
        nmcli radio wifi on
        echo "${GREEN}WiFi 已开启${RESET}"
    fi
}

main_menu() {
    local PS3="${BOLD}请选择操作 (1-5): ${RESET}"
    local options=(
        "查看已保存的 WiFi"
        "连接新 WiFi"
        "忘记已保存的 WiFi"
        "开关 WiFi"
        "退出"
    )
    while true; do
        clear                     # 每次进入主菜单前清屏，保持整洁
        show_status
        select opt in "${options[@]}"; do
            case $REPLY in
                1) list_saved_wifi; break ;;
                2) connect_new_wifi; break ;;
                3) forget_wifi_menu; break ;;
                4) toggle_wifi; break ;;
                5) echo "退出程序。"; exit 0 ;;
                *) echo "${RED}无效选择，请输入 1-5。${RESET}" ;;
            esac
        done
        echo -e "\n${BLUE}按任意键返回主菜单...${RESET}"
        read -n 1 -s -r
        # 循环重新开始，会先执行 clear
    done
}

# ---------- 程序入口 ----------
check_nm
main_menu