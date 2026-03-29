#!/bin/bash

# iptables 浜や簰寮忔祦閲忚浆鍙戣剼鏈?
# 閫傜敤浜?Debian/Ubuntu 绯荤粺
# 鍔熻兘锛氬皢鏈湴绔彛娴侀噺杞彂鍒拌繙绋嬫湇鍔″櫒

# 棰滆壊瀹氫箟
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 鍑芥暟锛氭墦鍗板甫棰滆壊鐨勪俊鎭?
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 鍑芥暟锛氭鏌oot鏉冮檺
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "姝よ剼鏈渶瑕乺oot鏉冮檺杩愯"
        echo "璇蜂娇鐢? sudo $0"
        exit 1
    fi
}

# 鍑芥暟锛氭鏌ョ郴缁?
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        print_error "姝よ剼鏈粎鏀寔Debian/Ubuntu绯荤粺"
        exit 1
    fi
}

# 鍑芥暟锛氬垵濮嬪寲鐜
init_environment() {
    # 妫€鏌ュ苟瀹夎渚濊禆
    if ! command -v iptables &> /dev/null; then
        print_info "姝ｅ湪瀹夎 iptables..."
        apt-get update -qq
        apt-get install -y iptables > /dev/null 2>&1
    fi
    
    # 妫€鏌ュ苟瀹夎iptables-persistent
    if ! dpkg -l | grep -q iptables-persistent; then
        print_info "姝ｅ湪瀹夎 iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent > /dev/null 2>&1
    fi
    
    # 妫€鏌ュ苟瀹夎dnsutils锛堢敤浜庡煙鍚嶈В鏋愶級
    if ! command -v nslookup &> /dev/null; then
        print_info "姝ｅ湪瀹夎 dnsutils..."
        apt-get install -y dnsutils > /dev/null 2>&1
    fi
    
    # 鍚敤IP杞彂
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) -ne 1 ]]; then
        print_info "鍚敤IP杞彂..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # 姘镐箙鍚敤
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        else
            sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        fi
        sysctl -p /etc/sysctl.conf > /dev/null 2>&1
    fi
}

# 鍑芥暟锛氳幏鍙栨湰鍦癐P
get_local_ip() {
    local ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    echo "$ip"
}

# 鍑芥暟锛氳В鏋愬煙鍚?
resolve_domain() {
    local domain=$1
    local ip=""
    
    # 妫€鏌ユ槸鍚︽槸IP鍦板潃
    if [[ "$domain" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$domain"
        return 0
    fi
    
    # 瑙ｆ瀽鍩熷悕锛堟棩蹇楄緭鍑哄埌stderr锛岄伩鍏嶆薄鏌搒tdout鐨勮繑鍥炲€硷級
    print_info "姝ｅ湪瑙ｆ瀽鍩熷悕: $domain" >&2
    ip=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | tail -1 | awk '{print $2}')
    
    if [[ -z "$ip" ]]; then
        # 灏濊瘯浣跨敤host鍛戒护
        ip=$(host "$domain" 2>/dev/null | grep "has address" | head -1 | awk '{print $4}')
    fi
    
    if [[ -z "$ip" ]]; then
        print_error "鏃犳硶瑙ｆ瀽鍩熷悕: $domain" >&2
        return 1
    fi
    
    print_info "鍩熷悕瑙ｆ瀽鎴愬姛: $domain -> $ip" >&2
    echo "$ip"
    return 0
}

# 鍑芥暟锛氶獙璇佺鍙?
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 鍑芥暟锛氭坊鍔犺浆鍙戣鍒?
add_forward_rule() {
    local protocol=$1
    local local_port=$2
    local remote_ip=$3
    local remote_port=$4
    local local_ip=$(get_local_ip)
    
    print_info "姝ｅ湪娣诲姞杞彂瑙勫垯..."
    
    # 娣诲姞TCP瑙勫垯
    if [[ "$protocol" == "tcp" ]] || [[ "$protocol" == "both" ]]; then
        # 妫€鏌ヨ鍒欐槸鍚﹀凡瀛樺湪
        if iptables -t nat -C PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port 2>/dev/null; then
            print_warning "TCP杞彂瑙勫垯宸插瓨鍦?
        else
            iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port
            iptables -t nat -A POSTROUTING -p tcp -d $remote_ip --dport $remote_port -j SNAT --to-source $local_ip
            iptables -A FORWARD -p tcp -d $remote_ip --dport $remote_port -j ACCEPT
            iptables -A FORWARD -p tcp -s $remote_ip --sport $remote_port -j ACCEPT
            print_info "TCP杞彂瑙勫垯宸叉坊鍔? $local_ip:$local_port -> $remote_ip:$remote_port"
        fi
    fi
    
    # 娣诲姞UDP瑙勫垯
    if [[ "$protocol" == "udp" ]] || [[ "$protocol" == "both" ]]; then
        # 妫€鏌ヨ鍒欐槸鍚﹀凡瀛樺湪
        if iptables -t nat -C PREROUTING -p udp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port 2>/dev/null; then
            print_warning "UDP杞彂瑙勫垯宸插瓨鍦?
        else
            iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port
            iptables -t nat -A POSTROUTING -p udp -d $remote_ip --dport $remote_port -j SNAT --to-source $local_ip
            iptables -A FORWARD -p udp -d $remote_ip --dport $remote_port -j ACCEPT
            iptables -A FORWARD -p udp -s $remote_ip --sport $remote_port -j ACCEPT
            print_info "UDP杞彂瑙勫垯宸叉坊鍔? $local_ip:$local_port -> $remote_ip:$remote_port"
        fi
    fi
    
    # 淇濆瓨瑙勫垯
    netfilter-persistent save > /dev/null 2>&1
    print_info "瑙勫垯宸蹭繚瀛樺苟鎸佷箙鍖?
}

# 鍑芥暟锛氭墽琛岃浆鍙戣缃?
setup_forward() {
    local protocol=$1
    local protocol_name=$2
    
    echo ""
    echo -e "${CYAN}========== 璁剧疆${protocol_name}杞彂 ==========${NC}"
    echo ""
    
    # 杈撳叆鏈湴绔彛
    local local_port=""
    while true; do
        read -p "璇疯緭鍏ユ湰鏈洪渶瑕佽浆鍙戠殑绔彛 (1-65535): " local_port
        if validate_port "$local_port"; then
            break
        else
            print_error "鏃犳晥鐨勭鍙ｅ彿锛岃杈撳叆1-65535涔嬮棿鐨勬暟瀛?
        fi
    done
    
    # 杈撳叆杩滅▼鍦板潃
    local remote_address=""
    local remote_ip=""
    while true; do
        echo ""
        read -p "璇疯緭鍏ラ渶瑕佽浆鍙戝埌鐨勭洰鏍囧湴鍧€ (鏀寔IP鎴栧煙鍚?: " remote_address
        
        # 瑙ｆ瀽鍦板潃
        remote_ip=$(resolve_domain "$remote_address")
        if [[ $? -eq 0 ]] && [[ -n "$remote_ip" ]]; then
            break
        else
            print_error "鏃犳晥鐨勫湴鍧€鎴栧煙鍚嶆棤娉曡В鏋愶紝璇烽噸鏂拌緭鍏?
        fi
    done
    
    # 杈撳叆杩滅▼绔彛
    local remote_port=""
    while true; do
        echo ""
        read -p "璇疯緭鍏ョ洰鏍囨湇鍔″櫒鐨勭鍙?(1-65535): " remote_port
        if validate_port "$remote_port"; then
            break
        else
            print_error "鏃犳晥鐨勭鍙ｅ彿锛岃杈撳叆1-65535涔嬮棿鐨勬暟瀛?
        fi
    done
    
    # 纭淇℃伅
    echo ""
    echo -e "${YELLOW}========== 纭杞彂淇℃伅 ==========${NC}"
    echo -e "杞彂鍗忚: ${GREEN}${protocol_name}${NC}"
    echo -e "鏈湴绔彛: ${GREEN}${local_port}${NC}"
    echo -e "鐩爣鍦板潃: ${GREEN}${remote_address}${NC}"
    if [[ "$remote_address" != "$remote_ip" ]]; then
        echo -e "瑙ｆ瀽鍚嶪P: ${GREEN}${remote_ip}${NC}"
    fi
    echo -e "鐩爣绔彛: ${GREEN}${remote_port}${NC}"
    echo ""
    
    read -p "纭娣诲姞姝よ浆鍙戣鍒欏悧锛?y/n): " confirm
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        add_forward_rule "$protocol" "$local_port" "$remote_ip" "$remote_port"
        echo ""
        print_info "杞彂瑙勫垯娣诲姞鎴愬姛锛?
    else
        print_warning "宸插彇娑堟坊鍔犺鍒?
    fi
    
    echo ""
    read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
}

# 鍑芥暟锛氭樉绀哄綋鍓嶈鍒?
show_current_rules() {
    clear
    echo -e "${CYAN}========== 褰撳墠杞彂瑙勫垯 ==========${NC}"
    echo ""
    
    # 鍙樉绀篋NAT杞彂瑙勫垯锛堟渶鏍稿績鐨勮鍒欙級
    echo -e "${YELLOW}褰撳墠杞彂瑙勫垯鍒楄〃:${NC}"
    echo "-------------------------------------------------------------------"
    printf "%-5s %-8s %-20s %-30s\n" "缂栧彿" "鍗忚" "鏈湴绔彛" "鐩爣鍦板潃"
    echo "-------------------------------------------------------------------"
    
    # 鑾峰彇瑙勫垯
    iptables -t nat -L PREROUTING -n --line-numbers | grep "dpt:" | while read line; do
        num=$(echo "$line" | awk '{print $1}')
        proto=$(echo "$line" | awk '{print $4}')
        local_port=$(echo "$line" | grep -oP 'dpt:\K[0-9]+')
        dest=$(echo "$line" | grep -oP 'to:\K[0-9.]+:[0-9]+')
        printf "%-5s %-8s %-20s %-30s\n" "$num" "$proto" "$local_port" "$dest"
    done
    
    echo "-------------------------------------------------------------------"
    echo ""
    read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
}

# 鍑芥暟锛氬垹闄よ鍒?
delete_rules() {
    clear
    echo -e "${CYAN}========== 鍒犻櫎杞彂瑙勫垯 ==========${NC}"
    echo ""
    
    # 鏄剧ず褰撳墠瑙勫垯鍒楄〃
    echo -e "${YELLOW}褰撳墠杞彂瑙勫垯鍒楄〃:${NC}"
    echo "-------------------------------------------------------------------"
    printf "%-5s %-8s %-20s %-30s\n" "缂栧彿" "鍗忚" "鏈湴绔彛" "鐩爣鍦板潃"
    echo "-------------------------------------------------------------------"
    
    # 淇濆瓨瑙勫垯鍒版暟缁?
    declare -a rule_nums
    declare -a rule_details
    local index=0
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "dpt:"; then
            num=$(echo "$line" | awk '{print $1}')
            proto=$(echo "$line" | awk '{print $4}')
            local_port=$(echo "$line" | grep -oP 'dpt:\K[0-9]+')
            dest=$(echo "$line" | grep -oP 'to:\K[0-9.]+:[0-9]+')
            printf "%-5s %-8s %-20s %-30s\n" "$num" "$proto" "$local_port" "$dest"
            rule_nums[$index]=$num
            rule_details[$index]="$proto $local_port -> $dest"
            ((index++))
        fi
    done < <(iptables -t nat -L PREROUTING -n --line-numbers)
    
    echo "-------------------------------------------------------------------"
    
    if [[ $index -eq 0 ]]; then
        print_warning "娌℃湁鎵惧埌浠讳綍杞彂瑙勫垯"
        echo ""
        read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
        return
    fi
    
    echo ""
    echo "鎻愮ず: 鍙互杈撳叆鍗曚釜缂栧彿鎴栧涓紪鍙?鐢ㄨ嫳鏂囬€楀彿鍒嗛殧锛屽: 1,3,5)"
    echo "      杈撳叆 0 杩斿洖涓昏彍鍗?
    echo ""
    read -p "璇疯緭鍏ヨ鍒犻櫎鐨勮鍒欑紪鍙? " rule_input
    
    if [[ "$rule_input" == "0" ]]; then
        return
    fi
    
    # 瑙ｆ瀽杈撳叆鐨勮鍒欑紪鍙?
    IFS=',' read -ra selected_rules <<< "$rule_input"
    
    # 楠岃瘉鎵€鏈夎緭鍏ョ殑缂栧彿
    declare -a valid_rules
    declare -a valid_details
    local valid_count=0
    
    for rule_num in "${selected_rules[@]}"; do
        # 鍘婚櫎绌烘牸
        rule_num=$(echo "$rule_num" | tr -d ' ')
        
        # 妫€鏌ユ槸鍚︿负鏁板瓧
        if [[ ! "$rule_num" =~ ^[0-9]+$ ]]; then
            print_error "鏃犳晥鐨勮鍒欑紪鍙? $rule_num"
            continue
        fi
        
        # 妫€鏌ヨ鍒欐槸鍚﹀瓨鍦?
        local found=0
        for i in "${!rule_nums[@]}"; do
            if [[ "${rule_nums[$i]}" == "$rule_num" ]]; then
                valid_rules[$valid_count]=$rule_num
                valid_details[$valid_count]="${rule_details[$i]}"
                ((valid_count++))
                found=1
                break
            fi
        done
        
        if [[ $found -eq 0 ]]; then
            print_error "鏈壘鍒拌鍒欑紪鍙? $rule_num"
        fi
    done
    
    if [[ $valid_count -eq 0 ]]; then
        print_warning "娌℃湁鏈夋晥鐨勮鍒欑紪鍙?
        echo ""
        read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
        return
    fi
    
    # 鏄剧ず灏嗚鍒犻櫎鐨勮鍒?
    echo ""
    echo -e "${YELLOW}灏嗚鍒犻櫎浠ヤ笅瑙勫垯:${NC}"
    for i in "${!valid_rules[@]}"; do
        echo "  瑙勫垯 ${valid_rules[$i]}: ${valid_details[$i]}"
    done
    
    echo ""
    read -p "纭鍒犻櫎杩欎簺瑙勫垯鍚楋紵(y/n): " confirm
    
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        # 浠庡ぇ鍒板皬鎺掑簭瑙勫垯缂栧彿锛岄伩鍏嶅垹闄ゆ椂缂栧彿鍙樺寲
        # 浣跨敤 printf 鍜?sort 鏉ユ纭鐞嗗浣嶆暟瀛楁帓搴?
        local sorted_rules=($(printf "%s\n" "${valid_rules[@]}" | sort -rn))
        
        local success_count=0
        local fail_count=0
        
        # 鍒犻櫎瑙勫垯
        # 娉ㄦ剰锛氳繖閲屽彧鍒犻櫎浜哖REROUTING瑙勫垯锛屼笌涔嬪叧鑱旂殑POSTROUTING鍜孎ORWARD瑙勫垯浼氫繚鐣欙紝
        # 浣嗗洜涓哄叆鍙ｈ鍒欏凡鍒犻櫎锛屽畠浠笉浼氳鍖归厤鍒帮紝閫氬父鏃犲銆?
        print_info "姝ｅ湪鍒犻櫎瑙勫垯..."
        for rule_num in "${sorted_rules[@]}"; do
            if iptables -t nat -D PREROUTING $rule_num 2>/dev/null; then
                print_info "宸插垹闄よ鍒?$rule_num"
                ((success_count++))
            else
                print_error "鍒犻櫎瑙勫垯 $rule_num 澶辫触"
                ((fail_count++))
            fi
        done
        
        # 淇濆瓨瑙勫垯
        netfilter-persistent save > /dev/null 2>&1
        
        echo ""
        if [[ $success_count -gt 0 ]]; then
            print_info "鎴愬姛鍒犻櫎 $success_count 鏉¤鍒欏苟宸叉寔涔呭寲"
        fi
        if [[ $fail_count -gt 0 ]]; then
            print_warning "鍒犻櫎澶辫触 $fail_count 鏉¤鍒?
        fi
    else
        print_warning "宸插彇娑堝垹闄?
    fi
    
    echo ""
    read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
}

# 鍑芥暟锛氬浠借鍒?
backup_rules() {
    clear
    echo -e "${CYAN}========== 澶囦唤iptables瑙勫垯 ==========${NC}"
    echo ""
    
    local default_path="/root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules"
    local backup_path=""
    
    read -p "璇疯緭鍏ュ浠芥枃浠惰矾寰?[榛樿: ${default_path}]: " backup_path
    if [[ -z "$backup_path" ]]; then
        backup_path="$default_path"
    fi
    
    # 妫€鏌ユ枃浠舵槸鍚﹀瓨鍦?
    if [[ -f "$backup_path" ]]; then
        print_warning "鏂囦欢宸插瓨鍦? $backup_path"
        read -p "鏄惁瑕嗙洊锛?(y/n): " confirm
        if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
            print_info "宸插彇娑堝浠?
            echo ""
            read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
            return
        fi
    fi
    
    print_info "姝ｅ湪澶囦唤瑙勫垯鍒?$backup_path ..."
    if iptables-save > "$backup_path"; then
        print_info "瑙勫垯澶囦唤鎴愬姛锛?
    else
        print_error "瑙勫垯澶囦唤澶辫触锛?
    fi
    
    echo ""
    read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
}

# 鍑芥暟锛氭仮澶嶈鍒?
restore_rules() {
    clear
    echo -e "${CYAN}========== 鎭㈠iptables瑙勫垯 ==========${NC}"
    echo ""
    
    local backup_path=""
    read -p "璇疯緭鍏ヨ鎭㈠鐨勫浠芥枃浠惰矾寰? " backup_path
    
    if [[ ! -f "$backup_path" ]]; then
        print_error "澶囦唤鏂囦欢涓嶅瓨鍦? $backup_path"
        echo ""
        read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
        return
    fi
    
    echo ""
    print_warning "璀﹀憡锛氭仮澶嶆搷浣滃皢瑕嗙洊鎵€鏈夌幇鏈塱ptables瑙勫垯锛?
    read -p "纭浠?$backup_path 鎭㈠瑙勫垯鍚楋紵 (y/n): " confirm
    
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
        print_info "姝ｅ湪浠?$backup_path 鎭㈠瑙勫垯..."
        if iptables-restore < "$backup_path"; then
            print_info "瑙勫垯鎭㈠鎴愬姛锛?
            print_info "姝ｅ湪鎸佷箙鍖栬鍒?.."
            netfilter-persistent save > /dev/null 2>&1
            print_info "瑙勫垯宸叉寔涔呭寲锛?
        else
            print_error "瑙勫垯鎭㈠澶辫触锛佽妫€鏌ュ浠芥枃浠舵牸寮忔槸鍚︽纭€?
        fi
    else
        print_warning "宸插彇娑堟仮澶嶆搷浣?
    fi
    
    echo ""
    read -p "鎸夊洖杞﹂敭杩斿洖涓昏彍鍗?.."
}

# 鍑芥暟锛氭樉绀轰富鑿滃崟
show_menu() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${CYAN}          IPTables 娴侀噺杞彂绠＄悊宸ュ叿${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo -e "${GREEN}璇烽€夋嫨鎿嶄綔:${NC}"
    echo ""
    echo "  1. 杞彂 TCP+UDP"
    echo "  2. 杞彂 TCP"
    echo "  3. 杞彂 UDP"
    echo "  4. 鏌ョ湅褰撳墠瑙勫垯"
    echo "  5. 鍒犻櫎杞彂瑙勫垯"
    echo "  6. 澶囦唤杞彂瑙勫垯"
    echo "  7. 鎭㈠杞彂瑙勫垯"
    echo "  0. 閫€鍑鸿剼鏈?
    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "鏈満IP: ${GREEN}$(get_local_ip)${NC}"
    echo -e "IP杞彂: ${GREEN}$([ $(cat /proc/sys/net/ipv4/ip_forward) -eq 1 ] && echo "宸插惎鐢? || echo "鏈惎鐢?)${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# 涓诲嚱鏁?
main() {
    # 妫€鏌ユ潈闄愬拰绯荤粺
    check_root
    check_system
    
    # 鍒濆鍖栫幆澧?
    print_info "姝ｅ湪鍒濆鍖栫幆澧?.."
    init_environment
    
    # 涓诲惊鐜?
    while true; do
        show_menu
        
        read -p "璇疯緭鍏ラ€夐」 (0-7): " choice
        
        case $choice in
            1)
                setup_forward "both" "TCP+UDP"
                ;;
            2)
                setup_forward "tcp" "TCP"
                ;;
            3)
                setup_forward "udp" "UDP"
                ;;
            4)
                show_current_rules
                ;;
            5)
                delete_rules
                ;;
            6)
                backup_rules
                ;;
            7)
                restore_rules
                ;;
            0)
                echo ""
                print_info "鎰熻阿浣跨敤锛屽啀瑙侊紒"
                exit 0
                ;;
            *)
                print_error "鏃犳晥鐨勯€夐」锛岃閲嶆柊閫夋嫨"
                sleep 2
                ;;
        esac
    done
}

# 鍚姩鑴氭湰
main
