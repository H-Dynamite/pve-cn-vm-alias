#!/usr/bin/env bash
set -Eeuo pipefail

# Tested target:
#   pve-manager 9.2.2 (b9984c6d90a4bd80)
#
# Behavior:
#   Keep the DNS-compatible VM/CT name unchanged.
#   Show the decoded first description line as the resource-tree alias.
#
# The default PVE paths can be overridden for testing:
#   CLUSTER_PM=/path/to/Cluster.pm
#   PVE_JS=/path/to/pvemanagerlib.js
#   BACKUP_ROOT=/path/to/backup/root

CLUSTER_PM="${CLUSTER_PM:-/usr/share/perl5/PVE/API2/Cluster.pm}"
PVE_JS="${PVE_JS:-/usr/share/pve-manager/js/pvemanagerlib.js}"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT%/}/pve-cn-alias-backup-${STAMP}"
RESTORED=0

die() {
    echo "ERROR: $*" >&2
    exit 1
}

restore_originals() {
    if [[ "$RESTORED" -eq 0 && -d "$BACKUP_DIR" ]]; then
        echo "Restoring original files from $BACKUP_DIR ..." >&2
        cp -a "$BACKUP_DIR/Cluster.pm" "$CLUSTER_PM"
        cp -a "$BACKUP_DIR/pvemanagerlib.js" "$PVE_JS"
        systemctl restart pvedaemon pveproxy || true
        RESTORED=1
    fi
}

on_error() {
    local exit_code=$?
    echo "Patch or functional verification failed." >&2
    restore_originals
    echo "The original files have been restored." >&2
    exit "$exit_code"
}

trap on_error ERR

[[ "$(id -u)" -eq 0 ]] || die "Please run this script as root."
[[ -f "$CLUSTER_PM" ]] || die "Missing $CLUSTER_PM"
[[ -f "$PVE_JS" ]] || die "Missing $PVE_JS"
command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v perl >/dev/null 2>&1 || die "perl is required."
command -v pvesh >/dev/null 2>&1 || die "pvesh is required."

PVE_MANAGER_VERSION="$(
    pveversion --verbose 2>/dev/null |
        awk -F': ' '$1 == "pve-manager" { print $2; exit }'
)"
[[ -n "$PVE_MANAGER_VERSION" ]] || die "Could not determine the pve-manager version."

if grep -qF "First line of the guest description" "$CLUSTER_PM" ||
    grep -qF "let displayName = info.description || info.name;" "$PVE_JS"; then
    die "The alias patch appears to be installed already. No files were changed."
fi

mkdir -p "$BACKUP_DIR"
cp -a "$CLUSTER_PM" "$BACKUP_DIR/Cluster.pm"
cp -a "$PVE_JS" "$BACKUP_DIR/pvemanagerlib.js"
printf '%s\n' "$PVE_MANAGER_VERSION" >"$BACKUP_DIR/pve-manager-version.txt"

# Build the expected VMID/description map before changing PVE. PVE 9 writes
# each description line as an URI-encoded leading #comment. The map lets the
# post-install test verify real data instead of only checking syntax.
EXPECTED_NOTES="$BACKUP_DIR/expected-notes.json"
python3 - "$EXPECTED_NOTES" <<'PY'
from pathlib import Path
from urllib.parse import unquote
import glob
import json
import re
import sys

expected = []
patterns = (
    ("/etc/pve/nodes/*/qemu-server/*.conf", "qemu"),
    ("/etc/pve/nodes/*/lxc/*.conf", "lxc"),
)
for pattern, guest_type in patterns:
    for filename in glob.glob(pattern):
        path = Path(filename)
        match = re.fullmatch(r"(\d+)\.conf", path.name)
        if not match:
            continue
        try:
            firstline = path.open("r", encoding="utf-8").readline().rstrip("\r\n")
        except (OSError, UnicodeError):
            continue
        if not firstline.startswith("#"):
            continue
        try:
            description = unquote(firstline[1:], encoding="utf-8", errors="strict")
        except UnicodeError:
            continue
        if description:
            expected.append(
                {
                    "vmid": int(match.group(1)),
                    "type": guest_type,
                    "description": description,
                }
            )

Path(sys.argv[1]).write_text(
    json.dumps(expected, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
print(f"Found {len(expected)} guest(s) with a description for functional verification.")
PY

python3 - "$CLUSTER_PM" "$PVE_JS" <<'PY'
from pathlib import Path
import sys

cluster_path = Path(sys.argv[1])
js_path = Path(sys.argv[2])
cluster = cluster_path.read_text(encoding="utf-8")
js = js_path.read_text(encoding="utf-8")

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)

# Declare description in the /cluster/resources response schema.
schema_marker = """                name => {
                    description => "Name of the resource.",
                    type => 'string',
                    optional => 1,
                },
"""
schema_replacement = """                description => {
                    description =>
                        "First line of the guest description (for types 'qemu' and 'lxc').",
                    type => 'string',
                    optional => 1,
                },
""" + schema_marker

resources_start = cluster.find("name => 'resources',")
resources_code = cluster.find("    code => sub {", resources_start)
if resources_start < 0 or resources_code < 0:
    raise SystemExit("Could not locate the /cluster/resources method")
resources_schema = cluster[resources_start:resources_code]
resources_schema = replace_once(
    resources_schema,
    schema_marker,
    schema_replacement,
    "/cluster/resources schema",
)
cluster = cluster[:resources_start] + resources_schema + cluster[resources_code:]

# Read the first encoded #comment line only after VM.Audit permission has been
# checked. PVE 9.2.2 writes every description line as an encoded leading
# comment; decode_text() is the matching native decoder. Including the node in
# the path also works when /cluster/resources contains guests on other nodes.
permission_marker = """                next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);

                for my $prop (@$prop_list) {
"""
permission_replacement = """                next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1);

                my $guest_config_dir =
                    $entry->{type} eq 'lxc' ? 'lxc' : 'qemu-server';
                my $guest_config_path =
                    "/etc/pve/nodes/$entry->{node}/$guest_config_dir/$vmid.conf";
                if (
                    my $firstline =
                        eval { PVE::Tools::file_read_firstline($guest_config_path) }
                ) {
                    if ($firstline =~ /^#(.*)$/) {
                        $entry->{description} = PVE::Tools::decode_text($1);
                    }
                }

                for my $prop (@$prop_list) {
"""
cluster = replace_once(
    cluster,
    permission_marker,
    permission_replacement,
    "guest description reader",
)

# Register the API field in ResourceStore.
resource_store_start = js.find("Ext.define('PVE.data.ResourceStore'")
resource_store_end = js.find("\nExt.define(", resource_store_start + 1)
if resource_store_start < 0 or resource_store_end < 0:
    raise SystemExit("Could not locate PVE.data.ResourceStore")
resource_store = js[resource_store_start:resource_store_end]

name_field = """            name: {
                header: gettext('Name'),
                hidden: true,
                sortable: true,
                type: 'string',
            },
"""
description_field = """            description: {
                header: gettext('Description'),
                hidden: true,
                sortable: true,
                type: 'string',
            },
"""
resource_store = replace_once(
    resource_store,
    name_field,
    description_field + name_field,
    "ResourceStore description field",
)

# VMID-first resource-tree label.
old_default_label = """                        if (info.name) {
                            text += ' (' + info.name + ')';
                        }
"""
new_default_label = """                        let displayName = info.description || info.name;
                        if (displayName) {
                            displayName = String(displayName).split('\\n')[0];
                            text += ' (' + Ext.htmlEncode(displayName) + ')';
                        }
"""
resource_store = replace_once(
    resource_store,
    old_default_label,
    new_default_label,
    "VMID-first resource label",
)
js = js[:resource_store_start] + resource_store + js[resource_store_end:]

# Name-first resource-tree label. This renderer overrides ResourceStore.text.
old_name_first_label = """                        text = `${info.name} (${String(info.vmid)})`;
"""
new_name_first_label = """                        let displayName = info.description || info.name || '';
                        displayName = Ext.htmlEncode(String(displayName).split('\\n')[0]);
                        text = `${displayName} (${String(info.vmid)})`;
"""
js = replace_once(
    js,
    old_name_first_label,
    new_name_first_label,
    "name-first resource label",
)

# Final static invariants.
required_cluster = [
    "PVE::Tools::file_read_firstline($guest_config_path)",
    "PVE::Tools::decode_text($1)",
    "First line of the guest description",
]
required_js = [
    "let displayName = info.description || info.name;",
    "let displayName = info.description || info.name || '';",
]
for marker in required_cluster:
    if cluster.count(marker) != 1:
        raise SystemExit(f"Unexpected backend marker count: {marker}")
for marker in required_js:
    if js.count(marker) != 1:
        raise SystemExit(f"Unexpected frontend marker count: {marker}")
if js.count(description_field) != 1:
    raise SystemExit("Unexpected ResourceStore description field count")

cluster_path.write_text(cluster, encoding="utf-8")
js_path.write_text(js, encoding="utf-8")
PY

perl -c "$CLUSTER_PM"

# Only use the installed node for validation if it can parse the unmodified
# PVE 9.2.2 bundle. Older node versions reject syntax already used upstream.
if command -v node >/dev/null 2>&1 &&
    node --check "$BACKUP_DIR/pvemanagerlib.js" >/dev/null 2>&1; then
    node --check "$PVE_JS"
else
    echo "INFO: skipped node --check because the installed node cannot parse the original bundle."
fi

systemctl restart pvedaemon pveproxy

# Functional backend verification. When the host has annotated guests, compare
# the real decoded first lines with /cluster/resources. A mismatch triggers the
# ERR trap and restores both original files automatically.
API_RESULT="$BACKUP_DIR/cluster-resources-after.json"
pvesh get /cluster/resources --type vm --output-format json >"$API_RESULT"
python3 - "$EXPECTED_NOTES" "$API_RESULT" <<'PY'
import json
from pathlib import Path
import sys

expected = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
resources = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
actual = {
    (item.get("type"), item.get("vmid")): item.get("description")
    for item in resources
    if item.get("type") in {"qemu", "lxc"}
}

if not expected:
    print(
        "API request succeeded. No annotated VM/CT was present, "
        "so description-value comparison was skipped."
    )
else:
    failures = []
    for item in expected:
        key = (item["type"], item["vmid"])
        received = actual.get(key)
        if received != item["description"]:
            failures.append(
                f"{item['type']} {item['vmid']}: "
                f"expected {item['description']!r}, received {received!r}"
            )
        else:
            print(
                f"API verified: {item['type']} {item['vmid']} "
                f"description={received!r}"
            )
    if failures:
        raise SystemExit(
            "Functional verification failed:\n  " + "\n  ".join(failures)
        )
PY

trap - ERR

cat >"$BACKUP_DIR/restore.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cp -a '$BACKUP_DIR/Cluster.pm' '$CLUSTER_PM'
cp -a '$BACKUP_DIR/pvemanagerlib.js' '$PVE_JS'
systemctl restart pvedaemon pveproxy
echo 'Original PVE files restored.'
EOF
chmod 700 "$BACKUP_DIR/restore.sh"

echo
echo "Patch and API functional verification completed."
echo "PVE:     $PVE_MANAGER_VERSION"
echo "Backup:  $BACKUP_DIR"
echo "Restore: $BACKUP_DIR/restore.sh"
echo "Open your normal PVE URL with this query parameter, then press Ctrl+F5:"
echo "  ?alias_patch=$STAMP"
