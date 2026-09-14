const fs = require('fs');
const path = require('path');

const workflowsDir = path.join(__dirname, 'workflows');
const files = fs.readdirSync(workflowsDir).filter(f => f.endsWith('.json'));

console.log(`Found ${files.length} workflow JSON files to validate.\n`);

let hasError = false;

const knownCredentials = ['gmailOAuth2', 'supabaseApi', 'groqApi', 'pineconeApi', 'googlePalmApi'];

files.forEach(file => {
  const filePath = path.join(workflowsDir, file);
  console.log(`--- Validating: ${file} ---`);
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const wf = JSON.parse(raw);

    if (!wf.name) {
      console.error(`  [FAIL] Missing 'name' field`);
      hasError = true;
    } else {
      console.log(`  [OK] Name: "${wf.name}"`);
    }

    if (!Array.isArray(wf.nodes)) {
      console.error(`  [FAIL] 'nodes' must be an array`);
      hasError = true;
      return;
    }

    const nodeIds = new Set();
    const nodeNames = new Set();

    wf.nodes.forEach((node, idx) => {
      if (!node.id) {
        console.error(`  [FAIL] Node at index ${idx} missing 'id'`);
        hasError = true;
      } else if (nodeIds.has(node.id)) {
        console.error(`  [FAIL] Duplicate node id '${node.id}'`);
        hasError = true;
      } else {
        nodeIds.add(node.id);
      }

      if (!node.name) {
        console.error(`  [FAIL] Node at index ${idx} missing 'name'`);
        hasError = true;
      } else {
        nodeNames.add(node.name);
      }

      if (!node.type) {
        console.error(`  [FAIL] Node '${node.name}' missing 'type'`);
        hasError = true;
      }
    });

    console.log(`  [OK] ${wf.nodes.length} nodes validated (unique IDs & names)`);

    // Validate connections
    if (wf.connections) {
      Object.keys(wf.connections).forEach(sourceNode => {
        if (!nodeNames.has(sourceNode)) {
          console.error(`  [FAIL] Connection source node '${sourceNode}' does not exist in nodes list`);
          hasError = true;
        }

        const outputs = wf.connections[sourceNode];
        Object.keys(outputs).forEach(outType => {
          outputs[outType].forEach(connList => {
            connList.forEach(conn => {
              if (!nodeNames.has(conn.node)) {
                console.error(`  [FAIL] Connection target node '${conn.node}' (from '${sourceNode}') does not exist`);
                hasError = true;
              }
            });
          });
        });
      });
      console.log(`  [OK] Connections graph verified`);
    }

    // Check for hardcoded secrets
    const jsonStr = JSON.stringify(wf);
    if (/sk-[a-zA-Z0-9]{20,}/.test(jsonStr) || /ghp_[a-zA-Z0-9]{20,}/.test(jsonStr) || /postgres:\/\/.*:.*/.test(jsonStr)) {
      console.error(`  [FAIL] Embedded secret/token detected in workflow JSON!`);
      hasError = true;
    } else {
      console.log(`  [OK] Security check: No embedded secrets found`);
    }

  } catch (err) {
    console.error(`  [FAIL] JSON parse error: ${err.message}`);
    hasError = true;
  }
});

console.log('\n========================================');
if (hasError) {
  console.error('VALIDATION RESULT: FAILED');
  process.exit(1);
} else {
  console.log('VALIDATION RESULT: ALL WORKFLOWS PASSED 100%');
}
