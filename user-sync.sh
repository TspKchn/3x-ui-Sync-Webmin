#!/bin/bash
set -euo pipefail

### ================= CONFIG =================
PG_DSN=$(grep '^XUI_DB_DSN=' /etc/default/x-ui | cut -d= -f2- | tr -d '"' | tr -d "'")
CONF="/etc/user-sync.conf"
TMP="/tmp/user-sync"
mkdir -p "$TMP"

### ================= UTILS =================
pause() { read -rp "กด Enter เพื่อกลับเมนู..."; }
log() { echo "[$(date '+%F %T')] $*"; }
require_root() { 
    if [[ $EUID -ne 0 ]]; then 
        echo "ต้องรันด้วย root"
        exit 1
    fi 
}
require_root

db_exec() {
    psql "$PG_DSN" -A -t -F '|' -c "$1"
}

for c in jq sshpass psql awk; do
    if ! command -v "$c" >/dev/null 2>&1; then
        echo "กำลังติดตั้ง $c ..."
        apt update -y && apt install -y jq sshpass postgresql-client gawk
        break
    fi
done

### ================= STATE MANAGEMENT =================
load_last_sync() {
    LAST_SYNC="ยังไม่เคยซิงค์"
    if [[ -f "$CONF" ]]; then
        LAST_SYNC=$(grep '^LAST_SYNC=' "$CONF" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
    fi
}

save_last_sync() {
    sed -i '/^LAST_SYNC=/d' "$CONF" 2>/dev/null || true
    TZ=Asia/Bangkok date '+LAST_SYNC="%F %T"' >> "$CONF"
}

load_config() {
    if [[ -f "$CONF" ]]; then
        source "$CONF"
    fi
}

save_config() {
    cat <<EOF > "$CONF"
WM_HOST="${WM_HOST:-}"
WM_PORT="${WM_PORT:-22}"
WM_USER="${WM_USER:-root}"
WM_PASS="${WM_PASS:-}"
INBOUND_ID="${INBOUND_ID:-}"
LAST_SYNC="${LAST_SYNC:-}"
EOF
    chmod 600 "$CONF"
}

### ================= SELECT INBOUND =================
select_inbound() {
    echo "[*] โหลดรายการ inbound จาก PostgreSQL..."
    mapfile -t INBOUND_LIST < <(db_exec "SELECT id, remark, protocol, port FROM inbounds;")
    
    if [[ ${#INBOUND_LIST[@]} -eq 0 ]]; then
        echo "❌ ไม่พบ inbound ในฐานข้อมูล"
        return 1
    fi
    
    echo
    for row in "${INBOUND_LIST[@]}"; do
        IFS='|' read -r id remark proto port <<<"$row"
        echo "[$id] $remark - $proto :$port"
    done
    echo
    
    read -rp "เลือก Inbound ID: " INBOUND_ID
    if [[ ! "$INBOUND_ID" =~ ^[0-9]+$ ]]; then return 1; fi
    
    for row in "${INBOUND_LIST[@]}"; do
        IFS='|' read -r id _ <<<"$row"
        if [[ "$id" == "$INBOUND_ID" ]]; then return 0; fi
    done
    return 1
}

### ================= FETCH WEBMIN =================
fetch_webmin() {
    read -rp "Webmin host [${WM_HOST:-}]: " INPUT_HOST
    WM_HOST=${INPUT_HOST:-${WM_HOST:-}}
    
    read -rp "Webmin ssh port [${WM_PORT:-22}]: " INPUT_PORT
    WM_PORT=${INPUT_PORT:-${WM_PORT:-22}}
    
    read -rp "Webmin user [${WM_USER:-root}]: " INPUT_USER
    WM_USER=${INPUT_USER:-${WM_USER:-root}}
    
    read -rp "Webmin password: " INPUT_PASS
    WM_PASS=${INPUT_PASS:-${WM_PASS:-}}

    echo
    select_inbound || { echo "ยกเลิก"; return 1; }
    save_config

    do_fetch
}

do_fetch() {
    log "Fetch users from Webmin ($WM_HOST)..."
    sshpass -p "$WM_PASS" ssh -p "$WM_PORT" \
        -o StrictHostKeyChecking=no \
        -o LogLevel=ERROR \
        "$WM_USER@$WM_HOST" '
        awk -F: "
        NR==FNR { if (\$3>=1000 && \$3<=65534) ok[\$1]=1; next }
        (\$1 in ok) {
            if (\$8==\"\" || \$8<0) ex=0;
            else ex=\$8*86400*1000;
            print \$1, ex
        }
        " /etc/passwd /etc/shadow
    ' > "$TMP/users.txt" || { echo "❌ ดึงข้อมูล Webmin ไม่สำเร็จ"; return 1; }
}

### ================= SYNC CORE (0.3 SECONDS HASH-MAP ENGINE) =================
sync_core() {
    if [[ ! -f "$TMP/users.txt" ]]; then 
        echo "❌ ไม่พบไฟล์ users.txt ให้ดึงข้อมูลใหม่ (เมนู 1) ก่อน"
        return 1
    fi

    if [[ -z "${INBOUND_ID:-}" ]]; then
        select_inbound || { echo "❌ ไม่ได้เลือก Inbound ยกเลิกการซิงค์"; return 1; }
        save_config
    fi
    
    TOTAL=$(wc -l < "$TMP/users.txt")
    echo "[*] Total users to sync: $TOTAL (ลง Inbound ID: $INBOUND_ID)"
    if [[ "$TOTAL" -eq 0 ]]; then return 1; fi

    psql "$PG_DSN" -A -t -c "SELECT settings FROM inbounds WHERE id=$INBOUND_ID;" > "$TMP/settings.raw.json"

    log "⚡ กำลังประมวลผลระบบ Dictionary Hash-Map ขนาด $TOTAL คน..."
    
    # ท่อที่ 1: เปลี่ยน users.txt เป็นตารางดิกชันนารีในความจำ RAM
    tr -d '\r' < "$TMP/users.txt" | awk '{print "{\""$1"\":"$2"}"}' | jq -s 'add // {}' > "$TMP/w_map.json"
    TS=$(date +%s%3N)

    # ท่อที่ 2: สั่ง jq ตบแปะข้อมูลม้วนเดียวจบ (ไม่ใช้ $ นำหน้าคีย์ ลดความเสี่ยงพัง 100%)
    jq --slurpfile w "$TMP/w_map.json" --argjson ts "$TS" '
      ($w[0] // {}) as $webmin_dict |
      (.clients // [] | map({(.email): .}) | add // {}) as $old_clients_dict |

      .clients = [
        $webmin_dict | to_entries[] | .key as $email | .value as $exp |
        if ($old_clients_dict | has($email)) then
          ($old_clients_dict[$email] + {"expiryTime": $exp, "updated_at": $ts})
        else
          {
            "id": $email, "email": $email, "subId": $email, "enable": true, "expiryTime": $exp,
            "limitIp": 0, "totalGB": 0, "reset": 0, "flow": "", "comment": "", "tgId": 0,
            "created_at": $ts, "updated_at": $ts
          }
        end
      ]
    ' "$TMP/settings.raw.json" > "$TMP/settings.min.json"

    # ท่อที่ 3: บันทึกลง PostgreSQL ผ่านคำสั่ง \set
    psql "$PG_DSN" -q <<SQL
\set new_settings \`cat $TMP/settings.min.json\`
UPDATE inbounds SET settings = :'new_settings' WHERE id = $INBOUND_ID;
SQL
    
    log "Reconciling 3x-ui v3.4.1 GUI tables in PostgreSQL..."

    psql "$PG_DSN" -q <<SQL
BEGIN;

INSERT INTO clients (
  email, sub_id, uuid, password, limit_ip, total_gb, expiry_time, enable, tg_id, group_name, comment, reset, created_at, updated_at
)
SELECT 
  j->>'email', j->>'subId', j->>'id', j->>'id', (j->>'limitIp')::int, (j->>'totalGB')::bigint,
  (j->>'expiryTime')::bigint, (j->>'enable')::boolean, (j->>'tgId')::int, '', j->>'comment',
  (j->>'reset')::int, (j->>'created_at')::bigint, (j->>'updated_at')::bigint
FROM inbounds i, jsonb_array_elements(i.settings::jsonb->'clients') j
WHERE i.id = $INBOUND_ID
ON CONFLICT (email) DO UPDATE SET
  expiry_time = EXCLUDED.expiry_time, enable = EXCLUDED.enable, updated_at = EXCLUDED.updated_at;

INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at)
SELECT c.id, $INBOUND_ID, '', (extract(epoch from now())*1000)::bigint
FROM clients c
WHERE c.email IN (
  SELECT j->>'email' FROM inbounds i, jsonb_array_elements(i.settings::jsonb->'clients') j WHERE i.id = $INBOUND_ID
) ON CONFLICT DO NOTHING;

DELETE FROM client_inbounds WHERE inbound_id = $INBOUND_ID AND client_id NOT IN (
  SELECT c.id FROM clients c, inbounds i, jsonb_array_elements(i.settings::jsonb->'clients') j
  WHERE i.id = $INBOUND_ID AND c.email = j->>'email'
);

DELETE FROM clients WHERE id NOT IN (SELECT DISTINCT client_id FROM client_inbounds);

DELETE FROM client_traffics WHERE inbound_id = $INBOUND_ID AND email NOT IN (
  SELECT j->>'email' FROM inbounds i, jsonb_array_elements(i.settings::jsonb->'clients') j WHERE i.id = $INBOUND_ID
);

DELETE FROM client_traffics WHERE expiry_time>0 AND expiry_time < (extract(epoch from now())*1000)::bigint;

INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset)
SELECT $INBOUND_ID, true, j->>'email', 0, 0, (j->>'expiryTime')::bigint, 0, 0
FROM inbounds i, jsonb_array_elements(i.settings::jsonb->'clients') j WHERE i.id = $INBOUND_ID
ON CONFLICT DO NOTHING;

COMMIT;
SQL

    systemctl restart x-ui || x-ui restart
    save_last_sync

    echo "[✓] Sync users สำเร็จทั้งหมดในเสี้ยววินาที!"
}

### ================= AUTO SYNC =================
set_auto_sync() {
    (crontab -l 2>/dev/null | grep -v user-sync.sh || true; echo "0 3 * * * $(realpath "$0") --auto") | crontab -
    echo "ตั้ง Auto Sync ทุกวันเวลา 03:00 น. เรียบร้อยแล้ว"; pause
}

disable_auto_sync() {
    (crontab -l 2>/dev/null | grep -v user-sync.sh || true) | crontab -
    echo "ยกเลิก Auto Sync เรียบร้อยแล้ว"; pause
}

### ================= AUTO MODE =================
if [[ "${1:-}" == "--auto" ]]; then
    load_config
    if [[ -z "${WM_HOST:-}" || -z "${INBOUND_ID:-}" ]]; then exit 1; fi
    do_fetch; sync_core; exit 0
fi

### ================= MENU =================
while true; do
    load_config; load_last_sync; clear
    echo "========================================="
    echo "  USER SYNC (PostgreSQL Turbo Edition)"
    echo "========================================="
    echo "Last Sync: $LAST_SYNC"
    echo "-----------------------------------------"
    echo "1) ดึงข้อมูลใหม่จาก Webmin และ Sync ทันที"
    echo "2) Sync จากไฟล์ข้อมูล Local เดิมที่มีอยู่"
    echo "3) เปิด Auto Sync (รันทุกวันเวลา 03:00 น.)"
    echo "4) ปิดการทำงาน Auto Sync"
    echo "0) ออก"
    echo "-----------------------------------------"
    read -rp "เลือกเมนู: " m
    case "$m" in
        1) fetch_webmin && sync_core || true; pause ;;
        2) sync_core || true; pause ;;
        3) set_auto_sync || true ;;
        4) disable_auto_sync || true ;;
        0) exit 0 ;;
    esac
done
