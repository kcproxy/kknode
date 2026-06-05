#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

########################
# 参数解析
########################
VERSION_ARG=""
API_HOST_ARG=""
SERVER_ID_ARG=""
SECRET_KEY_ARG=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                API_HOST_ARG="$2"; shift 2 ;;
            --server-id)
                SERVER_ID_ARG="$2"; shift 2 ;;
            --secret-key)
                SECRET_KEY_ARG="$2"; shift 2 ;;
            -h|--help)
                echo "用法: $0 [版本号] [--api-host URL] [--server-id ID] [--secret-key KEY]"
                exit 0 ;;
            --*)
                echo "未知参数: $1"; exit 1 ;;
            *)
                # 兼容第一个位置参数作为版本号
                if [[ -z "$VERSION_ARG" ]]; then
                    VERSION_ARG="$1"; shift
                else
                    shift
                fi ;;
        esac
    done
}

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    need_install_apt() {
        local packages=("$@")
        local missing=()
        
        # 批量检查已安装的包
        local installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
        
        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_yum() {
        local packages=("$@")
        local missing=()
        
        # 批量检查已安装的包
        local installed_list=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort)
        
        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_apk() {
        local packages=("$@")
        local missing=()
        
        # 批量检查已安装的包
        local installed_list=$(apk info 2>/dev/null | sort)
        
        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "安装缺失的包: ${missing[*]}"
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    }

    # 一次性安装所有必需的包
    if [[ x"${release}" == x"centos" ]]; then
        # 检查并安装 epel-release
        if ! rpm -q epel-release >/dev/null 2>&1; then
            echo "安装 EPEL 源..."
            yum install -y epel-release >/dev/null 2>&1
        fi
        need_install_yum wget curl unzip tar cronie socat ca-certificates pv iptables
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        need_install_apk wget curl unzip tar socat ca-certificates pv iptables ip6tables
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv iptables
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"ubuntu" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv iptables
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        echo "更新包数据库..."
        pacman -Sy --noconfirm >/dev/null 2>&1
        # --needed 会跳过已安装的包，非常高效
        echo "安装必需的包..."
        pacman -S --noconfirm --needed wget curl unzip tar cronie socat ca-certificates pv iptables >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/kknode/kknode ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service kknode status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status kknode | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

generate_kknode_config() {
        local api_host="$1"
        local server_id="$2"
        local secret_key="$3"

        mkdir -p /etc/kknode >/dev/null 2>&1
        cat > /etc/kknode/config.yml <<EOF
Log:
  # 日志等级，可选: debug, info, warn(warning), error
  Level: warn
  # 日志输出位置，可以是文件路径，留空时使用 "stdout"（标准输出）
  Output: 
  # 访问日志路径，例如logs/access.log，写none时关闭访问日志
  Access: none

Nodes:
  - # 后端 API 地址，例如 "https://api.example.com"
    ApiHost: ${api_host}
    # 服务器唯一标识
    ServerID: ${server_id}
    # 通讯密钥，用于验证请求合法性
    SecretKey: ${secret_key}
    # 请求超时时间（单位：秒）
    Timeout: 30
    LocalConfig: false
EOF
        echo -e "${green}kknode 配置文件生成完成,正在重新启动服务${plain}"
        if [[ x"${release}" == x"alpine" ]]; then
            service kknode restart
        else
            systemctl restart kknode
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}kknode 重启成功${plain}"
        else
            echo -e "${red}kknode 可能启动失败，请使用 kknode log 查看日志信息${plain}"
        fi
}

append_kknode_config() {
    local api_host="$1"
    local server_id="$2"
    local secret_key="$3"

    if grep -q "ApiHost: ${api_host}" /etc/kknode/config.yml; then
        echo -e "${yellow}发现 API 地址 ${api_host} 已存在于配置中，跳过追加。${plain}"
    else
        cat >> /etc/kknode/config.yml <<EOF
  - ApiHost: ${api_host}
    ServerID: ${server_id}
    SecretKey: ${secret_key}
    Timeout: 30
    LocalConfig: false
EOF
        echo -e "${green}成功将后端 API: ${api_host} 追加到配置文件中。${plain}"
    fi

    if [[ x"${release}" == x"alpine" ]]; then
        service kknode restart
    else
        systemctl restart kknode
    fi
    sleep 2
    check_status
    echo -e ""
    if [[ $? == 0 ]]; then
        echo -e "${green}kknode 重启成功${plain}"
    else
        echo -e "${red}kknode 可能启动失败，请使用 kknode log 查看日志信息${plain}"
    fi
}

migrate_from_original() {
    # 检测是否安装了原版 kknode 脚本（通过特征字符串判断）
    if [[ -f /usr/bin/kknode ]] && grep -q "perfect-panel/kknode" /usr/bin/kknode 2>/dev/null; then
        echo -e "${yellow}检测到原版 kknode，正在迁移配置...${plain}"
        
        # 停止原版服务
        if [[ x"${release}" == x"alpine" ]]; then
            service kknode stop 2>/dev/null
        else
            systemctl stop kknode 2>/dev/null
        fi

        # 迁移 config.yml：将 Api: 单后端格式转换为 Nodes: 多后端列表格式
        if [[ -f /etc/kknode/config.yml ]] && grep -q "^Api:" /etc/kknode/config.yml 2>/dev/null; then
            local old_api_host=$(grep "ApiHost:" /etc/kknode/config.yml | sed 's/.*ApiHost:[[:space:]]*//')
            local old_server_id=$(grep "ServerID:" /etc/kknode/config.yml | sed 's/.*ServerID:[[:space:]]*//')
            local old_secret_key=$(grep "SecretKey:" /etc/kknode/config.yml | sed 's/.*SecretKey:[[:space:]]*//')
            local old_timeout=$(grep "Timeout:" /etc/kknode/config.yml | sed 's/.*Timeout:[[:space:]]*//')
            old_timeout=${old_timeout:-30}

            # 提取 Log 配置
            local old_log_level=$(grep "Level:" /etc/kknode/config.yml | sed 's/.*Level:[[:space:]]*//')
            local old_log_output=$(grep "Output:" /etc/kknode/config.yml | head -1 | sed 's/.*Output:[[:space:]]*//')
            local old_log_access=$(grep "Access:" /etc/kknode/config.yml | sed 's/.*Access:[[:space:]]*//')
            old_log_level=${old_log_level:-warn}
            old_log_access=${old_log_access:-none}

            # 写入新格式
            cat > /etc/kknode/config.yml <<EOF
Log:
  Level: ${old_log_level}
  Output: ${old_log_output}
  Access: ${old_log_access}

Nodes:
  - ApiHost: ${old_api_host}
    ServerID: ${old_server_id}
    SecretKey: ${old_secret_key}
    Timeout: ${old_timeout}
    LocalConfig: false
EOF
            echo -e "${green}配置文件已从原版格式迁移为新格式。${plain}"
        fi

        # 清理 /etc/kknode/ 下除 geoip.dat、geosite.dat、config.yml 之外的所有文件和目录
        find /etc/kknode/ -mindepth 1 \
            ! -name "geoip.dat" \
            ! -name "geosite.dat" \
            ! -name "config.yml" \
            -exec rm -rf {} + 2>/dev/null
        echo -e "${green}已清理原版残留文件。${plain}"

        # 返回 1 表示需要强制全新安装（原版和二改版的发布仓库不同）
        return 1
    fi
    return 0
}

install_kknode() {
    local version_param="$1"
    local current_version=""
    local force_install=false

    # 检测并迁移原版
    migrate_from_original
    if [[ $? -eq 1 ]]; then
        force_install=true
        current_version=""
    fi
    
    if [[ "$force_install" != true ]] && [[ -f /usr/local/kknode/kknode ]]; then
        current_version=$(/usr/local/kknode/kknode version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    fi

    if [[ -z "$version_param" ]]; then
        last_version=$(curl -Ls "https://api.github.com/repos/kcproxy/kknode/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 kknode 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 kknode 版本安装${plain}"
            exit 1
        fi
    else
        last_version=$version_param
    fi

    local do_install=true

    if [[ -n "$current_version" ]]; then
        if [[ "$current_version" == "$last_version" ]]; then
            echo -e "${green}当前已是最新版本 (${current_version})，跳过核心程序下载环节。${plain}"
            do_install=false
        else
            read -rp "发现新版本 (${last_version})，当前版本 (${current_version})。是否更新 kknode？(y/n) [默认: y]: " update_choice
            update_choice=${update_choice:-y}
            if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
                echo -e "${yellow}已跳过版本更新，保留当前版本 (${current_version})。${plain}"
                do_install=false
            fi
        fi
    fi

    if [[ "$do_install" == true ]]; then
        if [[ -e /usr/local/kknode/ ]]; then
            rm -rf /usr/local/kknode/
        fi

        mkdir /usr/local/kknode/ -p
        cd /usr/local/kknode/

        echo -e "${green}开始下载版本：${last_version}...${plain}"
        url="https://github.com/kcproxy/kknode/releases/download/${last_version}/kknode-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "下载进度" > /usr/local/kknode/kknode-linux.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 kknode 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi

        unzip kknode-linux.zip
        rm kknode-linux.zip -f
        chmod +x kknode
        mkdir /etc/kknode/ -p
        cp geoip.dat /etc/kknode/
        cp geosite.dat /etc/kknode/
        if [[ x"${release}" == x"alpine" ]]; then
            rm /etc/init.d/kknode -f
            cat <<EOF > /etc/init.d/kknode
#!/sbin/openrc-run

name="kknode"
description="kknode"

command="/usr/local/kknode/kknode"
command_args="server"
command_user="root"

pidfile="/run/kknode.pid"
command_background="yes"

depend() {
        need net
}
EOF
            chmod +x /etc/init.d/kknode
            rc-update add kknode default
            echo -e "${green}kknode ${last_version}${plain} 安装完成，已设置开机自启"
        else
            rm /etc/systemd/system/kknode.service -f
            cat <<EOF > /etc/systemd/system/kknode.service
[Unit]
Description=kknode Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/kknode/
ExecStart=/usr/local/kknode/kknode server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl stop kknode
            systemctl enable kknode
            echo -e "${green}kknode ${last_version}${plain} 安装完成，已设置开机自启"
        fi

        curl -o /usr/bin/kknode -Ls https://raw.githubusercontent.com/kcproxy/kknode/master/scripts/kknode.sh
        chmod +x /usr/bin/kknode
    fi

    if [[ ! -f /etc/kknode/config.yml ]]; then
        # 如果通过 CLI 传入了完整参数，则直接生成配置并跳过交互
        if [[ -n "$API_HOST_ARG" && -n "$SERVER_ID_ARG" && -n "$SECRET_KEY_ARG" ]]; then
            generate_kknode_config "$API_HOST_ARG" "$SERVER_ID_ARG" "$SECRET_KEY_ARG"
            echo -e "${green}已根据参数生成 /etc/kknode/config.yml${plain}"
            first_install=false
        else
            cp config.yml /etc/kknode/
            first_install=true
        fi
    else
        if [[ -n "$API_HOST_ARG" && -n "$SERVER_ID_ARG" && -n "$SECRET_KEY_ARG" ]]; then
            append_kknode_config "$API_HOST_ARG" "$SERVER_ID_ARG" "$SECRET_KEY_ARG"
        else
            if [[ x"${release}" == x"alpine" ]]; then
                service kknode start
            else
                systemctl start kknode
            fi
            sleep 2
            check_status
            echo -e ""
            if [[ $? == 0 ]]; then
                echo -e "${green}kknode 重启成功${plain}"
            else
                echo -e "${red}kknode 可能启动失败，请使用 kknode log 查看日志信息${plain}"
            fi
        fi
        first_install=false
    fi


    curl -o /usr/bin/kknode -Ls https://raw.githubusercontent.com/kcproxy/kknode/master/scripts/kknode.sh
    chmod +x /usr/bin/kknode

    cd $cur_dir
    rm -f install.sh
    echo "------------------------------------------"
    echo "kknode 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "kknode              - 显示管理菜单 (功能更多)"
    echo "kknode start        - 启动 kknode"
    echo "kknode stop         - 停止 kknode"
    echo "kknode restart      - 重启 kknode"
    echo "kknode status       - 查看 kknode 状态"
    echo "kknode enable       - 设置 kknode 开机自启"
    echo "kknode disable      - 取消 kknode 开机自启"
    echo "kknode log          - 查看 kknode 日志"
    echo "kknode generate     - 生成 kknode 配置文件"
    echo "kknode update       - 更新 kknode"
    echo "kknode update x.x.x - 安装 kknode 指定版本"
    echo "kknode install      - 安装 kknode"
    echo "kknode uninstall    - 卸载 kknode"
    echo "kknode version      - 查看 kknode 版本"
    echo "------------------------------------------"

    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装 kknode，是否自动生成 /etc/kknode/config.yml？(y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            # 交互式收集参数，提供示例默认值
            read -rp "面板API地址[格式: https://example.com/]: " api_host
            api_host=${api_host:-https://example.com/}
            read -rp "服务器ID: " server_id
            server_id=${server_id:-1}
            read -rp "通讯密钥: " secret_key

            # 生成配置文件（覆盖可能从包中复制的模板）
            generate_kknode_config "$api_host" "$server_id" "$secret_key"
        else
            echo "${green}已跳过自动生成配置。如需后续生成，可执行: kknode generate${plain}"
        fi
    fi
}

parse_args "$@"
echo -e "${green}开始安装${plain}"
install_base
install_kknode "$VERSION_ARG"