#!/bin/bash

# Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo "Пожалуйста, запустите скрипт через sudo"
   exit 1
fi

# Автоматическое определение пользователя
REAL_USER=$(logname || echo $SUDO_USER || whoami)
SERVICE_NAME="kde_fast_mount.service"
# Важно: используем единые пути для установщика и создаваемого скрипта
CONFIG_FILE="/etc/kde_fast_mount.conf"
SCRIPT_PATH="/usr/local/bin/kde_fast_mount.sh"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

echo "--- Установка автомонтрирования для пользователя: $REAL_USER ---"

# 1. Поиск дисков с улучшенной фильтрацией системного раздела
echo "Поиск доступных дисков..."
# Исключаем разделы, которые монтируются в корень, home, boot или swap
mapfile -t DISKS < <(lsblk -rno NAME,UUID,MOUNTPOINTS,SIZE | grep -vE '(/|/home|/boot|/root|\[SWAP\])' | grep -v '^$')

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "Подходящие диски не найдены. Проверьте, не примонтированы ли они уже в систему."
    exit 1
fi

echo "Найдены следующие разделы:"
for i in "${!DISKS[@]}"; do
    IFS=' ' read -r name uuid mount size <<< "${DISKS[$i]}"
    echo "$((i+1))) $name ($size) UUID: $uuid"
done

# Чтение ввода напрямую из терминала для работы через curl
read -p "Введите номера дисков через пробел: " CHOICES < /dev/tty

if [ -z "$CHOICES" ]; then
    echo "Выбор не сделан. Отмена."
    exit 0
fi

# 2. Создание конфига
echo "# UUID                                 FOLDER_NAME" > "$CONFIG_FILE"
for num in $CHOICES; do
    index=$((num-1))
    if [ -n "${DISKS[$index]}" ]; then
        IFS=' ' read -r name uuid mount size <<< "${DISKS[$index]}"
        # Используем UUID как имя папки по умолчанию
        echo "$uuid   $uuid" >> "$CONFIG_FILE"
        echo "Добавлен в конфиг: $name"
    fi
done

# 3. Генерация основного скрипта монтирования
# Используем одинарные кавычки 'EOF', чтобы переменные внутри не раскрылись раньше времени
cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
CONFIG_FILE="$CONFIG_FILE"
TARGET_USER="$REAL_USER"
BASE_PATH="/run/media/\$TARGET_USER"
MAX_RETRIES=50
SLEEP_TIME=0.1

USER_UID=\$(id -u \$TARGET_USER)
USER_GID=\$(id -g \$TARGET_USER)

mount_single_disk() {
    local disk_uuid=\$1
    local dir_name=\$2
    [ -z "\$dir_name" ] && dir_name="\$disk_uuid"

    FULL_PATH="\$BASE_PATH/\$dir_name"
    DEVICE="/dev/disk/by-uuid/\$disk_uuid"

    for ((i=0; i<MAX_RETRIES; i++)); do
        if [ -e "\$DEVICE" ]; then
            mkdir -p "\$FULL_PATH"
            mountpoint -q "\$FULL_PATH" && return

            # Пробуем монтировать с правами пользователя (для NTFS/FAT)
            mount -U "\$disk_uuid" "\$FULL_PATH" -o defaults,noatime,nofail,uid=\$USER_UID,gid=\$USER_GID 2>/dev/null || \\
            mount -U "\$disk_uuid" "\$FULL_PATH" -o defaults,noatime,nofail

            # Для Linux ФС меняем владельца самой точки монтирования
            chown "\$USER_UID":"\$USER_GID" "\$FULL_PATH"
            return
        fi
        sleep \$SLEEP_TIME
    done
}

# Запуск параллельного монтирования
grep -vE '^\s*#|^\s*$' "\$CONFIG_FILE" | while read -r uuid folder; do
    mount_single_disk "\$uuid" "\$folder" &
done
wait
EOF

chmod +x "$SCRIPT_PATH"

# 4. Генерация systemd сервиса
cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Smart Auto-mount for $REAL_USER
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 5. Активация и немедленный запуск
echo "Активация сервиса..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
# Явный запуск скрипта для мгновенного результата
bash "$SCRIPT_PATH"

echo "------------------------------------------------"
echo "Установка завершена! Проверьте папку /run/media/$REAL_USER/"
