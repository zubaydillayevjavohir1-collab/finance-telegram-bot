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

# ---- Kredit (loan) dvigatelli: annuitet/differensial jadval, CRUD, statistika, oldindan yopish ----

function Get-MonthlyRate {
  param([decimal]$AnnualRate)
  return ($AnnualRate / 100) / 12
}

function Build-LoanSchedule {
  # To'liq amortizatsiya jadvalini qaytaradi: har oy uchun
  # {month, payment, principalPart, interestPart, remaining}
  param(
    [decimal]$Principal,
    [decimal]$AnnualRate,
    [int]$TermMonths,
    [string]$Type = "annuitet"
  )

  $rows = New-Object System.Collections.Generic.List[hashtable]
  if ($TermMonths -le 0 -or $Principal -le 0) { return $rows }

  $monthlyRate = Get-MonthlyRate $AnnualRate
  $remaining = $Principal

  if ($Type -eq "differensial") {
    $principalPart = [math]::Round($Principal / $TermMonths, 2)
    for ($m = 1; $m -le $TermMonths; $m++) {
      $interestPart = [math]::Round($remaining * $monthlyRate, 2)
      $thisPrincipalPart = if ($m -eq $TermMonths) { $remaining } else { $principalPart }
      $payment = $thisPrincipalPart + $interestPart
      $remaining = [math]::Round($remaining - $thisPrincipalPart, 2)
      if ($remaining -lt 0) { $remaining = [decimal]0 }
      $rows.Add(@{ month = $m; payment = $payment; principalPart = $thisPrincipalPart; interestPart = $interestPart; remaining = $remaining })
    }
  } else {
    $fixedPayment = Get-AnnuitetPayment $Principal $AnnualRate $TermMonths
    for ($m = 1; $m -le $TermMonths; $m++) {
      $interestPart = [math]::Round($remaining * $monthlyRate, 2)
      $thisPrincipalPart = $fixedPayment - $interestPart
      $payment = $fixedPayment
      if ($m -eq $TermMonths) {
        $thisPrincipalPart = $remaining
        $payment = $thisPrincipalPart + $interestPart
      }
      $remaining = [math]::Round($remaining - $thisPrincipalPart, 2)
      if ($remaining -lt 0) { $remaining = [decimal]0 }
      $rows.Add(@{ month = $m; payment = $payment; principalPart = $thisPrincipalPart; interestPart = $interestPart; remaining = $remaining })
    }
  }

  return $rows
}

function Add-Loan {
  param(
    [string]$ChatId,
    [hashtable]$Fields
  )

  $store = Read-Store $ChatId
  $loan = @{
    id = [guid]::NewGuid().ToString()
    bank = [string]$Fields["bank"]
    principal = [decimal]$Fields["principal"]
    issueDate = [string]$Fields["issueDate"]
    termMonths = [int]$Fields["termMonths"]
    annualRate = [decimal]$Fields["annualRate"]
    type = if ($Fields.ContainsKey("type") -and [string]$Fields["type"] -eq "differensial") { "differensial" } else { "annuitet" }
    downPayment = if ($Fields.ContainsKey("downPayment") -and $Fields["downPayment"]) { [decimal]$Fields["downPayment"] } else { [decimal]0 }
    note = if ($Fields.ContainsKey("note")) { [string]$Fields["note"] } else { "" }
    status = "Aktiv"
    payments = @()
    date = Now-Iso
  }

  $store.credits = @($store.credits) + $loan
  Write-Store $ChatId $store
  return $loan
}

function Update-Loan {
  param(
    [string]$ChatId,
    [string]$Id,
    [hashtable]$Fields
  )

  $store = Read-Store $ChatId
  $items = @($store.credits)
  $index = -1
  for ($i = 0; $i -lt $items.Count; $i++) {
    if ((Get-ItemValue $items[$i] "id") -eq $Id) { $index = $i; break }
  }
  if ($index -eq -1) { return $null }

  $existing = $items[$index]
  $updated = @{
    id = $Id
    bank = if ($Fields.ContainsKey("bank")) { [string]$Fields["bank"] } else { Get-ItemValue $existing "bank" }
    principal = if ($Fields.ContainsKey("principal")) { [decimal]$Fields["principal"] } else { [decimal](Get-ItemValue $existing "principal") }
    issueDate = if ($Fields.ContainsKey("issueDate")) { [string]$Fields["issueDate"] } else { Get-ItemValue $existing "issueDate" }
    termMonths = if ($Fields.ContainsKey("termMonths")) { [int]$Fields["termMonths"] } else { [int](Get-ItemValue $existing "termMonths") }
    annualRate = if ($Fields.ContainsKey("annualRate")) { [decimal]$Fields["annualRate"] } else { [decimal](Get-ItemValue $existing "annualRate") }
    type = if ($Fields.ContainsKey("type")) { [string]$Fields["type"] } else { Get-ItemValue $existing "type" }
    downPayment = if ($Fields.ContainsKey("downPayment")) { [decimal]$Fields["downPayment"] } else { [decimal](Get-ItemValue $existing "downPayment") }
    note = if ($Fields.ContainsKey("note")) { [string]$Fields["note"] } else { Get-ItemValue $existing "note" }
    status = if ($Fields.ContainsKey("status")) { [string]$Fields["status"] } else { Get-ItemValue $existing "status" }
    payments = @(Get-ItemValue $existing "payments")
    date = Get-ItemValue $existing "date"
  }

  $items[$index] = $updated
  $store.credits = $items
  Write-Store $ChatId $store
  return $updated
}

function Remove-Loan {
  param(
    [string]$ChatId,
    [string]$Id
  )

  $store = Read-Store $ChatId
  $before = @($store.credits).Count
  $store.credits = @(@($store.credits) | Where-Object { (Get-ItemValue $_ "id") -ne $Id })
  $after = @($store.credits).Count
  Write-Store $ChatId $store
  return ($after -lt $before)
}

function Get-Loans {
  param([string]$ChatId)
  $store = Read-Store $ChatId
  return @($store.credits | Sort-Object { [datetime](Get-ItemValue $_ "date") } -Descending)
}

function Get-LoanProgress {
  # Bitta kredit uchun: hozirgi holatga qadar necha oy o'tgani (issueDate asosida),
  # to'liq jadval, hozirgi oy qatori, shu vaqtgacha to'langan asosiy qarz/foiz,
  # qolgan qarz va keyingi to'lov sanasi.
  param(
    [string]$ChatId,
    [object]$Loan
  )

  $principal = [decimal](Get-ItemValue $Loan "principal")
  $annualRate = [decimal](Get-ItemValue $Loan "annualRate")
  $termMonths = [int](Get-ItemValue $Loan "termMonths")
  if ($termMonths -le 0) {
    $legacyMonths = Get-ItemValue $Loan "months"
    if ($legacyMonths) { $termMonths = [int]$legacyMonths }
  }
  $type = Get-ItemValue $Loan "type"
  $issueDateRaw = Get-ItemValue $Loan "issueDate"
  $storedStatus = Get-ItemValue $Loan "status"
  if ($storedStatus -eq "active") { $storedStatus = "Aktiv" }

  $schedule = Build-LoanSchedule -Principal $principal -AnnualRate $annualRate -TermMonths $termMonths -Type $type

  $issueDate = $null
  try { $issueDate = [datetime]$issueDateRaw } catch { $issueDate = [datetime](Get-ItemValue $Loan "date") }

  $monthsElapsed = 0
  if ($issueDate) {
    $monthsElapsed = (((Get-Date).Year - $issueDate.Year) * 12) + (Get-Date).Month - $issueDate.Month
    if ((Get-Date).Day -lt $issueDate.Day) { $monthsElapsed-- }
  }
  if ($monthsElapsed -lt 0) { $monthsElapsed = 0 }
  if ($monthsElapsed -gt $termMonths) { $monthsElapsed = $termMonths }

  $toDate = @($schedule | Select-Object -First $monthsElapsed)
  $paidPrincipal = Sum-Field $toDate "principalPart"
  $paidInterest = Sum-Field $toDate "interestPart"
  $remaining = if ($monthsElapsed -eq 0) { $principal } else { (Get-ItemValue $toDate[-1] "remaining") }

  $currentRow = if ($monthsElapsed -lt $schedule.Count) { $schedule[$monthsElapsed] } else { $null }

  $nextDueDate = $null
  if ($issueDate -and $monthsElapsed -lt $termMonths) {
    $nextDueDate = $issueDate.AddMonths($monthsElapsed + 1)
  }

  $autoStatus = $storedStatus
  if ($monthsElapsed -ge $termMonths -and $storedStatus -ne "Muzlatilgan") { $autoStatus = "Yopilgan" }

  @{
    loan = $Loan
    schedule = $schedule
    monthsElapsed = $monthsElapsed
    remainingMonths = $termMonths - $monthsElapsed
    paidPrincipal = $paidPrincipal
    paidInterest = $paidInterest
    remaining = $remaining
    currentPayment = if ($currentRow) { Get-ItemValue $currentRow "payment" } else { 0 }
    nextDueDate = $nextDueDate
    status = $autoStatus
  }
}

function Get-LoanSummary {
  param([string]$ChatId)

  $loans = Get-Loans $ChatId

  $totalPrincipal = [decimal]0
  $remainingTotal = [decimal]0
  $currentMonthTotal = [decimal]0
  $paidTotal = [decimal]0
  $interestPaidTotal = [decimal]0
  $maxLoan = [decimal]0
  $upcomingDue = New-Object System.Collections.Generic.List[hashtable]

  foreach ($loan in $loans) {
    $progress = Get-LoanProgress $ChatId $loan
    $principal = [decimal](Get-ItemValue $loan "principal")
    if ($principal -gt $maxLoan) { $maxLoan = $principal }
    $paidTotal += $progress.paidPrincipal + $progress.paidInterest
    $interestPaidTotal += $progress.paidInterest

    if ($progress.status -eq "Aktiv" -or $progress.status -eq "Kechiktirilgan") {
      $totalPrincipal += $principal
      $remainingTotal += $progress.remaining
      $currentMonthTotal += $progress.currentPayment
      if ($progress.nextDueDate) {
        $days = ($progress.nextDueDate.Date - (Get-Date).Date).Days
        if ($days -ge 0 -and $days -le 3) {
          $upcomingDue.Add(@{ bank = (Get-ItemValue $loan "bank"); dueDate = $progress.nextDueDate })
        }
      }
    }
  }

  @{
    totalPrincipal = $totalPrincipal
    remaining = $remainingTotal
    currentMonthPayment = $currentMonthTotal
    paidTotal = $paidTotal
    interestPaidTotal = $interestPaidTotal
    maxLoan = $maxLoan
    loanCount = $loans.Count
    upcomingDue = $upcomingDue
  }
}

function Get-EarlyPayoffEstimate {
  # "Oldindan to'lash kalkulyatori": hozir ExtraAmount to'lansa,
  # necha oy qisqaradi va qancha foiz tejaladi.
  param(
    [string]$ChatId,
    [object]$Loan,
    [decimal]$ExtraAmount
  )

  $progress = Get-LoanProgress -ChatId $ChatId -Loan $Loan
  $annualRate = [decimal](Get-ItemValue $Loan "annualRate")
  $type = Get-ItemValue $Loan "type"
  $monthlyRate = Get-MonthlyRate $annualRate

  $remainingMonths = $progress.remainingMonths
  $remainingPrincipal = $progress.remaining
  $newPrincipal = $remainingPrincipal - $ExtraAmount
  if ($newPrincipal -lt 0) { $newPrincipal = [decimal]0 }

  # Qolgan muddat davomida to'lanadigan asl foiz (hozirgi holatdan boshlab)
  $originalRemainingInterest = Sum-Field (@($progress.schedule) | Select-Object -Skip $progress.monthsElapsed) "interestPart"

  if ($newPrincipal -eq 0 -or $remainingMonths -le 0) {
    return @{
      monthsSaved = $remainingMonths
      interestSaved = $originalRemainingInterest
      newRemainingMonths = 0
    }
  }

  if ($type -eq "differensial") {
    $principalPart = [math]::Round((Get-ItemValue $Loan "principal") / (Get-ItemValue $Loan "termMonths"), 2)
    if ($principalPart -le 0) { $principalPart = $newPrincipal }
    $newMonths = [math]::Ceiling($newPrincipal / $principalPart)
  } else {
    $fixedPayment = Get-AnnuitetPayment (Get-ItemValue $Loan "principal") $annualRate (Get-ItemValue $Loan "termMonths")
    $newMonths = 0
    $balance = $newPrincipal
    while ($balance -gt 0.01 -and $newMonths -lt 1200) {
      $interest = $balance * $monthlyRate
      $principalPart = $fixedPayment - $interest
      if ($principalPart -le 0) { $newMonths = $remainingMonths; break }
      $balance -= $principalPart
      $newMonths++
    }
  }

  $newSchedule = Build-LoanSchedule -Principal $newPrincipal -AnnualRate $annualRate -TermMonths $newMonths -Type $type
  $newInterest = Sum-Field $newSchedule "interestPart"

  @{
    monthsSaved = [math]::Max(0, $remainingMonths - $newMonths)
    interestSaved = [math]::Max(0, $originalRemainingInterest - $newInterest)
    newRemainingMonths = $newMonths
  }
}
