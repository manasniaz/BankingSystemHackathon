import os
import json
import re
import sys

def is_placeholder_domain(domain, allowed):
    """True for a domain that cannot belong to anyone.

    `.example` is reserved by RFC 2606 for exactly this purpose, so any domain
    under it is safe without being enumerated -- which stops the allowlist
    growing a new entry every time an example needs a new name.
    """
    d = domain.lower().rstrip(".")
    return d in allowed or d == "example" or d.endswith(".example")


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

        # A node whose only predecessors are Gmail nodes sees the Gmail SEND
        # RESPONSE in $json -- {id, threadId, labelIds} -- not the upstream
        # business data. Every other field silently renders blank, and every
        # amount renders NaN, in an email that otherwise looks fine. This has
        # happened four times; the fix is always $('Producing Node').item.json.
        SEND_RESPONSE_FIELDS = {"id", "threadId", "labelIds"}
        predecessors = {}
        for source_node, outputs in connections.items():
            if not isinstance(outputs, dict):
                continue
            for conn_group in outputs.get("main", []) or []:
                for conn in conn_group or []:
                    predecessors.setdefault(conn.get("node"), []).append(source_node)

        nodes_by_name = {n.get("name"): n for n in nodes}
        stale_json = False
        for nname, node in nodes_by_name.items():
            preds = predecessors.get(nname, [])
            if not preds:
                continue
            if not all(nodes_by_name.get(p, {}).get("type", "").endswith(".gmail")
                       for p in preds):
                continue
            used = set(re.findall(r"\$json\.([A-Za-z_][A-Za-z0-9_]*)",
                                  json.dumps(node.get("parameters", {}))))
            leaked = sorted(used - SEND_RESPONSE_FIELDS)
            if leaked:
                print(f"  [FAIL] '{nname}' follows a Gmail node but reads "
                      f"$json.{', $json.'.join(leaked)} -- those will be blank/NaN. "
                      f"Reference the node that produced them instead.")
                has_error = True
                stale_json = True

        if not stale_json:
            print("  [OK] No node reads business data from a Gmail send response")

        # Security check
        json_str = json.dumps(wf)
        if re.search(r"sk-[a-zA-Z0-9]{20,}", json_str) or re.search(r"postgres://.*:.*@", json_str):
            print("  [FAIL] Embedded secret detected!")
            has_error = True
        else:
            print("  [OK] Security check: No embedded secrets found")

        # This repository is public and the live system runs on real mailboxes.
        # Every address here must be a reserved placeholder. A real customer's
        # address once reached a code comment by being copied back from the live
        # copy, which is exactly the path a checked-in secret takes.
        PLACEHOLDER_DOMAINS = {
            "example.com", "example.org", "example.net",
            "yourbank.example", "test.banking",
            "invalid.internal", "invalid.local",
        }
        real_addresses = sorted({
            addr for addr, domain in
            re.findall(r"([A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,}))", json_str)
            if not is_placeholder_domain(domain, PLACEHOLDER_DOMAINS)
        })
        if real_addresses:
            print(f"  [FAIL] Non-placeholder email address(es): {', '.join(real_addresses)}")
            print("         Live addresses belong in n8n, not in this repository.")
            has_error = True
        else:
            print("  [OK] Every email address is a reserved placeholder")

        # Control characters that look like regex escapes but are not. A shell
        # heredoc once turned \b word boundaries into literal backspaces, which
        # silently makes a pattern match nothing.
        stray = sorted({repr(c) for c in json_str if c in "\x07\x08\x0b\x0c"})
        if stray:
            print(f"  [FAIL] Stray control character(s) in node code: {', '.join(stray)}")
            has_error = True

    except Exception as e:
        print(f"  [FAIL] JSON parse error: {e}")
        has_error = True

# --------------------------------------------------------------------------
# Repository-wide address scan.
#
# A real customer's address has reached this repository twice: once in a node
# comment carried back from the live copy, once in a docs paragraph written
# while explaining something else. Both times it was caught by grep afterwards
# rather than by anything that runs. The live system uses real mailboxes and
# this repository is public, so the check belongs here, covering everything.
# --------------------------------------------------------------------------
PLACEHOLDER_DOMAINS = {
    "example.com", "example.org", "example.net",
    "yourbank.example", "test.banking",
    "invalid.internal", "invalid.local",
    # Named in the automated-sender filter, and deliberately quoted in docs.
    "accounts.google.com", "google.com", "googlemail.com.invalid",
    "amazonses.com", "sendgrid.net", "mailgun.org",
    "noreply.anthropic.com",
}
SCAN_EXTS = (".md", ".py", ".sql", ".json", ".txt", ".yml", ".yaml")
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv"}

repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
addr_re = re.compile(r"([A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,}))")
leaks = {}

for dirpath, dirnames, filenames in os.walk(repo_root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if not fn.endswith(SCAN_EXTS):
            continue
        full = os.path.join(dirpath, fn)
        try:
            with open(full, "r", encoding="utf-8") as fh:
                content = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        for addr, domain in addr_re.findall(content):
            if not is_placeholder_domain(domain, PLACEHOLDER_DOMAINS):
                leaks.setdefault(os.path.relpath(full, repo_root), set()).add(addr)

print("\n--- Repository-wide address scan ---")
if leaks:
    for path in sorted(leaks):
        print(f"  [FAIL] {path}: {', '.join(sorted(leaks[path]))}")
    print("         Real addresses belong in n8n and Supabase, not in this repository.")
    has_error = True
else:
    print("  [OK] No real email addresses committed anywhere in the repository")

print("\n========================================")
if has_error:
    print("VALIDATION RESULT: FAILED")
    sys.exit(1)
else:
    print("VALIDATION RESULT: ALL WORKFLOWS PASSED 100%")
