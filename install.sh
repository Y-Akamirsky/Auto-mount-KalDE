#!/bin/bash

# Проверка на root (нужен для записи в /usr/local/bin и /etc)
if [[ $EUID -ne 0 ]]; then
   echo "Пожалуйста, запустите скрипт через sudo"
   exit 1
fi

REAL_USER=$(logname || echo $SUDO_USER || whoami)
CONFIG_FILE="/etc/kde_fast_mount.conf"
SCRIPT_PATH="/usr/local/bin/kde_fast_mount.sh"
SERVICE_PATH="/etc/systemd/system/kde_fast_mount.service"

echo "--- Установка автомонтрирования для пользователя: $REAL_USER ---"

# 1. Поиск подходящих дисков (исключаем корень, бут и своп)
echo "Поиск доступных дисков..."
mapfile -t DISKS < <(lsblk -rno NAME,UUID,MOUNTPOINTS,SIZE,TYPE | grep 'part$' | grep -v ' /$' | grep -v '/boot' | grep -v '[SWAP]')

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "Подходящие диски не найдены."
    exit 1
fi

echo "Найдены следующие разделы:"
for i in "${!DISKS[@]}"; do
    IFS=' ' read -r name uuid mount size type <<< "${DISKS[$i]}"
    echo "$((i+1))) $name ($size) UUID: $uuid"
done

read -p "Введите номера дисков через пробел, которые нужно добавить (например: 1 3): " CHOICES

# 2. Создание конфига /etc/my_mounts.conf
echo "# UUID                                 FOLDER_NAME" > $CONFIG_FILE
for num in $CHOICES; do
    index=$((num-1))
    if [ -n "${DISKS[$index]}" ]; then
        IFS=' ' read -r name uuid mount size type <<< "${DISKS[$index]}"
        echo "$uuid   $uuid" >> $CONFIG_FILE
        echo "Добавлен диск: $name"
    fi
done

# 3. Генерация основного скрипта монтирования
cat << EOF > $SCRIPT_PATH
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

            # Попытка монтирования с uid/gid (для NTFS) или обычного
            mount -U "\$disk_uuid" "\$FULL_PATH" -o defaults,noatime,nofail,uid=\$USER_UID,gid=\$USER_GID 2>/dev/null || \\
            mount -U "\$disk_uuid" "\$FULL_PATH" -o defaults,noatime,nofail

            chown "\$USER_UID":"\$USER_GID" "\$FULL_PATH"
            return
        fi
        sleep \$SLEEP_TIME
    done
}

grep -vE '^\s*#|^\s*$' "\$CONFIG_FILE" | while read -r uuid folder; do
    mount_single_disk "\$uuid" "\$folder" &
done
wait
EOF

chmod +x $SCRIPT_PATH

# 4. Генерация systemd сервиса
cat << EOF > $SERVICE_PATH
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

# 5. Активация
systemctl daemon-reload
systemctl enable mount-drives.service
systemctl start mount-drives.service

echo "------------------------------------------------"
echo "Установка завершена! Диски примонтированы в /run/media/$REAL_USER/"
