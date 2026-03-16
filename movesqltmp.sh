#!/bin/bash

# Cores para o terminal
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly WHITE='\033[1;37m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # Sem cor

# Constantes
readonly OVERRIDE_DIR="/etc/systemd/system/mariadb.service.d"
readonly OVERRIDE_CONF="$OVERRIDE_DIR/override.conf"
readonly TMP_DIR="/home/mysqltmp"
readonly MY_CNF="/etc/my.cnf"

clear
echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}   OTIMIZAÇÃO DE DIRETÓRIO TEMPORÁRIO MARIADB        ${NC}"
echo -e "${BLUE}=====================================================${NC}"

# Função para reiniciar MariaDB (prioriza cPanel, fallback systemd)
restart_mariadb() {
    if command -v /scripts/restartsrv_mysql >/dev/null 2>&1; then
        echo "Reiniciando via cPanel: /scripts/restartsrv_mysql"
        /scripts/restartsrv_mysql
    elif systemctl is-active --quiet mariadb >/dev/null 2>&1; then
        echo "Reiniciando via systemd: systemctl restart mariadb"
        systemctl restart mariadb
    else
        echo "Reiniciando via service: service mariadb restart"
        service mariadb restart
    fi
}

# 1. Configurar override do systemd
echo -e "\n${YELLOW}[1/4] Verificando Systemd Override...${NC}"
mkdir -p "$OVERRIDE_DIR"
if [ ! -f "$OVERRIDE_CONF" ] || ! grep -q "ProtectHome=false" "$OVERRIDE_CONF"; then
    echo -e "    ${GREEN}+ Aplicando ProtectHome=false...${NC}"
    cat <<EOF > "$OVERRIDE_CONF"
[Service]
ProtectHome=false
EOF
    systemctl daemon-reload
    RESTART_NEEDED=true
else
    echo -e "    ${BLUE}✓ Configuração já existente.${NC}"
fi

# 2. Criar/ajustar diretório no /home
echo -e "\n${YELLOW}[2/4] Verificando diretório $TMP_DIR...${NC}"
if [ ! -d "$TMP_DIR" ]; then
    echo -e "    ${GREEN}+ Criando $TMP_DIR...${NC}"
    mkdir -p "$TMP_DIR"
else
    echo -e "    ${BLUE}i Diretório já existe.${NC}"
fi
chown mysql:mysql "$TMP_DIR"
chmod 1777 "$TMP_DIR"

# 3. Ajustar o /etc/my.cnf
echo -e "\n${YELLOW}[3/4] Analisando $MY_CNF...${NC}"
if ! command -v mariadb >/dev/null 2>&1; then
    echo -e "${RED}   Aviso: mariadb não encontrado. Usando sed direto.${NC}"
    if grep -q "^tmpdir=$TMP_DIR" "$MY_CNF" 2>/dev/null; then
        echo -e "    ${BLUE}✓ tmpdir já configurado.${NC}"
    elif grep -q "^tmpdir=" "$MY_CNF" 2>/dev/null; then
        echo -e "    ${GREEN}* Atualizando tmpdir...${NC}"
        sed -i "s|^tmpdir=.*|tmpdir=$TMP_DIR|" "$MY_CNF"
        RESTART_NEEDED=true
    else
        echo -e "    ${GREEN}+ Adicionando tmpdir no [mysqld]...${NC}"
        if grep -q "\[mysqld\]" "$MY_CNF"; then
            sed -i "/^\[mysqld\]/a tmpdir=$TMP_DIR" "$MY_CNF"
        else
            echo "[mysqld]" >> "$MY_CNF"
            echo "tmpdir=$TMP_DIR" >> "$MY_CNF"
        fi
        RESTART_NEEDED=true
    fi
else
    # Verifica configuração atual via mariadb
    CURRENT_TMPDIR=$(mariadb --execute="SELECT @@tmpdir;" --skip-column-names 2>/dev/null | tr -d '\r\n')
    if [ "$CURRENT_TMPDIR" = "$TMP_DIR" ]; then
        echo -e "    ${BLUE}✓ tmpdir já configurado corretamente (verificado via mariadb).${NC}"
    else
        echo -e "    ${GREEN}* Configurando tmpdir=$TMP_DIR no my.cnf...${NC}"
        if grep -q "^tmpdir=" "$MY_CNF" 2>/dev/null; then
            sed -i "s|^tmpdir=.*|tmpdir=$TMP_DIR|" "$MY_CNF"
        else
            if grep -q "\[mysqld\]" "$MY_CNF"; then
                sed -i "/^\[mysqld\]/a tmpdir=$TMP_DIR" "$MY_CNF"
            else
                echo "[mysqld]" >> "$MY_CNF"
                echo "tmpdir=$TMP_DIR" >> "$MY_CNF"
            fi
        fi
        RESTART_NEEDED=true
    fi
fi

# 4. Reiniciar serviço se necessário
echo -e "\n${YELLOW}[4/4] Status do Serviço...${NC}"
if [ "${RESTART_NEEDED:-false}" = true ]; then
    echo -e "    ${GREEN}* Reiniciando MariaDB...${NC}"
    restart_mariadb || echo -e "${RED}   Erro no reinício. Verifique manualmente.${NC}"
else
    echo -e "    ${BLUE}✓ Nenhuma reinicialização necessária.${NC}"
fi

# 5. Verificação final
echo -e "\n${BLUE}=====================================================${NC}"
echo -e "${GREEN}   VERIFICAÇÃO FINAL:${NC}"

if command -v mariadb >/dev/null 2>&1; then
    CURRENT_TMPDIR=$(mariadb --execute="SELECT @@tmpdir;" --skip-column-names 2>/dev/null | tr -d '\r\n')
    if [ -n "$CURRENT_TMPDIR" ]; then
        echo -e "${WHITE}tmpdir: $CURRENT_TMPDIR${NC}"
        if [ "$CURRENT_TMPDIR" = "$TMP_DIR" ]; then
            echo -e "${GREEN}✓ Configuração aplicada com sucesso!${NC}"
        else
            echo -e "${YELLOW}⚠ tmpdir ainda não aplicado (reinício pendente?).${NC}"
        fi
    else
        echo -e "${RED}   Erro: Não foi possível conectar ao MariaDB.${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Cliente mariadb não encontrado. Verifique /etc/my.cnf.${NC}"
fi

# Verificação de serviço rodando
if systemctl is-active --quiet mariadb >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Serviço mariadb ativo.${NC}"
elif systemctl is-active --quiet mysql >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Serviço mysql ativo.${NC}"
else
    echo -e "${RED}✗ Serviço não está rodando.${NC}"
fi

echo -e "${BLUE}=====================================================${NC}\n"
