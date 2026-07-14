FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

WORKDIR /app
COPY . .

# Render (va ko'p platformalar) PORT env orqali qaysi portni tinglash kerakligini beradi.
ENV PORT=8080
EXPOSE 8080

CMD ["pwsh", "-File", "/app/Server.ps1"]
