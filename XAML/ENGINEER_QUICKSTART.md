# Engineer Quick Start: Genesys Conversation Analysis App

Step-by-step guide to get the application running on a clean Windows machine.
Estimated time: 10-15 minutes.

---

## 1. Prerequisites

Before you begin, ensure you have the following:

- **Windows 10 or 11**
- **PowerShell 7.2+**
  Install: `winget install Microsoft.PowerShell` or [aka.ms/powershell](https://aka.ms/powershell)
- **Git**: `winget install Git.Git`
- **Genesys Cloud OAuth Client** — Client Credentials grant with at minimum:
  - `analytics:conversationDetail:view`
  - `analytics:conversationAggregate:view`

You will need the **Client ID** and **Client Secret** for this OAuth client.

---

## 2. Repository Setup

The application references `Genesys.Core` as an external side-by-side dependency.

```powershell
# 1. Create a root source directory
New-Item -Path 'C:\Source' -ItemType Directory -Force
Set-Location 'C:\Source'

# 2. Clone the Genesys.Core engine
git clone https://github.com/xfaith4/Genesys.Core .\Genesys.Core\

# 3. Clone this application
git clone <url_to_this_app_repo> .\Genesys.Core.ConversationAnalytics\
```

Final folder layout:

```text
C:\Source\
├── Genesys.Core\
│   └── modules\
│       ├── Genesys.Core\
│       │   └── Genesys.Core.psd1
│       └── Genesys.Auth\
│           └── Genesys.Auth.psd1
└── Genesys.Core.ConversationAnalytics\
    └── v.1.3.0\
        └── App.ps1          <- canonical entrypoint
```

> **Module path convention (v2):** `modules\Genesys.Core\Genesys.Core.psd1`
> Do **not** use the legacy path `src\ps-module\...` — that is the old v1 layout.

---

## 3. Environment Configuration

Set these variables in your PowerShell session before launching.
Add them to `$PROFILE` to persist across sessions.

```powershell
# --- Module paths (required) ---
$env:GENESYS_CORE_MODULE_PATH = 'C:\Source\Genesys.Core\modules\Genesys.Core\Genesys.Core.psd1'
$env:GENESYS_AUTH_MODULE_PATH = 'C:\Source\Genesys.Core\modules\Genesys.Auth\Genesys.Auth.psd1'

# --- Genesys Cloud credentials (required for Connect) ---
$env:GENESYS_CLIENT_ID     = 'your-client-id-goes-here'
$env:GENESYS_CLIENT_SECRET = 'your-client-secret-goes-here'
$env:GENESYS_REGION        = 'usw2.pure.cloud'   # e.g. mypurecloud.com, mypurecloude.com
```

**Alternative to env vars:** create `appsettings.json` at the repo root:

```json
{
  "GenesysCoreModulePath": "C:\\Source\\Genesys.Core\\modules\\Genesys.Core\\Genesys.Core.psd1",
  "GenesysAuthModulePath": "C:\\Source\\Genesys.Core\\modules\\Genesys.Auth\\Genesys.Auth.psd1"
}
```

---

## 4. Verify Readiness (Smoke Test)

Before launching the UI, run the smoke test to confirm everything is wired up:

```powershell
Set-Location 'C:\Source\Genesys.Core.ConversationAnalytics\v.1.3.0'

pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 -Verbose
```

Expected output:

```text
[PASS] Imports
[PASS] Paths
[PASS] Auth env-vars
[PASS] Token acquisition
[PASS] XAML artefact
--- Smoke: PASS ---
```

If any check fails, follow the inline guidance printed next to the `[FAIL]` line.

---

## 5. Launch the Application

```powershell
Set-Location 'C:\Source\Genesys.Core.ConversationAnalytics\v.1.3.0'

pwsh -NoProfile -ExecutionPolicy Bypass -File ./App.ps1
```

The WPF window opens. The connection indicator in the top-center will be red (Not connected).

---

## 6. Connect to Genesys Cloud

1. Click the **Connect** button in the top-right.
2. The app reads `GENESYS_CLIENT_ID`, `GENESYS_CLIENT_SECRET`, and `GENESYS_REGION` from the environment.
3. A Client Credentials token is acquired via the `Genesys.Auth` module.
4. On success: the indicator turns **green** and shows the region.
5. On failure: an error message is shown with guidance.

Common failure causes:

- Wrong `GENESYS_REGION` format — use the hostname only, e.g. `usw2.pure.cloud` not `https://...`
- OAuth client lacks analytics permissions
- Missing or incorrect `GENESYS_CLIENT_ID` / `GENESYS_CLIENT_SECRET`

You are now authenticated and ready to run queries.

---

## 7. Running Without Credentials (Offline Mode)

To explore the UI or open existing run artifacts without credentials:

```powershell
pwsh -NoProfile -File ./App.ps1 -Offline
```

Offline mode disables Connect, Preview Run, and Full Run. You can still use **Open Run** to browse existing run artifacts.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Dependency resolution failed" at startup | Set `GENESYS_CORE_MODULE_PATH` / `GENESYS_AUTH_MODULE_PATH` or create `appsettings.json` |
| "GENESYS_CORE_MODULE_PATH not set" in UI | Set the env var in the same session before launching |
| Connect throws on missing var | Set `GENESYS_CLIENT_ID` and `GENESYS_CLIENT_SECRET` before clicking Connect |
| Region errors | Use hostname only, e.g. `usw2.pure.cloud` not `https://...` |
| WPF window does not appear | Ensure PowerShell 7.2+ on Windows; run as a standard user (not elevated) |
| Module import fails | Run smoke test: `pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 -Verbose` |

---

## CLI Reference

```powershell
# Canonical launch (only supported entrypoint)
pwsh -NoProfile -ExecutionPolicy Bypass -File ./App.ps1

# Launch with explicit module paths
pwsh -NoProfile -File ./App.ps1 `
    -GenesysCoreModulePath 'C:\Source\Genesys.Core\modules\Genesys.Core\Genesys.Core.psd1' `
    -GenesysAuthModulePath 'C:\Source\Genesys.Core\modules\Genesys.Auth\Genesys.Auth.psd1'

# Offline mode
pwsh -NoProfile -File ./App.ps1 -Offline

# Smoke test
pwsh -NoProfile -File ./scripts/Invoke-Smoke.ps1 -Verbose

# Compliance checks
pwsh -NoProfile -File ./XAML/Invoke-AppCompliance.ps1
```

> **Deprecated:** `./XAML/Run-ConversationAnalytics.ps1` is a legacy shim that forwards to `./App.ps1`.
> Do not use it for new workflows.
