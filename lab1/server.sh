#!/usr/bin/env bash
# ==============================================================================
# Морской Бой (Battleship) - Сервер
# Вся логика, доски и состояние хранятся ТОЛЬКО на сервере.
# Поддерживает выбор: автоматическая или ручная расстановка кораблей.
# ==============================================================================

PORT_P1=8888
PORT_P2=8889

# Цвета ANSI
C_RESET=$'\033[0m'
C_CYAN=$'\033[1;36m'
C_GREEN=$'\033[1;32m'
C_RED=$'\033[1;31m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_GRAY=$'\033[1;30m'
C_BOLD=$'\033[1m'
C_CLEAR=$'\033[2J\033[H'

# Инициализация структур данных
# 100 ячеек (0..99). r: 0..9, c: 0..9 -> idx = r * 10 + c
declare -a P1_GRID P2_GRID           # 0 = пусто, 1 = корабль
declare -a P1_SHOTS P2_SHOTS         # 0 = не стреляли, 1 = промах (•), 2 = попадание (X)
declare -a P1_CELL_SHIP P2_CELL_SHIP # Индекс корабля (1..10)
declare -a P1_SHIP_LEN P2_SHIP_LEN   # Начальная длина
declare -a P1_SHIP_HITS P2_SHIP_HITS # Количество попаданий
declare -a P1_SHIP_CELLS P2_SHIP_CELLS # Индексы ячеек корабля

P1_SHIPS_REMAINING=10
P2_SHIPS_REMAINING=10

declare -a BOT_HUNT_LIST
declare -a BOT_TARGET_QUEUE

ROW_CHARS=("A" "B" "C" "D" "E" "F" "G" "H" "I" "J")

cleanup() {
    echo -e "\n${C_YELLOW}Завершение работы сервера и закрытие сокетов...${C_RESET}"
    if [ -n "$NC1_PID" ]; then kill "$NC1_PID" 2>/dev/null || true; fi
    if [ -n "$NC2_PID" ]; then kill "$NC2_PID" 2>/dev/null || true; fi
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ------------------------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------------------------
idx_to_coord() {
    local index=$1
    local r=$((index / 10))
    local c=$((index % 10 + 1))
    echo "${ROW_CHARS[$r]}$c"
}

can_place() {
    local player=$1
    local r=$2
    local c=$3
    local len=$4
    local dir=$5 # 0 = горизонт, 1 = вертик

    if [ "$dir" -eq 0 ]; then
        if [ $((c + len)) -gt 10 ]; then return 1; fi
    else
        if [ $((r + len)) -gt 10 ]; then return 1; fi
    fi

    # Проверка расстояния в 1 клетку во все стороны (включая диагонали)
    for ((i=0; i<len; i++)); do
        local cr=$r
        local cc=$c
        if [ "$dir" -eq 0 ]; then
            cc=$((c + i))
        else
            cr=$((r + i))
        fi

        for ((dr=-1; dr<=1; dr++)); do
            for ((dc=-1; dc<=1; dc++)); do
                local nr=$((cr + dr))
                local nc=$((cc + dc))
                if [ "$nr" -ge 0 ] && [ "$nr" -lt 10 ] && [ "$nc" -ge 0 ] && [ "$nc" -lt 10 ]; then
                    local n_idx=$((nr * 10 + nc))
                    if [ "$player" -eq 1 ]; then
                        if [ "${P1_GRID[$n_idx]}" -eq 1 ]; then return 1; fi
                    else
                        if [ "${P2_GRID[$n_idx]}" -eq 1 ]; then return 1; fi
                    fi
                fi
            done
        done
    done

    return 0
}

place_ship() {
    local player=$1
    local ship_id=$2
    local r=$3
    local c=$4
    local len=$5
    local dir=$6

    local cells=""
    for ((i=0; i<len; i++)); do
        local cr=$r
        local cc=$c
        if [ "$dir" -eq 0 ]; then
            cc=$((c + i))
        else
            cr=$((r + i))
        fi
        local cell_idx=$((cr * 10 + cc))
        cells="$cells $cell_idx"

        if [ "$player" -eq 1 ]; then
            P1_GRID[$cell_idx]=1
            P1_CELL_SHIP[$cell_idx]=$ship_id
        else
            P2_GRID[$cell_idx]=1
            P2_CELL_SHIP[$cell_idx]=$ship_id
        fi
    done

    if [ "$player" -eq 1 ]; then
        P1_SHIP_LEN[$ship_id]=$len
        P1_SHIP_HITS[$ship_id]=0
        P1_SHIP_CELLS[$ship_id]="${cells# }"
    else
        P2_SHIP_LEN[$ship_id]=$len
        P2_SHIP_HITS[$ship_id]=0
        P2_SHIP_CELLS[$ship_id]="${cells# }"
    fi
}

auto_place_fleet() {
    local player=$1
    local ship_lens=(4 3 3 2 2 2 1 1 1 1)
    local ship_id=1

    for len in "${ship_lens[@]}"; do
        local placed=0
        while [ "$placed" -eq 0 ]; do
            local r=$((RANDOM % 10))
            local c=$((RANDOM % 10))
            local dir=$((RANDOM % 2))
            if can_place "$player" "$r" "$c" "$len" "$dir"; then
                place_ship "$player" "$ship_id" "$r" "$c" "$len" "$dir"
                placed=1
                ship_id=$((ship_id + 1))
            fi
        done
    done
}

init_boards() {
    for ((i=0; i<100; i++)); do
        P1_GRID[$i]=0
        P2_GRID[$i]=0
        P1_SHOTS[$i]=0
        P2_SHOTS[$i]=0
        P1_CELL_SHIP[$i]=0
        P2_CELL_SHIP[$i]=0
    done
}

# ------------------------------------------------------------------------------
# Парсинг координат (поддержка английской A-J и русской А-К раскладки)
# ------------------------------------------------------------------------------
parse_coord() {
    local input="$1"
    input=$(echo "$input" | tr -d ' \r\n' | tr '[:lower:]' '[:upper:]')
    input=$(echo "$input" | sed 's/А/A/g; s/Б/B/g; s/В/C/g; s/Г/D/g; s/Д/E/g; s/Е/F/g; s/Ж/G/g; s/З/H/g; s/И/I/g; s/К/J/g')

    local r=""
    local c=""

    if [[ "$input" =~ ^([A-J])([1-9]|10)$ ]]; then
        r="${BASH_REMATCH[1]}"
        c="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^([1-9]|10)([A-J])$ ]]; then
        c="${BASH_REMATCH[1]}"
        r="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    local row_idx=-1
    for ((i=0; i<10; i++)); do
        if [ "${ROW_CHARS[$i]}" == "$r" ]; then
            row_idx=$i
            break
        fi
    done

    local col_idx=$((c - 1))
    echo $((row_idx * 10 + col_idx))
    return 0
}

# ------------------------------------------------------------------------------
# Отрисовка экрана при ручной расстановке
# ------------------------------------------------------------------------------
render_placement_screen() {
    local player=$1
    local current_ship_name="$2"
    local current_ship_len="$3"
    local status_msg="$4"

    local out="${C_CLEAR}"
    out+="${C_CYAN}========================================================================${C_RESET}\n"
    out+="${C_BOLD}             *** РАССТАНОВКА КОРАБЛЕЙ (ИГРОК $player) ***                     ${C_RESET}\n"
    out+="${C_CYAN}========================================================================${C_RESET}\n\n"
    out+="     ${C_GREEN}[ ВАШ ФЛОТ ]${C_RESET}\n"
    out+="   1  2  3  4  5  6  7  8  9  10\n"

    for ((r=0; r<10; r++)); do
        local row_char="${ROW_CHARS[$r]}"
        local line="$row_char "
        for ((c=0; c<10; c++)); do
            local cell_idx=$((r * 10 + c))
            local has_ship=0
            if [ "$player" -eq 1 ]; then
                has_ship=${P1_GRID[$cell_idx]}
            else
                has_ship=${P2_GRID[$cell_idx]}
            fi

            if [ "$has_ship" -eq 1 ]; then
                line+="${C_GREEN} ■ ${C_RESET}"
            else
                line+="${C_BLUE} ~ ${C_RESET}"
            fi
        done
        out+="$line\n"
    done

    out+="\n"
    if [ -n "$current_ship_name" ]; then
        out+="${C_BOLD}Корабль:${C_RESET} ${C_YELLOW}$current_ship_name ($current_ship_len палуб)${C_RESET}\n"
        out+="${C_GRAY}Правило: корабли не должны касаться друг друга даже углами.${C_RESET}\n"
        if [ "$current_ship_len" -gt 1 ]; then
            out+="${C_GRAY}Ориентация: H (вправо) или V (вниз). Пример: B3 H или B3 V${C_RESET}\n"
        else
            out+="${C_GRAY}Для 1-палубного достаточно ввести только клетку. Пример: C5${C_RESET}\n"
        fi
    fi
    out+="${C_CYAN}------------------------------------------------------------------------${C_RESET}\n"
    if [ -n "$status_msg" ]; then
        out+="$status_msg\n"
        out+="${C_CYAN}------------------------------------------------------------------------${C_RESET}\n"
    fi

    echo -ne "$out"
}

# ------------------------------------------------------------------------------
# Ручная расстановка кораблей игроком
# ------------------------------------------------------------------------------
manual_place_fleet() {
    local player=$1
    local in_fd=$2
    local out_fd=$3

    local ship_names=(
        "4-палубный линкор"
        "3-палубный крейсер #1"
        "3-палубный крейсер #2"
        "2-палубный эсминец #1"
        "2-палубный эсминец #2"
        "2-палубный эсминец #3"
        "1-палубный катер #1"
        "1-палубкупа катер #2"
        "1-палубный катер #3"
        "1-палубный катер #4"
    )
    local ship_lens=(4 3 3 2 2 2 1 1 1 1)
    local ship_id=1
    local status_msg=""

    for ((s_idx=0; s_idx<10; s_idx++)); do
        local name="${ship_names[$s_idx]}"
        local len="${ship_lens[$s_idx]}"
        local placed=0

        while [ "$placed" -eq 0 ]; do
            render_placement_screen "$player" "$name" "$len" "$status_msg" >&"$out_fd"
            echo -ne "${C_YELLOW}>>> Координаты: ${C_RESET}\n" >&"$out_fd"

            local raw_input=""
            read -r raw_input <&"$in_fd" || return 1
            raw_input=$(echo "$raw_input" | tr -d '\r\n')

            # Разделяем на клетку и направление
            local coord_part=""
            local dir_part=""
            read -r coord_part dir_part <<< "$raw_input"

            local cell_idx
            cell_idx=$(parse_coord "$coord_part")
            if [ -z "$cell_idx" ]; then
                status_msg="${C_RED}Неверный формат клетки '$coord_part'! Пример: B3${C_RESET}"
                continue
            fi

            local r=$((cell_idx / 10))
            local c=$((cell_idx % 10))

            # Направление: 0 = H (горизонт), 1 = V (вертикаль)
            local dir=0
            dir_part=$(echo "$dir_part" | tr '[:lower:]' '[:upper:]')
            if [ "$dir_part" == "V" ] || [ "$dir_part" == "В" ]; then
                dir=1
            fi

            if can_place "$player" "$r" "$c" "$len" "$dir"; then
                place_ship "$player" "$ship_id" "$r" "$c" "$len" "$dir"
                placed=1
                ship_id=$((ship_id + 1))
                status_msg="${C_GREEN}✓ $name успешно размещен!${C_RESET}"
            else
                status_msg="${C_RED}Нельзя сюда поставить! Корабль выходит за границы или задевает другой корабль.${C_RESET}"
            fi
        done
    done

    render_placement_screen "$player" "" 0 "${C_GREEN}✓ Все корабли расставлены! Ожидание начала боя...${C_RESET}" >&"$out_fd"
}

# ------------------------------------------------------------------------------
# Меню выбора способа расстановки
# ------------------------------------------------------------------------------
setup_player_fleet() {
    local player=$1
    local in_fd=$2
    local out_fd=$3

    local menu="${C_CLEAR}"
    menu+="${C_CYAN}========================================================================${C_RESET}\n"
    menu+="${C_BOLD}             *** РАССТАНОВКА ФЛОТА (ИГРОК $player) ***                        ${C_RESET}\n"
    menu+="${C_CYAN}========================================================================${C_RESET}\n\n"
    menu+="Выберите способ расстановки кораблей:\n"
    menu+="  [1] Автоматически (случайная расстановка по правилам)\n"
    menu+="  [2] Вручную (расставить каждый корабль самостоятельно)\n\n"
    menu+="${C_YELLOW}Ваш выбор [1/2, Enter=1]: ${C_RESET}\n"

    echo -ne "$menu" >&"$out_fd"

    local choice=""
    read -r choice <&"$in_fd" || return 1
    choice=$(echo "$choice" | tr -d ' \r\n')

    if [ "$choice" == "2" ]; then
        manual_place_fleet "$player" "$in_fd" "$out_fd"
    else
        auto_place_fleet "$player"
        render_placement_screen "$player" "" 0 "${C_GREEN}✓ Флот автоматически расставлен! Ожидание начала боя...${C_RESET}" >&"$out_fd"
    fi
}

# ------------------------------------------------------------------------------
# Отрисовка боевого экрана
# ------------------------------------------------------------------------------
render_screen() {
    local player=$1
    local msg="$2"
    local opponent_name="ПРОТИВНИК"
    if [ "$GAME_MODE" -eq 2 ]; then
        opponent_name="БОТ"
    fi

    local out="${C_CLEAR}"
    out+="${C_CYAN}========================================================================${C_RESET}\n"
    out+="${C_BOLD}                   *** МОРСКОЙ БОЙ (BATTLESHIP) ***                     ${C_RESET}\n"
    out+="${C_CYAN}========================================================================${C_RESET}\n\n"

    out+="     ${C_GREEN}[ ВАШ ФЛОТ ]${C_RESET}                          ${C_RED}[ РАДАР (${opponent_name}) ]${C_RESET}\n"
    out+="   1  2  3  4  5  6  7  8  9  10         1  2  3  4  5  6  7  8  9  10\n"

    for ((r=0; r<10; r++)); do
        local row_char="${ROW_CHARS[$r]}"
        local line="$row_char "

        # Левое поле (Свое)
        for ((c=0; c<10; c++)); do
            local cell_idx=$((r * 10 + c))
            local has_ship=0
            local shot=0

            if [ "$player" -eq 1 ]; then
                has_ship=${P1_GRID[$cell_idx]}
                shot=${P2_SHOTS[$cell_idx]}
            else
                has_ship=${P2_GRID[$cell_idx]}
                shot=${P1_SHOTS[$cell_idx]}
            fi

            if [ "$shot" -eq 2 ]; then
                line+="${C_RED} X ${C_RESET}"  # Подбитый корабль
            elif [ "$shot" -eq 1 ]; then
                line+="${C_YELLOW} • ${C_RESET}"  # Промах
            elif [ "$has_ship" -eq 1 ]; then
                line+="${C_GREEN} ■ ${C_RESET}"  # Живой корабль
            else
                line+="${C_BLUE} ~ ${C_RESET}"  # Вода
            fi
        done

        line+="      $row_char "

        # Правое поле (Радар врага)
        for ((c=0; c<10; c++)); do
            local cell_idx=$((r * 10 + c))
            local shot=0

            if [ "$player" -eq 1 ]; then
                shot=${P1_SHOTS[$cell_idx]}
            else
                shot=${P2_SHOTS[$cell_idx]}
            fi

            if [ "$shot" -eq 2 ]; then
                line+="${C_RED} X ${C_RESET}"
            elif [ "$shot" -eq 1 ]; then
                line+="${C_YELLOW} • ${C_RESET}"
            else
                line+="${C_BLUE} ~ ${C_RESET}"
            fi
        done

        out+="$line\n"
    done

    out+="\n"
    out+="${C_GRAY}Обозначения: ${C_GREEN}■${C_RESET} Корабль   ${C_RED}X${C_RESET} Попадание   ${C_YELLOW}•${C_RESET} Промах   ${C_BLUE}~${C_RESET} Вода\n"
    local p1_ships=$P1_SHIPS_REMAINING
    local p2_ships=$P2_SHIPS_REMAINING
    if [ "$player" -eq 1 ]; then
        out+="Осталось кораблей: Вы [${C_GREEN}$p1_ships${C_RESET}] | ${opponent_name} [${C_RED}$p2_ships${C_RESET}]\n"
    else
        out+="Осталось кораблей: Вы [${C_GREEN}$p2_ships${C_RESET}] | ${opponent_name} [${C_RED}$p1_ships${C_RESET}]\n"
    fi
    out+="${C_CYAN}------------------------------------------------------------------------${C_RESET}\n"
    if [ -n "$msg" ]; then
        out+="${C_BOLD}$msg${C_RESET}\n"
        out+="${C_CYAN}------------------------------------------------------------------------${C_RESET}\n"
    fi

    echo -ne "$out"
}

# ------------------------------------------------------------------------------
# Автоматическая обводка потопленного корабля
# ------------------------------------------------------------------------------
mark_sunken_halo() {
    local shooter=$1
    local ship_id=$2

    local cells=""
    if [ "$shooter" -eq 1 ]; then
        cells="${P2_SHIP_CELLS[$ship_id]}"
    else
        cells="${P1_SHIP_CELLS[$ship_id]}"
    fi

    for c_idx in $cells; do
        local cr=$((c_idx / 10))
        local cc=$((c_idx % 10))

        for ((dr=-1; dr<=1; dr++)); do
            for ((dc=-1; dc<=1; dc++)); do
                local nr=$((cr + dr))
                local nc=$((cc + dc))
                if [ "$nr" -ge 0 ] && [ "$nr" -lt 10 ] && [ "$nc" -ge 0 ] && [ "$nc" -lt 10 ]; then
                    local n_idx=$((nr * 10 + nc))
                    if [ "$shooter" -eq 1 ]; then
                        if [ "${P1_SHOTS[$n_idx]}" -eq 0 ]; then
                            P1_SHOTS[$n_idx]=1
                        fi
                    else
                        if [ "${P2_SHOTS[$n_idx]}" -eq 0 ]; then
                            P2_SHOTS[$n_idx]=1
                        fi
                    fi
                fi
            done
        done
    done
}

process_shot() {
    local shooter=$1
    local cell_idx=$2

    local target_grid_val=0
    local ship_id=0

    if [ "$shooter" -eq 1 ]; then
        target_grid_val=${P2_GRID[$cell_idx]}
        ship_id=${P2_CELL_SHIP[$cell_idx]}
    else
        target_grid_val=${P1_GRID[$cell_idx]}
        ship_id=${P1_CELL_SHIP[$cell_idx]}
    fi

    if [ "$target_grid_val" -eq 1 ]; then
        if [ "$shooter" -eq 1 ]; then
            P1_SHOTS[$cell_idx]=2
            P2_SHIP_HITS[$ship_id]=$((P2_SHIP_HITS[$ship_id] + 1))
            if [ "${P2_SHIP_HITS[$ship_id]}" -ge "${P2_SHIP_LEN[$ship_id]}" ]; then
                P2_SHIPS_REMAINING=$((P2_SHIPS_REMAINING - 1))
                mark_sunken_halo 1 "$ship_id"
                if [ "$P2_SHIPS_REMAINING" -le 0 ]; then
                    return 3
                fi
                return 2
            fi
        else
            P2_SHOTS[$cell_idx]=2
            P1_SHIP_HITS[$ship_id]=$((P1_SHIP_HITS[$ship_id] + 1))
            if [ "${P1_SHIP_HITS[$ship_id]}" -ge "${P1_SHIP_LEN[$ship_id]}" ]; then
                P1_SHIPS_REMAINING=$((P1_SHIPS_REMAINING - 1))
                mark_sunken_halo 2 "$ship_id"
                if [ "$P1_SHIPS_REMAINING" -le 0 ]; then
                    return 3
                fi
                return 2
            fi
        fi
        return 1
    else
        if [ "$shooter" -eq 1 ]; then
            P1_SHOTS[$cell_idx]=1
        else
            P2_SHOTS[$cell_idx]=1
        fi
        return 0
    fi
}

# ------------------------------------------------------------------------------
# Логика Бота (Hunt and Target)
# ------------------------------------------------------------------------------
init_bot() {
    BOT_HUNT_LIST=()
    BOT_TARGET_QUEUE=()

    local temp_list=()
    for ((r=0; r<10; r++)); do
        for ((c=0; c<10; c++)); do
            if [ $(((r + c) % 2)) -eq 0 ]; then
                temp_list+=($((r * 10 + c)))
            fi
        done
    done

    local n=${#temp_list[@]}
    for ((i=n-1; i>0; i--)); do
        local j=$((RANDOM % (i + 1)))
        local tmp=${temp_list[$i]}
        temp_list[$i]=${temp_list[$j]}
        temp_list[$j]=$tmp
    done

    BOT_HUNT_LIST=("${temp_list[@]}")
}

bot_choose_shot() {
    while [ "${#BOT_TARGET_QUEUE[@]}" -gt 0 ]; do
        local candidate=${BOT_TARGET_QUEUE[0]}
        BOT_TARGET_QUEUE=("${BOT_TARGET_QUEUE[@]:1}")
        if [ "${P2_SHOTS[$candidate]}" -eq 0 ]; then
            echo "$candidate"
            return
        fi
    done

    while [ "${#BOT_HUNT_LIST[@]}" -gt 0 ]; do
        local candidate=${BOT_HUNT_LIST[0]}
        BOT_HUNT_LIST=("${BOT_HUNT_LIST[@]:1}")
        if [ "${P2_SHOTS[$candidate]}" -eq 0 ]; then
            echo "$candidate"
            return
        fi
    done

    local remaining=()
    for ((i=0; i<100; i++)); do
        if [ "${P2_SHOTS[$i]}" -eq 0 ]; then
            remaining+=($i)
        fi
    done

    if [ "${#remaining[@]}" -gt 0 ]; then
        local rand_idx=$((RANDOM % ${#remaining[@]}))
        echo "${remaining[$rand_idx]}"
        return
    fi

    echo "0"
}

bot_add_adjacent_targets() {
    local hit_idx=$1
    local r=$((hit_idx / 10))
    local c=$((hit_idx % 10))

    local neighbors=()
    if [ "$r" -gt 0 ]; then neighbors+=($(((r - 1) * 10 + c))); fi
    if [ "$r" -lt 9 ]; then neighbors+=($(((r + 1) * 10 + c))); fi
    if [ "$c" -gt 0 ]; then neighbors+=($((r * 10 + (c - 1)))); fi
    if [ "$c" -lt 9 ]; then neighbors+=($((r * 10 + (c + 1)))); fi

    for nb in "${neighbors[@]}"; do
        if [ "${P2_SHOTS[$nb]}" -eq 0 ]; then
            BOT_TARGET_QUEUE+=($nb)
        fi
    done
}

# ------------------------------------------------------------------------------
# Старт сервера
# ------------------------------------------------------------------------------
echo -e "${C_CYAN}========================================================================${C_RESET}"
echo -e "${C_BOLD}           СЕРВЕР «МОРСКОЙ БОЙ» (BASH CLIENT-SERVER)                    ${C_RESET}"
echo -e "${C_CYAN}========================================================================${C_RESET}"
echo "Выберите режим игры:"
echo "  [1] 1 на 1 (Два игрока: Игрок 1 на :$PORT_P1, Игрок 2 на :$PORT_P2)"
echo "  [2] 1 на 1 (Человек против Бота: Игрок на :$PORT_P1)"
read -rp "Ваш выбор [1/2]: " GAME_MODE

if [ "$GAME_MODE" != "1" ] && [ "$GAME_MODE" != "2" ]; then
    GAME_MODE=2
fi

init_boards

if [ "$GAME_MODE" -eq 1 ]; then
    echo -e "\n${C_GREEN}[Режим: 2 Игрока]${C_RESET}"
    echo -e "Игрок 1 подключается командой: ${C_YELLOW}./client.sh 1${C_RESET} (порт $PORT_P1)"
    echo -e "Игрок 2 подключается командой: ${C_YELLOW}./client.sh 2${C_RESET} (порт $PORT_P2)"
    echo -e "Запуск прослушивания Игрока 1 на порту ${C_YELLOW}$PORT_P1${C_RESET}..."
    coproc NC1 { nc -l -p "$PORT_P1"; }
    echo -e "Запуск прослушивания Игрока 2 на порту ${C_YELLOW}$PORT_P2${C_RESET}..."
    coproc NC2 { nc -l -p "$PORT_P2"; }

    # Фаза подключения Игрока 1
    echo "Ожидание подключения Игрока 1..."
    echo -e "\n${C_GREEN}✓ Вы подключены как Игрок 1!${C_RESET}\n${C_YELLOW}Ожидание подключения Игрока 2...${C_RESET}\n" >&"${NC1[1]}"
    sleep 0.5
    echo -e "${C_GREEN}✓ Игрок 1 в сети!${C_RESET}"

    # Фаза подключения Игрока 2
    echo "Ожидание подключения Игрока 2..."
    echo -e "\n${C_GREEN}✓ Вы подключены как Игрок 2!${C_RESET}\n" >&"${NC2[1]}"
    sleep 0.5
    echo -e "${C_GREEN}✓ Игрок 2 в сети!${C_RESET}"

    # Расстановка флотов игроками
    echo "Переход к расстановке флотов..."
    echo -e "${C_GRAY}Игрок 1 сейчас выбирает способ расстановки. Ожидайте...${C_RESET}\n" >&"${NC2[1]}"
    setup_player_fleet 1 "${NC1[0]}" "${NC1[1]}"

    echo -e "${C_GRAY}Игрок 2 сейчас выбирает способ расстановки. Ожидайте...${C_RESET}\n" >&"${NC1[1]}"
    setup_player_fleet 2 "${NC2[0]}" "${NC2[1]}"

else
    echo -e "\n${C_GREEN}[Режим: Человек против Бота]${C_RESET}"
    echo -e "Запуск прослушивания Игрока на порту ${C_YELLOW}$PORT_P1${C_RESET}..."
    coproc NC1 { nc -l -p "$PORT_P1"; }

    echo "Ожидание подключения игрока (запустите ./client.sh)..."
    init_bot
    auto_place_fleet 2 # Флот бота всегда генерируется автоматически

    # Расстановка флота игрока
    setup_player_fleet 1 "${NC1[0]}" "${NC1[1]}"
fi

echo "Флоты расставлены. Игра началась!"

# ------------------------------------------------------------------------------
# Игровой цикл
# ------------------------------------------------------------------------------
CURRENT_TURN=1
LAST_MSG_P1="Игра началась! Ваш флот готов. Вы стреляете первым."
LAST_MSG_P2="Игра началась! Противник стреляет первым."
GAME_RUNNING=1

while [ "$GAME_RUNNING" -eq 1 ]; do
    if [ "$CURRENT_TURN" -eq 1 ]; then
        render_screen 1 "$LAST_MSG_P1\n${C_YELLOW}>>> ВАШ ХОД! Введите координаты (например, A1, B5, J10): ${C_RESET}" >&"${NC1[1]}"
        if [ "$GAME_MODE" -eq 1 ]; then
            render_screen 2 "$LAST_MSG_P2\n${C_GRAY}[Ход Игрока 1...]${C_RESET}" >&"${NC2[1]}"
        fi

        read -r raw_coord <&"${NC1[0]}" || break
        raw_coord=$(echo "$raw_coord" | tr -d '\r\n')
        shot_idx=$(parse_coord "$raw_coord")

        if [ -z "$shot_idx" ]; then
            LAST_MSG_P1="${C_RED}Неверный формат координат! Введите букву (A-J) и цифру (1-10), например: B4${C_RESET}"
            continue
        fi

        if [ "${P1_SHOTS[$shot_idx]}" -ne 0 ]; then
            LAST_MSG_P1="${C_YELLOW}В клетку $(idx_to_coord "$shot_idx") вы уже стреляли! Выберите другую.${C_RESET}"
            continue
        fi

        coord_str=$(idx_to_coord "$shot_idx")
        process_shot 1 "$shot_idx"
        res=$?

        if [ "$res" -eq 0 ]; then
            LAST_MSG_P1="${C_YELLOW}Выстрел в $coord_str: ПРОМАХ! Ход переходит сопернику.${C_RESET}"
            LAST_MSG_P2="${C_GREEN}Противник выстрелил в $coord_str и ПРОМАХНУЛСЯ! Ваш ход!${C_RESET}"
            CURRENT_TURN=2
        elif [ "$res" -eq 1 ]; then
            LAST_MSG_P1="${C_RED}Выстрел в $coord_str: РАНИЛ! Дополнительный ход!${C_RESET}"
            LAST_MSG_P2="${C_RED}Противник выстрелил в $coord_str и РАНИЛ ваш корабль!${C_RESET}"
            CURRENT_TURN=1
        elif [ "$res" -eq 2 ]; then
            LAST_MSG_P1="${C_RED}${C_BOLD}Выстрел в $coord_str: УБИЛ КОРАБЛЬ! Дополнительный ход!${C_RESET}"
            LAST_MSG_P2="${C_RED}Противник выстрелил в $coord_str и ПОТОПИЛ ваш корабль!${C_RESET}"
            CURRENT_TURN=1
        elif [ "$res" -eq 3 ]; then
            render_screen 1 "${C_GREEN}${C_BOLD}УРА! ВЫ ПОТОПИЛИ ВЕСЬ ВРАЖЕСКИЙ ФЛОТ! ПОБЕДА!${C_RESET}" >&"${NC1[1]}"
            if [ "$GAME_MODE" -eq 1 ]; then
                render_screen 2 "${C_RED}${C_BOLD}ВАШ ФЛОТ ПОЛНОСТЬЮ УНИЧТОЖЕН! ВЫ ПРОИГРАЛИ.${C_RESET}" >&"${NC2[1]}"
            fi
            echo -e "${C_GREEN}Игрок 1 победил!${C_RESET}"
            GAME_RUNNING=0
            break
        fi

    else
        # Ход Игрока 2 или Бота
        if [ "$GAME_MODE" -eq 1 ]; then
            render_screen 2 "$LAST_MSG_P2\n${C_YELLOW}>>> ВАШ ХОД! Введите координаты (например, A1, B5, J10): ${C_RESET}" >&"${NC2[1]}"
            render_screen 1 "$LAST_MSG_P1\n${C_GRAY}[Ход Игрока 2...]${C_RESET}" >&"${NC1[1]}"

            read -r raw_coord <&"${NC2[0]}" || break
            raw_coord=$(echo "$raw_coord" | tr -d '\r\n')
            shot_idx=$(parse_coord "$raw_coord")

            if [ -z "$shot_idx" ]; then
                LAST_MSG_P2="${C_RED}Неверный формат координат! Введите букву (A-J) и цифру (1-10), например: B4${C_RESET}"
                continue
            fi

            if [ "${P2_SHOTS[$shot_idx]}" -ne 0 ]; then
                LAST_MSG_P2="${C_YELLOW}В клетку $(idx_to_coord "$shot_idx") вы уже стреляли! Выберите другую.${C_RESET}"
                continue
            fi

            coord_str=$(idx_to_coord "$shot_idx")
            process_shot 2 "$shot_idx"
            res=$?

            if [ "$res" -eq 0 ]; then
                LAST_MSG_P2="${C_YELLOW}Выстрел в $coord_str: ПРОМАХ! Ход переходит сопернику.${C_RESET}"
                LAST_MSG_P1="${C_GREEN}Противник выстрелил в $coord_str и ПРОМАХНУЛСЯ! Ваш ход!${C_RESET}"
                CURRENT_TURN=1
            elif [ "$res" -eq 1 ]; then
                LAST_MSG_P2="${C_RED}Выстрел в $coord_str: РАНИЛ! Дополнительный ход!${C_RESET}"
                LAST_MSG_P1="${C_RED}Противник выстрелил в $coord_str и РАНИЛ ваш корабль!${C_RESET}"
                CURRENT_TURN=2
            elif [ "$res" -eq 2 ]; then
                LAST_MSG_P2="${C_RED}${C_BOLD}Выстрел в $coord_str: УБИЛ КОРАБЛЬ! Дополнительный ход!${C_RESET}"
                LAST_MSG_P1="${C_RED}Противник выстрелил в $coord_str и ПОТОПИЛ ваш корабль!${C_RESET}"
                CURRENT_TURN=2
            elif [ "$res" -eq 3 ]; then
                render_screen 2 "${C_GREEN}${C_BOLD}УРА! ВЫ ПОТОПИЛИ ВЕСЬ ВРАЖЕСКИЙ ФЛОТ! ПОБЕДА!${C_RESET}" >&"${NC2[1]}"
                render_screen 1 "${C_RED}${C_BOLD}ВАШ ФЛОТ ПОЛНОСТЬЮ УНИЧТОЖЕН! ВЫ ПРОИГРАЛИ.${C_RESET}" >&"${NC1[1]}"
                echo -e "${C_GREEN}Игрок 2 победил!${C_RESET}"
                GAME_RUNNING=0
                break
            fi
        else
            # Ход Бота (быстрый отклик 0.3s)
            sleep 0.3
            shot_idx=$(bot_choose_shot)
            coord_str=$(idx_to_coord "$shot_idx")
            process_shot 2 "$shot_idx"
            res=$?

            if [ "$res" -eq 0 ]; then
                LAST_MSG_P1="${C_GREEN}Бот выстрелил в $coord_str: ПРОМАХ! Ваш ход!${C_RESET}"
                CURRENT_TURN=1
            elif [ "$res" -eq 1 ]; then
                bot_add_adjacent_targets "$shot_idx"
                LAST_MSG_P1="${C_RED}Бот выстрелил в $coord_str и РАНИЛ ваш корабль! Бот делает повторный выстрел...${C_RESET}"
                CURRENT_TURN=2
            elif [ "$res" -eq 2 ]; then
                LAST_MSG_P1="${C_RED}${C_BOLD}Бот выстрелил в $coord_str и ПОТОПИЛ ваш корабль! Бот делает повторный выстрел...${C_RESET}"
                CURRENT_TURN=2
            elif [ "$res" -eq 3 ]; then
                render_screen 1 "${C_RED}${C_BOLD}БОТ ПОТОПИЛ ВЕСЬ ВАШ ФЛОТ! ВЫ ПРОИГРАЛИ.${C_RESET}" >&"${NC1[1]}"
                echo -e "${C_RED}Бот победил!${C_RESET}"
                GAME_RUNNING=0
                break
            fi
        fi
    fi
done

echo "Игра завершена."
