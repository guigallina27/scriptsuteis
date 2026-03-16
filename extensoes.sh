#!/bin/bash
set -uo pipefail

# Cores e Formatação
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${BLUE}=================================================================${NC}"
echo -e "${BLUE}   SETUP OTIMIZADO V17: PHP 8.1/8.2 + MELHORIAS (2026)          ${NC}"
echo -e "${BLUE}=================================================================${NC}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="./setup_debug_${TIMESTAMP}.log"
echo "--- LOG DE INSTALAÇÃO (Iniciado em $(date)) ---" > "$LOG_FILE"

log_message() {
    local type=$1
    local message=$2
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$type] $message" | tee -a "$LOG_FILE"
}

check_command() {
    local step_name=$1
    if [ $? -eq 0 ]; then
        echo -e " ${GREEN}[OK]${NC}"
        log_message INFO "$step_name: Sucesso."
    else
        echo -e " ${RED}[FALHA]${NC}"
        log_message ERROR "$step_name: FALHA. Verifique o log."
        exit 1
    fi
}

# [0/5] Verificações Iniciais
echo -ne "\n${YELLOW}[0/5] Verificações Iniciais...${NC}"
command -v yum >/dev/null || { log_message ERROR "Yum não encontrado."; exit 1; }
command -v whmapi1 >/dev/null || { log_message ERROR "whmapi1 não encontrado."; exit 1; }
check_command "Verificações Iniciais"

# [1/5] Dependências do Sistema
echo -ne "\n${YELLOW}[1/5] Instalando Dependências...${NC}"
OS_VER=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2 | cut -d '.' -f 1)

case "$OS_VER" in 7|8|9) ;; *) log_message ERROR "OS $OS_VER não suportado (7/8/9)."; exit 1 ;; esac

echo -ne "  ${YELLOW}*${NC} Repo MS ODBC... "
curl -sSL "https://packages.microsoft.com/config/rhel/$OS_VER/prod.repo" | tee /etc/yum.repos.d/mssql-release.repo >/dev/null
check_command "Repo MS ODBC"

echo -ne "  ${YELLOW}*${NC} Pacotes base... "
yum install -y epel-release pkgconf pkgconfig pcre-devel libzstd-devel lz4-devel gcc-c++ make autoconf \
    ImageMagick-devel unixODBC-devel redis libaio-devel libnsl re2c freetds-devel >> "$LOG_FILE" 2>&1
yum clean all >> "$LOG_FILE" 2>&1

ACCEPT_EULA=Y yum install -y msodbcsql18 msodbcsql17 mssql-tools unixODBC-devel >> "$LOG_FILE" 2>&1
check_command "MS ODBC Drivers"

systemctl enable --now redis >> "$LOG_FILE" 2>&1
check_command "Redis"

# [2/5] Oracle Client
echo -ne "\n${YELLOW}[2/5] Oracle Client...${NC}"
ORACLE_HOME=$(find /usr/lib/oracle -type d -name "client64" 2>/dev/null | head -n 1)

if [ -z "$ORACLE_HOME" ]; then
    cd /tmp && rm -f oracle-instantclient*.rpm
    
    # Repo oficial primeiro
    if yum install -y oracle-instantclient19.28-basic oracle-instantclient19.28-devel >> "$LOG_FILE" 2>&1; then
        log_message INFO "Oracle via repo oficial."
    else
        for VER in "19.28" "19.26" "23.6"; do
            curl -sSL -f -O "https://yum.oracle.com/repo/OracleLinux/OL8/oracle/instantclient/x86_64/getPackage/oracle-instantclient${VER}-basic-${VER}.0.0.0-1.el8.x86_64.rpm" >> "$LOG_FILE" 2>&1
            curl -sSL -f -O "https://yum.oracle.com/repo/OracleLinux/OL8/oracle/instantclient/x86_64/getPackage/oracle-instantclient${VER}-devel-${VER}.0.0.0-1.el8.x86_64.rpm" >> "$LOG_FILE" 2>&1
            if ls oracle-instantclient*.rpm >/dev/null 2>&1; then
                yum install -y ./oracle-instantclient*.rpm >> "$LOG_FILE" 2>&1
                rm -f oracle-instantclient*.rpm
                break
            fi
        done || { log_message ERROR "Falha Oracle download."; exit 1; }
    fi
    cd -
fi

ORACLE_HOME=$(find /usr/lib/oracle -type d -name "client64" 2>/dev/null | head -n 1)
if [ -n "$ORACLE_HOME" ]; then
    echo "$ORACLE_HOME/lib" > /etc/ld.so.conf.d/oracle.conf
    ldconfig >> "$LOG_FILE" 2>&1
    echo -e " ${GREEN}[OK]${NC}"
else
    echo -e " ${RED}[FALHA]${NC}"; exit 1
fi

# [3/5] Extensões PHP
echo -e "\n${YELLOW}[3/5] Extensões PHP (8.1/8.2)...${NC}"

TARGET_PHP=(ea-php81 ea-php82)
PHP_VERSIONS=$(whmapi1 php_get_installed_versions | grep -oE 'ea-php[0-9]+')

for php_version_dir in "${TARGET_PHP[@]}" $PHP_VERSIONS; do
    [[ "$php_version_dir" != ea-php8[12]* ]] && continue
    
    echo -e "\n${BLUE}--> $php_version_dir${NC}"
    PHP_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/php"
    PECL_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/pecl"
    PHP_INI_DIR="/opt/cpanel/$php_version_dir/root/etc/php.d"

    [[ ! -f "$PHP_BIN" || ! -f "$PECL_BIN" ]] && { echo "    ${RED}PHP não encontrado${NC}"; continue; }

    yum install -y ${php_version_dir}-php-devel ${php_version_dir}-php-pdo >> "$LOG_FILE" 2>&1
    $PECL_BIN channel-update pecl.php.net >> "$LOG_FILE" 2>&1
    $PECL_BIN clear-cache >> "$LOG_FILE" 2>&1

    install_ext() {
        local name=$1 pkg=$2
        $PHP_BIN -m 2>/dev/null | grep -qix "$name" && { echo "    ${GREEN}✔ $name${NC}"; return; }

        echo -ne "    ${YELLOW}* $name...${NC} "
        set +o pipefail
        [[ "$name" == "oci8" ]] && printf "instantclient,$ORACLE_HOME/lib\n\n\n" | $PECL_BIN install -f "$pkg" >> "$LOG_FILE" 2>&1 \
                                 || printf "\n\n\n" | $PECL_BIN install -f "$pkg" >> "$LOG_FILE" 2>&1
        set -o pipefail

        local ext_dir=$($PHP_BIN -r "echo ini_get('extension_dir');")
        if $PHP_BIN -m 2>/dev/null | grep -qix "$name" || ([ -f "$ext_dir/$name.so" ] && echo "extension=$name" > "$PHP_INI_DIR/zz-pecl-${name}.ini" && $PHP_BIN -m 2>/dev/null | grep -qix "$name"); then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${RED}[FALHA]${NC}"
        fi
    }

    install_ext imagick imagick
    install_ext redis redis
    install_ext sqlsrv sqlsrv
    install_ext pdo_sqlsrv pdo_sqlsrv
    [ -n "$ORACLE_HOME" ] && install_ext oci8 oci8
done

# [4/5] Serviços
echo -e "\n${YELLOW}[4/5] Serviços...${NC}"
/scripts/restartsrv_apache_php_fpm >> "$LOG_FILE" 2>&1
check_command "Apache/PHP-FPM"

# [5/5] CageFS + Checklist
echo -ne "\n${YELLOW}[5/5] CageFS...${NC}"
command -v cagefsctl &>/dev/null && { cagefsctl --force-update >> "$LOG_FILE" 2>&1; echo -e " ${GREEN}[OK]${NC}"; } || echo -e " ${GREEN}[IGN]${NC}"

echo -e "\n${BOLD}CHECKLIST FINAL${NC}"
echo -e "${BOLD}--- SISTEMA ---${NC}"
[ -n "$ORACLE_HOME" ] && echo "  ✔ Oracle ($ORACLE_HOME)" || echo "  ✘ Oracle"
rpm -q msodbcsql18 >/dev/null && echo "  ✔ ODBC 18" || echo "  ✘ ODBC 18"

echo -e "\n${BOLD}--- PHP 8.1/8.2 ---${NC}"
for php_version_dir in ea-php81 ea-php82; do
    PHP_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/php"
    [[ -f "$PHP_BIN" ]] || continue
    echo -e "${BLUE}● $php_version_dir${NC}"
    for ext in imagick redis sqlsrv pdo_sqlsrv oci8; do
        $PHP_BIN -m 2>/dev/null | grep -qix "$ext" && echo "  ✔ $ext" || echo "  ✘ $ext"
    done
done

echo -e "\n${BLUE}Log: $LOG_FILE${NC}"
echo -e "${BLUE}=================================================================${NC}"
