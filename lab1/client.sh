#!/usr/bin/env bash
# ==============================================================================
# Морской Бой (Battleship) - Тонкий Клиент
# ==============================================================================

HOST="127.0.0.1"
PORT=8888

# Разбор параметров командной строки
if [ "$1" == "1" ]; then
    PORT=8888
elif [ "$1" == "2" ]; then
    PORT=8889
elif [ "$1" == "8888" ] || [ "$1" == "8889" ]; then
    PORT="$1"
elif [ -n "$1" ] && [ -n "$2" ]; then
    HOST="$1"
    PORT="$2"
elif [ -n "$1" ]; then
    HOST="$1"
fi

# Если порт не был передан явно, спрашиваем слот игрока
if [ -z "$1" ]; then
    echo -e "\033[1;36m=== МОРСКОЙ БОЙ: ВХОД В ИГРУ ===\033[0m"
    echo "Выберите слот подключения:"
    echo "  [1] Игрок 1 / Одиночная игра с Ботом (порт 8888)"
    echo "  [2] Игрок 2 (порт 8889)"
    read -rp "Ваш выбор [1/2, Enter=1]: " choice
    if [ "$choice" == "2" ]; then
        PORT=8889
    else
        PORT=8888
    fi
fi

C_RESET=$'\033[0m'
C_CYAN=$'\033[1;36m'
C_RED=$'\033[1;31m'

echo -e "${C_CYAN}Подключение к серверу Морского Боя ($HOST:$PORT)...${C_RESET}"

# Прямой вызов nc без промежуточных пайпов (| cat) устраняет 4KB буферизацию
# и обеспечивает мгновенную передачу пакетов (<1 мс)
if command -v nc >/dev/null 2>&1; then
    exec nc "$HOST" "$PORT"
else
    # Резервный режим через встроенный сокет bash /dev/tcp
    if exec 3<>/dev/tcp/"$HOST"/"$PORT" 2>/dev/null; then
        cat <&3 &
        PID_BG=$!
        trap 'kill "$PID_BG" 2>/dev/null; exec 3>&-; exit 0' INT TERM EXIT
        while IFS= read -r line; do
            echo "$line" >&3
        done
    else
        echo -e "${C_RED}Ошибка: не удалось подключиться к $HOST:$PORT!${C_RESET}"
        echo -e "Убедитесь, что сервер запущен (./server.sh)."
        exit 1
    fi
fi
