/*
 * GammaOS Gamepad axis layout of the virtual pad
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.lineageparts.input;

import android.os.SystemProperties;

import java.util.HashMap;
import java.util.Map;

/**
 * Где на виртуальном геймпаде gammapad правый стик и курки. Это зависит от пресета
 * (persist.gammaos.gamepad.device_pid), см. KeyLayoutParser::normalizeToPreset:
 * 0x02fd - стандартная раскладка (стик RX/RY, курки Z/RZ), остальные, в том числе
 * 0x0b13 по умолчанию, - родная Xbox BT (стик Z/RZ, курки BRAKE/GAS).
 *
 * Диалоги здесь раньше подписывали Z/RZ как LT/RT при любом пресете. На RG52 Mini (0x0b13)
 * это правый стик: назначение курков в Axis assignment уводило стик в курки, а выбор
 * «LT»/«RT» в Button to axis двигал стик кнопкой.
 */
final class GamepadAxisLayout {
    static final int ABS_X = 0x00;
    static final int ABS_Y = 0x01;
    static final int ABS_Z = 0x02;
    static final int ABS_RX = 0x03;
    static final int ABS_RY = 0x04;
    static final int ABS_RZ = 0x05;
    static final int ABS_GAS = 0x09;
    static final int ABS_BRAKE = 0x0a;
    static final int ABS_HAT0X = 0x10;
    static final int ABS_HAT0Y = 0x11;

    private GamepadAxisLayout() {}

    /** The same test as GamepadCalibrationDialogFragment and the daemon. */
    static boolean usesStandardLayout() {
        String pid = SystemProperties.get("persist.gammaos.gamepad.device_pid", "0x0b13")
                .replace("0x", "").toLowerCase();
        return "02fd".equals(pid) || "2fd".equals(pid);
    }

    static int rightStickX() {
        return usesStandardLayout() ? ABS_RX : ABS_Z;
    }

    static int rightStickY() {
        return usesStandardLayout() ? ABS_RY : ABS_RZ;
    }

    static int leftTrigger() {
        return usesStandardLayout() ? ABS_Z : ABS_BRAKE;
    }

    static int rightTrigger() {
        return usesStandardLayout() ? ABS_RZ : ABS_GAS;
    }

    /**
     * Output axes of the virtual pad for the Axis to button picker: sticks, then triggers.
     * The standard layout also has GAS/BRAKE, as the picker always offered.
     */
    static int[] pickerAxes() {
        return usesStandardLayout()
                ? new int[] { ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ, ABS_GAS, ABS_BRAKE }
                : new int[] { ABS_X, ABS_Y, ABS_Z, ABS_RZ, ABS_BRAKE, ABS_GAS };
    }

    /** Axes a digital button can drive as a trigger (Button to axis). */
    static int[] triggerAxes() {
        return usesStandardLayout()
                ? new int[] { ABS_Z, ABS_RZ, ABS_BRAKE, ABS_GAS }
                : new int[] { ABS_BRAKE, ABS_GAS };
    }

    /** Short names of the virtual pad's output axes for summaries and pickers. */
    static Map<Integer, String> axisNames() {
        Map<Integer, String> names = new HashMap<>();
        names.put(ABS_X, "LX");
        names.put(ABS_Y, "LY");
        names.put(rightStickX(), "RX");
        names.put(rightStickY(), "RY");
        names.put(leftTrigger(), "LT");
        names.put(rightTrigger(), "RT");
        names.putIfAbsent(ABS_GAS, "GAS");
        names.putIfAbsent(ABS_BRAKE, "BRAKE");
        names.put(ABS_HAT0X, "DpadX");
        names.put(ABS_HAT0Y, "DpadY");
        return names;
    }
}
