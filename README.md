# Booking Share

แอปภายในบริษัทสำหรับแชร์ว่ามีการจองห้องพักและลูกค้าในแต่ละวันเท่าไร เน้นใช้งานบนมือถือและติดตั้งเป็น PWA ได้

เอกสารหลัก
- [SCOPE.md](./SCOPE.md) — ขอบเขตและกติกา MVP (แหล่งความจริง)
- [UX-UI.md](./UX-UI.md) — หน้าจอ การไหลของผู้ใช้ และ design tokens
- [wireframes/index.html](./wireframes/index.html) — wireframe แบบกดได้ เปิดในเบราว์เซอร์ได้เลย (ข้อมูลตัวอย่าง ใช้กติกาเดียวกับ schema)

## ขอบเขต MVP

- สมาชิกบริษัทเข้าสู่ระบบ
- การจองห้องพักข้ามคืน: หนึ่งรายการมีหลายห้อง ใช้วันเข้า–ออกชุดเดียวกัน กรอกจำนวนคนแยกต่อห้อง
- ห้องเดียวกันห้ามจองซ้อนคืนเดียวกัน บังคับที่ PostgreSQL
- ปฏิทินรายเดือน นับตามวันเข้าพัก แยกยอด **รอเช็กอิน** และ **เช็กอินแล้ว** แตะวันเพื่อดูรายการและกดเช็กอินได้ทันที
- เพิ่ม แก้ไข ยกเลิก และคืนรายการจอง (คืนได้เมื่อทุกห้องว่างตลอดช่วงพัก)
- ผู้ใช้กรอกยอดรวมเอง และตรวจใน dialog ก่อนบันทึก
- แจ้งเตือนในแอปเมื่อมีการจอง ยกเลิก หรือคืนรายการ
- เพิ่ม/แก้ไข/เปิด-ปิดใช้งานห้องในแอป (หน้าจัดการห้อง)

ยังไม่มี: จองผ่าน public API, หลายบริษัท/การซิงก์ `Booking-system`, คิดราคาอัตโนมัติ, รับชำระเงิน, รายงานรายรับ, push/LINE/อีเมล

## โครงสร้าง Next.js ที่จะสร้าง

```text
booking-share/
├── src/
│   ├── app/
│   │   ├── (auth)/login/page.tsx
│   │   ├── (main)/layout.tsx                  # shell + bottom nav
│   │   ├── (main)/calendar/page.tsx           # ปฏิทิน + ยอดรายวัน
│   │   ├── (main)/bookings/new/page.tsx
│   │   ├── (main)/bookings/[id]/page.tsx      # รายละเอียด/ยกเลิก/คืนรายการ
│   │   ├── (main)/bookings/[id]/edit/page.tsx
│   │   ├── (main)/notifications/page.tsx
│   │   ├── (main)/account/page.tsx
│   │   ├── (main)/rooms/page.tsx              # จัดการห้อง
│   │   ├── layout.tsx
│   │   ├── page.tsx                           # ไป /calendar
│   │   └── manifest.ts                        # PWA manifest
│   ├── components/
│   │   ├── calendar/                          # month grid, day summary, booking card
│   │   └── ui/                                # ปุ่ม ฟอร์ม dialog toast
│   ├── features/
│   │   ├── bookings/                          # actions, queries, types, room picker
│   │   └── notifications/
│   └── lib/
│       ├── supabase/client.ts
│       ├── supabase/server.ts
│       └── dates.ts                           # วันที่ Asia/Bangkok
├── public/icons/                              # ไอคอน PWA
├── supabase/migrations/                       # schema และ RLS
├── .env.example
├── SCOPE.md
├── UX-UI.md
└── README.md
```

ยังไม่ได้สร้างโค้ดแอป

## ข้อมูลหลัก

Schema อยู่ที่ [supabase/migrations/0001_initial.sql](./supabase/migrations/0001_initial.sql)

| ตาราง | ใช้เก็บ |
| --- | --- |
| `team_members` | คนในบริษัทที่ได้รับสิทธิ์ (`display_name`, `is_active`) |
| `rooms` | ห้อง: ชื่อ, ราคาอ้างอิงต่อคืน (ไม่บังคับ, ไม่ใช้คำนวณ), เปิด/ปิดใช้งาน ไม่มีรูป |
| `bookings` | รายการจอง: วันเข้า–ออก ชื่อ ยอดรวม สถานะ (`reserved`, `checked_in`, `cancelled`) และประวัติสร้าง/แก้ไข/เช็กอิน/ยกเลิก/คืนรายการ |
| `booking_rooms` | ห้องในแต่ละรายการ + จำนวนคนต่อห้อง; `EXCLUDE` constraint กันห้องเดียวกันซ้อนคืน |
| `notifications`, `notification_reads` | แจ้งเตือนในแอปและสถานะอ่านรายคน |

- ผู้ใช้ไม่เขียนตารางตรง ๆ ทุกการเขียนผ่าน RPC: `create_booking`, `update_booking`, `cancel_booking`, `restore_booking`, `mark_notification_read`, `mark_all_notifications_read`
- จัดการห้อง: `create_room`, `update_room` (ชื่อ, ราคาอ้างอิง, เปิด/ปิดใช้งาน) ใน [0002_room_management.sql](./supabase/migrations/0002_room_management.sql)
- RPC เช็กอิน: `check_in_booking(id)`, `undo_check_in_booking(id)` ใน [0003_checkin_status.sql](./supabase/migrations/0003_checkin_status.sql)
- RPC ฝั่งอ่าน: `get_daily_stats(from, to)` (ยอดรอเช็กอิน/เช็กอินแล้ว นับตามวันเข้าพัก), `available_rooms(check_in, check_out, exclude_booking_id)`
- View: `booking_overview` (รวมห้อง จำนวนคน ชื่อผู้กระทำ), `notification_feed` (มี `is_read`)
- รหัส error ที่แอปต้อง map: `BK001` ห้องไม่ว่าง (detail ระบุห้อง/คืน), `BK002` ข้อมูลไม่ถูกต้อง (รวมชื่อห้องซ้ำ), `BK003` ไม่มีสิทธิ์, `BK004` สถานะไม่ถูกต้อง, `BK005` ไม่พบรายการ
- การคืนรายการเป็น all-or-nothing: ถ้ามีห้องใดชน ไม่คืนอะไรเลยและคืน `BK001`
- ลบผู้ใช้ที่มีประวัติไม่ได้ ให้ตั้ง `team_members.is_active = false` แทน

ทดสอบ schema (ต้องมี Docker และ `psql`): `supabase/tests/run.sh`

## ลำดับทำงาน

1. ~~สรุปขอบเขต (SCOPE.md)~~
2. ~~ออกแบบ UX/UI (UX-UI.md)~~
3. ~~ออกแบบ schema + RLS + exclusion constraint (มีเทสต์)~~
3b. ~~Wireframe หน้าจอแบบกดได้ ([wireframes/index.html](./wireframes/index.html))~~
4. สร้าง Next.js App Router + TypeScript, ติดตั้ง `@supabase/supabase-js`, `@supabase/ssr`
5. ตั้งค่า Supabase Auth, รัน migration, เพิ่มผู้ใช้ใน `team_members` (ห้องเพิ่มได้ในแอป หรือใช้ `supabase/seed.sql`)
6. ทำ design tokens + คอมโพเนนต์ UI พื้นฐาน
7. ทำหน้า login, ปฏิทิน, ฟอร์มจอง, รายละเอียด, แจ้งเตือน, จัดการห้อง
8. เพิ่ม manifest ไอคอน และทดสอบบนมือถือก่อนเปิดใช้
