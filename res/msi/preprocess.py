#!/usr/bin/env python3

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import uuid
from itertools import chain
from pathlib import Path
from xml.sax.saxutils import quoteattr

g_indent_unit = "\t"
g_version = ""
g_build_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")
SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGE_DIR = SCRIPT_DIR / "Package"
REPOSITORY_ROOT = SCRIPT_DIR.parents[1]
APPLICATION_EXECUTABLE = "camellia-remote"
WINDOWS_BUILD_ROOT = REPOSITORY_ROOT / "flutter" / "build" / "windows"
ARM64_DISTRIBUTION_DIRECTORY = WINDOWS_BUILD_ROOT / "arm64" / "runner" / "Release"
X64_DISTRIBUTION_DIRECTORY = WINDOWS_BUILD_ROOT / "x64" / "runner" / "Release"
PRODUCT_TEXT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$")
BUILD_DATE = re.compile(
    r"(?:19|20)[0-9]{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01]) "
    r"(?:[01][0-9]|2[0-3]):[0-5][0-9](?: UTC)?",
    re.ASCII,
)
SHARED_PREPROCESSOR_VARIABLES = frozenset(
    {
        "Version",
        "Manufacturer",
        "Product",
        "Description",
        "ExeName",
        "ProductLower",
        "RegKeyRoot",
        "RegKeyInstall",
        "BuildDir",
        "BuildDate",
        "UpgradeCode",
    }
)
PREPROCESSOR_VARIABLE = re.compile(r"\$\(var\.([A-Za-z_][A-Za-z0-9_.-]*)\)")
SHARED_INCLUDE = re.compile(
    r"<\?include\s+(?:[^?]*[\\/])?Includes\.wxi\s*\?>", re.IGNORECASE
)

# Replace the following links with your own in the custom arp properties.
# https://learn.microsoft.com/en-us/windows/win32/msi/property-reference
g_arpsystemcomponent = {
    "Comments": {
        "msi": "ARPCOMMENTS",
        "t": "string",
        "v": "!(loc.AR_Comment)",
    },
    "Contact": {
        "msi": "ARPCONTACT",
        "v": "https://github.com/camellia-computing/remote-client",
    },
    "HelpLink": {
        "msi": "ARPHELPLINK",
        "v": "https://github.com/camellia-computing/remote-client/issues/",
    },
    "ReadMe": {
        "msi": "ARPREADME",
        "v": "https://github.com/camellia-computing/remote-client",
    },
}


def default_revision_version():
    return int(datetime.datetime.now(datetime.timezone.utc).timestamp() / 60)


def make_parser():
    parser = argparse.ArgumentParser(description="Msi preprocess script.")
    parser.add_argument(
        "--architecture",
        choices=("arm64", "x64"),
        default="x64",
        help="The checked-in Windows build architecture to package.",
    )
    parser.add_argument(
        "--arp",
        action="store_true",
        help="Is ARPSYSTEMCOMPONENT",
        default=False,
    )
    parser.add_argument(
        "--custom-arp",
        type=str,
        default="{}",
        help='Custom arp properties, e.g. \'["Comments": {"msi": "ARPCOMMENTS", "v": "Remote control application."}]\'',
    )
    parser.add_argument(
        "-c", "--custom", action="store_true", help="Is custom client", default=False
    )
    parser.add_argument(
        "--conn-type",
        type=str,
        choices=["", "incoming", "outgoing"],
        default="",
        help='Connection type, e.g. "incoming", "outgoing". Default is empty, means incoming-outgoing',
    )
    parser.add_argument(
        "--app-name", type=str, default="Camellia Remote", help="The app name."
    )
    parser.add_argument(
        "-v", "--version", type=str, default="", help="The app version."
    )
    parser.add_argument(
        "--revision-version",
        type=int,
        default=default_revision_version(),
        help="The revision version.",
    )
    parser.add_argument(
        "-m",
        "--manufacturer",
        type=str,
        default="CAMELLIA",
        help="The app manufacturer.",
    )
    return parser


def package_path(relative_path):
    file_path = (PACKAGE_DIR / relative_path).resolve()
    if not file_path.is_relative_to(PACKAGE_DIR.resolve()):
        raise ValueError(f"MSI project path escapes Package/: {relative_path}")
    return file_path


def stable_semver(value):
    if len(value) > 64:
        return None
    parts = value.split(".")
    if len(parts) != 3:
        return None
    for part in parts:
        if (
            not part
            or not all("0" <= character <= "9" for character in part)
            or (len(part) > 1 and part.startswith("0"))
        ):
            return None
    return tuple(parts)


def distribution_directory(architecture):
    if architecture == "arm64":
        return ARM64_DISTRIBUTION_DIRECTORY
    if architecture == "x64":
        return X64_DISTRIBUTION_DIRECTORY
    raise ValueError(f"unsupported Windows architecture: {architecture}")


def read_lines_and_tag_indexes(file_path, tag_start, tag_end):
    with file_path.open("r", encoding="utf-8") as f:
        lines = f.readlines()
    starts = [index for index, line in enumerate(lines) if tag_start in line]
    ends = [index for index, line in enumerate(lines) if tag_end in line]
    if len(starts) != 1 or len(ends) != 1 or ends[0] <= starts[0]:
        raise ValueError(
            f"{file_path} must contain one ordered {tag_start}/{tag_end} marker pair"
        )
    return lines, starts[0], ends[0]


def insert_components_between_tags(lines, index_start, app_name, exe_name, dist_dir):
    indent = g_indent_unit * 3
    path = Path(dist_dir)
    for file_path in sorted(path.glob("**/*")):
        if file_path.is_symlink():
            raise ValueError(f"distribution tree contains a symbolic link: {file_path}")
        if file_path.is_file():
            if file_path.name.lower() == f"{exe_name}.exe".lower():
                continue

            relative_path = file_path.relative_to(path)
            subdir = str(relative_path.parent)
            dir_attr = ""
            if subdir != ".":
                dir_attr = f"Subdirectory={quoteattr(subdir)}"
            component_guid = uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"camellia-remote-msi:{app_name}:{exe_name}:{relative_path.as_posix().lower()}",
            )

            to_insert_lines = f"""
{indent}<Component Guid="{component_guid}" {dir_attr}>
{indent}{g_indent_unit}<File Source={quoteattr(file_path.as_posix())} KeyPath="yes" Checksum="yes" />
{indent}</Component>
"""
            lines.insert(index_start + 1, to_insert_lines[1:])
            index_start += 1
    return True


def gen_auto_component(app_name, exe_name, dist_dir):
    return gen_content_between_tags(
        "Package/Components/RustDesk.wxs",
        "<!--$AutoComonentStart$-->",
        "<!--$AutoComponentEnd$-->",
        lambda lines, index_start: insert_components_between_tags(
            lines, index_start, app_name, exe_name, dist_dir
        ),
    )


def gen_pre_vars(args, dist_dir, exe_name):
    def func(lines, index_start):
        upgrade_code = uuid.uuid5(uuid.NAMESPACE_OID, args.app_name + ".exe")

        indent = g_indent_unit * 1
        to_insert_lines = [
            f"{indent}<?define Version={quoteattr(g_version)} ?>\n",
            f"{indent}<?define Manufacturer={quoteattr(args.manufacturer)} ?>\n",
            f"{indent}<?define Product={quoteattr(args.app_name)} ?>\n",
            f"{indent}<?define Description={quoteattr(args.app_name + ' Installer')} ?>\n",
            f"{indent}<?define ExeName={quoteattr(exe_name)} ?>\n",
            f"{indent}<?define ProductLower={quoteattr(args.app_name.lower())} ?>\n",
            f'{indent}<?define RegKeyRoot=".$(var.ProductLower)" ?>\n',
            f'{indent}<?define RegKeyInstall="$(var.RegKeyRoot)\\Install" ?>\n',
            f"{indent}<?define BuildDir={quoteattr(str(dist_dir))} ?>\n",
            f"{indent}<?define BuildDate={quoteattr(g_build_date)} ?>\n",
            "\n",
            (
                f"{indent}<!-- The UpgradeCode must be consistent for each product. ! -->\n"
                f'{indent}<?define UpgradeCode = "{upgrade_code}" ?>\n'
            ),
        ]

        for i, line in enumerate(to_insert_lines):
            lines.insert(index_start + i + 1, line)
        return lines

    return gen_content_between_tags(
        "Package/Includes.wxi", "<!--$PreVarsStart$-->", "<!--$PreVarsEnd$-->", func
    )


def replace_app_name_in_langs(app_name):
    langs_dir = PACKAGE_DIR / "Language"
    for file_path in langs_dir.glob("*.wxl"):
        with file_path.open("r", encoding="utf-8") as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            lines[i] = line.replace("RustDesk", app_name)
        with file_path.open("w", encoding="utf-8", newline="\n") as f:
            f.writelines(lines)


def replace_app_name_in_custom_actions(app_name):
    custom_actions_dir = SCRIPT_DIR / "CustomActions"
    for file_path in chain(
        custom_actions_dir.glob("*.cpp"), custom_actions_dir.glob("*.h")
    ):
        with file_path.open("r", encoding="utf-8") as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            line = re.sub(r"\bRustDesk\b", app_name, line)
            line = line.replace(
                f"{app_name} v4 Printer Driver", "Camellia v4 Printer Driver"
            )
            lines[i] = line
        with file_path.open("w", encoding="utf-8", newline="\n") as f:
            f.writelines(lines)


def gen_upgrade_info():
    def func(lines, index_start):
        indent = g_indent_unit * 3

        vs = g_version.split(".")
        major = vs[0]
        to_insert_lines = [
            f'{indent}<Upgrade Id="$(var.UpgradeCode)">\n',
            f'{indent}{g_indent_unit}<UpgradeVersion Property="OLD_VERSION_FOUND" Minimum="{major}.0.0" Maximum="{major}.99.99" IncludeMinimum="yes" IncludeMaximum="yes" OnlyDetect="no" IgnoreRemoveFailure="yes" MigrateFeatures="yes" />\n',
            f"{indent}</Upgrade>\n",
        ]

        for i, line in enumerate(to_insert_lines):
            lines.insert(index_start + i + 1, line)
        return lines

    return gen_content_between_tags(
        "Package/Fragments/Upgrades.wxs",
        "<!--$UpgradeStart$-->",
        "<!--$UpgradeEnd$-->",
        func,
    )


def gen_custom_dialog_bitmaps():
    def func(lines, index_start):
        indent = g_indent_unit * 2

        # https://wixtoolset.org/docs/tools/wixext/wixui/#customizing-a-dialog-set
        vars = [
            "WixUIBannerBmp",
            "WixUIDialogBmp",
            "WixUIExclamationIco",
            "WixUIInfoIco",
            "WixUINewIco",
            "WixUIUpIco",
        ]
        to_insert_lines = []
        for var in vars:
            if Path(f"Package/Resources/{var}.bmp").exists():
                to_insert_lines.append(
                    f'{indent}<WixVariable Id="{var}" Value="Resources\\{var}.bmp" />\n'
                )

        for i, line in enumerate(to_insert_lines):
            lines.insert(index_start + i + 1, line)
        return lines

    return gen_content_between_tags(
        "Package/Package.wxs",
        "<!--$CustomBitmapsStart$-->",
        "<!--$CustomBitmapsEnd$-->",
        func,
    )


def gen_custom_ARPSYSTEMCOMPONENT_False(properties):
    def func(lines, index_start):
        indent = g_indent_unit * 2

        lines_new = []
        lines_new.append(
            f"{indent}<!--https://learn.microsoft.com/en-us/windows/win32/msi/arpsystemcomponent?redirectedfrom=MSDN-->\n"
        )
        lines_new.append(
            f'{indent}<!--<Property Id="ARPSYSTEMCOMPONENT" Value="1" />-->\n\n'
        )

        lines_new.append(
            f"{indent}<!--https://learn.microsoft.com/en-us/windows/win32/msi/property-reference-->\n"
        )
        for v in properties.values():
            if "msi" in v and "v" in v:
                lines_new.append(
                    f"{indent}<Property Id={quoteattr(v['msi'])} Value={quoteattr(v['v'])} />\n"
                )

        for i, line in enumerate(lines_new):
            lines.insert(index_start + i + 1, line)
        return lines

    return gen_content_between_tags(
        "Package/Fragments/AddRemoveProperties.wxs",
        "<!--$ArpStart$-->",
        "<!--$ArpEnd$-->",
        func,
    )


def get_folder_size(folder_path):
    total_size = 0

    folder = Path(folder_path)
    for file in folder.glob("**/*"):
        if file.is_file():
            total_size += file.stat().st_size

    return total_size


def gen_custom_ARPSYSTEMCOMPONENT_True(args, properties, dist_dir, exe_name):
    def func(lines, index_start):
        indent = g_indent_unit * 5

        lines_new = []
        lines_new.append(
            f"{indent}<!--https://learn.microsoft.com/en-us/windows/win32/msi/property-reference-->\n"
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="DisplayName" Value="{args.app_name}" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="DisplayIcon" Value="[INSTALLFOLDER_INNER]{exe_name}.exe" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="DisplayVersion" Value="{g_version}" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="Publisher" Value="{args.manufacturer}" />\n'
        )
        install_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="InstallDate" Value="{install_date}" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="InstallLocation" Value="[INSTALLFOLDER_INNER]" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="InstallSource" Value="[InstallSource]" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Name="Language" Value="[ProductLanguage]" />\n'
        )

        # EstimatedSize in uninstall registry must be in KB.
        estimated_size_bytes = get_folder_size(dist_dir)
        estimated_size = max(1, (estimated_size_bytes + 1023) // 1024)
        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Name="EstimatedSize" Value="{estimated_size}" />\n'
        )

        lines_new.append(
            f'{indent}<RegistryValue Type="expandable" Name="ModifyPath" Value="MsiExec.exe /X [ProductCode]" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Id="NoModify" Value="1" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="expandable" Name="UninstallString" Value="MsiExec.exe /X [ProductCode]" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="expandable" Name="QuietUninstallString" Value="MsiExec.exe /qn /X [ProductCode]" />\n'
        )

        vs = g_version.split(".")
        major, minor, build = vs[0], vs[1], vs[2]
        lines_new.append(
            f'{indent}<RegistryValue Type="string" Name="Version" Value="{g_version}" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Name="VersionMajor" Value="{major}" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Name="VersionMinor" Value="{minor}" />\n'
        )
        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Name="VersionBuild" Value="{build}" />\n'
        )

        lines_new.append(
            f'{indent}<RegistryValue Type="integer" Name="WindowsInstaller" Value="1" />\n'
        )
        for k, v in properties.items():
            if "v" in v:
                t = v.get("t", "string")
                lines_new.append(
                    f"{indent}<RegistryValue Type={quoteattr(t)} "
                    f"Name={quoteattr(k)} Value={quoteattr(v['v'])} />\n"
                )

        for i, line in enumerate(lines_new):
            lines.insert(index_start + i + 1, line)
        return lines

    return gen_content_between_tags(
        "Package/Components/Regs.wxs",
        "<!--$ArpStart$-->",
        "<!--$ArpEnd$-->",
        func,
    )


def gen_custom_ARPSYSTEMCOMPONENT(args, dist_dir, exe_name):
    try:
        custom_arp = json.loads(args.custom_arp)
        if not isinstance(custom_arp, dict):
            raise TypeError("--custom-arp must be a JSON object")
        properties = {key: value.copy() for key, value in g_arpsystemcomponent.items()}
        for key, value in custom_arp.items():
            if (
                not isinstance(key, str)
                or not isinstance(value, dict)
                or not all(isinstance(field, str) for field in value)
                or not all(
                    isinstance(field_value, str) for field_value in value.values()
                )
            ):
                raise ValueError(
                    "--custom-arp entries must contain string keys and values"
                )
            properties[key] = value
    except (json.JSONDecodeError, TypeError, ValueError) as e:
        print(f"Failed to decode custom arp: {e}")
        return False

    if args.arp:
        return gen_custom_ARPSYSTEMCOMPONENT_True(args, properties, dist_dir, exe_name)
    else:
        return gen_custom_ARPSYSTEMCOMPONENT_False(properties)


def gen_conn_type(args):
    def func(lines, index_start):
        indent = g_indent_unit * 3

        lines_new = []
        if args.conn_type != "":
            lines_new.append(
                f"""{indent}<Property Id="CC_CONNECTION_TYPE" Value={quoteattr(args.conn_type)} />\n"""
            )

        for i, line in enumerate(lines_new):
            lines.insert(index_start + i + 1, line)
        return lines

    return gen_content_between_tags(
        "Package/Fragments/AddRemoveProperties.wxs",
        "<!--$CustomClientPropsStart$-->",
        "<!--$CustomClientPropsEnd$-->",
        func,
    )


def gen_content_between_tags(filename, tag_start, tag_end, func):
    target_file = package_path(filename.removeprefix("Package/"))
    lines, index_start, index_end = read_lines_and_tag_indexes(
        target_file, tag_start, tag_end
    )
    del lines[index_start + 1 : index_end]

    func(lines, index_start)

    with target_file.open("w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)

    return True


def validate_shared_preprocessor_contract():
    """Require each independently compiled WiX source to load shared metadata."""
    violations = []
    for source in sorted(PACKAGE_DIR.rglob("*.wxs")):
        content = source.read_text(encoding="utf-8")
        references = [
            match
            for match in PREPROCESSOR_VARIABLE.finditer(content)
            if match.group(1) in SHARED_PREPROCESSOR_VARIABLES
        ]
        include = SHARED_INCLUDE.search(content)
        if references and (include is None or include.start() > references[0].start()):
            referenced = {match.group(1) for match in references}
            variables = ", ".join(sorted(referenced))
            violations.append(f"{source.relative_to(PACKAGE_DIR)} ({variables})")
    if violations:
        raise ValueError(
            "WiX sources reference shared preprocessor variables before including "
            f"Includes.wxi: {'; '.join(violations)}"
        )
    return True


def prepare_resources():
    icon_src = SCRIPT_DIR.parent / "icon.ico"
    icon_dst = PACKAGE_DIR / "Resources" / "icon.ico"
    if icon_src.exists():
        icon_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(icon_src, icon_dst)
        return True
    else:
        # unreachable
        print(f"Error: icon.ico not found in {icon_src}")
        return False


def init_global_vars(dist_dir, args):
    dist_app = dist_dir / f"{APPLICATION_EXECUTABLE}.exe"
    if dist_app.is_symlink() or not dist_app.is_file():
        print(f"Error: expected a regular executable at {dist_app}")
        return False

    def read_process_output(*process_args):
        process = subprocess.run(
            [str(dist_app), *process_args],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        )
        return process.stdout.decode("utf-8").strip()

    global g_version
    global g_build_date
    g_version = args.version.replace("-", ".")
    if g_version == "":
        g_version = read_process_output("--version")
    if stable_semver(g_version) is None:
        print(f"Error: version {g_version} not found in {dist_app}")
        return False
    if g_version.count(".") == 2:
        # https://github.com/dotnet/runtime/blob/5535e31a712343a63f5d7d796cd874e563e5ac14/src/libraries/System.Private.CoreLib/src/System/Version.cs
        if args.revision_version < 0 or args.revision_version > 2147483647:
            raise ValueError(f"Invalid revision version: {args.revision_version}")
        g_version = f"{g_version}.{args.revision_version}"

    g_build_date = read_process_output("--build-date")
    if BUILD_DATE.fullmatch(g_build_date) is None:
        print(f"Error: build date {g_build_date} not found in {dist_app}")
        return False

    return True


def update_license_file(_app_name):
    license_file = PACKAGE_DIR / "License.rtf"
    source_license = Path(__file__).resolve().parents[2].joinpath("LICENSE")
    license_text = source_license.read_text(encoding="utf-8")
    escaped = license_text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
    escaped = escaped.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\par\n")
    license_file.write_text(
        "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Consolas;}}\\f0\\fs16\n"
        + escaped
        + "\n}",
        encoding="ascii",
    )


if __name__ == "__main__":
    parser = make_parser()
    args = parser.parse_args()

    app_name = args.app_name.strip()
    if PRODUCT_TEXT.fullmatch(app_name) is None:
        parser.error("--app-name contains unsupported installer metadata characters")
    args.app_name = app_name
    args.manufacturer = args.manufacturer.strip()
    if PRODUCT_TEXT.fullmatch(args.manufacturer) is None:
        parser.error(
            "--manufacturer contains unsupported installer metadata characters"
        )
    dist_dir = distribution_directory(args.architecture)
    if dist_dir.is_symlink() or not dist_dir.is_dir():
        parser.error(
            f"the {args.architecture} Windows distribution must be a regular directory: "
            f"{dist_dir}"
        )

    if not prepare_resources():
        sys.exit(-1)

    exe_name = APPLICATION_EXECUTABLE
    if not init_global_vars(dist_dir, args):
        sys.exit(-1)

    update_license_file(app_name)

    if not gen_pre_vars(args, dist_dir, exe_name):
        sys.exit(-1)

    if not gen_upgrade_info():
        sys.exit(-1)

    if not gen_custom_ARPSYSTEMCOMPONENT(args, dist_dir, exe_name):
        sys.exit(-1)

    if not gen_conn_type(args):
        sys.exit(-1)

    if not gen_auto_component(app_name, exe_name, dist_dir):
        sys.exit(-1)

    if not gen_custom_dialog_bitmaps():
        sys.exit(-1)

    validate_shared_preprocessor_contract()

    replace_app_name_in_langs(args.app_name)
    replace_app_name_in_custom_actions(args.app_name)
