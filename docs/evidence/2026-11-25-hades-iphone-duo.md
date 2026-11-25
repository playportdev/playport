# Hades on iPhone Duo

Hades (Steam 1145360) reached Tartarus on an iPhone Duo (iPhone19,4, iOS 27.2.1) with Playport 0.5.0. The Steam Windows files were imported as a local game. The release IPA before local signing had SHA-256 `2620958cb60a0b452351976ec5d43fd179d1a2ada9d1cc4adef5b7b89beca04a`.

| Executable | Playport graphics setting | Observed result |
| --- | --- | --- |
| `x64\Hades.exe` | Vulkan and DXMT | Exited before the first frame |
| `x64Vk\Hades.exe` | DXMT | Exited before the first frame |
| `x86\Hades.exe` | DXMT | Exited after the first frame |
| `x86\Hades.exe` | Vulkan | Main menu, new save and movement to the first gate in Tartarus |

The successful run used the touch gamepad, a 720p guest display and a 60 fps cap. The check covered the opening room. Sustained frame rate and Bluetooth controller input were unmeasured.

[Original launch report](https://github.com/playportdev/playport/issues/91)
