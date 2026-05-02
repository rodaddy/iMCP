# iMCP launchd keepalive

These scripts install a per-user LaunchAgent that starts iMCP at login and
restarts it after crashes or non-zero exits. This is useful for local MCP
setups because `imcp-server` can only service requests while the iMCP menu bar
app is running.

Install for `/Applications/iMCP.app`:

```bash
Scripts/launchd/install-keepalive.sh
```

Install for another app path:

```bash
Scripts/launchd/install-keepalive.sh /path/to/iMCP.app
```

Remove it:

```bash
Scripts/launchd/uninstall-keepalive.sh
```

The LaunchAgent uses `KeepAlive` with `SuccessfulExit=false`, so choosing Quit
from the iMCP menu should not immediately relaunch the app.

Logs are written to:

```text
/tmp/imcp-launchd.out.log
/tmp/imcp-launchd.err.log
```

The installer refuses to run while an `iMCP` process is already active. Quit
iMCP first so launchd owns the new process cleanly.
