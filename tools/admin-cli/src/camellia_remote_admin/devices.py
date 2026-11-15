import argparse
from datetime import UTC, datetime

from . import transport
from .batch_operations import (
    canonical_model_pk,
    canonical_operation_id,
    check_control_response,
    fail,
    operation_headers,
    required_generation,
)
from .outcomes import (
    CliError,
    ExitCode,
    add_options,
    control_mutations,
    read_page,
    run_mutations,
)


def view(
    url,
    token,
    id=None,
    device_name=None,
    user_name=None,
    group_name=None,
    device_group_name=None,
    offline_days=None,
):
    headers = {"Authorization": f"Bearer {token}"}
    pageSize = 30
    params = {
        "id": id,
        "device_name": device_name,
        "user_name": user_name,
        "group_name": group_name,
        "device_group_name": device_group_name,
    }

    # Exact filters stay exact; wildcard modes must be explicitly requested.
    params = {key: value for key, value in params.items() if value is not None}
    params["pageSize"] = pageSize

    devices = []

    current = 0

    while True:
        current += 1
        params["current"] = current
        response = transport.get(f"{url}/api/devices", headers=headers, params=params)
        response_json = read_page(response)
        data = response_json["data"]

        for device in data:
            if offline_days is None:
                devices.append(device)
                continue
            try:
                last_online = datetime.fromisoformat(device["last_online"])
            except (KeyError, TypeError, ValueError):
                fail("Device last_online field is not a valid timestamp")
            if last_online.tzinfo is None:
                fail("Device last_online field requires a timezone")
            if (datetime.now(UTC) - last_online).days >= offline_days:
                devices.append(device)

        total = response_json.get("total", 0)
        if len(data) < pageSize or current * pageSize >= total:
            break

    return devices


def _control_mutation(
    url,
    token,
    guid,
    *,
    action,
    operation_id=None,
    expected_generation=None,
):
    guid = canonical_model_pk(guid, "device GUID")
    expected_generation = required_generation(expected_generation)
    operation = f"device_status_{action}"
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation target: device {guid}", flush=True)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {"operation": operation, "device": str(guid)}
    if expected_generation is not None:
        request_document["expected_generation"] = expected_generation
    response = transport.post(
        f"{url}/api/devices/{guid}/{action}",
        headers=operation_headers(token, operation_id, expected_generation),
        json={},
    )
    return check_control_response(
        response,
        operation=operation,
        operation_id=operation_id,
        request_document=request_document,
        requested={"devices": 1},
    )


def disable(url, token, guid, id, operation_id=None, expected_generation=None):
    print("Disable", id)
    return _control_mutation(
        url,
        token,
        guid,
        action="disable",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def enable(url, token, guid, id, operation_id=None, expected_generation=None):
    print("Enable", id)
    return _control_mutation(
        url,
        token,
        guid,
        action="enable",
        operation_id=operation_id,
        expected_generation=expected_generation,
    )


def delete(url, token, guid, id, operation_id=None, expected_generation=None):
    print("Delete", id)
    guid = canonical_model_pk(guid, "device GUID")
    expected_generation = required_generation(expected_generation)
    operation = "device_delete"
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation target: device {guid}", flush=True)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {"operation": operation, "device": str(guid)}
    if expected_generation is not None:
        request_document["expected_generation"] = expected_generation
    response = transport.delete(
        f"{url}/api/devices/{guid}",
        headers=operation_headers(token, operation_id, expected_generation),
        json={},
    )
    return check_control_response(
        response,
        operation=operation,
        operation_id=operation_id,
        request_document=request_document,
        requested={"devices": 1},
    )


def assign(
    url, token, guid, id, type, value, operation_id=None, expected_generation=None
):
    print("assign", id, type)
    valid_types = [
        "ab",
        "strategy_name",
        "user_name",
        "device_group_name",
        "note",
        "device_username",
        "device_name",
    ]
    if type not in valid_types:
        fail(
            f"Invalid type, it must be one of: {', '.join(valid_types)}",
            ExitCode.INVALID,
        )
    if type == "ab":
        values = value.split(",")
        if len(values) != 5:
            fail("ab assignment must contain name,tag,alias,password,note")
        value = dict(
            zip(
                (
                    "address_book_name",
                    "address_book_tag",
                    "address_book_alias",
                    "address_book_password",
                    "address_book_note",
                ),
                values,
                strict=True,
            )
        )
    data = {"type": type, "value": value}
    guid = canonical_model_pk(guid, "device GUID")
    expected_generation = required_generation(expected_generation)
    operation_id = canonical_operation_id(operation_id)
    print(f"Operation target: device {guid}", flush=True)
    print(f"Operation ID: {operation_id}", flush=True)
    request_document = {
        "operation": "device_assign",
        "device": guid,
        "type": type,
        "value": (
            {
                **{
                    key: nested_value
                    for key, nested_value in value.items()
                    if key != "address_book_password"
                },
                "has_address_book_password": "address_book_password" in value,
                "address_book_password": (
                    value["address_book_password"]
                    if "address_book_password" in value
                    else None
                ),
            }
            if type == "ab"
            else value
        ),
        "expected_generation": expected_generation,
    }
    response = transport.post(
        f"{url}/api/devices/{guid}/assign",
        headers=operation_headers(token, operation_id, expected_generation),
        json=data,
    )
    return check_control_response(
        response,
        operation="device_assign",
        operation_id=operation_id,
        request_document=request_document,
        requested={"devices": 1},
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="camellia-remote-admin devices", description="Device manager"
    )
    parser.add_argument(
        "command", choices=["view", "disable", "enable", "delete", "assign"]
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--id")
    parser.add_argument("--guid", help="Exact Management device GUID")
    parser.add_argument("--device_name")
    parser.add_argument("--user_name")
    parser.add_argument("--group_name")
    parser.add_argument("--device_group_name")
    parser.add_argument("--assign_to", help="<type>=<value>")
    parser.add_argument("--offline_days", type=int)
    parser.add_argument("--operation-id")
    parser.add_argument("--expected-generation", type=int)
    add_options(parser)
    args = parser.parse_args(argv)
    transport.configure(args)
    args.url = args.url.rstrip("/")
    operation_id = (
        canonical_operation_id(args.operation_id) if args.operation_id else None
    )
    if args.offline_days is not None and args.offline_days < 0:
        parser.error("--offline_days must be non-negative")
    assign_type, assign_value = None, None
    if args.command == "assign":
        if not args.assign_to or "=" not in args.assign_to:
            parser.error("--assign_to must be <type>=<value>")
        assign_type, assign_value = args.assign_to.split("=", 1)
        if assign_type not in (
            "ab",
            "strategy_name",
            "user_name",
            "device_group_name",
            "note",
            "device_username",
            "device_name",
        ):
            parser.error("Unknown assignment type")
        if assign_type == "ab" and len(assign_value.split(",")) != 5:
            parser.error("ab assignment must contain name,tag,alias,password,note")
    if args.guid:
        if args.command == "view":
            parser.error("--guid is only supported for mutations")
        rows = [
            {
                "guid": canonical_model_pk(args.guid, "device GUID"),
                "id": args.id or args.guid,
                "mutation_generation": args.expected_generation,
            }
        ]
    else:
        rows = view(
            args.url,
            args.token,
            args.id,
            args.device_name,
            args.user_name,
            args.group_name,
            args.device_group_name,
            args.offline_days,
        )
    if args.command == "view":
        return rows
    for row in rows:
        canonical_model_pk(row.get("guid"), "device GUID")
    if args.expected_generation is not None:
        if len(rows) != 1:
            raise CliError(
                "--expected-generation requires exactly one device", ExitCode.INVALID
            )
        rows = [{**rows[0], "mutation_generation": args.expected_generation}]
    if args.command == "assign":

        def mutate(row, key):
            return assign(
                args.url,
                args.token,
                row["guid"],
                row["id"],
                assign_type,
                assign_value,
                operation_id=key,
                expected_generation=row["mutation_generation"],
            )
    else:
        action = {"disable": disable, "enable": enable, "delete": delete}[args.command]

        def mutate(row, key):
            return action(
                args.url,
                args.token,
                row["guid"],
                row["id"],
                operation_id=key,
                expected_generation=row["mutation_generation"],
            )

    mutations = control_mutations(rows, "devices", mutate, operation_id=operation_id)
    return run_mutations(
        "devices_" + args.command, mutations, allow_empty=args.allow_empty, yes=args.yes
    )
