# Reading Test & Build Results

## Build errors and warnings — use MCP

`GetBuildLog` is the primary tool for inspecting build output. No CLI needed:
```
mcp_xcode_GetBuildLog(
  tabIdentifier: "<tab>",
  severity: "error"
)

// Filter to a specific file or directory:
mcp_xcode_GetBuildLog(
  tabIdentifier: "<tab>",
  severity: "warning",
  glob: "**/MyFeature/**"
)

// Filter by message content:
mcp_xcode_GetBuildLog(
  tabIdentifier: "<tab>",
  severity: "error",
  pattern: "cannot find type|undeclared identifier"
)
```

---

## Per-test pass/fail results — xcresult (CLI)

MCP has no xcresult tool. After a CLI `xcodebuild test` run, parse the result:

```bash
# The DerivedData folder is named after the package (e.g., Modules-<hash>),
# NOT after the workspace. Using the wrong folder returns empty summaries.
XCRESULT=$(ls -t ~/Library/Developer/Xcode/DerivedData/Modules-*/Logs/Test/*.xcresult \
  2>/dev/null | head -1)

# Step 1: get testsRef
xcrun xcresulttool get object --legacy --format json \
  --path "$XCRESULT" > /tmp/summary.json
TESTS_REF=$(python3 -c "
import json
d = json.load(open('/tmp/summary.json'))
print(d['actions']['_values'][-1]['actionResult']['testsRef']['id']['_value'])
")

# Step 2: fetch and walk all tests
xcrun xcresulttool get object --legacy --format json \
  --path "$XCRESULT" --id "$TESTS_REF" > /tmp/tests.json

python3 -c "
import json
d = json.load(open('/tmp/tests.json'))

def walk(node, depth=0):
    name = node.get('name', {}).get('_value', '')
    status = node.get('testStatus', {}).get('_value', '')
    if name:
        print(f'{\"  \"*depth}{status or \"GROUP\"}: {name}')
    for sub in node.get('subtests', {}).get('_values', []):
        walk(sub, depth+1)

for grp in d.get('summaries', {}).get('_values', []):
    for tg in grp.get('testableSummaries', {}).get('_values', []):
        for t in tg.get('tests', {}).get('_values', []):
            walk(t)
"
```

⚠️ Always use `--legacy`; omitting it returns a different schema with missing fields.  
⚠️ Always use the `Modules-<hash>` DerivedData folder — **not** the workspace folder. The workspace folder returns empty `ActionTestPlanRunSummaries`.
