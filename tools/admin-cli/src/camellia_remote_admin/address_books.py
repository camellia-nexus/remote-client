import argparse
import json
import sys

from . import transport
from .batch_operations import (
    canonical_operation_id,
    check_control_response,
    fail,
    operation_headers,
    replayable_request_document,
    required_generation,
)


def replayable_mutation(
    request_method,
    http_method,
    url,
    token,
    path,
    payload,
    operation,
    *,
    operation_id=None,
    expected_generation=None,
):
    expected_generation = required_generation(expected_generation)
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    headers = operation_headers(token, operation_id, expected_generation)
    response = request_method(f"{url}{path}", headers=headers, json=payload)
    return check_control_response(
        response,
        operation=operation,
        operation_id=operation_id,
        request_document=replayable_request_document(
            operation,
            http_method,
            path,
            payload,
            expected_generation=expected_generation,
        ),
        requested={"mutations": 1},
    )


def get_personal_ab(url, token):
    """Get personal address book GUID"""
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    response = transport.post(f"{url}/api/ab/personal", headers=headers, json={})

    if response.status_code != 200:
        print(f"Error: HTTP {response.status_code}")
        sys.exit(1)

    response_json = response.json()
    if "error" in response_json:
        print("Error: Management rejected the request")
        sys.exit(1)

    return response_json


def view_shared_abs(url, token, name=None):
    """View all shared address books (excluding personal ones)"""
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    pageSize = 30
    params = {
        "name": name,
    }

    filtered_params = {
        k: "%" + v + "%" if (v != "-" and "%" not in v and k != "name") else v
        for k, v in params.items()
        if v is not None
    }
    filtered_params["pageSize"] = pageSize

    abs = []
    current = 0

    while True:
        current += 1
        filtered_params["current"] = current
        response = transport.post(
            f"{url}/api/ab/shared/profiles", headers=headers, params=filtered_params, json={}
        )
        if response.status_code != 200:
            print(f"Error: HTTP {response.status_code}")
            sys.exit(1)

        response_json = response.json()
        if "error" in response_json:
            print("Error: Management rejected the request")
            sys.exit(1)

        data = response_json.get("data", [])
        abs.extend(data)

        total = response_json.get("total", 0)
        if len(data) < pageSize or current * pageSize >= total:
            break

    return abs


def get_ab_by_name(url, token, ab_name):
    """Get address book by name"""
    abs = view_shared_abs(url, token, ab_name)
    for ab in abs:
        if ab["name"] == ab_name:
            return ab
    return None


def view_ab_peers(url, token, ab_guid, peer_id=None, alias=None):
    """View peers in an address book"""
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    pageSize = 30
    params = {
        "ab": ab_guid,
        "id": peer_id,
        "alias": alias,
    }

    filtered_params = {
        k: "%" + v + "%" if (v != "-" and "%" not in v and k not in ["ab"]) else v
        for k, v in params.items()
        if v is not None
    }
    filtered_params["pageSize"] = pageSize

    peers = []
    current = 0

    while True:
        current += 1
        filtered_params["current"] = current
        response = transport.post(
            f"{url}/api/ab/peers", headers=headers, params=filtered_params, json={}
        )
        if response.status_code != 200:
            print(f"Error: HTTP {response.status_code}")
            sys.exit(1)

        response_json = response.json()
        if "error" in response_json:
            print("Error: Management rejected the request")
            sys.exit(1)

        data = response_json.get("data", [])
        peers.extend(data)

        total = response_json.get("total", 0)
        if len(data) < pageSize or current * pageSize >= total:
            break

    return peers


def view_ab_tags(url, token, ab_guid):
    """View tags in an address book"""
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    response = transport.post(f"{url}/api/ab/tags/{ab_guid}", headers=headers, json={})
    response_json = check_response(response)

    tags = response_json.get("data", []) if isinstance(response_json, dict) else response_json

    # Format color values as hex
    if isinstance(tags, list):
        for tag in tags:
            if isinstance(tag, dict) and "color" in tag and tag["color"] is not None:
                # Convert color to hex format
                color_value = tag["color"]
                if isinstance(color_value, int):
                    tag["color"] = f"0x{color_value:08X}"

    return tags if isinstance(tags, list) else []


def check_response(response):
    """Check API response and return result"""
    if response.status_code != 200:
        print(f"Error: HTTP {response.status_code}")
        sys.exit(1)

    try:
        response_json = response.json()
        if "error" in response_json:
            print("Error: Management rejected the request")
            sys.exit(1)
        return response_json
    except ValueError:
        fail("Management response is not JSON")


def add_peer(
    url,
    token,
    ab_guid,
    peer_id,
    alias=None,
    note=None,
    tags=None,
    password=None,
    operation_id=None,
    expected_generation=None,
):
    """Add a peer to address book"""
    print(f"Adding peer {peer_id} to address book")
    payload = {
        "id": peer_id,
        "note": note,
    }

    # Add peer info if provided
    info = {}
    if alias:
        info["alias"] = alias
    if tags:
        info["tags"] = tags if isinstance(tags, list) else [tags]
    if password:
        info["password"] = password

    if info:
        payload.update(info)

    return replayable_mutation(
        transport.post,
        "POST",
        url,
        token,
        f"/api/ab/peer/add/{ab_guid}",
        payload,
        "address_book_peer_add",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def delete_peer(
    url, token, ab_guid, peer_ids, operation_id=None, expected_generation=None
):
    """Delete peers from address book by IDs"""
    if isinstance(peer_ids, str):
        peer_ids = [peer_ids]

    print(f"Deleting peers {peer_ids} from address book")
    return replayable_mutation(
        transport.delete,
        "DELETE",
        url,
        token,
        f"/api/ab/peer/{ab_guid}",
        peer_ids,
        "address_book_peer_delete",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def update_peer(
    url,
    token,
    ab_guid,
    peer_id,
    alias=None,
    note=None,
    tags=None,
    password=None,
    operation_id=None,
    expected_generation=None,
):
    """Update a peer in address book"""
    print(f"Updating peer {peer_id} in address book")
    # Check if at least one parameter is provided for update
    update_params = [alias, note, tags, password]
    if all(param is None for param in update_params):
        fail("At least one parameter must be specified for update")

    payload = {
        "id": peer_id,
    }

    # Add fields to update
    info = {}
    if alias is not None:
        info["alias"] = alias
    if tags is not None:
        info["tags"] = tags if isinstance(tags, list) else [tags]
    if password is not None:
        info["password"] = password

    if info:
        payload.update(info)

    if note is not None:
        payload["note"] = note

    return replayable_mutation(
        transport.put,
        "PUT",
        url,
        token,
        f"/api/ab/peer/update/{ab_guid}",
        payload,
        "address_book_peer_update",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def str2color(tag_name, existing_colors=None):
    """Generate color for tag name similar to str2color2 function"""
    if existing_colors is None:
        existing_colors = []

    color_map = {
        "red": 0xFFFF0000,
        "green": 0xFF008000,
        "blue": 0xFF0000FF,
        "orange": 0xFFFF9800,
        "purple": 0xFF9C27B0,
        "grey": 0xFF9E9E9E,
        "cyan": 0xFF00BCD4,
        "lime": 0xFFCDDC39,
        "teal": 0xFF009688,
        "pink": 0xFFF48FB1,
        "indigo": 0xFF3F51B5,
        "brown": 0xFF795548,
    }

    lower_name = tag_name.lower()

    # Check if tag name matches a predefined color
    if lower_name in color_map:
        return color_map[lower_name]

    # Special case for yellow
    if lower_name == "yellow":
        return 0xFFFFFF00

    # Generate hash-based color
    hash_value = 0
    for char in tag_name:
        hash_value += ord(char)

    color_list = list(color_map.values())
    hash_value = hash_value % len(color_list)
    result = color_list[hash_value]

    # If color is already used, try to find an unused one
    if result in existing_colors:
        for color in color_list:
            if color not in existing_colors:
                result = color
                break

    return result


def add_tag(
    url,
    token,
    ab_guid,
    tag_name,
    color=None,
    operation_id=None,
    expected_generation=None,
):
    """Add a tag to address book"""
    print(f"Adding tag '{tag_name}' to address book")
    # If no color specified, generate one based on tag name
    if color is None:
        # Get existing tags to avoid color conflicts
        try:
            existing_tags = view_ab_tags(url, token, ab_guid)
            existing_colors = [
                int(tag["color"], 16) if isinstance(tag.get("color"), str) and tag["color"].startswith("0x")
                else tag.get("color", 0)
                for tag in existing_tags if isinstance(tag, dict)
            ]
            color = str2color(tag_name, existing_colors)
        except (KeyError, ValueError, TypeError):
            # Fallback to default color if tag list structure is empty/unexpected
            color = str2color(tag_name)

    payload = {
        "name": tag_name,
        "color": color,
    }

    return replayable_mutation(
        transport.post,
        "POST",
        url,
        token,
        f"/api/ab/tag/add/{ab_guid}",
        payload,
        "address_book_tag_add",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def update_tag(
    url, token, ab_guid, tag_name, color, operation_id=None, expected_generation=None
):
    """Update a tag in address book"""
    print(f"Updating tag '{tag_name}' in address book")
    payload = {
        "name": tag_name,
        "color": color,
    }

    return replayable_mutation(
        transport.put,
        "PUT",
        url,
        token,
        f"/api/ab/tag/update/{ab_guid}",
        payload,
        "address_book_tag_update",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def delete_tags(
    url, token, ab_guid, tag_names, operation_id=None, expected_generation=None
):
    """Delete tags from address book"""
    if isinstance(tag_names, str):
        tag_names = [tag_names]

    print(f"Deleting tags {tag_names} from address book")
    return replayable_mutation(
        transport.delete,
        "DELETE",
        url,
        token,
        f"/api/ab/tag/{ab_guid}",
        tag_names,
        "address_book_tag_delete",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def add_shared_ab(url, token, name, note=None, password=None, operation_id=None):
    """Add a new shared address book"""
    print(f"Adding shared address book '{name}'")
    payload = {
        "name": name,
        "note": note or "",
    }

    if password is not None:
        payload["default_password"] = password
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.post(
        f"{url}/api/ab/shared/add",
        headers=operation_headers(token, operation_id),
        json=payload,
    )
    return check_control_response(
        response,
        operation="address_book_profile_create",
        operation_id=operation_id,
        request_document={
            "operation": "address_book_profile_create",
            "name": name.strip(),
            "note": note or "",
            "info": None,
            "has_default_password": password is not None,
            "default_password": password,
        },
        requested={"profiles": 1},
    )


def update_shared_ab(
    url,
    token,
    ab_guid,
    name=None,
    note=None,
    owner=None,
    password=None,
    operation_id=None,
    expected_generation=None,
):
    """Update a shared address book"""
    print(f"Updating shared address book {ab_guid}")
    # Check if at least one parameter is provided for update
    update_params = [name, note, owner, password]
    if all(param is None for param in update_params):
        fail("At least one parameter must be specified for update")

    payload = {
        "guid": ab_guid,
    }

    if name is not None:
        payload["name"] = name
    if note is not None:
        payload["note"] = note
    if owner is not None:
        payload["owner"] = owner
    if password is not None:
        payload["default_password"] = password
    expected_generation = required_generation(expected_generation)
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.put(
        f"{url}/api/ab/shared/update/profile",
        headers=operation_headers(token, operation_id, expected_generation),
        json=payload,
    )
    return check_control_response(
        response,
        operation="address_book_profile_update",
        operation_id=operation_id,
        request_document={
            "operation": "address_book_profile_update",
            "guid": str(ab_guid),
            "data": {
                key: value
                for key, value in payload.items()
                if key != "default_password"
            },
            "has_default_password": password is not None,
            "default_password": password,
            "owner": owner,
            "expected_generation": expected_generation,
        },
        requested={"profiles": 1},
    )


def delete_shared_abs(
    url, token, ab_guids, operation_id=None, expected_generation=None
):
    """Delete shared address books"""
    if isinstance(ab_guids, str):
        ab_guids = [ab_guids]
    if len(ab_guids) != 1:
        fail("one operation can delete exactly one address book")
    expected_generation = required_generation(expected_generation)

    print(f"Deleting shared address books {ab_guids}")
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation ID: {operation_id}", flush=True)
    response = transport.delete(
        f"{url}/api/ab/shared",
        headers=operation_headers(token, operation_id, expected_generation),
        json=ab_guids,
    )
    return check_control_response(
        response,
        operation="address_book_profile_delete",
        operation_id=operation_id,
        request_document={
            "operation": "address_book_profile_delete",
            "profiles": sorted(str(value) for value in ab_guids),
            "expected_generation": expected_generation,
        },
        requested={"profiles": len(ab_guids)},
    )


def permission_to_string(permission):
    """Convert numeric permission to string representation"""
    permission_map = {
        1: "ro",  # Read
        2: "rw",  # ReadWrite
        3: "full",  # FullControl
    }
    return permission_map.get(permission, str(permission))


def string_to_permission(permission_str):
    """Convert string permission to numeric representation"""
    permission_map = {
        "ro": 1,  # Read
        "rw": 2,  # ReadWrite
        "full": 3,  # FullControl
    }
    return permission_map.get(permission_str.lower(), None)


def view_ab_rules(url, token, ab_guid):
    """View rules in an address book"""
    headers = {"Authorization": f"Bearer {token}"}
    pageSize = 30
    params = {
        "ab": ab_guid,
        "pageSize": pageSize,
    }

    rules = []
    current = 0

    while True:
        current += 1
        params["current"] = current
        response = transport.get(f"{url}/api/ab/rules", headers=headers, params=params)
        if response.status_code != 200:
            print(f"Error: HTTP {response.status_code}")
            sys.exit(1)

        response_json = response.json()
        if "error" in response_json:
            print("Error: Management rejected the request")
            sys.exit(1)

        data = response_json.get("data", [])
        rules.extend(data)

        total = response_json.get("total", 0)
        if len(data) < pageSize or current * pageSize >= total:
            break

    # Convert numeric permissions to string format
    for rule in rules:
        if "rule" in rule:
            rule["rule"] = permission_to_string(rule["rule"])

    return rules


def add_ab_rule(
    url,
    token,
    ab_guid,
    rule_type,
    user=None,
    group=None,
    rule=1,
    operation_id=None,
    expected_generation=None,
):
    """Add a rule to address book"""
    print(f"Adding {rule_type} rule to address book")
    payload = {
        "guid": ab_guid,
        "rule": rule,
    }

    if rule_type == "user" and user:
        payload["user"] = user
    elif rule_type == "group" and group:
        payload["group"] = group
    elif rule_type == "everyone":
        # For everyone, both user and group are None (not included in payload)
        pass

    return replayable_mutation(
        transport.post,
        "POST",
        url,
        token,
        "/api/ab/rule",
        payload,
        "address_book_rule_mutation",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def update_ab_rule(
    url, token, rule_guid, rule, operation_id=None, expected_generation=None
):
    """Update an address book rule"""
    print(f"Updating rule {rule_guid}")
    payload = {
        "guid": rule_guid,
        "rule": rule,
    }

    return replayable_mutation(
        transport.patch,
        "PATCH",
        url,
        token,
        "/api/ab/rule",
        payload,
        "address_book_rule_mutation",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def delete_ab_rules(
    url, token, rule_guids, operation_id=None, expected_generation=None
):
    """Delete address book rules"""
    if isinstance(rule_guids, str):
        rule_guids = [rule_guids]

    print(f"Deleting rules {rule_guids}")
    return replayable_mutation(
        transport.delete,
        "DELETE",
        url,
        token,
        "/api/ab/rules",
        rule_guids,
        "address_book_rule_delete",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def main(argv=None):
    def parse_color(value):
        """Parse color value - supports both hex (0xFF00FF00) and decimal"""
        if value.startswith(("0x", "0X")):
            return int(value, 16)
        else:
            return int(value)

    def parse_permission(value):
        """Parse the canonical permission names."""
        permission_num = string_to_permission(value)
        if permission_num is not None:
            return permission_num
        raise argparse.ArgumentTypeError(
            f"Invalid permission value: {value}. Must be one of: ro, rw, full"
        )

    parser = argparse.ArgumentParser(
        prog="camellia-remote-admin address-books", description="Address Book manager"
    )

    # Required arguments
    parser.add_argument(
        "command",
        choices=[
            "view-ab",
            "add-ab",
            "update-ab",
            "delete-ab",
            "get-personal-ab",
            "view-peer",
            "add-peer",
            "update-peer",
            "delete-peer",
            "view-tag",
            "add-tag",
            "update-tag",
            "delete-tag",
            "view-rule",
            "add-rule",
            "update-rule",
            "delete-rule",
        ],
        help="Command to execute",
    )

    # Global arguments (used by all commands)
    parser.add_argument("--url", required=True, help="URL of the API")
    parser.add_argument(
        "--token", required=True, help="Bearer token for authentication"
    )

    # Address book identification (used by most commands except get-personal-ab)
    parser.add_argument("--ab-name", help="Address book name (for identification)")
    parser.add_argument("--ab-guid", help="Address book GUID (alternative to ab-name)")

    # Address book management arguments
    parser.add_argument("--ab-update-name", help="New address book name (for update)")
    parser.add_argument("--note", help="Note field")
    parser.add_argument("--password", help="Password field")
    parser.add_argument("--owner", help="Address book owner (username)")

    # Peer management arguments
    parser.add_argument("--peer-id", help="Peer ID")
    parser.add_argument("--alias", help="Peer alias")
    parser.add_argument(
        "--tags",
        help="Peer tags (supports both 'tag1,tag2' and '[tag1,tag2]' formats, use '[]' to clear tags)",
    )

    # Tag management arguments
    parser.add_argument("--tag-name", help="Tag name")
    parser.add_argument(
        "--tag-color",
        type=parse_color,
        help="Tag color (hex number like 0xFF00FF00 or decimal, auto-generated if not specified)",
    )

    # Rule management arguments
    parser.add_argument(
        "--rule-type",
        choices=["user", "group", "everyone"],
        help="Rule type (auto-detected if not specified)",
    )
    parser.add_argument(
        "--rule-user", help="Rule target user name (auto-sets rule-type=user)"
    )
    parser.add_argument(
        "--rule-group", help="Rule target group name (auto-sets rule-type=group)"
    )
    parser.add_argument(
        "--rule-permission",
        type=parse_permission,
        help="Rule permission (ro=Read, rw=ReadWrite, full=FullControl)",
    )
    parser.add_argument("--rule-guid", help="Rule GUID (for update/delete)")
    parser.add_argument(
        "--operation-id",
        help="Canonical UUID used to retry one mutation after response loss",
    )
    parser.add_argument(
        "--expected-generation",
        type=int,
        help="Address-book generation observed before mutation",
    )

    transport.add_options(parser)
    args = parser.parse_args(argv)
    transport.configure(args)

    # Remove trailing slashes from URL
    while args.url.endswith("/"):
        args.url = args.url[:-1]

    if args.command == "view-ab":
        # View all shared address books
        abs = view_shared_abs(args.url, args.token, args.ab_name)
        print(json.dumps(abs, indent=2))

    elif args.command == "get-personal-ab":
        # Get personal address book GUID
        personal_ab = get_personal_ab(args.url, args.token)
        print(json.dumps(personal_ab, indent=2))

    elif args.command in ["add-ab", "update-ab", "delete-ab"]:
        # Address book management commands
        if args.command == "add-ab":
            if not args.ab_name:
                print("Error: --ab-name is required for add-ab command")
                return

            result = add_shared_ab(
                args.url,
                args.token,
                args.ab_name,
                args.note,
                args.password,
                operation_id=args.operation_id,
            )
            print(f"Result: {result}")

        elif args.command in ["update-ab", "delete-ab"]:
            # Commands that need ab-name or ab-guid
            if not args.ab_name and not args.ab_guid:
                print("Error: --ab-name or --ab-guid is required for this command")
                return

            if args.ab_name and args.ab_guid:
                print("Error: Cannot specify both --ab-name and --ab-guid")
                return

            if args.ab_guid:
                ab_guid = args.ab_guid
                profile_generation = args.expected_generation
                print(f"Working with address book GUID: {ab_guid}")
            else:
                # Get address book by name
                ab = get_ab_by_name(args.url, args.token, args.ab_name)
                if not ab:
                    print(f"Error: Address book '{args.ab_name}' not found")
                    return
                ab_guid = ab["guid"]
                profile_generation = (
                    args.expected_generation
                    if args.expected_generation is not None
                    else ab.get("authorization_generation")
                )
                print(f"Working with address book: {args.ab_name} (GUID: {ab_guid})")

            if args.command == "update-ab":
                result = update_shared_ab(
                    args.url,
                    args.token,
                    ab_guid,
                    args.ab_update_name,
                    args.note,
                    args.owner,
                    args.password,
                    operation_id=args.operation_id,
                    expected_generation=profile_generation,
                )
                print(f"Result: {result}")

            elif args.command == "delete-ab":
                result = delete_shared_abs(
                    args.url,
                    args.token,
                    ab_guid,
                    operation_id=args.operation_id,
                    expected_generation=profile_generation,
                )
                print(f"Result: {result}")

    elif args.command in [
        "view-peer",
        "add-peer",
        "update-peer",
        "delete-peer",
        "view-tag",
        "add-tag",
        "update-tag",
        "delete-tag",
        "view-rule",
        "add-rule",
        "update-rule",
        "delete-rule",
    ]:
        if not args.ab_name and not args.ab_guid:
            print("Error: --ab-name or --ab-guid is required for this command")
            return

        if args.ab_name and args.ab_guid:
            print("Error: Cannot specify both --ab-name and --ab-guid")
            return

        if args.ab_guid:
            ab_guid = args.ab_guid
            profile_generation = args.expected_generation
            print(f"Working with address book GUID: {ab_guid}")
        else:
            # Get address book by name
            ab = get_ab_by_name(args.url, args.token, args.ab_name)
            if not ab:
                print(f"Error: Address book '{args.ab_name}' not found")
                return

            ab_guid = ab["guid"]
            profile_generation = (
                args.expected_generation
                if args.expected_generation is not None
                else ab.get("authorization_generation")
            )
            print(f"Working with address book: {args.ab_name} (GUID: {ab_guid})")

        if args.command == "view-peer":
            peers = view_ab_peers(
                args.url, args.token, ab_guid, args.peer_id, args.alias
            )
            print(json.dumps(peers, indent=2))

        elif args.command == "add-peer":
            if not args.peer_id:
                print("Error: --peer-id is required for add-peer command")
                return

            # Handle tags parsing - support both [tag1,tag2] and tag1,tag2 formats
            tags = None
            if args.tags is not None:
                if args.tags == "[]":
                    tags = []  # Empty list to clear tags
                else:
                    # Remove brackets if present and split by comma
                    tags_str = args.tags.strip()
                    if tags_str.startswith("[") and tags_str.endswith("]"):
                        tags_str = tags_str[1:-1]  # Remove brackets
                    tags = [tag.strip() for tag in tags_str.split(",") if tag.strip()]

            result = add_peer(
                args.url,
                args.token,
                ab_guid,
                args.peer_id,
                args.alias,
                args.note,
                tags,
                args.password,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "update-peer":
            if not args.peer_id:
                print("Error: --peer-id is required for update-peer command")
                return

            # Handle tags parsing - support both [tag1,tag2] and tag1,tag2 formats
            tags = None
            if args.tags is not None:
                if args.tags == "[]":
                    tags = []  # Empty list to clear tags
                else:
                    # Remove brackets if present and split by comma
                    tags_str = args.tags.strip()
                    if tags_str.startswith("[") and tags_str.endswith("]"):
                        tags_str = tags_str[1:-1]  # Remove brackets
                    tags = [tag.strip() for tag in tags_str.split(",") if tag.strip()]

            result = update_peer(
                args.url,
                args.token,
                ab_guid,
                args.peer_id,
                args.alias,
                args.note,
                tags,
                args.password,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "delete-peer":
            if not args.peer_id:
                print("Error: --peer-id is required for delete-peer command")
                return

            result = delete_peer(
                args.url,
                args.token,
                ab_guid,
                args.peer_id,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "view-tag":
            tags = view_ab_tags(args.url, args.token, ab_guid)
            print(json.dumps(tags, indent=2))

        elif args.command == "add-tag":
            if not args.tag_name:
                print("Error: --tag-name is required for add-tag command")
                return

            result = add_tag(
                args.url,
                args.token,
                ab_guid,
                args.tag_name,
                args.tag_color,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "update-tag":
            if not args.tag_name:
                print("Error: --tag-name is required for update-tag command")
                return

            result = update_tag(
                args.url,
                args.token,
                ab_guid,
                args.tag_name,
                args.tag_color,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "delete-tag":
            if not args.tag_name:
                print("Error: --tag-name is required for delete-tag command")
                return

            result = delete_tags(
                args.url,
                args.token,
                ab_guid,
                args.tag_name,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "view-rule":
            rules = view_ab_rules(args.url, args.token, ab_guid)
            print(json.dumps(rules, indent=2))

        elif args.command == "add-rule":
            if not args.rule_permission:
                print("Error: --rule-permission is required for add-rule command")
                return

            # Auto-detect rule type if not explicitly specified
            if not args.rule_type:
                if args.rule_user and args.rule_group:
                    print("Error: Cannot specify both --rule-user and --rule-group")
                    return
                elif args.rule_user:
                    rule_type = "user"
                elif args.rule_group:
                    rule_type = "group"
                else:
                    print(
                        "Error: Must specify --rule-type=everyone, --rule-user, or --rule-group"
                    )
                    return
            else:
                rule_type = args.rule_type

                # Validate explicit rule type with parameters
                if rule_type == "user" and not args.rule_user:
                    print("Error: --rule-user is required when rule-type=user")
                    return
                elif rule_type == "group" and not args.rule_group:
                    print("Error: --rule-group is required when rule-type=group")
                    return
                elif rule_type == "user" and args.rule_group:
                    print("Error: Cannot specify --rule-group when rule-type=user")
                    return
                elif rule_type == "group" and args.rule_user:
                    print("Error: Cannot specify --rule-user when rule-type=group")
                    return
                elif rule_type == "everyone" and (args.rule_user or args.rule_group):
                    print(
                        "Error: Cannot specify --rule-user or --rule-group when rule-type=everyone"
                    )
                    return

            result = add_ab_rule(
                args.url,
                args.token,
                ab_guid,
                rule_type,
                args.rule_user,
                args.rule_group,
                args.rule_permission,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "update-rule":
            if not args.rule_guid:
                print("Error: --rule-guid is required for update-rule command")
                return
            if not args.rule_permission:
                print("Error: --rule-permission is required for update-rule command")
                return

            result = update_ab_rule(
                args.url,
                args.token,
                args.rule_guid,
                args.rule_permission,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")

        elif args.command == "delete-rule":
            if not args.rule_guid:
                print("Error: --rule-guid is required for delete-rule command")
                return

            result = delete_ab_rules(
                args.url,
                args.token,
                args.rule_guid,
                operation_id=args.operation_id,
                expected_generation=profile_generation,
            )
            print(f"Result: {result}")
