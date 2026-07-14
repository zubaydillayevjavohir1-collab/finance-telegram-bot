# Cloudga joylashtirish (Render, bepul)

Bu versiyada nima o'zgardi:

- **Bot endi "webhook" rejimida ishlaydi** (avvalgi "polling" o'rniga). Bot va
  Mini App/API bitta `Server.ps1` faylida, bitta portda ishlaydi.
- **Ma'lumotlar Upstash Redis'da saqlanadi** (mahalliy `data/*.json` fayllar
  o'rniga), chunki Render'ning bepul tarifida disk vaqtinchalik — har safar
  qayta ishga tushganda fayllar o'chib ketadi. Redis esa doimiy qoladi.
- Docker orqali ishga tushadi (`Dockerfile`), chunki Render PowerShell'ni
  o'zi tanimaydi.

**Muhim cheklov:** Render'ning bepul "Web Service"i 15 daqiqa so'rovsiz
turgandan keyin uxlab qoladi va keyingi so'rovga 30-60 soniya kech javob
beradi. Shaxsiy foydalanish uchun (kamdan-kam foydalanuvchi) bu odatda muammo
emas — Telegram xabaringizni yo'qotmaydi, faqat birinchi javob biroz
kechikishi mumkin. Agar bu qabul qilinmasa, Render'ning $7/oy "Starter"
tarifiga o'tsangiz, uyqu muammosi butunlay yo'qoladi.

## 1-qadam: Upstash Redis (bepul, ~2 daqiqa)

1. https://upstash.com ga kiring, ro'yxatdan o'ting (GitHub bilan bo'ladi).
2. **Create Database** → nom bering (masalan `finance-bot`) → eng yaqin
   regionni tanlang → yarating.
3. Database sahifasida **REST API** bo'limiga o'ting, ikkita qiymatni
   nusxalab oling:
   - `UPSTASH_REDIS_REST_URL`
   - `UPSTASH_REDIS_REST_TOKEN`

## 2-qadam: Telegram bot tokeni

Agar hali yo'q bo'lsa: Telegramda `@BotFather` → `/newbot` → tokenni oling.

## 3-qadam: Kodni GitHub'ga joylang

Render GitHub repodan deploy qiladi. Shu papkani (Server.ps1, Storage.ps1,
Dockerfile, webapp/ va h.k.) yangi GitHub repo qilib yuklang.

## 4-qadam: Render'da servis yarating

1. https://render.com → **New** → **Web Service**.
2. GitHub repongizni tanlang.
3. **Runtime**: Docker (Dockerfile avtomatik topiladi).
4. **Instance Type**: Free.
5. **Environment** bo'limida quyidagi o'zgaruvchilarni qo'shing:
   - `TELEGRAM_BOT_TOKEN` = BotFather tokeningiz
   - `UPSTASH_REDIS_REST_URL` = 1-qadamdagi qiymat
   - `UPSTASH_REDIS_REST_TOKEN` = 1-qadamdagi qiymat
   - `WEB_APP_URL` = hozircha bo'sh qoldiring (keyingi qadamda to'ldiramiz)
6. **Create Web Service** bosing. Deploy tugagach, Render sizga manzil beradi,
   masalan: `https://my-finance-bot.onrender.com`

## 5-qadam: WEB_APP_URL ni to'ldiring

Render'dagi Environment sozlamalariga qaytib, `WEB_APP_URL` ga xuddi shu
manzilni yozing: `https://my-finance-bot.onrender.com`. Saqlang — servis
avtomatik qayta deploy bo'ladi.

## 6-qadam: Telegram webhookni ulash

O'z kompyuteringizda (yoki brauzerda) quyidagi manzilga bir marta kiring —
`<TOKEN>` o'rniga o'z tokeningizni qo'ying ikkala joyda ham:

```
https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://my-finance-bot.onrender.com/webhook/<TOKEN>
```

Muvaffaqiyatli bo'lsa, `{"ok":true,"result":true,...}` javobini ko'rasiz.

## 7-qadam: Tekshirish

Telegramda botingizga `/start` yozing. **My Finance Mini App** tugmasi
Render manzilingizga ochilishi kerak, `/dashboard`, `/income` va boshqa
buyruqlar ishlashi kerak.

## Muhim eslatmalar

- Har safar `TELEGRAM_BOT_TOKEN` ni o'zgartirsangiz, 6-qadamni qayta bajaring
  (yangi webhook o'rnating).
- Webhookni o'chirish kerak bo'lsa:
  `https://api.telegram.org/bot<TOKEN>/deleteWebhook`
- Ma'lumotlaringizni istalgan vaqt Upstash konsolida (Data Browser) ko'rishingiz
  mumkin — har bir foydalanuvchi `store:<chat_id>` nomli kalitda saqlanadi.
- Qarz/Jamg'arma/Kredit/Karta bo'limlari hozircha faqat botda ishlaydi (Mini
  App'da localStorage'da qoladi) — bu asl loyihaning o'zidan qolgan holat,
  cloud migratsiyasi bilan bog'liq emas.
