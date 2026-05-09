#!/bin/bash
# Gateway Watchdog — 工程控制论第二道防线
# 由 cron 每 2 分钟触发，no_agent 模式，零 token 消耗
# 路径: ~/.hermes/scripts/gateway-watchdog.sh

LOG=~/.hermes/logs/gateway-watchdog.log
MAX_LOG_LINES=200

# === 诊断函数 ===
diagnose() {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') DIAGNOSE ==="
    
    # 最近 20 条 gateway 日志中的错误
    echo "--- Recent errors ---"
    journalctl --user -u hermes-gateway --no-pager -n 50 2>/dev/null \
        | grep -iE 'error|fail|traceback|exception|killed|oom|signal|segfault' \
        | tail -10
    
    # 系统资源
    echo "--- System resources ---"
    echo "Memory: $(free -m | awk '/^Mem:/ {printf "%.0f%% used (%dM/%dM)", $3/$2*100, $3, $2}')"
    echo "Disk: $(df -h / | tail -1 | awk '{print $5 " used (" $4 " free)"}')"
    echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
    
    # OOM killer
    echo "--- OOM events ---"
    dmesg 2>/dev/null | grep -i 'oom.*hermes\|out of memory' | tail -3 || echo "none"
    
    # Docker
    echo "--- Docker ---"
    docker info --format 'Running: {{.ContainersRunning}}, Status: {{.ServerVersion}}' 2>/dev/null || echo "docker not responding"
    
    echo "=== END DIAGNOSE ==="
}

# === 自修复 ===
auto_fix() {
    local attempt=$1
    echo "[$(date '+%H:%M:%S')] Auto-restart attempt #$attempt"
    
    # 尝试重启
    if systemctl --user restart hermes-gateway 2>/dev/null; then
        sleep 5
        if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
            echo "[$(date '+%H:%M:%S')] ✅ Gateway restarted successfully"
            return 0
        fi
    fi
    
    # 重启失败，尝试更激进的修复
    echo "[$(date '+%H:%M:%S')] ⚠️  Restart failed, trying reset-failed"
    systemctl --user reset-failed hermes-gateway 2>/dev/null
    sleep 2
    systemctl --user restart hermes-gateway 2>/dev/null
    sleep 5
    
    if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
        echo "[$(date '+%H:%M:%S')] ✅ Gateway recovered after reset-failed"
        return 0
    fi
    
    return 1
}

# === 主逻辑 ===
STATUS=$(systemctl --user is-active hermes-gateway 2>/dev/null)
RESTART_COUNT=$(systemctl --user show hermes-gateway -p NRestarts 2>/dev/null | cut -d= -f2)

if [ "$STATUS" = "active" ]; then
    # Gateway 正常 — 静默（watchdog 模式：只在异常时输出）
    exit 0
fi

# === Gateway 挂了，进入修复流程 ===
echo "" >> "$LOG"
echo "========================================" >> "$LOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🚨 Gateway DOWN — status: $STATUS, restart count: $RESTART_COUNT" >> "$LOG"

# 先诊断原因
diagnose >> "$LOG" 2>&1

# 尝试自修复（最多 3 次）
FIXED=false
for i in 1 2 3; do
    if auto_fix $i >> "$LOG" 2>&1; then
        FIXED=true
        break
    fi
    sleep 10
done

if $FIXED; then
    echo "[$(date '+%H:%M:%S')] Summary: Gateway auto-recovered" >> "$LOG"
    # 输出恢复消息让 cron delivery 发送给用户
    echo "🔧 Gateway 自动恢复成功 (尝试了 $i 次)"
    echo "状态: $(systemctl --user is-active hermes-gateway)"
    echo "重启计数: $(systemctl --user show hermes-gateway -p NRestarts 2>/dev/null | cut -d= -f2)"
else
    echo "[$(date '+%H:%M:%S')] ❌ FAILED: Gateway could not be auto-recovered after 3 attempts" >> "$LOG"
    echo "🚨 Gateway 自动修复失败！需要手动介入"
    echo "详见日志: $LOG"
    echo "最后 30 行:"
    tail -30 "$LOG"
fi

# 轮转日志
if [ $(wc -l < "$LOG" 2>/dev/null || echo 0) -gt $MAX_LOG_LINES ]; then
    tail -n $MAX_LOG_LINES "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

exit 0
