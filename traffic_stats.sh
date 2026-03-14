#!/bin/bash

# --- 配置区域 ---
# 排除掉不需要统计的接口（如 lo, docker0, tailscale0 等）
EXCLUDE_IFACES="lo|docker|tailscale|veth|br-"
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
# 所有的记录都存在这一个文件里
DB_FILE="$SCRIPT_DIR/traffic_stats.txt"

# --- 核心工具函数 ---

# 初始化数据库文件
init_db() {
    if [ ! -f "$DB_FILE" ]; then
        echo "# --- 脚本配置数据 (请勿手动修改) ---" > "$DB_FILE"
        echo "RESET_DAY=1" >> "$DB_FILE"
        echo "CUR_RX=0" >> "$DB_FILE"
        echo "CUR_TX=0" >> "$DB_FILE"
        echo "LAST_HW_RX=0" >> "$DB_FILE"
        echo "LAST_HW_TX=0" >> "$DB_FILE"
        echo "START_DATE=$(date +%Y-%m-%d)" >> "$DB_FILE"
        echo -e "\n# --- 人类直观阅读区 ---" >> "$DB_FILE"
    fi
}

# 提取 Key-Value 数据
get_val() {
    grep "^$1=" "$DB_FILE" | cut -d= -f2
}

# 格式化流量单位 (支持 MB, GB, TB)
format_size() {
    awk -v n=$1 'BEGIN {
        if (n > 1099511627776) printf "%.2f TB", n/1099511627776
        else if (n > 1073741824) printf "%.2f GB", n/1073741824
        else printf "%.2f MB", n/1048576
    }'
}

# 获取所有物理网卡的硬件流量总和
get_hw_realtime() {
    local rx_sum=0 tx_sum=0
    for iface in /sys/class/net/*; do
        ifname=$(basename "$iface")
        if [[ ! "$ifname" =~ $EXCLUDE_IFACES ]]; then
            rx_sum=$((rx_sum + $(cat "$iface/statistics/rx_bytes" 2>/dev/null || echo 0)))
            tx_sum=$((tx_sum + $(cat "$iface/statistics/tx_bytes" 2>/dev/null || echo 0)))
        fi
    done
    echo "$rx_sum $tx_sum"
}

# 自动推算上一个重置日的具体日期
get_start_date() {
    local r_day=$1
    local cur_y=$(date +%Y)
    local cur_m=$(date +%m)
    local cur_d=$(date +%d)

    if [ "$cur_d" -ge "$r_day" ]; then
        # 本月已过重置日
        printf "%04d-%02d-%02d" $cur_y $cur_m $r_day
    else
        # 还没到重置日，回溯到上个月
        date -d "$cur_y-$cur_m-$cur_d -1 month" +%Y-%m-$r_day 2>/dev/null || \
        date -v-1m +%Y-%m-$r_day
    fi
}

# --- 核心业务逻辑 ---

update_stats() {
    init_db
    local reset_day=$(get_val "RESET_DAY")
    local cur_acc_rx=$(get_val "CUR_RX")
    local cur_acc_tx=$(get_val "CUR_TX")
    local last_hw_rx=$(get_val "LAST_HW_RX")
    local last_hw_tx=$(get_val "LAST_HW_TX")
    local start_date=$(get_val "START_DATE")

    # 如果是首次运行或重置日变更，重新校验起始日期
    if [ "$start_date" == "$(date +%Y-%m-%d)" ] || [ -z "$start_date" ]; then
        start_date=$(get_start_date "$reset_day")
    fi

    # 计算预期的结束日期（下一个重置日）
    local end_date=$(date -d "$start_date +1 month" +%Y-%m-%d 2>/dev/null || \
                    date -v+1m -j -f "%Y-%m-%d" "$start_date" +%Y-%m-%d)

    # 1. 检查是否到达重置日（当天清零）
    if [ "$(date +%d)" -eq "$reset_day" ]; then
        if [ ! -f "/tmp/traffic_reset.flag" ]; then
            cur_acc_rx=0; cur_acc_tx=0
            start_date=$(date +%Y-%m-%d)
            touch "/tmp/traffic_reset.flag"
        fi
    else
        rm -f "/tmp/traffic_reset.flag"
    fi

    # 2. 获取硬件增量并处理重启清零情况
    read hw_now_rx hw_now_tx <<< $(get_hw_realtime)
    local diff_rx=0; local diff_tx=0
    if [ "$hw_now_rx" -lt "$last_hw_rx" ]; then diff_rx=$hw_now_rx; else diff_rx=$((hw_now_rx - last_hw_rx)); fi
    if [ "$hw_now_tx" -lt "$last_hw_tx" ]; then diff_tx=$hw_now_tx; else diff_tx=$((hw_now_tx - last_hw_tx)); fi

    # 3. 更新累计值
    local new_acc_rx=$((cur_acc_rx + diff_rx))
    local new_acc_tx=$((cur_acc_tx + diff_tx))

    # 4. 持久化到文件 (单文件重构)
    cat > "$DB_FILE" <<EOF
# --- 脚本配置数据 (请勿手动修改) ---
RESET_DAY=$reset_day
CUR_RX=$new_acc_rx
CUR_TX=$new_acc_tx
LAST_HW_RX=$hw_now_rx
LAST_HW_TX=$hw_now_tx
START_DATE=$start_date

# --- 人类直观阅读区 ---
# 最后更新时间: $(date "+%Y-%m-%d %H:%M:%S")
# 统计周期: 每月 $reset_day 号重置
$start_date 至 $end_date 的流量情况为：
上行流量 (TX): $(format_size $new_acc_tx)
下行流量 (RX): $(format_size $new_acc_rx)
合计流量:      $(format_size $((new_acc_rx + new_acc_tx)))
EOF
}

setup_cron() {
    local COMMENT="# 每5分钟自动流量统计（此命令由脚本自动添加）："
    local JOB="*/5 * * * * /bin/bash $SCRIPT_PATH cron"
    if crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" >/dev/null 2>&1; then
        echo "提示：Crontab 定时任务已存在，无需重复添加。"
    else
        (crontab -l 2>/dev/null; echo ""; echo "$COMMENT"; echo "$JOB") | crontab -
        echo "SUCCESS: 定时任务已成功添加。"
    fi
}

# --- 菜单界面 ---
clear
if [ "$1" == "cron" ]; then
    update_stats
else
    echo "======================================"
    echo "       Linux 多网卡流量统计助手"
    echo "======================================"
    echo "1) 查看当前流量统计"
    echo "2) 设置每月重置日期 (1-31)"
    echo "3) 添加定时统计任务 (Crontab)"
    echo "q) 退出"
    echo "--------------------------------------"
    read -p "请选择操作 [1-3]: " opt

    case $opt in
        1) update_stats; sed -n '/人类直观阅读区/,$p' "$DB_FILE" ;;
        2) 
            read -p "请输入重置日期 (例如 28): " d
            if [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 1 ] && [ "$d" -le 31 ]; then
                init_db
                # 修改重置日后，强制清空 START_DATE 让脚本下一次运行重算周期
                sed -i "s/RESET_DAY=.*/RESET_DAY=$d/" "$DB_FILE"
                sed -i "s/START_DATE=.*/START_DATE=/" "$DB_FILE"
                echo "设置成功！起始日期将在下次更新时自动对齐。"
            else
                echo "输入无效。"
            fi
            ;;
        3) setup_cron ;;
        *) exit 0 ;;
    esac
fi
