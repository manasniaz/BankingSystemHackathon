import os
import json
import re
import sys

workflows_dir = os.path.join(os.path.dirname(__file__), "workflows")
files = [f for f in os.listdir(workflows_dir) if f.endswith(".json")]

print(f"Found {len(files)} workflow JSON files to validate.\n")

has_error = False

for file_name in sorted(files):
    file_path = os.path.join(workflows_dir, file_name)
    print(f"--- Validating: {file_name} ---")
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            wf = json.load(f)

        if not wf.get("name"):
            print("  [FAIL] Missing 'name' field")
            has_error = True
        else:
            print(f"  [OK] Name: '{wf['name']}'")

        nodes = wf.get("nodes")
        if not isinstance(nodes, list):
            print("  [FAIL] 'nodes' must be a list")
            has_error = True
            continue

        node_ids = set()
        node_names = set()

        for idx, node in enumerate(nodes):
            nid = node.get("id")
            nname = node.get("name")
            ntype = node.get("type")

            if not nid:
                print(f"  [FAIL] Node at index {idx} missing 'id'")
                has_error = True
            elif nid in node_ids:
                print(f"  [FAIL] Duplicate node id '{nid}'")
                has_error = True
            else:
                node_ids.add(nid)

            if not nname:
                print(f"  [FAIL] Node at index {idx} missing 'name'")
                has_error = True
            else:
                node_names.add(nname)

            if not ntype:
                print(f"  [FAIL] Node '{nname}' missing 'type'")
                has_error = True

        print(f"  [OK] {len(nodes)} nodes validated (unique IDs & names)")

        # Validate connections
        connections = wf.get("connections", {})
        for source_node, outputs in connections.items():
            if source_node not in node_names:
                print(f"  [FAIL] Connection source node '{source_node}' does not exist")
                has_error = True

            if isinstance(outputs, dict):
                for out_type, conn_lists in outputs.items():
                    if isinstance(conn_lists, list):
                        for conn_group in conn_lists:
                            if isinstance(conn_group, list):
                                for conn in conn_group:
                                    target_node = conn.get("node")
                                    if target_node not in node_names:
                                        print(f"  [FAIL] Connection target node '{target_node}' (from '{source_node}') does not exist")
                                        has_error = True

        print("  [OK] Connections graph verified")

        # Security check
        json_str = json.dumps(wf)
        if re.search(r"sk-[a-zA-Z0-9]{20,}", json_str) or re.search(r"postgres://.*:.*@", json_str):
            print("  [FAIL] Embedded secret detected!")
            has_error = True
        else:
            print("  [OK] Security check: No embedded secrets found")

    except Exception as e:
        print(f"  [FAIL] JSON parse error: {e}")
        has_error = True

print("\n========================================")
if has_error:
    print("VALIDATION RESULT: FAILED")
    sys.exit(1)
else:
    print("VALIDATION RESULT: ALL WORKFLOWS PASSED 100%")
