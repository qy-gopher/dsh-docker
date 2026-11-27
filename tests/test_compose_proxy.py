"""Check deployment proxy precedence without starting or building containers."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
PROXY_VARIABLES = (
    "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy",
)


@unittest.skipUnless(shutil.which("docker"), "Docker CLI is required to render Compose")
class ComposeProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["docker", "compose", "version"], capture_output=True, text=True, timeout=15
        )
        if result.returncode:
            raise unittest.SkipTest("Docker Compose is not available")

    def render(self, proxy):
        with tempfile.TemporaryDirectory(prefix="dsh-compose-proxy-test-") as directory:
            deployment = Path(directory)
            shutil.copyfile(REPOSITORY / "compose.yaml", deployment / "compose.yaml")
            expected = {key: proxy for key in PROXY_VARIABLES}
            expected.update({
                "NO_PROXY": "localhost,127.0.0.1,::1",
                "no_proxy": "localhost,127.0.0.1,::1",
                "NODE_USE_ENV_PROXY": "1",
            })
            (deployment / ".env").write_text(
                "\n".join(f"{key}={value}" for key, value in expected.items()) + "\n"
            )
            environment = dict(os.environ, DEEPSEEK_API_KEY="", NODE_USE_ENV_PROXY="0")
            environment.update({key: "http://127.0.0.1:7890" for key in PROXY_VARIABLES})
            environment.update(NO_PROXY="*", no_proxy="*")
            result = subprocess.run(
                ["docker", "compose", "--env-file", str(deployment / ".env"),
                 "-f", str(deployment / "compose.yaml"), "config", "--format", "json"],
                cwd=deployment,
                env=environment,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            actual = json.loads(result.stdout)["services"]["dsh"]["environment"]
            return expected, {key: actual.get(key) for key in expected}

    def test_env_file_proxy_overrides_host_shell_proxy(self):
        expected, actual = self.render("http://deployment-proxy.example:8080")
        self.assertEqual(expected, actual)

    def test_empty_env_file_proxy_disables_host_shell_proxy(self):
        expected, actual = self.render("")
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
