param(
  [int]$Port = 8080
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Storage.ps1")

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

function Read-JsonBody {
  param([System.Net.HttpListenerRequest]$Request)
  $reader = New-Object IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
  $text = $reader.ReadToEnd()
  $reader.Close()
  if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
  $obj = $text | ConvertFrom-Json
  $result = @{}
  foreach ($p in $obj.PSObject.Properties) { $result[$p.Name] = $p.Value }
  return $result
}

function Handle-Api {
  param(
    [System.Net.HttpListenerContext]$Context
  )

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

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "My Finance server (web + API): http://localhost:$Port/"
Write-Host "Bu skript ishlab turishi shart - Mini App ma'lumotlarni shu API orqali botning data papkasidan o'qiydi."
Write-Host "To'xtatish: Ctrl+C"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      if ($context.Request.Url.AbsolutePath.StartsWith("/api/")) {
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
