#!/bin/bash

ROOT=$PWD
USERDATA_FILE="$ROOT/modal-login/temp-data/userData.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export TUNNEL_TYPE=""

# 强制CPU模式配置
export CPU_ONLY="true"
export CUDA_VISIBLE_DEVICES="" 
export OMP_NUM_THREADS=90% 
export OPENBLAS_NUM_THREADS=90%
export MKL_NUM_THREADS=90%
export VECLIB_MAXIMUM_THREADS=90%
export NUMEXPR_NUM_THREADS=90%

DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

# 安装系统依赖
install_dependencies() {
    echo -e "${CYAN}${BOLD}[✓] 检测系统并安装依赖...${NC}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt &>/dev/null; then
            sudo apt update > /dev/null
            sudo apt install -y build-essential gcc g++ python3-venv iproute2 cpulimit > /dev/null
        elif command -v yum &>/dev/null; then
            sudo yum groupinstall -y "Development Tools" > /dev/null
            sudo yum install -y gcc gcc-c++ python3 iproute cpulimit > /dev/null
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm base-devel gcc python3 iproute2 cpulimit > /dev/null
        else
            echo -e "${RED}${BOLD}[✗] 不支持的Linux包管理器${NC}"
            exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        xcode-select --install > /dev/null 2>&1 || true
        if ! brew list cpulimit &>/dev/null; then
            brew install cpulimit > /dev/null
        fi
    else
        echo -e "${RED}${BOLD}[✗] 不支持的操作系统: $OSTYPE${NC}"
        exit 1
    fi
}
install_dependencies || exit 1

# 配置CPU限制
limit_cpu_usage() {
    echo -e "${CYAN}${BOLD}[✓] 配置CPU使用限制(90%)...${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sudo cpulimit -l 90 -i &
    else
        sudo cpulimit -l 90 --background
    fi
}
limit_cpu_usage

# 强制使用选项A
USE_BIG_SWARM=false
SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
echo -e "${CYAN}${BOLD}[✓] 已选择: [A] Math${NC}"
echo -e "${CYAN}${BOLD}[✓] 参数规模: 0.5 billion${NC}"

# 清理函数
cleanup() {
    echo -e "${YELLOW}${BOLD}[✓] 清理进程中..."
    kill $SERVER_PID $TUNNEL_PID 2>/dev/null
    rm -f "$ROOT/modal-login/server.log" "$ROOT/localtunnel_output.log" 
    rm -f "$ROOT/cloudflared_output.log" "$ROOT/ngrok_output.log"
    exit 0
}
trap cleanup INT

# 设置modal登录服务
setup_modal_login() {
    cd "$ROOT/modal-login" || exit 1
    mkdir -p temp-data && chmod 755 temp-data

    echo -e "${CYAN}${BOLD}[✓] 安装NPM依赖..."
    npm install --legacy-peer-deps --silent 2>&1 || {
        echo -e "${RED}${BOLD}[✗] 依赖安装失败，尝试修复..."
        npm cache clean --force
        npm install --legacy-peer-deps
    }

    echo -e "${CYAN}${BOLD}[✓] 启动开发服务器..."
    if ss -ltnp | grep -q ":3000"; then
        PID=$(ss -ltnp | grep ":3000" | awk '{print $NF}' | cut -d= -f2 | cut -d, -f1)
        sudo kill -9 $PID && sleep 2
    fi

    npm run dev > server.log 2>&1 &
    SERVER_PID=$!

    for i in {1..60}; do
        if PORT=$(grep -o "Local:.*:\([0-9]*\)" server.log | cut -d: -f3); then
            echo -e "${GREEN}${BOLD}[✓] 服务器运行在端口 $PORT"
            curl -s "http://localhost:$PORT" >/dev/null && break
        fi
        sleep 1
    done

    [[ -z "$PORT" ]] && {
        echo -e "${RED}${BOLD}[✗] 服务器启动超时"
        cat server.log
        exit 1
    }
    cd "$ROOT"
}

setup_modal_login

# 隧道设置函数
setup_tunnel() {
    echo -e "${CYAN}${BOLD}[✓] 设置网络隧道..."
    local max_retries=3
    local retries=0

    while [[ $retries -lt $max_retries ]]; do
        case $((retries % 3)) in
            0) try_ngrok && break ;;
            1) try_cloudflared && break ;;
            2) try_localtunnel && break ;;
        esac
        ((retries++))
    done

    [[ $retries -eq $max_retries ]] && {
        echo -e "${RED}${BOLD}[✗] 所有隧道方式均失败"
        exit 1
    }
}

# 等待用户登录
wait_login() {
    echo -e "\n${CYAN}${BOLD}[↻] 等待登录完成..."
    for i in {1..600}; do
        [[ -f "$USERDATA_FILE" ]] && break
        ((i % 15 == 0)) && echo -e "${CYAN}[↻] 已等待 ${i} 秒..."
        sleep 1
    done

    [[ ! -f "$USERDATA_FILE" ]] && {
        echo -e "${RED}${BOLD}[✗] 登录超时"
        exit 1
    }

    ORG_ID=$(grep -o '"orgId":"[^"]*' "$USERDATA_FILE" | cut -d'"' -f4)
    [[ -z "$ORG_ID" ]] && {
        echo -e "${RED}${BOLD}[✗] 无法获取ORG_ID"
        cat "$USERDATA_FILE"
        exit 1
    }
    echo -e "${GREEN}${BOLD}[✓] 成功获取ORG_ID: $ORG_ID"
}

# Python环境设置
setup_python() {
    echo -e "${CYAN}${BOLD}[✓] 设置Python虚拟环境..."
    python3 -m venv .venv || exit 1
    source .venv/bin/activate || exit 1
    pip install -r requirements-cpu.txt --quiet 2>&1
}

# 启动训练任务
start_training() {
    echo -e "\n${GREEN}${BOLD}[✓] 启动训练任务..."
    local config_path="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "None" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$SWARM_CONTRACT" \
        --config "$config_path" \
        --game "dapo" \
        --cpu_mode \
        --cpu_cores 90%
}

# 主执行流程
if [[ -f "$USERDATA_FILE" ]]; then
    ORG_ID=$(grep -o '"orgId":"[^"]*' "$USERDATA_FILE" | cut -d'"' -f4)
else
    setup_tunnel
    wait_login
fi

setup_python
start_training

wait
