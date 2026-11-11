#!/usr/bin/env bash
set -Eeuo pipefail

API_URL="https://painelinove.com.br/api/monitoramento.php"
AGENT="/usr/local/bin/i9net-agent.sh"
CONFIG="/etc/i9net-monitoramento.curl"
LOG="/var/log/i9net-agent.log"
CRON_LINE="* * * * * /usr/local/bin/i9net-agent.sh >> /var/log/i9net-agent.log 2>&1"

erro() {
    echo
    echo "[ERRO] $1"
    exit 1
}

[[ $EUID -eq 0 ]] || erro "Execute como root."
[[ -r /dev/tty && -w /dev/tty ]] || erro "Execute em terminal interativo."

TMP_CONFIG=""
TMP_RESPONSE=""
TMP_AGENT=""
BACKUP_DIR="/root/i9net-backups"
DATA=$(date +%Y%m%d-%H%M%S)
AGENT_EXISTIA=0
CONFIG_EXISTIA=0
LOG_CRIADO=0
INSTALACAO_INICIADA=0
CONCLUIDO=0
CRON_ALTERADO=0
CRON_ANTERIOR=""
CRON_EXISTIA=0
SERVICE_STATE_CAPTURED=0
CRON_ESTAVA_ATIVO=0
CRON_ESTAVA_HABILITADO=0

limpar() {
    [[ -n "$TMP_CONFIG" ]] && rm -f "$TMP_CONFIG"
    [[ -n "$TMP_RESPONSE" ]] && rm -f "$TMP_RESPONSE"
    [[ -n "$TMP_AGENT" ]] && rm -f "$TMP_AGENT"
    [[ -n "$CRON_ANTERIOR" ]] && rm -f "$CRON_ANTERIOR"
}

rollback() {
    local codigo=$?
    local falhas=0

    trap - EXIT
    set +e

    if [[ "$INSTALACAO_INICIADA" -eq 1 && "$CONCLUIDO" -eq 0 ]]; then
        echo
        echo "[RECUPERAÇÃO] Restaurando estado anterior..."

        if [[ "$CRON_ALTERADO" -eq 1 ]]; then
            if [[ "$CRON_EXISTIA" -eq 1 ]]; then
                crontab "$CRON_ANTERIOR"
                resultado_cron=$?
            else
                crontab -r 2>/dev/null
                resultado_cron=$?
            fi

            if [[ "$resultado_cron" -ne 0 ]]; then
                echo "[AVISO] Não foi possível restaurar o crontab."
                falhas=1
            else
                echo "[RECUPERAÇÃO] Crontab restaurado."
            fi
        fi

        if [[ "$SERVICE_STATE_CAPTURED" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
            if [[ "$CRON_ESTAVA_ATIVO" -eq 1 ]]; then
                systemctl start "$CRON_SERVICE" >/dev/null 2>&1
            else
                systemctl stop "$CRON_SERVICE" >/dev/null 2>&1
            fi
            if [[ "$?" -ne 0 ]]; then
                echo "[AVISO] Falha ao restaurar estado ativo do serviço cron."
                falhas=1
            fi

            if [[ "$CRON_ESTAVA_HABILITADO" -eq 1 ]]; then
                systemctl enable "$CRON_SERVICE" >/dev/null 2>&1
            else
                systemctl disable "$CRON_SERVICE" >/dev/null 2>&1
            fi
            if [[ "$?" -ne 0 ]]; then
                echo "[AVISO] Falha ao restaurar estado habilitado do serviço cron."
                falhas=1
            fi
        fi

        if [[ "$AGENT_EXISTIA" -eq 1 ]]; then
            cp -a "$BACKUP_DIR/i9net-agent-$DATA.backup" "$AGENT"
        else
            rm -f "$AGENT"
        fi
        if [[ "$?" -ne 0 ]]; then
            echo "[AVISO] Falha ao restaurar/remover o agente."
            falhas=1
        fi

        if [[ "$CONFIG_EXISTIA" -eq 1 ]]; then
            cp -a "$BACKUP_DIR/i9net-config-$DATA.backup" "$CONFIG"
        else
            rm -f "$CONFIG"
        fi
        if [[ "$?" -ne 0 ]]; then
            echo "[AVISO] Falha ao restaurar/remover a configuração."
            falhas=1
        fi

        if [[ "$LOG_CRIADO" -eq 1 ]]; then
            rm -f "$LOG"
            if [[ "$?" -ne 0 ]]; then
                echo "[AVISO] Não foi possível remover o log criado nesta instalação."
                falhas=1
            fi
        fi

        if [[ "$falhas" -eq 0 ]]; then
            echo "[RECUPERAÇÃO] Estado anterior restaurado."
        else
            echo "[ATENÇÃO] A recuperação terminou com falhas. Confira os avisos acima."
        fi
    fi

    limpar
    exit "$codigo"
}
trap rollback EXIT

echo "========================================"
echo "       INSTALADOR i9 NET"
echo "========================================"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "Sistema: ${PRETTY_NAME:-Linux}"
else
    erro "Não foi possível identificar o Linux."
fi

# Compatibilidade explicitamente validada nesta versão
case "${ID:-}" in
    ubuntu|debian)
        GERENCIADOR_PACOTES="apt"
        PACOTE_CRON="cron"
        CRON_SERVICE="cron"
        ;;
    *)
        erro "Sistema não suportado nesta versão: ${ID:-desconhecido}. Compatibilidade disponível: Ubuntu e Debian."
        ;;
esac

command -v apt-get >/dev/null 2>&1 ||
    erro "apt-get não encontrado. Nenhuma instalação foi iniciada."

validar_ipv4() {
    local ip="$1" a b c d extra octeto
    IFS=. read -r a b c d extra <<< "$ip"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -z "${extra:-}" ]] || return 1
    for octeto in "$a" "$b" "$c" "$d"; do
        [[ "$octeto" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octeto <= 255 )) || return 1
    done
}

# Ferramentas exigidas antes da autorização; não instala pacotes
for comando in curl top free df awk uptime tr grep mktemp chmod install; do
    command -v "$comando" >/dev/null 2>&1 || erro "Ferramenta ausente: $comando. Nenhum pacote foi instalado."
done

# Detecta IP público
echo
echo "[1/5] Detectando IPv4 público..."

IP=""
for URL in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://checkip.amazonaws.com"
do
    CANDIDATO=$(curl -4fsS --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null | tr -d '[:space:]' || true)
    if validar_ipv4 "$CANDIDATO"; then
        IP="$CANDIDATO"
        break
    fi
done

[[ -n "$IP" ]] || erro "Não foi possível detectar IPv4 público."
echo "IP detectado: $IP"

# Token
echo
echo "[2/5] Informe o token gerado no i9 NET BOT."
TOKEN=""
IFS= read -r -s -p "Token: " TOKEN </dev/tty
printf '\n'

[[ "$TOKEN" =~ ^[a-fA-F0-9]{64}$ ]] || erro "Token inválido. Deve conter 64 caracteres hexadecimais."

TMP_CONFIG=$(mktemp)
TMP_RESPONSE=$(mktemp)
TMP_AGENT=$(mktemp)
chmod 600 "$TMP_CONFIG" "$TMP_RESPONSE" "$TMP_AGENT"

{
    printf 'url = "%s"\n' "$API_URL"
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
    printf 'header = "Content-Type: application/json"\n'
    printf 'silent\nshow-error\n'
} > "$TMP_CONFIG"
unset TOKEN

coletar_metricas() {
    CPU=$(LC_ALL=C top -bn1 | awk -F'[, ]+' '/Cpu\(s\)/ {
        for (i=1; i<=NF; i++) {
            if ($i == "id") {
                print 100-$(i-1)
                exit
            }
        }
    }')
    CPU=${CPU:-0}
    RAM=$(free | awk '/Mem:/ { if ($2>0) printf "%.0f", ($3/$2)*100; else print 0 }')
    DISCO=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')
    LOAD=$(awk '{print $1}' /proc/loadavg)
    UPTIME=$(uptime -p)
    PAYLOAD=$(printf '{"server_id":"%s","cpu":"%s","ram":"%s","disco":"%s","load":"%s","uptime":"%s"}' \
        "$IP" "$CPU" "$RAM" "$DISCO" "$LOAD" "$UPTIME")
}

coletar_metricas

echo
echo "[3/5] Validando token e IP na API..."

HTTP_CODE=$(curl --config "$TMP_CONFIG" \
    --connect-timeout 10 --max-time 30 \
    --data-binary "$PAYLOAD" \
    -o "$TMP_RESPONSE" -w '%{http_code}' 2>/dev/null || true)

if [[ "$HTTP_CODE" != "200" ]] ||
   ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$TMP_RESPONSE" ||
   ! grep -Fq "\"server_id\":\"$IP\"" "$TMP_RESPONSE"; then
    echo "HTTP: ${HTTP_CODE:-sem resposta}"
    erro "API não autorizou este token e IP. Confira o cadastro no BOT."
fi

echo "Autorização confirmada para $IP."

# Instala cron somente após a autorização da API
if ! command -v crontab >/dev/null 2>&1; then
    echo "Instalando $PACOTE_CRON após autorização..."
    case "$GERENCIADOR_PACOTES" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y "$PACOTE_CRON"
            ;;
        dnf) dnf install -y "$PACOTE_CRON" ;;
        yum) yum install -y "$PACOTE_CRON" ;;
    esac
fi
command -v crontab >/dev/null 2>&1 || erro "Não foi possível disponibilizar o comando crontab."

# Backups e preparação
echo
echo "[4/5] Preparando agente..."

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ -e "$AGENT" ]]; then
    AGENT_EXISTIA=1
    cp -a "$AGENT" "$BACKUP_DIR/i9net-agent-$DATA.backup"
fi

if [[ -e "$CONFIG" ]]; then
    CONFIG_EXISTIA=1
    cp -a "$CONFIG" "$BACKUP_DIR/i9net-config-$DATA.backup"
fi

INSTALACAO_INICIADA=1

cat > "$TMP_AGENT" <<AGENTE
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="$CONFIG"
IP="$IP"

[[ -r "\$CONFIG" ]] || exit 1

validar_ipv4() {
    local ip="\$1" a b c d extra octeto
    IFS=. read -r a b c d extra <<< "\$ip"
    [[ -n "\$a" && -n "\$b" && -n "\$c" && -n "\$d" && -z "\${extra:-}" ]] || return 1
    for octeto in "\$a" "\$b" "\$c" "\$d"; do
        [[ "\$octeto" =~ ^[0-9]{1,3}\$ ]] || return 1
        (( 10#\$octeto <= 255 )) || return 1
    done
}

CURRENT_IP=""
for URL in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://checkip.amazonaws.com"
do
    CURRENT_CANDIDATO=\$(curl -4fsS --connect-timeout 5 --max-time 10 "\$URL" 2>/dev/null | tr -d '[:space:]' || true)
    if validar_ipv4 "\$CURRENT_CANDIDATO"; then
        CURRENT_IP="\$CURRENT_CANDIDATO"
        break
    fi
done

if [[ -z "\$CURRENT_IP" ]]; then
    echo "[AVISO] Não foi possível confirmar o IPv4 público. Métricas não enviadas." >&2
    exit 1
fi

if [[ "\$CURRENT_IP" != "\$IP" ]]; then
    echo "[AVISO] IPv4 público mudou: autorizado=\$IP atual=\$CURRENT_IP. Métricas não enviadas; atualize o cadastro no BOT." >&2
    exit 1
fi

CPU=\$(LC_ALL=C top -bn1 | awk -F'[, ]+' '/Cpu\\(s\\)/ {
    for (i=1; i<=NF; i++) {
        if (\$i == "id") {
            print 100-\$(i-1)
            exit
        }
    }
}')
CPU=\${CPU:-0}

RAM=\$(free | awk '/Mem:/ { if (\$2>0) printf "%.0f", (\$3/\$2)*100; else print 0 }')
DISCO=\$(df -P / | awk 'NR==2 { gsub("%","",\$5); print \$5 }')
LOAD=\$(awk '{print \$1}' /proc/loadavg)
UPTIME=\$(uptime -p)

PAYLOAD=\$(printf '{"server_id":"%s","cpu":"%s","ram":"%s","disco":"%s","load":"%s","uptime":"%s"}' \\
    "\$IP" "\$CPU" "\$RAM" "\$DISCO" "\$LOAD" "\$UPTIME")

RESPOSTA=\$(curl -fsS --config "\$CONFIG" --connect-timeout 10 --max-time 30 --data-binary "\$PAYLOAD") || {
    echo "ERRO: falha ao enviar métricas para a API."
    exit 1
}

if ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "\$RESPOSTA" ||
   ! grep -Fq "\"server_id\":\"\$IP\"" <<< "\$RESPOSTA"; then
    echo "ERRO: resposta da API inválida: \$RESPOSTA"
    exit 1
fi
AGENTE

install -o root -g root -m 600 "$TMP_CONFIG" "$CONFIG"
install -o root -g root -m 700 "$TMP_AGENT" "$AGENT"

echo "Testando agente antes de configurar cron..."

if ! "$AGENT" > "$TMP_RESPONSE" 2>&1; then
    cat "$TMP_RESPONSE"
    erro "Teste do agente falhou. Cron não será configurado."
fi

echo "Teste da API aprovado."

# Captura o estado original do serviço antes de alterar o cron
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$CRON_SERVICE"; then
        CRON_ESTAVA_ATIVO=1
    else
        CRON_ESTAVA_ATIVO=0
    fi

    if systemctl is-enabled --quiet "$CRON_SERVICE"; then
        CRON_ESTAVA_HABILITADO=1
    else
        CRON_ESTAVA_HABILITADO=0
    fi

    SERVICE_STATE_CAPTURED=1
fi

# Cron somente depois do teste
CRON_ANTERIOR=$(mktemp)
if LC_ALL=C crontab -l > "$CRON_ANTERIOR" 2> "$TMP_RESPONSE"; then
    CRON_EXISTIA=1
elif grep -qi 'no crontab for' "$TMP_RESPONSE"; then
    CRON_EXISTIA=0
else
    cat "$TMP_RESPONSE" >&2
    erro "Não foi possível consultar o crontab. Nenhuma alteração foi feita."
fi
chmod 600 "$CRON_ANTERIOR"

CURRENT_CRON=$(cat "$CRON_ANTERIOR")
NEW_CRON=$(printf '%s\n' "$CURRENT_CRON" | grep -Fv "$AGENT" || true)

CRON_ALTERADO=1
printf '%s\n%s\n' "$NEW_CRON" "$CRON_LINE" | sed '/^[[:space:]]*$/d' | crontab -

if command -v systemctl >/dev/null 2>&1; then
    if [[ "$CRON_ESTAVA_ATIVO" -eq 0 ]]; then
        systemctl start "$CRON_SERVICE"
    fi

    if [[ "$CRON_ESTAVA_HABILITADO" -eq 0 ]]; then
        systemctl enable "$CRON_SERVICE" >/dev/null
    fi
fi

if [[ ! -e "$LOG" ]]; then
    install -o root -g root -m 600 /dev/null "$LOG"
    LOG_CRIADO=1
fi

CONCLUIDO=1
echo
echo "========================================"
echo "       INSTALAÇÃO CONCLUÍDA!"
echo "========================================"
echo "IP autorizado: $IP"
echo "Agente: $AGENT"
echo "Execução: a cada minuto"
echo "Log: $LOG"
echo "Token: armazenado com permissão 600"
