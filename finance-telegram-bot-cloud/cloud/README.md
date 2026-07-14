# My Finance Telegram Bot

> **Cloudga (Render, bepul) joylashtirish uchun `CLOUD-DEPLOY.md` faylini
> o'qing.** U yerda `Server.ps1` (webhook + API bitta jarayonda) va Upstash
> Redis orqali ma'lumotlarni yo'qotmasdan saqlash yo'riqnomasi bor.
> Quyidagi bo'lim faqat **mahalliy kompyuterda** ishga tushirish uchun.

PPTX reja asosida tayyorlangan Telegram finance bot. Hozircha **Daromad va Xarajat**
bo'limi to'liq ishlaydi hamda bot bilan Mini App bir xil ma'lumotni ko'radi.

## Nima o'zgardi (muhim)

Avvalgi versiyada bot (PowerShell) ma'lumotlarni `data/<chat_id>.json` fayllarga yozar edi,
Mini App esa brauzerning **localStorage**'iga yozar edi — ikkalasi umuman bog'lanmagan edi.
Shu sababli botda qo'shgan daromad/xarajat Mini App'da ko'rinmas, aksincha ham shunday edi.

Endi:

- `Storage.ps1` — bot va server ikkalasi ham shu fayldagi bir xil funksiyalardan foydalanadi.
- `Start-LocalWebApp.ps1` endi shunchaki statik fayl serveri emas — u `data/` papkadagi
  bir xil JSON fayllar ustida ishlaydigan **JSON API** ham beradi (`/api/...`).
- `webapp/app.js` endi localStorage o'rniga shu API bilan gaplashadi, foydalanuvchini
  Telegram orqali (`initDataUnsafe.user.id`) aniqlaydi — bu bot ishlatadigan `chat_id`
  bilan bir xil (shaxsiy chatda `chat_id === user_id`).
- Daromad/Xarajat uchun: kategoriya/hisob turi/valyuta tanlash, sana, tahrirlash,
  o'chirish, qidiruv va sana bo'yicha filtr qo'shildi.
- Qarz, Jamg'arma, Kredit karta, Kredit kalkulyatori bo'limlari **hozircha eskicha**,
  faqat shu qurilmadagi localStorage'da qoladi — bu bo'limlarni ham serverga
  ko'chirish keyingi bosqichda qilinadi.

## Ishga tushirish

1. Telegramda `@BotFather` orqali bot yarating, tokenni oling.
2. Bitta kompyuterda **ikkita** PowerShell oynasi kerak bo'ladi — ikkalasi ham
   doim ishlab turishi shart:

   **1-oyna — server (Mini App + API):**
   ```powershell
   cd "papka\finance-telegram-bot"
   powershell -ExecutionPolicy Bypass -File .\Start-LocalWebApp.ps1 -Port 8080
   ```

   **2-oyna — bot:**
   ```powershell
   cd "papka\finance-telegram-bot"
   $env:TELEGRAM_BOT_TOKEN="BOTFATHER_TOKENINGIZ"
   $env:WEB_APP_URL="https://sizning-cloudflare-domeningiz"
   powershell -ExecutionPolicy Bypass -File .\Start-Bot.ps1
   ```

3. Agar cloudflared tunnel ishlatayotgan bo'lsangiz, tunnel albatta 1-oynadagi
   **bir xil portga** (masalan 8080) ishora qilishi kerak:
   ```powershell
   cloudflared tunnel --url http://127.0.0.1:8080
   ```
   Chiqqan `https://....trycloudflare.com` manzilni `WEB_APP_URL` sifatida
   botga bering.

   Diqqat: har safar cloudflared qayta ishga tushirilganda **yangi** manzil
   beriladi (bepul "quick tunnel" shunday ishlaydi). Doimiy manzil kerak bo'lsa,
   Cloudflare'da nomlangan tunnel yarating yoki Railway/Render kabi doimiy
   hostingga o'ting.

4. Botda `/start` bosing → **My Finance Mini App** tugmasi ochiladi. Endi shu
   yerda qo'shgan daromad/xarajat bot buyruqlaridan (`/income`, `/expense`,
   `/dashboard`, `/stats`) ham ko'rinadi va aksincha.

Token kiritmasdan ichki tekshiruv:
```powershell
powershell -ExecutionPolicy Bypass -File .\Start-Bot.ps1 -SelfTest
```

## Buyruqlar

- `/start`, `/menu` - asosiy menyu va Mini App tugmasi
- `/dashboard` - moliyaviy holat
- `/income` - daromad qo'shish (summa, kategoriya, hisob turi, valyuta, izoh, takrorlanuvchimi)
- `/income_list` - so'nggi daromadlar va o'chirish tugmalari
- `/expense` - xarajat qo'shish (summa, kategoriya, hisob turi, valyuta, izoh)
- `/expense_list` - so'nggi xarajatlar va o'chirish tugmalari
- `/debt` - qarz qo'shish
- `/saving` - jamg'arma qo'shish
- `/credit` - kredit qo'shish va annuitet hisoblash
- `/card` - kredit karta qo'shish
- `/stats` - statistika
- `/cancel` - jarayonni bekor qilish

Eslatma: daromad/xarajatni **tahrirlash** hozircha faqat Mini App orqali qilinadi
(ro'yxatdagi "Tahrirlash" tugmasi) — botda esa faqat qo'shish va o'chirish bor.

## API (Mini App ishlatadi, lekin boshqa integratsiyalar uchun ham foydali)

- `GET /api/meta` - kategoriya/hisob turi/valyuta ro'yxatlari
- `GET /api/entries?userId=&type=income|expense&search=&from=&to=` - ro'yxat
- `POST /api/entries` - yangi yozuv qo'shish
- `PUT /api/entries/{id}` - tahrirlash
- `DELETE /api/entries/{id}?userId=&type=` - o'chirish
- `GET /api/summary?userId=` - oylik/haftalik/bugungi statistika

## Keyingi bosqich

- Qarz, Jamg'arma, Kredit karta bo'limlarini ham shu API'ga ko'chirish
  (hozir faqat shu qurilmada saqlanadi).
- Takrorlanuvchi daromadni avtomatik yaratish uchun rejalashtiruvchi (scheduler).
- Eslatmalar (kredit to'lovi, qarz muddati, karta imtiyozli davri).
- Grafiklar va PDF/Excel hisobotlar.
- Doimiy hosting (Railway/Render) — hozirgi PowerShell + cloudflared quick tunnel
  faqat kompyuteringiz yoqilganda ishlaydi va manzil har safar o'zgaradi.
