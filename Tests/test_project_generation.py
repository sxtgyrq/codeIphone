"""Generator/configuration checks only; these do not compile or run iOS code."""
import contextlib
import importlib.util
import io
import ipaddress
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET


REPOSITORY = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("generate_project", REPOSITORY / "tools" / "generate_project.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class ProjectGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.old_root = generator.ROOT
        generator.ROOT = self.root
        for name in ("HelloYrq/HelloYrqApp.swift", "HelloYrq/MapAPI.swift", "HelloYrq/Models/MapModels.swift",
                     "HelloYrqTests/MapAPITests.swift", "HelloYrqUITests/HelloYrqUITests.swift"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// Fixture source for generator verification.\n", encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            generator.main()

    def tearDown(self):
        generator.ROOT = self.old_root
        self.temporary.cleanup()

    def object(self, name):
        return generator.objects[generator.oid(name)]

    def test_discovers_all_swift_sources_once_and_keeps_test_code_out_of_app(self):
        for key, expected in (("app", {"HelloYrqApp.swift", "MapAPI.swift", "Models/MapModels.swift"}),
                              ("unit", {"MapAPITests.swift"}), ("test", {"HelloYrqUITests.swift"})):
            phase = self.object(key + "/sources")
            paths = [generator.objects[generator.objects[build]["fileRef"]]["path"] for build in phase["files"]]
            self.assertEqual(set(paths), expected)
            self.assertEqual(len(paths), len(expected))
        app_settings = self.object("app/Debug")["buildSettings"]
        self.assertEqual(app_settings["ASSETCATALOG_COMPILER_APPICON_NAME"], "AppIcon")
        self.assertEqual(app_settings["CODE_SIGN_STYLE"], "Automatic")
        self.assertEqual(self.object("project/Debug")["buildSettings"]["IPHONEOS_DEPLOYMENT_TARGET"], "16.0")

    def test_unit_target_has_host_dependency_and_scheme_runs_both_test_bundles(self):
        app_id = generator.oid("app/target")
        unit = self.object("unit/target")
        self.assertEqual(unit["productType"], "com.apple.product-type.bundle.unit-test")
        dependency = generator.objects[unit["dependencies"][0]]
        self.assertEqual(dependency["target"], app_id)
        settings = self.object("unit/Debug")["buildSettings"]
        self.assertEqual(settings["BUNDLE_LOADER"], "$(TEST_HOST)")
        self.assertEqual(settings["TEST_HOST"], "$(BUILT_PRODUCTS_DIR)/HelloYrq.app/HelloYrq")
        scheme = ET.parse(self.root / "HelloYrq.xcodeproj/xcshareddata/xcschemes/HelloYrq.xcscheme")
        testables = scheme.findall("./TestAction/Testables/TestableReference/BuildableReference")
        self.assertEqual({entry.attrib["BlueprintName"] for entry in testables}, {"HelloYrqTests", "HelloYrqUITests"})
        self.assertEqual({entry.attrib["BlueprintIdentifier"] for entry in testables},
                         {generator.oid("unit/target"), generator.oid("test/target")})

    def test_network_usage_text_and_ipv4_exceptions_do_not_disable_public_ats(self):
        with (self.root / "HelloYrq/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertEqual(info["CFBundleDisplayName"], "Argument Map")
        self.assertIn("ArgumentMap Server", info["NSLocalNetworkUsageDescription"])
        ats = info["NSAppTransportSecurity"]
        self.assertTrue(ats["NSAllowsLocalNetworking"])
        self.assertNotIn("NSAllowsArbitraryLoads", ats)
        networks = [ipaddress.ip_network(key) for key in ats["NSExceptionDomains"]]
        for address in ("192.168.1.10", "172.16.4.5", "172.31.255.254", "10.2.3.4", "169.254.1.2"):
            self.assertTrue(any(ipaddress.ip_address(address) in network for network in networks), address)
        for address in ("8.8.8.8", "172.15.1.1", "172.32.1.1", "192.169.1.1"):
            self.assertFalse(any(ipaddress.ip_address(address) in network for network in networks), address)
        for exception in ats["NSExceptionDomains"].values():
            self.assertEqual(exception, {"NSExceptionAllowsInsecureHTTPLoads": True})

    def test_repeated_generation_is_deterministic_and_removes_deleted_source_references(self):
        project = self.root / "HelloYrq.xcodeproj/project.pbxproj"
        before = project.read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):
            generator.main()
        self.assertEqual(before, project.read_bytes())
        (self.root / "HelloYrq/MapAPI.swift").unlink()
        with contextlib.redirect_stdout(io.StringIO()):
            generator.main()
        self.assertNotIn("MapAPI.swift", project.read_text(encoding="utf-8"))
        self.assertNotIn(generator.oid("app/source/MapAPI.swift"), generator.objects)


if __name__ == "__main__":
    unittest.main()
