# 🚀 3x-ui Webmin User Sync (Universal Turbo Edition)

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-v3.4.2-green.svg)
![Database](https://img.shields.io/badge/Database-PostgreSQL%20%7C%20SQLite-orange)

สคริปต์ขั้นเทพสำหรับดึงข้อมูลผู้ใช้งาน (Users) จาก **Webmin** มาซิงค์เข้าสู่แผงควบคุม **3x-ui (v3.4.2)** แบบอัตโนมัติ มาพร้อมกับขุมพลัง **Hash-Map Engine** ที่เปลี่ยนการซิงค์ข้อมูลแบบเดิมที่ใช้เวลาหลายนาที ให้จบลงได้ภายใน **"เสี้ยววินาที"** (ทดสอบกับ 3,000+ Users ใช้เวลาเพียง 1-2 วินาที)

## ✨ ฟีเจอร์เด่น (Key Features)

* ⚡ **Ultra-Fast Performance (0.3 - 1.5s):** ประมวลผลด้วยระบบ Dictionary Hash-Map ($O(1)$) ข้ามข้อจำกัดการวนลูปแบบเก่า เร็วกว่าเดิม 100 เท่า!
* 🧠 **Auto-Detect Database:** รองรับทั้ง **PostgreSQL** และ **SQLite** โดยสคริปต์จะตรวจสอบและเลือกใช้คำสั่งให้เหมาะสมกับเซิร์ฟเวอร์นั้นๆ แบบอัตโนมัติ
* 🛡️ **Self-Healing System:** มีระบบตรวจสอบความสมบูรณ์ของโครงสร้าง JSON หากพบว่าฐานข้อมูลมีปัญหา สคริปต์จะทำการซ่อมแซมโครงสร้างพื้นฐานให้ทันที
* 🔓 **VLESS Auto-Fix:** ตรวจจับโปรโตคอล VLESS และฝังกฎ `decryption: none` ให้อัตโนมัติ ป้องกันปัญหา Xray-core แครช
* 🚀 **Memory Limit Bypass:** ทะลุขีดจำกัดกระเป๋าข้อมูล 64KB ของ Linux ด้วยการใช้ระบบสร้างไฟล์ TEMP SQL ไร้ปัญหาข้อมูลแหว่งหาย 100%
* 🤖 **Auto Sync (Cronjob):** มาพร้อมเมนูตั้งค่าทำงานอัตโนมัติในพื้นหลัง (รันทุกวันเวลา 03:00 น.)

## 📋 ความต้องการของระบบ (Requirements)

* OS: **Ubuntu / Debian** (จำเป็นต้องใช้สิทธิ์ `root` ในการรัน)
* แผงควบคุม: **3x-ui เวอร์ชัน 3.4.2**
* แพ็กเกจเสริม: `jq`, `sshpass`, `psql`, `sqlite3`, `gawk` *(สคริปต์จะติดตั้งให้เองหากไม่มี)*

## 🛠️ วิธีติดตั้งและใช้งาน (Installation & Usage)

คุณสามารถติดตั้งและรันสคริปต์ได้ทันทีผ่านคำสั่งเดียว (One-Liner):

```bash
wget -O user-sync.sh https://raw.githubusercontent.com/TspKchn/3x-ui-Sync-Webmin/main/user-sync.sh && chmod +x user-sync.sh && bash user-sync.sh

```
