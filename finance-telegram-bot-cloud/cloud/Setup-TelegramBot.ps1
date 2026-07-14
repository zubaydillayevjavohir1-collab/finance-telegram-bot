param(
  [string]$Token = $env:TELEGRAM_BOT_TOKEN,
  [string]$WebAppUrl = $env:WEB_APP_URL
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Token)) {
  Write-Host "TELEGRAM_BOT_TOKEN topilmadi."
  exit 1
}

if ([string]::IsNullOrWhiteSpace($WebAppUrl) -or -not $WebAppUrl.StartsWith("https://")) {
  Write-Host "WEB_APP_URL https link bo'lishi kerak. Telegram Mini App uchun public HTTPS URL talab qilinadi."
  exit 1
}

$baseUrl = "https://api.telegram.org/bot$Token"

$commands = @(
  @{ command = "start"; description = "Mini Appni ochish" },
  @{ command = "dashboard"; description = "Dashboard" },
  @{ command = "stats"; description = "Statistika" },
  @{ command = "income"; description = "Daromad qo'shish" },
  @{ command = "income_list"; description = "Daromadlar ro'yxati" },
  @{ command = "expense"; description = "Xarajat qo'shish" },
  @{ command = "expense_list"; description = "Xarajatlar ro'yxati" },
  @{ command = "credit"; description = "Kredit hisoblash" }
)

Invoke-RestMethod -Method Post -Uri "$baseUrl/setMyCommands" -Body @{
  commands = ($commands | ConvertTo-Json -Depth 6 -Compress)
} | Out-Null

Invoke-RestMethod -Method Post -Uri "$baseUrl/setChatMenuButton" -Body @{
  menu_button = (@{
    type = "web_app"
    text = "My Finance"
    web_app = @{ url = $WebAppUrl }
  } | ConvertTo-Json -Depth 6 -Compress)
} | Out-Null

Write-Host "Telegram bot sozlandi. Mini App URL: $WebAppUrl"
