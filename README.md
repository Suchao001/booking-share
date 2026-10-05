# Booking Share

แอปภายในบริษัทสำหรับแชร์ว่ามีการจองห้องพักและลูกค้าในแต่ละวันเท่าไร เน้นใช้งานบนมือถือและติดตั้งเป็น PWA ได้

เอกสารหลัก
- [SCOPE.md](./SCOPE.md) — ขอบเขตและกติกา MVP (แหล่งความจริง)
- [UX-UI.md](./UX-UI.md) — หน้าจอ การไหลของผู้ใช้ และ design tokens

## ขอบเขต MVP

- สมาชิกบริษัทเข้าสู่ระบบ
- การจองห้องพักข้ามคืน: หนึ่งรายการมีหลายห้อง ใช้วันเข้า–ออกชุดเดียวกัน กรอกจำนวนคนแยกต่อห้อง
- ห้องเดียวกันห้ามจองซ้อนคืนเดียวกัน บังคับที่ PostgreSQL
- ปฏิทินรายเดือน แยกยอดรายการจอง เช็กอิน และกำลังพัก แตะวันเพื่อดูรายการ
- เพิ่ม แก้ไข ยกเลิก และคืนรายการจอง (คืนได้เมื่อทุกห้องว่างตลอดช่วงพัก)
- ผู้ใช้กรอกยอดรวมเอง และตรวจใน dialog ก่อนบันทึก
- แจ้งเตือนในแอปเมื่อมีการจอง ยกเลิก หรือคืนรายการ
- จัดการรายชื่อห้องผ่าน Supabase Dashboard ในช่วงแรก

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

## ข้อมูลหลัก (แผน)

| ตาราง | ใช้เก็บ |
| --- | --- |
| `team_members` | คนในบริษัทที่ได้รับสิทธิ์ใช้งาน |
| `rooms` | ห้องที่เปิดให้จอง: ชื่อ, ราคาอ้างอิงต่อคืน (ไม่บังคับ, ไม่ใช้คำนวณ), เปิด/ปิดใช้งาน ไม่มีรูป |
| `bookings` | รายการจอง: วันเข้า–ออก ชื่อรายการ ยอดรวม สถานะ |
| `booking_rooms` | ห้องในแต่ละรายการ พร้อมจำนวนคนต่อห้อง และ constraint กันจองห้องซ้อนคืน |
| `notifications` | แจ้งเตือนในแอป |

- จำนวนคนของรายการ = ผลรวมจำนวนคนของแต่ละห้อง ในรายการที่ไม่ถูกยกเลิก
- กำลังพักวันที่ D เมื่อ `check_in <= D < check_out`
- ยอดรวมเป็นค่าที่ผู้ใช้กรอก ไม่คำนวณอัตโนมัติ

> `supabase/migrations/0001_initial.sql` เป็นร่างเก่า (1 การจองต่อ 1 ห้อง ไม่มียอดรวม) ต้องออกแบบใหม่ก่อนรัน ห้ามใช้เป็น schema สุดท้าย

## ลำดับทำงาน

1. ~~สรุปขอบเขต (SCOPE.md)~~
2. ~~ออกแบบ UX/UI (UX-UI.md)~~
3. ออกแบบ schema ใหม่ + RLS + exclusion constraint แล้วแทน `0001_initial.sql`
4. สร้าง Next.js App Router + TypeScript, ติดตั้ง `@supabase/supabase-js`, `@supabase/ssr`
5. ตั้งค่า Supabase Auth, รัน migration, เพิ่มผู้ใช้ใน `team_members` และห้องใน `rooms`
6. ทำ design tokens + คอมโพเนนต์ UI พื้นฐาน
7. ทำหน้า login, ปฏิทิน, ฟอร์มจอง, รายละเอียด, แจ้งเตือน
8. เพิ่ม manifest ไอคอน และทดสอบบนมือถือก่อนเปิดใช้
