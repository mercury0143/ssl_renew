#!/bin/bash
# Let's Encrypt 泛域名证书自动续期 + 多服务器分发脚本
# Usage: ./renew-cert.sh [--force] [--dry-run]
#
# 功能：
#   1. 在控制机申请/续期泛域名证书
#   2. 将证书分发到多个目标服务器
#   3. 重启目标服务器的 nginx
#
# 时间复杂度: O(n)，n为服务器数量
# 空间复杂度: O(n)，存储成功/失败列表

set -euo pipefail

# ======================== 配置 ========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="cloudacre.cn"
WILDCARD_DOMAIN="*.cloudacre.cn"
CERT_DEST_DIR="/opt/battle/cert"
SSH_USER="root"

# 目标服务器IP列表(硬编码)
# 格式: 每个IP一个元素 换行要处理好
SERVERS=(
    "39.108.107.99"
    "47.106.184.160"
)

# SSH/SCP 通用选项
# - ConnectTimeout: 连接超时10秒
# - StrictHostKeyChecking: 跳过首次指纹确认(已配好密钥)
# - BatchMode: 非交互模式，密码提示直接失败
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"

# 飞书通知配置(留空则不发送)
FEISHU_WEBHOOK_URL="https://open.feishu.cn/open-apis/bot/v2/hook/e414fe77-185e-4701-bfbd-e721c5d39806"

# 证书续期阈值(小时)
# 剩余有效期 ≤ 此值才触发续期
RENEW_THRESHOLD_HOURS=24

# ======================== 日志函数 ========================

log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_error() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

log_success() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $*"
}

# ======================== 证书检查函数 ========================

# 检查证书是否需要续期
#
# 逻辑:
#   1. 证书文件不存在 → 需要续期(首次申请)
#   2. 证书解析失败   → 需要续期(文件损坏)
#   3. 剩余有效期 ≤ RENEW_THRESHOLD_HOURS → 需要续期
#   4. 剩余有效期 > RENEW_THRESHOLD_HOURS → 无需续期
#
# Returns:
#   0: 需要续期
#   1: 无需续期(证书仍有效)
#
# 时间复杂度: O(1)
# 空间复杂度: O(1)
check_cert_needs_renewal() {
    local cert_file="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    
    # 场景1: 证书文件不存在(首次运行)
    if [[ ! -f "${cert_file}" ]]; then
        log "证书文件不存在，需要首次申请: ${cert_file}"
        return 0
    fi
    
    # 获取证书过期时间(格式: Dec 10 12:00:00 2025 GMT)
    local expiry_date
    if ! expiry_date=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2); then
        log_error "无法解析证书过期时间，强制续期"
        return 0
    fi
    
    # 场景2: 解析结果为空(文件损坏)
    if [[ -z "${expiry_date}" ]]; then
        log_error "证书过期时间为空，强制续期"
        return 0
    fi
    
    # 转换为时间戳
    local expiry_ts
    local now_ts
    if ! expiry_ts=$(date -d "${expiry_date}" +%s 2>/dev/null); then
        log_error "无法转换过期时间，强制续期: ${expiry_date}"
        return 0
    fi
    now_ts=$(date +%s)
    
    # 计算剩余秒数
    local remaining_seconds=$((expiry_ts - now_ts))
    local threshold_seconds=$((RENEW_THRESHOLD_HOURS * 3600))
    
    # 计算剩余天数和小时数(用于日志显示)
    local remaining_hours=$((remaining_seconds / 3600))
    local remaining_days=$((remaining_hours / 24))
    local remaining_hours_mod=$((remaining_hours % 24))
    
    # 场景3: 剩余时间 ≤ 阈值 → 需要续期
    if [[ ${remaining_seconds} -le ${threshold_seconds} ]]; then
        log "证书即将过期，需要续期"
        log "  过期时间: ${expiry_date}"
        log "  剩余时间: ${remaining_days}天${remaining_hours_mod}小时"
        log "  续期阈值: ${RENEW_THRESHOLD_HOURS}小时"
        return 0
    fi
    
    # 场景4: 剩余时间 > 阈值 → 无需续期
    log "证书仍有效, 无需续期"
    log "  过期时间: ${expiry_date}"
    log "  剩余时间: ${remaining_days}天${remaining_hours_mod}小时"
    log "  续期阈值: ${RENEW_THRESHOLD_HOURS}小时"
    return 1
}

# ======================== 飞书通知接口 ========================

# 发送部署结果通知到飞书
# 
# Args:
#   $1: 成功服务器列表(逗号分隔)
#   $2: 失败服务器列表(逗号分隔)
#
# Returns:
#   0: 发送成功或未配置(跳过)
#   1: 发送失败
#
# 依赖:
#   - notify-feishu.py
#   - 配置变量 FEISHU_WEBHOOK_URL
send_feishu_notification() {
    local success_servers="$1"
    local failed_servers="$2"
    
    # URL 为空则跳过
    if [[ -z "${FEISHU_WEBHOOK_URL}" ]]; then
        log "飞书通知: 未配置 FEISHU_WEBHOOK_URL，跳过"
        return 0
    fi
    
    # 调用 Python 脚本发送飞书通知
    python3.10 "${SCRIPT_DIR}/notify-feishu.py" \
        --webhook "${FEISHU_WEBHOOK_URL}" \
        --success "${success_servers}" \
        --failed "${failed_servers}" \
        --domain "${WILDCARD_DOMAIN}" || true
}

# ======================== 部署函数 ========================

# 将证书部署到单个服务器
#
# Args:
#   $1: 服务器IP地址
#
# Returns:
#   0: 部署成功
#   1: 部署失败
#
# 时间复杂度: O(1)
deploy_to_server() {
    local server_ip="$1"
    local target="${SSH_USER}@${server_ip}"
    
    log "开始部署到 ${server_ip} ..."
    
    # Step 1: SCP 传输证书文件
    if ! scp ${SSH_OPTS} \
        "${CERT_SRC}/fullchain.pem" \
        "${target}:${CERT_DEST_DIR}/fullchain.crt"; then
        log_error "${server_ip}: SCP fullchain.pem 失败"
        return 1
    fi
    
    if ! scp ${SSH_OPTS} \
        "${CERT_SRC}/privkey.pem" \
        "${target}:${CERT_DEST_DIR}/private.pem"; then
        log_error "${server_ip}: SCP privkey.pem 失败"
        return 1
    fi
    
    # Step 2: 设置权限并重启 nginx
    if ! ssh ${SSH_OPTS} "${target}" "chmod 600 ${CERT_DEST_DIR}/* && nginx -t && systemctl restart nginx"; then
        log_error "${server_ip}: nginx 重启失败"
        return 1
    fi
    
    log_success "${server_ip}: 部署成功"
    return 0
}

# ======================== 主逻辑 ========================

main() {
    # 解析参数
    local force=""
    local dry_run=""
    local skip_check=""
    for arg in "$@"; do
        case "$arg" in
            --force)   force="--force-renewal"; skip_check="yes" ;;
            --dry-run) dry_run="--dry-run" ;;
        esac
    done

    log "开始证书检查: ${WILDCARD_DOMAIN}"

    # 检查证书有效期(--force 跳过检查)
    if [[ -z "${skip_check}" ]]; then
        if ! check_cert_needs_renewal; then
            log "退出(证书仍有效)"
            exit 0
        fi
    else
        log "跳过有效期检查(--force 模式)"
    fi

    log "开始证书续期..."

    # 申请/续期证书
    certbot certonly --manual \
        --preferred-challenges dns \
        --manual-auth-hook "${SCRIPT_DIR}/dns-auth.py" \
        --manual-cleanup-hook "${SCRIPT_DIR}/dns-cleanup.py" \
        -d "${WILDCARD_DOMAIN}" \
        --agree-tos --non-interactive \
        --manual-public-ip-logging-ok \
        --register-unsafely-without-email \
        --keep-until-expiring \
        ${force} ${dry_run}

    # dry-run 模式不部署
    if [[ -n "${dry_run}" ]]; then
        log "测试完成(dry-run 模式, 跳过部署)"
        exit 0
    fi

    # 证书源路径
    CERT_SRC="/etc/letsencrypt/live/${DOMAIN}"
    
    # 检查证书是否存在
    if [[ ! -f "${CERT_SRC}/fullchain.pem" ]] || [[ ! -f "${CERT_SRC}/privkey.pem" ]]; then
        log_error "证书文件不存在: ${CERT_SRC}"
        exit 1
    fi

    log "证书续期成功，开始分发到 ${#SERVERS[@]} 台服务器..."

    # 部署结果统计
    local success_list=()
    local failed_list=()

    # 遍历服务器列表,逐一部署
    for server_ip in "${SERVERS[@]}"; do
        if deploy_to_server "${server_ip}"; then
            success_list+=("${server_ip}")
        else
            failed_list+=("${server_ip}")
        fi
    done

    # 汇总报告
    local success_str="无"
    local failed_str="无"
    [[ ${#success_list[@]} -gt 0 ]] && success_str=$(IFS=,; echo "${success_list[*]}")
    [[ ${#failed_list[@]} -gt 0 ]] && failed_str=$(IFS=,; echo "${failed_list[*]}")
    
    log "========== 部署汇总 =========="
    log "成功: ${#success_list[@]} 台 [${success_str}]"
    log "失败: ${#failed_list[@]} 台 [${failed_str}]"
    
    if [[ ${#failed_list[@]} -gt 0 ]]; then
        log_error "以下服务器部署失败:"
        for ip in "${failed_list[@]}"; do
            log_error "  - ${ip}"
        done
    fi

    # 发送飞书通知
    send_feishu_notification \
        "$(IFS=,; echo "${success_list[*]:-}")" \
        "$(IFS=,; echo "${failed_list[*]:-}")"

    log "全部任务完成"
    
    # 如果有失败的服务器，返回非0退出码
    [[ ${#failed_list[@]} -eq 0 ]]
}

# 执行主函数
main "$@"
