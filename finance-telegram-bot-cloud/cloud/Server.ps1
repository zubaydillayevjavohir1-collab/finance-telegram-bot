param(
  [string]$Token = $env:TELEGRAM_BOT_TOKEN,
  [string]$WebAppUrl = $env:WEB_APP_URL
)

# Server.ps1
# Bitta jarayonda ishlaydigan Cloud-ga moslashtirilgan server:
#  - Telegram bot logikasi (endi "polling" emas, "webhook" orqali)
#  - Mini App uchun statik fayllar (webapp/)
#  - Mini App uchun JSON API (/api/...)
#
# Nega birlashtirdik: Render kabi bepul platformalarda faqat "Web Service"
# (portni tinglaydigan xizmat) bepul, alohida "background worker" jarayoni bepul emas.
# Webhook rejimida bot ham aslida oddiy HTTP so'rovlarga javob beradi, shuning
# uchun bitta Web Service ichida ikkalasi ham ishlayveradi.

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Storage.ps1")

$BaseUrl = if ($Token) { "https://api.telegram.org/bot$Token" } else { "" }
$Script:Offset = 0
$Script:Sessions = @{}


function Send-Message {
  param(
    [string]$ChatId,
    [string]$Text,
    [object]$ReplyMarkup = $null
  )

  $body = @{
    chat_id = $ChatId
    text = $Text
    parse_mode = "HTML"
    disable_web_page_preview = $true
  }

  if ($null -ne $ReplyMarkup) {
    $body.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 8 -Compress)
  }

  Invoke-RestMethod -Method Post -Uri "$BaseUrl/sendMessage" -Body $body | Out-Null
}

function Answer-Callback {
  param([string]$CallbackQueryId, [string]$Text = "")
  $body = @{ callback_query_id = $CallbackQueryId }
  if ($Text) { $body.text = $Text }
  try { Invoke-RestMethod -Method Post -Uri "$BaseUrl/answerCallbackQuery" -Body $body | Out-Null } catch {}
}

function Get-Dashboard {
  param([string]$ChatId)

  $store = Read-Store $ChatId
  $summary = Get-IncomeExpenseSummary $ChatId
  $balance = $summary.totalIncome - $summary.totalExpense
  $activeDebt = Sum-Field (@($store.debts | Where-Object { (Get-ItemValue $_ "status") -ne "closed" }))
  $savingTarget = Sum-Field $store.savings "target"
  $savingCurrent = Sum-Field $store.savings "current"
  $savingProgress = if ($savingTarget -gt 0) { [math]::Round(($savingCurrent / $savingTarget) * 100, 1) } else { 0 }
  $creditLeft = Sum-Field $store.credits "principal"
  $nextCreditPayment = Sum-Field $store.credits "monthlyPayment"
  $cardSummary = Get-CardSummary $ChatId

  $cardWarning = ""
  if ($cardSummary.upcomingDue.Count -gt 0) {
    $names = ($cardSummary.upcomingDue | ForEach-Object { "$($_.bank) $($_.name)" }) -join ", "
    $cardWarning = "`n⚠️ To'lov muddati yaqinlashmoqda: <b>$names</b>"
  }

  @"
<b>Dashboard</b>

Umumiy balans: <b>$(Format-Money $balance)</b>
Bugungi xarajat: <b>$(Format-Money $summary.todayExpense)</b>
Oylik daromad: <b>$(Format-Money $summary.monthIncome)</b>
Oylik xarajat: <b>$(Format-Money $summary.monthExpense)</b>
Aktiv qarzlar: <b>$(Format-Money $activeDebt)</b>
Kredit qoldig'i: <b>$(Format-Money $creditLeft)</b>
Shu oy kredit to'lovi: <b>$(Format-Money $nextCreditPayment)</b>
Jamg'arma progress: <b>$savingProgress%</b>
Kredit karta ishlatilgan: <b>$(Format-Money $cardSummary.totalUsed)</b> / $(Format-Money $cardSummary.totalLimit) (<b>$($cardSummary.utilization)%</b>)$cardWarning
"@
}

function Get-Stats {
  param([string]$ChatId)

  $store = Read-Store $ChatId
  $summary = Get-IncomeExpenseSummary $ChatId
  $debt = Sum-Field $store.debts
  $saving = Sum-Field $store.savings "current"
  $credit = Sum-Field $store.credits "principal"
  $cardUsed = Sum-Field $store.cards "used"

  $topIncomeText = if ($summary.topIncomeSource) { "$($summary.topIncomeSource.category) - $(Format-Money $summary.topIncomeSource.amount)" } else { "-" }
  $topExpenseText = if ($summary.topExpenseCategory) { "$($summary.topExpenseCategory.category) - $(Format-Money $summary.topExpenseCategory.amount)" } else { "-" }
  $changeSign = if ($summary.expenseChangePercent -ge 0) { "+" } else { "" }

  @"
<b>Statistika</b>

Jami daromad: <b>$(Format-Money $summary.totalIncome)</b>
Jami xarajat: <b>$(Format-Money $summary.totalExpense)</b>
Jami qarz: <b>$(Format-Money $debt)</b>
Jami jamg'arma: <b>$(Format-Money $saving)</b>
Jami kredit: <b>$(Format-Money $credit)</b>
Kredit karta ishlatilgan: <b>$(Format-Money $cardUsed)</b>

<b>Daromad</b>
Eng katta manba: $topIncomeText
Oxirgi kirim: $(if ($summary.lastIncome) { Format-Money (Get-ItemValue $summary.lastIncome "amount") } else { "-" })

<b>Xarajat</b>
Haftalik: $(Format-Money $summary.weekExpense)
Eng ko'p ketgan: $topExpenseText
O'tgan oyga nisbatan: $changeSign$($summary.expenseChangePercent)%
"@
}

function Get-Menu {
  @"
<b>My Finance bot</b>

Tanlang:
/dashboard - Dashboard
/income - Daromad qo'shish
/income_list - Daromadlar ro'yxati
/expense - Xarajat qo'shish
/expense_list - Xarajatlar ro'yxati
/debt - Qarz qo'shish
/saving - Jamg'arma qo'shish
/credit - Kredit qo'shish
/card - Kredit karta qo'shish
/card_list - Kartalar ro'yxati, tahrirlash/o'chirish/to'lov
/card_pay - Kartaga to'lov qilish
/stats - Statistika

Jarayonni bekor qilish: /cancel
"@
}

function Send-StartMenu {
  param([string]$ChatId)

  if (-not [string]::IsNullOrWhiteSpace($WebAppUrl)) {
    $markup = @{
      inline_keyboard = @(
        @(
          @{
            text = "My Finance Mini App"
            web_app = @{ url = $WebAppUrl }
          }
        ),
        @(
          @{ text = "Dashboard"; callback_data = "dashboard" },
          @{ text = "Statistika"; callback_data = "stats" }
        )
      )
    }
    Send-Message $ChatId (Get-Menu) $markup
    return
  }

  Send-Message $ChatId ((Get-Menu) + "`n`nMini App tugmasi uchun WEB_APP_URL kerak.")
}

function Start-Flow {
  param(
    [string]$ChatId,
    [string]$Type,
    [array]$Fields
  )

  $Script:Sessions[$ChatId] = @{
    type = $Type
    fields = $Fields
    index = 0
    data = @{}
  }
  Send-Message $ChatId ("<b>{0}</b>`n{1}" -f $Type, $Fields[0].prompt)
}

function Complete-Flow {
  param([string]$ChatId)

  $session = $Script:Sessions[$ChatId]
  $data = $session.data

  switch ($session.type) {
    "Daromad qo'shish" {
      $entry = Add-Entry -ChatId $ChatId -Type "income" -Fields @{
        amount = $data["amount"]; category = $data["category"]; account = $data["account"]
        currency = $data["currency"]; note = $data["note"]
        recurring = ($data["recurring"] -match "^(ha|h|yes|y)$")
      }
      $reply = "Daromad qo'shildi: <b>$(Format-Money $entry.amount)</b> ($($entry.category))"
    }
    "Xarajat qo'shish" {
      $entry = Add-Entry -ChatId $ChatId -Type "expense" -Fields @{
        amount = $data["amount"]; category = $data["category"]; account = $data["account"]
        currency = $data["currency"]; note = $data["note"]
      }
      $reply = "Xarajat qo'shildi: <b>$(Format-Money $entry.amount)</b> ($($entry.category))"
    }
    "Qarz qo'shish" {
      $store = Read-Store $ChatId
      $store.debts += @{
        id = [guid]::NewGuid().ToString()
        name = $data["name"]
        amount = $data["amount"]
        type = $data["type"]
        dueDate = $data["dueDate"]
        note = $data["note"]
        status = "active"
        date = Now-Iso
      }
      Write-Store $ChatId $store
      $reply = "Qarz qo'shildi: <b>$($data['name'])</b> - <b>$(Format-Money $data['amount'])</b>"
    }
    "Jamg'arma qo'shish" {
      $store = Read-Store $ChatId
      $store.savings += @{
        id = [guid]::NewGuid().ToString()
        name = $data["name"]
        target = $data["target"]
        current = $data["current"]
        dueDate = $data["dueDate"]
        note = $data["note"]
        currency = "UZS"
        date = Now-Iso
      }
      Write-Store $ChatId $store
      $reply = "Jamg'arma qo'shildi: <b>$($data['name'])</b>"
    }
    "Kredit qo'shish" {
      $store = Read-Store $ChatId
      $monthly = Get-AnnuitetPayment $data["principal"] $data["annualRate"] $data["months"]
      $total = $monthly * $data["months"]
      $store.credits += @{
        id = [guid]::NewGuid().ToString()
        bank = $data["bank"]
        principal = $data["principal"]
        annualRate = $data["annualRate"]
        months = $data["months"]
        type = "annuitet"
        monthlyPayment = $monthly
        totalPayment = $total
        overpayment = $total - $data["principal"]
        status = "active"
        date = Now-Iso
      }
      Write-Store $ChatId $store
      $reply = @"
Kredit qo'shildi: <b>$($data['bank'])</b>
Oylik to'lov: <b>$(Format-Money $monthly)</b>
Foiz bilan jami: <b>$(Format-Money $total)</b>
Ortiqcha to'lov: <b>$(Format-Money ($total - $data['principal']))</b>
"@
    }
    "Kredit karta qo'shish" {
      $card = Add-Card -ChatId $ChatId -Fields @{
        bank = $data["bank"]; name = $data["name"]; limit = $data["limit"]; used = $data["used"]
        annualRate = $data["annualRate"]; graceDays = $data["graceDays"]; dueDate = $data["dueDate"]
      }
      $reply = @"
Kredit karta qo'shildi: <b>$($card.bank) $($card.name)</b>
Limit: <b>$(Format-Money $card.limit)</b>  Ishlatilgan: <b>$(Format-Money $card.used)</b>
"@
    }
    "Kredit karta to'lovi" {
      $card = Add-CardPayment -ChatId $ChatId -Id $session.cardId -Amount $data["amount"]
      if ($null -eq $card) {
        $reply = "Karta topilmadi, ehtimol allaqachon o'chirilgan."
      } else {
        $reply = @"
To'lov qabul qilindi: <b>$(Format-Money $data['amount'])</b>
$($card.bank) $($card.name) — qolgan qarz: <b>$(Format-Money $card.used)</b>
"@
      }
    }
  }

  $Script:Sessions.Remove($ChatId)
  Send-Message $ChatId $reply
  Send-Message $ChatId (Get-Dashboard $ChatId)
}

function Handle-FlowMessage {
  param(
    [string]$ChatId,
    [string]$Text
  )

  $session = $Script:Sessions[$ChatId]
  $field = $session.fields[$session.index]

  try {
    if ($field.kind -eq "money") {
      $session.data[$field.key] = Parse-Amount $Text
    } elseif ($field.kind -eq "int") {
      $session.data[$field.key] = [int]$Text
    } else {
      $session.data[$field.key] = $Text.Trim()
    }
  } catch {
    Send-Message $ChatId "Qiymat noto'g'ri. Qaytadan kiriting: $($field.prompt)"
    return
  }

  $session.index++
  if ($session.index -ge $session.fields.Count) {
    Complete-Flow $ChatId
    return
  }

  $next = $session.fields[$session.index]
  Send-Message $ChatId $next.prompt
}

function Format-EntryList {
  param([string]$Title, [array]$Entries)

  if ($Entries.Count -eq 0) {
    return "<b>$Title</b>`n`nHali ma'lumot yo'q."
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("<b>$Title</b>`n")
  $shown = @($Entries | Select-Object -First 10)
  foreach ($item in $shown) {
    $date = ([datetime](Get-ItemValue $item "date")).ToString("yyyy-MM-dd")
    $lines.Add("#$($item.id.Substring(0,6))  $(Format-Money $item.amount)  [$($item.category)]  $date")
  }
  $lines.Add("`nO'chirish uchun tugmani bosing.")
  return ($lines -join "`n")
}

function Send-EntryListWithButtons {
  param([string]$ChatId, [string]$Type, [string]$Title)

  $entries = Get-Entries -ChatId $ChatId -Type $Type
  $text = Format-EntryList $Title $entries
  $shown = @($entries | Select-Object -First 10)

  if ($shown.Count -eq 0) {
    Send-Message $ChatId $text
    return
  }

  $prefix = if ($Type -eq "income") { "delinc" } else { "delexp" }
  $rows = @($shown | ForEach-Object {
    @(@{ text = "O'chirish #$($_.id.Substring(0,6))"; callback_data = "$prefix`:$($_.id)" })
  })
  $markup = @{ inline_keyboard = $rows }
  Send-Message $ChatId $text $markup
}

function Format-CardList {
  param([array]$Cards)

  if ($Cards.Count -eq 0) {
    return "<b>Kredit kartalar</b>`n`nHali kredit karta qo'shilmagan. /card orqali qo'shing."
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("<b>Kredit kartalar</b>`n")
  foreach ($card in $Cards) {
    $limit = [decimal](Get-ItemValue $card "limit")
    $used = [decimal](Get-ItemValue $card "used")
    $utilization = if ($limit -gt 0) { [math]::Round(($used / $limit) * 100, 1) } else { 0 }
    $due = Get-ItemValue $card "dueDate"
    $dueText = if ($due) { " | Muddat: $due" } else { "" }
    $lines.Add("#$($card.id.Substring(0,6))  $($card.bank) $($card.name)")
    $lines.Add("   Ishlatilgan: $(Format-Money $used) / $(Format-Money $limit) ($utilization%)$dueText")
  }
  $lines.Add("`nTugmalar orqali to'lov qiling yoki o'chiring.")
  return ($lines -join "`n")
}

function Send-CardListWithButtons {
  param([string]$ChatId)

  $cards = Get-Cards $ChatId
  $text = Format-CardList $cards

  if ($cards.Count -eq 0) {
    Send-Message $ChatId $text
    return
  }

  $rows = @($cards | ForEach-Object {
    @(
      @{ text = "To'lov: $($_.bank) $($_.name)"; callback_data = "paycard:$($_.id)" },
      @{ text = "O'chirish #$($_.id.Substring(0,6))"; callback_data = "delcard:$($_.id)" }
    )
  })
  $markup = @{ inline_keyboard = $rows }
  Send-Message $ChatId $text $markup
}

function Handle-Command {
  param(
    [string]$ChatId,
    [string]$Text
  )

  switch -Regex ($Text) {
    "^/start" { Send-StartMenu $ChatId; break }
    "^/menu" { Send-StartMenu $ChatId; break }
    "^/dashboard" { Send-Message $ChatId (Get-Dashboard $ChatId); break }
    "^/stats" { Send-Message $ChatId (Get-Stats $ChatId); break }
    "^/cancel" {
      if ($Script:Sessions.ContainsKey($ChatId)) { $Script:Sessions.Remove($ChatId) }
      Send-Message $ChatId "Bekor qilindi."
      break
    }
    "^/income_list" { Send-EntryListWithButtons $ChatId "income" "Daromadlar"; break }
    "^/expense_list" { Send-EntryListWithButtons $ChatId "expense" "Xarajatlar"; break }
    "^/income" {
      Start-Flow $ChatId "Daromad qo'shish" @(
        @{ key = "amount"; kind = "money"; prompt = "Summa kiriting. Masalan: 5000000" },
        @{ key = "category"; kind = "text"; prompt = "Kategoriya: $($Script:IncomeCategories -join ', ')" },
        @{ key = "account"; kind = "text"; prompt = "Hisob turi: $($Script:AccountTypes -join ', ')" },
        @{ key = "currency"; kind = "text"; prompt = "Valyuta: $($Script:Currencies -join ', ')" },
        @{ key = "note"; kind = "text"; prompt = "Izoh yozing yoki '-' kiriting." },
        @{ key = "recurring"; kind = "text"; prompt = "Bu takrorlanuvchi daromadmi? (ha / yo'q)" }
      )
      break
    }
    "^/expense" {
      Start-Flow $ChatId "Xarajat qo'shish" @(
        @{ key = "amount"; kind = "money"; prompt = "Summa kiriting. Masalan: 120000" },
        @{ key = "category"; kind = "text"; prompt = "Kategoriya: $($Script:ExpenseCategories -join ', ')" },
        @{ key = "account"; kind = "text"; prompt = "Qaysi hisobdan ketdi: $($Script:AccountTypes -join ', ')" },
        @{ key = "currency"; kind = "text"; prompt = "Valyuta: $($Script:Currencies -join ', ')" },
        @{ key = "note"; kind = "text"; prompt = "Izoh yozing yoki '-' kiriting." }
      )
      break
    }
    "^/debt" {
      Start-Flow $ChatId "Qarz qo'shish" @(
        @{ key = "name"; kind = "text"; prompt = "Ism kiriting." },
        @{ key = "amount"; kind = "money"; prompt = "Qarz summasi." },
        @{ key = "type"; kind = "text"; prompt = "Qarz turi: olingan yoki berilgan." },
        @{ key = "dueDate"; kind = "text"; prompt = "Qaytarish muddati: yyyy-mm-dd yoki '-'." },
        @{ key = "note"; kind = "text"; prompt = "Izoh yozing yoki '-'." }
      )
      break
    }
    "^/saving" {
      Start-Flow $ChatId "Jamg'arma qo'shish" @(
        @{ key = "name"; kind = "text"; prompt = "Jamg'arma nomi. Masalan: Mashina uchun" },
        @{ key = "target"; kind = "money"; prompt = "Maqsad summa." },
        @{ key = "current"; kind = "money"; prompt = "Hozirgi yig'ilgan summa." },
        @{ key = "dueDate"; kind = "text"; prompt = "Muddat: yyyy-mm-dd yoki '-'." },
        @{ key = "note"; kind = "text"; prompt = "Izoh yozing yoki '-'." }
      )
      break
    }
    "^/credit" {
      Start-Flow $ChatId "Kredit qo'shish" @(
        @{ key = "bank"; kind = "text"; prompt = "Bank nomi." },
        @{ key = "principal"; kind = "money"; prompt = "Kredit summasi." },
        @{ key = "annualRate"; kind = "money"; prompt = "Yillik foiz stavkasi. Masalan: 28" },
        @{ key = "months"; kind = "int"; prompt = "Kredit muddati, oyda. Masalan: 36" }
      )
      break
    }
    "^/card_list" { Send-CardListWithButtons $ChatId; break }
    "^/card_pay" {
      $cards = Get-Cards $ChatId
      if ($cards.Count -eq 0) {
        Send-Message $ChatId "Hali kredit karta qo'shilmagan. Avval /card orqali qo'shing."
        break
      }
      $rows = @($cards | ForEach-Object {
        @(@{ text = "$($_.bank) $($_.name) - $(Format-Money $_.used)"; callback_data = "paycard:$($_.id)" })
      })
      Send-Message $ChatId "To'lov qilmoqchi bo'lgan kartani tanlang:" @{ inline_keyboard = $rows }
      break
    }
    "^/card" {
      Start-Flow $ChatId "Kredit karta qo'shish" @(
        @{ key = "bank"; kind = "text"; prompt = "Bank nomi." },
        @{ key = "name"; kind = "text"; prompt = "Karta nomi." },
        @{ key = "limit"; kind = "money"; prompt = "Kredit limiti." },
        @{ key = "used"; kind = "money"; prompt = "Hozir ishlatilgan summa." },
        @{ key = "annualRate"; kind = "money"; prompt = "Yillik foiz stavkasi." },
        @{ key = "graceDays"; kind = "int"; prompt = "Imtiyozli davr, kunlarda. Masalan: 30" },
        @{ key = "dueDate"; kind = "text"; prompt = "Keyingi to'lov muddati: yyyy-mm-dd yoki '-'." }
      )
      break
    }
    default {
      Send-Message $ChatId "Buyruq tushunarsiz. /menu ni bosing."
    }
  }
}

function Handle-Update {
  param([object]$Update)

  if ($null -ne $Update.callback_query) {
    $chatId = [string]$Update.callback_query.message.chat.id
    $data = [string]$Update.callback_query.data
    $cbId = [string]$Update.callback_query.id

    if ($data -eq "dashboard") { Send-Message $chatId (Get-Dashboard $chatId); Answer-Callback $cbId; return }
    if ($data -eq "stats") { Send-Message $chatId (Get-Stats $chatId); Answer-Callback $cbId; return }

    if ($data -like "delinc:*") {
      $id = $data.Substring(7)
      $ok = Remove-Entry -ChatId $chatId -Type "income" -Id $id
      Answer-Callback $cbId (if ($ok) { "O'chirildi" } else { "Topilmadi" })
      if ($ok) { Send-EntryListWithButtons $chatId "income" "Daromadlar" }
      return
    }
    if ($data -like "delexp:*") {
      $id = $data.Substring(7)
      $ok = Remove-Entry -ChatId $chatId -Type "expense" -Id $id
      Answer-Callback $cbId (if ($ok) { "O'chirildi" } else { "Topilmadi" })
      if ($ok) { Send-EntryListWithButtons $chatId "expense" "Xarajatlar" }
      return
    }
    if ($data -like "delcard:*") {
      $id = $data.Substring(8)
      $ok = Remove-Card -ChatId $chatId -Id $id
      Answer-Callback $cbId (if ($ok) { "O'chirildi" } else { "Topilmadi" })
      if ($ok) { Send-CardListWithButtons $chatId }
      return
    }
    if ($data -like "paycard:*") {
      $id = $data.Substring(8)
      Start-Flow $chatId "Kredit karta to'lovi" @(
        @{ key = "amount"; kind = "money"; prompt = "To'lov summasini kiriting." }
      )
      $Script:Sessions[$chatId].cardId = $id
      Answer-Callback $cbId
      return
    }
    Answer-Callback $cbId
    return
  }

  if ($null -eq $Update.message) { return }

  $message = $Update.message
  if ($null -eq $message.text) { return }

  $chatId = [string]$message.chat.id
  $text = [string]$message.text

  if ($text.StartsWith("/")) {
    Handle-Command $chatId $text
    return
  }

  if ($Script:Sessions.ContainsKey($chatId)) {
    Handle-FlowMessage $chatId $text
    return
  }

  Send-Message $chatId "Boshlash uchun /menu ni bosing."
}


# ---------------------------------------------------------------------------
# HTTP server: static (webapp/) + API (/api/...) + Telegram webhook
# ---------------------------------------------------------------------------

$webRoot = Join-Path $PSScriptRoot "webapp"
if (-not (Test-Path -LiteralPath $webRoot)) {
  Write-Host "webapp papkasi topilmadi."
  exit 1
}
$resolvedRoot = (Resolve-Path -LiteralPath $webRoot).Path

function Get-ContentType {
  param([string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { "text/html; charset=utf-8" }
    ".css" { "text/css; charset=utf-8" }
    ".js" { "application/javascript; charset=utf-8" }
    ".png" { "image/png" }
    ".jpg" { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    ".svg" { "image/svg+xml" }
    default { "application/octet-stream" }
  }
}

function Write-Bytes {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [byte[]]$Body,
    [string]$ContentType = "text/plain; charset=utf-8"
  )
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentLength64 = $Body.Length
  if ($Body.Length -gt 0) {
    $Response.OutputStream.Write($Body, 0, $Body.Length)
  }
  $Response.OutputStream.Close()
}

function Write-Json {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [object]$Data
  )
  $json = $Data | ConvertTo-Json -Depth 10 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  Write-Bytes -Response $Response -StatusCode $StatusCode -Body $bytes -ContentType "application/json; charset=utf-8"
}

function Read-Body {
  param([System.Net.HttpListenerRequest]$Request)
  $reader = New-Object IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
  $text = $reader.ReadToEnd()
  $reader.Close()
  return $text
}

function Read-JsonBody {
  param([System.Net.HttpListenerRequest]$Request)
  $text = Read-Body $Request
  if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
  $obj = $text | ConvertFrom-Json
  $result = @{}
  foreach ($p in $obj.PSObject.Properties) { $result[$p.Name] = $p.Value }
  return $result
}

function Handle-Api {
  param([System.Net.HttpListenerContext]$Context)

  $request = $Context.Request
  $response = $Context.Response
  $path = $request.Url.AbsolutePath
  $method = $request.HttpMethod
  $query = $request.QueryString

  try {
    if ($path -eq "/api/meta" -and $method -eq "GET") {
      Write-Json $response 200 (Get-Meta)
      return
    }

    if ($path -eq "/api/entries" -and $method -eq "GET") {
      $userId = $query["userId"]
      $type = $query["type"]
      if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($type)) {
        Write-Json $response 400 @{ error = "userId va type kerak" }
        return
      }
      $entries = Get-Entries -ChatId $userId -Type $type -Search $query["search"] -From $query["from"] -To $query["to"]
      Write-Json $response 200 @{ entries = $entries }
      return
    }

    if ($path -eq "/api/entries" -and $method -eq "POST") {
      $body = Read-JsonBody $request
      $userId = [string]$body["userId"]
      $type = [string]$body["type"]
      if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($type)) {
        Write-Json $response 400 @{ error = "userId va type kerak" }
        return
      }
      $entry = Add-Entry -ChatId $userId -Type $type -Fields $body
      Write-Json $response 200 @{ entry = $entry }
      return
    }

    if ($path -like "/api/entries/*" -and $method -eq "PUT") {
      $id = $path.Substring("/api/entries/".Length)
      $body = Read-JsonBody $request
      $userId = [string]$body["userId"]
      $type = [string]$body["type"]
      if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($type)) {
        Write-Json $response 400 @{ error = "userId va type kerak" }
        return
      }
      $updated = Update-Entry -ChatId $userId -Type $type -Id $id -Fields $body
      if ($null -eq $updated) {
        Write-Json $response 404 @{ error = "Topilmadi" }
        return
      }
      Write-Json $response 200 @{ entry = $updated }
      return
    }

    if ($path -like "/api/entries/*" -and $method -eq "DELETE") {
      $id = $path.Substring("/api/entries/".Length)
      $userId = $query["userId"]
      $type = $query["type"]
      if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($type)) {
        Write-Json $response 400 @{ error = "userId va type kerak" }
        return
      }
      $ok = Remove-Entry -ChatId $userId -Type $type -Id $id
      Write-Json $response 200 @{ deleted = $ok }
      return
    }

    if ($path -eq "/api/cards" -and $method -eq "GET") {
      $userId = $query["userId"]
      if ([string]::IsNullOrWhiteSpace($userId)) {
        Write-Json $response 400 @{ error = "userId kerak" }
        return
      }
      Write-Json $response 200 @{ cards = (Get-Cards $userId); summary = (Get-CardSummary $userId) }
      return
    }

    if ($path -eq "/api/cards" -and $method -eq "POST") {
      $body = Read-JsonBody $request
      $userId = [string]$body["userId"]
      if ([string]::IsNullOrWhiteSpace($userId)) {
        Write-Json $response 400 @{ error = "userId kerak" }
        return
      }
      $card = Add-Card -ChatId $userId -Fields $body
      Write-Json $response 200 @{ card = $card }
      return
    }

    if ($path -like "/api/cards/*/payment" -and $method -eq "POST") {
      $id = $path.Substring("/api/cards/".Length).Replace("/payment", "")
      $body = Read-JsonBody $request
      $userId = [string]$body["userId"]
      if ([string]::IsNullOrWhiteSpace($userId) -or -not $body.ContainsKey("amount")) {
        Write-Json $response 400 @{ error = "userId va amount kerak" }
        return
      }
      $card = Add-CardPayment -ChatId $userId -Id $id -Amount ([decimal]$body["amount"])
      if ($null -eq $card) {
        Write-Json $response 404 @{ error = "Topilmadi" }
        return
      }
      Write-Json $response 200 @{ card = $card }
      return
    }

    if ($path -like "/api/cards/*" -and $method -eq "PUT") {
      $id = $path.Substring("/api/cards/".Length)
      $body = Read-JsonBody $request
      $userId = [string]$body["userId"]
      if ([string]::IsNullOrWhiteSpace($userId)) {
        Write-Json $response 400 @{ error = "userId kerak" }
        return
      }
      $updated = Update-Card -ChatId $userId -Id $id -Fields $body
      if ($null -eq $updated) {
        Write-Json $response 404 @{ error = "Topilmadi" }
        return
      }
      Write-Json $response 200 @{ card = $updated }
      return
    }

    if ($path -like "/api/cards/*" -and $method -eq "DELETE") {
      $id = $path.Substring("/api/cards/".Length)
      $userId = $query["userId"]
      if ([string]::IsNullOrWhiteSpace($userId)) {
        Write-Json $response 400 @{ error = "userId kerak" }
        return
      }
      $ok = Remove-Card -ChatId $userId -Id $id
      Write-Json $response 200 @{ deleted = $ok }
      return
    }

    if ($path -eq "/api/summary" -and $method -eq "GET") {
      $userId = $query["userId"]
      if ([string]::IsNullOrWhiteSpace($userId)) {
        Write-Json $response 400 @{ error = "userId kerak" }
        return
      }
      Write-Json $response 200 (Get-IncomeExpenseSummary $userId)
      return
    }

    Write-Json $response 404 @{ error = "Bunday API yo'q" }
  } catch {
    Write-Json $response 500 @{ error = $_.Exception.Message }
  }
}

function Handle-Static {
  param([System.Net.HttpListenerContext]$Context)

  $request = $Context.Request
  $response = $Context.Response
  $path = $request.Url.AbsolutePath.TrimStart("/")
  if ([string]::IsNullOrWhiteSpace($path)) { $path = "index.html" }

  $file = Join-Path $resolvedRoot $path
  $resolvedFile = if (Test-Path -LiteralPath $file -PathType Leaf) { (Resolve-Path -LiteralPath $file).Path } else { "" }

  if ($resolvedFile -and $resolvedFile.StartsWith($resolvedRoot)) {
    $bytes = [IO.File]::ReadAllBytes($resolvedFile)
    Write-Bytes -Response $response -StatusCode 200 -Body $bytes -ContentType (Get-ContentType $resolvedFile)
  } else {
    $bytes = [Text.Encoding]::UTF8.GetBytes("Not found")
    Write-Bytes -Response $response -StatusCode 404 -Body $bytes
  }
}

function Handle-Webhook {
  param([System.Net.HttpListenerContext]$Context)

  $request = $Context.Request
  $response = $Context.Response

  try {
    $text = Read-Body $request
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $update = $text | ConvertFrom-Json
      Handle-Update $update
    }
    Write-Json $response 200 @{ ok = $true }
  } catch {
    Write-Host "Webhook xatolik: $($_.Exception.Message)"
    Write-Json $response 200 @{ ok = $true }
  }
}

if ([string]::IsNullOrWhiteSpace($Token)) {
  Write-Host "OGOHLANTIRISH: TELEGRAM_BOT_TOKEN topilmadi. Faqat Mini App/API ishlaydi, bot ishlamaydi."
}

# Webhook manzili token bilan "xufyona" qilinadi - shu URL'ni bilmagan odam
# soxta update yubora olmaydi. Masalan: https://sizning-app.onrender.com/webhook/<TOKEN>
$Script:WebhookPath = if ($Token) { "/webhook/$Token" } else { "" }

$Port = if ($env:PORT) { [int]$env:PORT } else { 8080 }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()

Write-Host "My Finance server ishga tushdi: port $Port"
if ($Script:WebhookPath) {
  Write-Host "Telegram webhook yo'li: $($Script:WebhookPath)"
}
Write-Host "To'xtatish: Ctrl+C"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $path = $context.Request.Url.AbsolutePath
      if ($Script:WebhookPath -and $path -eq $Script:WebhookPath -and $context.Request.HttpMethod -eq "POST") {
        Handle-Webhook $context
      } elseif ($path.StartsWith("/api/")) {
        Handle-Api $context
      } else {
        Handle-Static $context
      }
    } catch {
      try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("Server error: $($_.Exception.Message)")
        Write-Bytes -Response $context.Response -StatusCode 500 -Body $bytes
      } catch {}
    }
  }
} finally {
  $listener.Stop()
}
