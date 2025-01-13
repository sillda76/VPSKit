#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEFAULT_BANTIME=1800
DEFAULT_MAXRETRY=5
DEFAULT_FINDTIME=600
DEFAULT_IGNOREIP="127.0.0.1/8 ::1"

BANTIME=$DEFAULT_BANTIME
MAXRETRY=$DEFAULT_MAXRETRY
FINDTIME=$DEFAULT_FINDTIME
IGNOREIP="$DEFAULT_IGNOREIP"

log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行"
        exit 1
    fi
}

check_system() {
    if ! command -v apt-get &> /dev/null; then
        log_error "此脚本仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
}

check_system_version() {
    if ! command -v iptables &> /dev/null; then
        log_info "正在安装 iptables..."
        apt-get install -y iptables
    else
        log_info "iptables 已安装，跳过安装步骤。"
    fi

    if [[ -f /etc/debian_version ]]; then
        DEBIAN_VERSION=$(cat /etc/debian_version)
        if [[ $DEBIAN_VERSION =~ ^12 ]]; then
            log_info "正在安装 rsyslog..."
            apt-get install -y rsyslog
        fi
    fi
}

get_ssh_port() {
    SSH_PORT=$(ss -tnlp | awk '/sshd/ && /LISTEN/ {print $4}' | awk -F: '{print $NF}' | head -1)
    if [ -z "$SSH_PORT" ]; then
        SSH_PORT=22
        log_warn "未检测到自定义SSH端口，使用默认端口22。"
    else
        log_info "检测到的SSH端口: $SSH_PORT"
    fi
}

install_fail2ban() {
    log_info "正在更新软件包列表..."
    apt-get update
    check_system_version
    log_info "正在安装 fail2ban..."
    apt-get install -y fail2ban
}

configure_fail2ban() {
    log_info "正在配置 fail2ban..."

    if [ -f /etc/fail2ban/jail.local ]; then
        log_warn "正在备份现有的 jail.local 文件..."
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%Y%m%d%H%M%S)
    fi

    LOGPATH=""
    for logfile in "/var/log/auth.log" "/var/log/secure" "/var/log/messages"; do
        if [[ -f "$logfile" ]]; then
            LOGPATH="$logfile"
            log_info "检测到 SSH 日志文件路径: $LOGPATH"
            break
        fi
    done

    if [[ -z "$LOGPATH" ]]; then
        log_warn "未找到 SSH 日志文件，跳过日志文件配置。"
    fi

    # 获取 SSH 端口
    get_ssh_port

    # 生成配置文件
    cat > /etc/fail2ban/jail.local << EOL
[DEFAULT]
allowipv6 = auto
bantime = $BANTIME
findtime = $FINDTIME
maxretry = $MAXRETRY
ignoreip = $IGNOREIP
banaction = iptables-multiport
loglevel = INFO
logtarget = /var/log/fail2ban.log

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $LOGPATH
maxretry = $MAXRETRY
findtime = $FINDTIME
bantime = $BANTIME
EOL

    if ! fail2ban-client -t; then
        log_error "fail2ban 配置文件校验失败"
        exit 1
    fi
}

start_service() {
    log_info "正在启动 fail2ban 服务..."
    systemctl start fail2ban
    systemctl enable fail2ban

    if systemctl is-active --quiet fail2ban; then
        log_info "fail2ban 服务已成功启动"
    else
        log_error "fail2ban 服务启动失败"
        exit 1
    fi
}

setup_cron_job() {
    log_info "正在设置每7天清理 fail2ban 日志的定时任务..."
    CRON_JOB="0 0 */7 * * root /usr/bin/bash -c '> /var/log/fail2ban.log'"
    if ! grep -q "$CRON_JOB" /etc/crontab; then
        echo "$CRON_JOB" >> /etc/crontab
        log_info "定时任务已添加。"
    fi
}

show_status() {
    log_info "正在检查 fail2ban 状态..."
    fail2ban-client status

    log_info "fail2ban 安装和配置已完成！"
    echo -e "\nSSH 保护配置："
    echo "- 封禁时间: $BANTIME 秒"
    echo "- 最大尝试次数: $MAXRETRY 次"
    echo "- 检测时间窗口: $FINDTIME 秒"
    echo "- 忽略的 IP 地址: $IGNOREIP"

    log_info "正在重启 fail2ban 服务..."
    systemctl restart fail2ban
    if systemctl is-active --quiet fail2ban; then
        log_info "fail2ban 服务已成功重启。"
    else
        log_error "fail2ban 服务重启失败"
        exit 1
    fi
}

interactive_menu() {
    while true; do
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}GitHub: https://github.com/sillda76/vps-scripts${NC}"
        echo -e "${BLUE}----------------------------------------${NC}"
        echo "欢迎使用 fail2ban 自动安装和配置脚本"
        echo "本脚本将执行以下操作："
        echo "- 检查系统环境和权限"
        echo "- 安装 fail2ban 和 rsyslog（仅限 Debian 12 及以上版本）"
        echo "- 配置 fail2ban，保护 SSH 服务"
        echo "- 启动并启用 fail2ban 服务"
        echo "- 设置每7天清理 fail2ban 日志的定时任务"
        echo "- 显示配置状态和常用命令"
        echo -e "${GREEN}========================================${NC}"
        echo -e "${YELLOW}常用操作：${NC}"
        echo "1. 查看状态"
        echo "2. 查看 SSH 状态"
        echo "3. 封禁 IP"
        echo "4. 解封 IP"
        echo "5. 查看日志"
        echo "6. 查看配置"
        echo "7. 卸载 fail2ban"
        echo -e "${BLUE}========================================${NC}"
        read -p "请输入选项 (1-7) 或是否继续安装并配置 fail2ban？(y/n): " choice
        case "$choice" in
            1) fail2ban-client status ;;
            2) fail2ban-client status sshd ;;
            3) 
                read -p "请输入要封禁的 IP 地址: " ip
                fail2ban-client set sshd banip "$ip"
                ;;
            4) 
                read -p "请输入要解封的 IP 地址: " ip
                fail2ban-client set sshd unbanip "$ip"
                ;;
            5) tail -f /var/log/fail2ban.log ;;
            6) cat /etc/fail2ban/jail.local ;;
            7)
                apt purge -y fail2ban
                log_info "fail2ban 已卸载。"
                exit 0
                ;;
            y|Y) break ;;
            n|N) exit 0 ;;
            *) log_error "无效的选项" ;;
        esac
    done
}

main() {
    interactive_menu
    check_root
    check_system
    install_fail2ban
    configure_fail2ban
    start_service
    setup_cron_job
    show_status
}

main
