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

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启kknode" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/kcproxy/kknode/master/scripts/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version
    else
        version=$2
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/kcproxy/kknode/master/scripts/install.sh) $version
    if [[ $? == 0 ]]; then
        echo -e "${green}更新完成，已自动重启 kknode，请使用 kknode log 查看运行日志${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "kknode在修改配置后会自动尝试重启"
    vi /etc/kknode/config.yml
    sleep 2
    restart
    check_status
    case $? in
        0)
            echo -e "kknode状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动kknode或自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -rp "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "kknode状态: ${red}未安装${plain}"
    esac
}

toggle_local_config() {
    if [[ ! -f /etc/kknode/config.yml ]]; then
        echo -e "${red}未找到配置文件。${plain}"
        if [[ $# == 0 ]]; then before_show_menu; fi
        return
    fi
    local api_hosts=($(grep "ApiHost:" /etc/kknode/config.yml | sed 's/.*ApiHost:[[:space:]]*//'))
    if [[ ${#api_hosts[@]} -eq 0 ]]; then
        echo -e "${red}当前配置中没有后端节点。${plain}"
        if [[ $# == 0 ]]; then before_show_menu; fi
        return
    fi
    
    echo -e "${green}当前存在的后端节点及锁定状态：${plain}"
    local i=1
    for host in "${api_hosts[@]}"; do
        local_status=$(awk -v target="ApiHost: ${host}" '
            BEGIN { found=0; val="false" }
            /ApiHost:/ { if (index($0, target)>0) found=1; else found=0 }
            found && /LocalConfig:/ { val=$2; gsub(/[^a-zA-Z]/, "", val); found=0 }
            END { print val }
        ' /etc/kknode/config.yml)
        
        if [[ "$local_status" == "true" ]]; then
            echo -e "  ${green}${i}.${plain} ${host} [${red}已锁定${plain}]"
        else
            echo -e "  ${green}${i}.${plain} ${host} [${green}未锁定${plain}]"
        fi
        ((i++))
    done
    echo -e "  ${green}0.${plain} 返回主菜单"
    read -rp "请输入要切换状态的节点序号 [0-${#api_hosts[@]}]: " choice
    if [[ "$choice" == "0" ]]; then
        show_menu
        return
    fi
    if [[ "$choice" -ge 1 && "$choice" -le "${#api_hosts[@]}" ]]; then
        local target_host="${api_hosts[$((choice-1))]}"
        local_status=$(awk -v target="ApiHost: ${target_host}" '
            BEGIN { found=0; val="false" }
            /ApiHost:/ { if (index($0, target)>0) found=1; else found=0 }
            found && /LocalConfig:/ { val=$2; gsub(/[^a-zA-Z]/, "", val); found=0 }
            END { print val }
        ' /etc/kknode/config.yml)

        local new_val="true"
        if [[ "$local_status" == "true" ]]; then
            new_val="false"
        fi
        
        awk -v target="ApiHost: ${target_host}" -v new_val="${new_val}" '
        BEGIN { in_target=0 }
        /ApiHost:/ {
            if (index($0, target)>0) {
                in_target=1
                print $0
                print "    LocalConfig: " new_val
                next
            } else {
                in_target=0
            }
        }
        {
            if (in_target && /LocalConfig:/) {
                next
            }
            print $0
        }
        ' /etc/kknode/config.yml > /tmp/config.yml.tmp && mv /tmp/config.yml.tmp /etc/kknode/config.yml
        
        if [[ "$new_val" == "true" ]]; then
            echo -e "${green}已锁定 ${target_host} 的本地配置！${plain}"
        else
            echo -e "${green}已解锁 ${target_host} 的本地配置！${plain}"
        fi
        restart
        return
    fi
    if [[ $# == 0 ]]; then before_show_menu; fi
}

delete_backend() {
    if [[ ! -f /etc/kknode/config.yml ]]; then
        echo -e "${red}未找到配置文件。${plain}"
        if [[ $# == 0 ]]; then before_show_menu; fi
        return
    fi
    local api_hosts=($(grep "ApiHost:" /etc/kknode/config.yml | sed 's/.*ApiHost:[[:space:]]*//'))
    if [[ ${#api_hosts[@]} -eq 0 ]]; then
        echo -e "${red}当前配置中没有后端节点。${plain}"
        if [[ $# == 0 ]]; then before_show_menu; fi
        return
    fi
    echo -e "${green}当前存在的后端节点：${plain}"
    local i=1
    for host in "${api_hosts[@]}"; do
        echo -e "  ${green}${i}.${plain} ${host}"
        ((i++))
    done
    echo -e "  ${green}0.${plain} 返回主菜单"
    read -rp "请输入要删除的节点序号 [0-${#api_hosts[@]}]: " choice
    if [[ "$choice" == "0" ]]; then
        show_menu
        return
    fi
    if [[ "$choice" -ge 1 && "$choice" -le "${#api_hosts[@]}" ]]; then
        local target_host="${api_hosts[$((choice-1))]}"
        confirm "确定要删除节点 ${target_host} 吗?" "n"
        if [[ $? == 0 ]]; then
            local target_dir=$(calculate_api_dir "${target_host}")
            awk -v target="ApiHost: ${target_host}" '
            BEGIN { deleting=0 }
            /ApiHost:/ {
                if (index($0, target) > 0) { deleting=1 } else { deleting=0 }
            }
            { if (!deleting) { print $0 } }
            ' /etc/kknode/config.yml > /tmp/config.yml.tmp && mv /tmp/config.yml.tmp /etc/kknode/config.yml
            
            if [[ -d "${target_dir}" ]]; then
                rm -rf "${target_dir}"
                echo -e "${green}已成功从配置中删除节点 ${target_host} 并清理目录 ${target_dir}。${plain}"
            else
                echo -e "${green}已成功从配置中删除节点 ${target_host}。${plain}"
            fi
            restart
            return
        fi
    fi
    if [[ $# == 0 ]]; then before_show_menu; fi
}

portmap_delete_all() {
    local comments=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -oP "fami_(HOP|PORTMAP)_[0-9_]+" | sort -u)
    local comments_v6=$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -oP "fami_(HOP|PORTMAP)_[0-9_]+" | sort -u)
    local all_comments=$(echo -e "${comments}\n${comments_v6}" | sort -u | grep -v '^$')

    if [[ -z "$all_comments" ]]; then
        return
    fi

    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        portmap_delete_by_comment "iptables" "$c"
        portmap_delete_by_comment "ip6tables" "$c"
    done <<< "$all_comments"
}

uninstall() {
    echo -e "  ${green}1.${plain} 删除单个后端节点配置"
    echo -e "  ${green}2.${plain} 完全卸载 kknode"
    echo -e "  ${green}0.${plain} 返回主菜单"
    echo && read -rp "请输入选择 [0-2]: " uninstall_choice
    if [[ "${uninstall_choice}" == "0" ]]; then
        show_menu
        return
    elif [[ "${uninstall_choice}" == "1" ]]; then
        delete_backend
        return
    elif [[ "${uninstall_choice}" != "2" ]]; then
        echo -e "${red}输入无效${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return
    fi

    confirm "确定要完全卸载 kknode 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service kknode stop
        rc-update del kknode
        rm /etc/init.d/kknode -f
    else
        systemctl stop kknode
        systemctl disable kknode
        rm /etc/systemd/system/kknode.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi
    portmap_delete_all
    rm /etc/kknode/ -rf
    rm /usr/local/kknode/ -rf

    echo ""
    echo -e "卸载成功，已清理所有 kknode 相关 UDP 端口映射规则。如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/kknode -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}kknode已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service kknode start
        else
            systemctl start kknode
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}kknode 启动成功，请使用 kknode log 查看运行日志${plain}"
        else
            echo -e "${red}kknode可能启动失败，请稍后使用 kknode log 查看日志信息${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service kknode stop
    else
        systemctl stop kknode
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}kknode 停止成功${plain}"
    else
        echo -e "${red}kknode停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        sed -i 's/command_args="server --local"/command_args="server"/' /etc/init.d/kknode 2>/dev/null
        service kknode restart
    else
        sed -i 's/ExecStart=\/usr\/local\/kknode\/kknode server --local/ExecStart=\/usr\/local\/kknode\/kknode server/' /etc/systemd/system/kknode.service 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        systemctl restart kknode
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}kknode 重启成功，请使用 kknode log 查看运行日志${plain}"
    else
        echo -e "${red}kknode可能启动失败，请稍后使用 kknode log 查看日志信息${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service kknode status
    else
        systemctl status kknode --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add kknode
    else
        systemctl enable kknode
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}kknode 设置开机自启成功${plain}"
    else
        echo -e "${red}kknode 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del kknode
    else
        systemctl disable kknode
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}kknode 取消开机自启成功${plain}"
    else
        echo -e "${red}kknode 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then   
        echo -e "${red}alpine系统暂不支持日志查看${plain}\n" && exit 1
    else
        journalctl -u kknode -e --no-pager -f
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}


update_shell() {
    wget -O /usr/bin/kknode -N --no-check-certificate https://raw.githubusercontent.com/kcproxy/kknode/master/scripts/kknode.sh
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/kknode
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
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

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep kknode)
        if [[ x"${temp}" == x"" ]]; then
            return 1
        else
            return 0
        fi
    else
        temp=$(systemctl is-enabled kknode)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1;
        fi
    fi
}
check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}kknode已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装kknode${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "kknode状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "kknode状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "kknode状态: ${red}未安装${plain}"
    esac

    # 检查端口冲突
    if [[ -f /usr/local/kknode/kknode ]]; then
        /usr/local/kknode/kknode check > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            echo -e "端口检测状态: ${red}检测到端口冲突！请检查日志或配置${plain}"
        fi
    fi
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

show_kknode_version() {
    echo -n "kknode 版本："
    /usr/local/kknode/kknode version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
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

calculate_api_dir() {
    local api_host="$1"
    # 提取 hostname
    local hostname=$(echo "${api_host}" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:.*$||')
    echo "/etc/kknode/${hostname}"
}

generate_config_file() {
    # 交互式收集参数，提供示例默认值
    read -rp "面板API地址[格式: https://example.com/]: " api_host
    api_host=${api_host:-https://example.com/}
    read -rp "服务器ID: " server_id
    server_id=${server_id:-1}
    read -rp "通讯密钥: " secret_key

    if [[ -f /etc/kknode/config.yml ]]; then
        confirm "检测到已有配置文件，是否追加该节点配置？(选择 n 则覆盖原配置)" "y"
        if [[ $? == 0 ]]; then
            append_kknode_config "$api_host" "$server_id" "$secret_key"
            return
        fi
    fi

    # 生成配置文件（覆盖可能从包中复制的模板）
    generate_kknode_config "$api_host" "$server_id" "$secret_key"
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

# ===== 端口映射管理 =====
PORTMAP_COMMENT_PREFIX="FAMI_HOP"

portmap_generate_comment() {
    local service_port=$1
    local start_port=$2
    local end_port=$3
    echo "${PORTMAP_COMMENT_PREFIX}_${service_port}_${start_port}_${end_port}"
}

portmap_add() {
    echo -e "${green}===== 添加 UDP 端口映射 =====${plain}"
    read -rp "服务端口 (Hysteria2 实际监听端口): " service_port
    read -rp "Hop 起始端口: " start_port
    read -rp "Hop 结束端口: " end_port

    # 验证
    for port in $service_port $start_port $end_port; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            echo -e "${red}错误: 端口 '$port' 无效，必须是 1-65535 之间的数字${plain}"
            return
        fi
    done
    if [[ "$start_port" -gt "$end_port" ]]; then
        echo -e "${red}错误: 起始端口不能大于结束端口${plain}"
        return
    fi

    local comment=$(portmap_generate_comment "$service_port" "$start_port" "$end_port")
    local port_range="${start_port}:${end_port}"

    portmap_delete_by_comment "iptables" "$comment"
    iptables -t nat -A PREROUTING -p udp --dport "$port_range" -j DNAT --to-destination ":$service_port" -m comment --comment "$comment" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${green}IPv4 DNAT 已添加: UDP ${start_port}-${end_port} -> ${service_port}${plain}"
    else
        echo -e "${red}IPv4 DNAT 添加失败${plain}"
    fi

    modprobe ip6_tables 2>/dev/null
    modprobe ip6table_nat 2>/dev/null
    portmap_delete_by_comment "ip6tables" "$comment"
    ip6tables -t nat -A PREROUTING -p udp --dport "$port_range" -j DNAT --to-destination ":$service_port" -m comment --comment "$comment" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${green}IPv6 DNAT 已添加: UDP ${start_port}-${end_port} -> ${service_port}${plain}"
    else
        echo -e "${yellow}IPv6 DNAT 添加失败 (可能不支持)${plain}"
    fi
}

portmap_list() {
    echo -e "${green}===== 当前 UDP 端口映射规则 =====${plain}"
    echo ""
    echo -e "${green}[IPv4 规则]${plain}"
    local v4_rules=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "fami_")
    if [[ -z "$v4_rules" ]]; then
        echo -e "  ${yellow}无${plain}"
    else
        echo "$v4_rules" | while read line; do
            echo "  $line"
        done
    fi
    echo ""
    echo -e "${green}[IPv6 规则]${plain}"
    local v6_rules=$(ip6tables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "fami_")
    if [[ -z "$v6_rules" ]]; then
        echo -e "  ${yellow}无${plain}"
    else
        echo "$v6_rules" | while read line; do
            echo "  $line"
        done
    fi
}

portmap_delete_by_comment() {
    local cmd=$1
    local comment=$2
    local rules=$($cmd -t nat -S PREROUTING 2>/dev/null | grep "$comment")
    if [[ -z "$rules" ]]; then
        return
    fi
    echo "$rules" | while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^-A /-D /')
        eval "$cmd -t nat $line" 2>/dev/null
    done
}

portmap_delete() {
    # 收集所有唯一的 comment
    local comments=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -oP "fami_(HOP|PORTMAP)_[0-9_]+" | sort -u)
    local comments_v6=$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -oP "fami_(HOP|PORTMAP)_[0-9_]+" | sort -u)
    local all_comments=$(echo -e "${comments}\n${comments_v6}" | sort -u | grep -v '^$')

    if [[ -z "$all_comments" ]]; then
        echo -e "${yellow}当前没有通过此工具添加的端口映射规则${plain}"
        return
    fi

    echo -e "${green}===== 删除端口映射 =====${plain}"
    local i=1
    local comment_arr=()
    while IFS= read -r c; do
        # 解析 comment: fami_PORTMAP_<svcport>_<start>_<end>
        local parts=(${c//_/ })
        local svc_port=${parts[2]}
        local s_port=${parts[3]}
        local e_port=${parts[4]}
        echo -e "  ${green}${i}.${plain} UDP ${s_port}-${e_port} -> ${svc_port}"
        comment_arr+=("$c")
        ((i++))
    done <<< "$all_comments"
    echo -e "  ${green}a.${plain} 删除所有映射"
    echo -e "  ${green}0.${plain} 返回"

    read -rp "请选择: " choice
    case $choice in
        0) return ;;
        a|A)
            echo -e "${red}警告: 将删除所有通过此工具创建的端口映射规则!${plain}"
            read -rp "确定吗? [y/N]: " confirm_del
            if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                for c in "${comment_arr[@]}"; do
                    portmap_delete_by_comment "iptables" "$c"
                    portmap_delete_by_comment "ip6tables" "$c"
                done
                echo -e "${green}所有端口映射规则已删除${plain}"
            fi
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#comment_arr[@]}" ]]; then
                local target_comment="${comment_arr[$((choice-1))]}"
                portmap_delete_by_comment "iptables" "$target_comment"
                portmap_delete_by_comment "ip6tables" "$target_comment"
                echo -e "${green}映射规则已删除${plain}"
            else
                echo -e "${red}无效选择${plain}"
            fi
            ;;
    esac
}

portmap_menu() {
    while true; do
        echo -e ""
        echo -e "${green}===== UDP 端口映射管理 (Hysteria2 端口跳跃) =====${plain}"
        echo -e "  ${green}1.${plain} 添加端口映射"
        echo -e "  ${green}2.${plain} 查看当前映射"
        echo -e "  ${green}3.${plain} 删除端口映射"
        echo -e "  ${green}0.${plain} 返回主菜单"
        read -rp "请选择 [0-3]: " pm_choice
        case $pm_choice in
            1) portmap_add ;;
            2) portmap_list ;;
            3) portmap_delete ;;
            0) show_menu; return ;;
            *) echo -e "${red}无效选择${plain}" ;;
        esac
        echo ""
    done
}

# 放开防火墙端口
open_ports() {
    systemctl stop firewalld.service 2>/dev/null
    systemctl disable firewalld.service 2>/dev/null
    setenforce 0 2>/dev/null
    ufw disable 2>/dev/null
    iptables -P INPUT ACCEPT 2>/dev/null
    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -P OUTPUT ACCEPT 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -t mangle -F 2>/dev/null
    iptables -F 2>/dev/null
    iptables -X 2>/dev/null
    netfilter-persistent save 2>/dev/null
    echo -e "${green}放开防火墙端口成功！${plain}"
}

show_usage() {
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
    echo "kknode portmap      - 管理 UDP 端口映射"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}kknode 后端管理脚本，${plain}${red}不适用于docker${plain}
--- https://github.com/kcproxy/kknode ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 kknode
  ${green}2.${plain} 更新 kknode
  ${green}3.${plain} 卸载 kknode
————————————————
  ${green}4.${plain} 启动 kknode
  ${green}5.${plain} 停止 kknode
  ${green}6.${plain} 重启 kknode
  ${green}7.${plain} 锁定/解锁节点本地配置
  ${green}8.${plain} 查看 kknode 状态
  ${green}9.${plain} 查看 kknode 日志
————————————————
  ${green}10.${plain} 设置 kknode 开机自启
  ${green}11.${plain} 取消 kknode 开机自启
————————————————
  ${green}12.${plain} 查看 kknode 版本
  ${green}13.${plain} 升级 kknode 维护脚本
  ${green}14.${plain} 生成 kknode 配置文件
  ${green}15.${plain} 放行 VPS 的所有网络端口
  ${green}16.${plain} 管理 UDP 端口映射 (Hysteria2 端口跳跃)
  ${green}17.${plain} 退出脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -rp "请输入选择 [0-17]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && toggle_local_config ;;
        8) check_install && status ;;
        9) check_install && show_log ;;
        10) check_install && enable ;;
        11) check_install && disable ;;
        12) check_install && show_kknode_version ;;
        13) update_shell ;;
        14) generate_config_file ;;
        15) open_ports ;;
        16) portmap_menu ;;
        17) exit ;;
        *) echo -e "${red}请输入正确的数字 [0-17]${plain}" ;;
    esac
}


if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "update") check_install 0 && update 0 $2 ;;
        "config") config $* ;;
        "generate") generate_config_file ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "version") check_install 0 && show_kknode_version 0 ;;
        "update_shell") update_shell ;;
        "portmap") portmap_menu ;;
        *) show_usage
    esac
else
    show_menu
fi