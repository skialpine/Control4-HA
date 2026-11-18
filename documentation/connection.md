# HA connection

The Coordinator owns one HA WebSocket connection using the pinned template's
WebSocket, timer and logging helpers. Configure these Composer properties:

| Property            | Value                                                                                                                                                                                                   |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HA URL              | Final origin, such as `http://homeassistant.local:8123` or `https://ha.example.com`. Use a DNS name or IPv4 address, without a path, query, fragment or embedded credentials. For IPv6, use a DNS name. |
| HA Token            | HA long-lived access token, entered in the password-protected property. Never paste it into logs, programming or support reports.                                                                       |
| CA Certificate Path | Optional controller-side CA file path for HTTPS, relative to the driver location as defined by DriverWorks. Leave empty to use Director's trust configuration.                                          |

An existing BP or prototype Coordinator keeps its original **Home Assistant
URL**, **Long Lived Access Token** and **Use SSL** settings. Enter the host and
port in that address field. Choose **Yes** for **Use SSL** when the server
requires HTTPS. Advanced settings expose the original certificate, private-key
and CA file paths for secure connections. The directory selection applies to all
three. Both the WebSocket and HTTP requests use the saved certificate
configuration. If both sets of credentials are populated, the driver pauses the
connection and shows both sets so the installer can clear the obsolete one.

The **Connect to Home Assistant** and **Disconnect from Home Assistant** actions
operate the current connection. Disconnect also cancels pending automatic
retries. The negotiated Home Assistant version appears in Advanced after
authentication.

Existing programming can read the **HA URL** driver variable and run **Call
Service** with its original six parameters. The variable publishes the validated
host and optional port. The suite’s **HA URL** configuration property retains
the complete origin, including its scheme. The original variable keeps slot 1001
on an upgrade from BP. A prior side-by-side suite installation appends the
variable after its existing programming slots.

On the lab CORE 1 running 3.4.3, the saved project serialized **Use SSL** as
**No**, while the running property reader returned a boolean spelling. The
Coordinator accepts Yes/No and True/False case-insensitively for both transport
setup and certificate controls. An unknown choice leaves the connection offline
and identifies the setting to correct. The validated saved host remains
available to the programming variable while the restored connection settings are
loading.

Create the token in a Home Assistant administrator’s profile. The current driver
needs administrator permission to receive state changes and prepare companion
devices. The optional companion adds button gestures and supported indicators.
Ordinary lights and switches use their existing Home Assistant endpoints. See
the official
[HA authentication API](https://contributors.home-assistant.io/core/internals/auth-api/)
and
[WebSocket API](https://contributors.home-assistant.io/core/internals/websocket-api/).

Director must resolve and reach the origin and port. HTTPS requests peer
certificate verification through DriverWorks `VERIFY_MODE=peer`; configure a
trusted chain rather than disabling verification. Native TLS trust and hostname
behavior still require the Director qualification recorded in the compatibility
matrix. The isolated Container lab uses HTTP on its dedicated LAN port. HTTP
transmits the credential without encryption; use it only on a trusted network.
DriverWorks CA paths and verification modes are described in the official
[network API reference](https://snap-one.github.io/docs-driverworks-api/#netportoptions).

Reverse proxies must support upgrading `/api/websocket` at the configured
origin. Redirects are refused; enter the final destination explicitly. The token
is sent only after a valid 101 upgrade and HA's authentication challenge.
Upgrade and authentication each have a ten-second deadline. A timeout identifies
DNS, TLS, proxy and final-URL checks. A rejected token stops automatic retry
until the configuration is applied again. Other connection failures retry after
one, two, four, eight, sixteen and at most thirty seconds, after the old
socket's close cleanup has released its binding. Healthy connections use
WebSocket keepalive, without state polling.

When **Driver Status** says **Connected to Home Assistant**, Quick Setup can
discover devices. After adding a device, use its **Device Setup** tab to see its
selected target and feedback. See the
[driver setup guide](../drivers/coordinator/www/documentation/index.md).

Routine diagnostics contain fixed local status text. Tokens, URLs, raw server
errors and state payloads are excluded. The protected field is also excluded by
the template's web property helper. Raw WebSocket/network debug switches are not
supported by the suite because they can expose private messages. Configuration
changes retire the old connection before starting a replacement; destruction
invalidates callbacks and retries.

`test/test_ha_connection.lua` exercises authentication, rejection, timeout,
backoff, configuration replacement, destruction and privacy through the actual
template WebSocket implementation behind the C4 shim. These are local protocol
checks; real HA and native Director qualification remain separate tasks.
