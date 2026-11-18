from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from check_packages import PACKAGE_MODELS, boot, check


class PackageSetupTests(unittest.TestCase):
    def test_archive_missing_declared_setup_tab_fails_even_with_html_present(self):
        with TemporaryDirectory() as directory:
            folder = Path(directory)
            for name, model in PACKAGE_MODELS.items():
                with ZipFile(folder / name, "w") as package:
                    package.writestr("driver.xml", f"<devicedata><model>{model}</model><capabilities/><config/></devicedata>")
                    package.writestr("www/html/index.html", "<main>Device Setup</main>")
            with self.assertRaisesRegex(ValueError, "expected a Device Setup tab"):
                check(folder)

    def test_package_boot_requires_a_writable_property_from_the_archived_xml(self):
        xml = ET.fromstring("""<devicedata><model>HA Light</model><config><properties>
            <property><name>Manual entity ID</name><type>STRING</type></property>
            </properties></config></devicedata>""")
        runtime = """
JSON = dofile('vendor/JSON.lua')
function OnDriverInit() end
function OnDriverLateInit() Properties['Driver Status'] = 'Not configured' end
function UIRequest(command)
  assert(command == '_GET_PROPERTIES')
  local config = C4:GetDriverConfigInfo('config')
  local fields = {}
  if config:find('<name>Manual entity ID</name>', 1, true) then
    fields[1] = { name = 'Manual entity ID', readonly = false }
  end
  C4:SendDataToUI('PROPERTIES', {json = JSON:encode({properties = fields})})
end
"""
        boot(runtime, xml, "3.3.0", exercise_controls=False)
        xml.find("config/properties/property/name").text = "Unrelated field"
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            boot(runtime, xml, "3.3.0", exercise_controls=False)
        self.assertIn("did not return its writable manual device field", failure.exception.stderr)


if __name__ == "__main__":
    unittest.main()
