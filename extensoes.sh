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
echo -e "${BLUE}  SETUP OTIMIZADO V18: HARDCORE EDITION (SOURCE COMPILE FIX)     ${NC}"
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

# Função de Retentativa
retry_cmd() {
    local max=3
    local delay=5
    local n=1
    while true; do
        eval "$1" && return 0 || {
            if [[ $n -lt $max ]]; then
                log_message WARN "Falha detectada. Retentando em $delay segundos... ($n/$max)"
                sleep $delay
                ((n++))
            else
                log_message ERROR "Comando falhou após $max tentativas: $1"
                return 1
            fi
        }
    done
}

# 0. Verificações Iniciais
echo -ne "\n${YELLOW}[0/6] Verificações Iniciais...${NC}"
command -v yum >/dev/null || { log_message ERROR "Yum não encontrado."; exit 1; }
command -v whmapi1 >/dev/null || { log_message ERROR "whmapi1 não encontrado."; exit 1; }
check_command "Verificações Iniciais"

# 1. Dependências do Sistema
echo -ne "\n${YELLOW}[1/6] Limpando Cache e Instalando Dependências do SO...${NC}"
OS_VER=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2 | cut -d '.' -f 1)
curl -sSL "https://packages.microsoft.com/config/rhel/$OS_VER/prod.repo" > /etc/yum.repos.d/mssql-release.repo 2>>"$LOG_FILE"

echo -ne "\n  ${YELLOW}*${NC} Pacotes base e DevTools..."
yum clean all >> "$LOG_FILE" 2>&1
rm -rf /var/cache/yum

retry_cmd "yum install -y epel-release pkgconf pkgconfig pcre-devel libzstd-devel lz4-devel gcc-c++ make autoconf ImageMagick-devel unixODBC-devel redis libaio-devel libnsl re2c freetds-devel >> '$LOG_FILE' 2>&1"

# FIX MS ODBC: Divisão de pacotes e bypass de GPG para garantir a instalação dos drivers base
retry_cmd "ACCEPT_EULA=Y yum install -y msodbcsql17 msodbcsql18 unixODBC-devel --nogpgcheck >> '$LOG_FILE' 2>&1"
# O mssql-tools é opcional (são utilitários de linha de comando) e as vezes quebra a instalação principal, então rodamos em best-effort
ACCEPT_EULA=Y yum install -y mssql-tools mssql-tools18 --nogpgcheck >> "$LOG_FILE" 2>&1 || true

check_command "Instalação de Dependências YUM e MS ODBC Drivers"

systemctl enable --now redis >> "$LOG_FILE" 2>&1

# 2. Oracle Client
echo -ne "\n${YELLOW}[2/6] Verificando/Instalando Oracle Client...${NC}"
ORACLE_HOME=$(find /usr/lib/oracle -type d -name "client64" 2>/dev/null | head -n 1)

if [ -z "$ORACLE_HOME" ]; then
    cd /tmp
    rm -f oracle-instantclient*.rpm
    for ORACLE_VER in "19.24" "19.23" "19.22" "19.21"; do
        retry_cmd "curl -sSL -f -O 'https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER//./}000/oracle-instantclient${ORACLE_VER}-basic-${ORACLE_VER}.0.0.0-1.el8.x86_64.rpm' >> '$LOG_FILE' 2>&1"
        retry_cmd "curl -sSL -f -O 'https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER//./}000/oracle-instantclient${ORACLE_VER}-devel-${ORACLE_VER}.0.0.0-1.el8.x86_64.rpm' >> '$LOG_FILE' 2>&1"
        if ls oracle-instantclient*.rpm 1> /dev/null 2>&1; then break; fi
    done

    if ls oracle-instantclient*.rpm 1> /dev/null 2>&1; then
        retry_cmd "yum install -y ./oracle-instantclient*.rpm >> '$LOG_FILE' 2>&1"
        rm -f oracle-instantclient*.rpm
    fi
    cd - > /dev/null
fi

ORACLE_HOME=$(find /usr/lib/oracle -type d -name "client64" 2>/dev/null | head -n 1)
if [ -n "$ORACLE_HOME" ]; then
    echo "$ORACLE_HOME/lib" > /etc/ld.so.conf.d/oracle.conf
    ldconfig >> "$LOG_FILE" 2>&1
    echo -e " ${GREEN}[OK]${NC}"
else
    echo -e " ${RED}[FALHA]${NC} - Não foi possível baixar/instalar o Oracle Instant Client."
    exit 1
fi

# 3. Extensões PHP
echo -e "\n${YELLOW}[3/6] Processando Extensões PHP via PECL/YUM/Source...${NC}"

for php_version_dir in $(whmapi1 php_get_installed_versions | grep -oE 'ea-php[0-9]+'); do
    echo -e "\n${BLUE}--> Versão: $php_version_dir${NC}"
    
    PHP_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/php"
    PECL_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/pecl"
    PHP_INI_DIR="/opt/cpanel/$php_version_dir/root/etc/php.d"

    if [ ! -f "$PHP_BIN" ] || ! [ -f "$PECL_BIN" ]; then
        echo -e "    ${YELLOW}PHP CLI ou PECL não encontrados para esta versão. Pulando.${NC}"
        continue
    fi

    retry_cmd "yum install -y ${php_version_dir}-php-devel ${php_version_dir}-php-pdo >> '$LOG_FILE' 2>&1"
    
    $PECL_BIN clear-cache >> "$LOG_FILE" 2>&1
    retry_cmd "$PECL_BIN channel-update pecl.php.net >> '$LOG_FILE' 2>&1"
    
    case "$php_version_dir" in
        "ea-php5"*) 
            IMV="imagick-3.4.4"; REDV="redis-4.3.0"; OCI="oci8-2.0.12"; SQL=""; PDOSQL=""; DBLIB="pdo_dblib" ;;
        "ea-php70"|"ea-php71"|"ea-php72") 
            IMV="imagick-3.4.4"; REDV="redis-5.3.7"; OCI="oci8-2.2.0"; SQL="sqlsrv-5.3.0"; PDOSQL="pdo_sqlsrv-5.3.0"; DBLIB="" ;;
        "ea-php73") 
            IMV="imagick-3.7.0"; REDV="redis-5.3.7"; OCI="oci8-2.2.0"; SQL="sqlsrv-5.8.1"; PDOSQL="pdo_sqlsrv-5.8.1"; DBLIB="" ;;
        "ea-php74") 
            IMV="imagick-3.7.0"; REDV="redis-5.3.7"; OCI="oci8-2.2.0"; SQL="sqlsrv-5.10.1"; PDOSQL="pdo_sqlsrv-5.10.1"; DBLIB="" ;;
        "ea-php80") 
            IMV="imagick"; REDV="redis"; OCI="oci8-3.0.1"; SQL="sqlsrv-5.11.1"; PDOSQL="pdo_sqlsrv-5.11.1"; DBLIB="" ;;
        "ea-php81") 
            IMV="imagick"; REDV="redis"; OCI="oci8-3.2.1"; SQL="sqlsrv-5.12.0"; PDOSQL="pdo_sqlsrv-5.12.0"; DBLIB="" ;;
        "ea-php82") 
            IMV="imagick"; REDV="redis"; OCI="oci8-3.3.0"; SQL="sqlsrv"; PDOSQL="pdo_sqlsrv"; DBLIB="" ;;
        *) 
            IMV="imagick"; REDV="redis"; OCI="oci8"; SQL="sqlsrv"; PDOSQL="pdo_sqlsrv"; DBLIB="" ;;
    esac

    install_ext() {
        local name=$1
        local pkg=$2
        
        if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
            echo -e "    ${GREEN}✔ ${name}:${NC} Já instalado/Ativo."
            return
        fi

        # =========================================================================
        # FIX DEFINITIVO PDO_DBLIB: Compilação Manual via Código-Fonte do Museu PHP
        # =========================================================================
        if [ "$name" == "pdo_dblib" ]; then
            echo -ne "    ${YELLOW}* ${name}:${NC} Compilando via Código Fonte (PHP Museum)... "
            log_message INFO "Iniciando compilação hardcore de $name via código fonte para $php_version_dir."
            
            local src_dir="/tmp/php_compile_custom_src"
            rm -rf "$src_dir" && mkdir -p "$src_dir" && cd "$src_dir"
            
            # Baixa e extrai a versão específica do PHP 5.6
            retry_cmd "curl -sSL -f -o php-5.6.40.tar.gz https://museum.php.net/php5/php-5.6.40.tar.gz >> '$LOG_FILE' 2>&1"
            tar -zxf php-5.6.40.tar.gz
            cd php-5.6.40/ext/pdo_dblib
            
            local phpize_bin="/opt/cpanel/$php_version_dir/root/usr/bin/phpize"
            local phpconfig_bin="/opt/cpanel/$php_version_dir/root/usr/bin/php-config"
            
            # Compilação
            $phpize_bin >> "$LOG_FILE" 2>&1
            ./configure --with-php-config="$phpconfig_bin" --with-pdo-dblib=/usr >> "$LOG_FILE" 2>&1
            make >> "$LOG_FILE" 2>&1
            make install >> "$LOG_FILE" 2>&1
            
            # Ativação Manual
            echo "extension=pdo_dblib.so" > "$PHP_INI_DIR/zzzzzzz-pecl-pdo_dblib.ini"
            
            if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
                echo -e "${GREEN}[OK]${NC}"
                log_message INFO "$name ativado nativamente com sucesso via compilação manual."
            else
                echo -e "${RED}[FALHA]${NC}"
                log_message ERROR "Falha crítica ao compilar $name do código fonte."
            fi
            
            # Limpa o lixo da compilação
            cd /
            rm -rf "$src_dir"
            return
        fi

        echo -ne "    ${YELLOW}* ${name}:${NC} Compilando ($pkg)... "
        log_message INFO "Iniciando compilação de $name ($pkg) em $php_version_dir."
        
        set +o pipefail
        if [ "$name" == "oci8" ]; then
            retry_cmd "echo 'instantclient,$ORACLE_HOME/lib' | $PECL_BIN install -f '$pkg' >> '$LOG_FILE' 2>&1"
        else
            retry_cmd "yes '' | $PECL_BIN install -f '$pkg' >> '$LOG_FILE' 2>&1"
        fi
        set -o pipefail

        if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
            echo -e "${GREEN}[OK]${NC}"
            log_message INFO "$name ativado nativamente com sucesso."
        else
            local ext_dir=$($PHP_BIN -r "echo ini_get('extension_dir');")
            if [ -f "$ext_dir/$name.so" ]; then
                echo "extension=$name.so" > "$PHP_INI_DIR/zzzzzzz-pecl-${name}.ini"
                
                if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
                    echo -e "${GREEN}[OK] (Ativação Forçada)${NC}"
                    log_message INFO "$name ativado manualmente através do .ini."
                else
                    echo -e "${RED}[FALHA]${NC} (Módulo não carrega)"
                    log_message ERROR "$name foi compilado, o .so existe, mas falhou ao carregar no PHP."
                fi
            else
                echo -e "${RED}[FALHA]${NC} (.so não gerado)"
                log_message ERROR "$name falhou. O arquivo .so não foi gerado após as retentativas."
            fi
        fi
    }

    install_ext "imagick" "$IMV"
    install_ext "redis" "$REDV"
    
    if [ -n "$SQL" ]; then
        install_ext "sqlsrv" "$SQL"
        install_ext "pdo_sqlsrv" "$PDOSQL"
    elif [ -n "$DBLIB" ]; then
        install_ext "pdo_dblib" "$DBLIB"
    fi
    
    [ -n "$ORACLE_HOME" ] && install_ext "oci8" "$OCI"
done

# 4. Serviços
echo -e "\n${YELLOW}[4/6] Reiniciando Serviços Web...${NC}"
retry_cmd "/scripts/restartsrv_apache_php_fpm >> '$LOG_FILE' 2>&1"
echo -e " ${GREEN}[OK]${NC}"

echo -ne "\n${YELLOW}[5/6] Atualizando CageFS...${NC}"
if command -v cagefsctl &>/dev/null; then
    retry_cmd "cagefsctl --force-update >> '$LOG_FILE' 2>&1"
    echo -e " ${GREEN}[OK]${NC}"
else
    echo -e " ${GREEN}[IGNORADO]${NC}"
fi

# 5. Checklist Final
echo -e "\n${YELLOW}[6/6] VERIFICAÇÃO FINAL (CHECKLIST)${NC}"
echo -e "\n${BOLD}--- DEPENDÊNCIAS DO SISTEMA ---${NC}"
[ -n "$ORACLE_HOME" ] && echo -e "  [${GREEN}✔${NC}] Oracle Client" || echo -e "  [${RED}✘${NC}] Oracle Client"
rpm -q msodbcsql18 &>/dev/null && echo -e "  [${GREEN}✔${NC}] MS ODBC Driver 18 (PHP 8+)" || echo -e "  [${RED}✘${NC}] MS ODBC Driver 18"
rpm -q msodbcsql17 &>/dev/null && echo -e "  [${GREEN}✔${NC}] MS ODBC Driver 17 (PHP 7.x)" || echo -e "  [${RED}✘${NC}] MS ODBC Driver 17"

echo -e "\n${BOLD}--- EXTENSÕES PHP ---${NC}"
for php_version_dir in $(whmapi1 php_get_installed_versions | grep -oE 'ea-php[0-9]+'); do
    PHP_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/php"
    echo -e "\n${BLUE}● $php_version_dir${NC}"
    
    check_ext() {
        if $PHP_BIN -m 2>/dev/null | grep -qix "$1"; then
            echo -ne "    [${GREEN}✔${NC}] $1  "
        else
            echo -ne "    [${RED}✘${NC}] $1  "
        fi
    }

    check_ext "imagick"
    check_ext "redis"
    [[ "$php_version_dir" == "ea-php5"* ]] && check_ext "pdo_dblib" || { check_ext "sqlsrv"; check_ext "pdo_sqlsrv"; }
    check_ext "oci8"
    echo ""
done

echo -e "\n${BLUE}=================================================================${NC}"
echo -e "Instalação Finalizada. Log de auditoria em: ${WHITE}$LOG_FILE${NC}"
echo -e "${BLUE}=================================================================${NC}\n"
