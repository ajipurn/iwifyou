#!/usr/bin/env python3
"""Local, synthetic F460 fixture server. Never contacts a real router."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import time
from urllib.parse import parse_qs, urlsplit

FIXTURES = Path(__file__).resolve().parent.parent / "Tests/IWiFiYouCoreTests/Fixtures"
BASE = (FIXTURES / "F460WLAN.html").read_text()
LOGIN = (FIXTURES / "F460Login.html").read_text()
TOKEN_SCRIPT = (FIXTURES / "F460Token.js").read_text()
TIMEOUT = (FIXTURES / "F460SessionTimeout.html").read_text()
ADMIN_BUSY = (FIXTURES / "F460AdminBusy.html").read_text()
LAN_INFO = (FIXTURES / "F460LANInfo.html").read_text()
ARP_TABLE = (FIXTURES / "F460ARP.html").read_text()
MAC_FILTER = (FIXTURES / "F460MACFilter.html").read_text()
RESTART = (FIXTURES / "F460Restart.html").read_text()
STATIC_PAGES = {name: (FIXTURES / f"{fixture}.html").read_text() for name, fixture in [
    ("status_dev_info_t.gch", "F460DeviceInfo"), ("status_ethwan_if_t.gch", "F460WANStatus"),
    ("pon_status_link_info_t.gch", "F460Optical"), ("e8_status_wlan_info_t.gch", "F460WLANStatus"),
]}
DHCP = (FIXTURES / "F460DHCPStatic.html").read_text()
FORWARD = (FIXTURES / "F460PortForward.html").read_text()
URL_FILTER = (FIXTURES / "F460URLFilter.html").read_text()
HOSTS = (FIXTURES / "F460Hosts.html").read_text()
HOSTS_PAGE = "app_dev_name_t.gch"
DHCP_PAGE = "net_dhcp_static_t.gch"
FORWARD_PAGE = "app_virtual_conf_t.gch"
URL_PAGE = "sec_url_filter_t.gch"
FORWARD_RULE = ["Enable", "Name", "Protocol", "MinRemoteHost", "MaxRemoteHost", "MinExtPort", "MaxExtPort", "MinIntPort",
                "MaxIntPort", "WANCViewName", "InternalHost", "InternalMacHost", "MacEnable"]
FORWARD_OTHER = ["ViewName", "WANCName", "MaxIntPort", "Description", "LeaseDuration", "PortMappCreator"]
URL_RULE = ["ViewName", "Enable", "Url", "FilterTarget"]
URL_BASIC = ["IsWanSrvCntl", "IpFilterTarget", "UrlFilterTarget", "UrlFilterEnable", "SrvCntlTarget", "DefaultPolicy"]
IPV4 = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
WLAN_PAGE = "pon_net_wlan_conf_t.gch"
FILTER_PAGE = "sec_macfilter_conf_t.gch"
RESTART_PAGE = "manager_dev_restart_t.gch"
RULE_KEYS = ["Enable", "BlackList", "Type", "Protocol", "SrcMacAddr", "DstMacAddr"]
BASIC_KEYS = ["IsWanSrvCntl", "IpFilterTarget", "UrlFilterTarget", "UrlFilterEnable", "SrvCntlTarget",
              "DefaultPolicy", "MacFilterTarget", "MacFilterEnable"]
MAC = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
CONFIG = re.findall(r'"([^"]+)"', re.search(r"var CONFIG_PARA = new Array\((.*?)\)", BASE).group(1))
STATE = {}


def reset():
    STATE.clear()
    STATE.update(channel="11", auto="1", ssid="Fixture WiFi", posts=0, logins=0, drop=False, reject=False,
                 token_sequence=0, token=None, tokens_rejected=0, expire_next=False,
                 session_expired=False, expire_during_verification=False, admin_busy=False,
                 active_session=None, logouts=0, logout_attempts=0, logout_mode="normal", delay_apply=False, events=[],
                 filter_enabled="0", filter_mode="Discard", filter_entries=[], filter_posts=0, filter_drop=False,
                 restarts=0, reboot_seconds=1.5, reboot_until=0.0,
                 passphrase="fixture-only-password", credential_posts=0,
                 reservations=[], forwards=[], url_enabled="0", url_mode="0", urls=[], list_posts=0, hosts=[])


def assign(text, name, value):
    return re.sub(r"Transfer_meaning\('" + name + r"','[^']*'\);", lambda _: f"Transfer_meaning('{name}','{value}');", text)


def tokenized(text):
    STATE["token_sequence"] += 1
    STATE["token"] = f"fixture-session-{STATE['token_sequence']}"
    # Every page rotates the token, including read-only page loads.
    return text + "<script>" + TOKEN_SCRIPT.replace("fixture-session-token-01", STATE["token"]) + "</script>"


def filter_page(error="SUCC", parameter="SUCC"):
    rows = ""
    for index, mac in enumerate(STATE["filter_entries"]):
        escaped = mac.replace(":", "\\x3a")
        rows += f"<INPUT type='hidden' name=SrcMacAddr{index} ID=SrcMacAddr{index} value=''>\n<script language=javascript>Transfer_meaning('SrcMacAddr{index}','{escaped}');</script>\n"
        rows += f"<INPUT type='hidden' name=DstMacAddr{index} ID=DstMacAddr{index} value=''>\n<script language=javascript>Transfer_meaning('DstMacAddr{index}','00\\x3a00\\x3a00\\x3a00\\x3a00\\x3a00');</script>\n"
    text = MAC_FILTER.replace("<!--ENTRIES-->", rows)
    for name, value in [("IF_INSTNUM", str(len(STATE["filter_entries"]))), ("MacFilterEnable", STATE["filter_enabled"]),
                        ("MacFilterTarget", STATE["filter_mode"])]:
        text = assign(text, name, value)
    # The real page emits several IF_ERRORSTR assignments; the last one wins.
    text = text.replace("</FORM>", f"<script language=javascript>Transfer_meaning('IF_ERRORSTR','{error}');</script>\n"
                        f"<script language=javascript>Transfer_meaning('IF_ERRORPARAM','{parameter}');</script>\n</FORM>")
    return tokenized(text)


def restart_page(flag="NULL", error="SUCC", parameter="SUCC"):
    text = assign(RESTART, "flag", flag)
    text = text.replace("</FORM>", f"<script language=javascript>Transfer_meaning('IF_ERRORSTR','{error}');</script>\n"
                        f"<script language=javascript>Transfer_meaning('IF_ERRORPARAM','{parameter}');</script>\n</FORM>")
    return tokenized(text)


def js_escape(value):
    return "".join(ch if ch.isalnum() or ch == " " else "\\x%02x" % ord(ch) for ch in value)


def indexed_rows(rows):
    text = ""
    for index, row in enumerate(rows):
        for key, value in row:
            text += (f"<INPUT type='hidden' name={key}{index} ID={key}{index} value=''>\n"
                     f"<script language=javascript>Transfer_meaning('{key}{index}','{js_escape(value)}');</script>\n")
    return text


def list_page(template, rows, error="SUCC", parameter="SUCC", extra=()):
    text = template.replace("<!--ENTRIES-->", indexed_rows(rows))
    text = assign(text, "IF_INSTNUM", str(len(rows)))
    for name, value in extra:
        text = assign(text, name, value)
    text = text.replace("</FORM>", f"<script language=javascript>Transfer_meaning('IF_ERRORSTR','{error}');</script>\n"
                        f"<script language=javascript>Transfer_meaning('IF_ERRORPARAM','{parameter}');</script>\n</FORM>", 1)
    return tokenized(text)


def dhcp_page(error="SUCC"):
    return list_page(DHCP, [[("IPAddr", ip), ("MACAddr", mac)] for ip, mac in STATE["reservations"]], error)


def forward_page(error="SUCC"):
    return list_page(FORWARD, [[("Enable", "1"), ("Name", rule["Name"]), ("Protocol", rule["Protocol"]),
                                ("MinExtPort", rule["MinExtPort"]), ("MaxExtPort", rule["MaxExtPort"]),
                                ("InternalHost", rule["InternalHost"]), ("MinIntPort", rule["MinIntPort"])]
                               for rule in STATE["forwards"]], error)


def url_page(error="SUCC"):
    return list_page(URL_FILTER, [[("Url", url)] for url in STATE["urls"]], error,
                     extra=[("UrlFilterEnable", STATE["url_enabled"]), ("UrlFilterTarget", STATE["url_mode"])])


def hosts_page(error="SUCC"):
    text = HOSTS.replace("<!--ENTRIES-->", indexed_rows([[("HostName", name), ("IPAddress", ip)] for name, ip in STATE["hosts"]]))
    text = assign(text, "HOST_INSTNUM", str(len(STATE["hosts"])))
    return tokenized(assign(text, "HOST_ERRORSTR", error))


def in_pool(ip):
    match = IPV4.match(ip or "")
    return bool(match) and ip.startswith("192.168.1.") and 2 <= int(match.group(4)) <= 254


def content(page_name):
    if page_name == WLAN_PAGE:
        return page()
    if page_name == "status_lan_info_t.gch":
        return tokenized(LAN_INFO)
    if page_name == "diag_netDiag_arpTable_t.gch":
        return tokenized(ARP_TABLE)
    if page_name == FILTER_PAGE:
        return filter_page()
    if page_name == RESTART_PAGE:
        return restart_page()
    if page_name in STATIC_PAGES:
        return tokenized(STATIC_PAGES[page_name])
    if page_name == DHCP_PAGE:
        return dhcp_page()
    if page_name == FORWARD_PAGE:
        return forward_page()
    if page_name == URL_PAGE:
        return url_page()
    if page_name == HOSTS_PAGE:
        return hosts_page()
    return None


def page(error="SUCC", parameter="SUCC"):
    text = BASE
    for name, value in [("Channel", STATE["channel"]), ("AutoChannelEnabled", STATE["auto"]), ("ESSID", js_escape(STATE["ssid"])),
                        ("KeyPassphrase", js_escape(STATE["passphrase"])), ("IF_ERRORSTR", error), ("IF_ERRORPARAM", parameter)]:
        text = assign(text, name, value)
    return tokenized(text)


class Router(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log POST bodies or credentials.

    def send(self, body, *, status=200, cookie=None):
        body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def owns_session(self):
        cookies = self.headers.get("Cookie", "").split(";")
        return STATE["active_session"] is not None and any(
            cookie.strip() == "session=" + STATE["active_session"] for cookie in cookies
        )

    def rebooting(self):
        if time.time() < STATE["reboot_until"]:
            self.close_connection = True  # Nothing answers while the router is down.
            return True
        return False

    def next_page(self):
        return parse_qs(urlsplit(self.path).query).get("nextpage", [WLAN_PAGE])[0]

    def do_GET(self):
        path = urlsplit(self.path).path
        if not path.startswith("/simulate/") and self.rebooting():
            return
        if path == "/simulate/reset":
            reset()
            self.send("OK")
        elif path == "/simulate/state":
            self.send(json.dumps(STATE))
        elif path == "/simulate/drop-next":
            STATE["drop"] = True
            self.send("OK")
        elif path == "/simulate/reject-next":
            STATE["reject"] = True
            self.send("OK")
        elif path == "/simulate/expire-next":
            STATE["expire_next"] = True
            self.send("OK")
        elif path == "/simulate/expire-session":
            STATE["session_expired"] = True
            STATE["active_session"] = None
            self.send("OK")
        elif path == "/simulate/admin-busy":
            STATE["session_expired"] = True
            STATE["admin_busy"] = True
            STATE["active_session"] = "other-admin"
            self.send("OK")
        elif path == "/simulate/expire-during-verification":
            STATE["expire_during_verification"] = True
            self.send("OK")
        elif path == "/simulate/reject-logout":
            STATE["logout_mode"] = "reject"
            self.send("OK")
        elif path == "/simulate/lie-logout":
            STATE["logout_mode"] = "lie"
            self.send("OK")
        elif path == "/simulate/drop-logout":
            STATE["logout_mode"] = "drop"
            self.send("OK")
        elif path == "/simulate/allow-logout":
            STATE["logout_mode"] = "normal"
            self.send("OK")
        elif path == "/simulate/delay-apply":
            STATE["delay_apply"] = True
            self.send("OK")
        elif path == "/simulate/external-change":
            STATE["ssid"] = "Changed by someone else"
            self.send("OK")
        elif path == "/simulate/external-filter-change":
            STATE["filter_entries"].append("02:00:5e:10:00:77")
            self.send("OK")
        elif path == "/simulate/whitelist":
            STATE["filter_mode"] = "Permit"
            STATE["filter_entries"] = ["02:00:5e:10:00:01"]
            self.send("OK")
        elif path == "/simulate/drop-filter-post":
            STATE["filter_drop"] = True
            self.send("OK")
        elif path == "/getpage.gch" and STATE["session_expired"]:
            self.send(TIMEOUT)
        elif path == "/getpage.gch" and self.owns_session():
            body = content(self.next_page())
            if body is None:
                self.send("Not found", status=404)
                return
            STATE["events"].append("read")
            self.send(body)
        elif path == "/" and (STATE["admin_busy"] or (STATE["active_session"] and not self.owns_session())):
            self.send(ADMIN_BUSY)
        else:
            self.send(LOGIN)

    def do_POST(self):
        if self.rebooting():
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        fields = {key: values[0] for key, values in parse_qs(data, keep_blank_values=True).items()}
        if urlsplit(self.path).path == "/" and fields.get("logout") == "1":
            STATE["logout_attempts"] += 1
            STATE["events"].append("logout")
            if not self.owns_session() or STATE["admin_busy"]:
                self.send(TIMEOUT)
                return
            if fields.get("_SESSION_TOKEN") != STATE["token"] or set(fields) != {"logout", "_SESSION_TOKEN"}:
                self.send(page("FAIL", "_SESSION_TOKEN"))
                return
            mode = STATE["logout_mode"]
            if mode == "reject":
                self.send(page("FAIL"))
                return
            if mode == "lie":
                self.send(LOGIN)  # HTTP 200/login HTML alone is not proof.
                return
            STATE["session_expired"] = True
            STATE["active_session"] = None
            STATE["logouts"] += 1
            if mode == "drop":
                self.close_connection = True
                return
            self.send(LOGIN, cookie="session=; Path=/; Max-Age=0")
            return
        if urlsplit(self.path).path == "/":
            if STATE["admin_busy"]:
                self.send(ADMIN_BUSY)
                return
            STATE["logins"] += 1
            STATE["events"].append("login")
            if fields.get("Username") == "fixture-admin" and fields.get("Password") == "fixture-password" and fields.get("Frm_Logintoken") == "42":
                STATE["session_expired"] = False
                STATE["active_session"] = "fixture-" + str(STATE["logins"])
                self.send("<html>Logged in</html>", cookie="session=" + STATE["active_session"] + "; Path=/; HttpOnly; SameSite=Strict")
            else:
                self.send(LOGIN)
            return
        if not self.owns_session():
            self.send(LOGIN)
            return
        if self.next_page() == FILTER_PAGE:
            self.filter_post(fields)
            return
        if self.next_page() == RESTART_PAGE:
            self.restart_post(fields)
            return
        if self.next_page() in (DHCP_PAGE, FORWARD_PAGE, URL_PAGE, HOSTS_PAGE):
            self.list_post(self.next_page(), fields)
            return
        if self.next_page() != WLAN_PAGE:
            self.send("Not found", status=404)
            return
        STATE["posts"] += 1
        STATE["events"].append("apply")
        if STATE["delay_apply"]:
            STATE["delay_apply"] = False
            time.sleep(0.35)
        if not STATE["token"] or fields.get("_SESSION_TOKEN") != STATE["token"] or STATE["expire_next"]:
            STATE["expire_next"] = False
            STATE["tokens_rejected"] += 1
            self.send(page("FAIL", "_SESSION_TOKEN"))
            return
        if STATE["reject"]:
            STATE["reject"] = False
            self.send(page("FAIL"))
            return
        psk = fields.get("IF_PSKTAG") == "Y"
        allowed = {"Channel", "AutoChannelEnabled", "ESSID", "Enable"}
        current_security = {"BeaconType": "WPAand11i", "WPAAuthMode": "PSKAuthentication", "11iAuthMode": "PSKAuthentication",
                            "WPAEncryptType": "AESEncryption", "11iEncryptType": "AESEncryption", "WPAGroupRekey": ""}
        if psk:
            allowed |= set(current_security)
            # Mirrors pageSetValue(): security fields carry their current values.
            if any(fields.get(key) != value for key, value in current_security.items()):
                self.send(page("FAIL"))
                return
            passphrase = fields.get("KeyPassphrase", "")
            if not 8 <= len(passphrase) <= 63 or fields.get("PreSharedKey") != "NULL":
                self.send(page("FAIL"))
                return
        elif fields.get("KeyPassphrase") != "NULL":
            self.send(page("FAIL"))
            return
        if any(fields.get(key) != "NULL" for key in CONFIG if key not in allowed) or fields.get("IF_PSKTAG") not in ("N", "Y") \
                or fields.get("IF_CONFIGTAG") != "Y" or fields.get("Enable") not in ("NULL", "1"):
            self.send(page("FAIL"))
            return
        ssid = fields.get("ESSID", "NULL")
        if ssid != "NULL" and not 1 <= len(ssid) <= 32:
            self.send(page("FAIL"))
            return
        if fields.get("AutoChannelEnabled", "NULL") != "NULL":
            STATE["auto"] = fields["AutoChannelEnabled"]
        if fields.get("Channel", "NULL") != "NULL":
            STATE["channel"] = fields["Channel"]
        if ssid != "NULL" or psk:
            STATE["credential_posts"] += 1
        if ssid != "NULL":
            STATE["ssid"] = ssid
        if psk:
            STATE["passphrase"] = passphrase
        if STATE["drop"]:
            STATE["drop"] = False
            self.close_connection = True
            return  # Simulate Wi-Fi disappearing after the change was committed.
        response = page()
        if STATE["expire_during_verification"]:
            STATE["expire_during_verification"] = False
            STATE["session_expired"] = True
            STATE["active_session"] = None
        self.send(response)


    def filter_post(self, fields):
        STATE["filter_posts"] += 1
        action = fields.get("IF_ACTION")
        STATE["events"].append("filter:" + str(action))
        if not STATE["token"] or fields.get("_SESSION_TOKEN") != STATE["token"]:
            STATE["tokens_rejected"] += 1
            self.send(filter_page("FAIL", "_SESSION_TOKEN"))
            return
        untouched = [key for key in BASIC_KEYS if key not in ("MacFilterEnable", "MacFilterTarget")]
        if action == "basic_apply":
            if any(fields.get(key) != "NULL" for key in RULE_KEYS + untouched) \
                    or fields.get("MacFilterEnable") not in ("0", "1") or fields.get("MacFilterTarget") not in ("Discard", "Permit"):
                self.send(filter_page("FAIL"))
                return
            STATE["filter_enabled"] = fields["MacFilterEnable"]
            STATE["filter_mode"] = fields["MacFilterTarget"]
        elif action == "new":
            source = fields.get("SrcMacAddr", "")
            if any(fields.get(key) != "NULL" for key in untouched + ["BlackList"]) or fields.get("IF_INDEX") != "-1" \
                    or fields.get("Enable") != "1" or fields.get("Type") != "Bridge+Route" or fields.get("Protocol") != "ALL" \
                    or fields.get("DstMacAddr") != "00:00:00:00:00:00" or not MAC.match(source) \
                    or source in STATE["filter_entries"]:
                self.send(filter_page("FAIL"))
                return
            STATE["filter_enabled"] = fields.get("MacFilterEnable", STATE["filter_enabled"])
            STATE["filter_mode"] = fields.get("MacFilterTarget", STATE["filter_mode"])
            STATE["filter_entries"].append(source)
        elif action == "delete":
            try:
                index = int(fields.get("IF_INDEX", ""))
            except ValueError:
                index = -1
            if not 0 <= index < len(STATE["filter_entries"]):
                self.send(filter_page("FAIL"))
                return
            STATE["filter_entries"].pop(index)
        else:
            self.send(filter_page("FAIL"))
            return
        if STATE["filter_drop"]:
            STATE["filter_drop"] = False
            self.close_connection = True
            return  # The change committed but the response was lost.
        self.send(filter_page())

    def list_post(self, page_name, fields):
        STATE["list_posts"] += 1
        action = fields.get("IF_ACTION")
        STATE["events"].append(f"{page_name}:{action}")
        render = {DHCP_PAGE: dhcp_page, FORWARD_PAGE: forward_page, URL_PAGE: url_page, HOSTS_PAGE: hosts_page}[page_name]
        if not STATE["token"] or fields.get("_SESSION_TOKEN") != STATE["token"]:
            STATE["tokens_rejected"] += 1
            self.send(render("FAIL"))
            return
        ok = False
        if page_name == DHCP_PAGE and action == "new":
            ip, mac = fields.get("IPAddr", ""), fields.get("MACAddr", "")
            ok = (fields.get("ViewName") == "NULL" and fields.get("HostCfgViewName") == "NULL" and fields.get("IF_INDEX") == "-1"
                  and in_pool(ip) and MAC.match(mac) and all(ip != r[0] and mac != r[1] for r in STATE["reservations"]))
            if ok:
                STATE["reservations"].append((ip, mac))
        elif page_name == FORWARD_PAGE and action == "new":
            rule = {key: fields.get(key, "") for key in FORWARD_RULE}
            ok = (all(fields.get(key) == "NULL" for key in FORWARD_OTHER if key != "MaxIntPort") and fields.get("IF_INDEX") == "-1"
                  and rule["Enable"] in ("0", "1") and 1 <= len(rule["Name"]) <= 32 and rule["Protocol"] in ("0", "1", "2")
                  and rule["WANCViewName"] == "IGD.WD1.WCD1.WCPPP1" and rule["MacEnable"] == "0" and rule["InternalMacHost"] == "NULL"
                  and rule["MinRemoteHost"] == "0.0.0.0" and rule["MaxRemoteHost"] == "0.0.0.0" and IPV4.match(rule["InternalHost"])
                  and rule["MaxIntPort"] == rule["MinIntPort"] and int(rule["MinExtPort"] or 0) <= int(rule["MaxExtPort"] or 0)
                  and all(r["Name"] != rule["Name"] for r in STATE["forwards"]))
            if ok:
                STATE["forwards"].append(rule)
        elif page_name == URL_PAGE and action == "basic_apply":
            ok = (all(fields.get(key) == "NULL" for key in URL_BASIC if key not in ("UrlFilterEnable", "UrlFilterTarget"))
                  and fields.get("UrlFilterEnable") in ("0", "1") and fields.get("UrlFilterTarget") in ("0", "1"))
            if ok:
                STATE["url_enabled"], STATE["url_mode"] = fields["UrlFilterEnable"], fields["UrlFilterTarget"]
        elif page_name == URL_PAGE and action == "new":
            url = fields.get("Url", "")
            ok = (fields.get("ViewName") == "NULL" and fields.get("Enable") == "0" and fields.get("FilterTarget") == "0"
                  and fields.get("IF_INDEX") == "-1" and 1 <= len(url) <= 256 and url not in STATE["urls"])
            if ok:
                STATE["urls"].append(url)
        elif page_name == HOSTS_PAGE and action == "new":
            name, ip = fields.get("HostName", ""), fields.get("IPAddress", "")
            ok = (fields.get("IF_INDEX") == "-1" and re.match(r"^[0-9a-z][0-9a-z_.-]*[0-9a-z]$", name) is not None
                  and IPV4.match(ip) is not None and len(STATE["hosts"]) < 50 and all(name != h[0] for h in STATE["hosts"]))
            if ok:
                STATE["hosts"].append((name, ip))
        elif action == "delete":
            entries = {DHCP_PAGE: STATE["reservations"], FORWARD_PAGE: STATE["forwards"], URL_PAGE: STATE["urls"],
                       HOSTS_PAGE: STATE["hosts"]}[page_name]
            try:
                index = int(fields.get("IF_INDEX", ""))
            except ValueError:
                index = -1
            ok = 0 <= index < len(entries)
            if ok:
                entries.pop(index)
        self.send(render("SUCC" if ok else "FAIL"))

    def restart_post(self, fields):
        STATE["events"].append("restart")
        if not STATE["token"] or fields.get("_SESSION_TOKEN") != STATE["token"]:
            STATE["tokens_rejected"] += 1
            self.send(restart_page(error="FAIL", parameter="_SESSION_TOKEN"))
            return
        if fields.get("IF_ACTION") != "devrestart" or fields.get("flag") != "1":
            self.send(restart_page(error="FAIL"))
            return
        STATE["restarts"] += 1
        response = restart_page(flag="1")
        STATE["session_expired"] = True
        STATE["active_session"] = None
        STATE["reboot_until"] = time.time() + 0.2 + STATE["reboot_seconds"]
        self.send(response)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18742)
    args = parser.parse_args()
    reset()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Router)
    print(f"http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
