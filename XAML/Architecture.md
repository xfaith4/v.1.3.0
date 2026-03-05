# Architecture: Genesys Conversation Analysis

This application is a "thin UX wrapper" around the `Genesys.Core` engine, adhering to the strict "Core-first" architectural pattern.

## Core Principles

1. **Delegation of Extraction**: All Genesys Cloud data extraction (API calls, paging, retries, async jobs) is delegated to `Genesys.Core` via the `Invoke-Dataset` command. This application contains **zero** direct `Invoke-RestMethod` calls to Genesys Cloud.

2. **Module Boundaries**: Logic is strictly separated into modules:
    - `App.Auth.psm1`: Isolates authentication, acquiring a token and providing it to the Core Adapter. It is a thin wrapper over the shared `Genesys.Auth` module.
    - `App.CoreAdapter.psm1`: The **only** module that is permitted to `Import-Module Genesys.Core` and call `Invoke-Dataset`. It acts as a bridge between the UI and the Core engine.
    - `App.UI.psm1`: The UI "code-behind" that handles user interactions from `MainWindow.xaml` and orchestrates calls to other application modules. It is forbidden from calling `Genesys.Core` directly.
    - `App.Index.psm1`: Manages the creation and querying of a run's local index (`index.jsonl`) to ensure scalable and performant paging over large datasets.
    - `App.Export.psm1`: Handles streaming data from the run artifacts (`data/*.jsonl`) to CSV files, ensuring the application does not run out of memory.

3. **Data Contract**: The application does not consume raw API responses. It reads from the standardized, immutable "run artifacts" (`manifest.json`, `summary.json`, `events.jsonl`, `data/*.jsonl`) produced by `Genesys.Core`. This allows the app to open, analyze, and export previous runs without re-executing them.

4. **Dependency Management**: `Genesys.Core` is treated as an external, referenced dependency. It is not part of this application's source code. The path to the Core module is resolved at runtime, typically via an environment variable, ensuring the application is "detachable" and can be run against different versions of the Core engine.
