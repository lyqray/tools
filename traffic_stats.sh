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
        echo "START_DATE=$(date +%Y-%m-%d)" >> "$DB_FILE"
        echo "INTERVAL_MONTHS=1" >> "$DB_FILE"
        echo "CUR_RX=0" >> "$DB_FILE"
        echo "CUR_TX=0" >> "$DB_FILE"
        echo "LAST_HW_RX=0" >> "$DB_FILE"
        echo "LAST_HW_TX=0" >> "$DB_FILE"
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
            [ -f "$iface/statistics/rx_bytes" ] && rx_sum=$((rx_sum + $(cat "$iface/statistics/rx_bytes")))
            [ -f "$iface/statistics/tx_bytes" ] && tx_sum=$((tx_sum + $(cat "$iface/statistics/tx_bytes")))
        fi
    done
    echo "$rx_sum $tx_sum"
}

# --- 核心修正：手动计算月份加法，不依赖系统 date 的加减功能 ---
get_next_reset_date() {
    local start_date=$1
    local interval=$2

    local y=$(echo $start_date | cut -d- -f1)
    local m=$(echo $start_date | cut -d- -f2 | sed 's/^0//')
    local d=$(echo $start_date | cut -d- -f3)

    # 计算新月份
    local new_m=$((m + interval))
    local new_y=$y

    while [ $new_m -gt 12 ]; do
        new_y=$((new_y + 1))
        new_m=$((new_m - 12))
    done

    # 格式化输出 YYYY-MM-DD
    printf "%04d-%02d-%02d" $new_y $new_m $d
}

# --- 核心业务逻辑 ---

update_stats() {
    init_db
    local start_date=$(get_val "START_DATE")
    local interval=$(get_val "INTERVAL_MONTHS")
    local cur_acc_rx=$(get_val "CUR_RX")
    local cur_acc_tx=$(get_val "CUR_TX")
    local last_hw_rx=$(get_val "LAST_HW_RX")
    local last_hw_tx=$(get_val "LAST_HW_TX")

    local end_date=$(get_next_reset_date "$start_date" "$interval")
    
    # 兼容 BusyBox 的日期比较：转成 YYYYMMDD 数字进行比较
    local today_num=$(date +%Y%m%d)
    local end_num=$(echo $end_date | tr -d '-')

    if [ "$today_num" -ge "$end_num" ]; then
        if [ ! -f "/tmp/traffic_reset.flag" ]; then
            cur_acc_rx=0; cur_acc_tx=0
            start_date="$end_date"
            end_date=$(get_next_reset_date "$start_date" "$interval")
            touch "/tmp/traffic_reset.flag"
        fi
    else
        rm -f "/tmp/traffic_reset.flag"
    fi

    # 提取重置日用于显示
    local r_day=$(echo $start_date | cut -d- -f3 | sed 's/^0//')

    # 计算硬件增量
    read hw_now_rx hw_now_tx <<< $(get_hw_realtime)
    
    if [ "$last_hw_rx" -eq 0 ] && [ "$last_hw_tx" -eq 0 ]; then
        cur_acc_rx=$hw_now_rx
        cur_acc_tx=$hw_now_tx
    else
        local diff_rx=0; local diff_tx=0
        if [ "$hw_now_rx" -lt "$last_hw_rx" ]; then diff_rx=$hw_now_rx; else diff_rx=$((hw_now_rx - last_hw_rx)); fi
        if [ "$hw_now_tx" -lt "$last_hw_tx" ]; then diff_tx=$hw_now_tx; else diff_tx=$((hw_now_tx - last_hw_tx)); fi
        cur_acc_rx=$((cur_acc_rx + diff_rx))
        cur_acc_tx=$((cur_acc_tx + diff_tx))
    fi

    # 写入文件
    cat > "$DB_FILE" <<EOF
# --- 脚本配置数据 (请勿手动修改) ---
START_DATE=$start_date
INTERVAL_MONTHS=$interval
CUR_RX=$cur_acc_rx
CUR_TX=$cur_acc_tx
LAST_HW_RX=$hw_now_rx
LAST_HW_TX=$hw_now_tx

# --- 人类直观阅读区 ---
# 最后更新时间: $(date "+%Y-%m-%d %H:%M:%S")
# 统计周期: 每 $interval 个月 $r_day 号重置一次
$start_date 至 $end_date 的流量情况为：
上行流量 (TX): $(format_size $cur_acc_tx)
下行流量 (RX): $(format_size $cur_acc_rx)
合计流量:      $(format_size $((cur_acc_rx + cur_acc_tx)))
EOF
}

setup_cron() {
    local COMMENT="# 每5分钟自动流量统计（此命令由脚本自动添加）："
    local JOB="*/5 * * * * /bin/bash $SCRIPT_PATH cron"
    (crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH") >/dev/null 2>&1 || (crontab -l 2>/dev/null; echo ""; echo "$COMMENT"; echo "$JOB") | crontab -
    echo "SUCCESS: 定时任务已配置。"
}

# --- 菜单界面 ---
clear
if [ "$1" == "cron" ]; then
    update_stats
else
    echo "======================================"
    echo "       Linux 流量统计助手 (完善版)"
    echo "======================================"
    echo "1) 查看当前流量统计"
    echo "2) 设置统计起始日期与周期"
    echo "3) 添加定时统计任务 (Crontab)"
    echo "q) 退出"
    echo "--------------------------------------"
    read -p "请选择操作 [1-3]: " opt

    case $opt in
        1) update_stats; sed -n '/人类直观阅读区/,$p' "$DB_FILE" ;;
        2) 
            echo "当前系统日期: $(date +%Y-%m-%d)"
            read -p "请输入统计起始日期 (YYYY-MM-DD): " sd
            read -p "请输入重置间隔月数 (例如 1): " im
            
            # 简单的正则校验日期格式 YYYY-MM-DD
            if [[ "$sd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$im" =~ ^[0-9]+$ ]]; then
                cat > "$DB_FILE" <<EOF
# --- 脚本配置数据 (请勿手动修改) ---
START_DATE=$sd
INTERVAL_MONTHS=$im
CUR_RX=0
CUR_TX=0
LAST_HW_RX=0
LAST_HW_TX=0
EOF
                update_stats
                echo "设置成功！周期已对齐至每月 $(echo $sd | cut -d- -f3 | sed 's/^0//') 号。"
            else
                echo "错误：输入格式有误。日期请严格按照 YYYY-MM-DD 格式。"
            fi
            ;;
        3) setup_cron ;;
        *) exit 0 ;;
    esac
fi
