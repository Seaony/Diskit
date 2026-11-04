"""限制生成应用的 HTTP 例外只覆盖本地网络。"""
import ipaddress
import plistlib
import unittest
from pathlib import Path


class LocalNetworkPolicyTests(unittest.TestCase):
    def test_generated_app_preserves_public_transport_security(self):
        root = Path(__file__).resolve().parents[2]
        with (root / "build" / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        ats = info["NSAppTransportSecurity"]
        self.assertTrue(ats["NSAllowsLocalNetworking"])
        for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent",
                    "NSAllowsArbitraryLoadsForMedia"):
            self.assertFalse(ats.get(key, False))
        exceptions = ats["NSExceptionDomains"]
        self.assertEqual(set(exceptions), {
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
            "169.254.0.0/16", "fc00::/7", "fe80::/10", "::1",
        })
        for host, settings in exceptions.items():
            network = ipaddress.ip_network(host)
            self.assertFalse(network.is_global)
            self.assertEqual(settings, {"NSExceptionAllowsInsecureHTTPLoads": True})
        for host in ("8.8.8.8", "1.1.1.1", "2001:4860:4860::8888"):
            address = ipaddress.ip_address(host)
            self.assertFalse(any(address in ipaddress.ip_network(network) for network in exceptions))
