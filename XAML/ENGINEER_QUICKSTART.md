# Engineer Quick Start: Conversation Analysis App

This guide provides the step-by-step procedure for setting up and running the Genesys Conversation Analysis application on a local development machine.

## 1. Prerequisites

Before you begin, ensure you have the following:

- **Windows 10/11 Machine**
- **PowerShell 7.2+**: The application is developed with PowerShell 7 and WPF.
- **Git**: For cloning the required repositories.
- **Genesys Cloud OAuth Client**: You must have a Client Credentials grant configured in your Genesys Cloud organization with the following permissions:
  - `analytics:conversationDetail:view`
  - `analytics:conversationAggregate:view`
  - Any other permissions required for the datasets you intend to query.

You will need the **Client ID** and **Client Secret** for this OAuth client.

## 2. Repository Setup

The application is designed to reference the `Genesys.Core` engine as a separate, side-by-side dependency.

1.  **Create a Source Directory**: Create a root folder for your projects.

    ```powershell
    New-Item -Path "C:\GenesysCoreConversationAnalytics\" -ItemType Directory
    cd C:\GenesysCoreConversationAnalytics\
    ```

2.  **Clone `Genesys.Core`**: Clone the core engine repository.

    ```powershell
    git clone https://github.com/xfaith4/Genesys.Core .\Genesys.Core\
    ```

3.  **Clone This Application**: Clone the `Genesys.Core.ConversationAnalytics` repository.

    ```powershell
    git clone <url_to_this_app_repo> .\Genesys.Core.ConversationAnalytics\
    ```

Your final folder structure should look like this:
```
C:\Source\
├── Genesys.Core\
└── Genesys.Core.ConversationAnalytics\
```

## 3. Environment Configuration

The application uses environment variables to locate its dependencies and for authentication credentials. This allows the application to be "detachable" and avoids hardcoding secrets.

Open your PowerShell profile (`notepad $PROFILE`) or run these commands in your terminal session before launching the app.

1.  **Configure Authentication**: Set the environment variables for your OAuth client.

    ```powershell
    $env:GENESYS_CLIENT_ID = "your-client-id-goes-here"
    $env:GENESYS_CLIENT_SECRET = "your-client-secret-goes-here"
    ```

2.  **Configure Dependency Paths**: Tell the application where to find the `Genesys.Core` and `Genesys.Auth` modules you cloned.

    ```powershell
    $env:GENESYS_CORE_MODULE_PATH = "C:\Source\Genesys.Core\modules\Genesys.Core\Genesys.Core.psd1"
    $env:GENESYS_AUTH_MODULE_PATH = "C:\Source\Genesys.Core\modules\Genesys.Auth\Genesys.Auth.psd1"
    ```

## 4. Launch and Authenticate

1.  **Navigate to the App Directory**:
    ```powershell
    cd C:\Source\Genesys.Core.ConversationAnalytics
    ```
2.  **Run the Application**: Execute the main launcher script.
    ```powershell
    .\Run-ConversationAnalytics.ps1
    ```
3.  **Connect in the UI**:
    - The main window will appear. The connection status indicator in the top-center will be red ("Not connected").
    - Click the blue **"Connect"** button in the top-right corner.
    - The application will call `App.Auth.psm1`, which reads your environment variables and performs a Client Credentials grant against Genesys Cloud.
    - If successful, the status indicator will turn green, and the label will update to "Connected to...".

You are now authenticated and ready to run queries.
