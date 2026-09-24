import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const FIXTURES = join(REPO_ROOT, "test", "fixtures", "insert");
const CASES = ["NATURAL_UNITS", "COMPONENT_BASE"];

// Golden fixtures are generated on the fly and gitignored. Without a
// power-openapi-models checkout generation fails; golden tests then skip.
export default function setup(): void {
  const missing = CASES.some((c) => !existsSync(join(FIXTURES, `case14_${c}.json`)));
  if (!missing) {
    return;
  }
  try {
    execFileSync("python3", [join(REPO_ROOT, "test", "prepare_fixtures.py")], {
      stdio: "inherit",
    });
  } catch {
    console.warn("golden fixture generation failed; golden-dependent tests will skip");
  }
}
