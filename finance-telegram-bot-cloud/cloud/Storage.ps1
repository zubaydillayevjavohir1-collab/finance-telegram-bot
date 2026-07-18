# Storage.ps1
# Bot va server uchun umumiy funksiyalar.
#
# ICHKI SAQLASH REJIMI (2 xil bo'lishi mumkin):
#  1) Redis (Upstash) - UPSTASH_REDIS_REST_URL va UPSTASH_REDIS_REST_TOKEN
#     env o'zgaruvchilari mavjud bo'lsa ishlatiladi. Bu Cloud (masalan Render)
#     uchun tavsiya etiladi, chunki u yerda disk vaqtinchalik bo'ladi - har safar
#     qayta ishga tushganda mahalliy fayllar o'chib ketadi, Redis esa doimiy saqlaydi.
#  2) Mahalliy JSON fayl (data/<chat_id>.json) - Redis sozlanmagan bo'lsa,
#     masalan kompyuteringizda test qilayotganda ishlatiladi.

$Script:UseRedis = -not [string]::IsNullOrWhiteSpace($env:UPSTASH_REDIS_REST_URL) -and
                   -not [string]::IsNullOrWhiteSpace($env:UPSTASH_REDIS_REST_TOKEN)

if (-not $Script:UseRedis) {
  $Script:DataDir = Join-Path $PSScriptRoot "data"
  if (-not (Test-Path -LiteralPath $Script:DataDir)) {
    New-Item -ItemType Directory -Path $Script:DataDir | Out-Null
  }
}

function Invoke-UpstashCommand {
  param([array]$Command)

  $body = $Command | ConvertTo-Json -Compress
  $headers = @{ Authorization = "Bearer $($env:UPSTASH_REDIS_REST_TOKEN)" }
  $resp = Invoke-RestMethod -Method Post -Uri $env:UPSTASH_REDIS_REST_URL -Headers $headers -ContentType "application/json" -Body $body
  if ($resp.PSObject.Properties["error"]) {
    throw "Upstash xatolik: $($resp.error)"
  }
  return $resp.result
}

# ---- Kategoriya / hisob turi / valyuta ro'yxatlari (reja asosida) ----

$Script:IncomeCategories = @(
  "Ish haqi", "Bonus", "Biznes", "Freelance", "Savdo",
  "Cashback", "Investitsiya", "Sovg'a", "Boshqa"
)

$Script:ExpenseCategories = @(
  "Ovqat", "Transport", "Kommunal", "Internet va aloqa", "O'yin-kulgi",
  "Sog'liq", "Oila", "Ta'lim", "Kiyim", "Kredit to'lovi",
  "Qarz qaytarish", "Sayohat", "Soliq", "Boshqa"
)

$Script:AccountTypes = @("Naqd pul", "Uzcard", "Humo", "Visa", "Kredit karta", "Valyuta hisobi")

$Script:Currencies = @("UZS", "USD", "EUR")

function Get-Meta {
  @{
    incomeCategories = $Script:IncomeCategories
    expenseCategories = $Script:ExpenseCategories
    accounts = $Script:AccountTypes
    currencies = $Script:Currencies
  }
}

# ---- Fayl bilan ishlash ----

function Get-UserFile {
  param([string]$ChatId)
  Join-Path $Script:DataDir "$ChatId.json"
}

function New-Store {
  @{
    incomes = @()
    expenses = @()
    debts = @()
    savings = @()
    credits = @()
    cards = @()
  }
}

function Read-Store {
  param([string]$ChatId)

  if ($Script:UseRedis) {
    $json = Invoke-UpstashCommand @("GET", "store:$ChatId")
  } else {
    $file = Get-UserFile $ChatId
    $json = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw } else { $null }
  }

  if ([string]::IsNullOrWhiteSpace($json)) {
    return New-Store
  }

  $raw = $json | ConvertFrom-Json
  $store = New-Store
  foreach ($key in @($store.Keys).Clone()) {
    $property = $raw.PSObject.Properties[$key]
    if ($null -ne $property -and $null -ne $property.Value) {
      $store[$key] = @($property.Value)
    }
  }
  return $store
}

function Write-Store {
  param(
    [string]$ChatId,
    [hashtable]$Store
  )

  $json = $Store | ConvertTo-Json -Depth 8 -Compress

  if ($Script:UseRedis) {
    Invoke-UpstashCommand @("SET", "store:$ChatId", $json) | Out-Null
  } else {
    Set-Content -LiteralPath (Get-UserFile $ChatId) -Value $json -Encoding UTF8
  }
}

# ---- Yordamchi funksiyalar ----

function Format-Money {
  param([decimal]$Amount)
  "{0:N0} so'm" -f $Amount
}

function Parse-Amount {
  param([string]$Text)
  $clean = ($Text -replace "[^\d\.,-]", "") -replace ",", "."
  if ([string]::IsNullOrWhiteSpace($clean)) {
    throw "Summa raqam bo'lishi kerak."
  }
  return [decimal]::Parse($clean, [Globalization.CultureInfo]::InvariantCulture)
}

function Now-Iso {
  (Get-Date).ToString("o")
}

function Get-ItemValue {
  param(
    [object]$Item,
    [string]$Field
  )

  if ($null -eq $Item) { return $null }
  if ($Item -is [hashtable]) {
    if ($Item.ContainsKey($Field)) { return $Item[$Field] }
    return $null
  }

  $property = $Item.PSObject.Properties[$Field]
  if ($null -ne $property) { return $property.Value }
  return $null
}

function Get-MonthItems {
  param([array]$Items)
  $now = Get-Date
  @($Items | Where-Object {
    $dateValue = Get-ItemValue $_ "date"
    $dateValue -and ([datetime]$dateValue).Year -eq $now.Year -and ([datetime]$dateValue).Month -eq $now.Month
  })
}

function Get-LastMonthItems {
  param([array]$Items)
  $ref = (Get-Date).AddMonths(-1)
  @($Items | Where-Object {
    $dateValue = Get-ItemValue $_ "date"
    $dateValue -and ([datetime]$dateValue).Year -eq $ref.Year -and ([datetime]$dateValue).Month -eq $ref.Month
  })
}

function Get-WeekItems {
  param([array]$Items)
  $from = (Get-Date).Date.AddDays(-6)
  @($Items | Where-Object {
    $dateValue = Get-ItemValue $_ "date"
    $dateValue -and ([datetime]$dateValue).Date -ge $from
  })
}

function Sum-Field {
  param(
    [array]$Items,
    [string]$Field = "amount"
  )
  $sum = [decimal]0
  foreach ($item in @($Items)) {
    $value = Get-ItemValue $item $Field
    if ($null -ne $value) {
      $sum += [decimal]$value
    }
  }
  return $sum
}

function Get-TopCategory {
  param([array]$Items)
  $groups = @($Items) | Group-Object { Get-ItemValue $_ "category" } | Sort-Object { Sum-Field $_.Group } -Descending
  if ($groups.Count -eq 0) { return $null }
  $top = $groups[0]
  @{ category = $top.Name; amount = (Sum-Field $top.Group) }
}

function Get-AnnuitetPayment {
  param(
    [decimal]$Principal,
    [decimal]$AnnualRate,
    [int]$Months
  )

  if ($Months -le 0) { return [decimal]0 }
  $monthlyRate = ($AnnualRate / 100) / 12
  if ($monthlyRate -eq 0) {
    return [math]::Round($Principal / $Months, 2)
  }
  $payment = $Principal * ($monthlyRate * [math]::Pow(1 + $monthlyRate, $Months)) / ([math]::Pow(1 + $monthlyRate, $Months) - 1)
  return [math]::Round($payment, 2)
}

# ---- Daromad / Xarajat uchun umumiy CRUD (bot va API bir xil funksiyadan foydalanadi) ----

function Get-EntryArrayName {
  param([string]$Type)
  if ($Type -eq "income") { return "incomes" }
  if ($Type -eq "expense") { return "expenses" }
  throw "Noma'lum turi: $Type"
}

function Add-Entry {
  param(
    [string]$ChatId,
    [string]$Type,
    [hashtable]$Fields
  )

  $store = Read-Store $ChatId
  $arrayName = Get-EntryArrayName $Type

  $entry = @{
    id = [guid]::NewGuid().ToString()
    type = $Type
    amount = [decimal]$Fields["amount"]
    category = [string]$Fields["category"]
    account = [string]$Fields["account"]
    currency = ([string]$Fields["currency"])
    note = [string]$Fields["note"]
    recurring = [bool]($Fields["recurring"])
    date = if ($Fields["date"]) { [string]$Fields["date"] } else { Now-Iso }
  }
  if ([string]::IsNullOrWhiteSpace($entry.currency)) { $entry.currency = "UZS" }

  $store[$arrayName] = @($store[$arrayName]) + $entry
  Write-Store $ChatId $store
  return $entry
}

function Update-Entry {
  param(
    [string]$ChatId,
    [string]$Type,
    [string]$Id,
    [hashtable]$Fields
  )

  $store = Read-Store $ChatId
  $arrayName = Get-EntryArrayName $Type
  $items = @($store[$arrayName])
  $index = -1
  for ($i = 0; $i -lt $items.Count; $i++) {
    if ((Get-ItemValue $items[$i] "id") -eq $Id) { $index = $i; break }
  }
  if ($index -eq -1) { return $null }

  $existing = $items[$index]
  $updated = @{
    id = $Id
    type = $Type
    amount = if ($Fields.ContainsKey("amount")) { [decimal]$Fields["amount"] } else { [decimal](Get-ItemValue $existing "amount") }
    category = if ($Fields.ContainsKey("category")) { [string]$Fields["category"] } else { Get-ItemValue $existing "category" }
    account = if ($Fields.ContainsKey("account")) { [string]$Fields["account"] } else { Get-ItemValue $existing "account" }
    currency = if ($Fields.ContainsKey("currency")) { [string]$Fields["currency"] } else { Get-ItemValue $existing "currency" }
    note = if ($Fields.ContainsKey("note")) { [string]$Fields["note"] } else { Get-ItemValue $existing "note" }
    recurring = if ($Fields.ContainsKey("recurring")) { [bool]$Fields["recurring"] } else { Get-ItemValue $existing "recurring" }
    date = if ($Fields.ContainsKey("date")) { [string]$Fields["date"] } else { Get-ItemValue $existing "date" }
  }

  $items[$index] = $updated
  $store[$arrayName] = $items
  Write-Store $ChatId $store
  return $updated
}

function Remove-Entry {
  param(
    [string]$ChatId,
    [string]$Type,
    [string]$Id
  )

  $store = Read-Store $ChatId
  $arrayName = Get-EntryArrayName $Type
  $before = @($store[$arrayName]).Count
  $store[$arrayName] = @(@($store[$arrayName]) | Where-Object { (Get-ItemValue $_ "id") -ne $Id })
  $after = @($store[$arrayName]).Count
  Write-Store $ChatId $store
  return ($after -lt $before)
}

function Get-Entries {
  param(
    [string]$ChatId,
    [string]$Type,
    [string]$Search = "",
    [string]$From = "",
    [string]$To = ""
  )

  $store = Read-Store $ChatId
  $arrayName = Get-EntryArrayName $Type
  $items = @($store[$arrayName])

  if (-not [string]::IsNullOrWhiteSpace($Search)) {
    $needle = $Search.ToLowerInvariant()
    $items = @($items | Where-Object {
      $cat = [string](Get-ItemValue $_ "category")
      $note = [string](Get-ItemValue $_ "note")
      $acc = [string](Get-ItemValue $_ "account")
      ($cat.ToLowerInvariant().Contains($needle)) -or ($note.ToLowerInvariant().Contains($needle)) -or ($acc.ToLowerInvariant().Contains($needle))
    })
  }

  if (-not [string]::IsNullOrWhiteSpace($From)) {
    $fromDate = [datetime]$From
    $items = @($items | Where-Object { ([datetime](Get-ItemValue $_ "date")).Date -ge $fromDate.Date })
  }

  if (-not [string]::IsNullOrWhiteSpace($To)) {
    $toDate = [datetime]$To
    $items = @($items | Where-Object { ([datetime](Get-ItemValue $_ "date")).Date -le $toDate.Date })
  }

  return @($items | Sort-Object { [datetime](Get-ItemValue $_ "date") } -Descending)
}

function Get-IncomeExpenseSummary {
  param([string]$ChatId)

  $store = Read-Store $ChatId
  $incomes = @($store.incomes)
  $expenses = @($store.expenses)

  $monthIncome = Sum-Field (Get-MonthItems $incomes)
  $monthExpense = Sum-Field (Get-MonthItems $expenses)
  $lastMonthExpense = Sum-Field (Get-LastMonthItems $expenses)
  $today = (Get-Date).Date
  $todayExpense = Sum-Field (@($expenses | Where-Object { (Get-ItemValue $_ "date") -and ([datetime](Get-ItemValue $_ "date")).Date -eq $today }))
  $weekExpense = Sum-Field (Get-WeekItems $expenses)

  $topIncomeSource = Get-TopCategory $incomes
  $topExpenseCategory = Get-TopCategory $expenses

  $lastIncome = $null
  if ($incomes.Count -gt 0) {
    $lastIncome = ($incomes | Sort-Object { [datetime](Get-ItemValue $_ "date") } -Descending)[0]
  }

  $expenseChangePercent = 0
  if ($lastMonthExpense -gt 0) {
    $expenseChangePercent = [math]::Round((($monthExpense - $lastMonthExpense) / $lastMonthExpense) * 100, 1)
  }

  $incomeByCategory = @($incomes | Group-Object { Get-ItemValue $_ "category" } | ForEach-Object {
    @{ category = $_.Name; amount = (Sum-Field $_.Group) }
  })
  $expenseByCategory = @($expenses | Group-Object { Get-ItemValue $_ "category" } | ForEach-Object {
    @{ category = $_.Name; amount = (Sum-Field $_.Group) }
  })

  @{
    monthIncome = $monthIncome
    monthExpense = $monthExpense
    todayExpense = $todayExpense
    weekExpense = $weekExpense
    lastMonthExpense = $lastMonthExpense
    expenseChangePercent = $expenseChangePercent
    topIncomeSource = $topIncomeSource
    topExpenseCategory = $topExpenseCategory
    lastIncome = $lastIncome
    incomeByCategory = $incomeByCategory
    expenseByCategory = $expenseByCategory
    totalIncome = (Sum-Field $incomes)
    totalExpense = (Sum-Field $expenses)
  }
}

# ---- Kredit karta uchun alohida CRUD + to'lov + statistika ----
# (bot va Mini App bir xil funksiyalardan foydalanadi, xuddi Daromad/Xarajat kabi)

function Add-Card {
  param(
    [string]$ChatId,
    [hashtable]$Fields
  )

  $store = Read-Store $ChatId
  $dueDate = $null
  if ($Fields.ContainsKey("dueDate") -and -not [string]::IsNullOrWhiteSpace([string]$Fields["dueDate"]) -and [string]$Fields["dueDate"] -ne "-") {
    $dueDate = [string]$Fields["dueDate"]
  }

  $card = @{
    id = [guid]::NewGuid().ToString()
    bank = [string]$Fields["bank"]
    name = [string]$Fields["name"]
    limit = [decimal]$Fields["limit"]
    used = [decimal]$Fields["used"]
    annualRate = if ($Fields.ContainsKey("annualRate") -and $Fields["annualRate"]) { [decimal]$Fields["annualRate"] } else { [decimal]0 }
    graceDays = if ($Fields.ContainsKey("graceDays") -and $Fields["graceDays"]) { [int]$Fields["graceDays"] } else { 0 }
    dueDate = $dueDate
    note = if ($Fields.ContainsKey("note")) { [string]$Fields["note"] } else { "" }
    payments = @()
    date = Now-Iso
  }

  $store.cards = @($store.cards) + $card
  Write-Store $ChatId $store
  return $card
}

function Update-Card {
  param(
    [string]$ChatId,
    [string]$Id,
    [hashtable]$Fields
  )

  $store = Read-Store $ChatId
  $items = @($store.cards)
  $index = -1
  for ($i = 0; $i -lt $items.Count; $i++) {
    if ((Get-ItemValue $items[$i] "id") -eq $Id) { $index = $i; break }
  }
  if ($index -eq -1) { return $null }

  $existing = $items[$index]
  $dueDate = Get-ItemValue $existing "dueDate"
  if ($Fields.ContainsKey("dueDate")) {
    $raw = [string]$Fields["dueDate"]
    $dueDate = if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq "-") { $null } else { $raw }
  }

  $updated = @{
    id = $Id
    bank = if ($Fields.ContainsKey("bank")) { [string]$Fields["bank"] } else { Get-ItemValue $existing "bank" }
    name = if ($Fields.ContainsKey("name")) { [string]$Fields["name"] } else { Get-ItemValue $existing "name" }
    limit = if ($Fields.ContainsKey("limit")) { [decimal]$Fields["limit"] } else { [decimal](Get-ItemValue $existing "limit") }
    used = if ($Fields.ContainsKey("used")) { [decimal]$Fields["used"] } else { [decimal](Get-ItemValue $existing "used") }
    annualRate = if ($Fields.ContainsKey("annualRate")) { [decimal]$Fields["annualRate"] } else { [decimal](Get-ItemValue $existing "annualRate") }
    graceDays = if ($Fields.ContainsKey("graceDays")) { [int]$Fields["graceDays"] } else { [int](Get-ItemValue $existing "graceDays") }
    dueDate = $dueDate
    note = if ($Fields.ContainsKey("note")) { [string]$Fields["note"] } else { Get-ItemValue $existing "note" }
    payments = @(Get-ItemValue $existing "payments")
    date = Get-ItemValue $existing "date"
  }

  $items[$index] = $updated
  $store.cards = $items
  Write-Store $ChatId $store
  return $updated
}

function Remove-Card {
  param(
    [string]$ChatId,
    [string]$Id
  )

  $store = Read-Store $ChatId
  $before = @($store.cards).Count
  $store.cards = @(@($store.cards) | Where-Object { (Get-ItemValue $_ "id") -ne $Id })
  $after = @($store.cards).Count
  Write-Store $ChatId $store
  return ($after -lt $before)
}

function Get-Cards {
  param([string]$ChatId)
  $store = Read-Store $ChatId
  return @($store.cards | Sort-Object { [datetime](Get-ItemValue $_ "date") } -Descending)
}

function Add-CardPayment {
  # Kartaga to'lov qilinganda: 'used' kamayadi va shu summa avtomatik
  # xarajat sifatida ham yoziladi (Kredit to'lovi kategoriyasi), shunda
  # dashboard/statistikada ko'rinadi - alohida yozib qo'yish shart emas.
  param(
    [string]$ChatId,
    [string]$Id,
    [decimal]$Amount,
    [string]$Account = "Kredit karta"
  )

  $store = Read-Store $ChatId
  $items = @($store.cards)
  $index = -1
  for ($i = 0; $i -lt $items.Count; $i++) {
    if ((Get-ItemValue $items[$i] "id") -eq $Id) { $index = $i; break }
  }
  if ($index -eq -1) { return $null }

  $existing = $items[$index]
  $currentUsed = [decimal](Get-ItemValue $existing "used")
  $newUsed = $currentUsed - $Amount
  if ($newUsed -lt 0) { $newUsed = [decimal]0 }

  $payments = @(Get-ItemValue $existing "payments")
  $payments += @{ id = [guid]::NewGuid().ToString(); amount = $Amount; date = Now-Iso }

  # PSCustomObject'ni to'g'ridan-to'g'ri o'zgartirib bo'lmaydi (Redis/fayldan
  # o'qilgach JSON orqali qayta tiklangan obyekt), shuning uchun yangi
  # hashtable sifatida qayta yig'amiz - xuddi Update-Card'dagi kabi.
  $card = @{
    id = $Id
    bank = Get-ItemValue $existing "bank"
    name = Get-ItemValue $existing "name"
    limit = [decimal](Get-ItemValue $existing "limit")
    used = $newUsed
    annualRate = Get-ItemValue $existing "annualRate"
    graceDays = Get-ItemValue $existing "graceDays"
    dueDate = Get-ItemValue $existing "dueDate"
    note = Get-ItemValue $existing "note"
    payments = $payments
    date = Get-ItemValue $existing "date"
  }

  $items[$index] = $card
  $store.cards = $items

  $expense = @{
    id = [guid]::NewGuid().ToString()
    type = "expense"
    amount = $Amount
    category = "Kredit to'lovi"
    account = $Account
    currency = "UZS"
    note = "Kredit karta to'lovi: $($card.bank) $($card.name)"
    recurring = $false
    date = Now-Iso
  }
  $store.expenses = @($store.expenses) + $expense

  Write-Store $ChatId $store
  return $card
}

function Get-CardSummary {
  param([string]$ChatId)

  $cards = Get-Cards $ChatId
  $totalLimit = Sum-Field $cards "limit"
  $totalUsed = Sum-Field $cards "used"
  $utilization = if ($totalLimit -gt 0) { [math]::Round(($totalUsed / $totalLimit) * 100, 1) } else { 0 }

  $upcomingDue = @($cards | Where-Object {
    $due = Get-ItemValue $_ "dueDate"
    if ([string]::IsNullOrWhiteSpace($due)) { return $false }
    try {
      $days = (([datetime]$due).Date - (Get-Date).Date).Days
      return ($days -ge 0 -and $days -le 5)
    } catch { return $false }
  })

  @{
    totalLimit = $totalLimit
    totalUsed = $totalUsed
    utilization = $utilization
    cardCount = $cards.Count
    upcomingDue = $upcomingDue
  }
}
