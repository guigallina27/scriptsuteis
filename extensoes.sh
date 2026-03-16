#!/bin/bash
set -uo pipefail

LOG_FILE="/var/log/php_ext_install.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'

log_message() {
    local type="$1"; shift
    local message="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$type] $message" | tee -a "$LOG_FILE"
}

tail_log() { tail -n 40 "$LOG_FILE" >&2; }

check_command() {
    local step_name="$1"
    if [[ $? -eq 0 ]]; then
        echo -e " ${GREEN}[OK]${NC}"
        log_message INFO "$step_name: Sucesso."
    else
        echo -e " ${RED}[FALHA]${NC}"
        log_message ERROR "$step_name: FALHA. Verifique o log."
        tail_log
        exit 1
    fi
}

retry_cmd() {
    local cmd="$1"
    local max=3 delay=5 n=1
    while true; do
        if eval "$cmd"; then return 0; fi
        if [[ $n -lt $max ]]; then
            log_message WARN "Falha detectada. Retentando em $delay segundos... ($n/$max)"
            sleep $delay; ((n++))
        else
            log_message ERROR "Comando falhou após $max tentativas: $cmd"
            tail_log
            return 1
        fi
    done
}

# 0. Verificações Iniciais
echo -ne "\n${YELLOW}[0/6] Verificações Iniciais de Sistema...${NC}"
command -v dnf >/dev/null || command -v yum >/dev/null || { log_message ERROR "Gerenciador de pacotes não encontrado."; exit 1; }
command -v whmapi1 >/dev/null || { log_message ERROR "whmapi1 não encontrado (Sistema cPanel requerido)."; exit 1; }
check_command "Verificações Iniciais"

# 1. Dependências do Sistema
echo -ne "\n${YELLOW}[1/6] Configurando Repositórios e Dependências do SO...${NC}"
OS_VER=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2 | cut -d '.' -f 1)

if [[ "$OS_VER" -ge 9 ]]; then
    dnf config-manager --set-enabled crb >> "$LOG_FILE" 2>&1
else
    dnf config-manager --set-enabled powertools >> "$LOG_FILE" 2>&1 || true
fi

curl -sSL "https://packages.microsoft.com/config/rhel/$OS_VER/prod.repo" > /etc/yum.repos.d/mssql-release.repo 2>>"$LOG_FILE"

echo -ne "\n  ${YELLOW}*${NC} Instalando Pacotes Base e DevTools..."
dnf clean all >> "$LOG_FILE" 2>&1
rm -rf /var/cache/yum

retry_cmd "dnf install -y epel-release pkgconf pkgconfig pcre-devel libzstd-devel lz4-devel gcc-c++ make autoconf ImageMagick-devel unixODBC unixODBC-devel redis libaio-devel libnsl re2c freetds-devel >> '$LOG_FILE' 2>&1"

install_ms_odbc() {
    local repo="packages-microsoft-com-prod"
    retry_cmd "dnf clean metadata --disablerepo='*' --enablerepo='$repo' >> '$LOG_FILE' 2>&1"
    retry_cmd "dnf makecache --disablerepo='*' --enablerepo='$repo' >> '$LOG_FILE' 2>&1"
    retry_cmd "ACCEPT_EULA=Y dnf install -y --disablerepo='*' --enablerepo='$repo' msodbcsql18 mssql-tools18 --nogpgcheck >> '$LOG_FILE' 2>&1" \
      || retry_cmd "ACCEPT_EULA=Y dnf install -y --disablerepo='*' --enablerepo='$repo' msodbcsql17 mssql-tools --nogpgcheck >> '$LOG_FILE' 2>&1"
}
install_ms_odbc

check_command "Instalação de Dependências e Drivers OS"
systemctl enable --now redis >> "$LOG_FILE" 2>&1

# 2. Oracle Client
echo -ne "\n${YELLOW}[2/6] Verificando/Instalando Oracle Instant Client...${NC}"
ORACLE_HOME=$(find /usr/lib/oracle -type d -name "client64" 2>/dev/null | head -n 1)
if [[ -z "$ORACLE_HOME" ]]; then
    cd /tmp
    rm -f oracle-instantclient*.rpm
    for ORACLE_VER in "21.12" "21.8" "19.24" "19.23"; do
        retry_cmd "curl -sSL -f -O 'https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER//./}000/oracle-instantclient-basic-${ORACLE_VER}.0.0.0-1.el${OS_VER}.x86_64.rpm' >> '$LOG_FILE' 2>&1" || \
        retry_cmd "curl -sSL -f -O 'https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER//./}000/oracle-instantclient${ORACLE_VER}-basic-${ORACLE_VER}.0.0.0-1.el${OS_VER}.x86_64.rpm' >> '$LOG_FILE' 2>&1"
        retry_cmd "curl -sSL -f -O 'https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER//./}000/oracle-instantclient-devel-${ORACLE_VER}.0.0.0-1.el${OS_VER}.x86_64.rpm' >> '$LOG_FILE' 2>&1" || \
        retry_cmd "curl -sSL -f -O 'https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER//./}000/oracle-instantclient${ORACLE_VER}-devel-${ORACLE_VER}.0.0.0-1.el${OS_VER}.x86_64.rpm' >> '$LOG_FILE' 2>&1"
        ls oracle-instantclient*.rpm >/dev/null 2>&1 && break
    done
    if ls oracle-instantclient*.rpm >/dev/null 2>&1; then
        retry_cmd "dnf install -y ./oracle-instantclient*.rpm >> '$LOG_FILE' 2>&1"
        rm -f oracle-instantclient*.rpm
    fi
    cd - > /dev/null
fi
ORACLE_HOME=$(find /usr/lib/oracle -type d -name "client64" 2>/dev/null | head -n 1)
if [[ -n "$ORACLE_HOME" ]]; then
    echo "$ORACLE_HOME/lib" > /etc/ld.so.conf.d/oracle.conf
    ldconfig >> "$LOG_FILE" 2>&1
    echo -e " ${GREEN}[OK]${NC}"
else
    echo -e " ${RED}[FALHA]${NC} - Oracle Client não foi resolvido. A extensão OCI8 poderá falhar."
fi

# 3. Extensões PHP
echo -e "\n${YELLOW}[3/6] Processando Extensões PHP via Matriz de Versão (PECL/Source)...${NC}"

for php_version_dir in $(whmapi1 php_get_installed_versions | grep -oE 'ea-php[0-9]+'); do
    echo -e "\n${BLUE}--> Versão Analisada: $php_version_dir${NC}"

    PHP_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/php"
    PECL_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/pecl"
    PHP_INI_DIR="/opt/cpanel/$php_version_dir/root/etc/php.d"

    if [[ ! -x "$PHP_BIN" || ! -x "$PECL_BIN" ]]; then
        echo -e "    ${YELLOW}Binários CLI/PECL não encontrados para $php_version_dir. Pulando.${NC}"
        continue
    fi

    retry_cmd "dnf install -y ${php_version_dir}-php-devel ${php_version_dir}-php-pdo >> '$LOG_FILE' 2>&1"
    $PECL_BIN clear-cache >> "$LOG_FILE" 2>&1
    retry_cmd "$PECL_BIN channel-update pecl.php.net >> '$LOG_FILE' 2>&1"

    case "$php_version_dir" in
        "ea-php5"*) IMV="imagick-3.4.4"; REDV="redis-2.2.8"; OCI="oci8-2.0.12"; SQL=""; PDOSQL=""; DBLIB="pdo_dblib" ;;
        "ea-php70"|"ea-php71"|"ea-php72") IMV="imagick-3.4.4"; REDV="redis-5.3.7"; OCI="oci8-2.2.0"; SQL="sqlsrv-5.3.0"; PDOSQL="pdo_sqlsrv-5.3.0"; DBLIB="" ;;
        "ea-php73") IMV="imagick-3.7.0"; REDV="redis-5.3.7"; OCI="oci8-2.2.0"; SQL="sqlsrv-5.8.1"; PDOSQL="pdo_sqlsrv-5.8.1"; DBLIB="" ;;
        "ea-php74") IMV="imagick-3.7.0"; REDV="redis-5.3.7"; OCI="oci8-2.2.0"; SQL="sqlsrv-5.10.1"; PDOSQL="pdo_sqlsrv-5.10.1"; DBLIB="" ;;
        "ea-php80") IMV="imagick"; REDV="redis"; OCI="oci8-3.0.1"; SQL="sqlsrv-5.11.1"; PDOSQL="pdo_sqlsrv-5.11.1"; DBLIB="" ;;
        "ea-php81") IMV="imagick"; REDV="redis"; OCI="oci8-3.2.1"; SQL="sqlsrv-5.12.0"; PDOSQL="pdo_sqlsrv-5.12.0"; DBLIB="" ;;
        "ea-php82") IMV="imagick"; REDV="redis"; OCI="oci8-3.3.0"; SQL="sqlsrv"; PDOSQL="pdo_sqlsrv"; DBLIB="" ;;
        *) IMV="imagick"; REDV="redis"; OCI="oci8"; SQL="sqlsrv"; PDOSQL="pdo_sqlsrv"; DBLIB="" ;;
    esac

    install_ext() {
        local name="$1" pkg="$2"
        if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
            echo -e "    ${GREEN}✔ ${name}:${NC} Já ativo nativamente."
            return
        fi

        if [[ "$name" == "pdo_dblib" ]]; then
            echo -ne "    ${YELLOW}* ${name}:${NC} Compilando via Código Fonte... "
            log_message INFO "Iniciando compilação de $name para $php_version_dir."
            local EXACT_PHP_VER=$($PHP_BIN -r "echo PHP_VERSION;")
            local src_dir="/tmp/php_compile_custom_src_${EXACT_PHP_VER}"
            rm -rf "$src_dir" && mkdir -p "$src_dir" && cd "$src_dir"

            retry_cmd "curl -sSL -f -o php-${EXACT_PHP_VER}.tar.gz https://www.php.net/distributions/php-${EXACT_PHP_VER}.tar.gz >> '$LOG_FILE' 2>&1" || \
            retry_cmd "curl -sSL -f -o php-${EXACT_PHP_VER}.tar.gz https://museum.php.net/php5/php-${EXACT_PHP_VER}.tar.gz >> '$LOG_FILE' 2>&1"

            tar -zxf "php-${EXACT_PHP_VER}.tar.gz" >> "$LOG_FILE" 2>&1
            cd "php-${EXACT_PHP_VER}/ext/pdo_dblib"

            local phpize_bin="/opt/cpanel/$php_version_dir/root/usr/bin/phpize"
            local phpconfig_bin="/opt/cpanel/$php_version_dir/root/usr/bin/php-config"
            local freetds_prefix="/usr"
            local freetds_libdir=$(pkg-config --variable=libdir freetds 2>/dev/null || echo /usr/lib64)

            PHP_AUTOCONF=autoconf PHP_AUTOHEADER=autoheader $phpize_bin >> "$LOG_FILE" 2>&1
            FREETDS_LIBS="-L${freetds_libdir} -lsybdb" \
            ./configure --with-php-config="$phpconfig_bin" --with-pdo-dblib="$freetds_prefix" >> "$LOG_FILE" 2>&1
            make >> "$LOG_FILE" 2>&1 && make install >> "$LOG_FILE" 2>&1

            echo "extension=pdo_dblib.so" > "$PHP_INI_DIR/zzzzzzz-pecl-pdo_dblib.ini"

            if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
                echo -e "${GREEN}[OK]${NC}"
                log_message INFO "$name compilado com sucesso."
            else
                echo -e "${RED}[FALHA]${NC}"
                log_message ERROR "Falha na compilação do $name."
                tail_log
            fi
            cd / && rm -rf "$src_dir"
            return
        fi

        echo -ne "    ${YELLOW}* ${name}:${NC} Executando PECL Install ($pkg)... "
        set +o pipefail
        if [[ "$name" == "oci8" ]]; then
            retry_cmd "echo 'instantclient,$ORACLE_HOME/lib' | $PECL_BIN install -f '$pkg' >> '$LOG_FILE' 2>&1"
        else
            retry_cmd "yes '' | $PECL_BIN install -f '$pkg' >> '$LOG_FILE' 2>&1"
        fi
        set -o pipefail

        if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
            echo -e "${GREEN}[OK]${NC}"
        else
            local ext_dir=$($PHP_BIN -r "echo ini_get('extension_dir');")
            if [[ -f "$ext_dir/$name.so" ]]; then
                echo "extension=$name.so" > "$PHP_INI_DIR/zzzzzzz-pecl-${name}.ini"
                if $PHP_BIN -m 2>/dev/null | grep -qix "$name"; then
                    echo -e "${GREEN}[OK] (Ativação Forçada)${NC}"
                else
                    echo -e "${RED}[FALHA]${NC} (Não carregado)"
                    tail_log
                fi
            else
                echo -e "${RED}[FALHA]${NC} (.so não gerado)"
                tail_log
            fi
        fi
    }

    install_ext "imagick" "$IMV"
    install_ext "redis" "$REDV"
    if [[ -n "$SQL" ]]; then
        install_ext "sqlsrv" "$SQL"
        install_ext "pdo_sqlsrv" "$PDOSQL"
    elif [[ -n "$DBLIB" ]]; then
        install_ext "pdo_dblib" "$DBLIB"
    fi
    [[ -n "$OCI" ]] && install_ext "oci8" "$OCI"
done

# 4. Serviços
echo -e "\n${YELLOW}[4/6] Reiniciando Daemons e Serviços Web...${NC}"
retry_cmd "/scripts/restartsrv_apache_php_fpm >> '$LOG_FILE' 2>&1"
echo -e " ${GREEN}[OK]${NC}"

echo -ne "\n${YELLOW}[5/6] Sincronizando File Systems Virtuais (CageFS)...${NC}"
if command -v cagefsctl &>/dev/null; then
    retry_cmd "cagefsctl --force-update >> '$LOG_FILE' 2>&1"
    echo -e " ${GREEN}[OK]${NC}"
else
    echo -e " ${GREEN}${NC}"
fi

# 5. Checklist Final
echo -e "\n${YELLOW}[6/6] VERIFICAÇÃO FINAL E AUDITORIA${NC}"
echo -e "\n${BOLD}--- DEPENDÊNCIAS DO SISTEMA OS ---${NC}"
[[ -n "$ORACLE_HOME" ]] && echo -e "  Oracle Instant Client Ativo" || echo -e "  Oracle Client Ausente"
rpm -q msodbcsql18 &>/dev/null && echo -e "  Microsoft ODBC Driver 18 (PHP 8+)" || echo -e "  MS ODBC Driver 18 (ausente)"
rpm -q msodbcsql17 &>/dev/null && echo -e "  Microsoft ODBC Driver 17 (PHP 7.x)" || echo -e "  MS ODBC Driver 17 (ausente)"

echo -e "\n${BOLD}--- INTEGRIDADE DAS EXTENSÕES PHP ---${NC}"
for php_version_dir in $(whmapi1 php_get_installed_versions | grep -oE 'ea-php[0-9]+'); do
    PHP_BIN="/opt/cpanel/$php_version_dir/root/usr/bin/php"
    echo -e "\n${BLUE}● $php_version_dir${NC}"
    check_ext() {
        if $PHP_BIN -m 2>/dev/null | grep -qix "$1"; then
            echo -ne "    ${GREEN}$1  ${NC}"
        else
            echo -ne "    ${RED}$1  ${NC}"
        fi
    }
    check_ext "imagick"
    check_ext "redis"
    if [[ "$php_version_dir" == ea-php5* ]]; then
        check_ext "pdo_dblib"
    else
        check_ext "sqlsrv"
        check_ext "pdo_sqlsrv"
    fi
    check_ext "oci8"
    echo ""
done

echo -e "\n${BLUE}=================================================================${NC}"
echo -e "Implantação Finalizada. Log: ${WHITE}$LOG_FILE${NC}"
echo -e "${BLUE}=================================================================${NC}\n"
