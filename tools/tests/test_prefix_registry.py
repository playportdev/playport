# SPDX-License-Identifier: GPL-3.0-or-later
"""app/tools/prefix-registry.py: the NEUTRALISE keys (decision 0071) in the
committed user.reg seed, marked for top-up, with the values that keep winedbg's
crash dialog, winemenubuilder and control.exe's add-on download off the phone;
the Visual C++ runtime key (VC_RUNTIME), wintrust's and msisip's registration
(register_wintrust: OID functions, trust providers, SIPs; register_msisip) and the Windows Imaging Component
registration (register_wic, decision 0072) in the committed system.reg seed,
and its reading of windowscodecs' regsvr.c tables; wine.inf's AddReg sections, urlmon's
REGINST zones, the media registrations and the i386-only modules' classes (decision 0080),
with REQUIRED: registrations a wineboot'ed prefix has that the seed must keep, and
REQUIRED_I386: what i386 callers read in the one 64-bit view (PLA-175); and the shipped
fonts registered for DirectWrite (PLA-374)."""
import importlib.util
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]
MARKER = ";; playport:top-up"


class Keys(dict):
    """Registry key names compare without case, as wineserver's do."""

    def __getitem__(self, key):
        return super().__getitem__(key.lower())

    def __contains__(self, key):
        return super().__contains__(key.lower())


def sections(text):
    """[key] -> (marked, value lines) of a wineserver registry file."""
    out, key, marked, prev = Keys(), None, False, ""
    for line in text.splitlines():
        if line.startswith("["):
            key, marked = line[1:line.rindex("]")].lower(), prev == MARKER
            dict.__setitem__(out, key, (marked, []))
        elif key and line and not line.startswith(("#", ";")):
            out[key][1].append(line)
        prev = line
    return out


class Neutralise(unittest.TestCase):
    def test_user_seed_turns_off_the_crash_dialog_menubuilder_and_addon_installer(self):
        user = sections((REPO / "app/registry/user.reg").read_text())
        marked, values = user["Software\\\\Wine\\\\WineDbg"]
        self.assertTrue(marked)
        self.assertIn('"ShowCrashDialog"=dword:00000000', values)
        marked, values = user["Software\\\\Wine\\\\DllOverrides"]
        self.assertTrue(marked)
        self.assertIn('"control.exe"=""', values)
        self.assertIn('"winemenubuilder.exe"=""', values)


class VcRuntime(unittest.TestCase):
    def test_system_seed_reports_the_vc_runtime_installed_as_wine_inf_does(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        marked, values = system["Software\\\\Microsoft\\\\VisualStudio\\\\14.0\\\\VC\\\\Runtimes\\\\x64"]
        self.assertTrue(marked)
        self.assertIn('"Installed"=dword:00000001', values)
        self.assertIn('"Major"=dword:0000000e', values)
        self.assertIn('"Minor"=dword:00000033', values)
        self.assertIn('"Rbld"=dword:00000000', values)


class Fonts(unittest.TestCase):
    def test_system_seed_registers_each_shipped_face_where_dwrite_builds_its_collection(self):
        # Wine's dwrite reads only this key (PLA-374); a bare file name is in %windir%\fonts,
        # where wine_host.c link_fonts links every file of Runtime/fonts.
        marked, values = sections((REPO / "app/registry/system.reg").read_text())[
            "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts"]
        self.assertTrue(marked)
        self.assertIn('"Tahoma (TrueType)"="tahoma.ttf"', values)
        self.assertIn('"Tahoma Bold (TrueType)"="tahomabd.ttf"', values)
        spec = importlib.util.spec_from_file_location("font_stage", REPO / "build/stages/stage-artifacts.py")
        stage = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stage)
        registered = {line.split("=", 1)[1].strip('"') for line in values}
        self.assertEqual(registered, set(stage.FONTS))


class WintrustRegistration(unittest.TestCase):
    def test_pe_image_sip_names_wintrusts_functions_so_cryptqueryobject_finds_a_signature(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        key = ("Software\\\\Microsoft\\\\Cryptography\\\\OID\\\\EncodingType 0\\\\"
               "CryptSIPDllGetSignedDataMsg\\\\{C689AAB8-8E78-11D0-8C47-00C04FC295EE}")
        _marked, values = system[key]
        self.assertEqual(values, ['"Dll"="WINTRUST.DLL"', '"FuncName"="CryptSIPGetSignedDataMsg"'])

    def test_generic_verify_v2_names_softpubs_steps_so_winverifytrust_loads_a_signer(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        trust = "Software\\\\Microsoft\\\\Cryptography\\\\Providers\\\\Trust\\\\"
        for step, function in (("Message", "SoftpubLoadMessage"), ("Signature", "SoftpubLoadSignature"),
                               ("Certificate", "WintrustCertificateTrust"), ("FinalPolicy", "SoftpubAuthenticode")):
            _marked, values = system[f"{trust}{step}\\\\{{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}}"]
            self.assertEqual(values, ['"$DLL"="WINTRUST.DLL"', f'"$Function"="{function}"'])
        self.assertNotIn(f"{trust}DiagnosticPolicy\\\\{{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}}", system)

    def test_msi_package_sip_names_msisip_so_an_msi_signature_is_read(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        _marked, values = system["Software\\\\Microsoft\\\\Cryptography\\\\OID\\\\EncodingType 0\\\\"
                                 "CryptSIPDllIsMyFileType2\\\\{000C10F1-0000-0000-C000-000000000046}"]
        self.assertEqual(values, ['"Dll"="MSISIP.DLL"', '"FuncName"="MsiSIPIsMyTypeOfFile"'])

    def test_indirect_data_struct_decodes_through_wintrust(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        _marked, values = system["Software\\\\Microsoft\\\\Cryptography\\\\OID\\\\EncodingType 1\\\\"
                                 "CryptDllDecodeObject\\\\#2003"]
        self.assertEqual(values, ['"Dll"="WINTRUST.DLL"', '"FuncName"="WVTAsn1SpcIndirectDataContentDecode"'])


CLSID = "Software\\\\Classes\\\\CLSID\\\\"
PNG_DECODER = "{389EA17B-5078-4CDE-B6EF-25C15175C751}"
CATID_WIC_BITMAP_DECODERS = "{7ED96837-96F0-4812-B211-F13C24117ED3}"


class WicSeed(unittest.TestCase):
    def test_png_decoder_is_an_instance_of_the_decoder_category_in_the_64_bit_classes(self):
        system = sections((REPO / "app/registry/system.reg").read_text())
        marked, values = system[f"{CLSID}{CATID_WIC_BITMAP_DECODERS}\\\\Instance\\\\{PNG_DECODER}"]
        self.assertTrue(marked)
        self.assertEqual(values, [f'"CLSID"="{PNG_DECODER}"'])
        marked, values = system[f"{CLSID}{PNG_DECODER}\\\\Patterns\\\\0"]
        self.assertTrue(marked)
        self.assertIn('"Pattern"=hex:89,50,4e,47,0d,0a,1a,0a', values)
        self.assertIn('"Mask"=hex:ff,ff,ff,ff,ff,ff,ff,ff', values)
        self.assertIn('"Length"=dword:00000008', values)

    def test_existing_decoder_class_key_is_marked_so_a_prefix_gets_its_new_values(self):
        marked, values = sections((REPO / "app/registry/system.reg").read_text())[f"{CLSID}{PNG_DECODER}"]
        self.assertTrue(marked)
        self.assertIn('"ContainerFormat"="{1B7CFAF4-713F-473C-BBCD-6137425FAEAF}"', values)

    def test_no_32_bit_class_keys_hide_the_shared_classes_from_i386_callers(self):
        self.assertNotIn("Wow6432Node", (REPO / "app/registry/system.reg").read_text())

    def test_no_wow64_emulator_key_names_an_x86_64_hosts_cpu_dll_for_i386_games(self):
        self.assertNotIn("[Software\\\\Microsoft\\\\Wow64", (REPO / "app/registry/system.reg").read_text())

    def test_steam_dotnet_and_xna_redistributables_count_as_run_as_protons_wine_inf_has_them(self):
        marked, values = sections((REPO / "app/registry/system.reg").read_text())[
            "Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\.NET\\\\4.8"]
        self.assertTrue(marked)
        self.assertIn('"4.8"=dword:00000001', values)
        self.assertIn("Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\XNA\\\\4.0",
                      sections((REPO / "app/registry/system.reg").read_text()))


# Registrations a desktop wineboot of the wine pin has (PLA-163's comparison) that titles or
# Wine itself read; the seed must carry each (key, value line). A pin move that loses one
# fails here.
REQUIRED = [
    ("Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion", '"CurrentBuildNumber"="19045"'),
    ("Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion", '"ProductName"="Windows 10 Pro"'),
    ("Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion", '"CurrentMajorVersionNumber"=dword:0000000a'),
    ("Software\\\\Microsoft\\\\Windows\\\\CurrentVersion", '"ProgramFilesDir"="C:\\\\Program Files"'),
    ("Software\\\\Microsoft\\\\Windows\\\\CurrentVersion", '"CommonFilesDir"="C:\\\\Program Files\\\\Common Files"'),
    ("Software\\\\Microsoft\\\\Windows\\\\CurrentVersion", '"ProgramFilesDir (x86)"="C:\\\\Program Files (x86)"'),
    ("Software\\\\Microsoft\\\\DirectX", '"Version"="4.09.00.0904"'),
    ("Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes", '"MS Shell Dlg 2"="Tahoma"'),
    ("System\\\\CurrentControlSet\\\\Control\\\\Lsa", '"Security Packages"=str(7):"kerberos\\0schannel\\0"'),
    ("Software\\\\Classes\\\\.lnk", '@="lnkfile"'),
    ("Software\\\\Classes\\\\DirectShow\\\\MediaObjects\\\\2EEB4ADF-4578-4D10-BCA7-BB955F56320A",
     '@="WMAudio Decoder DMO"'),
    ("Software\\\\Classes\\\\MediaFoundation\\\\Transforms\\\\82d353df-90bd-4382-8bc2-3f6192b76e34",
     '@="WMVideo Decoder MFT"'),
    ("Software\\\\Classes\\\\CLSID\\\\{083863F1-70DE-11D0-BD40-00A0C911CE86}\\\\Instance\\\\"
     "{F9D8D64E-A144-47DC-8EE0-F53498372C29}", '"FriendlyName"="GStreamer splitter filter"'),
    ("Software\\\\Classes\\\\CLSID\\\\{D2AC2881-B39B-11D1-8704-00600893B1BD}\\\\InprocServer32",
     '@="C:\\\\windows\\\\system32\\\\dmime.dll"'),
]
REQUIRED_USER = [
    ("Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Internet Settings\\\\ZoneMap\\\\ProtocolDefaults",
     '"http"=dword:00000003'),
    ("Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\ThemeManager", '"ThemeActive"="1"'),
    # wineboot's create_volatile_environment_registry_key (decision 0098)
    ("Volatile Environment", '"USERDOMAIN"="PLAYPORT"'),
    ("Volatile Environment", '"LOGONSERVER"="\\\\\\\\PLAYPORT"'),
    ("Volatile Environment", '"SESSIONNAME"="Console"'),
]


class WineBootParity(unittest.TestCase):
    def test_seed_carries_the_registrations_a_wineboot_prefix_has(self):
        for name, required in (("system", REQUIRED), ("user", REQUIRED_USER)):
            seed = sections((REPO / f"app/registry/{name}.reg").read_text())
            for key, value in required:
                with self.subTest(key=key, value=value):
                    self.assertIn(key, seed)
                    marked, values = seed[key]
                    self.assertTrue(marked)
                    self.assertIn(value, values)

    def test_url_handlers_stay_playports_over_wine_infs_winebrowser(self):
        seed = sections((REPO / "app/registry/system.reg").read_text())
        _marked, values = seed["Software\\\\Classes\\\\https\\\\shell\\\\open\\\\command"]
        self.assertEqual(values, ['@="\\"C:\\\\windows\\\\system32\\\\playport-url-opener.exe\\" \\"%1\\""'])


# What an i386 (WoW64) caller reads where a wineboot'ed prefix has a 32-bit view (PLA-175).
# The seed has one view: wineserver sends an i386 open of HKLM\Software to
# Software\Wow6432Node only if that key exists (falling back to HKLM\Software for names it
# lacks, wine-unix 0030), and an i386 open of a class to Software\Classes\Wow6432Node
# (shared, falls back to Software\Classes). So i386
# callers read these 64-bit keys: the i386-only modules' classes (decision 0080), the classes
# i386 games create, the InstallRoot wine-pe 0036 maps to Framework\ for them (decision
# 0085), and the x86 Program Files path ntdll gives a WoW64 process as %ProgramFiles%.
REQUIRED_I386 = [
    (CLSID + "{D2AC2881-B39B-11D1-8704-00600893B1BD}\\\\InprocServer32",  # DirectMusicPerformance
     ['@="C:\\\\windows\\\\system32\\\\dmime.dll"', '"ThreadingModel"="Both"']),
    (CLSID + "{79BA9E00-B6EE-11D1-86BE-00C04FBF8FEF}\\\\InprocServer32",  # DirectMusicBand
     ['@="C:\\\\windows\\\\system32\\\\dmband.dll"', '"ThreadingModel"="Both"']),
    (CLSID + "{2FE8F810-B2A5-11D0-A787-0000F803ABFC}\\\\InprocServer32",  # DirectPlayLobby
     ['@="C:\\\\windows\\\\system32\\\\dplayx.dll"', '"ThreadingModel"="Both"']),
    (CLSID + "{0E59F1D5-1FBE-11D0-8FF2-00A0D10038BC}\\\\InprocServer32",  # ScriptControl
     ['@="C:\\\\windows\\\\system32\\\\msscript.ocx"', '"ThreadingModel"="Apartment"']),
    (CLSID + "{E436EBB3-524F-11CE-9F53-0020AF0BA770}\\\\InprocServer32",  # FilterGraph
     ['@="C:\\\\windows\\\\system32\\\\quartz.dll"', '"ThreadingModel"="Both"']),
    (CLSID + "{5A508685-A254-4FBA-9B82-9A24B00306AF}\\\\InprocServer32",  # XAudio2 2.7
     ['@="C:\\\\windows\\\\system32\\\\xaudio2_7.dll"', '"ThreadingModel"="Both"']),
    ("Software\\\\Microsoft\\\\.NETFramework",
     ['"InstallRoot"="C:\\\\windows\\\\Microsoft.NET\\\\Framework64\\\\"']),
    ("Software\\\\Microsoft\\\\Windows\\\\CurrentVersion",
     ['"ProgramFilesDir (x86)"="C:\\\\Program Files (x86)"',
      '"CommonFilesDir (x86)"="C:\\\\Program Files (x86)\\\\Common Files"']),
]


class Wow64View(unittest.TestCase):
    def test_i386_callers_find_their_registrations_in_the_one_64_bit_view(self):
        seed = sections((REPO / "app/registry/system.reg").read_text())
        for key, required in REQUIRED_I386:
            with self.subTest(key=key):
                self.assertIn(key, seed)
                for value in required:
                    self.assertIn(value, seed[key][1])

    def test_no_32_bit_software_view_hides_hklm_software_and_hkcr_from_i386_callers(self):
        # A Software\Wow6432Node key makes wineserver look up every i386 HKLM\Software path
        # there first, HKCR's Software\Classes included; wine-unix 0030 falls back to the one
        # view only for names it lacks, so a seeded key would still hide what it holds.
        for name in ("system", "user"):
            with self.subTest(hive=name):
                self.assertNotIn("software\\\\wow6432node",
                                 (REPO / f"app/registry/{name}.reg").read_text().lower())


WINE_INF = r"""
[DefaultInstall.ntamd64]
Needs=BaseInstall
AddReg=\
    Two

[BaseInstall]
AddReg=One ; a comment

[One]
HKLM,%Key%,"Name",,"%11%\x.exe ""%1"" go"
HKLM,%Key%,"Path",0x20000,"%%Path%%;%Unknown%"
HKLM,%Key%,"Nums",0x10000,"a","b"
HKLM,%Key%,"Dw",0x10001,0x1f4
HKLM,%Key%,"Bin",1,21,81,\
7c
HKLM,%Key%,"Keep",2,"first"
HKLM,%Key%,"Keep",2,"second"
HKCU,Software\Only,,16
HKLM,Software\Link,"SymbolicLinkValue",0x60000,"\Registry\Machine\X"

[Two]
HKCR,.foo,,2,"foofile"

[Strings]
Key="Software\Test"
"""


@unittest.skipUnless(importlib.util.find_spec("pefile"), "prefix-registry.py imports pefile")
class WineInf(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("prefix_registry", REPO / "app/tools/prefix-registry.py")
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def test_addreg_lines_follow_setupapis_types_strings_and_noclobber(self):
        hives = {"system": self.mod.Hive(), "user": self.mod.Hive()}
        sections = self.mod.inf_sections(WINE_INF)
        self.assertEqual(self.mod.wine_inf_addreg(sections), ["One", "Two"])
        marked = self.mod.apply_addreg(hives, sections, ["One", "Two"], "test")
        values = hives["system"].keys["software\\test"][1]
        self.assertEqual(values["name"], ("Name", "sz", 'C:\\windows\\system32\\x.exe "%1" go'))
        self.assertEqual(values["path"], ("Path", "expand_sz", "%Path%;%Unknown%"))
        self.assertEqual(values["nums"], ("Nums", "multi_sz", ["a", "b"]))
        self.assertEqual(values["dw"], ("Dw", "dword", 0x1f4))
        self.assertEqual(values["bin"], ("Bin", "binary", bytes([0x21, 0x81, 0x7c])))
        self.assertEqual(values["keep"][2], "first")
        self.assertIn("software\\only", hives["user"].keys)
        self.assertNotIn("software\\link", hives["system"].keys)
        self.assertEqual(hives["system"].keys["software\\classes\\.foo"][1][""][2], "foofile")
        self.assertIn("software\\test", marked["system"])

    def test_changed_reg_operation_stops_the_generation(self):
        with self.assertRaisesRegex(SystemExit, "do_reg_operation changed"):
            self.mod.register_wine_inf({}, WINE_INF, "static BOOL do_reg_operation( void )\n{\n}\n")

    def test_unknown_directory_id_fails(self):
        with self.assertRaisesRegex(SystemExit, "directory id"):
            self.mod.inf_subst("%16999%\\x", {})


REGSVR = r"""
struct decoder_pattern
{
    DWORD length;    /* 0 for end of list */
    DWORD position;
    const BYTE *pattern;
    const BYTE *mask;
    DWORD endofstream;
};
struct regsvr_thing
{
    CLSID const *clsid;         /* NULL for end of list */
    LPCSTR friendlyname;
    GUID const * const *formats;
    const struct decoder_pattern *patterns;
};
static const BYTE mask_all[] = {0xff,0xff,0xff,0xff};
static const BYTE ico_magic[] = {00,00,01,00};
static const BYTE gif_magic[3] = "GIF";
static const BYTE dds_magic[] = "DDS";
static GUID const * const formats[] = {
    &GUID_A,
    NULL
};
static struct decoder_pattern const patterns[] = {
    {4,0,ico_magic,mask_all,0},
    {3,2,gif_magic,mask_all,1},
    {0}
};
static struct regsvr_thing const thing_list[] = {
    {   &CLSID_Thing,
        "Thing \"One\"",
        formats,
        patterns
    },
    {   &CLSID_Other },
    { NULL }    /* list terminator */
};
"""
HEADER = """DEFINE_GUID(GUID_A, 0x6fddc324,0x4e03,0x4bfe,0xb1,0x85,0x3d,0x77,0x76,0x8d,0xc9,0x0f);
DEFINE_GUID(CLSID_Thing, 0x389ea17b,0x5078,0x4cde,0xb6,0xef,0x25,0xc1,0x51,0x75,0xc7,0x51);
DEFINE_GUID(CLSID_Other, 0x00000001,0x0002,0x0003,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b);
"""


@unittest.skipUnless(importlib.util.find_spec("pefile"), "prefix-registry.py imports pefile")
class WicSource(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("prefix_registry", REPO / "app/tools/prefix-registry.py")
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def test_struct_tables_resolve_guids_byte_arrays_and_stop_at_the_terminator(self):
        src = self.mod.WicSource(REGSVR, [HEADER])
        rows = src.entries("thing_list", "regsvr_thing", "clsid")
        self.assertEqual([r["clsid"] for r in rows], [
            "{389EA17B-5078-4CDE-B6EF-25C15175C751}", "{00000001-0002-0003-0405-060708090A0B}"])
        self.assertEqual(rows[0]["friendlyname"], b'Thing "One"')
        self.assertEqual(src.guid_list(rows[0]["formats"]), ["{6FDDC324-4E03-4BFE-B185-3D77768DC90F}"])
        self.assertIsNone(rows[1]["patterns"])
        pats = src.entries(rows[0]["patterns"], "decoder_pattern", "length")
        self.assertEqual([(p["length"], p["position"], p["pattern"], p["endofstream"]) for p in pats],
                         [(4, 0, b"\x00\x00\x01\x00", 0), (3, 2, b"GIF", 1)])
        self.assertEqual(src.array("dds_magic"), b"DDS\x00")

    def test_a_pattern_longer_than_its_table_fails(self):
        with self.assertRaises(SystemExit):
            self.mod.fixed(b"GIF", 4, "test")

    def test_changed_register_code_stops_the_generation(self):
        regsvr = "".join(f"static HRESULT {fn}(void *list)\n{{\n}}\n" for fn in self.mod.WIC_FUNCTIONS[:-1])
        regsvr += "HRESULT WINAPI DllRegisterServer(void)\n{\n}\n"
        with self.assertRaisesRegex(SystemExit, "register_\\* code changed"):
            self.mod.register_wic(self.mod.Hive(), regsvr, [HEADER])

    def test_changed_wintrust_registration_stops_the_generation(self):
        register = "".join(f"static BOOL {fn}(void)\n{{\n}}\n" for fn in self.mod.WINTRUST_FUNCTIONS)
        with self.assertRaisesRegex(SystemExit, "registration code changed"):
            self.mod.register_wintrust(self.mod.Hive(), register)

    def test_changed_msisip_registration_stops_the_generation(self):
        with self.assertRaisesRegex(SystemExit, "DllRegisterServer changed"):
            self.mod.register_msisip(self.mod.Hive(), "HRESULT WINAPI DllRegisterServer(void)\n{\n}\n")


if __name__ == "__main__":
    unittest.main()
