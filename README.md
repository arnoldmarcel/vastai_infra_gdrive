# VastAI ComfyUI Infra Scripts

Skripte zum Aufsetzen/Restoren/Beenden einer ComfyUI-Instanz auf Vast.ai Ubuntu 24.04 mit Google Drive (rclone).

## Setup
```bash
git clone https://github.com/arnoldmarcel/vastai_infra_gdrive
cd vastai_infra_gdrive
cp .env.example .env
# .env mit deinen Werten füllen (Folder-ID, optional Client-ID/Secret, Port, …)
chmod +x scripts/*.sh
